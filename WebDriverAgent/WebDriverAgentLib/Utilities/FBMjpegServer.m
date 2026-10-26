/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBMjpegServer.h"

#import <mach/mach_time.h>
@import UniformTypeIdentifiers;

// Textual import, not `@import Network;` - see the comment in FBTCPSocket.h.
#import <Network/Network.h>
#import "FBConfiguration.h"
#import "FBHTTPServer.h"
#import "FBLogger.h"
#import "FBScreenshot.h"
#import "FBScreen.h"
#import "FBImageProcessor.h"
#import "FBImageUtils.h"
#import "XCUIScreen.h"

static const NSUInteger MAX_FPS = 60;
static const NSTimeInterval FRAME_TIMEOUT = 1.;
// nw_connection_send buffers without backpressure, so a client that stops reading would retain
// every generated frame. Frames past this cap are dropped instead of queued.
static const NSUInteger MAX_PENDING_FRAMES_PER_CLIENT = 4;
static const NSTimeInterval FAILURE_BACKOFF_MIN = 1.0;
static const NSTimeInterval FAILURE_BACKOFF_MAX = 10.0;
// Caps a client's request head while it is being checked for credentials, so a connection that
// never completes one cannot grow its buffer without limit. Matches FBHTTPServer's header cap.
static const NSUInteger MAX_REQUEST_HEAD_SIZE = 16 * 1024;

static NSString *const SERVER_NAME = @"WDA MJPEG Server";
static const char *QUEUE_NAME = "JPEG Screenshots Provider Queue";

static NSUInteger FBNormalizedMjpegFramerate(NSUInteger framerate)
{
  return (0 == framerate || framerate > MAX_FPS) ? MAX_FPS : framerate;
}

// Whether a stream request's request line + headers carry `password`. An Authorization header,
// when present, is the only credential considered.
static BOOL FBMjpegRequestHeadIsAuthorized(NSString * _Nonnull requestHead, NSString * _Nonnull password)
{
  NSArray<NSString *> *lines = [requestHead componentsSeparatedByString:@"\r\n"];
  for (NSUInteger i = 1; i < lines.count; i++) {
    NSString *line = lines[i];
    NSRange colonRange = [line rangeOfString:@":"];
    if (NSNotFound == colonRange.location
        || NSOrderedSame != [[line substringToIndex:colonRange.location] caseInsensitiveCompare:@"Authorization"]) {
      continue;
    }
    NSString *value = [[line substringFromIndex:NSMaxRange(colonRange)]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return FBHTTPAuthorizationMatchesPassword(value, password);
  }
  // <img> tags cannot set headers, so the password is also accepted as a "token" query parameter.
  // Unlike a header, it can end up in logs or browser history.
  NSArray<NSString *> *requestLineParts = [lines.firstObject componentsSeparatedByString:@" "];
  if (requestLineParts.count < 2) {
    return NO;
  }
  NSURLComponents *requestTarget = [NSURLComponents componentsWithString:requestLineParts[1]];
  for (NSURLQueryItem *queryItem in requestTarget.queryItems) {
    if ([queryItem.name isEqualToString:@"token"] && nil != queryItem.value) {
      NSString *bearer = [@"Bearer " stringByAppendingString:(NSString * _Nonnull)queryItem.value];
      return FBHTTPAuthorizationMatchesPassword(bearer, password);
    }
  }
  return NO;
}


@interface FBMjpegServer()

@property (nonatomic, readonly) dispatch_queue_t backgroundQueue;
@property (nonatomic, readonly) NSMutableArray<nw_connection_t> *listeningClients;
@property (nonatomic, readonly) FBImageProcessor *imageProcessor;
@property (nonatomic, assign) NSUInteger consecutiveScreenshotFailures;
@property (atomic, assign) BOOL isStreaming;
@property (nonatomic, assign) NSUInteger sentFramesCount;
@property (nonatomic, assign) NSUInteger sentBytesCount;
@property (nonatomic, assign) NSUInteger droppedFramesCount;
// Frames submitted but not sent yet, per client. Guarded by @synchronized (self.listeningClients).
@property (nonatomic, readonly) NSMapTable<id, NSNumber *> *pendingFrameCounts;
// Request bytes received so far from clients whose credentials are not checked yet, and clients
// already turned away. Both guarded by @synchronized (self.listeningClients).
@property (nonatomic, readonly) NSMapTable<id, NSMutableData *> *pendingRequestBuffers;
@property (nonatomic, readonly) NSMutableSet *rejectedClients;

@end


@implementation FBMjpegServer

- (instancetype)init
{
  if ((self = [super init])) {
    _consecutiveScreenshotFailures = 0;
    _isStreaming = YES;
    _sentFramesCount = 0;
    _sentBytesCount = 0;
    _listeningClients = [NSMutableArray array];
    _pendingFrameCounts = [NSMapTable mapTableWithKeyOptions:(NSPointerFunctionsOptions)(NSMapTableObjectPointerPersonality | NSMapTableStrongMemory)
                                                valueOptions:(NSPointerFunctionsOptions)NSMapTableStrongMemory];
    _pendingRequestBuffers = [NSMapTable mapTableWithKeyOptions:(NSPointerFunctionsOptions)(NSMapTableObjectPointerPersonality | NSMapTableStrongMemory)
                                                   valueOptions:(NSPointerFunctionsOptions)NSMapTableStrongMemory];
    _rejectedClients = [NSMutableSet set];
    _imageProcessor = [[FBImageProcessor alloc] init];
    dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    _backgroundQueue = dispatch_queue_create(QUEUE_NAME, queueAttributes);
    __weak typeof(self) weakSelf = self;
    dispatch_async(_backgroundQueue, ^{
      [weakSelf streamScreenshot];
    });
  }
  return self;
}

- (void)scheduleNextScreenshotWithInterval:(uint64_t)timerInterval timeStarted:(uint64_t)timeStarted
{
  if (!self.isStreaming) {
    return;
  }
  uint64_t timeElapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - timeStarted;
  int64_t nextTickDelta = (int64_t)timerInterval - (int64_t)timeElapsed;
  __weak typeof(self) weakSelf = self;
  if (nextTickDelta > 0) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, nextTickDelta), self.backgroundQueue, ^{
      [weakSelf streamScreenshot];
    });
  } else {
    // Try to do our best to keep the FPS at a decent level
    dispatch_async(self.backgroundQueue, ^{
      [weakSelf streamScreenshot];
    });
  }
}

- (void)streamScreenshot
{
  if (!self.isStreaming) {
    return;
  }
  NSUInteger framerate = FBNormalizedMjpegFramerate(FBConfiguration.sharedInstance.mjpegServerFramerate);
  uint64_t timerInterval = (uint64_t)(1.0 / (double)framerate * NSEC_PER_SEC);
  uint64_t timeStarted = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
  @synchronized (self.listeningClients) {
    if (0 == self.listeningClients.count) {
      [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
      return;
    }
  }

  NSError *error;
  CGFloat compressionQuality = MAX(FBMinCompressionQuality,
                                   MIN(FBMaxCompressionQuality, (double)FBConfiguration.sharedInstance.mjpegServerScreenshotQuality / 100.0));
  XCUIScreen *screen = [FBScreen currentScreenWithError:&error];
  NSData *screenshotData = nil == screen ? nil : [FBScreenshot takeInOriginalResolutionWithScreenID:screen.displayID
                                                           compressionQuality:compressionQuality
                                                                          uti:UTTypeJPEG
                                                                      timeout:FRAME_TIMEOUT
                                                                        error:&error];
  if (nil == screenshotData) {
    [FBLogger logFmt:@"%@", error.description];
    self.consecutiveScreenshotFailures++;
    NSTimeInterval backoffSeconds = MIN(FAILURE_BACKOFF_MAX,
                                        FAILURE_BACKOFF_MIN * (1 << MIN(self.consecutiveScreenshotFailures, 4)));
    uint64_t backoffInterval = (uint64_t)(backoffSeconds * NSEC_PER_SEC);
    [self scheduleNextScreenshotWithInterval:backoffInterval timeStarted:timeStarted];
    return;
  }

  self.consecutiveScreenshotFailures = 0;

  CGFloat scalingFactor = FBConfiguration.sharedInstance.mjpegScalingFactor / 100.0;
  __weak typeof(self) weakSelf = self;
  [self.imageProcessor submitImageData:screenshotData
                         scalingFactor:scalingFactor
                     completionHandler:^(NSData * _Nonnull scaled) {
    [weakSelf sendScreenshot:scaled];
  }];

  [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
}

- (void)sendScreenshot:(NSData *)screenshotData {
  if (!self.isStreaming) {
    return;
  }
  NSString *chunkHeader = [NSString stringWithFormat:@"--BoundaryString\r\nContent-type: image/jpeg\r\nContent-Length: %@\r\n\r\n", @(screenshotData.length)];
  NSMutableData *chunk = [[chunkHeader dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  [chunk appendData:screenshotData];
  [chunk appendData:(id)[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
  @synchronized (self.listeningClients) {
    if (!self.isStreaming || 0 == self.listeningClients.count) {
      return;
    }
    NSUInteger clientCount = self.listeningClients.count;
    __weak typeof(self) weakSelf = self;
    for (nw_connection_t client in self.listeningClients) {
      NSUInteger pendingFrames = [self.pendingFrameCounts objectForKey:client].unsignedIntegerValue;
      if (pendingFrames >= MAX_PENDING_FRAMES_PER_CLIENT) {
        self.droppedFramesCount++;
        continue;
      }
      [self.pendingFrameCounts setObject:@(pendingFrames + 1) forKey:client];
      [self.socket writeData:chunk toClient:client completion:^(BOOL didSucceed) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (nil == strongSelf) {
          return;
        }
        @synchronized (strongSelf.listeningClients) {
          NSUInteger stillPending = [strongSelf.pendingFrameCounts objectForKey:client].unsignedIntegerValue;
          if (stillPending > 1) {
            [strongSelf.pendingFrameCounts setObject:@(stillPending - 1) forKey:client];
          } else {
            [strongSelf.pendingFrameCounts removeObjectForKey:client];
          }
        }
      }];
    }
    self.sentFramesCount++;
    self.sentBytesCount += chunk.length * clientCount;
    NSUInteger framerate = FBNormalizedMjpegFramerate(FBConfiguration.sharedInstance.mjpegServerFramerate);
    if (0 == self.sentFramesCount % framerate) {
      [FBLogger verboseLog:[NSString stringWithFormat:@"MJPEG stats: clients=%@ sentFrames=%@ sentBytes=%@ droppedFrames=%@",
                            @(clientCount),
                            @(self.sentFramesCount),
                            @(self.sentBytesCount),
                            @(self.droppedFramesCount)]];
    }
  }
}

- (void)didClientConnect:(nw_connection_t)newClient
{
  [FBLogger log:@"Got screenshots broadcast client connection"];
  // FBTCPSocket already schedules the receive that -client:didReceiveData: relies on below.
}

- (void)client:(nw_connection_t)client didReceiveData:(NSData *)data
{
  @synchronized (self.listeningClients) {
    if ([self.listeningClients containsObject:client] || [self.rejectedClients containsObject:client]) {
      return;
    }
  }

  NSString *password = self.authPassword;
  if (password.length > 0) {
    NSString *requestHead = nil;
    BOOL isOverHeadCap = NO;
    @synchronized (self.listeningClients) {
      NSMutableData *buffer = [self.pendingRequestBuffers objectForKey:client];
      if (nil == buffer) {
        buffer = [NSMutableData data];
        [self.pendingRequestBuffers setObject:buffer forKey:client];
      }
      [buffer appendData:data];
      NSData *headTerminator = (NSData * _Nonnull)[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
      NSRange headEnd = [buffer rangeOfData:headTerminator options:(NSDataSearchOptions)0 range:NSMakeRange(0, buffer.length)];
      if (NSNotFound != headEnd.location) {
        NSData *headData = [buffer subdataWithRange:NSMakeRange(0, headEnd.location)];
        requestHead = [[NSString alloc] initWithData:headData encoding:NSUTF8StringEncoding] ?: @"";
        [self.pendingRequestBuffers removeObjectForKey:client];
      } else {
        isOverHeadCap = buffer.length > MAX_REQUEST_HEAD_SIZE;
      }
    }
    if (nil == requestHead && !isOverHeadCap) {
      // Wait for the rest of the request head.
      return;
    }
    if (nil == requestHead || !FBMjpegRequestHeadIsAuthorized(requestHead, (NSString * _Nonnull)password)) {
      [self rejectUnauthorizedClient:client];
      return;
    }
  }

  [FBLogger log:@"Starting screenshots broadcast for the client"];
  NSString *streamHeader = [NSString stringWithFormat:@"HTTP/1.0 200 OK\r\nServer: %@\r\nConnection: close\r\nMax-Age: 0\r\nExpires: 0\r\nCache-Control: no-cache, private\r\nPragma: no-cache\r\nContent-Type: multipart/x-mixed-replace; boundary=--BoundaryString\r\n\r\n", SERVER_NAME];
  [self.socket writeData:(id)[streamHeader dataUsingEncoding:NSUTF8StringEncoding] toClient:client];
  @synchronized (self.listeningClients) {
    [self.listeningClients addObject:client];
  }
}

- (void)rejectUnauthorizedClient:(nw_connection_t)client
{
  [FBLogger log:@"Rejected a screenshots broadcast client without valid credentials"];
  @synchronized (self.listeningClients) {
    [self.pendingRequestBuffers removeObjectForKey:client];
    [self.rejectedClients addObject:client];
  }
  NSString *response = [NSString stringWithFormat:@"HTTP/1.0 401 Unauthorized\r\nServer: %@\r\nWWW-Authenticate: Basic realm=\"WebDriverAgent\", charset=\"UTF-8\"\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", SERVER_NAME];
  [self.socket writeData:(id)[response dataUsingEncoding:NSUTF8StringEncoding] toClient:client completion:^(BOOL didSucceed) {
    nw_connection_cancel(client);
  }];
}

- (void)didClientDisconnect:(nw_connection_t)client
{
  @synchronized (self.listeningClients) {
    [self.listeningClients removeObject:client];
    [self.pendingFrameCounts removeObjectForKey:client];
    [self.pendingRequestBuffers removeObjectForKey:client];
    [self.rejectedClients removeObject:client];
  }
  // Nothing is owed to a client that stopped listening, so its socket can go right away.
  nw_connection_cancel(client);
  [FBLogger log:@"Disconnected a client from screenshots broadcast"];
}

- (void)stopStreaming
{
  self.isStreaming = NO;
  @synchronized (self.listeningClients) {
    NSArray<nw_connection_t> *clients = self.listeningClients.copy;
    [self.listeningClients removeAllObjects];
    [self.pendingFrameCounts removeAllObjects];
    [self.pendingRequestBuffers removeAllObjects];
    [self.rejectedClients removeAllObjects];
    for (nw_connection_t client in clients) {
      nw_connection_cancel(client);
    }
  }
}

- (void)dealloc
{
  [self stopStreaming];
  [FBLogger verboseLog:@"FBMjpegServer deallocated"];
}

@end

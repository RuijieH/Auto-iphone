# WebDriverAgent 鉴权与监听地址

本仓库 `WebDriverAgent/` 基于 appium/WebDriverAgent **v16.15.3**，在此基础上增加了：

- **密码鉴权**：覆盖 HTTP API（默认 8100）和 MJPEG 视频流（默认 9100）两个端口
- **监听地址**：沿用上游已有的 `USE_IP` 环境变量，并新增 `--bind-address` 进程参数

不设置密码、不设置监听地址时，行为与上游完全一致。

## 配置项

| 配置 | 环境变量 | 进程参数（优先级更高） | 默认值 |
|---|---|---|---|
| 密码 | `WDA_AUTH_PASSWORD` | `--auth-password <pwd>` | 不设置，即不鉴权 |
| 监听地址 | `USE_IP` | `--bind-address <ip>` | 不设置，即监听所有网卡 |
| HTTP 端口 | `USE_PORT` | `--port <n>` | 8100 起 |
| MJPEG 端口 | `MJPEG_SERVER_PORT` | `--mjpeg-server-port <n>` | 9100 |

- 监听地址同时作用于 HTTP 和 MJPEG 两个端口。
- **建议使用环境变量传入密码**：进程参数可能出现在 xctestrun 文件或宿主机的进程列表里。
- 密码请用随机生成的长字符串，例如 `openssl rand -hex 24`。服务端**没有做失败次数限制**，弱密码可能被暴力破解。

## 客户端如何携带密码

HTTP API 支持以下两种方式，任选其一：

```bash
# Bearer（推荐）
curl -H "Authorization: Bearer $WDA_AUTH_PASSWORD" http://127.0.0.1:8100/status

# Basic：用户名任意，只校验密码
curl -u "any:$WDA_AUTH_PASSWORD" http://127.0.0.1:8100/status
```

- 未携带密码或密码错误时，返回 `401 Unauthorized`（带 `WWW-Authenticate: Basic realm="WebDriverAgent"`），服务端随即**关闭连接，不读取请求体，也不会执行任何路由**。
- `OPTIONS` 请求（CORS 预检）不需要密码：浏览器发预检时不会附带凭据。这个路由本身只返回一个 ping。
- `/status`、`/health` 同样需要密码。

MJPEG 视频流除了支持上述 `Authorization` 头，还支持查询参数，方便在网页 `<img>` 标签中使用：

```html
<img src="http://127.0.0.1:9100/?token=YOUR_PASSWORD">
```

> ⚠️ 查询参数可能被浏览器历史记录或日志记下来。只在本机或受信任的面板里使用；请求头里带了 `Authorization` 时，以请求头为准。

## 启动方式

### xcodebuild

在环境变量名前加上 `TEST_RUNNER_` 前缀，xcodebuild 会去掉前缀，再把变量传给设备上的测试 Runner：

```bash
export TEST_RUNNER_WDA_AUTH_PASSWORD="$(openssl rand -hex 24)"
export TEST_RUNNER_USE_IP=127.0.0.1
export TEST_RUNNER_USE_PORT=8100

xcodebuild test-without-building \
  -project WebDriverAgent/WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination "id=$UDID"
```

### xctestrun 文件 / devicectl / go-ios

把同样的变量写入 xctestrun 文件中 `TestingEnvironmentVariables`（或 `EnvironmentVariables`）字段，或者通过对应工具的环境变量参数传入：`WDA_AUTH_PASSWORD`、`USE_IP`。

## 监听地址怎么选

| 场景 | 建议 |
|---|---|
| Mac 通过 USB 端口转发（`iproxy` / usbmux）访问 | `USE_IP=127.0.0.1` + 密码。usbmux 转发的连接从设备本机回环地址进入，局域网完全访问不到（**待实机确认**） |
| 通过 Wi-Fi 访问 | 设为手机的局域网 IP 或不设置，**必须设置密码**；流量是明文 HTTP，只在可信网络中使用 |
| iOS 17+ 的 CoreDevice / RemoteXPC 隧道（`devicectl`、pymobiledevice3 tunnel） | 连接可能从隧道网卡（IPv6）进入，绑定 `127.0.0.1` 可能导致无法访问。建议先不设置监听地址，只用密码，**实机验证后再收紧** |

如果既没有设置密码、又在监听所有网卡，WDA 启动日志会打印一条 WARNING。

## 局限

- **传输不加密**：使用 HTTP 明文，密码可以被同网段的人嗅探。远程访问请走 USB、SSH 隧道或 Tailscale 等加密通道。
- **没有失败次数限制和锁定机制**。
- Appium xcuitest-driver 不会自动携带这个密码。和 Appium 一起使用时，不要设置 `WDA_AUTH_PASSWORD`，或者自行修改 driver。

## 修改的文件

- `WebDriverAgentLib/Utilities/FBConfiguration.{h,m}`：新增 `authPassword` 配置，`bindingIPAddress` 支持 `--bind-address` 参数
- `WebDriverAgentLib/Routing/FBHTTPServer.{h,m}`：新增鉴权检查（在解析请求头之后、读取请求体之前执行），以及常量时间的密码比较函数 `FBHTTPAuthorizationMatchesPassword`
- `WebDriverAgentLib/Utilities/FBMjpegServer.{h,m}`：视频流连接先校验请求头，通过后才开始推流
- `WebDriverAgentLib/Routing/FBWebServer.m`：把配置注入两个服务；CORS 允许 `Authorization` 请求头；启动时打印鉴权状态或告警
- `WebDriverAgentTests/UnitTests/FBHTTPServerTests.m`、`FBConfigurationTests.m`：新增单元测试

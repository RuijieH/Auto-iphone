# 基于 WDA 远控 iPhone + 在 iPhone 上部署 Agent Harness：市场竞争力与技术可行性调研

> 调研日期：2026-10-24
> 说明：文中的 "WDA" 指 WebDriverAgent（Appium 维护的 iOS XCTest 自动化服务）。标注「推断」的结论来自对公开资料的综合判断，未经实机验证。

---

## 1. 结论速览

| 维度 | 判断 |
|---|---|
| **技术可行性（有宿主机）** | ✅ 成熟可行。Mac/Linux 宿主机 + WDA + 云端多模态大模型，社区已有多个可运行的开源实现。 |
| **技术可行性（纯 iPhone 端、无电脑）** | ⚠️ 只能部分做到。WDA 的启动和保活要依赖宿主机通过 testmanagerd 拉起的 XCTest 会话；iOS 17+ 上有报告称宿主机断开后 WDA 会随之退出。iPhone 上的 App 可以通过 `127.0.0.1:8100` 调用 WDA，但普通 App 切到后台会被挂起，无法持续驱动其他 App。 |
| **分发** | ❌ 无法上架 App Store，也不能走 TestFlight（XCTest Runner 不属于可分发产物，且违反 2.5.2 条款）。只能由用户自签、企业 / MDM 部署，或在欧盟走替代应用市场（还需公证）。 |
| **C 端市场** | 偏弱。部署门槛高（需要 Mac、开发者证书、开发者模式），而且苹果 Siri AI（iOS 27）正在官方补齐「屏幕感知 + 跨 App 操作」。 |
| **差异化窗口** | **中国大陆**：苹果新版 Siri AI 在大陆暂不可用，iPhone 用户没有系统级 Agent，存在空白。**开发者 / B 端**：iOS 自动化测试、只有 iOS 端的业务 RPA、为 Claude Code / Codex 提供 MCP 手机工具，这些需求明确。 |
| **最大风险** | ① 苹果政策随时可以收紧（iOS 26 已新增 “Enable UI Automation” 开关）；② App 平台主动封锁（豆包手机助手被拒绝操作的应用已达 166 款）；③ WDA 本身没有鉴权，存在安全风险。 |

**一句话建议**：不要把它做成面向大众的「iPhone 版豆包手机」，而是定位为 **“iOS 真机 Agent 基础设施”**。具体做法是宿主盒子（Mac mini / Linux 小主机）+ WDA + 安全网关 + 流程录制回放，先切开发者、QA 和企业 RPA 市场。iPhone 端只做轻量控制台和审批入口，不承担主循环。

---

## 2. 技术可行性

### 2.1 WDA 工作原理与前置条件

- WDA 本质上是一个 **XCTest UI Testing Runner**（`WebDriverAgentRunner-Runner.app`）。它在手机上启动 HTTP 服务（默认端口 8100），通过 XCUITest 私有能力完成截图、读取无障碍树、点击、滑动、输入等操作。
- 前置条件：
  - **代码签名**：需要开发者证书。免费 Apple ID 的描述文件约 7 天过期，需要每周重签；付费开发者账号有效期 1 年；企业证书用于分发给外部用户属于违规，证书可能被吊销。
  - **手机端设置**：开启开发者模式，信任开发者证书；iOS 26 起还要开启 `设置 > 开发者 > Enable UI Automation`（来源：koprjaa/iphone-agent README）。
  - **启动方式**：通过 `xcodebuild test-without-building`、`devicectl`，或第三方工具 go-ios、pymobiledevice3、tidevice3。iOS 17+ 改用 RemoteXPC / lockdown 隧道，pymobiledevice3 从 iOS 17.4 起支持全平台（含 Linux）建立隧道。**但 WDA 的 IPA 仍然至少要在一台 Mac 上构建一次**。
- **能力边界**：
  - 截图（相对稳定）
  - 无障碍树 `/source`：复杂页面可能要数秒
  - MJPEG 推流：社区实测约 10 fps
  - 点击 / 滑动 / 输入：中文通过 `typeText` 输入可行
  - 做不到的：锁屏、Face ID / 密码输入、部分系统弹窗。对禁止截图的页面（安全输入框、部分金融 App），截图会是黑屏或只能拿到线框。

### 2.2 四种部署架构对比

| 架构 | 描述 | 可行性 | 主要问题 |
|---|---|---|---|
| **A. 宿主机 Harness** | Agent 循环跑在 Mac / Linux 主机上，经 USB 或 Wi-Fi 调用 WDA | ✅ 已被多个开源项目验证 | 用户需要一台常开的主机 |
| **B. iPhone 普通 App 内 Harness** | 手机上的 App 通过 `http://127.0.0.1:8100` 调用本机 WDA | ⚠️ 前台可用，后台不行 | Harness App 在前台时，目标 App 无法同时在前台；切到后台几秒内就会被挂起。用音频 / 定位等后台模式保活违反审核规则，而且不稳定 |
| **C. Harness 内嵌在 WDA Runner 进程** | 把 Agent 循环（调用 LLM、规划、执行）直接编译进 XCTest Runner | ⚠️ 技术上最接近「部署在 iPhone 上」 | XCTest 会话运行时进程不会被挂起，可以持续驱动任意 App；但会话仍然要由宿主机拉起，断连后有退出风险（iOS 17+ 有报告）。UI 交互需要另做一个配套 App 或通知 / 网页面板（推断） |
| **D. 云端 Harness + 隧道** | Harness 跑在云端，经安全隧道连接家里或机房的「主机 + iPhone」 | ✅ 可行 | 同样需要宿主机；还要做好鉴权和加密，不能把 8100 端口直接暴露到公网 |

**推荐组合：A/D 作为主执行路径，C 作为进阶优化，B 只用作轻量控制台。** 所谓「部署在 iPhone 上」，可以理解为把 Harness 逻辑放在 Runner 进程里（C），但不能指望完全脱离宿主机。

### 2.3 模型侧

- **端侧模型**：Apple Foundation Models 框架提供约 3B 的端侧模型，适合意图解析、摘要这类文本任务，不足以完成多步 GUI 规划与视觉定位。
- **云端模型**：GUI Agent 主循环仍需调用云端多模态大模型（Claude / GPT / Gemini computer use，或专用模型 UI-TARS、AutoGLM、UI-Voyager 等）。Gemini 3.5 Flash 的 computer use 已明确覆盖移动端屏幕。
- **效果参考**：AndroidWorld 已接近饱和（头部自报成绩超过 90%），更难的 MobileWorld 上最佳框架约 51.7%。**iOS 目前没有公认的 benchmark**，需要自建评测集，这也可以作为技术壁垒。
- **单步延迟（推断）**：截图或读取无障碍树 0.3–3 秒，加上模型推理 1–5 秒，单步约 2–8 秒，一个 10 步的任务约需 0.5–1.5 分钟。降本提速的手段：**流程录制回放**（iphone-use 已实现）、优先使用无障碍树而非纯视觉、优先调用 URL Scheme / App Intents / 快捷指令，GUI 操作只作兜底。

### 2.4 安全与合规

- **WDA 自身没有鉴权**：任何能访问 8100 端口的人都能完全控制手机，社区项目都在 README 中警告这一点。产品化必须加一层网关，提供 token 鉴权、只监听 USB / 本机、操作审计，以及对支付等敏感操作的二次确认。
- **苹果条款**：属于开发者调试能力的「非预期用途」。规模化商用（尤其是群控）存在被苹果收紧接口或吊销证书的风险。
- **国内监管**：面向公众提供 AI 智能体服务需要完成算法备案和大模型备案 / 登记。操作他人 App 涉及《个人信息保护法》以及各 App 用户协议中禁止自动化操作的条款。群控、刷量类用途属于灰色或违法地带，**应明确不做**。

---

## 3. 市场竞争格局

### 3.1 直接竞品（WDA / iPhone 方向）

| 产品 | 形态 | 要点 |
|---|---|---|
| **iphone-use**（开源，MIT，Product Hunt 有上架） | Mac + USB + 自研 XCTest Runner；21 个 MCP 工具；支持流程录制回放；可用浏览器或 iOS App 远程控制 | 与本方向最接近，已经验证开发者需求；用户质疑其控制端点的安全性 |
| **koprjaa/iphone-agent** | Mac + WDA + Python 客户端 + 网页实时画面 | 作者明确提到「iPhone 镜像在欧盟锁区」，替代镜像是一个真实需求 |
| **Mobster / Mobster for Mac** | WDA 驱动的 Agent 循环，自带 benchmark 和 eval | 已开始商业化（Mac 端产品） |
| **Phone Harness** | 不用 WDA，通过 macOS「iPhone 镜像」窗口做桥接 | 免签名，但受地区和镜像功能限制 |
| **GeoLibra/PhoneAgent、Open-AutoGLM、ai-phone** | AutoGLM + XCUITest，支持 iOS / Android / 鸿蒙 | 国内开源社区活跃，同质化明显 |
| **WDA-Runner 等国内工具** | 预签名安装包 + 图形界面，主打免越狱电脑控制 iPhone | 面向测试和群控用户，合规性存疑 |
| **测试云**（BrowserStack、Sauce Labs、AWS Device Farm 等） | 基于 WDA / XCUITest 的真机云 | B 端测试市场的成熟玩家，正在加入 AI 能力 |

### 3.2 间接竞品 / 替代方案

- **苹果 Siri AI（iOS 27）**：屏幕感知、跨 App 操作、App Intents / App Schemas 生态。2026 年 6 月开放开发者测试，首发仅支持英文，欧盟 iOS 暂缓，**中国大陆暂不可用**（苹果称仍在处理监管要求）。中长期看，这是 C 端最大的挤压来源。
- **Android 系统级 Agent**：豆包手机助手（努比亚 NaviX Ultra，2026 年 9 月发售）、阶跃 STEPX Neo / Amoo、华为小艺、荣耀、OPPO 小布等。它们拥有系统权限，体验上限远高于 iOS 上的 WDA 方案，但同样面临 App 平台封锁：豆包手机助手被拒绝操作的应用已达 166 款，覆盖腾讯系约 66 款、阿里系约 23 款，以及美团、快手等。
- **云端 Agent / 大厂 computer use**：OpenAI Codex Background Computer Use、Anthropic computer use、Gemini computer use，以及 Meta Muse、OpenAI Dots 等常驻型 Agent。目前都没有官方的 iPhone 操控产品，但模型能力已经具备。

### 3.3 竞争力评估（SWOT）

- **优势**：
  - 免越狱，可以操作任意第三方 App，不依赖 App 是否适配 App Intents。
  - 可以接入任意大模型，模型选择不受锁定。
  - 在大陆 iPhone 用户群体中暂时没有官方替代。
- **劣势**：
  - 部署门槛高：需要 Mac 构建、签名、开启开发者模式，还要常开宿主机。
  - 延迟高（每步数秒）。
  - 无法上架 App Store，获客渠道受限。
  - 开源同类项目多，技术壁垒低。
- **机会**：
  - **开发者工具**：给 Claude Code / Codex / Cursor 提供 iPhone 真机 MCP，用于 iOS App 开发自测和 E2E 测试。
  - **企业 RPA**：只有 iOS 端的业务流程，如门店、客服、内容审核。
  - **无障碍辅助**。
  - **硬件捆绑**：预装好的「Agent 盒子」，即插即用。
  - **自建 iOS Agent benchmark 和数据集**。
- **威胁**：
  - 苹果在 iOS 27 / 28 进一步收紧 UI Automation，或推出官方 Agent 后封堵第三方路径。
  - 微信、支付宝等平台的风控识别和封号。
  - Siri AI 在大陆落地后，C 端窗口关闭。
  - 安全事故引发信任危机。

---

## 4. 建议路线

1. **MVP（1–2 个月）**
   - 架构 A：Mac / Linux 宿主机 + WDA。
   - 鉴权网关：USB 优先，Wi-Fi 必须带 token 和 TLS。
   - MCP Server，支持接入 Claude Code 等客户端。
   - 流程录制回放。
   - 中文 App 适配：输入法、弹窗处理、无障碍树缺失时回退到视觉定位。
2. **差异化**
   - 自建 iOS 任务评测集（不少于 100 个中文真实任务），持续公布成功率。
   - 能力优先级：URL Scheme / 快捷指令 / App Intents → 无障碍树 → 视觉，降低延迟和成本。
   - 敏感操作（支付、转账、发消息）强制在 iPhone 端人工确认，并保留审计日志。
3. **进阶验证（技术预研）**
   - 架构 C：把 Harness 内嵌进 Runner 进程，实测 iOS 26 / 27 上 Wi-Fi 断开、锁屏、长时运行时 WDA 的存活情况，判断「准端侧」部署能否成立。
   - 评估 go-ios / pymobiledevice3 在 Linux 小主机上的稳定性，用于降低硬件成本。
4. **商业化优先级**：开发者 / QA（订阅制）> 企业 RPA（私有化部署）> C 端（谨慎，等待验证）。**明确不做群控、刷量**。

---

## 5. 待实机验证的问题

- [ ] iOS 26 / 27 上 `Enable UI Automation` 开关的行为，以及是否有更多限制。
- [ ] 宿主机断开后，WDA / Runner 进程能存活多久，在 USB 和 Wi-Fi 两种情况下分别测试。
- [ ] 手机端 App 通过 `127.0.0.1:8100` 调用 WDA，在前台和后台切换时的实际表现。
- [ ] 微信、支付宝、淘宝等 App 对 XCTest 自动化是否有检测或风控。
- [ ] 典型中文任务的单步延迟和端到端成功率。

---

## 参考来源

- [koprjaa/iphone-agent (GitHub)](https://github.com/koprjaa/iphone-agent)
- [iphone-use (Product Hunt)](https://www.producthunt.com/products/iphone-use)
- [iPhone-use 静态工程评测（掘金）](https://juejin.cn/post/7697181229842382890)
- [Your AI Agent Can Now Control an iPhone Without Jailbreaking It (Medium)](https://medium.com/coding-nexus/your-ai-agent-can-now-control-an-iphone-without-jailbreaking-it-d88360b2d374)
- [GitHub Topic: phone-use-agent](https://github.com/topics/phone-use-agent)
- [Apple Newsroom: Apple introduces Siri AI (2026-06)](https://www.apple.com/newsroom/2026/06/apple-introduces-siri-ai-a-profoundly-more-capable-and-personal-assistant/)
- [WWDC26: Explore advanced App Intents features](https://developer.apple.com/videos/play/wwdc2026/343/)
- [WWDC26: Build intelligent Siri experiences with App Schemas](https://developer.apple.com/videos/play/wwdc2026/240/)
- [虎嗅：豆包手机助手拒绝操作应用清单增至166款](https://www.huxiu.com/article/4899633.html)
- [腾讯新闻：AI手机进入系统级Agent时代](https://news.qq.com/rain/a/20260915A0CSPN00)
- [网易：WAIC 2026手机观察](https://www.163.com/dy/article/L25KPC1R051100B9.html)
- [Appium: Manage WebDriverAgent by Yourself](https://appium.github.io/appium-xcuitest-driver/6.2/guides/wda-custom-server/)
- [Appium Discuss: Unable to launch WDA manually on iOS 17](https://discuss.appium.io/t/unable-to-launch-ios-webdriver-agent-manually-on-ios-17-x-devices/41492)
- [pymobiledevice3 (PyPI)](https://pypi.org/project/pymobiledevice3/4.14.18)
- [go-ios](https://github.com/projectxyzio/go-ios)
- [tidevice3](https://github.com/codeskyblue/tidevice3)
- [MobileWorld / AndroidWorld 基准（benchmarklist）](https://benchmarklist.com/benchmarks/mobileworld/)
- [Gemini 3.5 Flash computer use (mlq.ai)](https://mlq.ai/news/google-adds-computer-use-to-gemini-35-flash-matching-anthropic-and-openai-on-agentic-desktop-control/)
- [MediaNama: App Review Guideline 2.5.2](https://www.medianama.com/2026/04/223-apple-vibe-coding-app-ban-anythng/)
- [阿里云：AI智能体备案全流程](https://developer.aliyun.com/article/1749932)

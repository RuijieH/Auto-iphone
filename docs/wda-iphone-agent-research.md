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

## 6. 补充评估：Harness 固定放在 Mac + 自进化 Skill（2026-10-24 追加）

> ⚠️ 本节中「Skill 命中后不调用大模型、直接回放」的设计已在第 9 节修正为**所有 Skill 都由 Agent 驱动执行**，以第 9 节为准。

### 6.1 方案定义

- **执行环境**：Harness 常驻在 Mac 上（Mac mini 或用户自己的 Mac），通过 USB 或局域网驱动 WDA。iPhone 只负责被控、人工审批和接收通知。
- **自进化 Skill**：Agent 第一次用大模型完成一个任务后，把成功的轨迹「编译」成一个参数化的 Skill。之后同类任务直接回放这个 Skill，不再每一步都调用大模型。回放失败时，再由大模型修复 Skill 并生成新版本。

### 6.2 Skill 的建议结构

参考学术界 EvoSkill-GUI 的多文件 Skill 包设计，以及 Qodex / Shiplight 在 Web 测试中「缓存 + 自愈」的做法，每个 Skill 包含以下部分：

| 组成 | 内容 | 作用 |
|---|---|---|
| 检索元数据 | 意图描述、示例指令、适用的 App 及版本范围 | 新任务进来时匹配已有 Skill |
| 参数槽 | 联系人、金额、文本、日期等 | 一个 Skill 可以覆盖一类任务 |
| 快捷路径 | URL Scheme、Universal Link、快捷指令、App Intents | 最快的执行方式，可以跳过多步导航 |
| 步骤序列 | 每一步的定位方式按优先级排列：无障碍标识 → 文本或谓词 → 图像模板 → 相对坐标 | 不调用大模型、不做视觉推理就能执行 |
| 每步后置断言 | 期望出现的元素或页面特征 | 及时发现偏离，避免「盲点」 |
| 失败恢复规则 | 常见弹窗、登录态失效、网络错误的处理方式 | 减少回退到大模型的次数 |
| 版本与统计 | 成功率、平均耗时、最近失败案例 | 决定 Skill 是否启用、降级或淘汰 |

Skill 的生命周期：大模型首次完成任务 → 生成候选 Skill → 在 Mac 侧用参数变体回放 N 次，全部通过断言后转为正式 Skill → 线上命中时直接回放 → 断言失败时由大模型从失败点接管并完成任务，同时修订 Skill 生成新版本 → 连续失败的 Skill 自动降级。

### 6.3 能把速度提升多少（推断）

| 场景 | 纯大模型逐步决策 | Skill 回放 |
|---|---|---|
| 单步耗时 | 2–8 秒（截图或读取无障碍树 + 模型推理） | 0.3–1 秒（WDA 操作 + 轻量断言） |
| 10 步任务 | 约 0.5–1.5 分钟 | 约 5–15 秒；有快捷路径时可能 3 秒以内 |
| 单次任务的 token 成本 | 高（每一步都带截图） | 接近 0，只有检索和参数抽取需要一次小模型调用 |

- 收益只出现在**重复性任务**上。第一次执行、长尾任务、开放式任务仍然要走大模型，依旧慢。
- 学术证据（EvoSkill-GUI，2026）：Skill 演化把 Claude-Sonnet-4.6 在 MobileWorld 上的成功率从 57.1% 提升到 67.6%，大约 3 轮演化后趋于饱和。论文只报告了成功率，**没有报告提速数据**，提速幅度需要自己实测。
- Mac 侧可以利用的额外能力：Apple Vision 的端侧 OCR 速度快，可以做断言；MLX 可以运行本地小模型，承担检索、参数抽取和断言判断，进一步减少云端调用。

### 6.4 竞争力重新评估

| 维度 | 原方案（纯大模型 GUI Agent） | Mac Harness + 自进化 Skill | 变化 |
|---|---|---|---|
| 执行速度 | 慢（每步数秒） | 高频任务提速约 5–10 倍（推断） | ⬆️ 显著提升 |
| 单次成本 | 高 | 高频任务接近 0 | ⬆️ 显著提升，订阅制毛利可行 |
| 稳定性 | 有随机性 | 回放过程可确定，加断言后可审计 | ⬆️ 对企业更友好 |
| 部署门槛 | 需要 Mac + 签名 | 不变，需要常开的 Mac | ➖ 没有改善 |
| 分发 / 平台封锁 | 无法上 App Store，App 平台可能封锁 | 不变；回放的操作节奏更像脚本，**可能更容易被风控识别** | ➖ 甚至略差 |
| 技术壁垒 | 低（开源同质化严重） | 中。Skill 库和 iOS 中文 App 的适配数据会持续积累 | ⬆️ 提升 |
| 对比 Siri AI | 覆盖面广但慢 | 覆盖没有 App Intents 的 App、速度接近、大陆可用 | ⬆️ 差异化更清晰 |

### 6.5 竞品是否已经在做

- **iphone-use**：已经支持「完成一次的任务保存为流程，之后不调用模型直接回放」。这说明录制回放本身不是壁垒，它缺少的是自动泛化、参数化、断言和自愈。
- **Web / 移动测试工具**：Qodex、Shiplight 已经在用「大模型解析一次 → 缓存操作 → 失败时再交给大模型修复」的模式；BrowserStack、Panto 在 Appium 上做定位器自愈。这个模式在测试领域已被验证，但都面向 QA，不面向个人或业务 Agent。
- **学术界**：EvoSkill-GUI、KnowAct-GUIClaw（Skill / 快捷路径库 + deeplink 跳过导航）、BlueLM-GUI（vivo 真机数据飞轮）都在 Android 上做，**iOS 上暂时没有看到对应工作**。
- **结论**：「iOS 真机 + 自进化 Skill + 中文 App」这个交叉点目前是空白，但单项技术都不难复制，窗口期估计在 6–12 个月（推断）。

### 6.6 壁垒该放在哪里

1. **Skill 质量和覆盖面，而不是 Skill 机制本身**：针对高频中文 App（微信、支付宝、美团、淘宝、钉钉、飞书等）的 Skill 库和版本适配数据才是护城河。
2. **共享 Skill 市场（需谨慎）**：用户之间共享去标识化的 Skill，可以形成网络效应。但要防范 Skill 投毒（例如恶意篡改的转账流程），必须做签名、审核和沙箱回放验证。
3. **iOS 专属加速路径库**：系统性收集各 App 的 URL Scheme、Universal Link 和 App Intents，把它们作为 Skill 的第一优先路径，这部分别人很难短期复制。
4. **把可靠性做成可量化的指标**：公开 Skill 的成功率、耗时和失败自愈率，作为对企业客户的服务承诺（SLA）。

### 6.7 新增风险

- **App 更新导致 Skill 失效**：A/B 测试、灰度发布、深色模式、字号设置都会改变界面。需要做好断言和降级处理，并在后台持续巡检回放。
- **回放出错的代价更高**：没有大模型实时判断时，可能「快速做错事」。涉及支付、发送消息、删除的步骤，必须在执行前强制人工确认，后置断言失败要立即中止。
- **风控**：固定的节奏和坐标更容易被识别为脚本。需要合理的操作间隔，并保持在用户本人账号、本人授权的使用范围内，**不做规避检测的设计**。
- **隐私**：Skill 和轨迹中可能包含联系人、地址等个人信息，默认只存本地 Mac；如果要上传，必须先脱敏并取得用户授权。

### 6.8 结论

加入自进化 Skill 后，产品从「慢但通用的 iPhone Agent」变成了 **“越用越快的 iPhone 自动化工作站”**，竞争力明显提升，尤其适合以下场景：

- **个人效率**：每天重复的固定操作，如打卡、报销、订餐、查询账单。
- **企业 RPA**：只有 iOS 端的业务流程，高频且固定。
- **开发者 / QA**：「一次描述，之后低成本回归」的 iOS E2E 测试。

但它**解决不了部署门槛和平台封锁这两个结构性问题**。因此建议：

- 定位为「Mac + iPhone 的个人或团队自动化工作站」，面向已有 Mac 的专业用户和企业，而不是大众 C 端。
- 核心指标设为 **Skill 命中率**（不调用大模型完成的任务占比）和 **端到端耗时**，MVP 阶段目标设为命中率超过 60%、命中任务 P50 耗时低于 10 秒（目标值，需要验证）。
- 第一批 Skill 覆盖 20–30 个高频中文场景，在冷启动阶段就展示「第二次明显更快」的体验。

### 6.9 补充参考

- [EvoSkill-GUI: Reflect, Revise, Reuse — Training-Free Skill Evolution for GUI Agents (arXiv 2609.17653)](https://arxiv.org/html/2609.17653v1)
- [KnowAct-GUIClaw: Self-Evolving Memory and Skill (arXiv 2607.12625)](https://arxiv.org/html/2607.12625v2)
- [BlueLM-GUI Technical Report (arXiv 2609.12394)](https://arxiv.org/pdf/2609.12394)
- [What Memory Do GUI Agents Really Need? (arXiv 2606.31612)](https://arxiv.org/pdf/2606.31612)
- [Qodex: UI testing replay cache](https://qodex.ai/docs/ui-testing-replay-cache)
- [Self-Healing Test Automation for Mobile Apps (Autosana)](https://blog.autosana.ai/blog/self-healing-test-automation-mobile)
- [Panto: Self-Healing](https://www.getpanto.ai/products/self-healing)

---

## 7. Mac 端 Harness 技术选型建议（2026-10-24 追加）

### 7.1 总体架构：快路径与慢路径分离（已被第 9 节修正）

```
用户指令
  └─ Skill 检索（本地向量 / 关键词匹配 + Haiku 抽取参数）
       ├─ 命中 → 【快路径】确定性回放引擎 ──→ WDA（HTTP，USB）
       │             每步做断言，失败则转入慢路径
       └─ 未命中 → 【慢路径】LLM Agent 循环 ──→ 同一套 iPhone 工具
                      成功后 → Skill 编译器（子 Agent）→ 生成或修订 Skill
```

- **快路径必须自己实现，不依赖任何 Agent 框架。** 它就是一个执行 Skill JSON 的状态机，延迟和成本都由我们自己控制。
- **慢路径可以使用现成的 Agent Harness。**

### 7.2 慢路径框架选型

| 方案 | 适合程度 | 理由 |
|---|---|---|
| **Claude Agent SDK**（TS / Python，即 Claude Code 封装成的库） | ⭐ MVP 首选 | 自带 Skills 机制（`SKILL.md` 文件，Agent 可以自己写新 Skill，天然契合「自进化」）；hooks 可以对支付、发送等敏感工具调用做拦截审批；原生支持 MCP；有子 Agent，可以专门承担 Skill 编译和修复；自带会话和上下文管理 |
| **Messages API + Tool Runner**（`anthropic` SDK 自建循环） | ⭐ 产品化阶段 | 对每一步的控制最细：模型路由（规划用 `claude-opus-5-5`，参数抽取和断言用 `claude-haiku-5-5`）、提示缓存、截图历史裁剪。等体验和成本需要精细优化时，再从 Agent SDK 迁移过来 |
| **Managed Agents** | ❌ 不适合做主循环 | 循环和沙箱都在 Anthropic 云端，无法直接访问 Mac 上通过 USB 连接的 iPhone，每一步都要多一次往返。可以考虑用于离线的 Skill 巡检和回归（定时任务） |
| LangGraph / OpenAI Agents SDK 等 | 可选 | 适合需要多家模型混用的场景；没有现成的 Skill 文件机制 |

- **不要直接使用 computer use 工具。** 它面向桌面坐标系，而且 Opus 5.5 只能通过 `computer_toolset_20260801` 使用。iPhone 应该定义一组**自定义工具**：`screenshot`、`ui_tree`、`tap(by=id|text|xy)`、`swipe`、`type_text`、`open_url`、`home`、`app_launch`，并对参数开启 `strict: true`。
- **把这组工具同时封装成 MCP Server。** 这样内部 Agent 可以使用，也可以直接提供给 Claude Code / Cursor 用户，覆盖「开发者工具」这条商业线。

### 7.3 其余组件

| 层 | 建议 | 说明 |
|---|---|---|
| 语言 | **TypeScript（Node）** 作为主进程；外壳用 **Swift** 写菜单栏 App | Agent SDK、MCP、Midscene 生态都以 TS 为主；Swift 负责系统权限、Vision OCR 和开机自启 |
| WDA 客户端 | 直接调用 WDA 的 HTTP API（轻量封装） | 不建议引入 Appium（太重）；Python 栈可以用 `facebook-wda` |
| 设备管理 | `xcodebuild test-without-building` / `xcrun devicectl` | 运行在 Mac 上就直接使用苹果官方工具链，比 go-ios / pymobiledevice3 更稳定；需要做好 WDA 保活和自动重启 |
| 视觉断言 | Apple Vision OCR（端侧，快） | 用于快路径的每步断言 |
| 本地小模型（可选） | MLX | 离线完成检索和意图匹配，进一步降低成本 |
| Skill 存储 | 文件（`SKILL.md` + `steps.json`）+ SQLite 记录统计和版本 | 文件格式与 Agent SDK 的 Skills 兼容，便于 Agent 读写 |
| 安全 | WDA 只监听 USB 转发端口；本地网关使用 token；敏感操作由 hook 拦截，推送到 iPhone 确认 | — |

### 7.4 电脑端任务可视化

目标：用户在 Mac 上能实时看到手机画面、Agent 正在执行的步骤和原因，并能随时暂停、接管或审批。

**界面布局（单窗口，三栏）**

| 区域 | 内容 |
|---|---|
| 左：实时手机画面 | 30–60 fps 镜像；叠加 Agent 即将点击的位置（高亮框 / 点击涟漪）、当前定位到的元素框 |
| 中：任务时间线 | 每步一张卡片：缩略截图、动作（如 tap “发送”）、路径标记（⚡ Skill 回放 / 🧠 LLM 推理）、断言结果 ✅ / ❌、耗时；LLM 步骤展示思考摘要 |
| 右：控制与状态 | 当前任务和命中的 Skill（版本、历史成功率）；累计耗时和 token 花费；按钮：暂停 / 继续 / 接管（人工直接在画面上点击）/ 终止；敏感操作的审批弹窗 |
| 附加页 | 历史任务回放（逐步截图 + 动作重放，类似 Midscene 的 HTML 报告）；Skill 库管理（成功率、最近失败、手动编辑 / 停用） |

**实现要点**

- **实时画面**：不要使用 WDA 的 MJPEG（约 10 fps，而且会占用 WDA 资源）。Mac 可以通过 **CoreMediaIO / AVFoundation 直接采集 USB 连接的 iPhone 屏幕**（QuickTime 录屏同样的机制），流畅且延迟低。WDA 截图只用于给模型看和做断言。
- **事件总线**：Harness 的每个动作都发出结构化事件，例如 `task_started`、`step_planned`、`action_executed`、`screenshot`、`assertion`、`skill_hit`、`approval_required`、`task_done`。
  - 事件通过 WebSocket 推送给 UI，同时写入 SQLite，供历史回放和 Skill 统计复用。
- **LLM 推理过程可视化**：开启 `thinking.display: "summarized"`（或 `"updates"`，用于工具调用之间的进度说明），把摘要展示在时间线卡片里，让用户知道「它为什么点这里」。
- **人工接管**：用户在实时画面上的点击，通过 WDA 转发到手机，并被记录为一次「人工步骤」，可以作为 Skill 修复的示范数据（这也是一个自进化的数据来源）。
- **UI 技术选型**：
  - Node 主进程内置 HTTP / WebSocket 服务，前端使用 React Web UI。
  - 外壳二选一：**Swift 菜单栏 App + WKWebView**（最轻，同时负责屏幕采集、Vision OCR 和系统通知），或 **Electron**（与 Node 主进程同栈，开发最快，但体积大）。MVP 推荐 Electron 先跑通，再根据体验需要换成 Swift 外壳。
  - 因为 UI 是 Web 实现，同一套界面还可以在局域网内用 iPhone 或 iPad 浏览器打开查看，但必须带鉴权。

### 7.5 可参考或可直接复用的开源项目

- **Midscene.js**（字节开源）：已经通过 WDA（≥ 7.0.0）支持 iOS 真机，提供 AI 驱动的操作和断言、HTML 回放报告，以及脚本缓存（缓存在 iOS 上的效果待验证）。可以作为慢路径执行层的候选，也是需要关注的竞品。
- **iphone-use**：MCP 工具设计和流程回放可以参考。
- **koprjaa/iphone-agent / phone-harness**：WDA 保活脚本和实时画面查看器可以参考。

### 7.6 结论

- **MVP**：TS 主进程 + Claude Agent SDK 跑慢路径 + 自研快路径回放引擎 + iPhone 工具 MCP Server + 任务可视化面板（Electron / React，实时画面通过 CoreMediaIO 采集，事件总线基于 WebSocket + SQLite）。
- **规模化之后**：慢路径迁移到 Messages API 自建循环，做模型分级路由和提示缓存，进一步压低延迟和成本。

- 参考：[Midscene iOS 集成文档](https://midscenejs.com/integrate-with-ios)、[Midscene iOS 介绍](https://midscenejs.com/ios-introduction)、[Midscene changelog](https://midscenejs.com/changelog)

---

## 8. 论文调研：Mobile Agent Harness 的特殊性，以及能否复用 Claude Code / pi（2026-10-24 追加）

### 8.1 关键论文要点

| 论文 | 核心结论 | 对本项目的启示 |
|---|---|---|
| **Beyond the GUI Paradigm**（arXiv 2606.19388，2026-06） | 不做任何移动端专门训练，直接用**通用编程 Agent**（Claude Code、mini-swe-agent、Terminus-2）通过 adb shell 操作 Android：Claude Code（Opus 4.7）在 AndroidWorld 上达到 71.8%、MobileWorld 上达到 51.9%，超过所有可复现的 GUI 专用模型（GUI-Owl-1.5-32B 分别为 69.3% / 43.2%）。在跨 App 任务上，GUI Agent 的成功率不超过 11%，CLI Agent 平均步数约为 GUI 的一半（10.7 vs 18.6）。 | ① **通用编程 Harness 可以直接迁移到手机场景**，关键在于系统提示词和工具层，而不是专门的模型。② 但它的优势依赖 **adb shell + 模拟器 root 权限可以直接读取 App 数据库**，这一点 **iOS 完全不具备**（见 8.3）。 |
| **PhoneHarness**（arXiv 2606.14832） | 采用 GUI、CLI、宿主机工具混合的动作空间，按「确定性路径优先，GUI 兜底」的原则选择执行方式；按需加载 Skill；对敏感任务分为 SAFE_COMPLETE / CONFIRM_FIRST / NEVER_AUTO 三级。总成功率 75.0%，对比 AutoGLM-Phone 的 37.1%；纯 GUI 的单 App 长流程仍然是最主要的失败来源。 | 架构几乎就是我们「Mac 宿主机 + 手机」方案的 Android 版本，验证了**混合动作空间**和**分级审批**的设计。 |
| **Mobile-Agent-v3 / GUI-Owl**（arXiv 2508.15144） | 多角色框架：Manager 负责规划，Worker 负责执行，Reflector 负责反思，Notetaker 负责记录。AndroidWorld 成绩 73.3%。 | **Notetaker（跨 App 的记事本）**正好对应 GUI Agent 在跨 App 任务上成功率不超过 11% 的短板 |
| **AppAgentX**（arXiv 2503.02268） | 从执行历史中挖掘重复的动作序列，进化出高层「快捷动作」；第三方摘要称耗时和 token 最多可降低 47%（未核实原文）。 | 直接支持第 6 节的自进化 Skill 方案 |
| **EvoSkill-GUI / KnowAct-GUIClaw**（2026） | 无需训练的 Skill 包进化；Skill / 快捷路径库 + deeplink 跳过导航 | 同上 |

### 8.2 Mobile Harness 相比编程 / 电脑 Harness 的特殊性

| # | 特殊性 | 编程 Harness（Claude Code / pi）的默认行为 | 手机场景需要的处理 |
|---|---|---|---|
| 1 | **观测以截图为主，token 很重** | 工具结果全部保留在上下文中 | 只保留最近 1–3 张截图，更早的替换为文字摘要；优先使用无障碍树或 OCR 文本（可以借助 context editing 的 `clear_tool_uses`） |
| 2 | **动作是异步的** | 工具返回即表示完成 | 每次动作后要等待界面稳定（动画、加载完成），再做后置验证 |
| 3 | **环境中断多** | 文件系统是确定的 | 弹窗、广告、权限请求、通知、登录失效都需要一个中断处理器，最好用规则处理，不消耗大模型 |
| 4 | **坐标定位** | 不存在 | 截图像素和 iOS point 坐标之间的换算；优先使用元素 ID，其次用 Set-of-Marks 编号，最后才用坐标 |
| 5 | **典型失败模式不同**（Beyond-GUI 的错误分析） | 编程 Agent 的典型失败是推理与动作不一致、验证不足 | GUI 的典型失败是**重复同一步骤**和**过早结束**，需要循环检测器和完成度验证器 |
| 6 | **跨 App 状态** | 状态都在文件里 | 需要 Notetaker / 工作记忆，把 A App 里看到的信息结构化记录下来，供 B App 使用 |
| 7 | **不可逆的真实副作用** | 权限按工具划分（bash、写文件） | 权限要按**语义动作**划分（付款、发消息、删除），采用三级审批（参考 PhoneHarness） |
| 8 | **人工接管** | 很少需要 | 登录、验证码、Face ID 等环节必须交给用户，完成后 Agent 再接着执行 |
| 9 | **延迟敏感** | 每一步都可以深度思考 | 常规步骤用低 effort 或小模型，重复任务走 Skill 快路径（第 6 节） |
| 10 | **设备层故障** | 不存在 | WDA 崩溃需要自动重启，USB 断开要能重连，任务要能断点续跑 |

### 8.3 iOS 相比 Android 论文结论的关键差异

- **iOS 没有 shell，也没有办法读取 App 数据**：Beyond-GUI 和 PhoneHarness 的大部分收益来自 adb shell、读取数据库和 content provider，这些在 iPhone 上都不存在。**iOS 的 Agent 更依赖 GUI**，因此 Skill 快路径和 GUI 稳定性的工程价值反而更高。
- **在 Mac 上构建「iOS 版 CLI 层」（差异化机会）**：
  - **iCloud 同步数据**：通讯录、日历、提醒事项、备忘录、照片，可以在 Mac 上通过 EventKit / AppleScript / Photos 框架直接读写；短信和 iMessage 可以读取 Mac 上的 `chat.db`，也可以通过 Messages.app 发送。很多「查询、汇总、跨 App」类任务因此**不需要操作手机界面**。
  - **快捷指令**：通过 WDA 打开 `shortcuts://run-shortcut?name=...` 来触发 iPhone 上的快捷指令，复用 App Intents 的能力。
  - **URL Scheme / Universal Link**：直达 App 的深层页面。
  - **设备管理**：`devicectl` 和 pymobiledevice3 可以完成 App 列表查询、启动 App、读取日志和设备信息，相当于 iOS 上的 `dumpsys`。
- **推荐的路由顺序**：Mac 侧数据或快捷路径（确定性）→ Skill 回放 → 无障碍树驱动的 GUI 操作 → 视觉 GUI 操作。

### 8.4 能否直接复用 Claude Code / Agent SDK / pi

**结论：Harness 的骨架可以复用，而且论文已经证明这么做有效；移动端运行时层必须自己写。**

| 选项 | 可复用的部分 | 不足 | 适用场景 |
|---|---|---|---|
| **Claude Code CLI 原样使用 + iPhone MCP** | 开箱即用，适合开发者用户 | 系统提示词面向编程；截图会持续累积在上下文中；权限审批按工具而不是按语义动作；不方便嵌入成产品 | 原型验证；「开发者工具」产品线（卖 MCP） |
| **Claude Agent SDK** | 与 Claude Code 是同一套循环；可以自定义系统提示词；有 hooks（等待稳定、验证、审批）、Skills、子 Agent（Notetaker / Reflector / Skill 编译器）、会话管理 | 只能使用 Claude 模型；**Claude API 在中国大陆不可用**，面向国内的产品存在合规和可用性问题 | 海外市场的产品主路径 |
| **pi（pi-mono）** | 核心极简（4 个工具 + 很短的系统提示词），提示词完全可控；用 TS 扩展机制添加手机工具和运行时；`pi-ai` 支持**多家模型**，可以接豆包 Seed、Qwen、GLM / AutoGLM 等国内模型，或「Claude 规划 + GUI 专用模型做视觉定位」的组合 | MCP、子 Agent、权限审批都需要靠扩展自己补；工程量比 Agent SDK 大 | **国内市场或需要多模型的场景**；希望完全掌控 Harness 的场景 |
| 自研循环（Messages API 等） | 控制最细 | 工程量最大 | 规模化之后 |

### 8.5 推荐架构（修正第 7 节）

```
┌ 规划层（复用）：Claude Agent SDK【海外】或 pi【国内 / 多模型】
│   系统提示词：移动端四阶段循环（发现 → 检查 → 执行 → 验证），参考 Beyond-GUI 附录 A.1
│   子 Agent：Notetaker（跨 App 记忆）、Reflector（失败反思）、Skill 编译器
│
├ 移动运行时层（自研，以 MCP Server 或 pi 扩展的形式提供）
│   路由器：Mac 侧数据 / 快捷路径 → Skill 回放 → 无障碍树 GUI → 视觉 GUI
│   截图上下文管理器（只保留最近 N 张，其余转为摘要）
│   动作执行器（等待稳定 + 后置断言）、中断处理器（弹窗 / 广告 / 权限）
│   循环检测与完成度验证、语义动作三级审批、人工接管
│   Mac 侧 iOS 数据工具：EventKit / Contacts / Photos / chat.db / 快捷指令
│
└ 设备层：WDA（xcodebuild 保活）+ CoreMediaIO 实时画面 + 事件总线 → 可视化面板
```

### 8.6 补充参考

- [Beyond the GUI Paradigm: Do Mobile Agents Need the Phone Screen? (arXiv 2606.19388)](https://arxiv.org/pdf/2606.19388)
- [PhoneHarness: Mixed GUI, CLI, and Tool Actions (arXiv 2606.14832)](https://arxiv.org/html/2606.14832)
- [Mobile-Agent-v3 / GUI-Owl (arXiv 2508.15144)](https://arxiv.org/abs/2508.15144)
- [AppAgentX (arXiv 2503.02268)](https://arxiv.org/html/2503.02268v3)
- [Dive into Claude Code: Design Space of AI Agent Systems (arXiv 2604.14228)](https://arxiv.org/html/2604.14228v3)
- [ShawnPana/phone-harness](https://github.com/ShawnPana/phone-harness)
- [Pi (pi.dev) 介绍](https://agentic-ai.readthedocs.io/en/latest/AgentHarness/pi-dev/)
- [The irrational effectiveness of the Pi harness](https://rednafi.com/misc/pi-harness/)

---

## 9. 设计修正：所有 Skill 都由 Agent 驱动（2026-10-24 追加）

**原因**：确定性回放不够鲁棒（App 改版、弹窗、A/B 测试都会让它失效），而用户的任务每次也不会完全一样。因此取消「命中 Skill 就不调用大模型、直接回放」的快路径，**Agent 始终在循环里**。这与论文中的做法一致：EvoSkill-GUI 的 Skill 由 Agent 检索后参考执行，AppAgentX 的快捷动作由 LLM 自主选择调用，PhoneHarness 采用「按需加载 Skill」。

### 9.1 Skill 的新定位：给 Agent 的知识和宏工具，而不是脚本

| 组成 | 形式 | Agent 如何使用 |
|---|---|---|
| **路线知识** | `SKILL.md`：目标页面路径、关键元素的特征、常见坑（弹窗、二次确认）、完成标志 | 检索命中后注入上下文，Agent 不再需要从零摸索 |
| **快捷入口** | URL Scheme、快捷指令、Mac 侧数据接口 | 由 Agent 决定是否使用，失败时 Agent 换路 |
| **宏工具（可选）** | 例如 `wechat.open_chat(name)`：内部连续执行多步并逐步断言，返回结构化结果和截图 | 由 Agent 调用和验证，出错时返回失败点，由 Agent 接管；**一次 LLM 决策覆盖 N 步动作** |
| **经验统计** | 成功率、常见失败、最近一次可用的 App 版本 | 帮助 Agent 判断是否信任这条路线 |

**进化方式**：每次任务结束后，由 Skill 编译子 Agent 对比轨迹，把新的坑、新路径、失败案例写回 `SKILL.md`。重复出现的稳定子序列沉淀为宏工具，对应 AppAgentX 的做法。

### 9.2 速度从哪里来（替代回放）

| 手段 | 作用 |
|---|---|
| 路线知识消除探索 | 步数减少，论文中探索、重复步骤和过早结束是主要失败与浪费来源 |
| 宏工具 | 多个动作只需一次 LLM 决策 |
| 有 Skill 时降档 | 用低 effort 或更快、更便宜的模型执行（例如 Haiku 级别或国内的轻量模型），没有 Skill 时再用强模型规划 |
| 观测轻量化 | 优先使用无障碍树或 OCR 文本，只在必要时发截图；只保留最近 N 张截图 |
| 提示缓存 | 系统提示词、工具定义、Skill 内容放在固定前缀，便于命中缓存 |

**预期（推断）**：重复类任务比无 Skill 时快约 2–3 倍，低于纯回放的 5–10 倍，但鲁棒性和泛化能力明显更好，用户感知也更一致。可视化面板上的路径标记相应改为「🧠 有 Skill 指导 / 🧭 自由探索」，并单独标出宏工具调用。

### 9.3 对竞争力评估的影响

- **鲁棒性和泛化**：Skill 从「脚本」变成「经验」，可以覆盖相似但不完全相同的任务，体验更好。
- **成本和速度优势**：从「接近 0」变为「明显降低」，订阅定价需要按 token 用量测算。
- **壁垒不变**：仍然是高频中文 App 的 Skill 知识库、宏工具库和 iOS 快捷路径库，这些反而更容易跨版本复用。
- **核心指标调整**：从「Skill 命中率」改为 **「有 Skill 指导时的平均步数、单任务耗时和成本」**，以及**成功率提升幅度**。

---

## 10. 哪个 Harness 最适合「套壳 + 魔改界面」（2026-10-24 追加）

套壳的关键是三点：**内核能否无界面运行（headless）、是否以结构化事件流对外暴露、能否在进程内注入自定义工具**。另外要满足本项目的两个硬约束：支持多家模型（国内市场），以及能完全控制系统提示词（移动端四阶段循环）。

| Harness | 嵌入方式 | 界面魔改自由度 | 多模型 | 许可证 | 评价 |
|---|---|---|---|---|---|
| **pi**（pi-mono） | **进程内 SDK**：`createAgentSession()` + `session.subscribe(event)`；也可以用 `pi --mode rpc`（stdin/stdout JSONL） | ⭐⭐⭐⭐⭐ 完全没有界面包袱，事件粒度细（如 `message_update` / `text_delta`） | ✅ `pi-ai` 支持多家模型 | MIT（2026-04 被 Earendil 收购，npm scope 已变为 `@earendil-works`，使用前确认） | **首选**：内核极简，提示词完全可控，iPhone 工具通过 TS 扩展在进程内注入，最适合做成自己的 Electron 或 Web 界面 |
| **OpenCode** | `opencode serve`：HTTP 服务 + OpenAPI 3.1 自动生成 SDK + SSE 事件流；官方 TUI、桌面端、Web 端都只是它的客户端 | ⭐⭐⭐⭐ 可以 fork 现成的 Web 或桌面客户端，再在此基础上改 | ✅ | MIT | **想要一个现成界面起步时的首选**：客户端和服务端分离最彻底；但内置了较多编程相关的默认设定，需要逐项关闭或替换 |
| **Goose** | Rust 核心 + 官方桌面端；支持「自定义发行版」（预置模型、扩展和品牌）；MCP 扩展可以在桌面端渲染交互式界面 | ⭐⭐⭐ 换品牌、改配置容易，但深度修改界面和循环需要动 Rust 和桌面端代码 | ✅ | Apache-2.0（Linux 基金会 AAIF 托管） | 适合「快速出一个带品牌的桌面 App」，深度定制成本高 |
| **Codex app-server** | JSON-RPC 2.0（stdio），官方的 CLI、VS Code 插件、桌面端都基于这套协议 | ⭐⭐⭐⭐ 协议成熟 | ⚠️ 主要面向 OpenAI 模型 | Apache-2.0 | 协议设计值得参考；核心是 Rust，而且偏向 OpenAI 生态 |
| **Claude Agent SDK** | 进程内 `query()` 返回消息流，界面完全自己写 | ⭐⭐⭐⭐ | ❌ 只支持 Claude | Anthropic 商业条款 | 只做海外市场时可选；Claude Code 本身闭源，**无法修改它的界面** |

### 推荐方案

- **主选 pi SDK + 自研 Electron / React 界面**：
  - Node 主进程中运行 `AgentSession`，事件经过转换后，与第 7.4 节的事件总线合并：pi 的事件，加上移动运行时层的 `action_executed` / `assertion` / `screenshot`，一起通过 WebSocket 推送到前端，并写入 SQLite。
  - iPhone 工具、截图上下文管理、等待稳定、审批拦截，都以 pi 扩展的形式在进程内实现。
  - 默认接国内模型，海外版本切换到 Claude，都通过 `pi-ai` 配置完成，只需维护一套代码。
- **备选 OpenCode**：如果希望第一周就有一个能用的聊天和会话管理界面，可以 fork 它的 Web 客户端，再加上手机画面和时间线面板。
- **两者都要注意**：内核是开源社区项目，迭代很快。建议**锁定版本**，并通过一层适配层（自定义的 `AgentEvent` 类型）把内核和界面解耦，以后更换内核时不用改界面。

### 补充参考

- [pi RPC Mode 文档](https://pi.dev/docs/latest/rpc)
- [pi SDK 文档](https://pidocs.seepine.com/en/sdk)
- [OpenCode Server 文档](https://www.mintlify.com/anomalyco/opencode/server)
- [Unlocking the Codex harness（OpenAI）](https://openai.com/index/unlocking-the-codex-harness)
- [Codex App Server 自定义客户端](https://codex.danielvaughan.com/2026/04/21/codex-app-server-architecture-custom-client-integrations/)
- [goose docs](https://goose-docs.ai/)
- [Goose review](https://www.promptquorum.com/power-local-llm/goose-review)

---

## 11. 把 Agent Harness 写进 WDA 是否可行（2026-10-26 追加）

**结论：技术上能跑通，但投入产出比低，不建议把整个 Harness 放进 WDA。** 推荐的折中方案是把**移动运行时层中对延迟敏感的部分**下沉到 WDA，作为自定义接口；LLM 循环仍然留在 Mac 上。

### 11.1 能做到的部分

- **进程不会被挂起**：XCTest Runner 在测试会话期间一直运行，可以持续驱动任意前台 App，避开了普通 App 切到后台就被挂起的问题（第 2.2 节架构 C）。
- **可以联网**：Runner 进程里可以用 URLSession 调用云端 LLM API。
- **进程内操作更快**：截图、无障碍快照、元素查询都直接调用 XCUITest，省去 HTTP 和 USB 这一跳，每步约节省几十到两百毫秒（推断）。
- **WDA 本身支持扩展**：可以在 fork 中通过 `FBCommandHandler` 注册自定义路由（这是社区常见的做法）。

### 11.2 关键障碍

| 障碍 | 影响 |
|---|---|
| **生命周期仍然依赖宿主机** | Runner 必须由 Mac 通过 testmanagerd（`xcodebuild` / `devicectl` / go-ios）拉起；有人实测发现每次启动都需要 Mac 处于唤醒状态、需要人工执行命令，从启动到服务可用约 90 秒；iOS 17+ 还有宿主机断开后 WDA 跟着退出的报告。**「脱离 Mac 自主运行」这个最大的潜在收益实际上拿不到** |
| **无法复用现成的 Harness** | iOS 上不能运行 Node，pi、Claude Agent SDK、OpenCode 都无法使用；只能**用 Swift 重写**循环、工具调用、上下文管理、Skill 加载、子 Agent 等全部逻辑，与第 10 节的「套壳」路线冲突 |
| **私有 API 不断被移除** | iOS 27 移除了 WDA 依赖的私有方法（`FBTestmanagerdVersion`、等待界面稳定的 `fb_waitUntilStableWithTimeout:`），需要打补丁才能继续运行。Harness 和 WDA 绑得越深，每次 iOS 升级的维护成本越高 |
| **延迟收益有限** | 单步耗时的大头是 LLM 推理（1–5 秒），进程内节省的几十到两百毫秒只是零头 |
| **开发和调试效率低** | 每改一次都要重新编译、签名、安装 Runner，无法像 Mac 上的 Node 那样热更新；日志和可视化都要额外回传 |
| **会丢掉 Mac 侧的能力** | 第 8.3 节的 iCloud 数据、`chat.db`、EventKit 等「iOS 版 CLI」工具都在 Mac 上，Harness 放到手机上后需要反向调用 Mac |
| **交互和安全** | Runner 本身没有可用的界面，用户输入要靠配套 App 或 Mac；API Key 存放在手机上；WDA 端口依然没有鉴权，需要自己加 |
| **会话期间手机被占用** | 自动化运行时屏幕被接管，手机无法正常使用，建议使用专用设备 |
| **其他约束** | 锁屏后 UI 操作会失败，需要保持屏幕常亮（待验证）；Runner 有内存上限；签名证书会过期（免费账号 7 天，付费账号 1 年） |

### 11.3 推荐的折中方案：WDA 只做「快执行层」

```
Mac：LLM 循环（pi / Agent SDK）+ Skill 库 + Mac 侧数据工具 + 可视化面板
   │  一次 LLM 决策 → 一个高层调用
   ▼  （USB 转发，带 token 鉴权）
WDA fork 中的自定义接口（Swift，进程内执行）：
   /agent/observe       压缩后的无障碍树 + OCR 文本 + 可选截图（一次返回）
   /agent/act           执行动作 → 等待界面稳定 → 后置断言 → 返回界面变化摘要
   /agent/macro         执行宏工具（多步 + 逐步断言），失败时返回失败点
   /agent/interrupts    规则化处理弹窗、权限请求、广告
```

- **收益**：一次 HTTP 往返完成「动作 + 等待 + 验证 + 观测」，减少 LLM 轮次和网络往返；宏工具在手机端以最低延迟执行。
- **Mac 侧的 Harness 保持不变**：可以继续套壳 pi 或 Agent SDK，界面魔改不受影响。
- **控制 WDA fork 的范围**：只做加法，即新增路由，**不改动核心代码**，以降低每次 iOS 升级时的合并成本。

### 11.4 如果仍然想验证「Harness 全部放在手机上」，需要先实测的问题

- [ ] 用 `devicectl` 或 `xcodebuild` 拉起后拔掉 USB，Wi-Fi 配对的 Mac 合盖或睡眠时，Runner 能存活多久（iOS 26 / 27 分别测）。
- [ ] 锁屏、来电、低电量模式下 Runner 的表现。
- [ ] Runner 进程内调用 Foundation Models（端侧模型）是否可行。
- [ ] Runner 连续运行 8 小时的内存和稳定性。

### 11.5 补充参考

- [My AI Agent Drove My iPhone for a Day. Then I Parked It.（DEV，iOS 27 实测）](https://dev.to/honeykiran/my-ai-agent-drove-my-iphone-for-a-day-then-i-parked-it-5901)
- [appium-xcuitest-driver issue #2978（iOS 26 / 18 上 WDA 约 20 秒后退出）](https://github.com/appium/appium-xcuitest-driver/issues/2978)
- [go-ios issue #391（runwda 与 testmanagerd）](https://github.com/danielpaulus/go-ios/issues/391)
- [mobilecli issue #487（Wi-Fi 真机 Runner）](https://github.com/mobile-next/mobilecli/issues/487)
- [WebDriverAgent - The Heart of iOS E2E Testing](https://trinhngocthuyen.com/posts/tech/mobile-e2e-wda/)

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

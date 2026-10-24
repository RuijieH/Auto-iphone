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

### 7.1 总体架构：快路径与慢路径分离

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

### 7.4 可参考或可直接复用的开源项目

- **Midscene.js**（字节开源）：已经通过 WDA（≥ 7.0.0）支持 iOS 真机，提供 AI 驱动的操作和断言、HTML 回放报告，以及脚本缓存（缓存在 iOS 上的效果待验证）。可以作为慢路径执行层的候选，也是需要关注的竞品。
- **iphone-use**：MCP 工具设计和流程回放可以参考。
- **koprjaa/iphone-agent / phone-harness**：WDA 保活脚本和实时画面查看器可以参考。

### 7.5 结论

- **MVP**：TS 主进程 + Claude Agent SDK 跑慢路径 + 自研快路径回放引擎 + iPhone 工具 MCP Server + Swift 菜单栏外壳。
- **规模化之后**：慢路径迁移到 Messages API 自建循环，做模型分级路由和提示缓存，进一步压低延迟和成本。

- 参考：[Midscene iOS 集成文档](https://midscenejs.com/integrate-with-ios)、[Midscene iOS 介绍](https://midscenejs.com/ios-introduction)、[Midscene changelog](https://midscenejs.com/changelog)

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

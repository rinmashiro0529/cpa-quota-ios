# 原生前端实现与审阅指南

本次实现基于 main 的 d6d18dce184b8b611c831a0c065ca1365ea0392b。目标是保留羊皮纸 / 曜石 / 赤陶色彩与衬线标题、等宽数据的视觉语言，并将表现层迁移到系统导航、控件和真正的 WidgetKit / ActivityKit。

## 实际代码边界

| 区域 | 本次实现 | 保留的合同 |
| --- | --- | --- |
| 应用外壳 | 原生 TabView，5 个独立 NavigationStack，统一 Sheet 所有权，安全深链 | 原有 5 工作区；切换已接受的 CPA 连接、CAP 权限模式时清理旧来源详情 |
| 额度 | 自适应 List、原生筛选 Menu、账号详情 Form、逐账号刷新、状态与旧数据提示 | CPAClient / CPAQuotaStore、限流、并发、配额解析、真实零值、未知值与超额语义 |
| 账号诊断 | 原生分区列表、准确的读取能力、账户及上游失败诊断 | 未把非 Codex 提供方一律判为不可读取；保留插件能力与被动快照 |
| CAP 用量 | 4 个栏目与完整钻取、真实时间桶散点及等价数据表、稳定分页、派生缓存 | 总览、initial、groups、costs、requests、管理 stats；原查询窗口、未知失败状态、缺失定价、严格加权 TPS |
| 连接与设置 | 原生 Form / SecureField / Picker / Toggle / 确认对话框 | HTTPS 规范化、连接验证后提交、Keychain、记住/忘记、外观、邮箱脱敏、显示模式 |
| 监控 | 连接、账号范围、有限时长、状态、恢复、诊断子页 | v1 平面协议、UUID 幂等、revision CAS、sequence、新鲜度、取消回执、原始 bridge / credential binding |
| 系统实时活动 | 真正 ActivityConfiguration / DynamicIsland 的各布局；应用级恢复、授权及内容观察、显式本机结束、孤儿活动处置 | 系统决定呈现；HTTP 接受、远端取消、APNs 送达和本机结束分别显示 |
| 普通小组件 | 可配置安全别名的 Widget，small / medium / large 与锁屏 rectangular / circular | 只读已共享快照、不访问 Keychain、不执行网络、不承诺实时刷新 |

后端服务代码、API 路由与核心业务解析没有被本次前端替换重写。新增 CPAQuotaUITestFixtures.swift 由 #if DEBUG 包围，只提供 UI 测试使用的本机协议响应；Release 不包含该实现。

## 导航与恢复

CPAQuotaiOSApp 为正常运行持有唯一 Session，并在各 Window 中复用。CPAQuotaRootView 负责 Tab、每个工作区的路径和 Sheet；页面自己拥有 List、Form 或 ScrollView，不再被一个全局 ScrollView 包裹。

TabView 的位置由系统决定；iPhone Duo 的本次模拟器运行呈现为侧边导航栏。UI 回归按 5 个实际按钮、选中状态和目标工作区验证，不限定底部 TabBar 的内部层级，也不强制覆盖系统 size class。

Root 将当前 Dynamic Type 环境显式传递到连接与账号详情 Sheet；不限制字号范围。测试会比较普通字号与 accessibility5 的实际详情邮箱行高度，防止只有底层页面放大而弹层仍保留普通字号。

应用启动合并重复恢复请求，同时恢复 CPA 与独立监控桥接；进入前台重新检查活动权限、现存系统活动和当前远端会话。监控页没有恢复专用的 .task，用户无需先打开该页才能恢复系统活动。

深链仅接受 cpaquota://quotas 与经严格解析的 cpaquota://monitor?source=...。来源别名不会被当作全局唯一身份。只有当前桥接与凭据绑定下唯一匹配的已知记录可以定位；歧义、未知来源或进行中的启动意图不会被 URL 覆盖，也不会自动发起注册。

旧 DynamicIslandCompanionBar 与 FloatingGlassTabBar 已删除。ConnectionStatusPresentation 是普通连接状态数据；为现有调用者保留的 deprecated DynamicIslandState / dynamicIslandState 仅为数据适配接口，不渲染任何假灵动岛，也不请求系统活动。

## 色彩、排版与 Liquid Glass

BrandPalette 保留原始 RGB 值，例如：

| Token | 浅色 | 深色 |
| --- | --- | --- |
| canvasBase | RGB 0.980 / 0.973 / 0.957 | RGB 0.075 / 0.071 / 0.067 |
| textPrimary | RGB 0.094 / 0.090 / 0.082 | RGB 0.957 / 0.941 / 0.918 |
| accent | RGB 0.824 / 0.427 / 0.298 | RGB 0.886 / 0.502 / 0.376 |
| contentSurface | RGB 1.000 / 0.992 / 0.976 | RGB 0.145 / 0.137 / 0.125 |

标题采用系统衬线语义字体；数值采用系统等宽语义字体；不会把字体固定在某个 iPhone 的点数。数据行在可用宽度不足或辅助字号下改为纵向布局。

系统 Tab、导航栏、工具栏、Menu、Sheet 保持原生行为。iOS / macOS 26 及以上的主要与次要按钮使用 .glassProminent / .glass；相邻操作组使用 GlassEffectContainer。内容卡片使用不透明普通内容表面，没有以 blur、Material 或多层高光冒充 Liquid Glass。更早系统采用原生 bordered 控件；iOS 最低版本保持 17.0，macOS 包最低版本保持 14.0。

主要玻璃按钮使用原品牌深墨色作为 textOnAccent，保持赤陶底色原值，同时避免深色外观下白字与较亮赤陶底色的低对比。材质、按压和形变仍由系统 ButtonStyle 提供。

没有定时的装饰粒子或主动持续动画。Reduce Transparency、Reduce Motion 的系统控件行为由系统处理；信息本身用文字、图标和状态共同表达，不能仅靠颜色。配额进度仅在实际比例已知时使用 ProgressView，未知值不会补成 0。

## Live Activities 的业务与数据语义

只在用户主动关注一个有限监控区间时创建活动，支持现有 1 / 4 / 8 小时范围；日常静态配额查看使用 Dashboard 或普通 Widget。不会自动续期把配额常驻灵动岛。

- 来源及账号授权由原监控服务决定；CPA 账号列表仅是候选输入，手动账号标识入口仍保留。
- 服务 v1 没有指标发现 / 选择接口，因此前端不会构造并不存在的 API 或反解 safe_id。
- snapshot.expiresAt 表示读数新鲜度，不能充当远端 lease 的剩余时间。系统活动不显示伪造的 lease 倒计时。
- 202、首次采集尚未到达、旧数据、失效、限流、部分失败与终态分别处理。
- “仅停止本机实时活动显示”可独立结束 ActivityKit 显示；不会声称远端已取消。
- 远端取消必须有服务回执；离线、5xx 或未完成的取消不能伪装为已停止。
- 请求成功后进程崩溃但未保存本机活动 ID 的情况，通过系统活动清单提示用户处置；不会猜测来源并自动注册。
- Compact Leading、Compact Trailing、Minimal、Expanded 与 Lock Screen 都由 Widget extension 提供。iOS 27 限宽环境使用 isDynamicIslandLimitedInWidth；不硬编码岛的框架尺寸、顶部位置或遮挡范围。该新符号另以 compiler(>=6.4) 隔离，以便 Xcode 26.2 兼容构建。

## 小组件隐私与身份

“允许小组件显示配额”默认关闭。开启后，主应用仅写最多 64 个账号的主要读数，使用“账号 N”、允许列表内的提供方名称、规范化窗口说明和不透明 UUID。原账号 ID、auth_index、邮箱、显示名、服务地址、原始错误及管理密钥不写入共享快照。

本机私有映射绑定 sourceIdentifier 与 id / provider / authIndex。源和映射作为单个版本化值保存在主 App 私有 preferences，不能出现新映射配到旧来源。重启后用户配置的 UUID 保持稳定；换源、账号换绑或删除的已选项不会退回显示其他账号。

共享快照原子写入 group.icu.nahida.cpaquota。读数沿用真实 observedAt；被动数据没有观察时间时不会使用 fetchedAt 假装新鲜。默认 300 秒新鲜度与应用一致，本地时间线只把旧数据标旧，不制造新配额。失败刷新仍可保留原读数及明确失败状态。

关闭共享或忘记连接会清理共享快照。清理失败显示待重试提示，并在前台继续重试，旧数据不会因失败操作重新获得有效期。

## 工程、签名与兼容

- App bundle：icu.nahida.cpaquota。
- Extension bundle：icu.nahida.cpaquota.activity。
- App 与 Extension 都声明 App Group group.icu.nahida.cpaquota。
- App 继续声明 NSSupportsLiveActivities 与原 aps-environment。
- WidgetBundle 注册 Live Activity、普通 Widget 与对应 AppIntentsPackage。
- 保持 iPhone / iPad 与现有三个 iPhone 方向、四个 iPad 方向。
- 新增 CPAQuotaAppUITests 原生 UI 测试 Target，宿主为 CPAQuota App；所有新增 Swift Testing 文件也加入 native unit target。
- CI 的 unsigned build 验证编译、链接和 extension 嵌入，不能替代 Apple Developer 中 App Group / Push 的 capability 与 provisioning。正式安装包仍需用匹配该团队、App ID 和 App Group 的签名配置。

## 自动化验证入口

本地非 Apple 环境可运行：

~~~sh
python3 -I ci/validate_source_layout.py --root .
python3 -I ci/test_source_layout.py
python3 -I ci/test_activity_extension.py
git diff --check
~~~

Apple 环境可运行：

~~~sh
swift test --parallel
xcodebuild test -project Apple/CPAQuota.xcodeproj -scheme CPAQuota \
  -configuration Debug -destination 'platform=iOS Simulator,id=<实际设备UDID>' \
  -resultBundlePath /tmp/CPAQuota-NativeTests.xcresult \
  -parallel-testing-enabled NO \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
~~~

CI 同时编译 Xcode 26.2 与正式版 27.1，运行 SPM、native unit、XCUITest，再构建 unsigned Release。ci/select_simulator.py 会记录实际运行设备及系统版本，找不到目标 major 的模拟器就失败，不使用旧系统冒充通过。Apple 的 2026-10-15 发布记录和托管镜像清单确认 Xcode 27.1（27A9275）为当前稳定验收基线；开发期间使用的 27.2（27B48）仍是 Release Candidate，只作为额外兼容证据。日志记录真实 xcodebuild 版本、解析路径、SDK 与模拟器 runtime。

| CI 工具链 | Simulator 实际目的地 | 布局验证 |
| --- | --- | --- |
| Xcode 26.2 / iOS 26.2 SDK | iPhone 17 Pro / iOS 26.2 | 普通与最大辅助字号、真实宽屏旋转、Sheet 与设置操作可达 |
| Xcode 27.1 / iOS 27.1 SDK | iPhone 18 Pro / iOS 27.0 | 用最新稳定 SDK 编译，在镜像实际提供的标准 iPhone runtime 验证宽屏旋转 |
| Xcode 27.1 / iOS 27.1 SDK | iPhone Duo / iOS 27.1 | 系统侧栏、普通与最大辅助字号、设备旋转后实际窗口中的操作可达 |

CI 要求精确匹配表中的机型和 runtime，缺失就失败。Apple 明确说明 Duo 的方向不能推断 App 窗口形状，因此只对标准 iPhone 要求旋转后宽大于高；Duo 不把发送旋转命令算作宽屏已验证。该区别仅存在于测试策略，生产界面依赖实际布局与系统安全区域。Duo 开合、折叠、多窗口及连续改变窗口宽度仍需 Device Hub / 真机补充记录。策略通过官方 TEST_RUNNER_ 环境变量传入测试进程，未知策略失败；duo-adaptive 必须匹配已记录的 iPhone Duo 目的地。

主要新增验证包括：

- 启动恢复合并、未进入监控 Tab 即恢复独立桥接。
- 账户换绑 / 切源 / 重启时 Widget UUID 的安全性；授权默认关闭及撤回；被动未知时间、失败旧值、真实零值。
- 授权变化、本机结束与远端失败隔离、系统孤儿活动、歧义深链。
- CAP 旧连接迟到、缓存原始窗口、空页与溢出、缺桶 / nil / 0、来源分组及加权指标。
- Debug fixture 经真实客户端解码，验证 401 / 分页 / 缺失数值。
- 6 条 XCUITest：登录校验与鉴权、5 Tab 与详情、CAP 4 栏目、独立监控凭据、浅深色实际亮度、最大辅助字号在总览及详情的实际布局变化与旋转后动作可达。标准 iPhone 必须进入真实宽屏；Duo 按实际窗口形状验证，不伪称宽屏或全部折叠姿态已覆盖。
- UI 测试截图以 keepAlways 附件保存在 xcresult。若 GitHub artifact 存储配额阻止上传，CI 明确告警，并在日志中保留测试摘要及有总量上限的 JPEG 审阅副本（附原始 PNG 与副本 SHA256）；这不等于完整 xcresult 已归档。测试与构建步骤仍是阻断门槛，只有附件上传允许带告警继续。亮度和可达断言覆盖关键退化；完整逐像素视觉基线仍需设备审阅后批准，不能仅因生成截图就宣称视觉验收通过。

## 仍需签名设备完成的验收

如果附件上传因 GitHub 存储配额失败，可从对应 job 日志恢复带校验和的截图审阅副本：

~~~sh
gh run view <run-id> --job <job-id> --log > native-job.log
python3 -I ci/export_frontend_evidence.py --restore-log native-job.log --evidence ./review-previews
~~~

脚本只恢复该次日志中的实际截图副本，并校验长度、SHA256 和文件路径；不能恢复未上传的完整 xcresult。

以下项目必须保留独立记录，不与模拟器 / 合成测试合并为“已验证”：

1. 使用匹配的正式签名在 iOS 27 真实设备上安装与运行。
2. App Group 的签名授权、系统 Widget 编辑与选择、设备锁定时隐私显示。
3. 真实桥接 + APNs 的 token 轮换、后台更新、被系统结束 / 用户划掉、8 小时活动上限与锁屏残留。
4. 不支持 Dynamic Island 的机型、不同大小的岛、横屏及多活动竞争时 Compact / Minimal / Expanded 的实际呈现。
5. iOS 17 低版本实际运行、iPad / 新设备的完整截图、VoiceOver、Reduce Transparency、Reduce Motion 与 Increase Contrast。
6. 长列表、最大 CAP 数据量、弱网和长时间监控的 Instruments 性能记录。

## 回滚

本 PR 在独立分支上替换表现层，保留后端协议与核心业务测试。回滚整个 PR 即可恢复原界面，不需要数据库或后端协议迁移。新增 Widget 共享文件只含版本化安全快照；未开启时没有网络或授权副作用。撤回已经部署的新版本前，应先在新版本中停止仍在运行的真实监控活动，并撤回共享；不能把界面回滚当作远端取消。

## 官方参考

- [Apple：Xcode 27.1 正式版发布记录](https://developer.apple.com/news/releases/?id=10152026a)
- [Apple：为 iPhone Duo 准备应用与方向无关的布局](https://developer.apple.com/iphone-duo/prepare/)
- [Apple：Xcode 测试进程环境变量](https://developer.apple.com/documentation/xcode/environment-variable-reference)
- [Apple：Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Apple：GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer)
- [Apple：Displaying live data with Live Activities](https://developer.apple.com/documentation/ActivityKit/displaying-live-data-with-live-activities)
- [Apple：isDynamicIslandLimitedInWidth](https://developer.apple.com/documentation/swiftui/environmentvalues/isdynamicislandlimitedinwidth)
- [GitHub：Xcode 27 runner image 与实际预装版本](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)

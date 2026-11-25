# CPA Quota 集成修复验证

> **历史记录**：首次提交 2026-10-27（`3abffeb`）；本文可能包含后续补充，仅反映所述时期及版本，测试结果不代表当前提交。当前入口见 [README](../README.md)。

公开资料中的环境标识已泛化；历史日志、回执和归档仅存原验证环境，不保证读者可以下载。

历史记录说明：以下内容保留 2026-10-26 集成阶段的验证结果和当时的边界，不表示当前版本尚未完成后续原生 CI 或独立开发签名安装。后续原生工程位于 `Apple/CPAQuota.xcodeproj`，使用独立 Bundle ID `icu.nahida.cpaquota`；提交 `47890575edcf0d32ec078dc2a21e8376eb1d108e` 已由 [GitHub 原生 CI 40374759742](https://github.com/rinmashiro0529/cpa-quota-ios/actions/runs/40374759742) 使用 Xcode 26.2 / iOS SDK 26.2 验证。下文的旧 Bundle ID、SDK stamp、138 项 Linux 测试和未签名状态只对应当时 Linux 构建环境中的集成构建，不替代后续原生 CI 证据。原始详细日志与归档仅保留在本地，不随源码上传。

本记录对应原验证环境中的独立集成副本。原项目、云盘原 ZIP 和只读前端交付保持独立；本次不包含签名、安装、Git 提交推送或 Google Drive 回传。

## 原始交付与范围

| 项目 | 基线 |
| --- | --- |
| 前端原始 ZIP SHA256 | `e0a0a232a29ffc2c00d0d3e339957f33798b2b1654e7e850c674987ba04bb925` |
| 原交付 | 52 文件、37 Swift 文件；原测试 111 项、16 套件 |
| 后端原始 commit | `fd9c6c2f758656ace7c9606b750a79e6486368d9` |
| 保持不变 | 原 Kit、Probe 和后端测试 20 个 Swift 文件；6 个核心设计文件 |
| 授权范围 | 会话/凭据生命周期、真实状态展示、相关回归及当时 Linux 构建环境工具链的未签名 App 打包 |

三栏页面、根路由、悬浮导航、字体配色和深浅双模沿用原设计。核心设计文件为 `LiquidGlassDesignSystem.swift`、`AppearanceAndPreferences.swift`、`CPAQuotaRootView.swift`、`FloatingGlassTabBar.swift`、`LoginOnboardingView.swift` 和 `AccountDetailSheetView.swift`。状态伴生栏是应用内 SwiftUI 组件，不是系统 Live Activity/ActivityKit。

## 修复内容与行为合同

| 范围 | 本次行为 |
| --- | --- |
| 连接验证与取消 | 未完成管理验证不保存新密钥；旧连接/恢复任务不能发布新状态；显式取消和调用方取消都需要检查归属 |
| 凭据存储 | 私有协调器串行化系统写删，以版本和完整事务前基线处理迟到操作；不因 actor 可重入而并发补偿 |
| 保存失败 | B 自身保存失败时保留 A 的保存地址和原凭据；B 可以作为明确告知存储错误的临时会话 |
| 清理失败 | B 保存成功、仅旧 A 删除失败时，保留已确认 B 并显示清理错误；不能把保存失败和清理失败混为一谈 |
| 忘记与不记住 | 删除失败显式报告且保留可定位配置；成功后才清保存元数据；无需先 restore 即可忘记已有配置 |
| 保存地址观察 | `savedServer` 是可观察、只读公开状态；偏好和状态统一更新，冷启动直接忘记也会通知界面 |
| 冷恢复 | 401/403 回到未配置并保留凭据供修正/忘记；network/timeout 可保留已知路由以便重试，但错误和连接异常必须可见 |
| 状态展示 | 全局错误不再显示连接就绪；诊断不以“没有能力警告”冒充健康；空列表区分未完成、失败和成功空列表 |
| 额度展示 | 真正存在 snapshot 才提示保留历史快照；显示 unavailable/停用和原始服务状态；卡片新鲜度每 15 秒按时间重算，不触发网络重试 |
| 进度 | 清单阶段不编造百分比，0/N 为 0；只计本轮可观察的 snapshot/error 变化，文案为“已更新”，不承诺逐请求精确完成计数 |
| 数值 | 普通百分比不变；合法极大 usedFraction 用科学计数，避免 Double 转 Int 越界崩溃，不显示成零或无限 |
| 打包 | App 使用 automatic library 产品及普通 target，由 `xtool.yml` 指定；保留 Kit/UI 产品；最低系统 iOS 17 |

原生测试在 Linux 上使用确定性网络和凭据存储替身，不触碰真实管理密钥或系统 Keychain。已批准的公开测试边界是 Session 操作/可观察状态、CredentialStore 的 load/save/remove，以及展示值；不测试私有协调器方法，不以 sleep 猜调度。

## 红绿证据与历史异常

最后还关闭了两个静态确认的归属窗口：协调器不能在 MainActor 接受前释放回滚基线；restore/cancel/forget 等待 Store 取消后不能继续清理已被新连接接管的状态。现实现以锁保护的 pending/cancelled/accepted 意图状态建立同步接受点，代际检查、接受、偏好及 connected 发布位于同一 MainActor 无 await 片段，异步 finalize 后置；新意图识别已接受事务后不回滚它。清理等待后重新检查代际，或交由已带检查的 abandon 方法处理。独立只读复核确认指定路径已关闭。

公开边界不能精确暂停私有 actor 的旧 finalize 返回窗口，因此没有把该静态交错伪称为已完成精准行为红，也没有为测试新增私有生产 hook。新增 `acceptedCredentialSwitchIsNotRolledBackByLaterFailedConnection` 验证已接受 B 后，下一次连接鉴权失败仍保留 B 的地址和密钥；它不证明精准旧窗口已被确定性触发。最终 25 项会话回归在 `20261026-135102-cleanup-generation-guards` 通过，冻结的全部 39 个 Swift 文件与该归档逐字节一致，SHA256 为 `19af53ffeded5650f37724dd37a6f2ada4bb0df24e4c9cda9829193c9897628d`。首次提交点编译因 finalize 返回值未使用而被 warnings-as-errors 拒绝，修正后重跑通过；这次编译失败不算行为红。

每轮 TDD 证据位于 `artifacts/integration/tdd/<时间戳-标签>/`，包含 `result.json`、`test.log` 和对应 `source.tar`；退出码和源码 SHA256 可追踪。最终验证 JSON 汇总全部历史阶段，失败记录保留，不代表最终矩阵失败。

| 行为 | 已观察的失败证据 | 对应通过证据 |
| --- | --- | --- |
| 生命周期深层交错 | `20261026-101416-red-lifecycle-gaps` | 后续会话及全量原生回归 |
| 极大百分比 | `20261026-111249-red-extreme-percentage`：旧实现进程崩溃 | `20261026-111413-green-extreme-percentage`，含 `1e20 → 1e+22%` 和最大有限 Double |
| 保存期间调用方取消 | `20261026-114802-red-cancel-remember-save` | `20261026-120017-green-cancel-remember-save-final` |
| B 保存后、删除 A 时取消 | `20261026-122553-red-switch-transaction-rollback` | `20261026-124535-green-switch-transaction-rollback-final` |
| B 自身保存失败保留 A | `20261026-132326-red-preserve-saved-metadata`：保存地址变 nil，2 项断言失败 | `20261026-132411-green-preserve-saved-metadata` |
| 冷启动直接忘记的观察通知 | `20261026-132518-red-observable-saved-metadata`：未触发观察通知 | `20261026-132628-green-observable-saved-metadata`，24 项会话回归通过 |

历史中出现过编译错误、门闩未释放导致的测试超时和代理 API `403 insufficient balance`。这些记录未算作行为红灯，也未隐藏；后续按实际上下文修复并重跑。早期 `red-zero-quota-progress` 实际 exit 0，不计红；临时恢复旧下限后才复现 0.1 错误。串行化后的门闩用例验证同一公开最终不变量，不要求旧实现特有的补偿调用次数。

恢复检查还定位到本项目专用测试目录的一个孤立子进程，存活约 7602 秒且可执行映像已被替换。只对已确认的该进程发送 TERM，再确认构建容器无测试/编译运行；没有重启容器、删除目录或清理其他项目。另一次本地 PowerShell 进程检查因引号语法失败，修正检查命令后成功，未计为产品构建失败。

## 最终验证矩阵

最终验收使用唯一冻结构建 `artifacts/integration/build-20261026-141005/`，远端为独立构建目录。六个构建步骤全部退出码 0；以下均为该次实际结果，不复用旧候选。

| 验证 | 实际结果 | 证据（相对该构建目录） |
| --- | --- | --- |
| 全量原生测试，warnings-as-errors | 138 项、18 套件通过 | `native-tests.log` |
| 只读探针产品构建 | 通过 | `probe-build.log` |
| arm64 iOS App target release 编译 | 通过 | `ios-device-build.log` |
| arm64 iOS Simulator App target release 编译 | 通过；未运行模拟器 | `ios-simulator-build.log` |
| xtool release 未签名 App 打包 | 通过，产出真实 `CPAQuotaApp.app` | `xtool-app-package.log` |
| App 包、Mach-O 和 SwiftUI 入口检查 | 通过 | `app-inspection.json`、`app-inspection.log` |
| 当前 Swift/打包配置与构建身份 | 39 个 Swift 文件及 3 项配置逐文件 SHA256 一致 | `final-verification.json` |
| App 归档下载回验 | 大小 2867200 字节，SHA256 一致 | `final-verification.json` |
| 重复 Integration 回归 | 20/20 轮通过；每轮 27 项、2 套件，共 540 次执行（不是 540 个不同测试） | `repeat-20261026-141442/repeat-result.json` 及日志归档 |
| 保护边界 | 原后端/探针/测试 20 文件、核心设计 6 文件、只读交付 52 文件均不变 | `final-verification.json` |

App 的 Bundle ID 为 `dev.rin.cpaquota`，显示名 `CPA Quota`，包类型 `APPL`；可执行文件为 arm64 / MH_EXECUTE，iOS platform 2，最低系统 17.0.0，含实际 SwiftUI 引用且无 Linux fallback 符号。可执行文件实测 SDK stamp 为 17.0.0，不应把环境已有 SDK 的版本当成此字段。未发现代码签名 load command 或 provisioning profile，未请求个人签名。

| 校验对象 | SHA256 |
| --- | --- |
| 最终 Linux 构建环境的构建输入 `source.tar` | `6f3853c24baec19494030b3c00693a0d8fd87f584ad2e6058aa9c19c34f59ed8` |
| 39 个 Swift 文件的集合摘要 | `01c278f1083776475e1abf921851b62ad81f80333bd92a7c609c4c3882581cd2` |
| App 可执行文件 | `6c263be26b6090d6e39ef9ec3bed2718ff91233695faaf108b2d6641ee92ffd3` |
| `unsigned-app.tar` | `a7cd6f6abe6ded010111f927de050b57ec5e6f5c4781da430c9f1291f53da5c1` |
| 20 轮回归日志归档 | `0f9aab6123936571221581508c89819cf5fd70d463f669a1eaffc1950ad1a39d` |

最终构建只记录到 SwiftPM 的 `--build-system native` 弃用告警，未见历史候选中的平台链接器告警；没有降低 Swift 编译警告等级。验证说明和交付清单在构建结束后补录，因此构建输入归档与源码 ZIP 的文档时间点不同；参与编译的全部 Swift 文件及 `Package.swift`、`xtool.yml`、`AppInfo.plist` 身份已实际核验一致。

源码身份校验另做了旧候选负控：`build-20261026-120900` 虽然六个步骤都曾通过，当前校验仍因 `compiled_swift_sources_match_local=false` 返回失败；核对该预期失败后确认负控通过。记录为 `artifacts/integration/negative-control-old-candidate.json`，其中的 135 项历史测试不是最终测试数量。

## 复现命令

```powershell
python -I -X utf8 tools/test_backend_nwd.py --project . --host BUILD_HOST --container BUILD_CONTAINER --mode test
```

原完整验收通过 `tools/Build-NWD.ps1 -Mode All` 执行，该命令仅作历史记录。上面的命令是当前工具的测试示例，不是历史完整打包矩阵的复现；需替换主机和容器占位符。历史运行建立独立目录并校验上传 SHA256，未新增或升级依赖、SDK、链接器或工具链。

## 未验证边界

未运行 iPhone/模拟器 App、真实 Keychain、前后台切换、屏幕布局、按钮触控、VoiceOver 或低版本运行兼容性验收；未以此次前端连接真实 CPA 服务；未使用个人签名材料、生成可安装签名 IPA 或安装设备。SwiftUI 编译、Mach-O 检查和未签名 App 打包不能替代这些运行验收。后端旧实服验证记录也不能替代当前前端验证。

进度采用不改 Kit 的保守计数：相同重复错误或复用缓存可能不增加“已更新”数量，因而可能低估；不会借用上轮结果伪造本轮完成。安全文件名及常见令牌模式扫描没有命中也不等于能证明不存在任何类型秘密。

## 本地交付与回退

历史本地交付仅存原验证环境，不是公开下载入口。入口 `DELIVERY.md` 和 `delivery-manifest.json` 对应完整源码 ZIP、仅新增/修改文件 ZIP、逐文件 diff、未签名 App 归档及 `verification/` 证据。完整源码包不包含 `.git`、构建缓存、原始 TDD 日志或个人签名材料，保留原交付已有的 6 份脱敏 JSON。源码 ZIP 校验全部文件内容与 manifest 一致；差异 ZIP 校验仅包含列出的新增/修改文件和 diff；App TAR 再核对成员路径、可执行文件哈希和 plist。

回退不需要删除或 Git reset：停止使用集成副本，切回保留的原项目或原始前端交付即可。差异包用于在原前端交付的另一个副本上应用本次修改，不应直接覆盖原后端目录；完整源码 ZIP 更适合作为继续开发入口。原始前端仍保留本报告所述已修缺陷，回退是源码基线恢复而非推荐使用有缺陷版本。

# CPA Quota iOS App & Backend (`CPAQuotaKit` + `CPAQuotaUI` + `CPAQuotaApp`)

Rin，本工程包含原生 Swift 6 后端包 `CPAQuotaKit`、SwiftUI 前端模块 `CPAQuotaUI` 以及 App 入口 `CPAQuotaApp`。后端负责连接个人 CPA、枚举已有账号、读取并归一化额度、缓存最后成功结果、管理并发/取消以及通过系统 Keychain 保存管理凭据；前端通过 `@MainActor @Observable CPAQuotaSession` 与 `CPAQuotaStore` 驱动登录态、应用内灵动岛样式状态伴生栏、深浅双模外观（跟随系统 / 浅色羊皮纸 / 深色曜石）以及底部玻璃导航栏。玻璃视觉沿用交付设计，不代表集成了系统 Live Activity 或 ActivityKit。

## 运行与兼容性

| 项目 | 约定 |
| --- | --- |
| 语言 | Swift 6，严格并发（Strict Concurrency），零 Emoji 纯矢量符号体系 |
| 最低系统 | iOS 17 / macOS 14；使用 NWD 现有 Darwin SDK 编译，运行兼容性尚未实机验收 |
| 后端状态层 | `@MainActor @Observable CPAQuotaStore`（位于 `Sources/CPAQuotaKit/`，保留原始基线不变） |
| 前端会话与视图层 | `@MainActor @Observable CPAQuotaSession` 与 SwiftUI 视图集（位于 `Sources/CPAQuotaUI/`） |
| App 入口与打包配置 | `Sources/CPAQuotaApp/CPAQuotaiOSApp.swift`、`xtool.yml` |
| 外部依赖 | 无；仅使用 Foundation、Observation、SwiftUI、Apple 平台 Security |
| 当前读取器 | Codex、CPA 插件标准化额度、xAI billing |
| 写入 CPA | 不提供；只读查询，不登录上游 OAuth、不重置额度、不修改配置或账号 |
| 缓存与安全 | 额度缓存仅在进程内（实时结果默认 60 秒复用）；管理密钥仅在连接验证成功后写入系统 Keychain（`WhenUnlockedThisDeviceOnly`） |

## 架构与模块划分

| Target | 类型 | 路径与职责 |
| --- | --- | --- |
| `CPAQuotaKit` | Library | `Sources/CPAQuotaKit/`：网络传输、双层解析、并发限流（上限 3）、取消作用域、Keychain 凭据存储与 `CPAQuotaStore` |
| `CPAQuotaUI` | Library | `Sources/CPAQuotaUI/`：跨平台可测试的会话管理（`CPAQuotaSession`）、额度/错误/灵动岛状态归一化（`QuotaPresentation`、`ErrorPresentation`、`DynamicIslandState`）及 SwiftUI 液态玻璃视图组件 |
| `CPAQuotaApp` | Library（App 入口） | `Sources/CPAQuotaApp/`：SwiftUI `@main` 应用入口，由 `xtool.yml` 显式选作 App 产品 |
| `cpa-quota-probe` | Executable | `Sources/CPAQuotaProbe/`：只读实服命令行探针 |
| `CPAQuotaKitTests` | Test | `Tests/CPAQuotaKitTests/`：原有 106 项后端、5 项前端测试，以及集成修复回归测试 |

## 在 NWD 编译和测试

```powershell
& "Z:\控制台\cpa-quota-ios-integration-20261026\tools\Build-NWD.ps1" -Mode All
```

Rin，脚本上传不含签名材料的源码归档并校验 SHA256，在 NWD 为每次执行新建隔离目录，不覆盖原后端构建副本。`All` 执行原生测试、探针构建、arm64 iOS/模拟器编译和 xtool 未签名 App 打包，再检查包内元数据、Mach-O 平台和实际 SwiftUI 入口。日志、构建源码归档和未签名 App 归档位于 `artifacts/integration/build-时间戳/`。`Package` 模式仅执行打包及包检查，不请求个人证书、签名、安装或运行。

Rin，`CPAQuotaApp` 使用 automatic library 产品和普通 target，满足现有 xtool 1.23.0 的产品选择要求；`xtool.yml` 显式选择此产品并通过 `AppInfo.plist` 设置显示名，最低系统版本由 `Package.swift` 决定。编译/打包结果不等于真机运行、系统 Keychain 或视觉交互已经验收；实际证据及未验证项见集成验证记录。

## 可回退的集成副本

Rin，此目录以云盘原始前端交付为基线，原项目、原 ZIP 与只读审查解压目录均保留不动。基本页面划分、三栏导航和设计系统保持原样，改动集中于会话状态、错误展示和打包。需要回退时切回原始工程或原交付，不需要删除目录或执行破坏性 Git 操作。交付的差异文件和 SHA256 清单用于核对每项修改。

## 文档索引

| 文件 | 内容 |
| --- | --- |
| `docs/BACKEND_CONTEXT.md` | 开发前收集的 CPA/构建/签名资料及边界 |
| `docs/FRONTEND_INTEGRATION.md` | 后端 public Interface、状态模型、取消、错误与单位合同 |
| `docs/INTEGRATION_VERIFICATION.md` | 本次集成修复的实际验证与剩余限制 |
| `docs/VERIFICATION.md` | 后端实服与编译验证基线记录 |
| `FRONTEND_PROMPT.md` | 原始 Drive 前端交接要求与功能边界；不是本集成版的下载入口 |

# CPA Quota iOS App & Backend (`CPAQuotaKit` + `CPAQuotaUI` + `CPAQuotaApp`)

Rin，本工程包含原生 Swift 6 后端包 `CPAQuotaKit`、SwiftUI 前端模块 `CPAQuotaUI` 以及 App 入口 `CPAQuotaApp`。后端负责连接个人 CPA、枚举已有账号、读取并归一化额度、缓存最后成功结果、管理并发/取消以及通过系统 Keychain 保存管理凭据；前端通过 `@MainActor @Observable CPAQuotaSession` 与 `CPAQuotaStore` 驱动登录态、应用内灵动岛样式状态伴生栏、深浅双模外观（跟随系统 / 浅色羊皮纸 / 深色曜石）以及底部玻璃导航栏。玻璃视觉沿用交付设计，不代表集成了系统 Live Activity 或 ActivityKit。

## Rin，当前交付与启用状态

| 层次 | 当前状态 | 边界 |
| --- | --- | --- |
| 现有 App | 已有账号、额度与连接状态界面 | 真机、Keychain 和完整交互验收不由后端合并代替 |
| 新增 Swift 后端 | CAP 近30分钟用量、逐模型加权 TPS、详情读取、监控客户端及独立桥接凭据存储 | 公开接口已提供，不代表新页面或系统活动已经接入 |
| 独立 Go 监控服务 | 受控读取、租约、取消墓碑、有界准入、加密状态和 APNs update/end | 源码合并不会启动或部署服务，不会配置真实凭据或启用 Apple 能力 |

Rin，监控服务必须由操作者另行配置并运行。`dry_run=true` 仅禁止 APNs，不禁止有活动时的 CPA 采集，因此不能把 dry-run 当作完全离线模式。真实 CPA、插件鉴权、APNs、ActivityKit 扩展、系统轮播与设备送达仍需独立接入和验收；600秒是服务端采集目标，不是设备必达承诺。

## Rin，运行与兼容性

| 项目 | 约定 |
| --- | --- |
| 语言 | Swift 6，严格并发（Strict Concurrency），零 Emoji 纯矢量符号体系；独立服务使用 Go 1.26 或更高兼容工具链 |
| 最低系统 | iOS 17 / macOS 14；最低系统的真机运行兼容性尚未验收 |
| 后端状态层 | `@MainActor @Observable CPAQuotaStore`、`CAPUsageStore` 与 `MonitoringStore`，位于 `Sources/CPAQuotaKit/` |
| 前端会话与视图层 | `@MainActor @Observable CPAQuotaSession` 与 SwiftUI 视图集，位于 `Sources/CPAQuotaUI/` |
| App 入口与打包配置 | `Sources/CPAQuotaApp/CPAQuotaiOSApp.swift`、`xtool.yml` 和 `Apple/CPAQuota.xcodeproj` |
| 外部依赖 | 无第三方运行时依赖；Swift 使用 Foundation、Observation、SwiftUI、Apple 平台 Security，Go 使用标准库 |
| 当前读取器 | Codex、CPA 插件标准化额度、xAI billing；CAP Usage 使用独立的只读统计接口 |
| 写入 CPA | 不提供；只读查询，不登录上游 OAuth、不重置额度、不修改配置或账号 |
| 缓存与安全 | App 额度缓存仅在进程内；管理和桥接凭据使用独立 Keychain 命名空间，保持 `WhenUnlockedThisDeviceOnly`；服务状态另行加密持久化 |

## Rin，架构与模块划分

| 模块 | 类型 | 路径与职责 |
| --- | --- | --- |
| `CPAQuotaKit` | Swift Library | `Sources/CPAQuotaKit/`：网络传输、解析、共享管理冷却与并发资格、取消、凭据存储、额度/CAP/监控状态层 |
| `CPAQuotaUI` | Swift Library | `Sources/CPAQuotaUI/`：会话管理、展示归一化及 SwiftUI 视图组件 |
| `CPAQuotaApp` | Swift Library（App 入口） | `Sources/CPAQuotaApp/`：SwiftUI `@main` 应用入口 |
| `cpa-quota-probe` | Swift Executable | `Sources/CPAQuotaProbe/`：只读实服命令行探针；不属于合成测试的默认联网目标 |
| `CPAQuotaKitTests` | Swift Test | `Tests/CPAQuotaKitTests/`：额度、凭据事务、取消、CAP 与监控回归；共享 JSON 由 `Tests/ContractFixtures/` 打包进入 SwiftPM/native 测试 bundle |
| `QuotaMonitor` | 独立 Go Module | `Services/QuotaMonitor/`：HTTP 控制、白名单采集、持久化、调度与 APNs；不属于 SwiftPM App 的自动启动流程 |

## Rin，验证与构建

Rin，`.github/workflows/backend-checks.yml` 在 PR 和 `main` 更新时运行 Go test/race/vet、Linux/Windows 构建、macOS SwiftPM、iOS Simulator 原生测试和 App 构建。该工作流仅使用 `contents: read`，不签名、不发布、不部署，也不使用真实 CPA/APNs/Apple 账号凭据；包含 macOS 作业，会消耗相应 CI 额度。当前结果应查看对应提交的 [GitHub Actions](https://github.com/rinmashiro0529/cpa-quota-ios/actions)，不能用历史回执替代新提交的检查。既有 `ios-ci.yml` 归档流程仍受原指定 CI 分支限制。

Rin，在仓库根目录可运行源码接线校验和独立 Go 合成验收；后者输出真实退出码、源码哈希和构建回执到新的 `artifacts/backend-verification/` 目录，不启动真实监控服务。

```powershell
python -I -X utf8 -B ci/validate_source_layout.py --root .
python -I -X utf8 -B ci/test_source_layout.py
python -I -X utf8 -B tools/test_monitor_backend.py --project .
```

Rin，已配置 NWD SSH 和既有 `ios-builder` 的环境可使用仓库内工具执行隔离测试与交叉编译，无需引用其他工程目录的脚本。

```powershell
python -I -X utf8 tools/test_backend_nwd.py --project . --mode test
python -I -X utf8 tools/test_backend_nwd.py --project . --mode device --target CPAQuotaApp
python -I -X utf8 tools/test_backend_nwd.py --project . --mode simulator --target CPAQuotaApp
```

Rin，NWD 工具为每次运行创建新目录并校验归档 SHA256，不覆盖旧构建、不清理共享缓存、不重启容器。Darwin SDK 交叉编译不等于 Xcode Simulator 测试、签名归档或真机运行；原生测试由上述 Apple CI 单独验证，真实设备行为仍需另行验收。

## Rin，接入、升级与回退边界

Rin，同一管理连接的 401/403 保护不能通过 force、重载清单或已有成功缓存绕过；429 尊重截止时间。修复凭据或管理权限后，应显式创建新的连接上下文重新验证，而不是清除保护或删除上游账号。插件监控仅使用稳定的 `summary-key:<key>`；旧位置选择器必须迁移，没有稳定 key 的指标不能通过猜测数组位置接入。

Rin，服务容量限制包含历史终态会话和取消墓碑，默认每个 principal 的历史意图上限为256，租约到期不会自动释放；容量不足时新意图返回507，不能靠删除状态文件腾空间。活动 token 失效会产生 v2 持久记录，旧服务不能直接读取；回退须保留已确认的取消事实并使用兼容格式，不能恢复陈旧状态丢弃它们。详见服务迁移说明；本仓库不包含自动部署或破坏性降级脚本。

Rin，PR #1 的功能与 PR #2 的可靠性修复应作为完整组合维护，测试、共享合同与原生接线不能拆开省略。原始交付、基线提交和历史验证记录继续保留；新的源码主线不替换既有安装包，也不撤销证书或清空 Keychain。

## Rin，文档索引

| 文件 | 内容 |
| --- | --- |
| [前端接入合同](docs/FRONTEND_INTEGRATION.md) | public Interface、状态、取消、错误与单位 |
| [CAP Usage 后端](docs/CAP_USAGE_BACKEND.md) | 统计鉴权、窗口、加权 TPS、分页与详情状态 |
| [Swift 监控后端](docs/MONITORING_SWIFT_BACKEND.md) | 会话控制、204 回执、对账与安全 DTO |
| [桥接凭据隔离](docs/MONITOR_BRIDGE_CREDENTIALS.md) | 独立 Keychain 命名空间和保护边界 |
| [独立监控服务](docs/MONITOR_SERVICE.md) | 配置、容量、稳定选择器、v2 状态与运行限制 |
| [可靠性专项验收](docs/BACKEND_RELIABILITY_PR.md) | PR #2 整改、验证范围与升级条件 |
| [后端历史回执](docs/BACKEND_VERIFICATION.md) | PR #1 的源码验证、失败历史及未验收项 |
| [开发资料](docs/BACKEND_CONTEXT.md) | 开发前收集的 CPA/构建/签名资料及边界 |
| [集成历史回执](docs/INTEGRATION_VERIFICATION.md) | 既有集成修复与验证限制 |
| [原后端验证基线](docs/VERIFICATION.md) | 早期实服与编译记录，不代表当前提交重跑 |
| [原始前端交接](FRONTEND_PROMPT.md) | 历史 Drive 交接要求，不是当前源码下载入口 |

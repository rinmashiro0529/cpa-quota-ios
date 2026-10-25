# CPA Quota iOS Backend

Rin，`CPAQuotaKit` 是供 SwiftUI App 导入的原生 Swift 后端包。它负责连接个人 CPA、枚举已有账号、读取并归一化额度、缓存最后成功结果、管理并发/取消，以及通过系统 Keychain 保存管理凭据。本工程没有任何 View、演示 App、网页前端或新的服务器进程。

## 运行与兼容性

| 项目 | 约定 |
| --- | --- |
| 语言 | Swift 6，严格并发 |
| 最低系统 | iOS 17 / macOS 14 |
| 前端接入 | `@MainActor @Observable CPAQuotaStore` |
| 外部依赖 | 无；Foundation、Observation、Apple 平台 Security |
| 当前读取器 | Codex、CPA 插件标准化额度、xAI billing |
| 当前线上验证范围 | 见 `docs/VERIFICATION.md`；不把结构测试等同所有平台实服通过 |
| 写入 CPA | 不提供；不登录、不重置额度、不修改配置或账号 |
| 缓存 | 进程内，实时结果默认 60 秒复用；失败保留最后成功数据；不持久化邮箱/额度到磁盘 |

## 快速接入

Rin，在未来 App 工程中添加本目录为本地 Swift Package 依赖，导入 `CPAQuotaKit`。前端只需要持有 `CPAQuotaStore` 并读取其账号、记录和加载状态，不需要解析任何上游 JSON。完整合同及错误语义见 [前端接入说明](docs/FRONTEND_INTEGRATION.md)。

```swift
import CPAQuotaKit

@MainActor
func makeQuotaBackend(serverAddress: String, managementKey: String) async throws -> CPAQuotaStore {
    let server = try CPAServer(baseURL: serverAddress)
    let key = try ManagementKey(managementKey)
    let client = CPAClient(server: server, managementKey: key)
    let store = CPAQuotaStore(client: client)
    await store.load()
    if let error = store.error { throw error }
    try await KeychainCredentialStore().save(key, for: server)
    return store
}
```

Rin，以上是接入代码示例，不是包含 View 的前端实现。密钥只在成功连接后保存，单个上游账号失效不会要求删除仍有效的 CPA 管理密钥。界面文案可按 `CPAError.Kind` 本地化，不要显示原始上游 body。

## 在 nwd 编译和测试

```powershell
& "Z:\控制台\cpa-quota-ios\tools\Build-NWD.ps1" -Mode All
```

Rin，脚本通过 `scp` 上传不含签名材料的源代码归档，校验 SHA256，再在 NWD 已有 `ios-builder` 容器中执行原生测试、探针构建和真实 Apple SDK 的 arm64 iOS / arm64 模拟器库编译。原生和交叉编译使用独立 scratch 目录，编译并行度为 2，warnings-as-errors 开启。日志取回 `artifacts/`；不在本机运行 Swift 编译，不安装或升级任何工具。

Rin，纯后端 library 不需要签名，也不会产生可以安装的 IPA。本次不复制或使用 `G:\Apple 证书\15 pro` 中的 p12、密码或描述文件；未来完整 SwiftUI App 才需要接入签名与打包。

Rin，当前 Swift 6.4 的默认 Swift Build 路径在这套已有 slim SDK 上无法发现 `iphoneos`，本项目仅对 Apple 交叉编译显式使用已安装工具链支持的 `--build-system native`，不改变 SDK。SwiftPM 会提示该构建后端已弃用，这是已记录的工具链兼容限制；没有关闭 Swift 源码的 warnings-as-errors，也不影响库在正常 Xcode/SwiftUI 工程中的源码接入。

## 只读实服探针

```powershell
python -I "Z:\控制台\cpa-quota-ios\tools\live_probe.py" --server "https://<your-cpa-host>" --credential-file "<existing-management-key-file>"
```

Rin，探针只运行 NWD 已编译的 Swift executable；管理密钥通过加密 SSH 的标准输入交给 `docker exec -i`，不出现在命令行参数、环境变量、归档或远端凭据文件中。输出仅含 provider、数量、窗口/指标数量及错误类别，不输出账号 ID、邮箱、token、余额或完整请求。这个命令会真实查询启用账号的额度；不应在自动单元测试中运行。

## 文档

| 文件 | 内容 |
| --- | --- |
| `docs/BACKEND_CONTEXT.md` | 开发前收集的 CPA/构建/签名资料及边界 |
| `docs/FRONTEND_INTEGRATION.md` | public Interface、状态模型、取消、错误和单位合同 |
| `docs/VERIFICATION.md` | 实际运行结果、未覆盖项和交付边界 |
| [FRONTEND_PROMPT.md](FRONTEND_PROMPT.md) | 可交接给前端 agent 的 App 功能与必要上下文，不预设界面设计 |

Rin，CPA 管理密钥本身拥有管理权限；本包只提供只读请求，并不会改变服务器对密钥的授权。需要真正的低权限手机凭据时，仍需单独设计服务器端只读隔离层，不能仅靠隐藏按钮或客户端固定 URL 达成权限隔离。

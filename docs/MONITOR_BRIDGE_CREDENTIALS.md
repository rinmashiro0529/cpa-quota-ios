# 桥接与各类凭据的安全存储合同

`MonitoringBridgeCredentialStore` 为独立监控服务（技术文档称监控桥接）的访问凭据提供独立存储。默认使用既有 `KeychainCredentialStore`，服务名为 `CPAQuotaKit.MonitorBridgeCredentials`，继续采用 `WhenUnlockedThisDeviceOnly`。不会修改原 `CPAQuotaKit.ManagementCredentials` 或 `CPAQuotaKit.ChatCredentials`、增加共享访问组，或在 Keychain 不可用时自动改存 UserDefaults / 文件。

## 各类凭据不可互换

| 凭据 | 用途 | 存储 / 传输边界 |
| --- | --- | --- |
| CPA 管理密钥 | App 或授权服务访问 CPA 管理接口 | Keychain 服务 `CPAQuotaKit.ManagementCredentials`（`WhenUnlockedThisDeviceOnly`）；不作为监控注册请求字段 |
| CPA 客户端 API Key | AI 对话调用模型目录与推理接口 | Keychain 服务 `CPAQuotaKit.ChatCredentials`，按 CPA 服务隔离（`client-api-key\|<server.identifier>`）；详见 [AI 对话指南](AI_CHAT.md) |
| 第三方搜索 API Key | AI 对话可选联网搜索 | Keychain 服务 `CPAQuotaKit.ChatCredentials`，全局共用（`search-key\|<provider>`），不随 CPA 连接隔离；详见 [AI 对话指南](AI_CHAT.md) |
| `MonitorBridgeToken`（监控访问令牌） | App 访问自有监控服务，服务端绑定 principal 与授权来源 | 独立 Keychain 服务 `CPAQuotaKit.MonitorBridgeCredentials`，HTTPS Bearer，不进入活动 payload |
| `MonitoringPushToken` | 服务端更新特定 Live Activity | 交给授权监控服务；不能用作用户登录凭据，不返回在会话响应中 |
| APNs 提供者私钥 | 服务端签署 Apple APNs 认证 JWT | 只由部署侧管理；不进入 App、Git 或本模块 |

## 调用方式

```swift
let address = try MonitorBridgeAddress(baseURL: bridgeURL)
let credentials = MonitoringBridgeCredentialStore()
try await credentials.save(bridgeAccessToken, for: address)
if let token = try await credentials.load(for: address) {
    let client = try CPAMonitorClient(baseURL: address.baseURL, token: token)
    // Keep the session UUID available for reconciliation after a request timeout.
}
```

调用方应在保存成功后更新「已保存」元数据；保存失败不能显示成功，删除失败不能宣告忘记完成。存储层不代替会话取消与凭据切换事务，不会替调用者清除旧连接或服务器活动。

停止监控与删除本机凭据是不同结果：先尝试停止服务端会话并核对结果，再删除本机监控凭据。离线或停止请求结果不明时，必须保留可追踪的会话 ID 并明确说明租约兜底；若用户选择仅在本机忘记，不得宣称服务器活动已结束，也不能未经同意继续保留或使用该凭据。

## 地址隔离

`MonitorBridgeAddress` 只接受 HTTPS、合法端口与无内嵌用户名密码、query 或 fragment 的地址，拒绝相对点路径、编码斜线、反斜线及控制字符。规范化 host、默认 443 端口与末尾斜线，但不会像 CPA 管理地址那样剥离 `/v0/management` 或 `/management.html` 后缀，因为它们可能是不同监控服务的合法反向代理前缀。

内部复用现有通用凭据存储时，为监控地址派生带固定作用域后缀的独立 account 标识；不会向该派生地址发 HTTP 请求。不同路径的监控凭据和原管理凭据互不覆盖。将已标准化的 `address.baseURL` 传给监控客户端，以免 UI 自行重复拼接地址。

## 凭据身份与格式迁移

前端历史会话还需要区分同一地址下的不同凭据。`loadCredential` / `bind` 使用 schemaVersion 1 的受保护记录，在同一个 Keychain item 中原子保存 token 与随机 binding UUID。UUID 仅是本地凭据身份，不是客户端自行断言的服务端 principal；UserDefaults 可以引用它，但不会保存 token 或 token hash。相同 token 的已保存 binding 可复用，更换 token 会得到新 binding。

旧 plain token 可读取；显式建立 binding 时只有完整受保护写入成功才完成迁移，失败保留旧值。Keychain / Memory 的内部 raw-record 接口限 16 KiB，以容纳完整 4096-byte token 与封装；公开 `ManagementKey` 和 `MonitorBridgeToken` 输入上限仍是 4096 bytes。

历史记录没有 binding，或与当前凭据 binding 不同时，仅允许在原监控服务地址 GET 对账。只有服务器成功返回且 UUID、source、accounts、activityID 与 revision 匹配后，前端才能接管；404 不会转移归属，也不能证明远端已停止。临时连接重启后若失去原 binding，同样遵守该规则。

旧客户端不理解新 Keychain 封装，会拒绝恢复，不能把回滚当成无损自动迁移。需要回滚时应先使用理解新格式的版本明确断开、保留会话索引，再在旧版本重新输入 token；不自动导出秘密，不通过清空历史规避对账。

## 错误与测试边界

已知安全存储失败保留其安全错误类别；未知存储错误统一映射为 `secureStorageFailure`，不把底层错误的任意文本或秘密转给前端。敏感 Token 没有 Codable 表示，文本描述脱敏；任何调用方仍不应记录其原值、请求认证头或完整会话上下文。

测试通过注入 `MemoryCredentialStore` 和合成 HTTPS 传输验证实际认证头、路径隔离、原管理凭据不被替换、失败保留、错误脱敏和移除幂等。Linux 无 Security 框架时验证默认存储报不可用，而非明文回退；这些不等同于真实 iPhone Keychain 验收。所有测试凭据均为合成值，没有读取用户的 Keychain 或 Apple 身份。

本模块没有创建或修改 Apple 开发者资源，不要求为了锁屏更新降低 Keychain 保护。它只完成监控凭据存储；真实 APNs 开通、签名、服务部署和系统活动呈现仍按各自阶段单独验收。

# 桥接凭据的安全存储合同

`MonitoringBridgeCredentialStore` 为监控桥接访问凭据提供独立存储。默认使用既有 `KeychainCredentialStore`，服务名为 `CPAQuotaKit.MonitorBridgeCredentials`，继续采用 `WhenUnlockedThisDeviceOnly`。不会修改原 `CPAQuotaKit.ManagementCredentials`、增加共享访问组，或在 Keychain 不可用时自动改存 UserDefaults/文件。

## 四种凭据不可互换

| 凭据 | 用途 | 存储/传输边界 |
| --- | --- | --- |
| CPA 管理密钥 | App或授权服务访问CPA管理接口 | 保持原有敏感类型与存储；不作为桥接注册请求字段 |
| `MonitorBridgeToken` | App访问自有桥接，服务端绑定principal与授权来源 | 独立Keychain命名空间，HTTPS Bearer，不进入活动payload |
| `MonitoringPushToken` | 服务端更新特定Live Activity | 交给授权桥接；不能用作用户登录凭据，不返回在会话响应中 |
| APNs提供者私钥 | 服务端签署Apple APNs认证JWT | 只由部署侧管理；不进入App、Git或本模块 |

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

调用方应在保存成功后更新“已保存”元数据；保存失败不能显示成功，删除失败不能宣告忘记完成。存储层不代替会话取消与凭据切换事务，不会替调用者清除旧连接或服务器活动。

停止监控与删除本机凭据是不同结果：先尝试停止服务端会话并核对结果，再删除本机桥接凭据。离线或停止请求结果不明时，必须保留可追踪的会话ID并明确说明租约兜底；若用户选择仅在本机忘记，不得宣称服务器活动已结束，也不能未经同意继续保留或使用该凭据。

## 地址隔离

`MonitorBridgeAddress` 只接受HTTPS、合法端口与无内嵌用户名密码、query或fragment的地址，拒绝相对点路径、编码斜线、反斜线及控制字符。标准化host、默认443端口与末尾斜线，但不会像CPA管理地址那样剥离`/v0/management`或`/management.html`后缀，因为它们可能是不同桥接服务的合法反向代理前缀。

内部复用现有通用凭据存储时，为桥接地址派生带固定作用域后缀的独立account标识；不会向该派生地址发HTTP请求。不同路径的桥接凭据和原管理凭据互不覆盖。将已标准化的`address.baseURL`传给监控客户端，以免UI自行重复拼接地址。

## 凭据身份与格式迁移

前端历史会话还需要区分同一地址下的不同凭据。`loadCredential` / `bind` 使用 schemaVersion 1 的受保护记录，在同一个 Keychain item 中原子保存 token 与随机 binding UUID。UUID 仅是本地凭据身份，不是客户端自行断言的服务端 principal；UserDefaults 可以引用它，但不会保存 token 或 token hash。相同 token 的已保存 binding 可复用，更换 token 会得到新 binding。

旧 plain token 可读取；显式建立 binding 时只有完整受保护写入成功才完成迁移，失败保留旧值。Keychain/Memory 的内部 raw-record 接口限 16 KiB，以容纳完整 4096-byte token 与封装；公开 `ManagementKey` 和 `MonitorBridgeToken` 输入上限仍是 4096 bytes。

历史记录没有 binding，或与当前凭据 binding 不同时，仅允许在原桥接地址 GET 对账。只有服务器成功返回且 UUID、source、accounts、activityID 与 revision 匹配后，前端才能接管；404 不会转移归属，也不能证明远端已停止。临时连接重启后若失去原 binding，同样遵守该规则。

旧客户端不理解新 Keychain 封装，会拒绝恢复，不能把回滚当成无损自动迁移。需要回滚时应先使用理解新格式的版本明确断开、保留会话索引，再在旧版本重新输入 token；不自动导出秘密，不通过清空历史规避对账。

## 错误与测试边界

已知安全存储失败保留其安全错误类别；未知存储错误统一映射为`secureStorageFailure`，不把底层错误的任意文本或秘密转给前端。敏感Token没有Codable表示，文本描述脱敏；任何调用方仍不应记录其原值、请求认证头或完整会话上下文。

测试通过注入`MemoryCredentialStore`和合成HTTPS传输验证实际认证头、路径隔离、原管理凭据不被替换、失败保留、错误脱敏和移除幂等。Linux无Security框架时验证默认存储报不可用，而非明文回退；这些不等同于真实iPhone Keychain验收。所有测试凭据均为合成值，没有读取用户的Keychain或Apple身份。

本模块没有创建或修改Apple开发者资源，不要求为了锁屏更新降低Keychain保护。它只完成桥接凭据存储；真实APNs开通、签名、服务部署和系统活动呈现仍按各自阶段单独验收。

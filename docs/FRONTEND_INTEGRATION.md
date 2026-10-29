# SwiftUI 前端接入合同

Rin，本文件说明 `CPAQuotaKit` 的 public Interface，不包含界面代码。前端通过原生 Swift 值类型与 MainActor 可观察状态消费数据；不得重复实现服务端 JSON、token 替换或窗口单位推算。

## 引入 Package

```swift
// 未来 App 的 Package.swift 内：
dependencies: [
    .package(path: "../cpa-quota-ios")
]
// App target 的 dependencies 内：
.product(name: "CPAQuotaKit", package: "cpa-quota-ios")
```

Rin，App 的最低系统需满足 iOS 17，Swift 工具链至少支持 Swift 6。本库没有第三方依赖，且没有需要 App 复制的证书、密钥或资源文件。

## 连接与凭据

```swift
let server = try CPAServer(baseURL: "https://cpa.example")
let key = try ManagementKey(userProvidedKey)
let client = CPAClient(server: server, managementKey: key)
let store = await MainActor.run { CPAQuotaStore(client: client) }
await store.load()
```

Rin，`CPAServer` 要求 HTTPS，拒绝 URL 内的用户名/密码、query、fragment、点路径和编码分隔符。它规范化 host、默认 443 端口、尾斜杠，并可从 `/management.html` 或 `/v0/management` 还原根路径；反代前缀可以保留。不要向 App 加入“忽略证书错误”开关。

Rin，`ManagementKey` 不可 Codable，description/debugDescription 已脱敏；它仍然是敏感的内存值，前端不应记录原始用户输入。以 `server.identifier` 作为非秘密的配置/Keychain关联标识，不能把密钥写入 UserDefaults、URL、剪贴板日志或崩溃遥测。

```swift
let credentials: any CredentialStore = KeychainCredentialStore()
try await credentials.save(key, for: server)
let saved = try await credentials.load(for: server)
// 仅在用户明确选择忘记该连接时：
try await credentials.remove(for: server)
```

Rin，Keychain 保存应在管理连接成功后进行。单个上游账号出现 `upstreamUnauthorized` 时，不要删除 CPA 管理密钥；管理密钥变更后创建新的 `CPAClient`/`CPAQuotaStore`。Keychain 默认 `WhenUnlockedThisDeviceOnly`，没有额外 access group 或 iCloud 同步。`MemoryCredentialStore` 只供显式临时会话和测试；不支持 Security 的平台会明确报告 Keychain 不可用，不自动明文降级。

## 可观察状态

| `CPAQuotaStore` 字段 | 消费方式 |
| --- | --- |
| `accounts: [CPAAccount]` | 显示账号列表和启用/不可用状态；id 在同一个 server 内使用 |
| `records: [String: QuotaRecord]` | 用 account.id 查归一化额度与本次账号错误 |
| `isLoading` | 正在读取账号与能力信息 |
| `isRefreshing` | 账号信息已发布，正在并发查询额度 |
| `error: CPAError?` | 整体连接/管理错误；不代替每个记录自己的 error |
| `capabilityWarning: CPAError?` | 可选额度能力发现的非阻塞异常；已有账号和内置读取器仍可用，不能据此删除管理密钥 |

| 操作 | 合同 |
| --- | --- |
| `await store.load()` | 读取最新账号列表，先发布已有观察，再查询启用账号；有效实时缓存可复用 |
| `await store.refresh()` | 同样刷新账号列表，并默认强制查询，仍尊重 Retry-After |
| `await store.refresh(force: false)` | 允许复用 60 秒进程内实时缓存 |
| `await store.cancel()` | 取消当前请求，立即停止加载标记；旧请求迟到不能覆盖新状态 |

Rin，同一个 store 正在执行时，额外 load/refresh 调用不会叠加请求；前端无需再套一层重试/定时器。正常 Task 取消也会传递到网络请求。不要在每次 body 求值时启动查询；前端负责在明确的生命周期/用户操作中调用以上 async 方法。

Rin，每个账号查询完成就更新对应记录，不等慢账号全部完成才发布成功结果。失败保留最后成功 snapshot，错误在记录中保留；使用缓存不能冒充新的查询成功。进程退出后额度缓存不保留到磁盘，恢复时需重新加载；服务器地址/显示偏好等非秘密持久化由宿主 App 自行决定。

## 额度与单位

| 数据 | 语义 |
| --- | --- |
| `QuotaSnapshot.source` | `.passive` 是已有观察，`.live` 是主动查询；缓存不篡改其来源 |
| `fetchedAt` | 本客户端取得该数据的时间 |
| `observedAt` | 上游/CPA 已有观察时间；passive 缺少它时必须视为新鲜度未知/陈旧 |
| `isStale(at:maximumAge:)` | 默认 300 秒，passive 按自身 observedAt 而非列表刷新时间判断 |
| `QuotaWindow.usedFraction` | 已用比例，0.58 表示 58%；nil 是未知。保留超过 1 的真实超额值 |
| `QuotaWindow.remainingFraction` | 已归一化且限制到 0–1 的展示用剩余比例；nil 仍是未知 |
| `durationSeconds` | 实际窗口长度，秒；不能按套餐名猜日/周/月 |
| `resetAt` | Date，前端按用户时区格式化，不再乘/除 1000 |
| `QuotaMetric.value/unit/format/currency` | 按返回单位展示；只有明确 currency 才格式化币种，不能统一按美元或分 |
| `QuotaCredits.balance` | nullable 额外 credits；不等于订阅可用百分比，也不保证是美元 |

Rin，`windows` 和 `metrics` 都可能为空，或只有其中一类。freetier 在调研时就是 summary-only 合法结果。缺少余额或窗口不是零也不是无限；不要把两个共享窗口的百分比相加。套餐到期声明不能独自证明当前账号已失效。

## 错误层次与重试

| `CPAError.Kind` | 前端行为 |
| --- | --- |
| `invalidServer` / `invalidManagementKey` | 修正输入，不联网重试 |
| `managementUnauthorized` | 修正管理密钥；停止整批查询，不删除上游账号 |
| `managementForbidden` | 显示远程管理/封禁提示，不连续重试 |
| `upstreamUnauthorized` | 只标记该账号，其他账号保持正常；不清空 CPA 密钥 |
| `rateLimited` | 查看 layer 与 retryAfter；不抢在指定时间前强制重试 |
| `accountDisabled` | 显示停用；不主动查该账号，不尝试自动启用 |
| `unsupportedProvider` | 明确显示未支持，不伪造可用额度 |
| `network` / `timeout` | 显示连接异常及最后成功数据的新鲜度 |
| `invalidResponse` / `responseTooLarge` | 提示接口兼容或响应问题，不把原始 body 当用户可见错误 |
| `cancelled` | 不作为额度耗尽或连接失效提示 |

Rin，默认没有自动重试。同一连接的额度与 CAP 管理请求共享协调器，最多三路管理读取；同账号额度请求合并。管理401/403会阻断该连接后续管理请求，避免触发 CPA 的失败封禁；force、重载账号清单或已有成功缓存都不能解除或掩盖阻断。修复凭据或远程管理权限后，应显式创建新的 `CPAClient`/`CPAQuotaStore` 连接上下文重新验证，不删除上游账号或自动清空凭据。管理429尊重 Retry-After，缺少有效截止时间时保守等待60秒，重载清单或 force 不得缩短；冷却到期只表示可以重试，不表示连接已经恢复。批量刷新会向调用者传播管理阻断错误，不用旧缓存发出新的成功回调。上游单账号失败不阻止其他账号。

Rin，批次内某个账号的共享读取被其他调用者取消，或该账号在读取期间被移除时，只跳过该行，不将其提升为整批失败；已有快照与其时间戳不被伪装成新成功。调用者取消整个批次或显式 `client.cancelRefreshes()` 仍是全局取消。Store 自己持有每次操作的 Task，取消与立即重新加载不依赖 sleep/yield 等调度猜测。

Rin，共享请求的取消约定是：任一等待者取消，会取消该账号的共享请求，所有等待者都将观察到取消；`cancelRefreshes()` 则取消该 client 的全部当前读取。同一个 store 的生命周期应只有一个明确的所有者。

## 不使用状态层时

```swift
let accounts = try await client.loadAccounts()
let cached = await client.currentRecords()
let records = try await client.refreshAll(force: true) { record in
    // 通过调用方自己的 MainActor 状态接收已归一化结果。
}
let quota = try await client.refreshQuota(for: accounts[0].id, force: true)
await client.cancelRefreshes()
```

Rin，上述示例中的下标只是展示调用关系，实际前端应先判断是否有账号。`refreshAll` 的回调是 Sendable async，前端自行切回 MainActor；使用 `CPAQuotaStore` 时不需要手动实现这些调度。使用不同服务器时必须创建独立 client，不得复用包含旧管理密钥的连接对象。

## 验证边界

Rin，SwiftUI 前端应按错误 kind 本地化文案并用原生 Text 展示服务器提供的标签，不执行 HTML。真实设备 Keychain、前台/后台切换、未来 App entitlement 与签名由完整 App 集成阶段验证；库的 iOS SDK 编译不等于已经在 iPhone 上运行。

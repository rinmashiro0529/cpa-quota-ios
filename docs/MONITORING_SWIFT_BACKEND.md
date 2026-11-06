# Swift 监控后端

当前实现是监控客户端与纯 Swift 快照模型，不代表真实 APNs、WidgetKit、Live Activity、服务部署或设备推送已经验证。持久墓碑、授权和调度的历史验证见 `BACKEND_RELIABILITY_PR.md`；当前提交应查阅对应的 CI 检查；`BACKEND_VERIFICATION.md` 仅是 PR #1 的历史回执，完成源码与合成测试不等于可以直接开启生产监控。

## 客户端与状态

`MonitorBridgeToken` 与 `MonitoringPushToken` 是独立的非 Codable 敏感类型，文本描述脱敏。使用 `MonitorBridgeAddress` 规范化 HTTPS 桥接地址后创建 `CPAMonitorClient`，调用 `capabilities`、`create`、`get`、`rotate`、`refresh`、`stop` 和 `cachedQuota`。地址规则与独立 Keychain 存储一致，不能自行剥离桥接的反向代理路径。监控访问令牌（Bridge Token）不等于 CPA 管理密钥。

创建会话时由调用方先生成并持久保存 UUID；请求超时后以原 UUID 查询对账，不能换 UUID 盲目重试。`stop` 返回 nil 只表示服务器返回204并接受停止意图，不能解释为设备活动已移除或 APNs 已送达。`MonitoringStore` 对启动、加载、刷新、token 更新和停止提供可观察状态；网络失败保留当前会话 UUID，并标为 uncertain，不把结果不明伪装成停止成功。

`rotate` 的 revision 为 expected-current，成功响应必须加一；溢出在发送前拒绝。初始 revision 为1，控制变更递增，快照更新只递增 sequence。`refresh` 接受200或202；202只表示当前会话已返回、采集尚待完成，不表示推送完成。push token 是非空偶数长度十六进制文本，最多4096字符，不固定为32字节。当前 `rotate` 的 activityID 参数只用于核对响应，不发送到 token 更新 body 中，也不把旧 session 改绑到另一 Activity。

401 表示桥接凭据失效，会阻断该客户端后续请求；403 可能只是来源/账号授权不足，只拒绝这一请求，不应阻止发送原本有权停止的会话 DELETE。此规则不同于 CPA 管理连接的共享 401/403 熔断：管理侧原合同不变。404、409、5xx、重定向和 429 有独立安全错误类别。普通查询/创建、refresh、DELETE 和 token PUT 各自遵守自己的 Retry-After；缺少有效期限时保守等待 60 秒。刷新被限流不会阻断其他通道，停止或 token 更新自身被限流时仍然等待，不能借通道隔离绕过服务端冷却。`await client.retryAt` 仅暴露普通查询/创建通道的期限。不得记录原始认证头、请求体、令牌或完整会话上下文。

507 单独映射为 `MonitoringError.capacityExceeded`，表示服务没有接纳新的持久意图，不设置共享冷却或凭据熔断。可继续查询和停止已接受的会话；未知 UUID 的 DELETE 收到 507 时必须保留 uncertain，不能生成取消回执。

## 授权验证与容量发现

`capabilities()` 通过携带独立 Bearer 的 `GET /v1/capabilities` 返回 `MonitoringCapabilities`。DTO 与 Go 共用 `monitoring-capabilities-v1.json`，验证协议版本、整数 Unix 秒、资源数量、重复标识与容量算式。它只证明当前服务识别此令牌并返回了授权范围，不证明真实 CPA 可达、APNs 成功或设备展示。

`MonitoringWorkspaceCoordinator.connectBridge` 先验证候选服务，再保存或替换凭据。401、403、404、网络失败及无效响应均不会替换原可用连接。成功连接后只显示服务授权清单；新建前再次核对来源、账号和数量容量，才分配 UUID 或请求本机系统活动。能力接口的 404 表示服务需要升级，不使用公开 healthz 代替验证。

候选地址的网络验证与最终凭据提交分别跟踪。候选或当前服务的只读验证在等待时，原会话仍可查询和停止；只有短暂的凭据切换阶段锁住配置。如果验证返回时原会话仍在处理控制请求，本次切换保留原连接并提示稍后再试，避免中途替换正在停止的身份。

恢复已保存凭据时标为“待验证”，先恢复原会话，不等待新的能力接口；验证入口和新会话启动才执行发现。原会话的查询和停止继续使用原身份与客户端，不依赖新能力验证成功。`MonitoringStore.lastConfirmedAt` 是最近一次接受有效 HTTP 会话响应或持久取消回执的本机时间，不等于额度观察时间，也不代表设备送达。

容量达到阈值时显示提醒，诊断中提供上次查询的计数、阈值和生成时间。此查询不预留名额，也不检查最终序列化字节预算；实际注册仍可能返回 507。v1 历史意图持续计数，不自动删除墓碑；安全回收所需的新协议合同见 [监控服务](MONITOR_SERVICE.md)。

## 共享 DTO 与内容预算

`MonitoringSnapshot` 和 `MonitoringAccount` 提供验证式公开构造器，可在取得 push token 前构造初始内容，也可用作不依赖 ActivityKit/WidgetKit 的 Codable 模型。时间按 Unix 秒数字编码，允许合法小数；缺失 observed_at 保持 nil，snapshot.expires_at 是数据过期时间，可早于 generated_at，与监控租约 session.expires_at 不同。没有原观察时间时不能用一次列表或桥接读取时间伪造新观察。

系统安全别名 id/provider/window_id 只允许字母数字及 `_ -`，最长128个UTF-8字节。显示文本 label/window_label/unit 可含中文和正常的 `% / · . -` 等已批准标点，拒绝控制字符、`@`、URL。不得填入真实邮箱、账号文件名、地址或秘密；字符验证不能代替调用方使用非敏感别名。单位保留源语义，不能把 credits 重标为 requests。

控制接口 account_ids 允许 `_ - @ .`、1–128个UTF-8字节，与系统安全别名不同。source ID 使用严格标识符规则。`activityContentData()` 限制动态内容最多3584字节，为静态属性预留512字节；未来扩展仍须检查实际 ActivityKit 静态属性和动态内容合计不超过系统预算，不得直接使用 CPA 原始对象作为 ContentState。

## 取消、切换与对账

Store 拒绝旧 revision/sequence 覆盖较新状态；同 UUID 重试失败保留已知快照，切换 UUID 不会错绑旧会话。停止后可以创建新 UUID；无法确认 end 投递的旧会话可保留在 detachedSessions，而不是静默遗忘。

配置切换将旧会话 UUID、旧客户端和最后已知会话放入 detachedSessions，按唯一 handle 调用 loadDetached/stopDetached。可信服务的 DELETE 204 表示同 principal 的取消墓碑已持久化；Store 记录绑定原 CPAMonitorClient 和 UUID 的 `MonitoringCancellationReceipt`，随后可创建新 UUID，也可移除尚无 lastSession 的 detached 项，不再要求一个永远只会 404 的会话变成可读取状态。404、超时、507 和普通网络错误均不能生成这份回执。已取得回执的 UUID 拒绝迟到 active 结果；回执仅证明服务端取消约束，不证明 APNs end 或设备移除。`cancelPending()` 会异步发起停止，不只是隐藏迟到响应；阻止迟到 POST 重新激活仍依赖服务端同 principal 的持久墓碑。

以上跟踪是进程内状态。调用方必须持久保存所需的连接标识与 UUID，重启后结合原桥接凭据和服务端租约对账；不能为恢复方便把敏感 token 写进 UserDefaults。用户只在本机忘记凭据时，不能声称服务器监控已经结束，也不能未经同意继续保留或使用该凭据。

Go handler 实际响应生成的 `Tests/ContractFixtures/monitoring-lifecycle-v1.json` 由 Swift Store 顺序消费，覆盖显式停止、到期、配置改变、授权撤销、首次快照前到期及其重启重复读取。共享 fixtures 通过 SwiftPM resource bundle 和原生测试 target 的资源阶段加载，不依赖构建机器的源码绝对路径。

## 验证边界

本地合成测试覆盖 DTO 向量、Unix 秒、安全文本、4KiB分配策略、令牌脱敏、地址/路径、CAS、401与请求级403、429、202、错误保留、迟到响应和 detached 操作。`BACKEND_RELIABILITY_PR.md` 与 `verification/backend-reliability-20261029.json` 记录的是既有版本的历史验证。2026-11-07 审计整改的实际执行范围见 [整改交付记录](AUDIT_REMEDIATION_20261107.md) 与对应候选 SHA 的 PR Checks；新增的合成测试尚需在具备工具链的环境执行。`BACKEND_VERIFICATION.md` 中的 Swift/iOS 交叉编译是 PR #1 的历史结果，不覆盖本次改动。没有访问真实 CPA、Keychain、APNs 或 Apple 账号，也没有修改签名能力或安装 App。

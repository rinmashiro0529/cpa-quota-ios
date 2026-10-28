# Rin，Quota Monitor 独立服务

Rin，`Services/QuotaMonitor` 是仅使用 Go 标准库的独立监控服务。它接受 App 的有限期活动注册，读取服务端白名单中的 CPA 账号，把安全摘要交给 APNs ActivityKit。它不是 CPA 插件，不是开放代理，也不包含 WidgetKit 页面或设备端活动启停代码。代码、合成测试与交叉构建不等于真实服务已经部署。

## Rin，运行前边界

Rin，本轮未操作 Apple 账号、证书、描述文件、推送能力或 APNs key，未读取真实管理密钥、Keychain、签名私钥，未访问用户 CPA 或向 Apple 发送推送。下面是接入说明，不表示这些操作已执行或已获得下一轮部署授权。

Rin，入口为 `cmd/quota-monitor`，需要 Go 1.26 或更高的兼容工具链。默认监听 `127.0.0.1:8787`；非数字 IP 监听地址被拒绝，非 loopback 地址必须配置完整 TLS 证书/私钥对。外部客户端包括 Swift 客户端应通过可信 HTTPS 地址接入；只在本机测试时使用 loopback 明文监听。TLS 至少 1.2，拒绝来源重定向，不提供跳过证书验证选项。

```powershell
go -C Services/QuotaMonitor build -o ../../artifacts/quota-monitor.exe ./cmd/quota-monitor
.\artifacts\quota-monitor.exe -h
.\artifacts\quota-monitor.exe -config <operator-owned-config.json>
```

```sh
./quota-monitor -config /etc/quota-monitor/config.json
```

Rin，示例为 `Services/QuotaMonitor/config.example.json`。复制到由操作者保护的配置位置后再填写；不要覆盖示例、把真实配置提交到 Git，或在命令行参数中放秘密。命令行只接受配置文件位置；相对 state/TLS 文件路径以配置文件所在目录为基准。配置最多 1 MiB，拒绝未知字段和第二份 JSON。无配置、无效配置和启动错误只输出泛化错误，不回显秘密或 CPA 响应。

## Rin，配置与秘密

| 字段 | 合同 |
| --- | --- |
| `listen` | 默认 `127.0.0.1:8787`；对外监听需 TLS |
| `state_path` | 加密状态文件；建议专用 `.state/` 目录 |
| `state_key_env` | AES 密钥所在环境变量的名字 |
| `dry_run` | 为 true 时禁 APNs，但不禁有活动时的 CPA 采集 |
| `tls_cert_file` / `tls_key_file` | 可选完整配对；非 loopback 必填 |
| `sources` | 固定来源、管理密钥环境变量名和账号白名单 |
| `principals` | 桥接身份及允许的 source/account 范围 |
| `apns` | 非 dry-run 时所需的推送环境和密钥变量名 |

Rin，配置只保存环境变量名，不保存秘密。示例变量如下；本轮没有为真实服务设置这些变量。由操作者使用受保护的服务配置或秘密注入方式提供，避免 shell history、终端录屏、日志和仓库。

| 环境变量 | 内容 |
| --- | --- |
| `QUOTA_MONITOR_STATE_KEY` | 标准 Base64 编码，解码后恰好 32 字节的随机 AES 密钥 |
| `QUOTA_MONITOR_CPA_KEY` | 对应固定来源的 CPA 管理密钥 |
| `QUOTA_MONITOR_BRIDGE_TOKEN` | 独立桥接 Bearer token，至少 32 个可打印 ASCII 字符，无空白 |
| `QUOTA_MONITOR_APNS_KEY` | PKCS8 P-256 私钥 PEM 内容，而不是文件路径；仅非 dry-run 读取 |

Rin，桥接 token 不能复用管理密钥或活动 push token。每个 principal 的环境变量名及实际 Bearer 值都必须唯一；principal 只能读取配置授权的来源和账号。状态密钥应稳定并单独备份，丢失或替换会使旧状态无法解密；不得通过删除状态来掩盖恢复失败。操作者更换秘密、来源或授权后应受控重启，而不是假定运行中的配置会热更新。

Rin，持久化使用 AES-256-GCM、随机 nonce、认证头 `QMON1`、临时文件、文件同步、原子替换和单写者 OS 锁；单个状态文件上限 32 MiB。Unix 状态目录不得 group/world 可写，文件按 0600 创建并同步目录。Windows 使用独占锁和 write-through 替换，但程序不替操作者配置目录 ACL，须预先确保仅服务身份可访问。不要将状态放入共享可写目录、公开同步盘或仓库。底层落盘出现不确定结果时，服务停止采集并返回 503，包括 `/healthz`，需要检查存储后恢复，不能继续假报健康。

## Rin，来源、身份、窗口和单位

Rin，`sources[].base_url` 必须是安全 HTTPS URL，可含反代前缀，也接受末尾 `/v0/management` 的规范形式；禁止 URL 内凭据、查询、片段、点路径和编码路径。一个进程的配置不允许重复 canonical HTTPS origin，以免同一服务绕过共享冷却。调用方不能提交 URL、管理密钥、provider 或任意上游请求，来源仅使用服务端配置。管理请求最多三路，同来源采集合并；HTTP 单响应最多 4 MiB，单次 HTTP 上限 75 秒，采集轮次 240 秒。

Rin，`accounts[].id` 是真实 inventory 账号标识，按 CPA 合同的 id/name/auth_index 选择，不按邮箱、昵称或 Source 强配。`safe_id` 与 `label` 是另行配置的非敏感系统显示别名；真实 id 可以用于授权控制，但不进入 APNs 快照。每轮重新核对 inventory 的 provider、禁用状态和身份映射；不可用账号不能从服务层的旧快照重新拿回旧值。auth_index/owner等身份变化通过不含原始身份内容的指纹贯穿读数和加密状态，即使恢复后新读取失败，也不能跨身份回填旧值；该指纹不进入公开HTTP或APNs快照。

| 账号字段 | 用途 |
| --- | --- |
| `provider` | inventory 中真实 provider，例如 `codex`、`xai` 或插件实际名称 |
| `reader` | 读取/解析类型 `codex`、`xai`、`plugin`；为空时采用 provider |
| `selection` | 单一明确窗口或指标，不能跨窗口相加 |
| `window_id` / `window_label` | 安全的配置窗口标识与显示文字，不是自动证明的上游稳定 ID |
| `unit` | 可选预期单位，不是改名模板；实际单位不同则不显示读数 |

Rin，Codex reader 支持 `primary`、`secondary`，经管理 `api-call` 读取固定额度路由，并在可用时带经 inventory 核对的 `Chatgpt-Account-Id`。xAI reader 支持 `monthly`、`monthly-limit-usd`、`used-usd`，USD 与 cents 的归一化由纯函数和共享向量验证。插件 reader 通过 `quota/fetch` 直接读取，不套 Codex envelope；实际 provider 不能为了使用插件读取而改写成 `plugin`。

Rin，插件选择支持 `summary:N` 与 `bucket:I:J`。这些数字是返回数组中的位置，不是强稳定窗口身份；操作者必须先核对真实响应并固定配置，上游重排后应停止监控并重新核对，而不是继续声称是同一窗口。本轮未连接用户实例，因此未证明其 provider、窗口顺序、插件版本或返回结构。

Rin，比例与值是不同合同：无明确上限的 summary 指标不造百分比，已超额的来源不通过跨窗口相加掩盖；系统 `remaining_fraction` 是限幅后的剩余图形，不能代替 App 内原始超额语义。实际单位缺失时不靠配置补造，`credits` 不会被改叫 `requests`；有值但单位未知/不符则标不可用。普通临时失败保留旧成功值及原 `observed_at`，不以清单读取、桥接读取或重新推送时间冒充源观察时间。

Rin，管理层 401/403 熔断整个来源，直到受控进程重启并修复凭据，不会一小时后自动开路。管理外层 429 阻断整个来源，尊重秒数或 HTTP-date `Retry-After`；代理返回的上游 429 仅作用于对应账号。冷却到期只表示可再次尝试，不代表数据已恢复。匿名 CAP Usage 资源读取是 Swift 端另一条显式鉴权合同，不由本服务代替。

## Rin，HTTP v1

Rin，除最小 `/healthz` 外，所有路由都需要 `Authorization: Bearer <bridge-token>`。控制响应不含 push token、管理密钥、原始响应或内部 principal。版本为 1，JSON 使用 snake_case，时间为 Unix 秒数字。完整 Swift 接入见 `MONITORING_SWIFT_BACKEND.md`。

| 路由 | 成功与关键失败语义 |
| --- | --- |
| `POST /v1/monitoring/sessions` | 201；等价规范化请求幂等，不同意图 409；无权限 403；已写墓碑拒绝迟到创建 |
| `GET /v1/monitoring/sessions/{id}` | 200 当前会话；其他 owner 或未知 ID 返回 404 |
| `PUT .../{id}/token` | `push_token` 与 expected-current `revision`；成功加一，旧版本/溢出 409 |
| `POST .../{id}/refresh` | 202 当前会话，只表示意图已接受；合并来源采集并守节拍，不表示采集/推送完成 |
| `DELETE .../{id}` | 已知会话 200，停止版本递增且落盘后发送 end；未知 UUID 在当前 principal 下持久墓碑并 204 |
| `GET /v1/sources/{sourceID}/quota` | 200 授权缓存；无缓存 404，不触发网络；不跨 session 直接用 sequence 选新旧 |
| `GET /healthz` | 200 最小健康；存储不确定或服务停止时 503 |

Rin，注册字段为 `id`、`source_id`、`account_ids`、`duration_seconds`、`activity_id`、`push_token`。id 为标准 UUID，大小写规范化；account_ids 为 1–5 个已授权标识；租约仅 3600/14400/28800 秒。JSON 空格、键序和 UUID/token 大小写不产生假冲突，账号数组顺序仍是活动意图的一部分。重发原注册不会延长租约，token 轮换也不延长租约。未知 DELETE 的墓碑按 principal 隔离，另一个身份不能预占或结束已有 owner 的 UUID。

Rin，push token 必须是非空、偶数长度十六进制，最多 4096 字符，不假设固定 32 字节。注册和 token 更新都拒绝未知字段、尾随 JSON 和超大请求体。活动显示组合在注册时检查最坏动态内容预算；单字段合法不代表五个长别名组合一定能放进系统活动。

Rin，session `revision` 只随控制变更递增；采集增加 `snapshot.sequence`，不改变控制 revision。`snapshot.expires_at` 是数据期限，可能早于 `generated_at`；`session.expires_at` 是租约终点，二者不能混用。安全 id/provider/window_id 仅允许字母数字与 `_ -`，显示 label/window_label/unit 另允许正常空格、`% / · . -`，都限制 128 UTF-8 字节并拒控制、邮箱及 URL。控制 account_ids 可额外含 `@ .`，但不能因此直接用作系统显示别名。

## Rin，调度、取消和推送失败

Rin，服务每秒扫描到期，但同来源采集目标间隔为 600 秒，以轮次开始时间计算，不是每秒采集。首次自动采集在注册后约 600 秒；第一次手动刷新可立即启动，之后不得绕过来源节拍或 CPA 冷却。并发活动共享一次来源读取，取有效活动授权账号的并集；错过的轮次不补发全套历史采集。没有有效租约时停止来源采集，最后一个订阅停止会取消来源作业；其他仍有效订阅不被一并取消。

Rin，update、token 轮换、end 按活动串行化；发送前后复核控制版本、数据序号与租约，旧回调不能给新快照标记 sent。停止或过期后不发布迟到 ready 结果，先落盘终止意图再发 end；即便还没采过快照，也能发安全的终止内容。服务重启不延长租约，恢复时重新核对当前授权；来源或账号窗口配置的指纹变化时清除旧快照，而不是将旧值重新贴上新窗口/单位标签。

Rin，APNs 使用 PKCS8 P-256/ES256 JWT，缓存 50 分钟；按服务器固定 sandbox/production 和 `<main-bundle>.push-type.liveactivity` 主题，经 HTTP/2 以 priority 5 发送 update/end。动态 content-state 最多 3584 字节，为静态属性留 512 字节；整个 APNs body 还受 4096 字节约束。end 带即时 `dismissal-date`，但 APNs 200 仍仅表示接受，不证明设备展示或移除。

Rin，推送状态独立于采集状态：`disabled` 表示 dry-run，`pending` 表示当前快照尚未确认接受，`sent`/`ended` 表示 APNs 接受，`failed` 表示发送失败。新快照不会继承上一次 sent。传输错误和 APNs 429/5xx 使用按活动持久化的 60/120/240/480/600 秒退避，显式 `Retry-After` 更晚时优先采用；重复 DELETE 和进程恢复不能缩短该期限。到期扫描可重发仍有效活动的最新快照，或已停止/过期活动的 end，不为重发另采一次 CPA。永久 4xx 不自动高频重试，修复配置或活动 token 后由控制操作对账。此退避是按活动的，不是经负载验证的全团队限流器。

Rin，`SIGINT`/`SIGTERM` 会取消来源、等待本服务工作并关闭 HTTP；不 killall、不重启共享容器。正常退出不等于所有设备活动已结束，未终止的租约按加密状态恢复，终止的 pending/可重试失败由到期扫描继续对账。设备离线、强退、系统预算、网络延迟与 APNs 限流都可能造成延迟；600 秒不是设备必达 SLA，活动最长持续时间也仍受 ActivityKit 平台规则约束。

## Rin，验证和未完成的真实环境验收

```powershell
python -I -X utf8 -B tools/test_monitor_backend.py --project <project>
```

Rin，工具只运行合成测试、`gofmt -l`、`go vet`、`go test -race`、Windows/当前平台构建、Linux amd64 交叉构建和无配置帮助命令，将源码清单、哈希、逐项退出码、测试计数及二进制哈希保存到新的 `artifacts/backend-verification/*-go/`。缓存、真实配置、加密状态与二进制不进入源码清单；未部署或向真实 APNs 发请求。准确的最终结果和失败历史见 `BACKEND_VERIFICATION.md`，不能仅凭本说明认定已通过。

Rin，真实接入尚需另外授权和验收：确认用户 CPA/插件协议及鉴权、选定稳定账号/窗口与非敏感别名、服务器 TLS/ACL/备份、APNs 身份/主题/环境、设备 token 与活动扩展，以及后台/锁屏/常亮/强退/离线/过期/轮播。Linux 交叉编译不等于 Linux 实机运行，更不等于 Apple 真机验收。原有 App 安装、main、共享证书和团队资源均不因本地后端源码交付而改变。

# 后端实现与验证回执

公开资料中的环境标识已泛化；文中本地回执和二进制仅存原验证环境，除明确列出的仓库摘要外不保证可以下载。

本文件记录本地分支 `feature/backend-monitoring-20261028` 的最终源码验收证据。App 业务后端与独立 Go 服务已完成本轮编码、合成回归和构建；真实部署、Apple/APNs 身份、设备活动与前端呈现仍未验收，不能宣称系统灵动岛功能已经上线。

## 权限与交付范围

基线 main 为 `3abffebf8f47699f426332da557845c4bf25e54d`。后端开发验收阶段未执行 Git add/commit/push；用户随后另行授权将本轮新增成果提交 PR。没有触发 GitHub CI，没有部署、签名、安装或启动 App，也没有操作 Apple 账号、能力、证书、描述文件、APNs 密钥或团队权限。真实 CPA、管理密钥、Keychain 和 APNs 均未用于测试。用户要求停用 Codex 后，没有再调用或恢复 Codex；取消的实现不算成功交付。

App 业务后端包括 CAP 只读资源、固定30分钟窗口、逐模型基础计数与严格加权 TPS、可观察概览/详情状态、共享管理请求资格、刷新事件与单账号操作、候选连接保留、健康/新鲜度、安全身份、监控客户端与共享 DTO、独立桥接凭据存储。前端布局、WidgetKit 页面、真实账号轮播和系统 Live Activity 启停呈现不在本轮范围。

## Swift 最终源码

| 项目 | 已观察结果 |
| --- | --- |
| 完整 Swift Testing 回归 | 233项、38套件通过，exit 0 |
| 归档 SHA256 | `82783e9f365cda5f4b001d04ca2425674eecf88bd09c94d615edc4e42589b589` |
| 完整回执 | `artifacts/backend-verification/20261028-155108-d3da4208-test/result.json` |
| 远端隔离目录 | 原验证环境中的隔离目录 |
| 原生测试接线 | 32个 SwiftPM 测试文件、32个原生测试文件，无遗漏/悬空/重复/额外非测试源 |
| Swift 源计数 | 74（包含 Package.swift，与既有计数合同一致） |
| 接线校验器单元检查 | 5项通过 |
| 最终 iOS device 交叉编译 | CPAQuotaApp及依赖通过，exit 0；`20261028-155217-9b8e7cb9-device/result.json` |
| 最终 iOS simulator 交叉编译 | CPAQuotaApp及依赖通过，exit 0；`20261028-155315-0435a234-simulator/result.json` |

```powershell
python -I -X utf8 tools/test_backend_nwd.py --project <project> --host BUILD_HOST --container BUILD_CONTAINER --mode test
python -I -X utf8 tools/test_backend_nwd.py --project <project> --host BUILD_HOST --container BUILD_CONTAINER --mode device --target CPAQuotaApp
python -I -X utf8 tools/test_backend_nwd.py --project <project> --host BUILD_HOST --container BUILD_CONTAINER --mode simulator --target CPAQuotaApp
python -I -X utf8 -B ci/validate_source_layout.py --root <project>
python -I -X utf8 -B ci/test_source_layout.py
```

上述三次最终 Swift 运行使用完全相同的归档 SHA256；设备和模拟器回执均位于 `artifacts/backend-verification/`。独立身份检查重新计算76个当前文件（74个Swift/Package文件和2个JSON向量）的 SHA256，确认 `sameArchive=true`、`allExitZero=true`、`changedFiles=[]`。首次内联校验遇到 PowerShell 5.1 原生命令引号传递问题并以 NameError 失败；改用独立 Python `-I` 脚本后实际通过，未改动产品代码。

这些结果是 Linux Swift Testing 与 Darwin SDK 交叉编译，不是 Xcode Simulator 测试运行、原生签名归档或实际设备行为验收。

工具将当前 Sources/Tests、Package 和独立 JSON 合同向量打成新归档，验证 SHA256 后放入历史 Linux 构建环境容器中的新目录；使用 flock 串行、`-j 2` 和编译警告视为错误。没有复用覆盖旧工作目录、删除共享构建缓存或重启容器。SwiftPM 关于 `--build-system native` 的弃用提示是工具级警告，命令实际 exit 0；不是未披露的测试失败。

## 修复与测试依据

旧基线在本轮环境重新运行138项通过。六个旧断言与本轮批准合同冲突，已保留测试并更新为：管理清单重载不绕过401/403或管理429；候选连接失败/取消保留最后已接受连接。没有删除凭据保存、回滚、FIFO、接受和 finalize 的旧断言来获得通过。

CAP 独立通道在取消任务修复后34项、10套件通过，回执 `artifacts/backend-20261028-1038/usage/20261028-101946-0a7ee273-test/result.json`。随后完整工程包含这些测试。覆盖实际固定版请求字段、计数缺失不归零、失败部分用量、31.25 TPS 向量、provider/stream 分组、匿名与管理认证、双向管理熔断、资源429、分页重复/total变化、10页/5000条、8MiB保守预留、4MiB响应限制、详情整批发布、失败保留、取消和新窗口中止旧分页。

主会话新增修复有可追溯行为红绿：已含 reasoning 的 provider 缺无关字段、完整计数保留、请求详情字段保留、迟到 HTTP 成功的取消检查、匿名资源429、逐模型基础计数、详情批次、旧刷新停止翻页，以及冷却到期不能假报连接恢复。编译错误（包括并行文件在途、测试可见性）不计行为红。部分既有代理新增回归是在实现后补写，不能称为所有代码全程 TDD。

健康 DTO 独立区分重试资格、连接结果与数据新鲜度；冷却到期只允许重试，旧错误未获成功重试前仍保留失败。最后修复的行为红回执为 `artifacts/backend-verification/20261028-102828-31a29bee-test/result.json`，绿灯纳入先前232项回归，并继续通过当前233项完整回归。桥接请求级403不会阻止合法会话停止的新增回归先红（`20261028-105524-c857f455-test`），修复后也纳入同一份最终源码。

桥接凭据测试使用内存存储与合成传输验证独立命名空间、原管理凭据不被替换、路径隔离、失败保留和无 Security 框架时拒绝明文回退。Linux 的六项测试不是 iPhone Keychain 安全访问组或锁屏实际行为验收；原管理 Keychain service 和 `WhenUnlockedThisDeviceOnly` 未变。

## 独立合同与 Go 状态

共享独立向量为 `Tests/ContractFixtures/monitoring-v1-session.json` 与 `quota-parity-v1.json`。最终 Swift 测试已直接从磁盘读取两份向量，不再只使用内嵌会话副本；7项定向合同测试通过，随后纳入233项全量及同归档双端编译。Go同样实际读取这两份文件。监控时间是 Unix 秒数字，数据过期时间和监控租约不同；token revision 是 expected-current CAS，成功加一；未知 UUID DELETE 要求授权 principal 下持久取消墓碑。一次 HTTP/APNs 接受不证明设备展示或移除。

Go 独立服务已实现完整入口、白名单配置、principal 控制 API、来源级采集、加密恢复、租约终止、APNs update/end 和持久化推送退避；不是原先仅两个纯函数包的切片。当前验收回执为 `artifacts/backend-verification/20261028-160336-bedc5de3-go/result.json`，源码清单 SHA256 为 `660dd6cff10512f5a6439362756ce531005a64bd0f8d3a8bbab98af82dbe213b`，25个 Go 文件及模块/样例/两份共享向量/验收工具共30个清单文件，运行期间无漂移。

| Go 检查 | 已观察结果 |
| --- | --- |
| 工具链 | `go1.26.2 windows/amd64` |
| `gofmt -l` | 无待格式化文件，exit 0 |
| `go test -json ./... -count=1 -timeout=90s` | 93项（含子测试）、5包通过，0失败/跳过 |
| `go vet ./...` | exit 0 |
| `go test -race ./... -count=1 -timeout=90s` | 5包通过，exit 0 |
| 当前 Windows 构建 | 真正 `cmd/quota-monitor`，exit 0；无配置 `-h` 正常 |
| Linux amd64 交叉构建 | `GOOS=linux GOARCH=amd64 CGO_ENABLED=0`，exit 0 |
| 本地 TCP 运行 | 合成环境、dry-run、无活动；健康200后取消正常退出的回归通过 |

```powershell
python -I -X utf8 -B tools/test_monitor_backend.py --project <project>
```

二进制位于上述回执同目录：`quota-monitor.exe`（SHA256 `d35091754979ed3281c7ebbd72777a7b96582cb5200f5ba3c5004af3376813bf`）及 `quota-monitor-linux-amd64`（SHA256 `d04a97ac0066fbb16577c80d1ff8dfda73a41b655d6d6cc148506477d4fd007b`）。这些是未部署的本地验收产物，不是 IPA 或服务器线上版本；Linux 仅交叉编译，未做 Linux 实机运行与文件系统故障测试。

Go 回归包括规范化幂等、expected-current CAS、owner隔离、principal墓碑、恢复撤销授权、源配置改变清缓存、加密篡改拒绝/单写者、持久失败关闭、并发刷新合并、600秒节拍、租约到期end、迟到采集拒绝、update/end串行、失败旧观察时间保留、不可用账号清值、单位不伪造/改名、源缓存时间选择、最坏payload及Swift斜杠转义预算、APNs HTTP/2/JWT/大小和end dismissal、持久化Retry-After与恢复重试、CLI帮助及运行退出。

首次本轮整体验收 `20261028-152917-f37f1c54-go` 中测试/race/双平台构建通过，但 vet 因测试里复制无用途 `sync.Once` 失败，整体明确判 failed；移除残留后重新全量通过。之后新增跨端预算和配置隔离回归，以上93项回执才是对应当前Go源码的结果。APNs退避新增后旧“立刻重试”的测试按新合同增加等待检查，仍保留不改变租约和控制版本的断言。

独立只读复核后，主会话另用HTTP回归复现：auth_index/owner改变且新读取失败时，适配器虽已清缓存，服务层仍可能回填旧身份值。现已将opaque SHA256身份指纹贯穿CPA读数、runtime映射及加密会话记录；不同指纹不能回退旧值，指纹不进入HTTP/APNs公开快照。普通同身份失败仍保留旧值和原观察时间，恢复后的身份轮换隔离回归通过。302在Go安全地归为非阻断failed，不跟随重定向；Swift具有更具体的redirectRefused错误，错误名称不完全一致，不声称两端所有错误枚举相同。

源码清单的定向敏感模式检查未发现常见私钥正文、GitHub/provider token格式，Git枚举清单也未包含真实配置、加密状态、`.test-work`缓存或二进制；这不是全面秘密检测的证明。原生工程diff只增测试引用，CI只改动态源码计数，签名、能力、触发权限未变。`git diff --check`通过；Git提示LF未来可能转CRLF属于工作区行尾提示，未为消除提示改写无关文件。

最终独立身份复核另存 `artifacts/backend-verification/final-identity-20261029.json`，实际结果为 passed：Swift三次归档相同且exit 0，76个Swift/向量文件及30个Go/配置样例/工具文件与当前清单一致，两个共享向量的跨端哈希相同，源码与两个二进制均无漂移。这份记录核对的是编译/测试输入和产物，不把文档、真实服务配置或设备状态当作已验证源码。

可随 PR 查阅的脱敏验证摘要为 `docs/verification/backend-20261029.json`，保留本地回执来源、输入文件哈希、检查退出码及产物哈希，不含原始日志、绝对机器路径、凭据或二进制文件。它记录已经完成的本地验证，不表示 GitHub Actions 或真实环境验收已经运行。提交前逐文件核对确认，Git索引与已测工作区的差异仅为CRLF转LF；摘要另列发生行尾规范化的测试输入及仓库内哈希，区分原验收字节哈希和Git保存的字节哈希，未修改Git配置或产品逻辑。

## 接入文档与剩余真实环境验收

- `CAP_USAGE_BACKEND.md`：资源鉴权、计数、速度、分页和状态。
- `MONITORING_SWIFT_BACKEND.md`：监控 DTO、会话控制、取消与对账。
- `MONITOR_BRIDGE_CREDENTIALS.md`：凭据隔离和安全存储合同。
- `MONITOR_SERVICE.md`：独立服务配置、运行、reader/provider、单位、推送退避与真实部署边界。

未验证的真实环境项目包括：用户实例插件版本与资源鉴权、部署 TLS/代理、CPA 实际响应、APNs 身份与推送环境、设备网络及省电/强退下的送达、ActivityKit 内容预算和轮播呈现。600秒是服务端采集目标，不是 Apple 或设备必达承诺。当前安装包和旧 main 不被本轮本地分支改动替换；回退不涉及删除 Keychain、卸载 App 或撤销团队资源。

# 后端可靠性专项改动与验收记录

> **历史记录**：首次提交 2026-10-29（`83a6d1a`）；本文可能包含后续补充，仅反映所述时期及版本，测试结果不代表当前提交。当前入口见 [README](../README.md)。

日期：2026-10-29。实现基于 PR #1 的 `80e469520712dbb1b2e70e5d3d4247d3b9728366`，以 `feature/backend-monitoring-20261028` 为目标分支。当时的 main 尚不包含独立监控服务，故此改动作为依赖 PR #1 的后续 PR 审查。审计编号沿用本次技术审计；下表同时写出问题本身，阅读本 PR 不依赖另行取得审计文件。

## 目标和设计选择

修复已经有代码路径或本地复现支持的状态机、取消、调度、容量、推送和解析问题。保留已验证的 HTTPS 白名单、principal 授权、CAS、AES-GCM 文件存储、单写者锁、来源协调器与纯解析模块。主要结构调整集中于来源调度入口、投递状态生命周期和有界准入；没有引入第三方运行时依赖。

| 审计问题 | 改动 | 关键验收行为 |
| --- | --- | --- |
| F01 终态内容变更破坏 Swift 单调校验 | stop/expiry/config change 使用递增快照序号；配置变化终止旧语义会话；撤权生成脱敏终态占位 | Swift 接受服务实际生成的五类终态，拒绝随后重放的旧 active；重启不重置或重复增加版本 |
| F02 DELETE 204 后未知会话无法退出对账 | 引入绑定原 client 与 UUID 的取消回执 | 204 后可创建新 UUID、清理 nil detached；404/超时/507 不冒充成功 |
| F03 慢采集阻塞租约与重试扫描 | 周期扫描提交来源单飞 worker，不等待采集完成 | 阻塞 collector 时仍能结束其他到期租约；关闭取消并等待 worker |
| F04 历史无限增长最终使整个服务 503 | 全局、principal、序列化预留预算在同一锁内准入；门锁引用归零后释放 | 容量满仅拒绝新意图并返回 507；既有查询、停止、幂等操作及健康检查可用；并发准入不超配 |
| F05 Go 丢失 envelope Retry-After | 统一 header/headers、大小写、标量/数组与状态码合同 | 两端消费同一组 28 个向量；冷却前不增加上游请求 |
| F06 失效 APNs token 被新快照重新激活 | 固定失效原因持久化；区分设备 token 与 provider JWT；相同 token 的晚到拒绝跨内容版本生效 | 新采集、重启、过期不重新发送失效 token；不同 token 的合法 CAS 才可恢复；旧 token 结果不污染新 token |
| F07 数组位置被误当稳定窗口身份 | 插件只允许精确且唯一的 `summary-key:<key>` | 同单位指标重排仍选中原窗口，缺 key/重复 key 不产生新成功读数 |
| F08 管理熔断被批量刷新伪装为缓存成功 | 向批量调用者传播 management-blocking 错误 | 暖缓存后 401/403/429 仍失败，不发成功回调或新 quota 请求 |
| F09 CAP reasoning 口径优先级错误 | 明确 included → separate → generic included 顺序 | provider/executor 冲突按上游优先级处理；加权 TPS 与完整性测试保留 |
| F11 原生测试依赖构建机源码路径 | SwiftPM/native 测试 bundle 复制共享 fixtures | 从 bundle 读取；Go handler 的实际生命周期响应与 Swift Store 交叉验证 |
| F12 PR 没有自动验证 | 新增只读 PR/main workflow | Go test/race/vet、跨平台编译、SwiftPM、iOS native tests 与 app build；没有 release 或部署动作 |
| F16 数字身份经 Double 转换丢失精度 | 先保留原始整型 NSNumber 表示，再验证安全范围 | 超界、浮点、小数、布尔身份拒绝；大整数以字符串保持精确；指标解析不变 |

## 本地实际执行

| 检查 | 结果与范围 |
| --- | --- |
| Go 1.26.10，`go test -json -count=1 ./...` | 通过：5 个 package，109 个顶层测试；包含子测试的 pass 事件为 184，不把两个数字相加 |
| `go test -race -count=1 ./...` | 最终 Go 源码全部 5 个 package 通过 |
| `go vet ./...`、`gofmt -l .` | 通过，格式检查输出为空 |
| Linux amd64 / Windows amd64 `go build -trimpath` | 均编译通过；Windows 为交叉编译，没有执行 Windows 测试 |
| Swift 6.2.4，Swift 6 mode，warnings-as-errors | Linux SwiftPM 250 个测试、38 个 suite 通过 |
| 源码成员验证与其 Python 测试 | native/SPM 均 32 个测试源文件；74 个 Swift 文件；5 项验证器测试通过 |
| 共享合同 | 28 个 envelope 向量；5 类 lifecycle × 3 个实际 handler 响应；bundle 中 4 个 JSON 文件与源文件哈希一致 |
| 身份精度红绿回归 | 中间解码器实际出现 20 个失败断言，保留整型来源后完整套件通过；这不是未经修改的 PR #1 基线测试 |
| `git diff --check`、JSON 与 workflow YAML 解析 | 通过 |

Go 官方归档已核对 SHA-256，Swift 6.2.4 归档已验证 Swift 6.x 发布签名；工具链与缺少的 Ubuntu 运行库放在隔离目录。普通沙箱最初禁止创建 loopback socket，获准后使用本地 TLS 假服务完成测试。没有使用真实用户秘密、真实 CPA 或 APNs 请求。Linux SwiftPM 无法验证 `canImport(SwiftUI)` / Apple Security 路径、原生测试 bundle、模拟器或真机。

对应源码和验证日志的 SHA-256 回执见 [verification/backend-reliability-20261029.json](verification/backend-reliability-20261029.json)。GitHub CI 的实际状态应查看本 PR 当前 head 的 Checks；本文件记录本地执行结果，不将新增 workflow 视为已经在 macOS 上通过。

常规复现命令：

```sh
cd Services/QuotaMonitor
go test -count=1 ./...
go test -race -count=1 ./...
go vet ./...
gofmt -l .
```

```sh
swift test -j 2 -Xswiftc -warnings-as-errors
python3 -I ci/validate_source_layout.py --root .
python3 -I ci/test_source_layout.py
```

生命周期 fixture 只有在审查过合同变化后才重新生成：`UPDATE_MONITORING_FIXTURES=1 go test -run '^TestMonitoringLifecycleFixtureMatchesServiceResponses$' .`（在 Go 模块目录）。普通测试从实际 handler 重新计算结果并比较已提交 fixture，不重写它。

## 首次自动 CI 的平台反馈

初始三个提交的 head 为 `83a6d1a00d5ce4adff1b625e1ca556cb19ab2c4f`，上面的本地验证和源码哈希对应这一实现快照。[首次自动运行](https://github.com/rinmashiro0529/cpa-quota-ios/actions/runs/40831960571) 实际选择 Xcode 26.2 / Apple Swift 6.2.3，通过源码成员检查后，在 macOS SwiftPM 编译登录页时发现 iOS 专用 `textInputAutocapitalization` 未受平台保护。该次 macOS job 失败，未执行后续 native tests，不能当作 Apple 验证通过。

后续最小补丁为两个输入框的这一 modifier 增加 `#if os(iOS)`，保持 iOS 行为。此 Apple 分支修复以当前 head 的实际 CI 为验收依据；没有为此新增无法覆盖该平台的 Linux 测试。历史 PR #1 的交叉编译回执不覆盖新源码。

## 升级条件

1. 将插件位置选择器迁移为 `summary-key:<key>`。缺少稳定 key 或只有 bucket 的上游目前不支持监控；不要机械地把数组下标拼成 key。
2. 评估 retained sessions、tombstones 和各 principal 的历史意图量。默认上限分别为 1024、4096、256；既有超额状态会拒绝启动且保持文件不变。空间预算考虑未来 token/快照增长，调高计数并不绕过 32 MiB 文件预算。
3. HTTP 仍为 v1。APNs token 失效会把该条持久记录升级为 v2；之后使用兼容 v2 的修复版本或前向修复。旧二进制不能读取这种状态，不能删除字段、重置版本或恢复陈旧备份来绕过已确认的取消记录。
4. 上游数值账号身份必须是安全范围内的原始整型表示；大整数、`42.0`、`4.2e1` 等应作为字符串传输。数值额度和金额保持原有表示。
5. macOS SwiftPM、原生 iOS 测试与 app build 必须通过当前 PR Checks。设备端 ActivityKit、APNs 配置、生产部署和真实 CPA 合同验收仍是后续独立工作。

## 已知剩余边界与回退

v1 注册没有可验证的重放期限，安全的历史回收不能直接添加 TTL。本次提供有界准入和存储预留，保留历史墓碑与终态记录；有限容量耗尽后需要受控升级或后续版本化回收方案。历史 push token 的擦除与回收也没有在本次实现。服务仍是单写者文件存储，未设计多个实例共享同一状态并发调度；APNs 重试仍按活动退避，未经大规模负载验收。

上线前可直接撤回代码 PR。若尚未产生 v2 状态，回退也必须保留升级期间新写入的取消/终态事实，并使用支持当前选择器和容量合同的版本。出现 v2 后只能使用兼容该格式的回退版本或前向修复；不提供破坏性自动降级脚本。

UI 凭据编辑、标题隐私、原生 Keychain 重启清理、可访问性及页面刷新范围等审计项保留在后续工程清单。本 PR 的通过不等于整体产品已完成全部审计整改，也不表示设备已收到 APNs 更新。

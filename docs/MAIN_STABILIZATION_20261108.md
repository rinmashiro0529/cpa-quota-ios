# 主线稳定化与公开协作状态

本记录固定于合并基线 `a0914ffd77e708fb9485e816495aacee88a8de2a`，不是实时 CI 仪表盘，也不宣称全部安全或发行门禁已经通过。后续候选的 SHA、run、attempt 和最终结论应从对应 PR 与 GitHub Actions 回执核对。

## 已核对的起点

PR #12 与 #13 已合入主线。PR #13 最后候选 `40f15dcafa8fbe4d869bbed2b819c74095760841` 的 [运行 42395828868](https://github.com/rinmashiro0529/cpa-quota-ios/actions/runs/42395828868) 四个作业成功。合并提交 `a0914ffd` 的 [运行 42398161811](https://github.com/rinmashiro0529/cpa-quota-ios/actions/runs/42398161811) **attempt 1** 中，Go、iPhone 17 Pro 和 iPhone 18 Pro 成功，iPhone Duo 的原生测试步骤失败。

Duo 日志记录八项 UI 测试零断言失败，但 xcodebuild 仍报告测试运行器在建立连接前挂起并以 65 退出；同时出现模拟器服务连接异常。因此该作业整体仍为失败，不能只抽取“八项通过”作为完整成功。该现象支持进一步检查运行器启动过程，不证明所有业务代码均无缺陷，也不保证再次运行必然成功。后续 attempt 必须独立核对，原始失败记录保留。

仓库已经公开；读取到的 `main protected=false`，规则集返回空列表。公开状态不会自动启用分支保护或私密漏洞报告。规则与报告渠道状态需另行获取管理端证据。

## 本轮代码边界

`ci/prepare_simulator.py` 在原生测试前读取既有 `simulator.json`，验证明确的 UUID、运行时、设备名和可用性。它使用 `simctl bootstatus <UUID> -b` 等待启动完成，所有命令共享 300 秒墙钟预算，之后再次核对同一设备及 Booted 状态。

预检输出 `simulator-readiness.json` 和独立启动日志，沿用现有 CI 证据上传。开始执行时替换陈旧成功报告；失败、超时、设备身份改变或缺少工具都会非零退出。它不清空、删除、重置或替换设备，不选择旧系统降级，不自动重跑测试，不把启动就绪等同于 XCTest 或 APNs 通过。

既有四项 CI 作业名称、Swift/Go 测试、原生 UI 断言、扩展验证和未签名 Release 构建均保留。原生测试仍只运行一次，并通过 `pipefail` 保留 xcodebuild 的非零结果。启动预检可以提前暴露或减少冷启动问题，不能保证修复所有 Simulator service hub 或 XCTest 连接异常。

新增离线回归覆盖明确目标、身份变化、异常输入、共享超时、失败不重试、陈旧报告，以及预检顺序和规则模板检查名一致性。这些回归不启动真实模拟器；macOS 实际行为仍以新候选的原生 CI 为准。

本轮不改 Swift/Go 业务状态机、不部署监控服务、不连接真实 CPA/CAP/APNs、不操作签名材料、不发布草稿 Release、不重写 Git 历史，也不通过降低检查要求换取绿色状态。

## 仓库管理仍须单独落地

[main 规则模板](../.github/main-ruleset.example.json) 只作用于 `refs/heads/main`，要求 PR、至少一名批准者、最新推送的非推送者批准、过时批准失效和对话解决，禁止强推与删除，要求四个 GitHub Actions 检查成功且基线最新，不配置绕过者。文件合入不代表服务端规则已生效。

管理员可在 Settings → Rules → Rulesets 导入模板。**导入前必须确认有符合条件的独立审阅者**；单人仓库直接启用该模板可能阻止之后的合并，不应为了通过而默默移除批准要求或添加管理员绕过。先审查现有规则和检查名称，避免叠加重复规则。保存后读取规则 ID、enforcement、conditions 与实际 main 规则，保留回执；在隔离分支或测试仓库验证拒绝行为，不破坏 main。

私密报告按 [安全政策](../SECURITY.md) 启用并验证。GitHub 管理权限、账户政策和这些设置的实际生效，不能由仓库文件或本地单测代替。

## 公开与发行结论分开记录

| 层级 | 要求与当前证据边界 |
| --- | --- |
| 公开源码协作 | 已有公开仓库、许可证与贡献说明；仍须确认最新全部可达历史和拟公开产物无敏感信息、可验证私密报告渠道及素材授权。未补证据的项不记作通过。 |
| 代码合并 | 核对准确候选 SHA、实际检查结果和适用的审阅规则；合并后继续核对 main 的独立运行。PR 的绿色结果不能覆盖主线失败。 |
| 可安装版本发行 | 另需 iOS 17/目标设备、真实 Keychain、签名安装、APNs、辅助功能与性能验收。模拟器或未签名构建不能替代这些证据。 |

[公开准备检查表](OPEN_SOURCE_READINESS.md) 保留的 2026-11-02/03 扫描与附件记录属于历史证据。该记录不覆盖后续所有提交、所有 Actions 产物或不可达对象。本轮没有新增全历史秘密扫描或附件分发权利证明；FS-03 等既有未决项也未在本轮静默关闭。发现真实泄露时应先撤销或轮换凭据，再按范围处理公开副本，不能只删除当前工作树文件。

参考：[Xcode 命令行工具](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference)、[GitHub 分支规则 API](https://docs.github.com/en/rest/repos/rules)、[私密漏洞报告](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository)。

# 安全政策

本项目按维护者可用资源处理安全问题，不保证响应时限、持续支持、漏洞修复或不存在安全缺陷；历史验证不能替代当前版本的安全评估。

## 私密报告

本仓库现为公开仓库。请查看 [Security 页面](https://github.com/rinmashiro0529/cpa-quota-ios/security)；只有该页面确实提供 **Report a vulnerability** 私密报告按钮时，才通过该入口发送报告。私密漏洞报告功能需要仓库管理员单独启用，公开仓库或存在本文件并不证明该功能已经启用。本次维护尚未取得该入口实际可用的验证证据。

若按钮不可用，请先请求维护者提供可验证的私密联系渠道；公开 issue 只能说明“缺少私密报告渠道”，不要附漏洞利用细节、真实凭据或未脱敏日志。不要使用未在仓库中确认的邮箱，也不要把公开 issue 作为私密报告的替代。

报告应使用合成账号和令牌，说明受影响的提交 SHA、组件、复现步骤、影响及最小脱敏证据。请勿提交真实管理密钥、监控令牌、APNs 私钥、签名材料、账号信息或生产配置。

## 维护者操作与验收

在仓库 **Settings → Advanced Security → Private vulnerability reporting** 启用私密报告，并通过普通访问者能看到的入口复核可用性，再记录验证日期。具体界面与权限以 [GitHub 官方说明](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository) 为准。

公开协作、代码合并和可安装版本发行是不同的验收层级。最新主线的完整历史秘密扫描、附件分发、素材权属、设备和 APNs 验收不能由 CI 成功替代；状态与证据边界见 [主线稳定化记录](docs/MAIN_STABILIZATION_20261108.md)、[发布门禁](docs/RELEASE_GATES.md) 和 [公开准备检查表](docs/OPEN_SOURCE_READINESS.md)。

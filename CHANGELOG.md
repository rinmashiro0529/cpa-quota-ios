# 变更日志

本文件汇总已合入 `main` 的主要面向用户与维护者的演进记录；历史验证结果仅对应各自提交与运行环境，具体 CI 状态以 [GitHub Actions](https://github.com/rinmashiro0529/cpa-quota-ios/actions) 为准。

## Unreleased（`main` 自 `v1.0.0-unsigned.9f1eec8` 以来的变更）

### 新增功能
- **AI 对话工作区（PR #17、#24、#29–#34）**：
  - 支持经 CPA 读取模型目录（`GET /v1/models`）与流式对话推理（Claude 模型优先 `POST /v1/messages` 并按条件回退 `POST /v1/chat/completions`）；
  - 支持客户端 API Key 自动发现（`/v0/management/api-keys` 并在 `404`/`501` 回退 `/v8/management/config/access/api-keys`）与手动填写；
  - 支持通用思考等级选择、流式推理过程展示、中断后输入框一键续写、消息编辑、全局规则、记忆与斜杠技能；
  - 支持可选第三方联网搜索（Tavily、Brave、Exa、Serper、SerpAPI）；
  - 支持 iOS 18.4+ 静态 HTML 代码块隔离预览，以及后台约 30 秒续跑与固定脱敏完成通知；
  - 图片附件外置至 `Attachments/` 并引入 `Conversations/index.json` 索引懒加载。
- **额度总览与 CAP 用量增强（PR #16）**：展示 Codex 额度窗口并扩展 CAP 用量滚动小时/天及按月时间范围选择。
- **导航结构调整（PR #17）**：将「监控与活动」移入「连接管理」内，不再占用顶层标签页。

### 质量、安全与文档整改
- 完成 AI 对话 P0/P1/P2 安全、协议、流式性能、对比度与存储架构整改（PR #25、#30、#31、#34）。
- 优化原生 iOS CI：去重构建、启用缓存并将原生 UI 测试按分片并行执行（PR #32、#33）。
- 补齐 `Apple/PrivacyInfo.xcprivacy` 文件时间戳 API 声明（`C617.1`）、全量 SwiftPM 第三方许可声明（`THIRD_PARTY_NOTICES.md`）、`docs/AI_CHAT.md`、`.github/ISSUE_TEMPLATE/`，并按 `docs/COPY_STYLE.md` 同步修正界面与文档文案。

## Pre-release `v1.0.0-unsigned.9f1eec8`（2026-11-09）

- 公开首个未签名预发布 IPA（`CPAQuota-unsigned.ipa` + `SHA256SUMS.txt`，基于源码提交 `9f1eec8`，不含签名与描述文件，需自签名安装）。
- 包含原生 iOS App（`icu.nahida.cpaquota`）、Widget / 实时活动扩展（`icu.nahida.cpaquota.activity`）、CAP Token Usage Tracker 只读统计接入，以及可选的独立 Go 监控服务。
- 引入持续秘密扫描门禁（`readiness-audit.yml`）、Duo 展开内屏冒烟验证（`duo-inner-display.yml`）与公开文案检查（`ci/validate_public_copy.py`）。

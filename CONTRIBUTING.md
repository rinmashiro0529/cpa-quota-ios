# 贡献指南

项目使用 [MIT 许可证](LICENSE)；请仅提交自己有权以该许可证授权的代码、素材及其他材料，并核对第三方材料的许可义务。

请保持变更最小、说明动机与验证结果，使用合成夹具和最小复现；不要提交真实凭据、账号、生产配置或私有日志。安全问题按 [安全政策](SECURITY.md) 处理，不要公开秘密。

容量限制和持久取消墓碑用于防止重放，不能通过删除历史状态释放容量；管理连接的 401/403 是永久熔断，不能通过 force、清单重载或缓存绕过；`healthz` 的现有语义不能被改变或夸大为真实上游与设备送达的保证。涉及这些合同的变更须保留对应回归。

文案请遵循 [编辑准则](docs/COPY_STYLE.md)。在仓库根目录可运行以下本地检查；按需准备项目已有工具链，不需要真实服务或 Apple 身份。Apple 原生、签名和真机验收以及真实服务连接均不默认执行。

```powershell
python -I -B ci/validate_public_copy.py --root .
python -I -X utf8 -B ci/validate_source_layout.py --root .
python -I -X utf8 -B ci/test_source_layout.py
python -I -X utf8 -B ci/test_activity_extension.py
python -I -B -m unittest discover -s tools/tests -p "test_*.py"
go -C Services/QuotaMonitor test ./...
go -C Services/QuotaMonitor vet ./...
```

执行结果和未运行项应在贡献说明中如实区分；`dry_run` 不禁止有活动时采集 CPA，不能用于宣称完全离线。

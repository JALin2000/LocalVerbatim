# Contributing / 参与贡献

LocalVerbatim is an experimental project for Apple Silicon Macs. v0.5.0 provides an explicitly unnotarized preview installer. English and Chinese contributions are welcome.

## English

- Search existing [issues](https://github.com/JALin2000/LocalVerbatim/issues) before opening a bug report or proposing a change. Include the app version or commit, macOS version, chip/memory, minimal steps, and expected versus actual behavior.
- Reproduce problems with synthetic audio and invented meeting names. Never submit real recordings, transcripts, participant names, credentials or personal paths. Inspect and redact logs and screenshots before attaching them. For suspected vulnerabilities, follow [SECURITY.md](SECURITY.md).
- Keep pull requests focused. Explain the behavior changed and why, follow the existing code style, and preserve English/Chinese UI and documentation where affected. Discuss substantial changes in an issue first.
- Use the [developer guide](docs/DEVELOPMENT.md) to build and run checks relevant to your change. Report the checks performed and any checks you could not run. Add regression coverage when a behavior change needs it; documentation-only edits need link/content review.
- Commit source and safe generated test fixtures only. Keep runtime/model downloads, recordings, logs, `.app` and `.dmg` files out of pull requests.
- Submit original contributions under [Apache-2.0](LICENSE). Include the source and applicable notices for any third-party material; do not remove existing attribution.

## 简体中文

- 提交问题或建议前先搜索已有 [issue](https://github.com/JALin2000/LocalVerbatim/issues)。报告应用版本或提交号、macOS 版本、芯片／内存、最小复现步骤、预期与实际行为。
- 用合成音频和虚构会议名称复现。不要提交真实录音、逐字稿、与会者姓名、凭证或个人路径；附日志和截图前先检查并脱敏。疑似漏洞按 [SECURITY.md](SECURITY.md) 报告。
- 每个 pull request 聚焦一个问题，说明行为变化及原因，沿用现有代码风格，并同步受影响的中英文界面和文档。较大的改动先在 issue 中讨论。
- 按[开发说明](docs/DEVELOPMENT.zh-CN.md)构建，运行与改动有关的检查，说明已完成和无法运行的检查。行为改动需要时补充回归测试；纯文档修改检查内容和链接即可。
- 仅提交源码和安全生成的测试样例。不要提交运行时、模型下载、录音、日志、`.app` 或 `.dmg`。
- 原创贡献采用 [Apache-2.0](LICENSE)。引入第三方内容时注明来源并保留适用许可和署名；不要移除已有归属信息。

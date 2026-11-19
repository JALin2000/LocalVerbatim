# Release preparation / 发行准备

This checklist separates the experimental v0.4.7 [source release](https://github.com/JALin2000/LocalVerbatim) from public installer preparation. There is no public installer yet. Open installer items do not imply that the source is unavailable.

## Source preparation

- [x] Separate allowlisted source tree; exclude recordings, private analysis, runtime, models, logs and personal installation helpers.
- [x] English and Chinese README, installation and developer guides.
- [x] Apache-2.0 for original code, documentation and icon; collective attribution in NOTICE.
- [x] Preserve observed third-party license texts and document their provenance/scope.
- [x] Source contents and local documentation link checks available.
- [x] Choose LocalVerbatim / 本地逐字稿 and update application/source/documentation names.
- [x] Keep collective project attribution in NOTICE and use repository channels without publishing personal contact details.
- [x] Add bilingual contribution/security guidance and a privacy-conscious bug report template.
- [x] Run source-content, local documentation link and Python syntax checks in GitHub Actions with read-only permissions.
- [ ] Verify that GitHub private vulnerability reporting is enabled; SECURITY.md explains what to do if the form is unavailable.
- [ ] Add macOS CI and artifact/hash provenance suitable for the chosen hosting destination.

Contribution guidance, issue templates and CI improve maintenance; they are separate from the original source's Apache-2.0 license and the installer checks below.

## Public installer

- [ ] Complete exact-version native dependency/license review; collect remaining notices/source references as applicable.
- [ ] Lock Python package artifacts/hashes and review the managed Python build provenance.
- [ ] Verify every bundled native binary's architecture and minimum macOS version, then test the packaged app on a clean macOS 15 Mac. Runtime preparation selects macOS 15 arm64 wheels; wheel selection and local import checks do not prove minimum-version compatibility.
- [x] Preserve the historical bundle identifier and data paths across the rename.
- [ ] Configure a Developer ID signing identity for public binaries.
- [ ] Sign nested executables/native libraries, enable appropriate Hardened Runtime settings, notarize and staple.
- [ ] Test a fresh Mac user account with no existing permissions, runtime or model cache.
- [ ] Test supported macOS versions and representative M-series hardware, offline use, interrupted downloads, denied permissions, updates and external storage.
- [ ] Publish checksums, release notes and only sanitized screenshots/examples after explicit release authorization.

The local build and packaging scripts do not publish to GitHub, enroll certificates or upload artifacts.

v0.4.7 为实验性源码版，目前没有公开安装包。已整理原创部分 Apache-2.0 许可、集体署名、第三方许可、双语文档和参与贡献／安全报告说明；GitHub 私密漏洞报告功能仍需确认已开启。完整二进制许可核查、安装文件哈希、正式签名公证、CI 和多机首装仍待完成。源码公开与安装包准备分别记录。

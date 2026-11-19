# Release preparation / 发行准备

This checklist separates the [0.4.8 unnotarized preview installer](https://github.com/JALin2000/LocalVerbatim/releases/tag/v0.4.8-preview.1) from Developer ID/notarized distribution. Open signing and wider-device checks are disclosed preview limitations.

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

## Installer preparation

- [x] Review the exact 42-package Qwen application runtime and native/static dependencies; ship notices, inventories and MPL-covered source. SciPy/GCC libraries are excluded.
- [x] Pin the CPython archive by official source/SHA-256 and preparation wheels by source/size/SHA-256; install verified artifacts offline.
- [x] Verify all 37 retained native files contain arm64 and require macOS 15 or earlier; run local native imports and synthetic English/Mandarin Qwen recognition.
- [ ] Test the packaged app on a clean macOS 15 Mac. Binary inspection and local tests do not prove first-install or all-device compatibility.
- [x] Preserve the historical bundle identifier and data paths across the rename.
- [ ] Configure a Developer ID signing identity for notarized distribution. The current preview path is explicitly ad-hoc signed and unnotarized.
- [x] Implement and test inside-out signing and preview DMG round-trip integrity checks.
- [ ] Exercise Developer ID signing, Hardened Runtime and notarization/stapling with a real certificate. Scripts and minimal entitlements are prepared; no signing identity is currently configured.
- [ ] Test a fresh Mac user account with no existing permissions, runtime or model cache.
- [ ] Test supported macOS versions and representative M-series hardware, offline use, interrupted downloads, denied permissions, updates and external storage.
- [x] Prepare privacy-checked preview DMG, checksums and bilingual release notes under explicit preview-release authorization. No real meeting screenshots are included.

The local build and packaging scripts do not publish to GitHub, enroll certificates or upload artifacts.

v0.4.7 源码已经公开；0.4.8 提供未公证预览安装包。已固定解释器及依赖文件哈希、核查精简后的实际运行时许可，并补充必要源码与隐私检查。未公证预览版必须明确标注安装限制；它不等于正式签名、公证或全新 Mac 验证已完成。正式 Developer ID 路径需要维护者配置会员、证书和本机公证凭据。源码公开、预览包准备与公证发行分别记录。

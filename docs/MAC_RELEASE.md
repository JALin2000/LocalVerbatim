# macOS release packaging / macOS 发行打包

LocalVerbatim targets Apple Silicon and macOS 15+. The scripts never install or open the app, alter existing recordings, create certificates, or change Gatekeeper settings. Keep runtime downloads, apps, installers, signing logs and test data outside the source checkout.

## Preview without an Apple Developer membership / 无开发者会员的预览版

An ad-hoc signature checks bundle integrity locally; it does not establish an Apple-verified developer identity or notarization. Gatekeeper may block a downloaded preview and require user approval in System Settings. Organization policy can prohibit it entirely. Label the release and installer **Preview · Not notarized / 预览版 · 未经 Apple 公证**, and do not describe successful local signature verification as Gatekeeper approval.

临时签名不能证明 Apple 已验证开发者，也不等于公证。下载的预览版可能被 Gatekeeper 阻止；受组织管理的 Mac 可能完全禁止运行。请先说明这些限制，再决定是否发布。

```bash
# Use a fresh directory outside the checkout; choose your own absolute location.
release_work=/tmp/localverbatim-release
mkdir -p "$release_work"
scripts/prepare_runtime.sh "$release_work/runtime-build"
LOCALVERBATIM_BUILD_CACHE="$release_work/swift-cache" \
  scripts/package_app.sh "$release_work/runtime-build/runtime" \
  "$release_work/LocalVerbatim.app" --download-model
scripts/package_dmg.sh "$release_work/LocalVerbatim.app" \
  "$release_work/LocalVerbatim-preview-not-notarized.dmg" --preview
```

The model-download variant includes the Python/MLX runtime but no model weights. Its setup guide downloads or imports the model. Omitting `--preview` retains the private local-trial label. Local `package_dmg.sh --download-model` may strip weights from its own staging copy and then re-sign it; it never mutates the source app.

## Developer ID release / Developer ID 正式发行

This optional path requires an Apple Developer Program membership and a valid **Developer ID Application** certificate with its private key already available in Keychain. An Apple Development or Developer ID Installer certificate is insufficient. These scripts do not enroll an account, generate/export/import a certificate, or save credentials in the repository.

1. List available identities with `security find-identity -v -p codesigning`. Choose the exact Developer ID Application name or its SHA-1 fingerprint.
2. In your own Terminal, run `xcrun notarytool store-credentials LocalVerbatim-notary` and answer its interactive prompts. Enter account credentials only into Apple's local prompt. Do not paste passwords, private keys or certificate exports into chat, scripts, environment files, or command-line arguments.
3. Build the final model variant, sign, notarize/staple the app, and then package/sign/notarize/staple the DMG. Use a fresh log directory for each submission.

```bash
# Use new output paths even if you already built the preview above.
signed_work="$(mktemp -d /tmp/localverbatim-signed.XXXXXX)"
scripts/prepare_runtime.sh "$signed_work/runtime-build"
# Replace the example with an existing identity, without angle brackets.
signing_identity='Developer ID Application: Example Organization (TEAMID1234)'
LOCALVERBATIM_BUILD_CACHE="$signed_work/swift-cache" \
  scripts/package_app.sh "$signed_work/runtime-build/runtime" \
  "$signed_work/LocalVerbatim.app" --download-model --identity "$signing_identity"
scripts/notarize.sh "$signed_work/LocalVerbatim.app" \
  LocalVerbatim-notary "$signed_work/app-notary-logs"
scripts/package_dmg.sh "$signed_work/LocalVerbatim.app" \
  "$signed_work/LocalVerbatim.dmg" --identity "$signing_identity"
scripts/notarize.sh "$signed_work/LocalVerbatim.dmg" \
  LocalVerbatim-notary "$signed_work/dmg-notary-logs"
```

正式发行须先准备有效的 Developer ID Application 身份，并在本机钥匙串保存公证凭据。脚本仅接受钥匙串配置名称，不接受明文密码。先确定是否内置模型；应用签名和公证后不能再删减模型。先公证并附加应用票据，再制作、公证并附加 DMG 票据。

The public path enables Hardened Runtime, requests Apple's secure timestamp for every native code signature, and checks consistent Team ID, expected entitlements and signatures. It requires a valid app staple before creating the public DMG. No `--deep` signing is used: regular Mach-O files (including Python extensions and libraries in Resources) and nested code bundles are signed inside-out, followed by the outer app. Symlinks must resolve inside the app and are never signed twice. `--deep` is used only as an additional verification check.

`notarize.sh` uploads the artifact to Apple, waits for an `Accepted` response, retrieves the log, stops on any reported issue, staples and validates the ticket, and checks Gatekeeper. Submission logs remain on disk if a command fails. A timeout or a successful upload alone is not approval. Use the saved submission ID with `xcrun notarytool info`, `wait`, or `log` and the same `--keychain-profile` to diagnose an interrupted submission. Resolve issues and repeat the final validation before publishing. Do not rebuild or re-sign an accepted artifact; that changes its identity and requires notarization again. Generate release checksums after the final DMG staple.

## Entitlements and verification / 权限与验证

The Swift process alone records audio, so [app.plist](../scripts/entitlements/app.plist) grants only `com.apple.security.device.audio-input`. macOS microphone and screen/system-audio consent is still requested from the user. The Python worker receives audio files; its [runtime.plist](../scripts/entitlements/runtime.plist) is empty. The code uses CPython and MLX, with no demonstrated need for a CPU JIT or unsigned executable memory. All bundled native libraries are re-signed under the same identity, so library validation remains enabled. No `get-task-allow`, sandbox, JIT, unsigned-memory, or library-validation exception is granted. If a future dependency changes this, reproduce the failure in a disposable build and justify a narrowly scoped exception before changing entitlements.

```bash
# Read-only plan; this does not validate availability of a signing identity.
/usr/bin/python3 -I -B scripts/sign_app.py "$release_work/LocalVerbatim.app" \
  --adhoc --dry-run
/usr/bin/python3 -I -B tests/test_signing.py

# Developer ID builds only:
/usr/bin/python3 -I -B scripts/sign_app.py "$release_work/LocalVerbatim.app" \
  --verify-only --require-developer-id
xcrun stapler validate "$release_work/LocalVerbatim.app"
xcrun stapler validate "$release_work/LocalVerbatim.dmg"
spctl --assess --type execute --verbose=2 "$release_work/LocalVerbatim.app"
spctl --assess --type open --context context:primary-signature \
  --verbose=2 "$release_work/LocalVerbatim.dmg"
```

Packaging validates native imports and a small MLX operation before and after signing without starting recording, loading a model, installing, or opening the app. An optional `sign_app.py --adhoc --hardened-runtime` can exercise Hardened Runtime on a disposable test app; ad-hoc signatures have no Team ID, so Hardened Runtime can reject native imports. This does not justify disabling library validation: test it with the real Developer ID instead. Before a public release, also check the exact installer contents for private data, verify bundled license/provenance records, and test a normally downloaded, quarantined copy on a separate Mac with microphone/system audio, model setup and offline transcription. Signing/notarization success alone does not demonstrate those user flows.

### Apple references

- [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac): signing identities, nested code and manual signing.
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution): Developer ID, Hardened Runtime and timestamp requirements.
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow): submissions, Keychain profiles, logs and stapling.
- [Audio Input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input) and [library validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation): resource access and same-team native library loading.

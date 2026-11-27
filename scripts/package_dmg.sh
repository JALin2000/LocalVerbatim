#!/bin/bash
# Package a verified app. Public mode preserves its notarized/stapled bytes.
set -euo pipefail
package_source="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -lt 2 ]; then
  echo "Usage: $0 INPUT_APP OUTPUT_DMG [--download-model] [--preview | --identity IDENTITY]" >&2; exit 2
fi
source_app="$1"
output_dmg="$2"
shift 2
variant=""
package_preview=0
package_identity=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --download-model) test -z "$variant" || exit 2; variant="$1"; shift ;;
    --preview) test "$package_preview" = 0 || exit 2; package_preview=1; shift ;;
    --identity)
      test "$#" -ge 2 && test -n "$2" && test -z "$package_identity" || { echo 'Provide exactly one signing identity' >&2; exit 2; }
      package_identity="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
case "$source_app" in /*.app) ;; *) echo 'INPUT_APP must be an absolute app path' >&2; exit 2 ;; esac
case "$output_dmg" in /*.dmg) ;; *) echo 'OUTPUT_DMG must be an absolute dmg path' >&2; exit 2 ;; esac
test ! -e "$output_dmg" && test ! -L "$output_dmg" || { echo 'Refusing to overwrite an existing installer' >&2; exit 2; }
package_verify_options=(--verify-only)
if [ -n "$package_identity" ]; then
  test "$package_preview" = 0 || { echo '--preview and --identity are mutually exclusive' >&2; exit 2; }
  test -z "$variant" || { echo 'Build --download-model in package_app.sh before public signing; signed/stapled apps cannot be stripped.' >&2; exit 2; }
  package_identity="$(/usr/bin/python3 -I -B - "$package_source/scripts" "$package_identity" "$source_app" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from sign_app import identity_from_keychain
fingerprint, team = identity_from_keychain(sys.argv[2])
from sign_app import check_developer_signature
check_developer_signature(sys.argv[3], expected_team=team)
print(fingerprint)
PY
)"
  package_verify_options+=(--require-developer-id)
else
  # Never silently replace a real signature with an ad-hoc signature.
  /usr/bin/codesign --display --verbose=4 "$source_app" 2>&1 | /usr/bin/grep '^Signature=adhoc$' >/dev/null || {
    echo 'Local packaging requires an ad-hoc app. For Developer ID use --identity.' >&2; exit 2;
  }
fi
/usr/bin/python3 -I -B "$package_source/scripts/sign_app.py" "$source_app" "${package_verify_options[@]}"
if [ -n "$package_identity" ]; then xcrun stapler validate "$source_app"; fi
package_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")"
mkdir -p "$(dirname "$output_dmg")"
package_work="$(mktemp -d "$(dirname "$output_dmg")/.localverbatim-dmg.XXXXXX")"
package_mount=""
cleanup_package() {
  if [ -n "$package_mount" ]; then
    # Only this script's disposable staging or verification mount is detached.
    if ! hdiutil detach "$package_mount" >/dev/null 2>&1 &&
       ! hdiutil detach -force "$package_mount" >/dev/null 2>&1; then
      echo "Could not detach temporary mount; preserved work directory: $package_work" >&2
      return
    fi
  fi
  rm -rf "$package_work"
}
trap cleanup_package EXIT
stage="$package_work/payload"
mkdir "$stage"
/bin/cp -cR "$source_app" "$stage/LocalVerbatim.app"
if [ "$variant" = '--download-model' ]; then
  rm -rf "$stage/LocalVerbatim.app/Contents/Resources/Support/models"
  mkdir -p "$stage/LocalVerbatim.app/Contents/Resources/Support/models"
  /usr/bin/python3 -I -B "$package_source/scripts/sign_app.py" "$stage/LocalVerbatim.app" --adhoc
fi
/usr/bin/python3 -I -B "$package_source/scripts/sign_app.py" "$stage/LocalVerbatim.app" "${package_verify_options[@]}"
if [ -n "$package_identity" ]; then xcrun stapler validate "$stage/LocalVerbatim.app"; fi
ln -s /Applications "$stage/Applications"
cat > "$stage/安装说明 - Read me.txt" <<'TEXT'
LocalVerbatim / 本地逐字稿

将 LocalVerbatim（本地逐字稿）拖到 Applications 文件夹。然后从 Applications 打开。
从 LocalScribe 升级时先退出旧应用，保留原数据目录，无需移动录音。
升级前请备份完整录音库（含隐藏文件）。0.4.5 起自动按日期和会议名整理目录。
如果旧模型内置于应用包，请保留旧应用并在向导中导入其模型文件夹，避免重新下载。
首次启动跟随系统语言。按向导选择并下载 BF16（约 4.08 GB）或 8 位量化版（约 2.47 GB）。
录音与识别在本机完成。需要麦克风及屏幕与系统音频录制授权；不保存屏幕画面。
适用于 Apple Silicon Mac，macOS 15 或更新版本。Windows 尚未适配。

Drag LocalVerbatim to Applications, then open it from Applications.
When upgrading from LocalScribe, quit the old app and keep its existing data folder.
Back up the complete library, including hidden files, before upgrading. From 0.4.5,
meeting folders are organized by date and title. The app reuses recordings and settings.
Models in the user cache are reused; for older builds with bundled weights, import
its model folder using the setup guide. If a local model is unavailable, the guide
offers BF16 (4.08 GB) and 8-bit (2.47 GB) downloads. Recordings and transcription stay local.
Microphone and Screen & System Audio Recording permissions are needed;
screen images are not saved. Apple Silicon, macOS 15 or later.
TEXT
if [ "$package_preview" = 1 ]; then
  cat >> "$stage/安装说明 - Read me.txt" <<'TEXT'

Preview · Not notarized / 预览版 · 未经 Apple 公证
此预览版仅使用本地临时签名。Apple 无法验证开发者身份；macOS Gatekeeper 可能阻止打开。
使用须知：可能需按 macOS 系统设置提示由用户批准；受组织管理的 Mac 可能无法运行。
请仅在了解以上限制后使用，并在升级前备份完整录音库。
This preview is ad-hoc signed. Apple has not verified the developer or notarized it.
macOS Gatekeeper may block opening it and require the user's approval through
System Settings. Organization-managed Macs may prohibit it. Use only if you
understand these limitations, and back up the complete recording library first.
TEXT
elif [ -z "$package_identity" ]; then
  cat >> "$stage/安装说明 - Read me.txt" <<'TEXT'

私人试用版：本地临时签名，未经 Developer ID 签名或 Apple 公证。
Private trial: ad-hoc signed for local testing, not Developer ID signed or notarized.
TEXT
fi
# Use a private staging mount instead of -srcfolder's implicit /Volumes mount,
# which background services can hold busy. Only our own mounts may be forced off.
package_kib="$(du -sk "$stage" | awk '{print $1}')"
package_kib=$((package_kib + package_kib / 4 + 65536))
hdiutil create -size "${package_kib}k" -fs HFS+ -volname "LocalVerbatim $package_version" \
  -type SPARSE -nospotlight "$package_work/payload.sparseimage"
mkdir "$package_work/write-mount"
package_mount="$package_work/write-mount"
hdiutil attach "$package_work/payload.sparseimage" -nobrowse -noautoopen -mountpoint "$package_mount"
/usr/bin/ditto "$stage" "$package_mount"
/usr/bin/python3 -I -B "$package_source/scripts/sign_app.py" \
  "$package_mount/LocalVerbatim.app" "${package_verify_options[@]}"
if [ -n "$package_identity" ]; then xcrun stapler validate "$package_mount/LocalVerbatim.app"; fi
hdiutil detach "$package_mount" || hdiutil detach -force "$package_mount"
package_mount=""
hdiutil convert "$package_work/payload.sparseimage" -format UDZO -o "$package_work/LocalVerbatim.dmg"
hdiutil verify "$package_work/LocalVerbatim.dmg"
mkdir "$package_work/verify-mount"
package_mount="$package_work/verify-mount"
hdiutil attach "$package_work/LocalVerbatim.dmg" -readonly -nobrowse -noautoopen \
  -mountpoint "$package_work/verify-mount"
/usr/bin/python3 -I -B "$package_source/scripts/sign_app.py" \
  "$package_work/verify-mount/LocalVerbatim.app" "${package_verify_options[@]}"
test "$(readlink "$package_work/verify-mount/Applications")" = /Applications
if [ -n "$package_identity" ]; then xcrun stapler validate "$package_work/verify-mount/LocalVerbatim.app"; fi
hdiutil detach "$package_work/verify-mount" || hdiutil detach -force "$package_work/verify-mount"
package_mount=""
if [ -n "$package_identity" ]; then
  codesign --force --sign "$package_identity" --timestamp "$package_work/LocalVerbatim.dmg"
  codesign --verify --strict "$package_work/LocalVerbatim.dmg"
fi
mv "$package_work/LocalVerbatim.dmg" "$output_dmg"
echo "Packaged $output_dmg"
if [ -n "$package_identity" ]; then echo 'DMG signed; run notarize.sh on this DMG before public distribution.'; fi

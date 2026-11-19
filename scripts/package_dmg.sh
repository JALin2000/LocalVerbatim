#!/bin/bash
# Package an already verified app as a private drag-to-Applications installer.
# The optional download-model variant strips weights only from its own copy.
set -euo pipefail
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 INPUT_APP OUTPUT_DMG [--download-model]" >&2; exit 2
fi
source_app="$1"
output_dmg="$2"
variant="${3:-}"
case "$variant" in ""|--download-model) ;; *) exit 2 ;; esac
case "$source_app" in /*.app) ;; *) echo 'INPUT_APP must be an absolute app path' >&2; exit 2 ;; esac
case "$output_dmg" in /*.dmg) ;; *) echo 'OUTPUT_DMG must be an absolute dmg path' >&2; exit 2 ;; esac
test ! -e "$output_dmg" || { echo 'Refusing to overwrite an existing installer' >&2; exit 2; }
codesign --verify --deep --strict "$source_app"
package_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")"
stage="$(mktemp -d "${TMPDIR:-/tmp}/localverbatim-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
/bin/cp -cR "$source_app" "$stage/LocalVerbatim.app"
if [ "$variant" = "--download-model" ]; then
  rm -rf "$stage/LocalVerbatim.app/Contents/Resources/Support/models"
  mkdir -p "$stage/LocalVerbatim.app/Contents/Resources/Support/models"
  codesign --force --deep --sign - "$stage/LocalVerbatim.app"
fi
codesign --verify --deep --strict "$stage/LocalVerbatim.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/安装说明 - Read me.txt" <<'TEXT'
LocalVerbatim / 本地逐字稿 · Private trial / 私人试用版

将 LocalVerbatim（本地逐字稿）拖到 Applications 文件夹。然后从 Applications 打开。
从 LocalScribe 升级时先退出旧应用，保留原数据目录，无需移动录音。
升级前请备份完整录音库（含隐藏文件）。0.4.5 起自动按日期和会议名整理目录。
如果旧模型内置于应用包，请保留旧应用并在向导中导入其模型文件夹，避免重新下载。
第一次使用时选择界面语言；若本机没有模型，按向导下载或导入模型（约4.08GB）。
录音与识别在本机完成。需要麦克风及屏幕与系统音频录制授权；不保存屏幕画面。
适用于 Apple Silicon Mac，macOS 15 或更新版本。Windows 尚未适配。
此包为本地临时签名的试用包，尚未进行 Developer ID 签名、公证和多机发行验证。

Drag LocalVerbatim to Applications, then open it from Applications.
When upgrading from LocalScribe, quit the old app and keep its existing data folder.
Back up the complete library, including hidden files, before upgrading. From 0.4.5,
meeting folders are organized by date and title. The app reuses recordings and settings. Models in the user cache are reused;
for older private builds with bundled weights, import the model folder from the old app.
Choose the interface language. If a local model is unavailable, the setup guide
offers download or import (about 4.08GB). Recording and transcription stay local.
Microphone and Screen & System Audio Recording permissions are needed;
screen images are not saved. Apple Silicon, macOS 15 or later.
This private build is ad-hoc signed, not Developer ID signed or notarized.
TEXT
hdiutil create -volname "LocalVerbatim $package_version" -srcfolder "$stage" -format UDZO -ov "$output_dmg"
hdiutil verify "$output_dmg"
echo "Packaged $output_dmg"

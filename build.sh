#!/bin/zsh
# 編譯並安裝 SmallImg.app 到 /Applications，同時建立 smallimg 命令列連結
set -e
cd "$(dirname "$0")"

swift build -c release
BIN=$(swift build -c release --show-bin-path)/SmallImg

APP=build/SmallImg.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SmallImg"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep -s - "$APP"

DEST=/Applications/SmallImg.app
[[ -w /Applications ]] || DEST="$HOME/Applications/SmallImg.app"
mkdir -p "$(dirname "$DEST")"
pkill -x SmallImg 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"

LINK=/opt/homebrew/bin/smallimg
[[ -w /opt/homebrew/bin ]] || LINK=/usr/local/bin/smallimg
ln -sf "$DEST/Contents/MacOS/SmallImg" "$LINK" 2>/dev/null || echo "無法建立 $LINK，可以在設定中安裝命令列工具"

/System/Library/CoreServices/pbs -update 2>/dev/null || true
open "$DEST"
echo "已安裝：$DEST"
echo "命令列：$LINK"

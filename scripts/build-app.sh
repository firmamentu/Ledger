#!/bin/bash
set -euo pipefail

# 使用已安装的 Xcode 工具链（不修改系统 xcode-select）
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
[ -d "$DEVELOPER_DIR" ] || { echo "未找到 Xcode：$DEVELOPER_DIR" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Ledger.app"

swift build --package-path "$ROOT" -c release
BIN_DIR="$(swift build --package-path "$ROOT" -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Ledger" "$APP/Contents/MacOS/Ledger"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"

if [ -d "$ROOT/Resources" ]; then
    cp -R "$ROOT/Resources/." "$APP/Contents/Resources/"
fi

codesign --force --sign - "$APP"
echo "Built $APP"

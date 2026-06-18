#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-$HOME/.local/share/pi_slideshow}"
APP_DIR="$HOME/.local/share/applications"

SOURCE_SCRIPT="$BASE_DIR/slideshow.sh"
SOURCE_DESKTOP="$BASE_DIR/slideshow.desktop"

TARGET_SCRIPT="$INSTALL_DIR/slideshow.sh"
TARGET_DESKTOP="$INSTALL_DIR/slideshow.desktop"
MENU_DESKTOP="$APP_DIR/pi-slideshow.desktop"

if [ ! -f "$SOURCE_SCRIPT" ] || [ ! -f "$SOURCE_DESKTOP" ]; then
    echo "必要ファイルが見つかりません: slideshow.sh / slideshow.desktop"
    exit 1
fi

mkdir -p "$INSTALL_DIR" "$APP_DIR"

cp "$SOURCE_SCRIPT" "$TARGET_SCRIPT"
chmod +x "$TARGET_SCRIPT"

cp "$SOURCE_DESKTOP" "$TARGET_DESKTOP"
escaped_exec=$(printf '%s\n' "$TARGET_SCRIPT" | sed 's/[&|]/\\&/g')
sed -i "s|^Exec=.*|Exec=$escaped_exec|" "$TARGET_DESKTOP"

cp "$TARGET_DESKTOP" "$MENU_DESKTOP"
chmod 644 "$MENU_DESKTOP"

# メニューに即時反映されるよう、利用可能な更新コマンドを実行
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APP_DIR" || true
fi

if command -v xdg-desktop-menu >/dev/null 2>&1; then
    xdg-desktop-menu forceupdate || true
fi

echo "✅ インストール完了"
echo "- スクリプト: $TARGET_SCRIPT"
echo "- デスクトップエントリ: $MENU_DESKTOP"
echo "- メニュー更新: 実行済み（環境により再ログインが必要）"

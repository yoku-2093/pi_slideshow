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

# 稼働中インスタンスがあれば警告する。
# bash は実行中スクリプトをバイト位置で逐次読むため、内容を直接上書きすると
# 行ズレで "command not found" や "syntax error" を引き起こす。
if pgrep -f "$TARGET_SCRIPT" >/dev/null 2>&1; then
    echo "⚠ 稼働中のスライドショーを検出しました。"
    echo "  反映には一度終了して再起動してください（pkill -f slideshow.sh）。"
fi

# 原子的置換でスクリプトを配置する。
# 同一ディレクトリの一時ファイルに書き出してから mv することで、
# 置換は inode の入れ替えになり、稼働中プロセスは旧 inode を読み続ける。
# これにより上書き起因の行ズレ破損を防ぐ。
tmp_script="$(mktemp "$INSTALL_DIR/.slideshow.sh.XXXXXX")"
cp "$SOURCE_SCRIPT" "$tmp_script"
chmod +x "$tmp_script"
mv -f "$tmp_script" "$TARGET_SCRIPT"

tmp_desktop="$(mktemp "$INSTALL_DIR/.slideshow.desktop.XXXXXX")"
cp "$SOURCE_DESKTOP" "$tmp_desktop"
escaped_exec=$(printf '%s\n' "$TARGET_SCRIPT" | sed 's/[&|]/\\&/g')
sed -i "s|^Exec=.*|Exec=$escaped_exec|" "$tmp_desktop"
mv -f "$tmp_desktop" "$TARGET_DESKTOP"

tmp_menu="$(mktemp "$APP_DIR/.pi-slideshow.desktop.XXXXXX")"
cp "$TARGET_DESKTOP" "$tmp_menu"
chmod 644 "$tmp_menu"
mv -f "$tmp_menu" "$MENU_DESKTOP"

# メニューに即時反映されるよう、利用可能な更新コマンドを実行
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APP_DIR" || true
fi

if command -v xdg-desktop-menu >/dev/null 2>&1; then
    xdg-desktop-menu forceupdate || true
fi

# TTY 自動切替に必要な openvt/chvt の sudo 権限を設定
# NOPASSWD で openvt と chvt だけを許可（最小権限）
SUDOERS_FILE="/etc/sudoers.d/pi-slideshow-vt"
SUDOERS_LINE="${USER} ALL=(root) NOPASSWD: /usr/bin/openvt, /usr/bin/chvt"
if ! sudo grep -qF "$SUDOERS_LINE" "$SUDOERS_FILE" 2>/dev/null; then
    echo "$SUDOERS_LINE" | sudo tee "$SUDOERS_FILE" >/dev/null
    sudo chmod 440 "$SUDOERS_FILE"
    echo "- sudoers 設定: $SUDOERS_FILE"
else
    echo "- sudoers 設定: 既に設定済み"
fi

echo "✅ インストール完了"
echo "- スクリプト: $TARGET_SCRIPT"
echo "- デスクトップエントリ: $MENU_DESKTOP"
echo "- メニュー更新: 実行済み（環境により再ログインが必要）"

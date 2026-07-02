#!/bin/bash
set -euo pipefail

echo "pi_slideshow をアンインストールします..."

# 稼働中のインスタンスを停止
if pgrep -f "slideshow.sh" >/dev/null 2>&1; then
    echo "- 稼働中のスライドショーを停止しています..."
    pkill -f "slideshow.sh" || true
    sleep 1
fi

# インストールディレクトリを削除
INSTALL_DIR="$HOME/.local/share/pi_slideshow"
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "- インストールディレクトリを削除: $INSTALL_DIR"
fi

# デスクトップエントリを削除
MENU_DESKTOP="$HOME/.local/share/applications/pi-slideshow.desktop"
if [ -f "$MENU_DESKTOP" ]; then
    rm -f "$MENU_DESKTOP"
    echo "- デスクトップエントリを削除: $MENU_DESKTOP"
fi

# sudoers設定を削除
SUDOERS_FILE="/etc/sudoers.d/pi-slideshow-vt"
if [ -f "$SUDOERS_FILE" ]; then
    sudo rm -f "$SUDOERS_FILE"
    echo "- sudoers設定を削除: $SUDOERS_FILE"
fi

# メニューキャッシュを更新
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
fi

if command -v xdg-desktop-menu >/dev/null 2>&1; then
    xdg-desktop-menu forceupdate 2>/dev/null || true
fi

echo ""
echo "以下のディレクトリには設定やキャッシュが残っています："
echo "  - ログ: $HOME/.local/state/pi_slideshow/"
echo "  - キャッシュ: $HOME/.cache/pi_slideshow/"
echo ""
echo "これらも削除する場合は以下のコマンドを実行してください："
echo "  rm -rf ~/.local/state/pi_slideshow ~/.cache/pi_slideshow"
echo ""
echo "✅ アンインストール完了"

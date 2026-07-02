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
LOG_DIR="$HOME/.local/state/pi_slideshow"
CACHE_DIR="$HOME/.cache/pi_slideshow"

if [ -d "$LOG_DIR" ] || [ -d "$CACHE_DIR" ]; then
    echo "以下のディレクトリが残っています："
    [ -d "$LOG_DIR" ] && echo "  - ログ: $LOG_DIR"
    [ -d "$CACHE_DIR" ] && echo "  - キャッシュ: $CACHE_DIR"
    echo ""
    read -p "これらも削除しますか？ (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        [ -d "$LOG_DIR" ] && rm -rf "$LOG_DIR" && echo "- ログを削除: $LOG_DIR"
        [ -d "$CACHE_DIR" ] && rm -rf "$CACHE_DIR" && echo "- キャッシュを削除: $CACHE_DIR"
    else
        echo "ログとキャッシュは保持されました"
        echo "手動で削除する場合: rm -rf ~/.local/state/pi_slideshow ~/.cache/pi_slideshow"
    fi
fi

echo ""
echo "✅ アンインストール完了"

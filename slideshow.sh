#!/bin/bash
set -u

VIEWER_PID=""
VIEWER_BIN=""
MONITOR_PID=""
RELOAD_FLAG_FILE="/tmp/pi_slideshow.reload.$$"

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/pi_slideshow"
LOG_FILE="$LOG_DIR/slideshow.log"
mkdir -p "$LOG_DIR"

# 画像拡張子のマッチ用（大文字小文字を区別しない）
shopt -s nullglob nocaseglob

# GUI起動時でも追跡できるようにファイルへログを残す
exec >>"$LOG_FILE" 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

image_signature() {
    local dir="$1"
    find "$dir" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' \) \
        -printf '%f\t%s\t%T@\n' 2>/dev/null | sort | sha256sum | awk '{print $1}'
}

cleanup_child() {
    if [ -n "${MONITOR_PID}" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
    fi
    MONITOR_PID=""

    if [ -n "${VIEWER_PID}" ] && kill -0 "$VIEWER_PID" 2>/dev/null; then
        log "ビューアプロセスを停止します: pid=$VIEWER_PID"
        kill "$VIEWER_PID" 2>/dev/null || true
        wait "$VIEWER_PID" 2>/dev/null || true
    fi
    VIEWER_PID=""

    rm -f "$RELOAD_FLAG_FILE"
}

handle_signal() {
    local sig="$1"
    log "シグナル受信: $sig"
    cleanup_child
    exit 0
}

show_error() {
    local msg="$1"
    log "ERROR: $msg"
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="スライドショー" --text="$msg" 2>/dev/null || true
    fi
}

log "----- slideshow start -----"

# 多重起動を防止
LOCK_FILE="/tmp/pi_slideshow.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    show_error "既にスライドショーが起動しています。多重起動を防ぐため終了します。"
    exit 1
fi

set -o errtrace
trap 'rc=$?; cleanup_child; log "終了コード: $rc"' EXIT
trap 'log "ERR line=$LINENO cmd=${BASH_COMMAND} rc=$?"' ERR
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

RUN_TTY=$(tty 2>/dev/null || echo "not-a-tty")
log "実行TTY: $RUN_TTY"

VIEWER_MODE="gui"
if [[ "$RUN_TTY" =~ ^/dev/tty[0-9]+$ ]]; then
    VIEWER_MODE="tty"
fi
log "ビューアモード: $VIEWER_MODE"

# 画像フォルダを選択（引数優先。未指定時はzenity、TTYでは対話入力）
IMAGE_DIR="${1:-}"
if [ -z "$IMAGE_DIR" ]; then
    if command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
        IMAGE_DIR=$(zenity --file-selection --directory \
            --title="画像フォルダを選択" \
            --filename="${HOME}/" 2>/dev/null)
    else
        read -r -p "画像フォルダのパスを入力してください: " IMAGE_DIR
    fi
fi
if [ -z "$IMAGE_DIR" ] || [ ! -d "$IMAGE_DIR" ]; then
    log "有効な画像フォルダが選択されませんでした"
    exit 0
fi
log "選択フォルダ: $IMAGE_DIR"

# 画面表示デバイスの事前確認
TTY_DEV=""
if [ "$VIEWER_MODE" = "tty" ]; then
    TTY_DEV="$RUN_TTY"
    log "表示先TTY: $TTY_DEV"
    VIEWER_BIN="fbi"

    if ! command -v fbi >/dev/null 2>&1; then
        show_error "fbi が見つかりません。'sudo apt install fbi' を実行してください。"
        exit 1
    fi

    if [ ! -w "$TTY_DEV" ]; then
        show_error "$TTY_DEV に書き込めません。'sudo usermod -aG tty pi' 実行後に再ログインしてください。"
        exit 1
    fi
else
    if command -v mpv >/dev/null 2>&1; then
        VIEWER_BIN="mpv"
    else
        show_error "GUIモードには mpv が必要です。'sudo apt install mpv' を実行してください。"
        exit 1
    fi
fi
log "使用ビューア: $VIEWER_BIN"

# 1枚あたりの表示時間（秒）
DURATION=10
log "表示秒数: $DURATION"

# ビューアが即終了した場合のCPU負荷を抑える待機秒数
LOOP_BACKOFF=2

# ビューアが短時間終了を繰り返したら、表示失敗とみなして安全終了
MAX_QUICK_EXIT=3
quick_exit_count=0

# ディスプレイのスリープ（消灯）を防止
xset -display :0 s off 2>/dev/null || true
xset -display :0 -dpms 2>/dev/null || true
if [ "$VIEWER_MODE" = "tty" ]; then
    setterm -blank 0 -powerdown 0 <$TTY_DEV >$TTY_DEV 2>&1 || true
fi
log "スリープ抑止設定を適用"

# ループ処理（ビューアが終了しても、最新の画像リストを読み直して再実行）
while true; do
    image_files=(
        "$IMAGE_DIR"/*.jpg
        "$IMAGE_DIR"/*.jpeg
        "$IMAGE_DIR"/*.png
        "$IMAGE_DIR"/*.gif
        "$IMAGE_DIR"/*.bmp
        "$IMAGE_DIR"/*.webp
    )

    # 対応画像ファイルが存在する場合のみ実行
    if [ ${#image_files[@]} -gt 0 ]; then
        start_ts=$(date +%s)

        if [ "$VIEWER_MODE" = "tty" ]; then
            # -t: 表示時間, -a: 自動リサイズ, -u: ランダム再生, -noverb: 下部のステータス非表示
            log "fbi 実行: $IMAGE_DIR (files=${#image_files[@]})"
            tty_num="${TTY_DEV#/dev/tty}"
            fbi -T "$tty_num" -t "$DURATION" -a -u -noverb "${image_files[@]}" &
        else
            log "mpv 実行: $IMAGE_DIR (files=${#image_files[@]})"
            mpv \
                --no-config \
                --gpu-context=wayland \
                --vo=gpu \
                --hwdec=no \
                --vd-lavc-dr=no \
                --cache=no \
                --demuxer-seekable-cache=no \
                --demuxer-max-bytes=8MiB \
                --demuxer-max-back-bytes=4MiB \
                --fs \
                --screen=0 \
                --geometry=100%x100%+0+0 \
                --no-keepaspect-window \
                --video-unscaled=no \
                --panscan=0 \
                --no-terminal \
                --image-display-duration="$DURATION" \
                --shuffle \
                --loop-playlist=inf \
                "${image_files[@]}" &
        fi

        VIEWER_PID=$!

        if [ "$VIEWER_MODE" = "gui" ]; then
            rm -f "$RELOAD_FLAG_FILE"
            current_sig="$(image_signature "$IMAGE_DIR")"
            (
                prev_sig="$current_sig"
                while kill -0 "$VIEWER_PID" 2>/dev/null; do
                    sleep 3
                    next_sig="$(image_signature "$IMAGE_DIR")"
                    if [ "$next_sig" != "$prev_sig" ]; then
                        touch "$RELOAD_FLAG_FILE"
                        kill -TERM "$VIEWER_PID" 2>/dev/null || true
                        break
                    fi
                done
            ) &
            MONITOR_PID=$!
        fi

        wait "$VIEWER_PID"
        viewer_rc=$?
        VIEWER_PID=""

        if [ -n "${MONITOR_PID}" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
            kill "$MONITOR_PID" 2>/dev/null || true
            wait "$MONITOR_PID" 2>/dev/null || true
        fi
        MONITOR_PID=""

        elapsed=$(( $(date +%s) - start_ts ))
        log "ビューア終了コード: $viewer_rc"
        log "ビューア実行時間: ${elapsed}s"

        if [ -f "$RELOAD_FLAG_FILE" ]; then
            rm -f "$RELOAD_FLAG_FILE"
            quick_exit_count=0
            log "画像フォルダの変更を検知したため、ビューアを再起動して一覧を更新します"
            continue
        fi

        # GUIモードでmpvが正常終了した場合は、ユーザー終了とみなして全体を終了
        if [ "$VIEWER_MODE" = "gui" ] && [ "$viewer_rc" -eq 0 ]; then
            log "GUIモードでビューアが正常終了したため、スライドショーを終了します"
            exit 0
        fi

        if [ "$viewer_rc" -ne 0 ]; then
            show_error "ビューアがエラー終了しました (rc=$viewer_rc)。プロセスを残さず終了します。"
            exit 1
        fi
        if [ "$elapsed" -lt 2 ]; then
            quick_exit_count=$((quick_exit_count + 1))
            log "WARN: ビューアが短時間で終了しました (count=${quick_exit_count}/${MAX_QUICK_EXIT})"
            if [ "$quick_exit_count" -ge "$MAX_QUICK_EXIT" ]; then
                show_error "画像表示に連続で失敗したため、安全に終了します。tty表示状態を確認してください。"
                exit 1
            fi
        else
            quick_exit_count=0
        fi
        log "次のループまで ${LOOP_BACKOFF}秒待機"
        sleep "$LOOP_BACKOFF"
    else
        log "対応画像が見つかりません。5秒後に再試行します..."
        sleep 5
    fi
done

#!/bin/bash
set -u

PLAYER_PID=""
BUSY_DIALOG_PID=""

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/pi_slideshow"
LOG_FILE="$LOG_DIR/slideshow.log"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/pi_slideshow"
WORK_DIR="$CACHE_DIR/work"
VIDEO_A="$CACHE_DIR/slideshow_a.mp4"
VIDEO_B="$CACHE_DIR/slideshow_b.mp4"
LIST_FILE="$WORK_DIR/images.concat.txt"
IPC_SOCKET="$CACHE_DIR/mpv.sock"

mkdir -p "$LOG_DIR" "$CACHE_DIR" "$WORK_DIR"
exec >>"$LOG_FILE" 2>&1

# 生成するスライドショー動画で、1枚の画像を表示する秒数。
IMAGE_DURATION=10
# 画像フォルダを再走査して変更を検知する間隔（秒）。
CHECK_INTERVAL=30
# メインループの待機間隔（秒）。短くすると境界検知の取りこぼしが減る。
POLL_INTERVAL=0.2
# 出力動画の解像度（幅:高さ）。画像は比率維持で余白付き配置される。
# 1280:720 は 1920:1080 よりエンコード負荷が軽く、生成が速い。
TARGET_RESOLUTION="1280:720"
# 生成動画の最大フレームレート。VFR(可変フレームレート)生成時の上限として使う。
# 静止画スライドは画像切替時のみフレームを持てば十分なので低めでよい。
VIDEO_FPS=1
# エンコード速度優先設定。Raspberry Pi では ultrafast 推奨。
ENCODE_PRESET="ultrafast"
# 画質と容量のバランス。値を上げるほど軽量/低画質。
ENCODE_CRF=28
# ループ境界を判定する余白（秒）。
# 直前のtime-posが終端側この範囲内、かつ現在のtime-posが先頭側この範囲内なら
# 「1ループ終了して先頭に戻った」と判定する。
LOOP_EDGE_SEC=1.5
# ループ境界を取りこぼした場合の保険（最小待機秒）。
# 実際の強制切替秒は「動画長 x FORCE_SWITCH_FACTOR」と比較して大きい方を使う。
FORCE_SWITCH_MIN_SEC=120
FORCE_SWITCH_FACTOR=1.2

log() {
    # Input: $* (log message)
    # Output: timestamped line to stdout/log
    # Return: 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

show_error() {
    # Input: $1 (error message)
    # Output: log + optional zenity dialog
    # Return: 0
    local msg="$1"
    log "ERROR: $msg"
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="スライドショー" --text="$msg" 2>/dev/null || true
    fi
}

cleanup_child() {
    # Input: none
    # Output: none
    # Return: 0
    # Side effect: terminate player and clear PLAYER_PID
    if [ -n "$PLAYER_PID" ] && kill -0 "$PLAYER_PID" 2>/dev/null; then
        kill "$PLAYER_PID" 2>/dev/null || true
        wait "$PLAYER_PID" 2>/dev/null || true
    fi
    PLAYER_PID=""
    if [ -n "$BUSY_DIALOG_PID" ] && kill -0 "$BUSY_DIALOG_PID" 2>/dev/null; then
        kill "$BUSY_DIALOG_PID" 2>/dev/null || true
        wait "$BUSY_DIALOG_PID" 2>/dev/null || true
    fi
    BUSY_DIALOG_PID=""
    rm -f "$IPC_SOCKET"
}

show_busy_start() {
    # Input: none
    # Output: visible busy dialog (yad) or fallback log
    # Return: 0
    if [ -n "${DISPLAY:-}" ] && command -v yad >/dev/null 2>&1; then
        # 前回異常終了時の取り残しダイアログを先に掃除する。
        pkill -f "yad --title=スライドショー" 2>/dev/null || true
        yad --title="スライドショー" \
            --text="\n\n\n初期動画を生成中です...\n" \
            --text-align=center \
            --no-buttons --on-top --center --fixed --geometry=320x90 \
            --undecorated --skip-taskbar --no-wrap 2>/dev/null &
        BUSY_DIALOG_PID=$!
        return 0
    fi

    log "【生成中】初期動画を生成しています..."
}

show_busy_end() {
    # Input: none
    # Output: close busy dialog asynchronously after short delay
    # Return: 0
    local pid="$BUSY_DIALOG_PID"
    BUSY_DIALOG_PID=""

    (
        sleep 2
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    ) &
}

handle_signal() {
    # Input: $1 (signal name)
    # Output: none
    # Return: none (exits process)
    log "シグナル受信: $1"
    cleanup_child
    exit 0
}

collect_images() {
    # Input: $1 (image directory)
    # Output: sorted image paths, one per line
    # Return: 0
    local dir="$1"
    find "$dir" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' -o -iname '*.heif' -o -iname '*.heic' \) \
        -print 2>/dev/null | sort
}

image_signature() {
    # Input: $1 (image directory)
    # Output: SHA256 signature string
    # Return: 0
    local dir="$1"
    collect_images "$dir" | while IFS= read -r f; do
        printf '%s\t%s\t%s\n' "$f" "$(stat -c '%s' "$f" 2>/dev/null || echo 0)" "$(stat -c '%Y' "$f" 2>/dev/null || echo 0)"
    done | sha256sum | awk '{print $1}'
}

auto_orient_inplace() {
    # Input: $1 (jpg file path)
    # Output: none (rewrites file with EXIF rotation baked into pixels)
    # Return: 0
    # HEIF/iPhone 由来の JPG は EXIF Orientation(例:6=90度回転)を持つが、
    # ffmpeg の concat demuxer はこのタグを無視して横倒しのまま再生してしまう。
    # ここで PIL を使い回転を実ピクセルへ適用しタグを除去することで、
    # 再生エンジンに依存せず常に正しい向きで表示させる。
    local f="$1"
    python3 - "$f" <<'PY' 2>/dev/null || true
import sys
try:
    from PIL import Image, ImageOps
except Exception:
    sys.exit(0)  # PIL が無ければ何もしない（向き補正をスキップ）
p = sys.argv[1]
try:
    im = Image.open(p)
    exif = im.getexif()
    orient = exif.get(0x0112) if exif else None
    if orient in (None, 0, 1):
        sys.exit(0)  # 回転不要
    fixed = ImageOps.exif_transpose(im)  # EXIF回転を実ピクセルへ適用
    fixed.save(p, quality=92)
except Exception:
    sys.exit(0)
PY
}

generate_concat_list() {
    # Input: $1 (image directory)
    # Output: LIST_FILE for ffmpeg concat demuxer
    # Return: 0
    local dir="$1"
    local last=""
    : >"$LIST_FILE"

    while IFS= read -r img; do
        local use_img="$img"
        # Convert HEIF/HEIC on-the-fly to temporary JPG if needed.
        # heif-convert (libheif) を優先し、無ければ ffmpeg にフォールバックする。
        case "$img" in
            *.heif|*.HEIF|*.heic|*.HEIC)
                local tmp_jpg="$WORK_DIR/temp_$(basename "${img%.*}").jpg"
                if command -v heif-convert >/dev/null 2>&1 \
                    && heif-convert "$img" "$tmp_jpg" >/dev/null 2>&1; then
                    use_img="$tmp_jpg"
                elif ffmpeg -y -hide_banner -loglevel error -i "$img" "$tmp_jpg" 2>/dev/null; then
                    use_img="$tmp_jpg"
                else
                    log "WARN: HEIF 変換失敗: $img"
                    continue
                fi
                # EXIF Orientation を実ピクセルへ焼き込み、横倒し再生を防ぐ。
                auto_orient_inplace "$tmp_jpg"
                ;;
        esac
        printf "file '%s'\n" "${use_img//\'/'\\'''}" >>"$LIST_FILE"
        printf "duration %s\n" "$IMAGE_DURATION" >>"$LIST_FILE"
        last="$use_img"
    done < <(collect_images "$dir")

    # concat demuxer needs the last file repeated so its duration applies.
    if [ -n "$last" ]; then
        printf "file '%s'\n" "${last//\'/'\\'''}" >>"$LIST_FILE"
    fi
}

build_video() {
    # Input: $1 (image directory), $2 (output video file path)
    # Output: writes output video atomically
    # Return: 0 success, 1 failure
    local dir="$1"
    local out_file="$2"
    local tmp_video="$WORK_DIR/$(basename "$out_file").tmp.mp4"
    local image_count=""
    local est_seconds=""

    generate_concat_list "$dir"
    if ! [ -s "$LIST_FILE" ]; then
        return 1
    fi

    image_count="$(collect_images "$dir" | wc -l)"
    est_seconds=$(( image_count * IMAGE_DURATION ))

    log "動画を再生成します: $(basename "$out_file") (images=${image_count}, est=${est_seconds}s)"
    # ffmpeg key options:
    # -y                  overwrite output
    # -hide_banner        suppress startup banner
    # -loglevel error     show errors only
    # -f concat -safe 0   use concat list (allows absolute paths)
    # -i LIST_FILE        image list with per-image duration
    # -vf ...             normalize frame size/format for stable playback
    # -vsync vfr          可変フレームレート出力。画像切替点のみフレームを持つため
    #                     1fps CFR のように同一フレームを量産せず、生成が大幅に速い。
    #                     concat の duration がそのまま各画像の表示時間になる。
    # -c:v libx264        H.264 encode
    # -preset ultrafast   prioritize encode speed on low-power devices
    # -crf 28             quality/size balance (higher = smaller/faster)
    # -movflags +faststart place metadata at file head
    if ! ffmpeg -y -hide_banner -loglevel error \
        -f concat -safe 0 -i "$LIST_FILE" \
        -vf "scale=${TARGET_RESOLUTION}:force_original_aspect_ratio=decrease,pad=${TARGET_RESOLUTION}:(ow-iw)/2:(oh-ih)/2,format=yuv420p" \
        -vsync vfr \
        -c:v libx264 -preset "$ENCODE_PRESET" -crf "$ENCODE_CRF" -movflags +faststart \
        "$tmp_video"; then
        rm -f "$tmp_video"
        return 1
    fi

    mv -f "$tmp_video" "$out_file"
    return 0
}

start_player() {
    # Input: $1 (video path)
    # Output: none
    # Return: 0 success, 1 failure
    # Side effect: restart mpv and set PLAYER_PID
    local video="$1"
    if [ ! -f "$video" ]; then
        return 1
    fi

    cleanup_child
    log "動画再生を開始します: $(basename "$video")"
    # mpv key options:
    # --no-config         ignore per-user config for deterministic behavior
    # --fs                fullscreen playback
    # --loop-file=inf     loop one file forever
    # --no-terminal       suppress terminal status UI
    # --input-ipc-server  expose control/status socket for loop-boundary detect
    mpv --no-config --fs --loop-file=inf --no-terminal --input-ipc-server="$IPC_SOCKET" "$video" &
    PLAYER_PID=$!
    return 0
}

mpv_ipc_get_number() {
    # Input: $1 (property name)
    # Output: numeric property value (stdout) or empty
    # Return: 0 success, 1 failure
    local prop="$1"
    python3 - "$IPC_SOCKET" "$prop" <<'PY'
import json
import socket
import sys

sock_path = sys.argv[1]
prop = sys.argv[2]

try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(0.5)
    s.connect(sock_path)
    payload = json.dumps({"command": ["get_property", prop]}) + "\n"
    s.sendall(payload.encode("utf-8"))

    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    s.close()

    if not data:
        raise RuntimeError("empty response")

    resp = json.loads(data.decode("utf-8").strip())
    if resp.get("error") != "success":
        raise RuntimeError("ipc error")

    value = resp.get("data")
    if isinstance(value, (int, float)):
        print(value)
    else:
        raise RuntimeError("non numeric")
except Exception:
    sys.exit(1)
PY
}

mpv_ipc_command() {
    # Input: $@ (mpv IPC command words, e.g. loadfile <path> replace)
    # Output: none
    # Return: 0 success, 1 failure
    # mpv の JSON IPC に任意コマンドを送る。loadfile などの制御に使う。
    python3 - "$IPC_SOCKET" "$@" <<'PY'
import json
import socket
import sys

sock_path = sys.argv[1]
cmd = sys.argv[2:]

try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(1.0)
    s.connect(sock_path)
    payload = json.dumps({"command": cmd}) + "\n"
    s.sendall(payload.encode("utf-8"))

    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    s.close()

    if not data:
        raise RuntimeError("empty response")

    resp = json.loads(data.decode("utf-8").strip())
    if resp.get("error") != "success":
        raise RuntimeError("ipc error")
except Exception:
    sys.exit(1)
PY
}

switch_video() {
    # Input: $1 (video path)
    # Output: none
    # Return: 0 success, 1 failure
    # 実行中の mpv に loadfile で新ファイルを読み込ませ、シームレスに切り替える。
    # mpv を終了・再起動しないため、切替時にデスクトップが一瞬見えることがない。
    local video="$1"
    if [ ! -f "$video" ] || [ ! -S "$IPC_SOCKET" ]; then
        return 1
    fi
    if mpv_ipc_command loadfile "$video" replace; then
        # loadfile 直後はループ設定を確実に効かせるため再指定する。
        mpv_ipc_command set_property loop-file inf >/dev/null 2>&1 || true
        log "動画をシームレス切替しました: $(basename "$video")"
        return 0
    fi
    return 1
}

is_loop_boundary() {
    # Input: $1 prev_time, $2 curr_time, $3 duration
    # Output: none
    # Return: 0 if loop boundary detected else 1
    local prev="$1"
    local curr="$2"
    local dur="$3"

    awk -v p="$prev" -v c="$curr" -v d="$dur" -v e="$LOOP_EDGE_SEC" 'BEGIN {
        if (d <= (e * 2)) exit 1;
        if (p >= (d - e) && c <= e) exit 0;
        # time-pos が急に小さくなった場合もループ境界とみなす（取りこぼし対策）。
        if ((c + e) < p) exit 0;
        exit 1;
    }'
}

log "----- slideshow start -----"

LOCK_FILE="/tmp/pi_slideshow.${EUID}.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    show_error "既にスライドショーが起動しています。"
    exit 1
fi

set -o errtrace
trap 'rc=$?; cleanup_child; log "終了コード: $rc"' EXIT
trap 'log "ERR line=$LINENO cmd=${BASH_COMMAND} rc=$?"' ERR
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

if [ -z "${DISPLAY:-}" ]; then
    show_error "GUI セッションで実行してください。"
    exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    show_error "ffmpeg が見つかりません。'sudo apt install ffmpeg' を実行してください。"
    exit 1
fi

if ! command -v mpv >/dev/null 2>&1; then
    show_error "再生コマンドが見つかりません。'sudo apt install mpv' を実行してください。"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    show_error "python3 が見つかりません。IPC制御に必要です。"
    exit 1
fi

IMAGE_DIR="${1:-}"
if [ -z "$IMAGE_DIR" ]; then
    if command -v zenity >/dev/null 2>&1; then
        IMAGE_DIR=$(zenity --file-selection --directory --title="画像フォルダを選択" --filename="${HOME}/" 2>/dev/null)
    else
        read -r -p "画像フォルダのパスを入力してください: " IMAGE_DIR
    fi
fi

if [ -z "$IMAGE_DIR" ] || [ ! -d "$IMAGE_DIR" ]; then
    log "有効な画像フォルダが選択されませんでした"
    exit 0
fi

log "選択フォルダ: $IMAGE_DIR"
log "画像表示秒数: $IMAGE_DURATION"

show_busy_start

sig="$(image_signature "$IMAGE_DIR")"
if ! build_video "$IMAGE_DIR" "$VIDEO_A"; then
    show_busy_end
    show_error "初期動画生成に失敗しました。画像ファイル形式を確認してください。"
    exit 1
fi

show_busy_end

ACTIVE_VIDEO="$VIDEO_A"
PENDING_VIDEO=""
PENDING_SIG=""
PENDING_SINCE=0
prev_sig="$sig"

if ! start_player "$ACTIVE_VIDEO"; then
    show_busy_end
    show_error "動画再生に失敗しました。"
    exit 1
fi

next_sig_check=$(( $(date +%s) + CHECK_INTERVAL ))
prev_time=""

while true; do
    now=$(date +%s)

    if [ -n "$PLAYER_PID" ] && ! kill -0 "$PLAYER_PID" 2>/dev/null; then
        log "再生ウィンドウが閉じられました。スライドショーを終了します"
        break
    fi

    if [ "$now" -ge "$next_sig_check" ]; then
        sig="$(image_signature "$IMAGE_DIR")"
        # 現在の再生中(prev_sig)とも、生成済みの保留動画(PENDING_SIG)とも異なる
        # 場合のみ再生成する。これにより同じ内容を毎回作り直す無駄を防ぐ。
        if [ "$sig" != "$prev_sig" ] && [ "$sig" != "$PENDING_SIG" ]; then
            if [ "$ACTIVE_VIDEO" = "$VIDEO_A" ]; then
                target="$VIDEO_B"
            else
                target="$VIDEO_A"
            fi

            if build_video "$IMAGE_DIR" "$target"; then
                PENDING_VIDEO="$target"
                PENDING_SIG="$sig"
                PENDING_SINCE="$now"
                log "更新動画を準備しました。次ループ境界で切り替えます"
            else
                log "WARN: 更新動画の再生成に失敗しました"
            fi
        fi
        next_sig_check=$(( now + CHECK_INTERVAL ))
    fi

    if [ -n "$PENDING_VIDEO" ] && [ -S "$IPC_SOCKET" ]; then
        dur="$(mpv_ipc_get_number duration 2>/dev/null || true)"
        cur="$(mpv_ipc_get_number time-pos 2>/dev/null || true)"

        if [ -n "$dur" ] && [ -n "$cur" ]; then
            if [ -n "$prev_time" ] && is_loop_boundary "$prev_time" "$cur" "$dur"; then
                log "ループ境界を検知。更新動画へ切り替えます"
                if switch_video "$PENDING_VIDEO"; then
                    ACTIVE_VIDEO="$PENDING_VIDEO"
                    prev_sig="$PENDING_SIG"
                    PENDING_VIDEO=""
                    PENDING_SIG=""
                    PENDING_SINCE=0
                    prev_time=""
                else
                    log "WARN: 更新動画への切替に失敗しました"
                fi
            else
                prev_time="$cur"
            fi
        fi

        # 境界判定を取りこぼしても、動画長に応じた待機時間を超えたら強制切替する。
        if [ -n "$PENDING_VIDEO" ] && [ "$PENDING_SINCE" -gt 0 ]; then
            elapsed=$(( now - PENDING_SINCE ))
            force_switch_sec="$(awk -v d="$dur" -v m="$FORCE_SWITCH_MIN_SEC" -v f="$FORCE_SWITCH_FACTOR" 'BEGIN {
                t = int((d * f) + 0.5);
                if (t < m) t = m;
                print t;
            }')"

            if [ "$elapsed" -ge "$force_switch_sec" ]; then
                log "ループ境界未検知が継続したため、更新動画へ強制切替します (elapsed=${elapsed}s, threshold=${force_switch_sec}s)"
                if switch_video "$PENDING_VIDEO"; then
                    ACTIVE_VIDEO="$PENDING_VIDEO"
                    prev_sig="$PENDING_SIG"
                    PENDING_VIDEO=""
                    PENDING_SIG=""
                    PENDING_SINCE=0
                    prev_time=""
                else
                    log "WARN: 強制切替に失敗しました"
                fi
            fi
        fi
    fi

    sleep "$POLL_INTERVAL"
done

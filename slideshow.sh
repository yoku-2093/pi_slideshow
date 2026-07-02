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
# 低解像度ほどエンコードが高速: 960:540=30-40%高速, 854:480=50-60%高速
TARGET_RESOLUTION="${SLIDESHOW_RESOLUTION:-1280:720}"
# エンコード速度優先設定。Raspberry Pi では ultrafast 推奨。
ENCODE_PRESET="ultrafast"
# 画質と容量のバランス。値を上げるほど軽量/低画質/高速。
ENCODE_CRF="${SLIDESHOW_CRF:-30}"
# フレームレート。静止画スライドショーでは低くても問題なし。
ENCODE_FPS="${SLIDESHOW_FPS:-15}"
# クリップ生成の並列数。CPUコア数に応じて調整。
MAX_PARALLEL="${SLIDESHOW_PARALLEL:-4}"
# GPUエンコーダーを使用するか (auto/yes/no)
USE_GPU_ENCODER="${SLIDESHOW_GPU:-auto}"
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

detect_gpu_encoder() {
    # Input: none
    # Output: encoder name (h264_v4l2m2m, h264_omx, or libx264)
    # Return: 0
    if [ "$USE_GPU_ENCODER" = "no" ]; then
        echo "libx264"
        return 0
    fi

    # h264_v4l2m2m を優先 (Raspberry Pi 4/5で安定)
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_v4l2m2m"; then
        # 実際にテストエンコードして動作確認
        if ffmpeg -y -f lavfi -i color=black:s=64x64:d=0.1 -c:v h264_v4l2m2m -f null - >/dev/null 2>&1; then
            echo "h264_v4l2m2m"
            return 0
        fi
    fi

    # h264_omx を次に試す (古いRaspberry Pi)
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_omx"; then
        if ffmpeg -y -f lavfi -i color=black:s=64x64:d=0.1 -c:v h264_omx -f null - >/dev/null 2>&1; then
            echo "h264_omx"
            return 0
        fi
    fi

    # フォールバック: ソフトウェアエンコーダー
    echo "libx264"
}

get_media_cache_key() {
    # Input: $1 (media file path)
    # Output: cache key (mtime-size-resolution-crf-fps)
    # Return: 0
    local f="$1"
    local mtime=$(stat -c '%Y' "$f" 2>/dev/null || echo 0)
    local size=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
    echo "${mtime}-${size}-${TARGET_RESOLUTION}-${ENCODE_CRF}-${ENCODE_FPS}"
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
    # Side effect: terminate player, dialogs and cleanup temporary files
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
            --text="\n\n\n動画を生成中です...\n" \
            --text-align=center \
            --no-buttons --on-top --center --fixed --geometry=320x90 \
            --undecorated --skip-taskbar --no-wrap 2>/dev/null &
        BUSY_DIALOG_PID=$!
        return 0
    fi

    log "【生成中】動画を生成しています..."
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

collect_media() {
    # Input: $1 (media directory)
    # Output: sorted media paths (images and videos), one per line, newest first
    # Return: 0
    local dir="$1"
    # stat で更新日時を取得し、sort -rn で新しい順にソート
    find "$dir" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' -o -iname '*.heif' -o -iname '*.heic' -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.mkv' -o -iname '*.webm' \) \
        -exec stat -c '%Y %n' {} \; 2>/dev/null | sort -rn | cut -d' ' -f2-
}

media_signature() {
    # Input: $1 (media directory)
    # Output: SHA256 signature string
    # Return: 0
    local dir="$1"
    collect_media "$dir" | while IFS= read -r f; do
        printf '%s\t%s\t%s\n' "$f" "$(stat -c '%s' "$f" 2>/dev/null || echo 0)" "$(stat -c '%Y' "$f" 2>/dev/null || echo 0)"
    done | sha256sum | awk '{print $1}'
}

check_needs_rotation() {
    # Input: $1 (jpg file path)
    # Output: none
    # Return: 0 if rotation needed, 1 otherwise
    local f="$1"
    python3 - "$f" <<'PY' 2>/dev/null
import sys
try:
    from PIL import Image
except Exception:
    sys.exit(1)  # PIL が無ければ回転不要扱い

p = sys.argv[1]
try:
    im = Image.open(p)
    exif = im.getexif()
    orient = exif.get(0x0112) if exif else None
    if orient and orient not in (0, 1):
        sys.exit(0)  # 回転必要
    sys.exit(1)  # 回転不要
except Exception:
    sys.exit(1)
PY
}

apply_rotation() {
    # Input: $1 (source jpg file path), $2 (destination jpg file path)
    # Output: none (creates destination with EXIF rotation baked into pixels)
    # Return: 0 if success, 1 if failed
    local src="$1"
    local dst="$2"

    # PIL での回転処理の代わりに、ffmpeg -autorotate を使用
    # これにより concat demuxer との互換性問題を回避
    if ffmpeg -y -hide_banner -loglevel fatal -autorotate 1 -i "$src" -q:v 2 "$dst" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

convert_video_to_clip() {
    # Input: $1=index $2=video_path $3=encoder
    # Output: writes converted video clip
    # Return: 0 success, 1 failure (outputs converted path on success)
    local idx="$1"
    local video="$2"
    local encoder="$3"
    local converted_clip="$WORK_DIR/video_$(printf '%03d' $idx).mp4"
    local cache_key=$(get_media_cache_key "$video")
    local cache_meta="$WORK_DIR/video_$(printf '%03d' $idx).meta"
    local encoder_opts=""

    # キャッシュチェック
    if [ -f "$cache_meta" ] && [ -f "$converted_clip" ]; then
        if [ "$(cat "$cache_meta" 2>/dev/null)" = "$cache_key" ]; then
            echo "$converted_clip"
            return 0
        fi
    fi

    # GPUエンコーダー優先
    if [ "$encoder" = "h264_v4l2m2m" ] || [ "$encoder" = "h264_omx" ]; then
        encoder_opts="-c:v $encoder -b:v 2M"
    else
        encoder_opts="-c:v libx264 -preset $ENCODE_PRESET -crf $ENCODE_CRF"
    fi

    if ffmpeg -y -hide_banner -loglevel error -i "$video" \
        -vf "scale=${TARGET_RESOLUTION}:force_original_aspect_ratio=decrease,pad=${TARGET_RESOLUTION}:(ow-iw)/2:(oh-ih)/2,format=yuv420p" \
        -r "$ENCODE_FPS" $encoder_opts \
        -an -movflags +faststart \
        "$converted_clip" 2>/dev/null; then
        echo "$cache_key" > "$cache_meta"
        echo "$converted_clip"
        return 0
    fi

    return 1
}

convert_image_to_clip() {
    # Input: $1=index $2=image_path
    # Output: single-frame video clip path
    # Return: 0 success, 1 failure
    local idx="$1"
    local image="$2"
    local use_image="$image"
    local converted_clip="$WORK_DIR/image_$(printf '%03d' $idx).mp4"
    local cache_key=$(get_media_cache_key "$image")
    local cache_meta="$WORK_DIR/image_$(printf '%03d' $idx).meta"
    local tmp_jpg=""
    local tmp_raw=""

    # キャッシュチェック
    if [ -f "$cache_meta" ] && [ -f "$converted_clip" ]; then
        if [ "$(cat "$cache_meta" 2>/dev/null)" = "$cache_key" ]; then
            echo "$converted_clip"
            return 0
        fi
    fi

    # HEIF/HEIC を JPG に変換
    case "$image" in
        *.heif|*.HEIF|*.heic|*.HEIC)
            tmp_jpg="$WORK_DIR/temp_$(basename "${image%.*}").jpg"
            tmp_raw="$WORK_DIR/temp_raw_$(basename "${image%.*}").jpg"

            if command -v heif-convert >/dev/null 2>&1; then
                if heif-convert "$image" "$tmp_raw" >/dev/null 2>&1; then
                    if check_needs_rotation "$tmp_raw"; then
                        if apply_rotation "$tmp_raw" "$tmp_jpg"; then
                            use_image="$tmp_jpg"
                            rm -f "$tmp_raw"
                        else
                            mv -f "$tmp_raw" "$tmp_jpg"
                            use_image="$tmp_jpg"
                        fi
                    else
                        mv -f "$tmp_raw" "$tmp_jpg"
                        use_image="$tmp_jpg"
                    fi
                else
                    return 1
                fi
            else
                return 1
            fi
            ;;
    esac

    # 画像を1フレームの動画に変換（超高速）
    if ffmpeg -y -hide_banner -loglevel error \
        -loop 1 -i "$use_image" -vframes 1 \
        -vf "scale=${TARGET_RESOLUTION}:force_original_aspect_ratio=decrease,pad=${TARGET_RESOLUTION}:(ow-iw)/2:(oh-ih)/2,format=yuv420p" \
        -c:v libx264 -preset ultrafast -crf 23 \
        -movflags +faststart \
        "$converted_clip" 2>/dev/null; then
        echo "$cache_key" > "$cache_meta"
        echo "$converted_clip"
        return 0
    fi

    return 1
}

generate_concat_list() {
    # Input: $1 (media directory)
    # Output: LIST_FILE for ffmpeg concat demuxer
    # Return: 0
    local dir="$1"
    local media_list="$WORK_DIR/media_list.txt"
    local encoder=$(detect_gpu_encoder)
    local idx=0
    local video_idx=0
    local is_video=""
    local media=""
    local use_media=""
    local parallel_count=0
    local pids=()
    local completed_count=0
    local video_count=0
    local last=""

    log "エンコーダー: $encoder (解像度:${TARGET_RESOLUTION}, CRF:${ENCODE_CRF}, FPS:${ENCODE_FPS}, 並列:${MAX_PARALLEL})"

    : >"$LIST_FILE"

    collect_media "$dir" > "$media_list"
    local total_count=$(wc -l < "$media_list")
    local image_idx=0

    log "全メディアを1フレーム動画に変換中: ${total_count}件"

    # すべてのメディア（画像・動画）を並列で1フレーム動画に変換
    while IFS= read -r media <&3; do
        idx=$((idx + 1))
        is_video=false

        case "$media" in
            *.mp4|*.MP4|*.mov|*.MOV|*.avi|*.AVI|*.mkv|*.MKV|*.webm|*.WEBM)
                is_video=true
                video_idx=$((video_idx + 1))
                ;;
            *)
                image_idx=$((image_idx + 1))
                ;;
        esac

        # 並列変換
        (
            if [ "$is_video" = "true" ]; then
                result=$(convert_video_to_clip "$video_idx" "$media" "$encoder")
                type="video"
            else
                result=$(convert_image_to_clip "$image_idx" "$media")
                type="image"
            fi
            if [ -n "$result" ]; then
                echo "$idx|$type|$result" > "$WORK_DIR/media_result_${idx}.txt"
            fi
        ) &

        pids+=($!)
        parallel_count=$((parallel_count + 1))

        # 並列数制限
        if [ "$parallel_count" -ge "$MAX_PARALLEL" ]; then
            wait "${pids[@]}"
            pids=()
            parallel_count=0
        fi
    done 3< "$media_list"

    # 残りの変換を待機
    if [ ${#pids[@]} -gt 0 ]; then
        wait "${pids[@]}"
    fi

    # 結果をインデックス順にソートしてリストに追加
    for result_file in "$WORK_DIR"/media_result_*.txt; do
        [ -f "$result_file" ] || continue
        while IFS='|' read -r idx_val type_val path_val; do
            echo "$idx_val|$type_val|$path_val"
        done < "$result_file"
    done | sort -t'|' -k1 -n | while IFS='|' read -r idx_val type_val path_val; do
        [ -z "$path_val" ] && continue

        # 動画はその動画の長さ、画像はIMAGE_DURATION
        if [ "$type_val" = "video" ]; then
            local media_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$path_val" 2>/dev/null || echo "1")
        else
            local media_duration="$IMAGE_DURATION"
        fi

        printf "file '%s'\n" "$path_val" >>"$LIST_FILE"
        printf "duration %s\n" "$media_duration" >>"$LIST_FILE"
        last="$path_val"
    done

    # concat demuxer needs the last file repeated
    if [ -n "$last" ]; then
        printf "file '%s'\n" "$last" >>"$LIST_FILE"
    fi

    rm -f "$WORK_DIR"/media_result_*.txt
}

build_video() {
    # Input: $1 (media directory), $2 (output video file path)
    # Output: writes output video atomically
    # Return: 0 success, 1 failure
    local dir="$1"
    local out_file="$2"
    local tmp_video="$WORK_DIR/$(basename "$out_file").tmp.mp4"
    local media_count=""
    local est_seconds=""

    generate_concat_list "$dir"
    if ! [ -s "$LIST_FILE" ]; then
        return 1
    fi

    media_count="$(collect_media "$dir" | wc -l)"
    est_seconds=$(( media_count * IMAGE_DURATION ))

    log "動画を再生成します: $(basename "$out_file") (media=${media_count}, est=${est_seconds}s)"
    # ffmpeg key options:
    # -y                  overwrite output
    # -hide_banner        suppress startup banner
    # -loglevel error     show errors (but exit code determines success)
    # -f concat -safe 0   use concat list (allows absolute paths)
    # -i LIST_FILE        画像と変換済み動画の混在リスト
    # -vf ...             画像のみ正規化（動画は既に変換済み）
    # -vsync vfr          可変フレームレート（画像は1フレーム、動画は元のまま）
    # -c:v libx264        エンコード
    # -movflags +faststart place metadata at file head
    # エラー出力は記録するが、終了コードで成否を判定
    ffmpeg_output=$(ffmpeg -y -hide_banner -loglevel error \
        -f concat -safe 0 -i "$LIST_FILE" \
        -vf "scale=${TARGET_RESOLUTION}:force_original_aspect_ratio=decrease,pad=${TARGET_RESOLUTION}:(ow-iw)/2:(oh-ih)/2,format=yuv420p" \
        -vsync vfr \
        -c:v libx264 -preset "$ENCODE_PRESET" -crf "$ENCODE_CRF" -movflags +faststart \
        -an \
        "$tmp_video" 2>&1)
    ffmpeg_exit=$?

    # 動画が正常に生成されたか確認（終了コードではなくファイルの存在で判定）
    # ffmpegは警告があってもexit code 0以外を返すことがあるが、ファイルは生成される
    if [ ! -s "$tmp_video" ]; then
        log "ERROR: 動画ファイルが生成されませんでした (ffmpeg exit code: $ffmpeg_exit)"
        [ -n "$ffmpeg_output" ] && log "ffmpeg output: $ffmpeg_output"
        rm -f "$tmp_video"
        return 1
    fi

    # ファイルが生成されていれば成功（警告は無視）
    if [ $ffmpeg_exit -ne 0 ]; then
        log "WARN: ffmpeg returned exit code $ffmpeg_exit but file was generated successfully"
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
    # --no-audio          音声を再生しない
    mpv --no-config --fs --loop-file=inf --no-terminal --no-audio --input-ipc-server="$IPC_SOCKET" "$video" &
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
trap 'rc=$?; cleanup_child; rm -f "$LOCK_FILE"; log "終了コード: $rc"' EXIT
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

sig="$(media_signature "$IMAGE_DIR")"
if ! build_video "$IMAGE_DIR" "$VIDEO_A"; then
    show_busy_end
    show_error "動画生成に失敗しました。メディアファイル形式を確認してください。"
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
        sig="$(media_signature "$IMAGE_DIR")"
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

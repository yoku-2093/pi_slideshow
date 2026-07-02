# pi_slideshow

Raspberry Pi の画像・動画フォルダを、GUI 上で安定表示するスライドショーツールです。

画像や動画をそのまま順送りするのではなく、`ffmpeg` で 1 本の動画にまとめてから再生します。
これにより、ファイルサイズ差による切替ムラを減らしています。

## 仕組み

1. 画像・動画フォルダから concat リストを生成
2. `ffmpeg` でスライドショー動画（`slideshow_a.mp4` / `slideshow_b.mp4`）を作成
3. `mpv` で動画を無限ループ再生
4. フォルダ変更時は裏で新動画を再生成（`pending_video`）
5. `mpv` の IPC でループ境界（終端→先頭）を検知し、`loadfile` でシームレスに切替

このため、再生成直後に途中割り込みせず、次ループ頭で差し替えます。
切替は `mpv` を再起動せず行うため、切替時にデスクトップ画面が一瞬見えることはありません。

## 特徴

- GUI 専用（TTY 切替なし）
- 画像は 1枚あたり表示時間を `IMAGE_DURATION` で制御、動画は元の長さで再生
- 画像・動画の追加・削除・更新を定期監視して反映
- ループ境界での遅延切替（`pending_video`）＋ `mpv` IPC によるシームレス切替
- VFR（可変フレームレート）+ 720p 生成で Raspberry Pi でも高速にエンコード
- JPG/JPEG/HEIF/HEIC の EXIF 回転（向き）を自動補正
- 動画生成中は `yad` で待機ダイアログを表示
- ログを `~/.local/state/pi_slideshow/slideshow.log` に保存

## 必要パッケージ

```bash
sudo apt update
sudo apt install -y ffmpeg mpv zenity python3 yad
```

### 任意（推奨）

- `python3-pil`（PIL/Pillow）: JPG/JPEG の向き（EXIF Orientation）補正に使用

```bash
sudo apt install -y python3-pil
```

## 対応形式

### 画像形式

以下の画像形式に対応しています：

- JPG / JPEG
- PNG
- GIF
- BMP
- WebP
- HEIF / HEIC

HEIF / HEIC 形式（iPhone や Google Photos で使われることがあります）は、
動画生成時に自動で一時 JPG へ変換してから使用します。
変換時に `ffmpeg` の `-autorotate 1` オプションで回転情報を実ピクセルへ適用するため、
正しい向きで表示されます。
元のフォルダ内のファイルは変更しません（変換ファイルは作業ディレクトリに作成されます）。

また、JPG/JPEG も撮影時の向きを EXIF Orientation タグで持つことがあります。
`ffmpeg` の concat demuxer はこのタグを無視するため、そのままでは横倒しで表示されてしまいます。
本ツールは PIL（Pillow）で回転を実ピクセルへ焼き込み、常に正しい向きで表示します。
（PIL が無い環境では向き補正をスキップします）

### 動画形式

以下の動画形式に対応しています：

- MP4
- MOV
- AVI
- MKV
- WebM

動画ファイルは元の長さ（秒数）のままスライドショーに含まれます。
画像のように固定秒数ではなく、動画の実際の再生時間が使用されます。

## インストール

```bash
cd /home/pi/src/pi_slideshow
./install.sh
```

インストール内容:

- `slideshow.sh` を `~/.local/share/pi_slideshow/` へ配置
- `slideshow.desktop` を `~/.local/share/applications/pi-slideshow.desktop` として配置
- メニュー更新コマンド実行

## 起動

### メニューから

アプリメニューの「スライドショー」を起動。

### コマンドから

```bash
~/.local/share/pi_slideshow/slideshow.sh /path/to/images
```

引数なしの場合はフォルダ選択ダイアログが開きます。

## 主な設定（`slideshow.sh`）

- `IMAGE_DURATION=10` : 1枚あたり秒数
- `CHECK_INTERVAL=30` : 画像変更チェック間隔（秒）
- `POLL_INTERVAL=0.2` : IPC ポーリング間隔（秒）
- `TARGET_RESOLUTION="1280:720"` : 出力動画解像度（720p。負荷が軽く生成が速い）
- `ENCODE_PRESET="ultrafast"` : エンコード速度優先（Raspberry Pi 推奨）
- `ENCODE_CRF=28` : 画質と容量のバランス（値を上げるほど軽量・低画質）
- `LOOP_EDGE_SEC=1.5` : ループ境界判定のしきい値（秒）
- `FORCE_SWITCH_MIN_SEC=120` / `FORCE_SWITCH_FACTOR=1.2` : 境界検知を取りこぼした場合の強制切替の保険

## ログ確認

```bash
tail -f ~/.local/state/pi_slideshow/slideshow.log
```

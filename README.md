# pi_slideshow

Raspberry Pi の画像フォルダを、GUI 上で安定表示するスライドショーツールです。

画像をそのまま順送りするのではなく、`ffmpeg` で 1 本の動画にまとめてから再生します。
これにより、画像サイズ差による切替ムラを減らしています。

## 仕組み

1. 画像フォルダから concat リストを生成
2. `ffmpeg` でスライドショー動画（`slideshow_a.mp4` / `slideshow_b.mp4`）を作成
3. `mpv` で動画を無限ループ再生
4. フォルダ変更時は裏で新動画を再生成（`pending_video`）
5. `mpv` の IPC でループ境界（終端→先頭）を検知して切替

このため、再生成直後に途中割り込みせず、次ループ頭で差し替えます。

## 特徴

- GUI 専用（TTY 切替なし）
- 1枚あたり表示時間は `IMAGE_DURATION` で制御
- 画像追加・削除・更新を定期監視して反映
- ループ境界での遅延切替（`pending_video`）
- 初期動画生成中は `yad` で待機ダイアログを表示
- ログを `~/.local/state/pi_slideshow/slideshow.log` に保存

## 必要パッケージ

```bash
sudo apt update
sudo apt install -y ffmpeg mpv zenity python3 yad
```

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
- `POLL_INTERVAL=1` : IPC ポーリング間隔（秒）
- `TARGET_RESOLUTION="1920:1080"` : 出力動画解像度
- `LOOP_EDGE_SEC=0.8` : ループ境界判定のしきい値（秒）

## ログ確認

```bash
tail -f ~/.local/state/pi_slideshow/slideshow.log
```

## 停止方法（VNC/GUIから）

```bash
pkill -f slideshow.sh || true
pkill -x mpv || true
```

## トラブルシュート

- 画像が反映されない
  - `CHECK_INTERVAL` の間隔後に再生成されます
  - ログに `更新動画を準備しました` が出るか確認

- 切替がぎこちない
  - ループ境界切替時にわずかな切れ目が出る場合があります
  - `TARGET_RESOLUTION` と `IMAGE_DURATION` を調整すると改善することがあります

- 再生が始まらない
  - `DISPLAY` がある GUI セッションで起動しているか確認
  - `ffmpeg`, `mpv`, `python3` がインストール済みか確認

## ファイル構成

- `slideshow.sh` : 本体
- `slideshow.desktop` : デスクトップエントリ
- `install.sh` : 配置・メニュー更新

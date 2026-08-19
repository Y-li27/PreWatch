# Echo Clock App (Flutter)

Echo Show 5（Android 11改造）向けのシンプルな2×2ダッシュボードです。

## 表示内容
- 左上：大きな時計（時分＋秒）
- 右上：日付・曜日（日本語）
- 左下：東京の現在天気（Open-Meteo API・APIキー不要）
- 右下：選択した画像の表示

## 使い方

1. Flutterがインストールされている環境でこのフォルダを開く
2. `flutter pub get`
3. 実機またはエミュレータで `flutter run`
4. APKを作りたい場合：`flutter build apk --release`

## アラームを変更したい場合

1. `assets` に `wakeuptime.wav` を入れてください。
2. その上で`main.dart` の `wakeuptime.wav` を変更してください。

## 注意
- 天気は30分ごとに自動更新します

# RouteDiary iOS Port v0.2 — Android v2.11 の機能をiPhoneへ移植

Windowsだけで編集し、GitHub ActionsのmacOSランナーで署名なしIPAを生成するSwiftUIプロジェクトです。
前回の **RouteDiary iOS Trial v0.1** からの継続版です。

## 重要：現在の検証状況

- **ソースコードとビルド設定**を提供しています。**IPAそのものではありません**。
- Swift構文解析・XML plist・YAML・翻訳JSON・アーカイブ検査をローカルで実施しています。
- この環境にXcode/iOS SDKはないため、**SwiftのiOS向け型検査、Xcodeによるビルド、iPhone実機テストは未実施**です。
- GitHub Actionsが赤くなった場合、`xcodebuild-log` の内容を確認して修正してください。

## 実装済み（今回の変更）

| Android v2.11の機能 | iOS版v0.2 | 補足 |
|---|---|---|
| GPS記録・測位待ち・初回位置の再記録防止 | 実装 | 35m精度/15秒鮮度/25m移動判定など |
| 画面OFF中のバックグラウンド記録 | 実装 | iOSが停止・強制終了した後の継続は保証不可 |
| 地図・衛星写真・現在地・追従 | 実装 | Apple MapKitを使用、Android版のOSMとは地図が異なる |
| 方位磁石・地図回転・円形画像 | 実装 | Android v2.11のコンパス画像を同梱 |
| 滞在時間・最高速度・日別集計 | 実装 | 日付越えの集計を分割、表示日は変更可能 |
| 6項目のダッシュボード並び替え・表示切替 | 実装 | 設定画面やアカウント画面（未ログインでも可）から変更 |
| 記録除外エリアの複数追加・編集・削除 | 実装 | 地図＋・地図長押し・現在地から追加。半径10～5000m |
| 除外内の記録抑止・滞在時間・GPS断絶処理 | 実装 | 個別除外のGPS位置履歴は保存しない |
| 記録地点ピン表示切替・詳細表示 | 実装 | 描画負荷のため地図上のピンは直近350個まで |
| 現在地の青丸 / プロフィール画像 | 実装 | ログイン・画像取得時に利用できる |
| Android互換CSV 14列 v1.6 | 実装 | 6列/11列旧形式も取り込み可。選択日を出力 |
| クラウドへ履歴バックアップ・復元 | **実装（未接続検証）** | Androidと同じ`sync_push` / `sync_pull` / `sync_stats`を呼ぶ |
| 会員登録・ログイン・復旧コード・パス変更 | **実装（未接続検証）** | Android v2.11と同じAPIを使用 |
| プロフィール画像選択・十字ガイド・トリミング | 実装 | ピンチ拡大・ドラッグ移動、512px JPEGに変換 |
| 日本語・英語・簡体中国語 | 実装 | Androidの翻訳JSONを移植。動的なGPS状態文字列などは日本語のままの場合あり |
| ダークモード | 実装 | 設定で切替 |
| ログ・エラー情報 | 実装 | 機密情報やGPS座標をログへ出力しない |
| バージョン情報・オンライン更新 | 代替実装 | IPA作成→Sideloadlyで再署名、AndroidのAPK自動更新は使用不可 |

### 注意点

- **クラウド接続は未検証**です。サーバー`https://cc.zsg.jp/routediary/api/v1/index.php`が実装済みで、認証・同期APIがAndroid版と同じ形式の場合に動作する設計です。サーバー側がまだ未実装なら連携できません。DBやサーバー構成には変更を加えません。
- **認証トークンはKeychain**に保存します。クラウドに別アカウントの端末履歴を誤送信しないよう、端末内の利用者名を記憶して切り替えを制限します。位置履歴が実際に誰のものかをサーバーが確認する仕組みではありません。
- AndroidとiOSでUIの組み立ては異なります。Androidの左スライドメニューの代わりにiPhoneではタブ画面を採用しています。地図タイルやOSのバックグラウンド動作は完全に同一にはなりません。
- Android版で既に実装された全細部の**完全な1対1動作を検証したという意味ではありません**。特にクラウド接続、多言語の動的文言、GPS長時間試験、プロフィール画像の初回登録、メモリ消費はiPhone実機で検証が必要です。

## Windowsでの更新方法（今のiOS v0.1から上書き）

**重要：iPhone上のアプリをアンインストールしないでください。** 同じBundle IDを保持しています。

1. 本ZIPを展開します。
2. `RouteDiary-iOS-v0.2` の**中にあるファイル・フォルダー**（`.github`, `Sources`, `project.yml`など）を開きます。
3. GitHubの既存リポジトリ `RouteDiary-iOS-Trial` を開き、「Add file → Upload files」でファイル・フォルダーをアップロードし、`Commit changes`します。
4. GitHub Actionsの **Build unsigned RouteDiary IPA** からビルドします。`push: main` でも自動的に起動します。
5. 緑のチェック後、実行詳細にある `Artifacts → RouteDiary-iOS-trial-unsigned` をクリックしてZIPを取得します。
6. 中の `RouteDiary-iOS-trial-unsigned.ipa` をSideloadlyに読み込み、**以前と同じApple Account**でiPhoneへ上書きインストールします。
7. 起動後に「設定 → バージョン情報」で **0.2** を確認します。

GitHub Webのアップロードで`.github`が上書きされない場合、既存のActions workflowのままでも`project.yml`と`Sources`を更新すれば動作します。ただし、同梱のWorkflowはリソースの存在検査などが増えています。

### GitHubでコードがアップロードできないとき

一度にフォルダー全体を更新しにくい場合は、WindowsでGitHub DesktopまたはGit CLIを使用できます。

```powershell
# 初回のみ。以下は既存リポジトリをクローンする例です。
git clone https://github.com/<GitHubユーザー>/<リポジトリ>.git
cd <リポジトリ>
# ZIPの展開先にある中身をここにコピー（古い .github / Sources を上書き）
git add .
git commit -m "Port Android RouteDiary v2.11 features to iOS 0.2"
git push origin main
```

`<GitHubユーザー>` 等は実際の名前に置き換えてください。GitHubの認証が必要です。

## 動作確認順

1. IPAビルド成功、Sideloadlyで上書きインストール、バージョン **0.2** を確認
2. 「設定 → 地図・外観・言語」「カスタム画面」で各機能を試す
3. GPS記録開始 → 外出 → 25m以上移動 → 日別履歴と距離を確認
4. 画面をOFFにして継続記録できるか確認。終了/再起動後の連続記録は保証対象外
5. GPS停止 → Androidで書き出したCSVをiPhoneで取り込む → 日付選択と履歴を確認
6. 除外エリア（現在地/地図で指定） → 記録抑止・合計時間・日またぎを確認
7. 会員アカウントへログイン → クラウドへ全履歴バックアップ → 復元 → 重複しないことを確認
8. ダークモード / 英語 / 中国語 / アイコン画像トリミングを確認

## iOS固有の制約

- App Store・TestFlightの公開はApple Developer Programが必要です。
- 無料Apple AccountでSideloadly署名したアプリは通常7日間で署名期限切れです。期限が切れると起動できません。
- iOSのCoreLocationは、アプリが明示的に終了された後の毎秒GPS記録を保証しません。
- iOSではAPK形式の自動更新はできません。同じBundle IDを保ってIPAを再署名/上書きしてください。
- iOS向けの機能であっても、無料署名で使える権限には限界があります。今回のプロジェクトにVPN機能は含みません。

## 主要なファイル

```
.github/workflows/build-ios.yml   GitHub Actions IPAビルド
project.yml                       XcodeGenプロジェクト定義
Sources/RouteDiaryApp.swift       エントリポイント
Sources/RootView.swift            地図と日別ダッシュボード
Sources/HistorySettingsView.swift 履歴・CSV・設定
Sources/LocationRecorder.swift    CoreLocation GPS + heading
Sources/TrackStore.swift          SQLite
Sources/CSVBridge.swift           Android互換CSV
Sources/CloudClient.swift         Keychain・HTTP API・同期
Sources/AccountView.swift         会員登録・ログイン・プロフィール
Sources/CloudBackupView.swift     クラウドバックアップと復元
Sources/AvatarCropView.swift      画像手動トリミング
Sources/AppPreferences.swift      日英中・カスタムダッシュボード
Sources/Diagnostics.swift         ログ画面
Sources/Resources/               Android v2.11コンパス画像と翻訳JSON
```

# RouteDiary iOS Trial v0.1 — Windows開発・無料Apple Account向け

Android版 **RouteDiary v2.11** (`RouteDiary-Android-v2.11-source(1).zip`) を基に作成した、**SwiftUI + CoreLocation + MapKit + SQLite3** のiPhone移植試験用ソースコードです。

> **これはIPAではありません。** Mac / Xcodeを手元に用意せず、GitHub Actions の macOS ランナー上で `xcodebuild` を実行して**未署名IPA**を作るプロジェクトです。Appleの無料署名で実機利用する場合は各自がSideloadly等で署名します。実機の動作とクラウドビルドは、この作業環境からは未検証です。

## 1. 実装済み（試験版）

- SwiftUIの地図、MapKitの標準/衛星切替、現在地、GPSルートの描画、GPS断線区間の非接続表示
- iOS CoreLocationによる**ユーザーが明示的に開始したGPS記録**。アプリ初回起動だけでは記録開始しません
- 古い/精度の悪い座標の破棄：**15秒以内、水平精度35m以内**、0mより大きい精度のみ保存
- 既定**25m**の移動しきい値、**30秒**の最短保存間隔、**60秒**の滞在判定
- 45秒を超えるGPS途切れや除外エリアを跨ぐと、再開時はギャップフラグで区切り、その区間の距離を加算しません
- 移動速度、日別最高速度、滞在時間（0時で分割）、除外エリア滞在（座標なし）のSQLite記録
- 除外エリアの追加（地図＋から任意の場所をタップ / GPS現在地）、半径・名称変更と削除
- 日別表示、ルート再表示、履歴の一覧表示、日別削除と全履歴削除
- Androidの**14列CSV v1.6**と互換のエクスポート、インポート（`POINT / STAY / ZONE_STAY / MAX_SPEED`）。旧6列CSV / 11列CSVも読み込み対応
- Android版ランチャーアイコンをiOS用に転用
- iOS 17以上のiPhone対象

## 2. Android版からの移植上の違い / 未実装

| 機能 | この試験版 |
| --- | --- |
| GPS記録・画面OFF中の記録 | 実装。iOSの許可/バックグラウンド管理次第で継続。実機確認が必要 |
| 強制終了してから自動でGPSを続ける | **保証しない**。本試験版はユーザーによる再開を優先 |
| AndroidのGPSプロバイダ指定 | iOSでは取得方式を直接指定できないため、鮮度と精度で除外 |
| 日別移動距離・滞在・最高速度 | 実装 |
| 記録除外エリア | 実装（保存なし・滞在時間のみ） |
| 地図の衛星切替 | 実装（Apple MapKit、Android版のOSM/Esriとは地図提供元が異なる） |
| 方位磁石による地図回転 | **未実装** |
| 滞在タイトル編集 | 実装 |
| アバター / プロフィール / 会員登録 | **未実装** |
| `cc.zsg.jp` MySQL・PHPのクラウド同期 | **未実装**。意図的にサーバー連携・認証情報は入れていません |
| AndroidのLAN内APK自動アップデート | **未実装**。iOS版はIPAを再ビルド・再署名する方式 |
| 画面のダーク対応 | iOSのシステムカラーに自動追従 |
| 中国語・英語の画面 | **未実装**（今回のUIは日本語） |
| CSV | 14列互換を実装。大量CSVは実機で性能検証が必要 |

**注意:** バックグラウンド位置記録はAppleの仕様上、記録開始前に利用者の位置情報許可が必要です。利用者がアプリを強制終了した場合やOSに停止された場合、AndroidのForeground Serviceと完全に同じ継続動作にはなりません。

## 3. WindowsでGitHubへアップロード

**必要:** Windows 10/11、Git、GitHubアカウント、（任意）VS Code。Apple Developer Programへの有料登録なし。

1. このZIPをWindowsで任意のフォルダーに展開してください。
2. [GitHub](https://github.com/new) で空のリポジトリ `RouteDiary-iOS-Trial` を新規作成します。既存ファイルと衝突するため、READMEを自動追加せず空で作ってください。
3. PowerShellで解凍フォルダーに移動して、次を実行します。`YOURNAME` を自分のGitHubユーザー名に置き換えてください。

```powershell
cd "C:\開発\RouteDiary-iOS-Trial"
git init
git add .
git commit -m "Initial RouteDiary iOS trial"
git branch -M main
git remote add origin https://github.com/YOURNAME/RouteDiary-iOS-Trial.git
git push -u origin main
```

GitHubのサインイン画面が出たらブラウザーで認証します。**Apple Accountや位置履歴CSV、パスワードはGitHubに登録しないでください。**

## 4. GitHub Actionsから未署名IPAをビルド

1. GitHubで作成したリポジトリを開き、**Actions** を選びます。
2. 左側から **Build unsigned RouteDiary IPA** を選択します。
3. **Run workflow → main → Run workflow** を押します。
4. 成功した実行（緑のチェック）の **Artifacts → RouteDiary-iOS-trial-unsigned** をダウンロードします。
5. ダウンロードしたGitHubのZIPを展開すると `RouteDiary-iOS-trial-unsigned.ipa` が得られます。

`.github/workflows/build-ios.yml` が macOSランナー上に XcodeGenを入れ、`project.yml` から `.xcodeproj` を生成、`xcodebuild` でiOS端末用アプリをビルドし `Payload/RouteDiary.app` を未署名IPAとしてZIP化します。

**ビルド成功は現時点では未確認**です。失敗した場合はActionsの該当ステップの赤いログ、または `xcodebuild-log` を確認してください。GitHub ActionsのmacOS使用は、公開リポジトリでは標準ホストランナーが基本的に無料ですが、プライベートリポジトリでは無料枠などの制限があります。

## 5. Windowsから実機iPhoneへインストール

1. [Sideloadly](https://sideloadly.io/) のWindows版をインストールします。
2. 必要なら公式サイトの案内どおり、**AppleのWeb配布版**iTunes / iCloudを入れます（Microsoft Store版では動作しない場合があります）。
3. iPhoneをUSB接続し「このコンピューターを信頼」を許可します。
4. `RouteDiary-iOS-trial-unsigned.ipa` をSideloadlyへドラッグします。
5. 自分のApple Accountで署名してインストールします。Appleの認証情報は**友人に渡さず**、利用者本人の端末・アカウントで行ってください。
6. iPhoneでデベロッパモードを求められた場合は、**設定 → プライバシーとセキュリティ → デベロッパモード**を有効にします。必要なら**設定 → 一般 → VPNとデバイス管理**から開発者を信頼します。
7. RouteDiaryを開き、位置情報を許可して**GPS記録を開始**します。

Apple無料署名は**7日ごとに更新が必要**です。Sideloadlyの自動更新にはWi-Fi接続の設定済みWindows PCまたはUSB接続が必要です。同じApple Account・Bundle IDで上書きしていれば通常はローカルデータを維持できますが、アップデート前のCSVバックアップを推奨します。アンインストールするとローカル履歴が消える可能性があります。

## 6. GPSの実機テスト例

- 起動直後：地図が表示されるが、**記録は開始しない**
- 「GPS記録を開始」を押す。まず「測位待ち」が表示される
- 屋外で精度が良い測位が到着すると初回地点が保存される
- 25m以内に留まった場合：新しい地点は追加せず、60秒以上なら滞在時間が伸びる
- 25m以上移動し、保存間隔を満たした場合：新しい地点を保存
- 除外エリア内を移動：GPS点と最高速度は保存しないが、滞在時間は集計する
- エリア外に出る / GPSが長く途切れる：GPS欠損区間の移動距離は加算しない
- 画面OFF中に徒歩で数分移動：後から履歴に反映されるか実機で確認（OS制限あり）
- Android版から出したCSVを**履歴 → Android版CSVを取り込み**で読めるか確認

GPS記録中は継続的な高精度測位によりバッテリー消費が大きくなります。

## 7. ディレクトリ

```text
RouteDiary-iOS-Trial/
├── .github/workflows/build-ios.yml    ← GitHub ActionsによるIPA生成
├── project.yml                         ← XcodeGen設定
├── Sources/
│   ├── RouteDiaryApp.swift             ← アプリのエントリ
│   ├── RootView.swift                  ← MapKit地図 / 除外設定
│   ├── HistorySettingsView.swift       ← 履歴 / CSV / 設定
│   ├── LocationRecorder.swift          ← GPS記録ロジック
│   ├── RouteDiaryModel.swift           ← モデル / 記録読み出し
│   ├── Models.swift                     ← 型定義
│   ├── TrackStore.swift                ← SQLite3 DB
│   ├── CSVBridge.swift                 ← Android互換CSV
│   ├── Info.plist                      ← GPS許可 / バックグラウンド
│   └── Assets.xcassets/                ← iOSアプリアイコン
└── README.md
```

## 8. VPNアプリとの分離

将来のワンタップVPN接続アプリはこのアプリに混ぜず、**別リポジトリ・別Bundle ID**で作成する予定です。特に `NEVPNManager` / `NetworkExtension` の可否、AppleのVPN利用権限、ユーザーごとの認証情報の安全な保存は別途設計する必要があります。

## 検証状況

- ZIP中のAndroidソース：README、TrackDb / TrackingService / MainActivity / OnlineCsvの主要仕様を確認
- Swift：ソースの文法解析（`swiftc -frontend -parse`）
- `Info.plist`：XML/Plist形式を検査
- `project.yml` / GitHub Actions：YAML構造を検査
- **未実施**：XcodeGenによる `.xcodeproj` 生成、Xcode/iOS SDKによる実ビルド、署名、実機インストール・GPS計測

実ビルドで発生したエラーは Actions のログを確認して修正する必要があります。試験版ですので、日常利用や重要な位置履歴保存の唯一の手段としては使用しないでください。

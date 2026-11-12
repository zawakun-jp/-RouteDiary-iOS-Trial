# RouteDiary iOS v0.2 — 検証と制限

## 実施済み検査

- `swiftc -frontend -parse Sources/*.swift`（Swift構文、LinuxのSwiftコンパイラで確認）
- `project.yml`と`.github/workflows/build-ios.yml`のYAML構文
- `Sources/Info.plist`のXML plist構文
- 追加した`i18n_en.json` / `i18n_zh.json`のJSONパース
- iOS用Asset CatalogのContents.jsonパース
- 主要な静的日本語翻訳キーが日英中辞書に存在するか
- ビルド用アーカイブのZIP整合性、ファイル存在検査
- bundle identifierがv0.1同様`jp.zsg.routediary.ios`であること

## まだ検証できないもの

- macOS/XcodeでのSwift型検査およびアプリのコンパイル
- 実際にiPhoneでの画面表示・GPS測位・バックグラウンド記録
- 実サーバー`cc.zsg.jp`の認証・MySQL同期API・画像アップロード動作
- GitHub ActionsからのIPA出力、およびSideloadlyでの署名・上書き

GitHub Actionsビルド失敗時はWorkflowの`xcodebuild-log`を確認してください。

# 静的検証結果

- 参照元: RouteDiary Android v2.11（Java / SQLite v4）
- iOS移植版: RouteDiary iOS Trial v0.1
- 対象iOS: 17以降
- Swift構文解析: 実施（`swiftc -frontend -parse Sources/*.swift`）
- Info.plist / XcodeGen YAML / GitHub Actions YAML: 形式検査
- GitHub ActionsによるMacビルド: **未実施**
- IPAの生成 / iPhone署名 / GPS実機試験: **未実施**
- 本番サーバーAPIの動作試験: **未実施（この試験版は未接続）**

実機検証前の試作品です。安全性や記録継続性を保証するものではありません。

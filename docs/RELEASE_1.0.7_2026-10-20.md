# Ongaku 1.0.7 配布記録 — 2026-10-20

- バージョン: 1.0.7 / ビルド: 3
- 対象: iPhone / iPad（littlebuddha.audio）
- 更新情報: [日本語・英語・简体中文](RELEASE_NOTES_1.0.7.md)

## 検証

- 🟢 [Done] 直近の設定タブ・リンク・再生復旧・曲末処理の差分を確認し、バージョン/ビルド番号、plist、三言語の構文と空白検査を確認。
- 🟢 [Done] prepared EOF、recovered track end、foreground recovery、transport continuityの4回帰スクリプトが成功。元の不具合を再導入するnegative controlも拒否。
- 🟢 [Done] Xcode 27.1の署名付きReleaseアーカイブが成功。実際のInfo.plistで1.0.7（3）を照合し、codesignの厳格検証に成功。

## 配布

- 🟢 [Done] App Store Connectへのアップロード成功（`Upload succeeded` / `EXPORT SUCCEEDED`）。TestFlightに1.0.7（3）が表示され、処理完了。
- 🟢 [Done] App Store Connectに1.0.7を作成し、日本語・英語・简体中文の更新情報と審査メモを保存。既存の承認後自動リリース設定を維持。
- 🟢 [Done] GitHub mainと[v1.0.7](https://github.com/matsushibadenki/Ongaku-mobile/releases/tag/v1.0.7)のソースリリースを公開。
- 🟢 [Done] ユーザーの明示承認に基づき暗号化申告「上記のアルゴリズムのどれでもない」を保存。ビルド3でApp Reviewへ提出し、1.0.7「審査待ち」を確認。
- ⭕️ [Pending] Apple審査と承認後の自動公開。
- ⭕️ [Pending] 実機での音声、出力機器・割込み・曲末の確認は既存の各検証記録に記載した範囲で継続。

成果物・ログはGit管理外の `build/releases/1.0.7/` に保存。

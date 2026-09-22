# call-insight-lab

コールセンター対話(音声書き起こし・チャットログ)の分析基盤に関する検討・試作リポジトリ。

## 方針(検討中)

LLM を使って各通話を「原文 / 構造 / 根拠」の 3 層に半構造化し、構造層(用件ごとに固定の項目へ閉じた語彙の値を入れたもの)に対する SQL / BI の単純集計で分析する。通話 1 件 = 1 行の表は構造層から導出する。
構造で覆えない問いはスキーマの不備として塞ぎ、問いに答えるために原文へ LLM を当て直すことはしない(原則 5)。注釈層に書くのは構造と明言だけで、判断は集計時の規則で導く(原則 6、v0.4)。原則は [docs/01_concept.md](docs/01_concept.md) にまとめてある。

## 決定記録と作業規則

- [docs/decisions/](docs/decisions/README.md): 設計・方針の決定を 1 決定 1 ファイルで記録する(承認済みは不変、覆すときは新記録)。
- [CLAUDE.md](CLAUDE.md): Claude Code の作業規則。発言の種別(決定 / 提案 / 仮説 / 訂正)、議論ターンと適用ターンの分離、docs 編集の hook 検査。

## ドキュメント(読む順)

- [docs/01_concept.md](docs/01_concept.md) 要件、目的の分解、原則 1〜6、全体像。原則の唯一の置き場。
- [docs/02_schema.md](docs/02_schema.md) 現行スキーマ v0.4: 3 層、発話行為、導出規則、業務知識表、不変条件、版の経緯、取込時にしか得られない情報。DDL は [poc/schema/](poc/schema/)。
- [docs/03_vocabulary.md](docs/03_vocabulary.md) 語彙の 3 層、進化ループ、既知の誤解一覧の保守、対象マスタ草案(自動車保険)。
- [docs/04_analysis_needs.md](docs/04_analysis_needs.md) 分析ニーズの目録(45 問)とテーマの文法(条件の 7 族)。「特定のテーマを拾えるか」の試験集。
- [docs/05_poc_plan.md](docs/05_poc_plan.md) PoC 計画: 合成コーパス仕様、品質ゲート、Go / No-Go、第 1 段で実測する項目、次の作業。
- [docs/06_cost.md](docs/06_cost.md) 費用見積り(外部 API 前提。ローカル LLM は参考)。
- [docs/open_issues.md](docs/open_issues.md) 未決の論点と依頼者への確認事項。
- [docs/reference/](docs/reference/) 調査記録(研究・製品動向、参考文献)と先行研究との突き合わせ。推奨部分は決定記録で撤回済みのものがある。

## PoC

- [poc/](poc/) 日本語通話サンプル 19 件に対する抽出・根拠検証・タグ集計の試行。結果と教訓は [poc/README.md](poc/README.md)。

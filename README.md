# call-insight-lab

コールセンター対話(音声書き起こし・チャットログ)の分析基盤に関する検討・試作リポジトリ。

## 方針(検討中)

LLM を使って各通話を「原文 / 構造 / 根拠」の 3 層に半構造化し、構造層に対する SQL / BI の単純集計で分析する。構造で覆えない問いはスキーマの不備として塞ぎ、問いに答えるために原文へ LLM を当て直すことはしない。注釈層に書くのは構造と明言だけで、判断は集計時の規則で導く(v0.4)。決定と案の区別を含め、要件と原則は [docs/01_concept.md](docs/01_concept.md) にある。

## 作業規則

- [CLAUDE.md](CLAUDE.md): Claude Code の作業規則。発言の種別(決定 / 提案 / 仮説 / 訂正)、チャットで承認してファイルに反映する流れ、決定の書式(根拠発言つき)、docs 編集の hook 検査。
- [docs/history.md](docs/history.md): 承認・却下・撤回・保留の時系列(追記のみ)。
- [docs/open_issues.md](docs/open_issues.md): 未決の論点と依頼者への確認事項。

## ドキュメント(読む順)

- [docs/01_concept.md](docs/01_concept.md) 要件と前提、原則 1〜6、目録に関する決定(いずれも根拠発言つき)、案(決定ではないもの)の一覧。原則の唯一の置き場。
- [docs/02_schema.md](docs/02_schema.md) 現行スキーマ v0.4: 3 層、発話行為、導出規則、業務知識表、不変条件、版の経緯、取込時にしか得られない情報、処理の流れ、構造の定義、列の規約。DDL は [poc/schema/](poc/schema/)。
- [docs/03_vocabulary.md](docs/03_vocabulary.md) 語彙の 3 層、進化ループ(案。依頼者が前提に疑義)、既知の誤解一覧の保守、対象マスタ草案(自動車保険)。
- [docs/04_analysis_needs.md](docs/04_analysis_needs.md) 分析ニーズの目録(45 問)、テーマの文法(条件の 7 族)、分析手順、汎用性の見立て、できること・できないこと。
- [docs/05_poc_plan.md](docs/05_poc_plan.md) PoC 計画: 合成コーパス仕様、品質ゲート、Go / No-Go、第 1 段で実測する項目、次の作業。
- [docs/06_cost.md](docs/06_cost.md) 費用見積り(外部 API 前提。ローカル LLM は参考)。
- [docs/reference/](docs/reference/) 調査記録(研究・製品動向、参考文献)と先行研究との突き合わせ。推奨部分は決定ではない。

## PoC

- [poc/](poc/) 日本語通話サンプル 19 件に対する抽出・根拠検証・タグ集計の試行。結果と教訓は [poc/README.md](poc/README.md)。

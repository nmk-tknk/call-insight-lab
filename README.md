# call-insight-lab

コールセンター対話(音声書き起こし・チャットログ)の分析基盤に関する検討・試作リポジトリ。

## 方針(検討中)

LLM を使って各通話を固定スキーマの構造化データ(通話 1 件 = 1 行)に変換し、その上を SQL / BI の単純集計で分析する。
自由な LLM 質問は探索用に限定し、KPI は構造化テーブルから再現可能に算出する。

## ドキュメント

- [docs/study/01_llm_structuring_feasibility.md](docs/study/01_llm_structuring_feasibility.md)
  「非構造→構造化→単純集計」アプローチの実現可能性検討。最新研究・商用製品の動向調査、推奨アーキテクチャ、未確定事項(質問リスト)、PoC 計画を含む。
- [docs/study/02_decision_memo.md](docs/study/02_decision_memo.md)
  要件ヒアリング(月 10 万件、教師データなし、人手ラベリング不可、目的は入電増の真因調査と「わかりづらい」パターン特定)を反映した意思決定メモ。作るもの・作らないもの、人手ラベルなしの品質担保、Go/No-Go 基準。
- [docs/study/03_tag_only_schema.md](docs/study/03_tag_only_schema.md)
  分析列を閉じた語彙(タグ)のみに改めたスキーマ v0.2。タグ集計で目的の数値が出ることの SQL 確認と、語彙を維持する条件。
- [docs/study/04_vocabulary_evolution.md](docs/study/04_vocabulary_evolution.md)
  語彙の自動進化。新タグの検知・候補生成・自動検証・暫定採用・履歴整合を自動化し、人は拒否権のみ持つ設計。
- [docs/study/05_prior_art.md](docs/study/05_prior_art.md)
  「ターン帰属+用件単位」設計と先行研究・商用製品の突き合わせ。借用すべき名前・層構造・境界規則・評価指標と、設計 v0.3 の骨子。
- [docs/study/06_v03_concept.md](docs/study/06_v03_concept.md)
  v0.3 の結論とコンセプトの一枚紙(4 原則、データモデル、処理の流れ、できること・できないこと)。
- [docs/study/07_schema_v03.md](docs/study/07_schema_v03.md)
  スキーマ v0.3 確定版。処理と切り分け、確定事項 10 点、ER 図、不変条件、集計例。DDL は [poc/schema/v0_3.sql](poc/schema/v0_3.sql)。
- [docs/study/08_information_loss_inventory.md](docs/study/08_information_loss_inventory.md)
  スキーマ v0.3 で落ちる情報の棚卸し(58 項目)。「今決めないと戻らない(取込時のみ)/ 再注釈で回復できる / 語彙に潰す本質的損失 / 意図的除外」の軸で整理し、v0.3.1 への追加一覧と v0.2 → v0.3 の置き換え対応表を含む。

## PoC

- [poc/](poc/) 日本語通話サンプル 19 件に対する抽出・根拠検証・タグ集計の試行。結果と教訓は [poc/README.md](poc/README.md)。

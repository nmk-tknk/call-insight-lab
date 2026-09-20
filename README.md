# call-insight-lab

コールセンター対話(音声書き起こし・チャットログ)の分析基盤に関する検討・試作リポジトリ。

## 方針(検討中)

LLM を使って各通話を「原文 / 構造 / 根拠」の 3 層に半構造化し、構造層(用件ごとに固定の項目へ閉じた語彙の値を入れたもの)に対する SQL / BI の単純集計で分析する。通話 1 件 = 1 行の表は構造層から導出する。
構造で覆えない問いはスキーマの不備として塞ぎ、問いに答えるために原文へ LLM を当て直すことはしない(06 原則 5)。注釈層に書くのは構造と明言だけで、判断は集計時の規則で導く(06 原則 6、v0.4)。

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
  スキーマ v0.3 確定版。処理と切り分け、確定事項 10 点、ER 図、不変条件、集計例。DDL は [poc/schema/v0_3.sql](poc/schema/v0_3.sql)、v0.3.1 の追加差分は [poc/schema/v0_3_1.sql](poc/schema/v0_3_1.sql)。
- [docs/study/08_information_loss_inventory.md](docs/study/08_information_loss_inventory.md)
  スキーマ v0.3 で落ちる情報の棚卸し(58 項目)。「今決めないと戻らない(取込時のみ)/ 再注釈で回復できる / 語彙に潰す本質的損失 / 意図的除外」の軸で整理し、v0.3.1 への追加一覧と v0.2 → v0.3 の置き換え対応表を含む。
- [docs/study/09_open_issues.md](docs/study/09_open_issues.md)
  論点台帳。決定済み(再論しない)事項と、未決の論点を「決め手・期限・決定者」付きで一覧化。依頼者への質問と回答状況(2026-09-20 時点で残りは費用上限と比率の補正のみ)。
- [docs/study/11_cost_model.md](docs/study/11_cost_model.md)
  コストモデル。外部 API 前提で、月 10 万件の全項目抽出をモデル別に見積もり(中位単一で月 1,000〜1,400 USD、小型主体で 300〜700 USD、PoC は一度きり 300 USD 未満)、列ごとに必要な性能帯と候補構成 3 案を示す。ローカル LLM 前提の計算時間の見積りは参考として残す。
- [docs/study/13_v04_concept.md](docs/study/13_v04_concept.md)
  v0.4 コンセプト。注釈層を「構造」と「明言(発話行為)」に限り、混乱・動機・結果・受容・横断フラグ・感情は発話行為と既知の誤解一覧から SQL で導く。判断の定義変更に再抽出が不要になり、分析用ビューは v0.3.1 と列互換。DDL は [poc/schema/v0_4.sql](poc/schema/v0_4.sql)。
- [docs/study/12_analysis_needs_catalog.md](docs/study/12_analysis_needs_catalog.md)
  分析ニーズの目録。経営・商品・マーケ・営業・運営・コンプライアンス・CX の 7 部署と基盤監視から 44 問を集め、各問いを対象 / 軸 / 指標 / 比較に分解して v0.3.1 で埋まるかを判定。31 問は埋まり、不備 13 件を「項目がない / 選択肢がない / 取込データに依存」に分けて起票。
- [docs/study/10_synthetic_corpus_spec.md](docs/study/10_synthetic_corpus_spec.md)
  合成コーパス仕様。自動車保険(事故対応外)の用件 34 種・混乱 16 点・対象マスタ草案、ASR 風の乱れの注入規則、急増シナリオ 5 本の封印による盲検テスト、合成個人情報によるマスキング検証、ローカル LLM を第一候補とするモデル計画、300 件 → 2,000 件の 2 段構成。

## PoC

- [poc/](poc/) 日本語通話サンプル 19 件に対する抽出・根拠検証・タグ集計の試行。結果と教訓は [poc/README.md](poc/README.md)。

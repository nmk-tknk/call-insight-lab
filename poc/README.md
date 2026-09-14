# PoC: 日本語通話サンプルの構造化と集計

`docs/study/03_tag_only_schema.md` のスキーマ v0.2 を、自作の日本語通話サンプル 19 件に適用し、
「抽出 → 根拠の逐語検証 → タグ集計」が通ることを確認した。

## 構成

| パス | 内容 |
|---|---|
| `samples/transcripts.jsonl` | 通話サンプル 19 件(2026-W34〜W38、書き起こし風の日本語)。9 月 1 日の料金改定通知後に「日割り」記載を誤解した請求照会が増える、という筋書きで作成 |
| `vocab/vocab_v0.1.yaml` | 閉じた語彙(reason L1/L2、trigger、touchpoint など) |
| `prompts/extract_system.md` | 抽出プロンプト。語彙はプロンプト本文とは別に注入する(語彙更新でプロンプト版は変わらない) |
| `src/schema.py` | Pydantic スキーマ。分析列は全て Literal(列挙)/bool、自由記述は要約・根拠・other_text のみ |
| `src/extract.py` | Claude API(`messages.parse` + structured outputs)で全件抽出する自動パス。要認証情報 |
| `samples/extracted.jsonl` | 本 PoC の抽出結果(下記「出所」参照) |
| `src/verify_evidence.py` | 根拠引用が書き起こし本文に逐語一致するかを機械検証 |
| `src/aggregate.py` | DuckDB による集計。目的 (a) 急増真因、(b) わかりづらいパターン、外部整合、語彙進化シグナル |
| `out/aggregate_report.txt` | 集計出力 |

実行:

```bash
pip install duckdb pandas pyyaml anthropic
python -m src.verify_evidence --transcripts samples/transcripts.jsonl --extracted samples/extracted.jsonl --out out/verified.jsonl
python -m src.aggregate --transcripts samples/transcripts.jsonl --extracted out/verified.jsonl
# API 認証情報がある環境では自動抽出:
python -m src.extract --in samples/transcripts.jsonl --out out/extracted.jsonl
```

## 抽出結果の出所(重要)

この実行環境には API 認証情報がなかったため、`samples/extracted.jsonl` は `src/extract.py` を実行したものではなく、
**このセッションのモデルが `prompts/extract_system.md` の指示に従って手動で生成した**ものである。
各行の `model` 列にその旨を記録している。スキーマ検証(Pydantic)と根拠の逐語検証は機械的に実施した。

また、サンプル通話は筋書きを決めて作成しているため、**「急増の真因が集計で出た」ことは手法の妥当性の証明にはならない。**
本 PoC が示すのは、(1) スキーマがタグのみで成立すること、(2) 目的の数値が GROUP BY で出ること、(3) 品質ゲートが機械的に回ること、の 3 点に限る。
妥当性の検証は実データと既知事例(02 §6)で行う。

## 結果の要約

- 品質ゲート: スキーマ違反 0 / 19、根拠引用の逐語一致 30 / 30。
- 目的 (a): テーマ `BILL_AMOUNT_INQUIRY` の全体比が W34〜36 の 0〜33% から W37〜38 の 75% に上昇。急増期間のテーマ該当通話では、
  `confusion_touchpoint_code = TERM_PRORATION` が 6 件中 3 件(平常期間 0 件)、組み合わせ `viewed_bill × indirect_misread × TERM_PRORATION` が最多。
  引用を読むと「二重に取られてる」「二回請求されてる」と日割り記載を二重請求と誤解している。→ 真因候補が**タグの組み合わせの件数差として出る**。
- 目的 (b): 接点 × 訴え方の表で、`TERM_PRORATION`(日割り)と `DOC_RATE_CHANGE_NOTICE_2609`(改定通知)が上位。
  下流コスト列(通話時間、未解決率、終了時ネガ率)も同じクエリで出る。
- 外部整合: `callback_promised` の 7 日以内再入電率 0.5、`resolved` は 0。LLM の判定と CRM 側の事実が矛盾していない(件数は少なすぎるが、検証の型は動く)。
- 語彙進化シグナル: `touchpoint` の other が 2 件(初月無料の適用条件、テレビ CM)。実運用ではこれが 04 の検知ループの入力になる。

## 試してわかった設計上の教訓

1. **汎用の受け皿カテゴリは other を隠す。** `SERVICE_INFO_GENERAL` を用意したため、家族割キャンペーンの問い合わせ(C007)が other に落ちず、
   新テーマの検知シグナルが弱まった。受け皿カテゴリは作らないか、other と同様に監視対象にする。
2. **用語と書面の境界が揺れる。** 「日割り」への混乱を `TERM_PRORATION` にするか `DOC_BILL_STATEMENT` にするかで判断が割れた(C019)。
   語彙は階層化して(`DOC_BILL_STATEMENT > TERM_PRORATION`)親でも集計できるようにするべき。04 の「親の子として追加」の原則がここでも効く。
3. **trigger と reason の分離は有効だった。** 同じ `BILL_AMOUNT_INQUIRY` でも、`viewed_bill`(請求書を見て誤解)と `received_notice`(通知を読んで確認)と
   `word_of_mouth`(近所で聞いた)で対処が違う。真因分析の軸として残す価値がある。
4. **根拠が取れない判断がある。** C015 は顧客の了承発話が「はい」のみで、逐語引用として意味をなさない。
   `resolution_evidence` は空を許容し、「根拠なし率」を列ごとに監視する方がよい。
5. **判断列の推論欄は有効。** `confusion_reasoning` を先に書かせることで direct / indirect の区別が安定した(手動実行での所感。自動実行で要再確認)。
6. **要約列は集計に使わなくても必要。** 引用一覧(A-4)と要約があるから、集計表から個別通話へ数秒で降りられる。これが「信じ込み」防止の実体。

## 次にやること

- 認証情報のある環境で `src/extract.py` を実行し、手動結果との一致(κ)を測る。これが「複数モデル一致」ゲートの最初の実測になる。
- 同じ通話を言い換えプロンプトで再抽出し、判断列の安定性を測る。
- 語彙を階層化(`touchpoint` の親子)し、`SERVICE_INFO_GENERAL` を廃止して再実行する。

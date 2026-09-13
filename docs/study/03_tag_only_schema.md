# スキーマ改訂: 「タグを集計すれば目的の数値が出る」形への変更

- 作成日: 2026-09-13
- 経緯: 02 の v0 案は `request_summary` 等の自由記述列を含み、集計可能な構造化になっていなかった。分析列を閉じた語彙のみに改める。

## 1. 原則

1. **分析に使う列は、すべて閉じた語彙(列挙・コード・真偽値)。** 自由記述は分析列に置かない。
2. **自由記述は 2 用途に限定する。** (a) 語彙を育てるための材料(`*_other_text`、`request_summary`)、(b) 検証用の逐語引用(`*_evidence`)。どちらも集計対象ではない。
3. **すべての列挙列に `other` と `unknown` を持つ。** `other` 率が語彙見直しのトリガになる。
4. **語彙はバージョン管理し、変更時は必要期間をバックフィルする。** 同じ列の意味が期間で変わらないようにする。
5. **複数該当は配列+主(primary)で持つ。** 集計時は主で数えるか、展開して数えるかを明示する。

## 2. スキーマ v0.2

### 2.1 分析列(閉じた語彙のみ)

| 列 | 型 / 語彙規模 | 定義 | 語彙の出所 |
|---|---|---|---|
| `reason_l1` | 列挙 10〜15 | 用件大分類 | LLM 誘導+人の審査で作成、凍結 |
| `reason_l2` | 列挙 50〜100(l1 配下) | 用件中分類 | 同上 |
| `reason_secondary[]` | `reason_l2` の配列 | 副次的な用件 | 同上 |
| `request_type` | 列挙 6: inquiry / procedure / complaint / cancel_intent / feedback / other | 顧客が求めた行為の種類 | 固定 |
| `trigger_code` | 列挙 10〜15: received_notice / viewed_bill / app_or_web_change / media_sns / word_of_mouth / followup_of_previous_contact / our_outbound_contact / life_event / unknown / other | 入電の直接のきっかけ | 固定(業種で微調整) |
| `product_code` | 列挙(マスタ準拠) | 対象商品・サービス | 既存マスタ |
| `touchpoint_code` | 制御語彙 50〜200: 書類・画面・手続き・用語の一覧(例: `DOC_BILL_SUMMARY`, `APP_CANCEL_FLOW`, `TERM_PRORATION`) | 顧客が接触していた自社の成果物 | 社内で整備・維持(§4) |
| `confusion_signal` | bool | 理解困難・誤解・確認の表明があるか | 固定 |
| `confusion_type` | 列挙 4: direct / indirect_misread / indirect_clarify / none | 訴え方の種類 | 固定 |
| `confusion_touchpoint_code` | `touchpoint_code` と同じ語彙 | 何がわかりづらかったか | 同上 |
| `resolution_status` | 列挙 5: resolved / escalated / callback_promised / unresolved / unknown | 通話内での解決状況 | 固定 |
| `repeat_contact_signal` | bool | 「以前も連絡した」旨の発話があるか | 固定 |
| `emotion_end` | 列挙 3 | 終了時の顧客感情 | 固定 |

13 列。すべて GROUP BY・COUNT・比率計算がそのままできる。

### 2.2 非分析列(集計しない)

| 列 | 用途 |
|---|---|
| `request_summary` | 語彙誘導・見直しの材料、ドリルダウン時の一覧表示。**レポートの軸には使わない** |
| `reason_other_text`, `trigger_other_text`, `touchpoint_other_text` | 各列で `other` を選んだときだけ記入。語彙見直しジョブの入力 |
| `confusion_evidence`, `resolution_evidence`, `repeat_evidence` | 逐語引用。本文との一致を機械検証し、分析者の目視確認に使う |
| `*_reasoning` | 判断列の推論欄。精度向上のために出力させるが保存は任意 |
| メタ: `schema_version`, `vocab_version`, `prompt_version`, `model`, `extracted_at`, `evidence_verified` | 再現性・品質管理 |

## 3. 目的の数値がタグ集計で出ることの確認

### 目的 (a): テーマの入電増加の真因

```sql
-- 1. テーマ(例: reason_l2 = 'BILL_AMOUNT_INQUIRY')の週次件数と全体比
SELECT week, COUNT(*) FILTER (WHERE reason_l2 = 'BILL_AMOUNT_INQUIRY') AS n,
       COUNT(*) AS total,
       COUNT(*) FILTER (WHERE reason_l2 = 'BILL_AMOUNT_INQUIRY')::float / COUNT(*) AS share
FROM calls GROUP BY week ORDER BY week;

-- 2. 急増期間 vs 平常期間で、きっかけ・接点・商品・混乱の分布を比較
SELECT period, trigger_code, COUNT(*) AS n,
       COUNT(*)::float / SUM(COUNT(*)) OVER (PARTITION BY period) AS share
FROM calls_with_period
WHERE reason_l2 = 'BILL_AMOUNT_INQUIRY'
GROUP BY period, trigger_code;
-- 同じクエリを touchpoint_code / product_code / confusion_touchpoint_code / confusion_type で繰り返し、
-- share の差が大きい順に並べる(効果量と信頼区間は件数ベースで計算)
```

「9 月改定通知(`touchpoint_code = DOC_RATE_CHANGE_NOTICE_2609`)を受け取って(`trigger_code = received_notice`)日割り表記(`confusion_touchpoint_code = TERM_PRORATION`)を誤解した(`confusion_type = indirect_misread`)入電が急増期間に集中している」という真因候補は、**すべてタグの組み合わせの件数差として出る。** 引用は確認用に後から見る。

### 目的 (b): 「わかりづらい」パターンの特定

```sql
SELECT confusion_touchpoint_code, confusion_type,
       COUNT(*) AS n,
       AVG(handle_seconds) AS aht,
       AVG(CASE WHEN repeat_within_7d THEN 1 ELSE 0 END) AS repeat_rate,
       AVG(CASE WHEN resolution_status = 'unresolved' THEN 1 ELSE 0 END) AS unresolved_rate
FROM calls
WHERE confusion_signal
GROUP BY 1, 2
ORDER BY n DESC;
```

「どの書類・画面・用語が、どの訴え方で、どれだけの件数と下流コストを生んでいるか」がそのまま出る。

## 4. 閉じた語彙を成立させるための条件

タグだけで数値が出る設計は、**語彙の設計と維持**にコストが移る。ここを省くと 01 で述べた「発見ループのない固定スキーマ」になり、新しい真因を `other` に押し込んで見逃す。

1. **初期語彙の作成(教師データなし):** サンプル 3,000〜5,000 件の `request_summary` を LLM に誘導させて `reason` 体系を提案させ(TnT-LLM / TopicGPT の手順)、人が統合・命名して凍結する。`touchpoint` は社内の書類・画面・手続き一覧から作る(これは LLM ではなく業務側の資産)。
2. **大きな語彙の分類精度:** 選択肢が 50 を超えると LLM の選択精度が落ちる。`reason` は l1 → l2 の 2 段階で、`touchpoint` は埋め込み検索で候補 10〜20 件に絞ってから LLM に選ばせる(AmiVoice の多段階推論と同じ発想)。
3. **`other` の監視と語彙の改訂:** `other` 率が閾値(例: 5%)を超えた列は、`*_other_text` と `request_summary` をクラスタリングして新タグ候補を提案し、人が採否を決める。採用時は `vocab_version` を上げ、対象期間を再抽出する。
4. **新しい真因が語彙にないケース:** 目的 (a) で最も重要な弱点。対策は、(i) 急増期間の `other` と `request_summary` を自動クラスタリングして「未分類の塊」を差分表に必ず表示する、(ii) 急増が既存タグの組み合わせの偏りとして現れることが多い(新テーマでも `trigger` や `touchpoint` は既存語彙で表現できる)ため、まず組み合わせで当たりを付ける。

## 5. 02 からの変更点まとめ

| 02 の v0 | v0.2 | 理由 |
|---|---|---|
| `request_summary` を分析入力に使用 | 非分析列に降格。語彙誘導と一覧表示のみ | 集計不能 |
| `trigger` 列挙+自由記述 | `trigger_code` 列挙のみ+`other_text` | 集計可能に |
| `confusion_object` 自由記述 | `confusion_touchpoint_code` 制御語彙 | 集計可能に。かつ「どの成果物を直すか」に直結 |
| `product_or_service` 列挙 or 自由記述 | `product_code` マスタ準拠 | 集計可能に |
| なし | `touchpoint_code`, `request_type`, `repeat_contact_signal`, `reason_secondary[]` | 真因分析の軸と多重該当の扱いを追加 |
| テーマ定義エンジンで自由記述を再分類 | 役割を「語彙にないテーマの一時分類」と「新タグ候補の検証」に限定 | 定常レポートはタグ集計で完結させる |

テーマ定義エンジン(02 ③)は不要にはならないが、**主役から補助に下がる。** 定常的に見る数値はすべてタグ集計で出し、語彙に昇格させる前の仮説検証や、一度きりの問いにだけ使う。

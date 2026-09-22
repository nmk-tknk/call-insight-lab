# 語彙: 3 層、進化ループ、業務知識表の保守、対象マスタ草案

- 出所: 旧 docs/study/04(語彙の自動進化)全体、12 §0.4(語彙の 3 層)、13 §4(業務知識表)、10 §7(対象マスタ草案)を統合(決定記録 0011、2026-09-22)。原則は [01_concept.md](01_concept.md) 原則 1・2。
- 語彙の表構造(`codes`, `objects`, `code_lineage`, `known_misconceptions`)は [02_schema.md](02_schema.md) §3。

## 1. 「語彙」の 3 層と汎用性

v0.4 で「語彙」と呼ぶものは 3 層あり、業種依存の有無が違う。構造(項目と発話行為の種類)は業種固有の語彙に依存させない。値の層だけが業種に依存し、それは語彙進化ループで育てる意図した依存である。

| 層 | 例 | 業種依存 | 変わり方 |
|---|---|---|---|
| 発話行為の種類 | 照会する、主張する、理由を述べる、了承する、訂正した、暴言 | しない | 固定(役割の一覧そのもの)。問いの有無にかかわらず常に全種類を抽出する(決定記録 0009、承認待ち) |
| 対象 | 更新案内、運転者限定、マイページ | する | 語彙進化ループで育つ。業種が変われば入れ替える |
| 値 | 動機、側面、主張(既知の誤解) | 動機・側面はほぼしない。主張はする | 語彙進化ループで育つ。語彙にない値は「その他」+ 自由記述に落ち、構造は壊れない |

業種を変えるときに差し替えるのは対象マスタと既知の誤解一覧だけで、発話行為の種類・側面・動機・導出規則は持ち越す。

## 2. 語彙進化ループ

汎用性の源泉は固定スキーマではなく、どの項目にも同じように働く語彙進化ループにある。対象・動機・主張・きっかけなど、値の層すべてに同じ機構を適用する。ループは「検知 → 候補生成 → 自動検証 → 暫定採用 → 安定化 → 履歴の整合」の 6 段で、人の関与は拒否権(veto)と週次ダイジェストの確認のみ。承認待ちで止まらない。語彙は追加優先・階層構造・写像表付きで管理し、新しい値が増えても過去の時系列が壊れないようにする。

### 2.1 何を自動検知するか

| シグナル | 検知方法 | 意味 |
|---|---|---|
| `other` 率の上昇 | 項目ごと・期間ごとの管理図(CUSUM / EWMA) | 語彙に穴がある |
| 新しい塊の出現 | `other_text` と要約の埋め込みを週次で増分クラスタリング。既存の値のプロトタイプから遠く、複数週にわたり成長する塊 | 新しい対象・新しい主張 |
| 既存の値の内部の分裂 | 配下の埋め込み分散の増大、重心の移動、下位クラスタの出現 | 粒度が粗くなった(分割候補) |
| 判定の不安定化 | 特定の値での複数モデル不一致率・低確信率の上昇 | 定義が現実とずれてきた |
| 新規性スコアの上昇 | 各通話の「最近傍の値までの距離」の分布が右に寄る | 未知のものが増えている |
| 消滅 | 値の件数が N 期間ゼロ近傍 | 退役候補(削除はしない) |

いずれも件数と埋め込みだけで計算でき、LLM 呼び出しは不要。日次または週次のバッチで回る。

### 2.2 候補の自動生成

検知された塊ごとに LLM が次を生成する(TopicGPT / LLooM / Clio と同じ手順)。

1. 名前と 1 文の定義
2. 包含基準・除外基準・境界例(これがそのまま抽出プロンプトの一部と、埋め直しの指示になる)
3. 階層上の位置(どの親の子か、既存の値の分割か、完全に新規か)
4. 既存の値との関係(近い既存の値と、その違い)
5. 対象の場合: 社内の成果物マスタ(書類・画面・手続き一覧)との照合。一致すればそのコード、なければ「マスタ未登録」フラグ付きの新コード

### 2.3 自動検証(採用前ゲート)

候補は以下をすべて満たしたときだけ次段へ進む。すべて自動。基準値は慣行に基づく初期値で、運用で調整する([open_issues.md](open_issues.md) X4)。

| 検証 | 基準(初期値) |
|---|---|
| 規模 | 直近 4 週で該当 N 件以上(月 10 万件なら 50 件以上) |
| 持続 | 連続 2 期間以上で出現(単発のスパイクは候補のまま保留) |
| 分離 | 候補定義を既存の値の配下のサンプルに適用したとき、既存との重複率が閾値以下(20%)。超える場合は「分割」または「統合」候補として扱う |
| 一貫性 | 候補定義を該当サンプルに 2 モデル(または言い換えプロンプト 2 種)で適用し、一致 κ ≥ 0.7 |
| 凝集性 | LLM 判定で塊内サンプルの 80% 以上が定義に合致 |
| 分割半分再現 | 塊を無作為二分し、両半分で同じ候補が生成される |
| 階層整合 | 親の件数が候補追加の前後で変わらない(子の追加として扱えること) |

### 2.4 採用ポリシー: 暫定採用+拒否権

- 検証を通過した候補は自動で語彙に追加される(状態 = provisional)。以後の抽出で選択肢に含まれ、出現期間ぶんは `other` と近傍の値の該当分のみを対象に埋め直す(差分バックフィル)。全件再抽出はしない。
- 暫定の値はレポート上で「暫定」と表示される。集計には含まれるので、急増の真因分析で「語彙にないから見えない」状態が起きない。
- 連続 M 期間(8 週)安定して出現し、判定一貫性を保てば自動で stable に昇格。
- 人は週次ダイジェスト(新規・分割・統合・退役の一覧と根拠サンプル)を受け取り、拒否・改名・統合を指示できる。指示がなければそのまま進む。「承認」ではなく「拒否権」である理由は、承認待ちが語彙の陳腐化そのものを生むから。
- 退役: N 期間ゼロ近傍の値はアーカイブし、選択肢から外す。履歴は残る。

### 2.5 過去との整合(時系列を壊さない)

1. **追加優先・階層構造。** 新しい値は原則として既存の親の子として追加する。親レベルの時系列は語彙変更の影響を受けない。
2. **写像表(`code_lineage`)。** 分割、統合、改名、親替えをすべて語彙版間の写像として記録する。任意の過去期間を、任意の語彙版で再表現できる。
3. **差分バックフィル。** 語彙変更時に埋め直すのは、影響を受ける値の配下と `other` の通話のみ。
4. **抽出プロンプトの自動更新。** 語彙は抽出プロンプトの外部データとして注入する。語彙が変わってもプロンプト本文は変わらず、語彙版だけが上がる。
5. **全レポートに語彙版を表示。** 「この数字はどの語彙で数えたか」が常に追える。

### 2.6 自動化の限界

- **意味の妥当性は保証できない。** 機構が保証するのは、分離・一貫性・持続・階層整合であり、「その値が業務上意味のある切り方か」は保証しない。拒否権と週次ダイジェストはこのために残す。
- **断片化のリスク。** 長期運用で近縁の値が増殖しやすい。分離基準と統合候補の自動提案で抑えるが、年 1 回程度の語彙棚卸しは想定しておくべき。
- **対象は業務マスタに依存する。** 新しい書類や画面が出たとき、機構は「顧客が混乱している未知の対象」を検知できるが、正式なコードはマスタ側にある。マスタとの照合を自動化し、未登録は暫定コードで走らせる。
- **モデル更新による語彙のずれ。** 抽出モデルが変わると同じ語彙でも判定境界が動く。合成データ回帰([05_poc_plan.md](05_poc_plan.md) §3)をモデル更新のたびに走らせ、値別の再現率変化を検出する。

## 3. 業務知識表の保守

`known_misconceptions`(既知の誤解一覧)は、「顧客がこう主張したら、それは誤解である」を主張コードで持ち、正しい事実を添える表である。オペレータの訂正がなくても、この表に載っていれば誤解と数える([02_schema.md](02_schema.md) §4.2)。初期値の 8 件は設計者が置いたもので、正誤と文言の確認、以後の追加・退役の担当は依頼者の確認待ち([open_issues.md](open_issues.md) S12)。保守の手順は語彙と同じ(暫定追加 → 拒否権 → 安定化)を用いる。

## 4. 対象マスタ(自動車保険用の草案)

`objects` の初期値。`object_kind` は product / document / screen / procedure / contract_attribute / term / campaign / coverage / rider / competitor / other。coverage と rider は自動車保険で必要になった種別。実データが入ったら 300 件から LLM 誘導し、草案との差を見る([open_issues.md](open_issues.md) X3)。

| object_code | kind | parent | label_ja |
|---|---|---|---|
| PRODUCT_AUTO | product | — | 自動車保険 |
| COV_LIABILITY_BODILY | coverage | PRODUCT_AUTO | 対人賠償 |
| COV_LIABILITY_PROPERTY | coverage | PRODUCT_AUTO | 対物賠償 |
| COV_PERSONAL_INJURY | coverage | PRODUCT_AUTO | 人身傷害 |
| COV_VEHICLE | coverage | PRODUCT_AUTO | 車両保険 |
| COV_DRIVER_SCOPE | coverage | PRODUCT_AUTO | 運転者限定(本人・配偶者・家族) |
| COV_AGE_CONDITION | coverage | PRODUCT_AUTO | 運転者年齢条件 |
| RIDER_LAWYER | rider | PRODUCT_AUTO | 弁護士費用特約 |
| RIDER_PERSONAL_LIABILITY | rider | PRODUCT_AUTO | 個人賠償責任特約 |
| RIDER_FAMILY_BIKE | rider | PRODUCT_AUTO | ファミリーバイク特約 |
| RIDER_ROADSIDE | rider | PRODUCT_AUTO | ロードサービス |
| RIDER_RENTAL_CAR | rider | PRODUCT_AUTO | 代車費用特約 |
| RIDER_PROPERTY_EXCESS | rider | PRODUCT_AUTO | 対物超過修理費用特約 |
| DOC_RENEWAL_NOTICE | document | — | 更新案内 |
| DOC_RENEWAL_NOTICE_2609 | document | DOC_RENEWAL_NOTICE | 更新案内(2026 年 9 月様式) |
| DOC_POLICY_CERT | document | — | 保険証券 |
| DOC_CONTRACT_CONFIRM | document | — | 契約内容確認書 |
| DOC_PAYMENT_SLIP | document | — | 払込票 |
| DOC_PAYMENT_REMINDER | document | — | 引落し不能・督促ハガキ |
| DOC_TAX_CERT | document | — | 保険料控除証明書(自動車保険は対象外) |
| DOC_SUSPENSION_CERT | document | — | 中断証明書 |
| DOC_WEB_CERT_NOTICE | document | — | Web 証券移行案内 |
| DOC_DEBIT_DATE_NOTICE | document | — | 引落し日変更案内 |
| APP_MYPAGE | screen | — | マイページ・アプリ |
| APP_MYPAGE_LOGIN | screen | APP_MYPAGE | ログイン画面 |
| APP_MYPAGE_PROCEDURE | screen | APP_MYPAGE | Web 手続き画面 |
| PROC_PAYMENT_METHOD | procedure | — | 保険料の払込方法 |
| PROC_VEHICLE_REPLACE | procedure | — | 車両入替 |
| PROC_RENEWAL | procedure | — | 満期・更新手続き |
| PROC_GRADE_TRANSFER | procedure | — | 等級の引継ぎ(他社・家族) |
| PROC_TEMP_DRIVER | procedure | — | 一時的な運転者追加 |
| PROC_DECEASED | procedure | — | 契約者死亡時の手続き |
| ATTR_POLICYHOLDER | contract_attribute | — | 契約者 |
| ATTR_NAMED_INSURED | contract_attribute | — | 記名被保険者 |
| ATTR_VEHICLE_OWNER | contract_attribute | — | 車両所有者 |
| ATTR_ADDRESS / ATTR_PHONE / ATTR_EMAIL | contract_attribute | — | 住所 / 電話 / メール |
| ATTR_VEHICLE_REG | contract_attribute | — | 車両登録情報(ナンバー、車検証) |
| ATTR_USAGE | contract_attribute | — | 使用目的 |
| ATTR_MILEAGE | contract_attribute | — | 走行距離区分 |
| TERM_PREMIUM_CHANGE | term | — | 保険料の増減理由 |
| TERM_PREMIUM_ESTIMATE | term | — | 保険料見積り |
| TERM_GRADE | term | — | 等級 |
| TERM_ACCIDENT_COEFF | term | TERM_GRADE | 事故有係数適用期間 |
| TERM_GOLD_DISCOUNT | term | — | ゴールド免許割引 |
| TERM_DEDUCTIBLE | term | — | 免責金額 |
| TERM_RATE_REVISION | term | — | 料率改定 |
| TERM_VEHICLE_RATE_CLASS | term | — | 車両料率クラス |
| COMPETITOR_UNSPECIFIED | competitor | — | 他社(不特定) |
| OUR_CONTACT | other | — | 当社からの連絡(営業電話・DM) |
| OUT_OF_SCOPE_CLAIM | other | — | 事故受付・保険金請求(スコープ外) |

「補償 / 保証」の混同は対象ではなく訴え方の問題なので、混乱の対象は該当する補償(COV_*)に付け、要約に混同を記す。書面の部位(保険料内訳欄、補償一覧表など)は、目録の問い([04_analysis_needs.md](04_analysis_needs.md) #12)に応じて書面の子として育てる。

## 5. 根拠となる研究・事例

- 増分・オープンワールド意図発見: IntentGPT(2024)、LANID(2025)、NILC(2025)、Oracle のライフサイクル対応増分クラスタリング(IJCNLP-AACL 2025)、サービスフィードバックの新興トピック検知(2026)
- タクソノミー生成と一貫性判定: TnT-LLM(KDD 2024)、TopicGPT(NAACL 2024)、LLooM(CHI 2024)、Dial-In LLM(EMNLP 2025)、Clio(2024)
- 製品事例: Intercom Topic Curation(AI 生成トピックを人が統合・改名)、Google CX Insights(発見→凍結→推論)、Enterpret / Unwrap の「自己更新タクソノミー」
- 概念ドリフト検知の古典手法: CUSUM、EWMA、ADWIN

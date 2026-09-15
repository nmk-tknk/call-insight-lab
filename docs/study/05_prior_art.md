# 先行研究・社会実装との突き合わせ: 「ターン帰属+用件単位」設計は車輪の再発明か

- 作成日: 2026-09-15
- 対象: 直前に提案した構造(ターンを原子単位とし、各ターンに「局面」と「用件 ID(非連続可)」を付け、分析上の事実は用件に付け、通話行は導出する)
- 出典注記: 調査時、arXiv・ACL Anthology・多くのベンダー文書への直接アクセスが制限され、多くは検索スニペット・抄録・GitHub README に基づく。数値は原典で再確認すること。

## 0. 結論

**大部分は車輪の再発明であり、それは良い知らせである。** 提案構造の各要素には、対話研究の標準(ISO 24617-2、AMI コーパス、Grosz & Sidner)と商用製品(AWS Contact Lens、Google CX Insights、Dynamics 365)に直接の先例があり、名前・層構造・境界規則・評価指標をそのまま借りられる。独自なのは「局面層と、ターンに対して多対多の用件エンティティを、同一スキーマで実コールセンターデータに適用する」組み合わせだけで、これも CRM の親子ケースと Oracle の "concern"(IJCNLP-AACL 2025)に近い先例がある。

したがって方針は、**設計を捨てるのではなく、既存の語彙と構造に合わせて改名・整形し、評価法を借用する**ことになる。

## 1. 提案要素ごとの先例

| 提案要素 | 直接の先例 | 標準的な名前 | 判定 |
|---|---|---|---|
| ターンを原子単位にし、複数の直交ラベルを付ける | ISO 24617-2(DiAML)の 9 次元(dimension)。DAMSL / SWBD-DAMSL / MRDA の多層タグ。AWS・NICE・Genesys・Google はすべてターン(segment / utterance)+タイムスタンプが基本単位 | dimension(層)、turn / utterance / segment | 先例あり |
| 局面(あいさつ・目的発話・本人確認・議論・クロージング) | IBM 2007「call section」(Greeting / Question / Refine / Research / Resolution / Closing / Out-of-topic、発話分類→隣接統合、精度 87.2%、特許 US8750489)。**NTT 2018「コールシーン」(opening / 要件確認 / 応対 / 顧客確認 / closing、発話単位、日本語)**。Dialpad 2022「Purpose of Call 検出」(F1 88.6)。COPC 由来の 5 段階(Connecting / Identifying / Exploring / Resolving / Maintaining)。AMI の「機能的トピック」(Opening / Chitchat / Closing)。QA スコアカードの Opening / Verification / Discovery / Resolution / Closing | call section / call scene / stage / functional topic | 先例あり(日本語の先例も) |
| 用件が非連続でありうる | ISO の functional segment は「不連続でも、重なっても、複数話者にまたがってもよい」。Grosz & Sidner 1986 の焦点スタック(割り込み → 復帰)。DECODA(仏コールセンター)「複数テーマが不連続な談話区間に現れる」。会話分離(disentanglement)タスク。「long-range topical recurrence」(2026) | discourse segment purpose、thread、theme | 先例あり |
| 事実を用件に付け、ターンには付けない | MultiWOZ / SGD のドメインフレーム(状態がターンを越えて持続)。AMI の抽象要約項目 ↔ 抽出根拠(対話行為 ID)リンク。Oracle 2025 の "concern"(1 セッション複数、F1 0.84、人手 κ 0.79)。商用の要約三点セット issue / outcome(resolution) / action item(AWS 2024-03、Salesforce、Genesys、Dynamics) | issue / concern / contact reason、outcome、action item | 先例あり |
| 根拠を逐語引用で持つ | AWS `IssuesDetected[].CharacterOffsets`、Google `annotationStartBoundary{transcriptIndex, wordIndex}`、AMI の抽出要約リンク | offsets / evidence links | 先例あり(ただし引用文字列ではなく**位置参照**が標準) |
| 通話行を下層から導出 | NXT(NITE XML Toolkit)のスタンドオフ多層注釈。商用はすべて通話レベルの多値ラベル+要約を下層から生成 | stand-off annotation | 先例あり |
| 保留・転送を局面にする | **反例**: 全ベンダーが保留・転送をタイムレンジ付きイベント(annotation)として扱う。ABCD データセットは system action を別話者として持つ | event / annotation | 修正すべき |
| 用件エンティティが複数ターンに多対多で結びつく | 商用アナリティクス製品には**ない**(AWS の issue はハイライト区間、Google の issue は通話レベル)。CRM では親子ケース(Salesforce / ServiceNow)。学術では Oracle の concern | issue(子ケース) | 独自だが正当化可能 |
| 1 ターンに 0〜複数の用件 | disentanglement は 1 メッセージ 1 スレッドが標準。DECODA は 1 文に複数テーマが共存すると報告 | — | 非標準だが根拠あり |
| 混乱シグナル・きっかけを用件の事実にする | 近いのは AMI の Problems/Issues 見出し、Dynamics の root cause / error codes、Genesys のカスタムインサイト枠(最大 10) | custom insight | 独自 |

## 2. 業界のデファクト構造(参考)

商用製品は例外なく 3 層で、局面ラベルは持たない。

1. **ターン層:** タイムスタンプ付き発話、ターンごとの感情(AWS / NICE / Genesys / Google)。
2. **検出層:** ターン上のタイムスタンプ付き検出物。名前は moment(Observe.AI)/ marker(Genesys)/ annotation・highlight(Google)/ point of interest・issue・action item・outcome(AWS)。位置は ms または transcriptIndex+wordIndex または文字オフセット。
3. **通話層:** 多値のカテゴリ・トピック・意図・理由と、issue → outcome → action item 型の生成要約。

**位置の扱い:** 局面ラベルではなく、(a) ルールの時間窓(最初の 30 秒、最後の 10%: AWS / CallMiner / Observe.AI)、(b) 冒頭・末尾の感情(NICE / Genesys)、(c) 通話単位の行動チェック(Zendesk AutoQA の Greeting / Closing / Solution Offered)。局面のタイムラインを出荷しているのは Dynamics 365 Sales(GPT-Calls, 2023: 発話埋め込みをトピックアンカーと照合し時間平滑化)のみ。

**複数用件の扱い:** 通話レベルの多値ラベル(Intercom「1 会話に 1 つ以上のトピック」、Google `IssueAssignment[]` とスコア)か、通話横断のクラスタリング(AWS テーマ検知、Salesforce Conversation Mining、Cresta Topic Discovery)。ターン帰属を伴う用件エンティティは持たない。Zendesk は 1 チケット 1 意図、Airbnb は 1 通話 1 コンタクト理由。

## 3. 人はどこまで一致するか(設計への含意)

| 対象 | 一致度 | 出典 |
|---|---|---|
| 対話行為(粗い 5〜7 クラス) | κ ≈ 0.80 | SWBD-DAMSL、MRDA |
| ISO 次元ごとの機能割当 | κ 0.55〜1.00 | DialogBank |
| 区間の境界(segmentation) | κ 0.55〜0.94、トピック転換は κ 0.48(TIAGE)、会議のサブトピックは「ほとんど一致しない」(Gruenstein 2005) | 各論文 |
| 用件(concern)抽出 | F1 0.84、κ 0.79 | Oracle 2025 |
| 境界評価の知見 | データセット間の差の大半は**粒度の不一致**。「同じ行為だと合意しつつ境界では不一致」が常態 | 2512.17083、2601.12061 |

**含意:** 人は「何が話されたか」と「粗い局面」では一致し、「正確な境界」と「細かいサブトピック」では一致しない。したがって**事実を境界ではなく用件(内容)に付ける**という提案の選択は、文献が支持する方向である。局面は ≤7 の粗い閉集合に保つ。

## 4. 借用すべきもの(設計 v0.3 への反映)

### 4.1 名前

| 提案時 | 改名後 | 根拠 |
|---|---|---|
| matter(用件) | `issue`(または `contact_reason`) | AWS / Google / Salesforce / Cresta / Airbnb |
| phase | `phase` のまま。値は QA 語彙に合わせる: `opening` / `purpose_statement` / `verification` / `discussion` / `closing` / `off_topic` | IBM / NTT / Dialpad / スコアカード。`off_topic` は IBM の Out-of-topic |
| hold_or_transfer(局面) | 廃止。`events` テーブル(`hold` / `transfer` / `system_action`、開始・終了時刻) | 全ベンダー、ABCD |
| 用件の事実 | `reason`(なぜ)/ `outcome`(解決状況)/ `action_items` を基本三点とし、`trigger` / `confusion_*` / `root_cause` をカスタムインサイトとして追加 | 商用の要約三点セット、Dynamics の root cause |
| 用件の主従 | `is_primary` と `score` を持つ | Google `IssueAssignment{issue, score}`、Dialpad の PoC |

### 4.2 層構造(スタンドオフ)

```
turns(call_id, turn_idx, speaker, text, start_ms, end_ms)
turn_phases(call_id, turn_idx, phase)                 -- 局面。話者交代でのみ境界、隣接同ラベルは統合
issues(call_id, issue_id, is_primary, score, reason_l1/l2, trigger, touchpoint,
       confusion_*, outcome, action_items[], root_cause?)
issue_turns(call_id, issue_id, turn_idx)              -- 多対多。非連続可
evidence(call_id, issue_id, field, turn_idx, begin_char, end_char, quote)  -- 位置参照+引用
events(call_id, event_type, start_ms, end_ms)         -- 保留・転送・システム操作
calls  = 上記からの導出ビュー(用件数、主用件、全用件解決、局面ごとのターン数、冒頭/末尾感情)
```

### 4.3 境界と帰属の規則(コードブックに書く)

1. 局面の境界は話者交代の位置にのみ置く(Galley 2003 / AMI)。隣接する同一局面は統合する(IBM 2007)。
2. `verification` と保留は**割り込み区間**であり、進行中の用件を閉じない(Grosz & Sidner の焦点スタック)。復帰後のターンは同じ `issue_id` に戻す。
3. 顧客が複数用件を一文で述べたターン(目的発話)は複数 `issue_id` を持ってよい(DECODA)。それ以外は原則 1 ターン 1 用件。
4. 相槌・確認のターンは直前の用件を引き継ぐ。
5. 用件の粒度は語彙の階層で吸収し、親で集計できるようにする。細かい分割の是非で揉めない。
6. QA 的なルール(冒頭 30 秒に名乗りがあるか)は局面ラベルではなく**時間窓クエリ**で書き、局面精度に依存させない(AWS / CallMiner 流)。

### 4.4 評価法

| 層 | 指標 | 目安 |
|---|---|---|
| 局面(ターン単位) | κ / Krippendorff α | 粗い 6 クラスで κ ≥ 0.7 |
| 局面の境界 | Pk、WindowDiff、窓許容 F1 | 境界は最も弱い数字になる前提 |
| ターン → 用件の帰属 | B-cubed / ARI、または exact-match F1(disentanglement 流) | — |
| 用件の事実(カテゴリ列) | κ、F1 | Oracle の κ 0.79 / F1 0.84 を参照値に |
| 複数モデル一致 | 上記を人手の代わりに 2 モデル間で計測 | 02 §4 の方針と整合 |

人手ラベルがほぼ不可という制約下では、Oracle が 150 区間で行った検証を「2 モデル間一致+分析者の少数目視」に置き換える。

## 5. 判断

- 「車輪の再発明か」への答え: **構造は既存の車輪で組めるし、組むべき。** 独自部分(ターンに多対多で結びつく用件エンティティ)は、CRM の親子ケースと Oracle の concern に先例があり、商用アナリティクスが持たない点はむしろ差別化になる。
- 借用によって減るリスク: 名前と層構造を標準に寄せることで、将来の商用製品・DWH 関数との相互運用、評価指標の比較可能性、コードブックの説明性が上がる。
- 次の PoC では、v0.3(§4.2)で多用件・本人確認を挟む通話を処理し、`issue_turns` の非連続帰属、「目的発話で述べられたが `discussion` に現れない用件」の検出、局面境界の Pk を実際に出す。

## 参考(主要)

- ISO 24617-2 / DiAML: Bunt et al., LREC 2012 https://aclanthology.org/L12-1296/ ; DialogBank(LRE 2018)https://link.springer.com/article/10.1007/s10579-018-9436-9
- SWBD-DAMSL https://web.stanford.edu/~jurafsky/ws97/manual.august1.html ; MRDA(SIGdial 2004)https://aclanthology.org/W04-2319/
- AMI 注釈・トピック分割ガイドライン https://groups.inf.ed.ac.uk/ami/corpus/annotation.shtml ; Galley et al. ACL 2003 https://aclanthology.org/P03-1071/ ; Gruenstein et al. SIGdial 2005 https://aclanthology.org/2005.sigdial-1.13/
- Grosz & Sidner 1986 https://aclanthology.org/J86-3001/
- Kummerfeld et al. ACL 2019(disentanglement)https://aclanthology.org/P19-1374/
- DECODA(LREC 2012 / 2016)https://aclanthology.org/L12-1399/ ; 複数テーマ https://arxiv.org/abs/1812.09321
- IBM Park, CIKM 2007 https://dl.acm.org/doi/10.1145/1321440.1321459 ; 特許 US8750489 https://patents.google.com/patent/US8750489
- NTT コールシーン分類(APSIPA 2018)https://ieeexplore.ieee.org/document/8659521/
- Dialpad, Purpose of Call(NAACL Industry 2022)https://aclanthology.org/2022.naacl-industry.29/
- Oracle, Lifecycle-Aware Clustering(IJCNLP-AACL 2025)https://aclanthology.org/2025.ijcnlp-long.170/
- GPT-Calls(Microsoft, 2023)https://arxiv.org/abs/2306.07941 ; COPC 由来 5 段階(2025)https://arxiv.org/abs/2508.04423
- 分割評価の粒度問題(2025-12)https://arxiv.org/abs/2512.17083 ; コードブック注入分割(2026-01)https://arxiv.org/abs/2601.12061
- MultiWOZ / SGD / ABCD https://aclanthology.org/2021.naacl-main.239/ / MultiDoGO https://github.com/awslabs/multi-domain-goal-oriented-dialogues-dataset / NatCS https://arxiv.org/abs/2305.03007
- AWS Contact Lens issue detection https://docs.aws.amazon.com/connect/latest/adminguide/contact-lens-issue-detection.html ; PCA 出力スキーマ https://github.com/aws-samples/amazon-transcribe-post-call-analytics/blob/develop/docs/output_json_structure.md
- Google CX Insights API(Issue / CallAnnotation)https://cloud.google.com/contact-center/insights/docs/reference/rpc/google.cloud.contactcenterinsights.v1
- Dynamics 365 通話要約(区間タイムライン)https://learn.microsoft.com/en-us/dynamics365/sales/view-and-understand-call-summary ; Copilot 要約項目 https://learn.microsoft.com/en-us/dynamics365/contact-center/administer/customize-copilot-conv-summary
- Salesforce 親子ケース https://help.salesforce.com/s/articleView?id=service.cases_parent.htm ; Zendesk AutoQA https://support.zendesk.com/hc/en-us/articles/7043747123354 ; Intercom トピック https://www.intercom.com/help/en/articles/11390087

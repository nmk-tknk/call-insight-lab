# 合成コーパス仕様: 自動車保険(事故対応を除く)の通話

- 作成日: 2026-09-20
- 前提: 実データは使えない(09 P1)。業種は自動車保険、事故対応(事故受付・保険金請求・示談)はスコープ外。書き起こしは話者分離・ターン分割済み、フィラー残存、句読点なし、数字表記混在、漢字誤りあり。業務メタデータなし。マスキング未実施。LLM は設定可能だが費用を抑えたく、ローカル LLM 前提の可能性がある。
- 目的: (1) 抽出器と品質ゲートを合成データで実測する、(2) 急増真因レシピを封印シナリオで盲検テストする、(3) マスキング処理を合成の個人情報で検証する。
- 本書は「何を作るか」の仕様。生成器の実装は `poc/synth/`(未作成)で行う。

## 0. 要点

- 通話は **用件の組合せ × 混乱の有無 × きっかけ × ASR 風の乱れ × 合成個人情報** で生成する。正解ラベルは生成時の仕様そのものであり、v0.3.1 の注釈層に `annotator = 'synthetic:<gen_id>'` の run として保存する。抽出 run と同じ SQL で比較できる。
- 用件は依頼者の 8 種を核に **34 種**(§2)。うち事故関連 3 種は「スコープ外を正しく弾けるか」を試すために少量混ぜる。
- 混乱の対象は依頼者の 3 点を核に **16 点**(§3)。「補償」と「保証」の混同のように、ASR の漢字誤りと顧客の誤解が重なる点を意図的に入れる。
- 急増シナリオは **5 本のプール**(§5)から乱数で 1 本を選び、正解を封印ファイルに置く。分析者は封印を開けずにレシピを回し、結果を出してから開ける。これが「盲検」の実務的な形で、09 Q3 の回答になる。
- 規模は 2 段。第 1 段 300 件で抽出器を固め、第 2 段 2,000 件(26 週分)で急増と語彙進化を試す。

## 1. スコープ境界

| 区分 | 扱い | 生成での割合 |
|---|---|---|
| 契約の照会・手続き・苦情(事故に起因しない) | 対象 | 92% |
| 事故起因だが契約の手続き(事故後の等級確認、事故有係数の説明要求、解約) | **対象**。事故の詳細は語らず、契約への影響だけが話題 | 3% |
| 事故受付・保険金請求・示談進捗 | **対象外**。生成はするが、抽出器が `object_code = OUT_OF_SCOPE_CLAIM` に落とし用件の分析列を埋めないことを検証する | 5% |

## 2. 用件の一覧(行為 × 対象)

行為は v0.3.1 の `issue_action`(inquire / request_change / apply / cancel / report_problem / complain / confirm / suggest / other)。対象は §7 の対象マスタ。★ は依頼者が挙げた核、それ以外は追加バリエーション。件数比は第 2 段の平常期間での目安。

| # | 用件 | 行為 × 対象 | 典型的なきっかけ | 比率 |
|---|---|---|---|---|
| 1★ | 補償内容の確認: 息子・親戚・友人が運転しても補償されるか | inquire × COV_DRIVER_SCOPE | life_event(帰省、免許取得)、received_notice(証券) | 8% |
| 2★ | 郵送物の内容が分からない(更新案内、証券、ハガキ、契約内容確認書) | inquire × DOC_* | received_notice | 10% |
| 3★ | 保険料の払込方法の確認(口座振替、クレジット、コンビニ払、年払・月払) | inquire × PROC_PAYMENT_METHOD | received_notice(払込票)、viewed_bill | 6% |
| 4★ | 名義変更(契約者、記名被保険者、車両所有者) | request_change × ATTR_POLICYHOLDER / ATTR_NAMED_INSURED / ATTR_VEHICLE_OWNER | life_event(結婚、相続、譲渡) | 4% |
| 5★ | 車両入替 | request_change × PROC_VEHICLE_REPLACE | life_event(車購入) | 5% |
| 6★ | 新規加入 | apply × PRODUCT_AUTO | life_event、word_of_mouth、media_sns | 4% |
| 7★ | 解約申出 | cancel × PRODUCT_AUTO(`motive_code` 必須) | life_event(車を手放す)、competitor | 4% |
| 8★ | 更新内容の確認: 無事故なのに保険料が上がった | inquire × TERM_PREMIUM_CHANGE | received_notice(更新案内) | 8% |
| 9★ | ゴールド免許になったが割引は増えるか | inquire × TERM_GOLD_DISCOUNT | life_event(免許更新) | 3% |
| 10 | 等級・事故有係数の確認(等級はいくつか、なぜ下がったか、いつ戻るか) | inquire × TERM_GRADE / TERM_ACCIDENT_COEFF | received_notice、followup | 3% |
| 11 | 運転者限定・年齢条件の変更(子どもが免許取得、別居の子が乗る) | request_change × COV_DRIVER_SCOPE / COV_AGE_CONDITION | life_event | 4% |
| 12 | 車両保険の有無・免責金額・保険金額の確認 | inquire × COV_VEHICLE / TERM_DEDUCTIBLE | received_notice(証券)、word_of_mouth | 3% |
| 13 | 特約の内容確認(弁護士費用、個人賠償、ファミリーバイク、ロードサービス、代車) | inquire × RIDER_* | received_notice(証券)、media_sns | 4% |
| 14 | 特約の追加・削除 | request_change × RIDER_* | followup、life_event | 2% |
| 15 | 住所・電話・メールの変更 | request_change × ATTR_ADDRESS / ATTR_PHONE / ATTR_EMAIL | life_event(引越し) | 4% |
| 16 | 支払方法の変更(カード変更、口座変更、分割へ) | request_change × PROC_PAYMENT_METHOD | viewed_bill、followup | 3% |
| 17 | 引落し不能・未払いの連絡(督促ハガキを受け取った) | inquire / report_problem × DOC_PAYMENT_REMINDER | received_notice | 3% |
| 18 | 証券の再発行、証券が届かない(Web 証券) | inquire / request_change × DOC_POLICY_CERT | received_notice(不着)、followup | 3% |
| 19 | 保険料控除証明書の請求(自動車保険は所得控除の対象外) | inquire × DOC_TAX_CERT | media_sns、word_of_mouth、季節(10〜11 月) | 2% |
| 20 | 中断証明書の発行(車を手放す、海外赴任) | apply × DOC_SUSPENSION_CERT | life_event | 2% |
| 21 | 満期・更新手続き(自動更新か、更新しない場合の手続き) | inquire / confirm × PROC_RENEWAL | received_notice | 3% |
| 22 | 他社への乗換え(解約日の調整、等級引継ぎ、見積比較) | cancel / inquire × PROC_GRADE_TRANSFER | competitor、media_sns | 2% |
| 23 | 家族間の等級引継ぎ | inquire / request_change × PROC_GRADE_TRANSFER | life_event | 1% |
| 24 | 契約者死亡時の手続き | inquire / request_change × PROC_DECEASED | life_event | 1% |
| 25 | ナンバー変更・登録地変更(車検証の変更) | request_change × ATTR_VEHICLE_REG | life_event | 1% |
| 26 | 使用目的の変更(日常・レジャー → 通勤) | request_change × ATTR_USAGE | life_event、our_outbound_contact(確認連絡) | 1% |
| 27 | 走行距離区分の変更・申告 | request_change × ATTR_MILEAGE | received_notice(更新案内) | 1% |
| 28 | 一時的な運転者の追加(1 日だけ、帰省中) | inquire × PROC_TEMP_DRIVER | life_event | 1% |
| 29 | マイページ・アプリのログイン不可、Web 手続きの操作 | report_problem × APP_MYPAGE | app_or_web_change、received_notice(Web 案内) | 3% |
| 30 | 保険料の見積り依頼・条件変更時の増減 | inquire × TERM_PREMIUM_ESTIMATE | life_event、competitor | 2% |
| 31 | 更新時期に自動更新されて解約したかった(苦情) | complain × PROC_RENEWAL | viewed_bill | 1% |
| 32 | 営業電話・郵送物が多い(苦情)、通知が来ない(苦情) | complain × DOC_* / OUR_CONTACT | our_outbound_contact | 1% |
| 33 | 改善提案(更新案内に前年との差の内訳を載せてほしい 等) | suggest × DOC_RENEWAL_NOTICE | received_notice | 1% |
| 34 | 事故受付・保険金請求・示談進捗 | (スコープ外)× OUT_OF_SCOPE_CLAIM | — | 5%(§1) |

多用件の通話は 30% とし、組合せは「更新案内を見て保険料の理由を聞き、ついでに払込方法を変える」「車両入替と同時に運転者限定を変える」「解約申出の途中で等級引継ぎを聞く」のように業務上自然なものに限る(§8 の組合せ表)。

## 3. 混乱の対象(confusion_object)と訴え方

依頼者の 3 点(★)と追加。`confusion_type` は direct(「わかりにくい」と明言)/ indirect_misread(誤解した状態で入電)/ indirect_clarify(既に案内済みの内容を確認するための入電)。

| # | 混乱の対象 | 典型的な誤解・不明 | 主な訴え方 | 関連用件 |
|---|---|---|---|---|
| 1★ | TERM_PREMIUM_CHANGE(保険料の増減理由) | 無事故無違反なのに上がった。等級は上がったのに保険料は上がった。料率改定・年齢区分・車両料率クラス・割引消滅が更新案内から読み取れない | indirect_misread, direct | 8, 10 |
| 2★ | DOC_POLICY_CERT(証券の補償内容欄) | 証券を見ても具体的に何が補償されるか分からない。「対人無制限」「対物」「人身傷害」の違い | direct | 1, 12, 13 |
| 3★ | PROC_PAYMENT_METHOD(払込方法) | 払込票と口座振替が両方来た気がする。年払と月払の違い。カード払の引落し日 | indirect_clarify, direct | 3, 16 |
| 4 | TERM_GRADE / TERM_ACCIDENT_COEFF(等級と事故有係数) | 等級が同じでも事故有係数で保険料が違うことが分からない | indirect_misread | 10 |
| 5 | TERM_GOLD_DISCOUNT | ゴールドになったら即反映されると思っている(更新時の免許色で判定) | indirect_misread | 9 |
| 6 | COV_DRIVER_SCOPE(運転者限定、「別居の未婚の子」) | 別居の子、既婚の子、友人の扱い。「家族限定」の家族の範囲 | indirect_misread, direct | 1, 11 |
| 7 | COV_AGE_CONDITION(年齢条件) | 年齢条件は記名被保険者だけに掛かると思っている / 全運転者に掛かると思っている | indirect_misread | 1, 11 |
| 8 | TERM_DEDUCTIBLE(免責金額) | 免責の意味(自己負担)が分からない | direct | 12 |
| 9 | DOC_TAX_CERT(控除証明書) | 自動車保険も生命保険料控除の対象と思っている | indirect_misread | 19 |
| 10 | PROC_RENEWAL(自動更新) | 自動更新かどうか、何もしないとどうなるか | indirect_clarify | 21, 31 |
| 11 | DOC_RENEWAL_NOTICE(更新案内の様式) | 前年との差の内訳がない。「見直し後」「現在」の列が読めない | direct | 2, 8 |
| 12 | DOC_POLICY_CERT 不着(Web 証券) | 証券が届かないのは事故だと思っている | indirect_misread | 18 |
| 13 | RIDER_LAWYER / RIDER_PERSONAL_LIABILITY(特約名) | 弁護士費用特約、個人賠償の意味と適用範囲 | direct | 13 |
| 14 | 「補償」と「保証」 | 顧客が「ほしょう」を保証(メーカー保証)の意味で使い、話が噛み合わない。ASR も「保証」と誤変換する | indirect_misread | 1, 12 |
| 15 | DOC_PAYMENT_REMINDER(督促ハガキ) | 引落しできなかった理由と再引落し日が読み取れない | direct | 17 |
| 16 | ATTR_USAGE / ATTR_MILEAGE(使用目的・走行距離) | 申告と実態がずれると補償されないと思っている(逆も) | indirect_clarify | 26, 27 |

混乱ありの通話は平常期間で 25%。急増期間はシナリオに応じて特定対象が増える(§5)。

## 4. 書き起こしの様式(ASR 風の乱れ)

依頼者回答(09 Q4): 話者分離・ターン分割済み、フィラー残存、句読点なし、数字表記混在、漢字誤りあり。生成は「きれいな台本 → 決定的な乱れ注入」の 2 段にし、乱れは乱数シード付きで再現できるようにする。

| 乱れ | 仕様 | 率(目安) |
|---|---|---|
| 句読点なし | 「。」「、」を除去。疑問符も除去 | 100% |
| フィラー | えー / あの / えっと / その / なんか / はい / そうですね を発話頭・句境界に挿入。顧客に多め | 顧客ターンの 60%、オペレータの 30% |
| 相槌ターン | 「はい」「ええ」「なるほど」だけのターン | 全ターンの 15% |
| 言い直し | 「保険料が、あ、保険の料金が」型の途中訂正 | 顧客ターンの 10% |
| 数字表記の混在 | 三千円 / 3000 円 / さんぜんえん、二十等級 / 20 等級 | 数字を含むターンの 100%(表記は 3 種から乱択) |
| 漢字誤り(同音異義) | 保険料→保健料、補償→保証、証券→商圏・証券、等級→統一級、更新→交信、特約→徳役、免責→面積、名義→明記、車両→社領、満期→万期 | 対象語の 8% |
| 固有名詞の誤認識 | 人名・車種名・地名の一部を音が近い別語に | 出現の 15% |
| ターン分割の誤り | 2 発話が 1 ターンに結合 / 1 発話が 2 ターンに分裂 | 3% |
| 話者ラベルの誤り | customer と agent の取り違え | 1% |
| ターン時刻 | 文字数から話速を仮定して start_ms / end_ms を生成。保留は `events` に | 100% |
| 信頼度 | `turns.asr_confidence` は乱れ量から逆算した値(実 ASR の信頼度は取れないため参考値と明記) | 100% |

## 5. 急増シナリオのプールと封印(09 Q3 の回答)

「盲検」とは、分析する人が答えを知らない状態で分析することを指す。合成データでは誰かが「真因」を決めるので、決めた人が分析すると当然その真因を見つける。それを避ける最も簡単な方法は、生成器が下記プールから乱数で 1 本を選び、選ばれたシナリオと真因を封印ファイル(`poc/synth/out/answer_key.json`、Git 管理外)に書くことである。分析者(依頼者でも設計者でも)は封印を開けずにレシピを回し、上位仮説を書いてから開ける。同一人物でも成立する。

各シナリオは「急増期間 / 該当用件 / ファセットの署名(集計で出るべき差)/ 未説明残余(仮説で説明できない分)」を持つ。残余を必ず入れるのは、02 §2.1 の反証ステップを試すため。

| # | シナリオ | 期間 | 急増する用件と署名 | 意図的な残余 |
|---|---|---|---|---|
| A | **更新案内の様式変更**で保険料差の理由欄が消え、料率改定と重なった | W18〜W22 | #8 が 2.5 倍。trigger = received_notice、trigger_object = DOC_RENEWAL_NOTICE_2609、confusion = indirect_misread × TERM_PREMIUM_CHANGE。direct × DOC_RENEWAL_NOTICE も増える | 同期間に #3(払込方法)も 1.3 倍。原因は別(引落し日変更の案内)で、様式変更では説明できない |
| B | **特定車種の車両料率クラス改定**で該当車の保険料が上がった | W10〜W14 | #8 が 1.8 倍。ただし object の親(車種)で偏る。confusion = indirect_misread × TERM_PREMIUM_CHANGE。更新案内は変わっていない | #1(運転者範囲)が季節要因(帰省)で 1.4 倍 |
| C | **控除証明書の季節**(10〜11 月)に、他社の通知を見た顧客が自動車保険も対象と誤解 | W40〜W45 | #19 が 4 倍。trigger = media_sns / word_of_mouth、confusion = indirect_misread × DOC_TAX_CERT | なし(単純ケース。レシピが素直に当てられるかの基準線) |
| D | **Web 証券への移行**で紙の証券が届かなくなり「証券が来ない = 契約されていない」と誤解 | W06〜W12 | #18 が 3 倍。trigger = received_notice(移行案内)/ 不着、confusion = indirect_misread × DOC_POLICY_CERT。#29(マイページ)も 2 倍 | #7(解約)が競合キャンペーンで 1.5 倍。移行とは無関係 |
| E | **引落し日の変更案内**が読まれず、督促ハガキが一斉に届いた | W30〜W33 | #17 が 5 倍、#3 が 2 倍。trigger = received_notice × DOC_PAYMENT_REMINDER、confusion = direct × DOC_PAYMENT_REMINDER。emotion_start = negative が増える | なし |

第 2 段の 2,000 件は 26 週にわたり、平常期間の分布(§2 の比率)に選ばれた 1 本の署名を重ねて生成する。分割半分再現(02 §4)のため、各週の件数は 60〜100 の幅で揺らす。

## 6. 合成個人情報とマスキング検証(09 Q6 の回答を受けて)

実データはマスキングされていないため、取込時にマスキングを行う必要がある。マスキング前のデータは外部 API に送れないので、マスキング処理はローカルで動かす。合成データに偽の個人情報を意図的に埋め込めば、この処理の再現率を測れる。

| 種別 | 生成規則 | 出現 |
|---|---|---|
| 氏名 | 架空の姓名(実在しない組合せを姓リスト × 名リストで生成)。本人確認と名義変更で登場 | 90% の通話 |
| 証券番号 | 固定フォーマット(例: 英字 2 + 数字 8)。読み上げは数字表記混在 | 70% |
| 電話番号 | 架空の番号(0X0-XXXX-XXXX、末尾 4 桁を乱数) | 40% |
| 住所 | 架空の市区町村・番地(実在市区名 + 架空の町名) | 30% |
| 生年月日 | 年齢条件の確認で読み上げ | 30% |
| 車両ナンバー | 地域名 + 分類番号 + かな + 4 桁 | 25% |
| 口座・カード | 銀行名と下 4 桁のみ。全桁は生成しない | 15% |

正解は `turns` と別に `synth_pii_spans(call_id, turn_idx, begin_char, end_char, kind)` として保存し、マスキング処理の出力と突き合わせる。マスキング後の本文が `turns.text` になり、マスキング前は保持しない(保持方針は 09 G2)。

## 7. 対象マスタ(自動車保険用の草案)

v0.3.1 の `objects` に入れる草案。`object_kind` は product / document / screen / procedure / contract_attribute / term / campaign / coverage / rider / other。coverage と rider は自動車保険で必要になった種別で、`codes(code_set='object_kind')` に追加する。

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
| OUR_CONTACT | other | — | 当社からの連絡(営業電話・DM) |
| OUT_OF_SCOPE_CLAIM | other | — | 事故受付・保険金請求(スコープ外) |

「補償 / 保証」の混同(§3-14)は対象ではなく訴え方の問題なので、`confusion_object` は該当する補償(COV_*)に付け、`summary_ja` に混同を記す。

## 8. 生成パイプライン

```
scenario_spec (JSON, 通話ごと)              ← §2 の比率 + §5 の署名 + §6 の PII スロットから乱数生成(seed 付き)
  ├ issues[]: action, object, trigger, trigger_object, outcome, confusion_type/object/resolved,
  │           motive, customer_accepted, agent_actions[], turn_flags[]
  ├ phases: 期待する局面の並び(本人確認の位置、保留の有無)
  └ pii_slots: 氏名・証券番号・…の値
        ↓ LLM(生成用)
clean_dialogue (話者付きターン列。句読点あり)
        ↓ 規則(決定的、seed 付き)
noisy_transcript (§4 の乱れ) + turns.start_ms/end_ms + events + synth_pii_spans
        ↓
ground_truth run: annotation_runs(annotator='synthetic:gen_v1') に issues / issue_turns / turn_phases / evidence(引用は clean 側から取り、noisy 側に位置を写像)/ agent_actions / turn_flags を保存
```

生成用 LLM と抽出用 LLM は別にする(09 SD6)。生成には個人情報が含まれないので外部 API を使ってよく、一度きりの費用で済む。抽出はローカル LLM を想定する(§9)。

正解の `evidence` は clean 側の引用を noisy 側に写像するため、乱れ注入で引用箇所が変形した場合(漢字誤り、言い直し挿入)は `verified = false` の正解行になる。これは「実 ASR では逐語一致が取れない根拠がある」ことの模擬であり、02 §6 の逐語一致率 98% がどの程度の乱れまで成立するかを測る材料になる。

## 9. モデル計画(費用を抑える。09 X6 の更新)

| 工程 | 想定 | 理由 |
|---|---|---|
| 合成台本の生成(一度きり) | 外部 API の中位モデル、または生成専用にローカル | 個人情報なし。品質が高い方が抽出の評価が厳しくなる |
| 乱れ注入・PII 埋込 | 規則(LLM 不要) | 再現性 |
| マスキング(v1 の取込) | ローカル(規則 + NER、またはローカル LLM) | マスキング前は外部に出せない |
| 抽出(局面・用件・分析列) | **ローカル LLM を第一候補**。日本語対応のオープンウェイトモデルを 300 件で比較し、JSON スキーマ制約付きデコードが使える実行系を選ぶ | 月 10 万件の継続費用 |
| 2 run 一致 | ローカル 2 モデル、またはローカル × 外部 API(マスキング済み) | 外部 API は判断列のみに限定すれば費用が抑えられる |

ローカル LLM で懸念されるのは、(1) 長い通話(4〜6k トークン)での帰属精度、(2) 閉じた語彙への準拠(スキーマ制約付きデコードで担保)、(3) indirect 混乱の検出力。第 1 段 300 件で外部 API の上位モデルと κ を比べ、列ごとに「ローカルで足りる列 / 外部に出す列」を決める。全列を外部に出す場合の費用は、規模とモデルが決まってから別途見積もる。

## 10. 規模と段階

| 段 | 件数 | 目的 | 測るもの |
|---|---|---|---|
| 第 1 段 | 300 件(平常分布のみ、急増なし) | 抽出器と語彙を固める。ローカル LLM と外部 API の比較 | 逐語一致率、列ごとの κ、混乱の再現率・適合率、スコープ外の除外率、マスキング再現率 |
| 第 2 段 | 2,000 件(26 週、シナリオ 1 本を封印) | 急増真因レシピの盲検テスト、分割半分再現、語彙進化の検知 | 上位 3 仮説に真因が入るか、残余の可視化、意図的に語彙から外した用件(#20 中断証明書、#28 一時運転者)を `other` から検知できるか |

第 2 段で語彙進化(04)を試すため、初期語彙から #20 と #28 の対象コードを意図的に外し、`other_text` からの検知と暫定コード生成が動くかを見る。

## 11. 未決(09 に登録)

- SD8: 生成用モデルの選定(外部 API かローカルか)。費用上限は未回答(09 Q2-c)
- SD9: 抽出用ローカル LLM の候補と実行系(スキーマ制約付きデコードの可否)
- MK1: マスキングの方式(規則 + NER / ローカル LLM)と、マスキング前データの保持方針
- SD10: 用件比率(§2)と混乱率(§3)の妥当性。実データがないため設計者の推定。依頼者の業務感覚で補正する

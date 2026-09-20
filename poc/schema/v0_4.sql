-- call-insight-lab  論理スキーマ v0.4(v0_3.sql → v0_3_1.sql の後に適用する追加のみの差分)
-- 根拠: docs/study/13_v04_concept.md
--
-- v0.4 の要点
--   注釈層に LLM が書くのは「構造」(局面、用件の切り出し、ターン帰属)と「発話行為」(誰が何を明言したか)だけ。
--   混乱の型・動機・結果・受容・横断フラグ・感情は、発話行為と業務知識表から SQL で導く(§3 のビュー)。
--   v0.3.1 の判断列(issues.confusion_type など)は表としては残すが、v0.4 の run では仮値('unknown' / 'none' / false)のまま触らない。
--   分析用ビュー(v_issues / v_calls / v_call_flags / v_agent_actions)を置き換え、v0.4 の run では判断列を導出ビューから返す。
--   列名・列数は変えないので、v0.3.1 向けの集計 SQL はそのまま動く。判断を「保存しない」ことで、規則の変更は SQL の変更だけで反映される。
--
-- 追加の分類
--   §1 語彙: act / aspect / claim / emotion_kind / intent、既知の誤解一覧(業務知識)
--   §2 注釈層: acts(発話行為)、取込層: masked_spans
--   §3 導出ビュー: 判断列の導出
--   §4 不変条件
--   §5 分析用ビューの置き換え(v0.4 run では判断列を導出ビューから返す)
--   §6 初期語彙(任意)

------------------------------------------------------------
-- 1. 語彙と業務知識
------------------------------------------------------------
-- 既知の誤解一覧。「顧客がこう主張したら、それは誤解である」を業務側が保守する。
-- 顧客の主張(acts.act_code='assert_belief')の value_code がここにあれば indirect_misread と数える。
CREATE TABLE known_misconceptions (
  claim_code      VARCHAR PRIMARY KEY,           -- codes(code_set='claim') と同じ値
  object_code     VARCHAR REFERENCES objects(object_code),
  aspect_code     VARCHAR,                       -- codes(code_set='aspect')
  label_ja        VARCHAR NOT NULL,
  correct_fact_ja VARCHAR,                       -- 正しい事実(オペレータの訂正文の素)
  valid_from      VARCHAR NOT NULL REFERENCES vocab_versions(vocab_version),
  valid_to        VARCHAR REFERENCES vocab_versions(vocab_version)
);

------------------------------------------------------------
-- 2. 発話行為(注釈層)と、マスキング結果(取込層)
------------------------------------------------------------
-- 発話行為: 「誰が / 何をした / 何について / どの側面 / 値」を、必ず引用付きで持つ。
-- すべて明言(引用がその値を直接含む)であることが v0.4 の規約。推論した値は入れない。
CREATE TABLE acts (
  run_id          VARCHAR NOT NULL REFERENCES annotation_runs(run_id),
  call_id         VARCHAR NOT NULL,
  act_idx         INTEGER NOT NULL,              -- 通話内の連番
  turn_idx        INTEGER NOT NULL,
  issue_idx       INTEGER,                       -- 用件に帰属しない行為(挨拶、暴言、感情表出)は NULL 可
  speaker         VARCHAR NOT NULL CHECK (speaker IN ('customer','agent')),
  act_code        VARCHAR NOT NULL,              -- codes(code_set='act')。話者ごとに許される値が決まる(I11)
  object_code     VARCHAR REFERENCES objects(object_code),
  aspect_code     VARCHAR,                       -- codes(code_set='aspect'): timing/amount/content/delivery/scope/procedure/readability/other
  value_code      VARCHAR,                       -- 行為ごとの閉じた値。state_reason→motive, state_trigger→trigger, assert_belief→claim,
                                                 -- express_emotion→emotion_kind, state_intent→intent, state_quantity→NULL(value_text/num を使う)
  value_text      VARCHAR,                       -- 数量の陳述など、閉じた値にならないもの(集計には使わない)
  value_num       DOUBLE,
  begin_char      INTEGER NOT NULL,
  end_char        INTEGER NOT NULL,
  quote           VARCHAR NOT NULL,
  verified        BOOLEAN,                       -- turns.text[begin:end] = quote
  PRIMARY KEY (run_id, call_id, act_idx),
  FOREIGN KEY (call_id, turn_idx) REFERENCES turns(call_id, turn_idx)
);

-- 取込層: マスキングの結果。turns.text はマスキング後の本文であり、ここに「どこを何としてマスキングしたか」を残す。
CREATE TABLE masked_spans (
  call_id         VARCHAR NOT NULL REFERENCES calls(call_id),
  turn_idx        INTEGER NOT NULL,
  begin_char      INTEGER NOT NULL,              -- マスキング後本文での位置
  end_char        INTEGER NOT NULL,
  kind            VARCHAR NOT NULL,              -- name/policy_no/phone/address/birthdate/plate/account/other
  masker          VARCHAR NOT NULL,              -- 'rule:<name>' | 'ner:<model>' | 'llm:<model>'
  PRIMARY KEY (call_id, turn_idx, begin_char),
  FOREIGN KEY (call_id, turn_idx) REFERENCES turns(call_id, turn_idx)
);

------------------------------------------------------------
-- 3. 導出ビュー(判断列を発話行為から導く。規則はここが唯一の定義)
------------------------------------------------------------
-- 用件ごとの導出。各判断列の規則:
--   trigger_code        : 顧客の state_trigger の value_code。なければ 'unknown'
--   motive_code         : 顧客の state_reason の value_code。なければ 'unknown'(推し量らない)
--   confusion_type      : express_difficulty があれば 'direct'
--                         なければ assert_belief に (a) 同一用件で後続する agent の corrected があるか (b) value_code が known_misconceptions にあれば 'indirect_misread'
--                         なければ mention_prior_notice があれば 'indirect_clarify'
--                         なければ 'none'
--   confusion_object    : 上で採用した行為の object_code
--   confusion_resolved  : 混乱あり かつ その行為より後に顧客の accept があれば TRUE、reject があれば FALSE、どちらもなければ NULL
--   customer_accepted   : 顧客の最後の accept/reject が accept なら TRUE、reject なら FALSE、なければ NULL
--   outcome_code        : agent の escalated → 'escalated'; callback_promised → 'callback_promised';
--                         agent の explained/changed/reissued/redirected_web があり customer_accepted が FALSE でなければ 'resolved';
--                         customer_accepted が FALSE、または agent の対応行為がなければ 'unresolved'; それ以外 'unknown'
--   repeat_contact_signal: mention_prior_contact があれば TRUE
--   aspect_code         : 主たる依頼行為(issue_action 系の act)の aspect_code
CREATE VIEW v_issue_derived AS
WITH a AS (
  SELECT * FROM acts WHERE issue_idx IS NOT NULL
),
req AS (  -- 用件の主たる依頼行為(最初の issue_action 系の行為)
  SELECT run_id, call_id, issue_idx, act_code, object_code, aspect_code,
         ROW_NUMBER() OVER (PARTITION BY run_id, call_id, issue_idx ORDER BY turn_idx, act_idx) AS rn
  FROM a WHERE speaker = 'customer'
    AND act_code IN ('inquire','request_change','apply','cancel','report_problem','complain','confirm','suggest')
),
trg AS (
  SELECT run_id, call_id, issue_idx, value_code, object_code,
         ROW_NUMBER() OVER (PARTITION BY run_id, call_id, issue_idx ORDER BY turn_idx, act_idx) AS rn
  FROM a WHERE speaker = 'customer' AND act_code = 'state_trigger'
),
mot AS (
  SELECT run_id, call_id, issue_idx, value_code,
         ROW_NUMBER() OVER (PARTITION BY run_id, call_id, issue_idx ORDER BY turn_idx, act_idx) AS rn
  FROM a WHERE speaker = 'customer' AND act_code = 'state_reason'
),
diff AS (
  SELECT run_id, call_id, issue_idx, object_code, turn_idx, act_idx,
         ROW_NUMBER() OVER (PARTITION BY run_id, call_id, issue_idx ORDER BY turn_idx, act_idx) AS rn
  FROM a WHERE speaker = 'customer' AND act_code = 'express_difficulty'
),
misread AS (
  SELECT b.run_id, b.call_id, b.issue_idx, b.object_code, b.turn_idx, b.act_idx,
         ROW_NUMBER() OVER (PARTITION BY b.run_id, b.call_id, b.issue_idx ORDER BY b.turn_idx, b.act_idx) AS rn
  FROM a b
  WHERE b.speaker = 'customer' AND b.act_code = 'assert_belief'
    AND ( EXISTS (SELECT 1 FROM a c WHERE c.run_id = b.run_id AND c.call_id = b.call_id AND c.issue_idx = b.issue_idx
                    AND c.speaker = 'agent' AND c.act_code = 'corrected' AND (c.turn_idx, c.act_idx) > (b.turn_idx, b.act_idx))
       OR EXISTS (SELECT 1 FROM known_misconceptions k WHERE k.claim_code = b.value_code AND k.valid_to IS NULL) )
),
clar AS (
  SELECT run_id, call_id, issue_idx, object_code, turn_idx, act_idx,
         ROW_NUMBER() OVER (PARTITION BY run_id, call_id, issue_idx ORDER BY turn_idx, act_idx) AS rn
  FROM a WHERE speaker = 'customer' AND act_code = 'mention_prior_notice'
),
conf AS (
  SELECT i.run_id, i.call_id, i.issue_idx,
         CASE WHEN d.rn = 1 THEN 'direct' WHEN m.rn = 1 THEN 'indirect_misread' WHEN c.rn = 1 THEN 'indirect_clarify' ELSE 'none' END AS confusion_type,
         COALESCE(d.object_code, m.object_code, c.object_code) AS confusion_object_code,
         COALESCE(d.turn_idx, m.turn_idx, c.turn_idx) AS conf_turn,
         COALESCE(d.act_idx, m.act_idx, c.act_idx) AS conf_act
  FROM issues i
  LEFT JOIN diff d    ON d.run_id = i.run_id AND d.call_id = i.call_id AND d.issue_idx = i.issue_idx AND d.rn = 1
  LEFT JOIN misread m ON m.run_id = i.run_id AND m.call_id = i.call_id AND m.issue_idx = i.issue_idx AND m.rn = 1
  LEFT JOIN clar c    ON c.run_id = i.run_id AND c.call_id = i.call_id AND c.issue_idx = i.issue_idx AND c.rn = 1
),
lastacc AS (  -- 顧客の最後の了承/不服
  SELECT run_id, call_id, issue_idx, act_code, turn_idx, act_idx,
         ROW_NUMBER() OVER (PARTITION BY run_id, call_id, issue_idx ORDER BY turn_idx DESC, act_idx DESC) AS rn
  FROM a WHERE speaker = 'customer' AND act_code IN ('accept','reject')
),
ag AS (  -- オペレータの対応行為の有無
  SELECT run_id, call_id, issue_idx,
         BOOL_OR(act_code = 'escalated')          AS escalated,
         BOOL_OR(act_code = 'callback_promised')  AS callback,
         BOOL_OR(act_code IN ('explained','changed','reissued','redirected_web')) AS handled
  FROM a WHERE speaker = 'agent' GROUP BY run_id, call_id, issue_idx
)
SELECT i.run_id, i.call_id, i.issue_idx,
       COALESCE(t.value_code, 'unknown')  AS trigger_code,
       t.object_code                       AS trigger_object_code,
       COALESCE(mo.value_code, 'unknown') AS motive_code,
       cf.confusion_type,
       cf.confusion_object_code,
       CASE WHEN cf.confusion_type = 'none' THEN NULL
            WHEN EXISTS (SELECT 1 FROM a x WHERE x.run_id = i.run_id AND x.call_id = i.call_id AND x.issue_idx = i.issue_idx
                           AND x.speaker = 'customer' AND x.act_code = 'accept' AND (x.turn_idx, x.act_idx) > (cf.conf_turn, cf.conf_act)) THEN TRUE
            WHEN EXISTS (SELECT 1 FROM a x WHERE x.run_id = i.run_id AND x.call_id = i.call_id AND x.issue_idx = i.issue_idx
                           AND x.speaker = 'customer' AND x.act_code = 'reject' AND (x.turn_idx, x.act_idx) > (cf.conf_turn, cf.conf_act)) THEN FALSE
            ELSE NULL END                   AS confusion_resolved,
       CASE la.act_code WHEN 'accept' THEN TRUE WHEN 'reject' THEN FALSE ELSE NULL END AS customer_accepted,
       CASE WHEN COALESCE(g.escalated, FALSE) THEN 'escalated'
            WHEN COALESCE(g.callback, FALSE)  THEN 'callback_promised'
            WHEN COALESCE(g.handled, FALSE) AND COALESCE(la.act_code, '') <> 'reject' THEN 'resolved'
            WHEN COALESCE(la.act_code, '') = 'reject' OR NOT COALESCE(g.handled, FALSE) THEN 'unresolved'
            ELSE 'unknown' END              AS outcome_code,
       EXISTS (SELECT 1 FROM a x WHERE x.run_id = i.run_id AND x.call_id = i.call_id AND x.issue_idx = i.issue_idx
                 AND x.speaker = 'customer' AND x.act_code = 'mention_prior_contact') AS repeat_contact_signal,
       r.act_code                          AS action_code,
       r.object_code                       AS object_code,
       r.aspect_code                       AS aspect_code
FROM issues i
LEFT JOIN req r      ON r.run_id = i.run_id AND r.call_id = i.call_id AND r.issue_idx = i.issue_idx AND r.rn = 1
LEFT JOIN trg t      ON t.run_id = i.run_id AND t.call_id = i.call_id AND t.issue_idx = i.issue_idx AND t.rn = 1
LEFT JOIN mot mo     ON mo.run_id = i.run_id AND mo.call_id = i.call_id AND mo.issue_idx = i.issue_idx AND mo.rn = 1
LEFT JOIN conf cf    ON cf.run_id = i.run_id AND cf.call_id = i.call_id AND cf.issue_idx = i.issue_idx
LEFT JOIN lastacc la ON la.run_id = i.run_id AND la.call_id = i.call_id AND la.issue_idx = i.issue_idx AND la.rn = 1
LEFT JOIN ag g       ON g.run_id = i.run_id AND g.call_id = i.call_id AND g.issue_idx = i.issue_idx;

-- 横断フラグの導出(turn_flags と同じ形。turn_flags 表は v0.4 では §5 でここから具体化する)
CREATE VIEW v_turn_flags_derived AS
SELECT run_id, call_id, turn_idx,
       CASE
         WHEN speaker = 'customer' AND act_code = 'state_intent' AND value_code IN ('churn','switch_competitor') THEN 'churn_intent'
         WHEN speaker = 'customer' AND act_code = 'abuse'                                         THEN 'harassment'
         WHEN speaker = 'agent'    AND act_code = 'asserted_guarantee'                            THEN 'compliance_risk'
         WHEN speaker = 'customer' AND act_code = 'request_escalation'                            THEN 'escalation_requested'
         WHEN speaker = 'customer' AND act_code = 'express_emotion' AND value_code = 'gratitude'  THEN 'praise'
         WHEN speaker = 'customer' AND act_code = 'state_constraint'                              THEN 'accessibility_need'
         WHEN speaker = 'customer' AND act_code = 'state_unaware'                                 THEN 'unaware_of_self_service'
       END AS flag_code,
       begin_char, end_char, quote, verified
FROM acts
WHERE (speaker = 'customer' AND act_code IN ('abuse','request_escalation','state_constraint','state_unaware'))
   OR (speaker = 'customer' AND act_code = 'state_intent' AND value_code IN ('churn','switch_competitor'))
   OR (speaker = 'customer' AND act_code = 'express_emotion' AND value_code = 'gratitude')
   OR (speaker = 'agent'    AND act_code = 'asserted_guarantee');

-- 感情の導出: 表出のみから。開始側 = 最初の 25% のターン、終了側 = 最後の 25% のターン。
-- 否定的な表出があれば negative、なければ肯定的な表出があれば positive、なければ neutral。口調からの推定はしない。
CREATE VIEW v_call_emotion_derived AS
WITH n AS (
  SELECT call_id, COUNT(*) AS total FROM turns GROUP BY call_id
),
e AS (
  SELECT a.run_id, a.call_id, a.turn_idx,
         CASE WHEN a.value_code IN ('anger','dissatisfaction','anxiety','confusion') THEN 'negative'
              WHEN a.value_code IN ('gratitude','relief') THEN 'positive' ELSE 'neutral' END AS pol,
         a.turn_idx < n.total * 0.25  AS at_start,
         a.turn_idx >= n.total * 0.75 AS at_end
  FROM acts a JOIN n ON n.call_id = a.call_id
  WHERE a.speaker = 'customer' AND a.act_code = 'express_emotion'
)
SELECT ca.run_id, ca.call_id,
       COALESCE((SELECT CASE WHEN BOOL_OR(pol = 'negative') THEN 'negative' WHEN BOOL_OR(pol = 'positive') THEN 'positive' ELSE 'neutral' END
                 FROM e WHERE e.run_id = ca.run_id AND e.call_id = ca.call_id AND e.at_start), 'neutral') AS emotion_start,
       COALESCE((SELECT CASE WHEN BOOL_OR(pol = 'negative') THEN 'negative' WHEN BOOL_OR(pol = 'positive') THEN 'positive' ELSE 'neutral' END
                 FROM e WHERE e.run_id = ca.run_id AND e.call_id = ca.call_id AND e.at_end), 'neutral')   AS emotion_end
FROM current_annotation ca;

-- 保留・転送の注釈(テレフォニー情報がない場合)。オペレータの hold / transfer 行為から。時間はターン時刻から近似
CREATE VIEW v_event_annotations AS
SELECT a.run_id, a.call_id, a.turn_idx,
       CASE a.act_code WHEN 'hold' THEN 'hold' WHEN 'transfer' THEN 'transfer' END AS event_type,
       t.end_ms AS start_ms,
       (SELECT MIN(t2.start_ms) FROM turns t2 WHERE t2.call_id = a.call_id AND t2.turn_idx > a.turn_idx) AS end_ms,
       a.quote
FROM acts a JOIN turns t ON t.call_id = a.call_id AND t.turn_idx = a.turn_idx
WHERE a.speaker = 'agent' AND a.act_code IN ('hold','transfer');

------------------------------------------------------------
-- 4. 不変条件(新規。既存 I1〜I9 は変更しない)
------------------------------------------------------------
-- I10: 発話行為の引用は本文と逐語一致している
CREATE VIEW chk_acts_unverified AS
SELECT a.* FROM acts a
JOIN current_annotation ca ON ca.call_id = a.call_id AND ca.run_id = a.run_id
WHERE a.verified IS DISTINCT FROM TRUE;

-- I11: 発話行為の話者はターンの話者と一致し、act_code はその話者に許された値である(codes.definition の先頭に 'customer:' / 'agent:' を置く規約)
CREATE VIEW chk_acts_speaker AS
SELECT a.run_id, a.call_id, a.act_idx, a.speaker, t.speaker AS turn_speaker, a.act_code
FROM acts a
JOIN turns t ON t.call_id = a.call_id AND t.turn_idx = a.turn_idx
LEFT JOIN codes k ON k.code_set = 'act' AND k.code = a.act_code AND k.status <> 'retired'
WHERE a.speaker <> t.speaker
   OR k.code IS NULL
   OR NOT (k.definition LIKE a.speaker || ':%' OR k.definition LIKE 'both:%');

-- I12: 発話行為の value_code は行為ごとの code_set に存在する
CREATE VIEW chk_acts_value AS
SELECT a.run_id, a.call_id, a.act_idx, a.act_code, a.value_code
FROM acts a
WHERE a.value_code IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM codes k WHERE k.status <> 'retired' AND k.code = a.value_code AND k.code_set =
    CASE a.act_code WHEN 'state_reason' THEN 'motive' WHEN 'state_trigger' THEN 'trigger' WHEN 'assert_belief' THEN 'claim'
                    WHEN 'express_emotion' THEN 'emotion_kind' WHEN 'state_intent' THEN 'intent' ELSE '(none)' END);

-- I13: v0.4 の run では、issues の判断列は仮値のままである(LLM の判断や手書きが混入していないこと)
CREATE VIEW chk_issue_placeholders AS
SELECT i.run_id, i.call_id, i.issue_idx, i.trigger_code, i.outcome_code, i.confusion_type, i.motive_code
FROM issues i
JOIN annotation_runs r ON r.run_id = i.run_id AND r.schema_version >= '0.4'
WHERE i.trigger_code <> 'unknown' OR i.outcome_code <> 'unknown' OR i.confusion_type <> 'none'
   OR i.repeat_contact_signal OR i.motive_code IS NOT NULL OR i.confusion_resolved IS NOT NULL OR i.customer_accepted IS NOT NULL
   OR i.trigger_object_code IS NOT NULL OR i.confusion_object_code IS NOT NULL;

------------------------------------------------------------
-- 5. 分析用ビューの置き換え(列名・列数は v0.3.1 と同じ。v0.4 の run では判断列を導出ビューから返す)
------------------------------------------------------------
ALTER TABLE issues ADD COLUMN aspect_code VARCHAR;      -- codes(code_set='aspect')。v0.4 run では NULL のまま(導出で返す)

CREATE OR REPLACE VIEW v_issues AS
SELECT i.run_id, i.call_id, i.issue_idx, i.is_primary, i.score,
       CASE WHEN v4 THEN COALESCE(d.action_code, i.action_code) ELSE i.action_code END AS action_code,
       CASE WHEN v4 THEN COALESCE(d.object_code, i.object_code) ELSE i.object_code END AS object_code,
       CASE WHEN v4 THEN d.trigger_code          ELSE i.trigger_code          END AS trigger_code,
       CASE WHEN v4 THEN d.trigger_object_code   ELSE i.trigger_object_code   END AS trigger_object_code,
       CASE WHEN v4 THEN d.outcome_code          ELSE i.outcome_code          END AS outcome_code,
       CASE WHEN v4 THEN d.repeat_contact_signal ELSE i.repeat_contact_signal END AS repeat_contact_signal,
       CASE WHEN v4 THEN d.confusion_type        ELSE i.confusion_type        END AS confusion_type,
       CASE WHEN v4 THEN d.confusion_object_code ELSE i.confusion_object_code END AS confusion_object_code,
       i.summary_ja, i.other_text,
       CASE WHEN v4 THEN d.motive_code           ELSE i.motive_code           END AS motive_code,
       CASE WHEN v4 THEN d.confusion_resolved    ELSE i.confusion_resolved    END AS confusion_resolved,
       CASE WHEN v4 THEN d.customer_accepted     ELSE i.customer_accepted     END AS customer_accepted,
       CASE WHEN v4 THEN d.aspect_code           ELSE i.aspect_code           END AS aspect_code,
       c.started_at, c.channel, c.customer_id, c.agent_id,
       o.object_kind, o.parent_object,
       (SELECT COUNT(*) FROM issue_turns t
         WHERE t.run_id = i.run_id AND t.call_id = i.call_id AND t.issue_idx = i.issue_idx) AS n_turns,
       (SELECT COUNT(*) FROM issue_turns t JOIN turn_phases p
           ON p.run_id = t.run_id AND p.call_id = t.call_id AND p.turn_idx = t.turn_idx
         WHERE t.run_id = i.run_id AND t.call_id = i.call_id AND t.issue_idx = i.issue_idx
           AND p.phase = 'discussion') AS n_discussion_turns
FROM issues i
JOIN current_annotation ca ON ca.call_id = i.call_id AND ca.run_id = i.run_id
JOIN annotation_runs r ON r.run_id = i.run_id
CROSS JOIN LATERAL (SELECT r.schema_version >= '0.4' AS v4) f
LEFT JOIN v_issue_derived d ON d.run_id = i.run_id AND d.call_id = i.call_id AND d.issue_idx = i.issue_idx
JOIN calls c ON c.call_id = i.call_id
JOIN objects o ON o.object_code = CASE WHEN v4 THEN COALESCE(d.object_code, i.object_code) ELSE i.object_code END;

CREATE OR REPLACE VIEW v_calls AS
SELECT c.call_id, c.started_at, c.channel, c.customer_id, c.agent_id, c.duration_sec,
       ca.run_id,
       (SELECT COUNT(*) FROM issues i WHERE i.run_id = ca.run_id AND i.call_id = c.call_id) AS n_issues,
       (SELECT vi.action_code FROM v_issues vi WHERE vi.run_id = ca.run_id AND vi.call_id = c.call_id AND vi.is_primary LIMIT 1) AS primary_action,
       (SELECT vi.object_code FROM v_issues vi WHERE vi.run_id = ca.run_id AND vi.call_id = c.call_id AND vi.is_primary LIMIT 1) AS primary_object,
       (SELECT BOOL_AND(vi.outcome_code = 'resolved') FROM v_issues vi WHERE vi.run_id = ca.run_id AND vi.call_id = c.call_id) AS all_resolved,
       (SELECT COUNT(*) FROM turn_phases p WHERE p.run_id = ca.run_id AND p.call_id = c.call_id AND p.phase = 'verification') AS verification_turns,
       (SELECT COUNT(*) FROM turn_phases p WHERE p.run_id = ca.run_id AND p.call_id = c.call_id) AS total_turns,
       EXISTS (SELECT 1 FROM v_issues vi WHERE vi.call_id = c.call_id AND vi.n_discussion_turns = 0) AS has_unaddressed_issue,
       CASE WHEN r.schema_version >= '0.4' THEN e.emotion_start ELSE an.emotion_start END AS emotion_start,
       CASE WHEN r.schema_version >= '0.4' THEN e.emotion_end   ELSE an.emotion_end   END AS emotion_end
FROM calls c
JOIN current_annotation ca ON ca.call_id = c.call_id
JOIN annotation_runs r ON r.run_id = ca.run_id
LEFT JOIN call_annotations an ON an.run_id = ca.run_id AND an.call_id = c.call_id
LEFT JOIN v_call_emotion_derived e ON e.run_id = ca.run_id AND e.call_id = c.call_id;

-- 横断フラグ: v0.4 run は導出、それ以前は turn_flags 表
CREATE OR REPLACE VIEW v_turn_flags AS
SELECT f.run_id, f.call_id, f.turn_idx, f.flag_code, f.begin_char, f.end_char, f.quote, f.verified,
       t.speaker, c.started_at, c.channel, c.agent_id AS call_agent_id
FROM (
  SELECT tf.* FROM turn_flags tf JOIN annotation_runs r ON r.run_id = tf.run_id AND r.schema_version < '0.4'
  UNION ALL
  SELECT d.run_id, d.call_id, d.turn_idx, d.flag_code, d.begin_char, d.end_char, d.quote, d.verified
  FROM v_turn_flags_derived d JOIN annotation_runs r ON r.run_id = d.run_id AND r.schema_version >= '0.4'
  WHERE d.flag_code IS NOT NULL
) f
JOIN current_annotation ca ON ca.call_id = f.call_id AND ca.run_id = f.run_id
JOIN turns t ON t.call_id = f.call_id AND t.turn_idx = f.turn_idx
JOIN calls c ON c.call_id = f.call_id;

CREATE OR REPLACE VIEW v_call_flags AS
SELECT c.call_id,
       COALESCE(BOOL_OR(f.flag_code = 'churn_intent'), FALSE)          AS has_churn_intent,
       COALESCE(BOOL_OR(f.flag_code = 'harassment'), FALSE)            AS has_harassment,
       COALESCE(BOOL_OR(f.flag_code = 'compliance_risk'), FALSE)       AS has_compliance_risk,
       COALESCE(BOOL_OR(f.flag_code = 'escalation_requested'), FALSE)  AS has_escalation_request,
       COALESCE(BOOL_OR(f.flag_code = 'praise'), FALSE)                AS has_praise,
       COALESCE(BOOL_OR(f.flag_code = 'accessibility_need'), FALSE)    AS has_accessibility_need,
       COUNT(f.flag_code)                                              AS n_flags
FROM calls c
JOIN current_annotation ca ON ca.call_id = c.call_id
LEFT JOIN v_turn_flags f ON f.run_id = ca.run_id AND f.call_id = c.call_id
GROUP BY c.call_id;

-- オペレータ行動: v0.4 run は acts から
CREATE OR REPLACE VIEW v_agent_actions AS
SELECT a.run_id, a.call_id, a.issue_idx, a.action_code, a.turn_idx, a.begin_char, a.end_char, a.quote, a.verified,
       vi.action_code AS issue_action_code, vi.object_code, vi.outcome_code, c.started_at
FROM (
  SELECT aa.run_id, aa.call_id, aa.issue_idx, aa.action_code, aa.turn_idx, aa.begin_char, aa.end_char, aa.quote, aa.verified
  FROM agent_actions aa JOIN annotation_runs r ON r.run_id = aa.run_id AND r.schema_version < '0.4'
  UNION ALL
  SELECT x.run_id, x.call_id, x.issue_idx, x.act_code, x.turn_idx, x.begin_char, x.end_char, x.quote, x.verified
  FROM acts x JOIN annotation_runs r ON r.run_id = x.run_id AND r.schema_version >= '0.4'
  WHERE x.speaker = 'agent' AND x.issue_idx IS NOT NULL
    AND x.act_code IN ('explained','reissued','changed','escalated','callback_promised','declined','redirected_web','retention_offer')
) a
JOIN current_annotation ca ON ca.call_id = a.call_id AND ca.run_id = a.run_id
JOIN v_issues vi ON vi.run_id = a.run_id AND vi.call_id = a.call_id AND vi.issue_idx = a.issue_idx
JOIN calls c ON c.call_id = a.call_id;

-- evidence.field に 'aspect' を追加(I9 のビューを置き換え)
CREATE OR REPLACE VIEW chk_evidence_field AS
SELECT e.run_id, e.call_id, e.issue_idx, e.field
FROM evidence e
WHERE e.field NOT IN ('action','trigger','outcome','confusion','repeat_contact','motive','primary','aspect');

------------------------------------------------------------
-- 6. 初期語彙(vocab_version '0.4'。任意)
------------------------------------------------------------
INSERT INTO vocab_versions VALUES ('0.4', CURRENT_TIMESTAMP, 'v0.4: act / aspect / claim / emotion_kind / intent を追加。turn_flag に unaware_of_self_service、trigger に agent_referral、motive に digital_barrier、agent_action に retention_offer、object_kind に competitor');

-- 発話行為。definition の先頭に許される話者を置く('customer:' / 'agent:' / 'both:')。I11 が参照する
INSERT INTO codes (code_set, code, parent_code, label_ja, definition, status, valid_from, valid_to) VALUES
  -- 顧客: 依頼系(issue_action と同じ値。用件の主たる行為になる)
  ('act','inquire',              NULL,'照会する',      'customer: 内容・可否・理由を尋ねる',                          'stable','0.4',NULL),
  ('act','request_change',       NULL,'変更を依頼する','customer: 契約・登録内容の変更を求める',                      'stable','0.4',NULL),
  ('act','apply',                NULL,'申し込む',      'customer: 新規加入・特約追加・証明書発行を申し込む',           'stable','0.4',NULL),
  ('act','cancel',               NULL,'解約する',      'customer: 解約・更新しない意思を伝える',                       'stable','0.4',NULL),
  ('act','report_problem',       NULL,'不具合を報告する','customer: 届かない・使えない・誤っている等を報告する',       'stable','0.4',NULL),
  ('act','complain',             NULL,'苦情を言う',    'customer: 対応・商品・書面への不満を述べる',                   'stable','0.4',NULL),
  ('act','confirm',              NULL,'確認する',      'customer: 既に知っている内容が正しいか確かめる',               'stable','0.4',NULL),
  ('act','suggest',              NULL,'提案する',      'customer: 改善の提案・要望を述べる',                           'provisional','0.4',NULL),
  -- 顧客: 明言される事実(判断列の材料)
  ('act','state_trigger',        NULL,'経緯を述べる',  'customer: なぜ今電話したかを述べる。value=trigger',            'stable','0.4',NULL),
  ('act','state_reason',         NULL,'理由を述べる',  'customer: 依頼の理由・動機を述べる。value=motive',             'stable','0.4',NULL),
  ('act','assert_belief',        NULL,'主張する',      'customer: 事実についての認識を述べる(正誤は問わない)。value=claim','stable','0.4',NULL),
  ('act','express_difficulty',   NULL,'理解困難を表明する','customer: 分かりにくい・分からないと明言する',             'stable','0.4',NULL),
  ('act','express_emotion',      NULL,'感情を表出する','customer: 怒り・不満・不安・困惑・感謝・安堵を言葉にする。value=emotion_kind','stable','0.4',NULL),
  ('act','state_intent',         NULL,'意向を表明する','customer: 解約・乗換え等の意向を明言する。value=intent',       'stable','0.4',NULL),
  ('act','accept',               NULL,'了承する',      'customer: 説明・対応を受け入れる',                             'stable','0.4',NULL),
  ('act','reject',               NULL,'不服を述べる',  'customer: 説明・対応に納得しない',                             'stable','0.4',NULL),
  ('act','mention_prior_contact',NULL,'以前の連絡に言及する','customer: 前にも電話した・問い合わせたと述べる',         'stable','0.4',NULL),
  ('act','mention_prior_notice', NULL,'案内済みに言及する','customer: 既に案内された・書面に書いてあったと述べる',      'stable','0.4',NULL),
  ('act','request_escalation',   NULL,'上席を求める',  'customer: 上席・責任者を出すよう求める',                       'stable','0.4',NULL),
  ('act','abuse',                NULL,'暴言・脅迫',    'customer: 脅迫、暴言、人格攻撃',                               'stable','0.4',NULL),
  ('act','state_constraint',     NULL,'制約を述べる',  'customer: 視力・聴力・言語・年齢等の利用上の制約を述べる',     'provisional','0.4',NULL),
  ('act','state_unaware',        NULL,'知らなかったと述べる','customer: Web で手続きできること等を知らなかったと述べる','provisional','0.4',NULL),
  ('act','state_quantity',       NULL,'数量を述べる',  'customer: 金額・回数・期間を述べる。value_text/value_num',    'provisional','0.4',NULL),
  -- オペレータ
  ('act','explained',            NULL,'説明した',      'agent: 仕組み・理由・手順を説明した',                          'stable','0.4',NULL),
  ('act','corrected',            NULL,'訂正した',      'agent: 顧客の誤った認識を訂正した',                            'stable','0.4',NULL),
  ('act','reissued',             NULL,'再発行した',    'agent: 書面・ID 等を再発行・再送した',                         'stable','0.4',NULL),
  ('act','changed',              NULL,'変更した',      'agent: 契約・登録内容を変更した',                              'stable','0.4',NULL),
  ('act','escalated',            NULL,'上席に上げた',  'agent: 上席・専門部署に引き継いだ',                            'stable','0.4',NULL),
  ('act','callback_promised',    NULL,'折返しを約束した','agent: 後日連絡すると約束した',                              'stable','0.4',NULL),
  ('act','declined',             NULL,'断った',        'agent: 顧客の要求に応じなかった',                              'stable','0.4',NULL),
  ('act','redirected_web',       NULL,'Web を案内した','agent: Web・アプリ・書面での手続きに誘導した',                 'stable','0.4',NULL),
  ('act','retention_offer',      NULL,'引き止めを提案した','agent: 解約申出に対し代替案・割引等を提案した',            'provisional','0.4',NULL),
  ('act','asserted_guarantee',   NULL,'断定的に保証した','agent: 「必ず」「絶対に」等の断定的な保証を述べた',          'provisional','0.4',NULL),
  ('act','apologized',           NULL,'謝罪した',      'agent: 謝罪した',                                              'stable','0.4',NULL),
  ('act','hold',                 NULL,'保留した',      'agent: 保留に入ることを告げた',                                'stable','0.4',NULL),
  ('act','transfer',             NULL,'転送した',      'agent: 他部署・担当に転送することを告げた',                    'stable','0.4',NULL),
  ('act','verify_identity',      NULL,'本人確認した',  'agent: 氏名・証券番号等の確認を求めた',                        'stable','0.4',NULL),
  ('act','other',                NULL,'その他',        'both: いずれにも当たらない',                                    'stable','0.4',NULL);

-- 側面(S8)
INSERT INTO codes (code_set, code, parent_code, label_ja, definition, status, valid_from, valid_to) VALUES
  ('aspect','timing',      NULL,'時期',      '届く時期、反映時期、引落し日',              'provisional','0.4',NULL),
  ('aspect','amount',      NULL,'金額',      '保険料・割引額・免責の金額',                'provisional','0.4',NULL),
  ('aspect','content',     NULL,'記載内容',  '書面・画面に書かれている内容の意味',        'provisional','0.4',NULL),
  ('aspect','delivery',    NULL,'届き方',    '郵送・メール・Web の到達、不着、重複',       'provisional','0.4',NULL),
  ('aspect','scope',       NULL,'適用範囲',  '誰が・何が対象か(運転者、車両、事故の種類)','provisional','0.4',NULL),
  ('aspect','procedure',   NULL,'手続き・操作','手順、必要書類、画面操作',               'provisional','0.4',NULL),
  ('aspect','readability', NULL,'見やすさ',  '文字の大きさ、レイアウト、用語の難しさ',    'provisional','0.4',NULL),
  ('aspect','other',       NULL,'その他',    '',                                          'stable','0.4',NULL);

-- 感情の表出の種類、意向、主張(既知の誤解は known_misconceptions にも登録)
INSERT INTO codes (code_set, code, parent_code, label_ja, definition, status, valid_from, valid_to) VALUES
  ('emotion_kind','anger',          NULL,'怒り',   '',              'stable','0.4',NULL),
  ('emotion_kind','dissatisfaction',NULL,'不満',   '',              'stable','0.4',NULL),
  ('emotion_kind','anxiety',        NULL,'不安',   '',              'stable','0.4',NULL),
  ('emotion_kind','confusion',      NULL,'困惑',   '',              'stable','0.4',NULL),
  ('emotion_kind','gratitude',      NULL,'感謝',   '',              'stable','0.4',NULL),
  ('emotion_kind','relief',         NULL,'安堵',   '',              'stable','0.4',NULL),
  ('intent','churn',                NULL,'解約意向','',             'stable','0.4',NULL),
  ('intent','switch_competitor',    NULL,'他社乗換え意向','',       'stable','0.4',NULL),
  ('intent','continue',             NULL,'継続意向','',             'stable','0.4',NULL),
  ('claim','grade_up_premium_down', NULL,'等級が上がれば保険料は必ず下がる', '',   'provisional','0.4',NULL),
  ('claim','no_accident_no_increase',NULL,'無事故なら保険料は上がらない',     '',   'provisional','0.4',NULL),
  ('claim','gold_immediate',        NULL,'ゴールド免許は即座に割引に反映される','', 'provisional','0.4',NULL),
  ('claim','tax_deductible',        NULL,'自動車保険料は所得控除の対象',       '',   'provisional','0.4',NULL),
  ('claim','family_incl_separated_child',NULL,'別居の子も家族限定に含まれる','',    'provisional','0.4',NULL),
  ('claim','no_cert_means_uninsured',NULL,'証券が届かないのは契約されていない','',  'provisional','0.4',NULL),
  ('claim','double_charge',         NULL,'二重に請求されている',              '',   'provisional','0.4',NULL),
  ('claim','age_cond_named_only',   NULL,'年齢条件は記名被保険者だけに掛かる','',  'provisional','0.4',NULL),
  ('claim','other',                 NULL,'その他の主張',                      '',   'stable','0.4',NULL);

INSERT INTO known_misconceptions (claim_code, object_code, aspect_code, label_ja, correct_fact_ja, valid_from, valid_to) VALUES
  ('grade_up_premium_down',      NULL, 'amount', '等級が上がれば保険料は必ず下がる', '料率改定・年齢区分・車両料率クラスの変更で上がることがある', '0.4', NULL),
  ('no_accident_no_increase',    NULL, 'amount', '無事故なら保険料は上がらない',     '同上', '0.4', NULL),
  ('gold_immediate',             NULL, 'timing', 'ゴールド免許は即座に反映される',   '更新時の免許色で判定するため次回更新から', '0.4', NULL),
  ('tax_deductible',             NULL, 'scope',  '自動車保険料は所得控除の対象',     '生命保険料控除・地震保険料控除の対象外', '0.4', NULL),
  ('family_incl_separated_child',NULL, 'scope',  '別居の子も家族限定に含まれる',     '別居の未婚の子は含まれるが、既婚の子・別居の親族は含まれない(約款による)', '0.4', NULL),
  ('no_cert_means_uninsured',    NULL, 'delivery','証券が届かないのは未契約',        'Web 証券に移行した契約は紙の証券を発行しない', '0.4', NULL),
  ('double_charge',              NULL, 'amount', '二重に請求されている',             '日割り・月割りの内訳であり二重ではない', '0.4', NULL),
  ('age_cond_named_only',        NULL, 'scope',  '年齢条件は記名被保険者だけに掛かる','年齢条件は補償対象の運転者全員に掛かる', '0.4', NULL);

-- 目録で起票した選択肢(12 §3.2 V1〜V6)
INSERT INTO codes (code_set, code, parent_code, label_ja, definition, status, valid_from, valid_to) VALUES
  ('object_kind','competitor',   NULL,'競合他社','',                                     'provisional','0.4',NULL),
  ('turn_flag','unaware_of_self_service',NULL,'Web 手続きの不認知','Web で手続きできることを知らなかった','provisional','0.4',NULL),
  ('trigger','agent_referral',   NULL,'代理店経由','代理店・販売店に言われて',            'provisional','0.4',NULL),
  ('motive','digital_barrier',   NULL,'Web が使えない・不安','',                        'provisional','0.4',NULL),
  ('agent_action','retention_offer',NULL,'引き止め提案','',                             'provisional','0.4',NULL);
INSERT INTO objects (object_code, object_kind, parent_object, label_ja, external_ref, status, valid_from, valid_to) VALUES
  ('COMPETITOR_UNSPECIFIED','competitor',NULL,'他社(不特定)',NULL,'provisional','0.4',NULL);

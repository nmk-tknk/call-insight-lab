-- call-insight-lab  論理スキーマ v0.3.1(v0_3.sql に対する追加のみの差分)
-- 適用順: v0_3.sql → v0_3_1.sql。既存の表・列・ビュー・不変条件は変更しない。
-- 根拠: docs/study/08_information_loss_inventory.md §8
--
-- 追加の分類
--   §1 ソース層: 取込時にしか得られない情報(後から戻らない)
--   §2 注釈層:   再注釈で埋められる情報(新しい annotation_run で埋め直す)
--   §3 導出ビュー(新規のみ)
--   §4 不変条件(新規のみ。既存 I1〜I5 はそのまま)
--   §5 初期語彙(vocab_version '0.3.1')。運用では語彙管理側から投入するため任意

------------------------------------------------------------
-- 1. ソース層(取込時に保存。08 §2)
------------------------------------------------------------
-- S10 着信経路
ALTER TABLE calls ADD COLUMN direction        VARCHAR;   -- codes(code_set='direction'): inbound/outbound/unknown
ALTER TABLE calls ADD COLUMN queue            VARCHAR;   -- 着信キュー(テレフォニー側の ID。語彙化しない)
ALTER TABLE calls ADD COLUMN ivr_path         VARCHAR;   -- IVR 選択列。例 '2>1>3'。語彙化しない
ALTER TABLE calls ADD COLUMN wait_sec         INTEGER;   -- 応答までの待ち秒数
-- S15 終了理由
ALTER TABLE calls ADD COLUMN end_reason       VARCHAR;   -- codes(code_set='end_reason'): customer_hangup/agent_end/dropped/transferred/unknown
-- S11 CRM 突合
ALTER TABLE calls ADD COLUMN external_case_id VARCHAR;   -- CRM ケース ID
ALTER TABLE calls ADD COLUMN disposition_code VARCHAR;   -- オペレータが CRM に入れた後処理コード(既存分類。語彙化しない)
-- S13 音声(任意)
ALTER TABLE calls ADD COLUMN audio_uri        VARCHAR;

-- S6 ASR 信頼度(ターン単位)
ALTER TABLE turns ADD COLUMN asr_confidence       DOUBLE;    -- ターン平均
ALTER TABLE turns ADD COLUMN asr_word_confidence  VARCHAR;   -- 任意。単語別信頼度の JSON 文字列。集計には使わない

-- S9 転送後の担当
ALTER TABLE events ADD COLUMN agent_id VARCHAR;              -- transfer 以降に応対したオペレータ

-- S12 顧客属性の時点スナップショット。CRM 側に時点履歴があれば作らず customer_id で結合する
CREATE TABLE call_customer_snapshot (
  call_id         VARCHAR PRIMARY KEY REFERENCES calls(call_id),
  snapshot_at     TIMESTAMP NOT NULL,
  plan_code       VARCHAR,                       -- objects(object_kind='product') に合わせる
  tenure_months   INTEGER,
  age_band        VARCHAR,                       -- 粗い区分のみ('20s','30s',...)。個人を特定する粒度は持たない
  segment_code    VARCHAR                        -- CRM 側のセグメント ID
);

------------------------------------------------------------
-- 2. 注釈層(再注釈で埋める。08 §3.1, §3.3)
------------------------------------------------------------
-- C4 動機、C10 混乱の解消、C7 結果の質
ALTER TABLE issues ADD COLUMN motive_code        VARCHAR;   -- codes(code_set='motive'): price/competitor/no_need/quality/service_dissatisfaction/unknown/other
ALTER TABLE issues ADD COLUMN confusion_resolved BOOLEAN;   -- confusion_type <> 'none' のときのみ非 NULL(I7)
ALTER TABLE issues ADD COLUMN customer_accepted  BOOLEAN;   -- 結果を顧客が受け入れたか(outcome とは独立)

-- M2 列ごとの確信度(任意)
ALTER TABLE evidence ADD COLUMN confidence DOUBLE;
-- evidence.field の語彙に 'motive'(C4)と 'primary'(M7: 主用件の根拠は目的発話の引用)を追加。検査は I9

-- C6, C17 オペレータが取った・約束した行動。根拠は自表に持つ(evidence の主キーを変えないため)
CREATE TABLE agent_actions (
  run_id          VARCHAR NOT NULL REFERENCES annotation_runs(run_id),
  call_id         VARCHAR NOT NULL,
  issue_idx       INTEGER NOT NULL,
  action_code     VARCHAR NOT NULL,              -- codes(code_set='agent_action'): explained/reissued/changed/escalated/callback_promised/declined/redirected_web/other
  turn_idx        INTEGER,                       -- 根拠(任意。「はい」だけの了承など引用が意味をなさない場合は NULL)
  begin_char      INTEGER,
  end_char        INTEGER,
  quote           VARCHAR,
  verified        BOOLEAN,
  PRIMARY KEY (run_id, call_id, issue_idx, action_code),
  FOREIGN KEY (run_id, call_id, issue_idx) REFERENCES issues(run_id, call_id, issue_idx),
  FOREIGN KEY (call_id, turn_idx) REFERENCES turns(call_id, turn_idx)
);

-- X1〜X6 用件に帰属しない横断フラグ。ターン単位。根拠は自表に持つ
CREATE TABLE turn_flags (
  run_id          VARCHAR NOT NULL REFERENCES annotation_runs(run_id),
  call_id         VARCHAR NOT NULL,
  turn_idx        INTEGER NOT NULL,
  flag_code       VARCHAR NOT NULL,              -- codes(code_set='turn_flag'): churn_intent/harassment/compliance_risk/escalation_requested/praise/accessibility_need/other
  begin_char      INTEGER NOT NULL,
  end_char        INTEGER NOT NULL,
  quote           VARCHAR NOT NULL,
  verified        BOOLEAN,                       -- turns.text[begin:end] = quote
  PRIMARY KEY (run_id, call_id, turn_idx, flag_code),
  FOREIGN KEY (call_id, turn_idx) REFERENCES turns(call_id, turn_idx)
);

------------------------------------------------------------
-- 3. 導出ビュー(新規。v_issues は SELECT i.* のため新列を自動的に含む)
------------------------------------------------------------
CREATE VIEW v_turn_flags AS
SELECT f.*, t.speaker, c.started_at, c.channel, c.agent_id AS call_agent_id
FROM turn_flags f
JOIN current_annotation ca ON ca.call_id = f.call_id AND ca.run_id = f.run_id
JOIN turns t ON t.call_id = f.call_id AND t.turn_idx = f.turn_idx
JOIN calls c ON c.call_id = f.call_id;

CREATE VIEW v_agent_actions AS
SELECT a.*, i.action_code AS issue_action_code, i.object_code, i.outcome_code, c.started_at
FROM agent_actions a
JOIN current_annotation ca ON ca.call_id = a.call_id AND ca.run_id = a.run_id
JOIN issues i ON i.run_id = a.run_id AND i.call_id = a.call_id AND i.issue_idx = a.issue_idx
JOIN calls c ON c.call_id = a.call_id;

-- 通話単位の横断フラグ有無。v_calls は変えず、call_id で結合して使う
CREATE VIEW v_call_flags AS
SELECT c.call_id,
       BOOL_OR(f.flag_code = 'churn_intent')          AS has_churn_intent,
       BOOL_OR(f.flag_code = 'harassment')            AS has_harassment,
       BOOL_OR(f.flag_code = 'compliance_risk')       AS has_compliance_risk,
       BOOL_OR(f.flag_code = 'escalation_requested')  AS has_escalation_request,
       BOOL_OR(f.flag_code = 'praise')                AS has_praise,
       BOOL_OR(f.flag_code = 'accessibility_need')    AS has_accessibility_need,
       COUNT(f.flag_code)                             AS n_flags
FROM calls c
JOIN current_annotation ca ON ca.call_id = c.call_id
LEFT JOIN turn_flags f ON f.run_id = ca.run_id AND f.call_id = c.call_id
GROUP BY c.call_id;

------------------------------------------------------------
-- 4. 不変条件(新規。既存 I1〜I5 は変更しない)
------------------------------------------------------------
-- I6: turn_flags / agent_actions の引用は本文と逐語一致している(I4 と同型)
CREATE VIEW chk_flag_evidence_unverified AS
SELECT 'turn_flags' AS src, f.run_id, f.call_id, f.turn_idx, f.begin_char, f.quote, f.verified
FROM turn_flags f
JOIN current_annotation ca ON ca.call_id = f.call_id AND ca.run_id = f.run_id
WHERE f.verified IS DISTINCT FROM TRUE
UNION ALL
SELECT 'agent_actions', a.run_id, a.call_id, a.turn_idx, a.begin_char, a.quote, a.verified
FROM agent_actions a
JOIN current_annotation ca ON ca.call_id = a.call_id AND ca.run_id = a.run_id
WHERE a.quote IS NOT NULL AND a.verified IS DISTINCT FROM TRUE;

-- I7: confusion_resolved は confusion_type <> 'none' のときだけ値を持つ
CREATE VIEW chk_confusion_resolved AS
SELECT i.run_id, i.call_id, i.issue_idx, i.confusion_type, i.confusion_resolved
FROM issues i
JOIN current_annotation ca ON ca.call_id = i.call_id AND ca.run_id = i.run_id
WHERE (i.confusion_type = 'none' AND i.confusion_resolved IS NOT NULL)
   OR (i.confusion_type <> 'none' AND i.confusion_resolved IS NULL);

-- I8: 新しいコード列は退役していないコードを参照している(I5 の拡張。NULL は未注釈として許容)
CREATE VIEW chk_code_validity_v031 AS
SELECT i.run_id, i.call_id, i.issue_idx, 'motive' AS col, i.motive_code AS code
FROM issues i
WHERE i.motive_code IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM codes k WHERE k.code_set = 'motive' AND k.code = i.motive_code AND k.status <> 'retired')
UNION ALL
SELECT a.run_id, a.call_id, a.issue_idx, 'agent_action', a.action_code
FROM agent_actions a
WHERE NOT EXISTS (SELECT 1 FROM codes k WHERE k.code_set = 'agent_action' AND k.code = a.action_code AND k.status <> 'retired')
UNION ALL
SELECT f.run_id, f.call_id, f.turn_idx, 'turn_flag', f.flag_code
FROM turn_flags f
WHERE NOT EXISTS (SELECT 1 FROM codes k WHERE k.code_set = 'turn_flag' AND k.code = f.flag_code AND k.status <> 'retired')
UNION ALL
SELECT NULL, c.call_id, NULL, 'end_reason', c.end_reason
FROM calls c
WHERE c.end_reason IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM codes k WHERE k.code_set = 'end_reason' AND k.code = c.end_reason AND k.status <> 'retired')
UNION ALL
SELECT NULL, c.call_id, NULL, 'direction', c.direction
FROM calls c
WHERE c.direction IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM codes k WHERE k.code_set = 'direction' AND k.code = c.direction AND k.status <> 'retired');

-- I9: evidence.field は定義された値のみ('motive', 'primary' を追加)
CREATE VIEW chk_evidence_field AS
SELECT e.run_id, e.call_id, e.issue_idx, e.field
FROM evidence e
WHERE e.field NOT IN ('action','trigger','outcome','confusion','repeat_contact','motive','primary');

------------------------------------------------------------
-- 5. 初期語彙(任意。語彙管理側から投入する場合は本節を実行しない)
------------------------------------------------------------
INSERT INTO vocab_versions VALUES ('0.3.1', CURRENT_TIMESTAMP, 'v0.3.1: motive / agent_action / turn_flag / end_reason / direction を追加。issue_action に suggest を追加');

-- 新しい code_set。すべて provisional で入れ、運用の安定化手順(04)で stable に上げる
INSERT INTO codes (code_set, code, parent_code, label_ja, definition, status, valid_from, valid_to) VALUES
  ('motive', 'price',                   NULL, '価格',         '料金が高い、値上がりした、払いたくない',                     'provisional', '0.3.1', NULL),
  ('motive', 'competitor',              NULL, '競合',         '他社の方が安い・良い、他社に乗り換える',                       'provisional', '0.3.1', NULL),
  ('motive', 'no_need',                 NULL, '不要',         '使っていない、必要なくなった',                                 'provisional', '0.3.1', NULL),
  ('motive', 'quality',                 NULL, '品質',         'つながらない、遅い、壊れる、期待した機能がない',               'provisional', '0.3.1', NULL),
  ('motive', 'service_dissatisfaction', NULL, '対応不満',     '過去の応対・案内・手続きへの不満',                             'provisional', '0.3.1', NULL),
  ('motive', 'unknown',                 NULL, '不明',         '動機が述べられていない',                                       'stable',      '0.3.1', NULL),
  ('motive', 'other',                   NULL, 'その他',       'いずれにも当たらない。other_text に記入',                      'stable',      '0.3.1', NULL),

  ('agent_action', 'explained',         NULL, '説明した',     '仕組み・理由・手順を説明した',                                 'provisional', '0.3.1', NULL),
  ('agent_action', 'reissued',          NULL, '再発行した',   '書面・ID・パスワード等を再発行・再送した',                     'provisional', '0.3.1', NULL),
  ('agent_action', 'changed',           NULL, '変更した',     '契約・登録内容を通話内で変更した',                             'provisional', '0.3.1', NULL),
  ('agent_action', 'escalated',         NULL, '上席に上げた', '上席・専門部署に転送または引き継いだ',                         'provisional', '0.3.1', NULL),
  ('agent_action', 'callback_promised', NULL, '折返し約束',   '後日連絡すると約束した',                                       'provisional', '0.3.1', NULL),
  ('agent_action', 'declined',          NULL, '断った',       '顧客の要求(返金、上席、例外対応)に応じなかった',             'provisional', '0.3.1', NULL),
  ('agent_action', 'redirected_web',    NULL, 'Web を案内',   'Web・アプリ・書面での手続きに誘導した',                        'provisional', '0.3.1', NULL),
  ('agent_action', 'other',             NULL, 'その他',       'いずれにも当たらない',                                         'stable',      '0.3.1', NULL),

  ('turn_flag', 'churn_intent',         NULL, '解約意向',     '用件が解約でなくても解約・乗り換えを示唆した',                 'provisional', '0.3.1', NULL),
  ('turn_flag', 'harassment',           NULL, 'ハラスメント', '脅迫、暴言、人格攻撃、執拗な要求',                             'provisional', '0.3.1', NULL),
  ('turn_flag', 'compliance_risk',      NULL, 'コンプラ懸念', '禁止表現、誤案内の疑い、断定的な保証',                         'provisional', '0.3.1', NULL),
  ('turn_flag', 'escalation_requested', NULL, '上席要求',     '上席・責任者を出すよう求めた(実現の有無は問わない)',         'provisional', '0.3.1', NULL),
  ('turn_flag', 'praise',               NULL, '称賛',         '応対・商品への明示的な感謝・称賛',                             'provisional', '0.3.1', NULL),
  ('turn_flag', 'accessibility_need',   NULL, '利用上の制約', '視力・聴力・言語・年齢・障がい等による利用上の制約の表明',     'provisional', '0.3.1', NULL),
  ('turn_flag', 'other',                NULL, 'その他',       'いずれにも当たらない',                                         'stable',      '0.3.1', NULL),

  ('end_reason', 'customer_hangup',     NULL, '顧客切断',     '顧客側が切った',                                               'stable',      '0.3.1', NULL),
  ('end_reason', 'agent_end',           NULL, 'オペレータ終了', 'オペレータ側が終了した',                                     'stable',      '0.3.1', NULL),
  ('end_reason', 'dropped',             NULL, '途中切断',     '回線・システム起因で切れた',                                   'stable',      '0.3.1', NULL),
  ('end_reason', 'transferred',         NULL, '転送で終了',   '転送先に引き継いで当該録音が終わった',                         'stable',      '0.3.1', NULL),
  ('end_reason', 'unknown',             NULL, '不明',         'テレフォニー側に記録がない',                                   'stable',      '0.3.1', NULL),

  ('direction',  'inbound',             NULL, '着信',         '',                                                             'stable',      '0.3.1', NULL),
  ('direction',  'outbound',            NULL, '発信',         '',                                                             'stable',      '0.3.1', NULL),
  ('direction',  'unknown',             NULL, '不明',         '',                                                             'stable',      '0.3.1', NULL);

-- C8: issue_action に suggest を追加(既存の語彙に 1 コード追加。既存コードは変えない)
INSERT INTO codes (code_set, code, parent_code, label_ja, definition, status, valid_from, valid_to) VALUES
  ('issue_action', 'suggest', NULL, '提案する', '商品・書面・手続きへの改善提案・要望。苦情(complain)と区別する', 'provisional', '0.3.1', NULL);

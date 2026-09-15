-- call-insight-lab  論理スキーマ v0.3(DuckDB / PostgreSQL 互換の範囲で記述)
-- 「何を保存するか」だけを定義する。値をどう作るか(LLM、人手、規則)はこのファイルの対象外。

------------------------------------------------------------
-- 0. 語彙(コード表)と版管理
------------------------------------------------------------
CREATE TABLE vocab_versions (
  vocab_version   VARCHAR PRIMARY KEY,          -- 例 '0.3.12'
  created_at      TIMESTAMP NOT NULL,
  note            VARCHAR
);

-- すべての閉じた語彙を 1 表で持つ。code_set ごとに階層と状態を持つ。
CREATE TABLE codes (
  code_set        VARCHAR NOT NULL,              -- 'issue_action' | 'trigger' | 'outcome' | 'confusion_type' | 'phase' | 'event_type' | 'emotion' | 'object_kind'
  code            VARCHAR NOT NULL,
  parent_code     VARCHAR,                       -- 階層(親で集計できるようにする)
  label_ja        VARCHAR NOT NULL,
  definition      VARCHAR,                       -- 包含・除外基準(人が読める定義)
  status          VARCHAR NOT NULL CHECK (status IN ('stable','provisional','retired')),
  valid_from      VARCHAR NOT NULL REFERENCES vocab_versions(vocab_version),
  valid_to        VARCHAR REFERENCES vocab_versions(vocab_version),  -- NULL = 現行
  PRIMARY KEY (code_set, code)
);

-- 「何について」を表す対象マスタ。商品・書面・画面・手続き・契約属性・用語・キャンペーンを 1 表で持つ。
-- 既存の業務マスタ(商品マスタ、帳票一覧)から外部参照で取り込む。
CREATE TABLE objects (
  object_code     VARCHAR PRIMARY KEY,           -- 例 'DOC_RATE_CHANGE_NOTICE_2609', 'PLAN_A', 'ATTR_ADDRESS', 'TERM_PRORATION'
  object_kind     VARCHAR NOT NULL,              -- codes(code_set='object_kind'): product/document/screen/procedure/contract_attribute/term/campaign/other
  parent_object   VARCHAR REFERENCES objects(object_code),
  label_ja        VARCHAR NOT NULL,
  external_ref    VARCHAR,                       -- 業務マスタ側の ID
  status          VARCHAR NOT NULL CHECK (status IN ('stable','provisional','retired')),
  valid_from      VARCHAR NOT NULL REFERENCES vocab_versions(vocab_version),
  valid_to        VARCHAR REFERENCES vocab_versions(vocab_version)
);

-- 語彙の分割・統合・改名の履歴。任意の過去期間を任意の版で再表現するために使う。
CREATE TABLE code_lineage (
  code_set        VARCHAR NOT NULL,              -- 'objects' も含む
  from_code       VARCHAR NOT NULL,
  to_code         VARCHAR NOT NULL,
  relation        VARCHAR NOT NULL CHECK (relation IN ('split','merge','rename','reparent')),
  vocab_version   VARCHAR NOT NULL REFERENCES vocab_versions(vocab_version),
  PRIMARY KEY (code_set, from_code, to_code, vocab_version)
);

------------------------------------------------------------
-- 1. ソース層(観測された事実。注釈ではない)
------------------------------------------------------------
CREATE TABLE calls (
  call_id         VARCHAR PRIMARY KEY,
  started_at      TIMESTAMP NOT NULL,
  channel         VARCHAR NOT NULL,              -- 'voice' | 'chat' | ...
  customer_id     VARCHAR,
  agent_id        VARCHAR,
  duration_sec    INTEGER,
  asr_engine      VARCHAR,
  asr_confidence  DOUBLE
);

CREATE TABLE turns (
  call_id         VARCHAR NOT NULL REFERENCES calls(call_id),
  turn_idx        INTEGER NOT NULL,              -- 0 始まりの連番
  speaker         VARCHAR NOT NULL CHECK (speaker IN ('customer','agent','system')),
  text            VARCHAR NOT NULL,
  start_ms        INTEGER,
  end_ms          INTEGER,
  PRIMARY KEY (call_id, turn_idx)
);

-- 保留・転送・システム操作はターンではなくイベント。
CREATE TABLE events (
  call_id         VARCHAR NOT NULL REFERENCES calls(call_id),
  event_idx       INTEGER NOT NULL,
  event_type      VARCHAR NOT NULL,              -- codes(code_set='event_type'): hold/transfer/callback_scheduled/system_action
  start_ms        INTEGER,
  end_ms          INTEGER,
  detail          VARCHAR,                       -- 転送先など
  PRIMARY KEY (call_id, event_idx)
);

------------------------------------------------------------
-- 2. 注釈層(スタンドオフ。すべて run_id で出所を持つ)
------------------------------------------------------------
-- 「誰が・どの設定で」付けた注釈かを 1 行で表す。LLM でも人手でも規則でも同じ表。
CREATE TABLE annotation_runs (
  run_id          VARCHAR PRIMARY KEY,
  annotator       VARCHAR NOT NULL,              -- 'llm:<model>' | 'human:<id>' | 'rule:<name>'
  schema_version  VARCHAR NOT NULL,
  vocab_version   VARCHAR NOT NULL REFERENCES vocab_versions(vocab_version),
  config_version  VARCHAR,                       -- プロンプト版など。中身はここでは問わない
  run_at          TIMESTAMP NOT NULL
);

-- 通話ごとに「現在有効な注釈 run」を 1 つ指す。再抽出・バックフィルはここを差し替える。
CREATE TABLE current_annotation (
  call_id         VARCHAR PRIMARY KEY REFERENCES calls(call_id),
  run_id          VARCHAR NOT NULL REFERENCES annotation_runs(run_id)
);

-- 2a. 局面: ターンごとに 1 つ
CREATE TABLE turn_phases (
  run_id          VARCHAR NOT NULL REFERENCES annotation_runs(run_id),
  call_id         VARCHAR NOT NULL,
  turn_idx        INTEGER NOT NULL,
  phase           VARCHAR NOT NULL,              -- codes(code_set='phase'): opening/purpose_statement/verification/discussion/closing/off_topic
  PRIMARY KEY (run_id, call_id, turn_idx),
  FOREIGN KEY (call_id, turn_idx) REFERENCES turns(call_id, turn_idx)
);

-- 2b. 用件: 分析の単位。分析列はすべて閉じた語彙。
CREATE TABLE issues (
  run_id                  VARCHAR NOT NULL REFERENCES annotation_runs(run_id),
  call_id                 VARCHAR NOT NULL REFERENCES calls(call_id),
  issue_idx               INTEGER NOT NULL,      -- 通話内の連番(言及順)
  is_primary              BOOLEAN NOT NULL,
  score                   DOUBLE,                -- 帰属の確信度(任意)
  -- 何を(action × object)
  action_code             VARCHAR NOT NULL,      -- codes('issue_action'): inquire/request_change/apply/cancel/report_problem/complain/confirm/other
  object_code             VARCHAR NOT NULL REFERENCES objects(object_code),
  -- なぜ今(きっかけ)
  trigger_code            VARCHAR NOT NULL,      -- codes('trigger')
  trigger_object_code     VARCHAR REFERENCES objects(object_code),   -- 例: received_notice のどの書面か
  -- 結果
  outcome_code            VARCHAR NOT NULL,      -- codes('outcome'): resolved/escalated/callback_promised/unresolved/unknown
  repeat_contact_signal   BOOLEAN NOT NULL,
  -- わかりづらさ
  confusion_type          VARCHAR NOT NULL,      -- codes('confusion_type'): none/direct/indirect_misread/indirect_clarify
  confusion_object_code   VARCHAR REFERENCES objects(object_code),
  -- 非分析列(集計しない)
  summary_ja              VARCHAR,               -- 用件 1 文要約。語彙保守とドリルダウン用
  other_text              VARCHAR,               -- いずれかの列で other を選んだときの説明
  PRIMARY KEY (run_id, call_id, issue_idx)
);

-- 2c. 用件とターンの多対多(非連続可)
CREATE TABLE issue_turns (
  run_id          VARCHAR NOT NULL,
  call_id         VARCHAR NOT NULL,
  issue_idx       INTEGER NOT NULL,
  turn_idx        INTEGER NOT NULL,
  PRIMARY KEY (run_id, call_id, issue_idx, turn_idx),
  FOREIGN KEY (run_id, call_id, issue_idx) REFERENCES issues(run_id, call_id, issue_idx),
  FOREIGN KEY (call_id, turn_idx) REFERENCES turns(call_id, turn_idx)
);

-- 2d. 根拠: 判断列ごとに、どのターンのどの範囲か。位置参照+引用の両方を持つ。
CREATE TABLE evidence (
  run_id          VARCHAR NOT NULL,
  call_id         VARCHAR NOT NULL,
  issue_idx       INTEGER NOT NULL,
  field           VARCHAR NOT NULL,              -- 'action' | 'trigger' | 'outcome' | 'confusion' | 'repeat_contact'
  turn_idx        INTEGER NOT NULL,
  begin_char      INTEGER NOT NULL,
  end_char        INTEGER NOT NULL,
  quote           VARCHAR NOT NULL,
  verified        BOOLEAN,                       -- turns.text[begin:end] = quote を検査した結果
  PRIMARY KEY (run_id, call_id, issue_idx, field, turn_idx, begin_char),
  FOREIGN KEY (run_id, call_id, issue_idx) REFERENCES issues(run_id, call_id, issue_idx),
  FOREIGN KEY (call_id, turn_idx) REFERENCES turns(call_id, turn_idx)
);

-- 2e. 通話レベルの注釈(用件に帰属しないもの)
CREATE TABLE call_annotations (
  run_id          VARCHAR NOT NULL REFERENCES annotation_runs(run_id),
  call_id         VARCHAR NOT NULL REFERENCES calls(call_id),
  emotion_start   VARCHAR,                       -- codes('emotion'): negative/neutral/positive
  emotion_end     VARCHAR,
  summary_ja      VARCHAR,                       -- 非分析列
  PRIMARY KEY (run_id, call_id)
);

------------------------------------------------------------
-- 3. 導出ビュー(現在有効な run のみ)
------------------------------------------------------------
CREATE VIEW v_issues AS
SELECT i.*, c.started_at, c.channel, c.customer_id, c.agent_id,
       o.object_kind, o.parent_object,
       (SELECT COUNT(*) FROM issue_turns t
         WHERE t.run_id = i.run_id AND t.call_id = i.call_id AND t.issue_idx = i.issue_idx) AS n_turns,
       (SELECT COUNT(*) FROM issue_turns t JOIN turn_phases p
           ON p.run_id = t.run_id AND p.call_id = t.call_id AND p.turn_idx = t.turn_idx
         WHERE t.run_id = i.run_id AND t.call_id = i.call_id AND t.issue_idx = i.issue_idx
           AND p.phase = 'discussion') AS n_discussion_turns
FROM issues i
JOIN current_annotation ca ON ca.call_id = i.call_id AND ca.run_id = i.run_id
JOIN calls c ON c.call_id = i.call_id
JOIN objects o ON o.object_code = i.object_code;

CREATE VIEW v_calls AS
SELECT c.call_id, c.started_at, c.channel, c.customer_id, c.agent_id, c.duration_sec,
       ca.run_id,
       (SELECT COUNT(*) FROM issues i WHERE i.run_id = ca.run_id AND i.call_id = c.call_id) AS n_issues,
       (SELECT i.action_code FROM issues i WHERE i.run_id = ca.run_id AND i.call_id = c.call_id AND i.is_primary LIMIT 1) AS primary_action,
       (SELECT i.object_code FROM issues i WHERE i.run_id = ca.run_id AND i.call_id = c.call_id AND i.is_primary LIMIT 1) AS primary_object,
       (SELECT BOOL_AND(i.outcome_code = 'resolved') FROM issues i WHERE i.run_id = ca.run_id AND i.call_id = c.call_id) AS all_resolved,
       (SELECT COUNT(*) FROM turn_phases p WHERE p.run_id = ca.run_id AND p.call_id = c.call_id AND p.phase = 'verification') AS verification_turns,
       (SELECT COUNT(*) FROM turn_phases p WHERE p.run_id = ca.run_id AND p.call_id = c.call_id) AS total_turns,
       -- 目的発話で述べられたが discussion に一度も現れない用件があるか
       EXISTS (SELECT 1 FROM v_issues vi WHERE vi.call_id = c.call_id AND vi.n_discussion_turns = 0) AS has_unaddressed_issue,
       an.emotion_start, an.emotion_end
FROM calls c
JOIN current_annotation ca ON ca.call_id = c.call_id
LEFT JOIN call_annotations an ON an.run_id = ca.run_id AND an.call_id = c.call_id;

------------------------------------------------------------
-- 4. 不変条件(制約で書けないものは検査クエリとして定義)
------------------------------------------------------------
-- I1: 現在有効な run では、全ターンにちょうど 1 つの phase がある
CREATE VIEW chk_phase_coverage AS
SELECT t.call_id, COUNT(*) AS turns, COUNT(p.turn_idx) AS phased
FROM turns t
JOIN current_annotation ca ON ca.call_id = t.call_id
LEFT JOIN turn_phases p ON p.run_id = ca.run_id AND p.call_id = t.call_id AND p.turn_idx = t.turn_idx
GROUP BY t.call_id HAVING COUNT(*) <> COUNT(p.turn_idx);

-- I2: 主用件は通話につき高々 1 つ(用件が 1 つ以上あれば必ず 1 つ)
CREATE VIEW chk_primary_issue AS
SELECT i.call_id, SUM(CASE WHEN is_primary THEN 1 ELSE 0 END) AS n_primary, COUNT(*) AS n_issues
FROM issues i JOIN current_annotation ca ON ca.call_id = i.call_id AND ca.run_id = i.run_id
GROUP BY i.call_id HAVING SUM(CASE WHEN is_primary THEN 1 ELSE 0 END) <> 1;

-- I3: verification 局面のターンは用件に帰属しない
CREATE VIEW chk_verification_not_in_issue AS
SELECT it.call_id, it.turn_idx
FROM issue_turns it
JOIN current_annotation ca ON ca.call_id = it.call_id AND ca.run_id = it.run_id
JOIN turn_phases p ON p.run_id = it.run_id AND p.call_id = it.call_id AND p.turn_idx = it.turn_idx
WHERE p.phase = 'verification';

-- I4: 根拠の引用は本文と逐語一致している(verified が NULL/false の行を列挙)
CREATE VIEW chk_evidence_unverified AS
SELECT e.* FROM evidence e
JOIN current_annotation ca ON ca.call_id = e.call_id AND ca.run_id = e.run_id
WHERE e.verified IS DISTINCT FROM TRUE;

-- I5: 用件の各コード列は、その run の vocab_version で有効な code を参照している
CREATE VIEW chk_code_validity AS
SELECT i.run_id, i.call_id, i.issue_idx, 'action' AS col, i.action_code AS code
FROM issues i JOIN annotation_runs r ON r.run_id = i.run_id
WHERE NOT EXISTS (SELECT 1 FROM codes k WHERE k.code_set = 'issue_action' AND k.code = i.action_code AND k.status <> 'retired')
UNION ALL
SELECT i.run_id, i.call_id, i.issue_idx, 'trigger', i.trigger_code
FROM issues i WHERE NOT EXISTS (SELECT 1 FROM codes k WHERE k.code_set = 'trigger' AND k.code = i.trigger_code AND k.status <> 'retired')
UNION ALL
SELECT i.run_id, i.call_id, i.issue_idx, 'outcome', i.outcome_code
FROM issues i WHERE NOT EXISTS (SELECT 1 FROM codes k WHERE k.code_set = 'outcome' AND k.code = i.outcome_code AND k.status <> 'retired')
UNION ALL
SELECT i.run_id, i.call_id, i.issue_idx, 'confusion_type', i.confusion_type
FROM issues i WHERE NOT EXISTS (SELECT 1 FROM codes k WHERE k.code_set = 'confusion_type' AND k.code = i.confusion_type AND k.status <> 'retired');

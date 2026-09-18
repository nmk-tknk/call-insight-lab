"""v0_3.sql -> v0_3_1.sql を DuckDB に適用し、新しいビューと不変条件 I6-I9 を 1 通話のサンプルで検査する。

実行: python poc/schema/check_v0_3_1.py  (リポジトリのどこからでも可)
"""
import duckdb, sys, pathlib
HERE = pathlib.Path(__file__).resolve().parent
con = duckdb.connect()
for f in [HERE / "v0_3.sql", HERE / "v0_3_1.sql"]:
    con.execute(f.read_text(encoding="utf-8"))
    print("applied", f)

# v0.3 側の最低限の語彙(chk_code_validity のため)
con.execute("INSERT INTO vocab_versions VALUES ('0.3', now(), 'base')")
con.execute("""INSERT INTO codes VALUES
 ('issue_action','inquire',NULL,'照会','', 'stable','0.3',NULL),
 ('trigger','viewed_bill',NULL,'請求書を見た','', 'stable','0.3',NULL),
 ('outcome','resolved',NULL,'解決','', 'stable','0.3',NULL),
 ('outcome','unresolved',NULL,'未解決','', 'stable','0.3',NULL),
 ('confusion_type','none',NULL,'なし','', 'stable','0.3',NULL),
 ('confusion_type','indirect_misread',NULL,'誤解','', 'stable','0.3',NULL),
 ('object_kind','document',NULL,'書面','', 'stable','0.3',NULL)""")
con.execute("INSERT INTO objects VALUES ('DOC_BILL_STATEMENT','document',NULL,'請求明細',NULL,'stable','0.3',NULL)")

# サンプル通話(新しいソース列を含む)
con.execute("""INSERT INTO calls (call_id, started_at, channel, customer_id, agent_id, duration_sec,
  direction, queue, ivr_path, wait_sec, end_reason, external_case_id, disposition_code)
  VALUES ('C1', now(), 'voice', 'cust1', 'ag1', 300, 'inbound', 'Q_BILL', '2>1', 45, 'customer_hangup', 'CASE-1', 'BILL_INQ')""")
con.execute("""INSERT INTO turns (call_id, turn_idx, speaker, text, asr_confidence) VALUES
 ('C1',0,'agent','お電話ありがとうございます。',0.95),
 ('C1',1,'customer','請求が二重に取られてる気がして。高いなら解約も考えます。',0.88),
 ('C1',2,'agent','日割りの記載ですので二重ではありません。ご説明します。',0.93),
 ('C1',3,'customer','はい、わかりました。',0.90)""")
con.execute("INSERT INTO events (call_id, event_idx, event_type, start_ms, end_ms, detail, agent_id) VALUES ('C1',0,'hold',1000,5000,NULL,NULL)")
con.execute("INSERT INTO call_customer_snapshot VALUES ('C1', now(), 'PLAN_A', 14, '40s', 'SEG1')")

con.execute("INSERT INTO annotation_runs VALUES ('R1','llm:test','0.3.1','0.3.1','p1',now())")
con.execute("INSERT INTO current_annotation VALUES ('C1','R1')")
for i, p in enumerate(['opening','purpose_statement','discussion','closing']):
    con.execute("INSERT INTO turn_phases VALUES ('R1','C1',?,?)", [i, p])
con.execute("""INSERT INTO issues (run_id, call_id, issue_idx, is_primary, score, action_code, object_code,
  trigger_code, trigger_object_code, outcome_code, repeat_contact_signal, confusion_type, confusion_object_code,
  summary_ja, other_text, motive_code, confusion_resolved, customer_accepted)
  VALUES ('R1','C1',0,true,0.9,'inquire','DOC_BILL_STATEMENT','viewed_bill','DOC_BILL_STATEMENT','resolved',false,
  'indirect_misread','DOC_BILL_STATEMENT','日割りを二重請求と誤解',NULL,'price',true,true)""")
con.execute("INSERT INTO issue_turns VALUES ('R1','C1',0,1),('R1','C1',0,2),('R1','C1',0,3)")
q = '請求が二重に取られてる気がして。'
con.execute("INSERT INTO evidence VALUES ('R1','C1',0,'confusion',1,0,?,?,true,0.8)", [len(q), q])
con.execute("INSERT INTO evidence VALUES ('R1','C1',0,'primary',1,0,?,?,true,NULL)", [len(q), q])
q2 = 'ご説明します。'
t2 = con.execute("SELECT text FROM turns WHERE call_id='C1' AND turn_idx=2").fetchone()[0]
b = t2.index(q2)
con.execute("INSERT INTO agent_actions VALUES ('R1','C1',0,'explained',2,?,?,?,true)", [b, b+len(q2), q2])
t1 = con.execute("SELECT text FROM turns WHERE call_id='C1' AND turn_idx=1").fetchone()[0]
q3 = '解約も考えます。'
b = t1.index(q3)
con.execute("INSERT INTO turn_flags VALUES ('R1','C1',1,'churn_intent',?,?,?,true)", [b, b+len(q3), q3])

print("--- views ---")
print(con.execute("SELECT call_id, issue_idx, motive_code, confusion_resolved, customer_accepted, n_turns FROM v_issues").fetchall())
print(con.execute("SELECT call_id, flag_code, quote, speaker FROM v_turn_flags").fetchall())
print(con.execute("SELECT call_id, action_code, issue_action_code, outcome_code FROM v_agent_actions").fetchall())
print(con.execute("SELECT * FROM v_call_flags").fetchall())
print(con.execute("SELECT call_id, direction, end_reason, wait_sec FROM calls").fetchall())

print("--- invariants (expect all empty) ---")
ok = True
for v in ["chk_phase_coverage","chk_primary_issue","chk_verification_not_in_issue","chk_evidence_unverified",
          "chk_code_validity","chk_flag_evidence_unverified","chk_confusion_resolved","chk_code_validity_v031","chk_evidence_field"]:
    rows = con.execute(f"SELECT * FROM {v}").fetchall()
    print(v, rows)
    ok = ok and not rows

print("--- negative cases (expect each to be caught) ---")
con.execute("UPDATE issues SET confusion_resolved = NULL WHERE issue_idx = 0")
r = con.execute("SELECT COUNT(*) FROM chk_confusion_resolved").fetchone()[0]; print("I7 catches NULL on confusion:", r == 1); ok = ok and r == 1
con.execute("UPDATE issues SET confusion_resolved = true, motive_code = 'bogus' WHERE issue_idx = 0")
r = con.execute("SELECT COUNT(*) FROM chk_code_validity_v031").fetchone()[0]; print("I8 catches bogus motive:", r == 1); ok = ok and r == 1
con.execute("UPDATE issues SET motive_code = 'price' WHERE issue_idx = 0")
con.execute("UPDATE turn_flags SET verified = false")
r = con.execute("SELECT COUNT(*) FROM chk_flag_evidence_unverified").fetchone()[0]; print("I6 catches unverified flag:", r == 1); ok = ok and r == 1
con.execute("INSERT INTO evidence VALUES ('R1','C1',0,'bogus',1,0,3,'請求が',true,NULL)")
r = con.execute("SELECT COUNT(*) FROM chk_evidence_field").fetchone()[0]; print("I9 catches bogus field:", r == 1); ok = ok and r == 1
# FK: turn_flags to nonexistent turn
try:
    con.execute("INSERT INTO turn_flags VALUES ('R1','C1',99,'praise',0,1,'x',true)"); print("FK turn_flags->turns: NOT enforced"); ok = False
except Exception as e:
    print("FK turn_flags->turns enforced:", type(e).__name__)
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)

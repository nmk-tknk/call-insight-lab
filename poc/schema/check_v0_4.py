"""v0_3.sql -> v0_3_1.sql -> v0_4.sql を DuckDB に適用し、発話行為から判断列を導くビューと不変条件 I10-I13、具体化手順を 1 通話で検査する。

実行: python poc/schema/check_v0_4.py
"""
import duckdb, sys, pathlib
HERE = pathlib.Path(__file__).resolve().parent
con = duckdb.connect()
for f in ["v0_3.sql", "v0_3_1.sql", "v0_4.sql"]:
    con.execute((HERE / f).read_text(encoding="utf-8")); print("applied", f)

# v0.3 側の最低限の語彙・対象
con.execute("INSERT INTO vocab_versions VALUES ('0.3', now(), 'base')")
con.execute("""INSERT INTO codes VALUES
 ('issue_action','inquire',NULL,'照会','', 'stable','0.3',NULL),
 ('trigger','received_notice',NULL,'通知を受け取った','', 'stable','0.3',NULL),
 ('trigger','unknown',NULL,'不明','', 'stable','0.3',NULL),
 ('outcome','resolved',NULL,'解決','', 'stable','0.3',NULL),
 ('outcome','unresolved',NULL,'未解決','', 'stable','0.3',NULL),
 ('outcome','unknown',NULL,'不明','', 'stable','0.3',NULL),
 ('confusion_type','none',NULL,'なし','', 'stable','0.3',NULL),
 ('confusion_type','indirect_misread',NULL,'誤解','', 'stable','0.3',NULL),
 ('object_kind','document',NULL,'書面','', 'stable','0.3',NULL)""")
con.execute("""INSERT INTO objects VALUES
 ('DOC_RENEWAL_NOTICE','document',NULL,'更新案内',NULL,'stable','0.3',NULL),
 ('TERM_PREMIUM_CHANGE','term',NULL,'保険料の増減理由',NULL,'stable','0.3',NULL),
 ('COV_DRIVER_SCOPE','coverage',NULL,'運転者限定',NULL,'stable','0.3',NULL)""")

turns = [
 (0,'agent',   'お電話ありがとうございます'),
 (1,'customer','更新案内を見たら保険料が上がっていて 無事故なのに上がるのはおかしいですよね 高いので解約も考えます 正直腹が立ちます'),
 (2,'agent',   '無事故でも料率改定で上がることがございます 料率改定についてご説明します'),
 (3,'customer','そうなんですね わかりました'),
 (4,'customer','あと家族限定は別居の子も入ってますよね'),
 (5,'agent',   '別居の未婚のお子様は含まれますが ご結婚されたお子様は含まれません'),
 (6,'customer','ありがとうございました'),
]
con.execute("INSERT INTO calls (call_id, started_at, channel) VALUES ('C1', now(), 'voice')")
for i, sp, tx in turns:
    con.execute("INSERT INTO turns (call_id, turn_idx, speaker, text, start_ms, end_ms) VALUES ('C1',?,?,?,?,?)", [i, sp, tx, i*10000, i*10000+8000])
con.execute("INSERT INTO annotation_runs VALUES ('R4','llm:test','0.4','0.4','p1',now())")
con.execute("INSERT INTO current_annotation VALUES ('C1','R4')")
for i, p in enumerate(['opening','purpose_statement','discussion','discussion','purpose_statement','discussion','closing']):
    con.execute("INSERT INTO turn_phases VALUES ('R4','C1',?,?)", [i, p])
# 構造のみ(判断列は具体化前の仮値)
for idx, prim in [(0, True), (1, False)]:
    con.execute("""INSERT INTO issues (run_id, call_id, issue_idx, is_primary, action_code, object_code, trigger_code, outcome_code,
      repeat_contact_signal, confusion_type) VALUES ('R4','C1',?,?,'inquire',?, 'unknown','unknown', false,'none')""",
      [idx, prim, 'TERM_PREMIUM_CHANGE' if idx == 0 else 'COV_DRIVER_SCOPE'])
con.execute("INSERT INTO issue_turns VALUES ('R4','C1',0,1),('R4','C1',0,2),('R4','C1',0,3),('R4','C1',1,4),('R4','C1',1,5)")
con.execute("INSERT INTO call_annotations (run_id, call_id) VALUES ('R4','C1')")

def act(idx, turn, issue, speaker, code, quote, obj=None, aspect=None, value=None):
    text = turns[turn][2]; b = text.index(quote)
    con.execute("INSERT INTO acts VALUES ('R4','C1',?,?,?,?,?,?,?,?,NULL,NULL,?,?,?,true)",
                [idx, turn, issue, speaker, code, obj, aspect, value, b, b+len(quote), quote])
act(0, 1, 0, 'customer', 'state_trigger',   '更新案内を見たら', 'DOC_RENEWAL_NOTICE', None, 'received_notice')
act(1, 1, 0, 'customer', 'inquire',         '保険料が上がっていて', 'TERM_PREMIUM_CHANGE', 'amount')
act(2, 1, 0, 'customer', 'assert_belief',   '無事故なのに上がるのはおかしいですよね', 'TERM_PREMIUM_CHANGE', 'amount', 'no_accident_no_increase')
act(3, 1, 0, 'customer', 'state_reason',    '高いので', None, None, 'price')
act(4, 1, None,'customer','state_intent',   '解約も考えます', None, None, 'churn')
act(5, 1, None,'customer','express_emotion','腹が立ちます', None, None, 'anger')
act(6, 2, 0, 'agent',    'corrected',       '無事故でも料率改定で上がることがございます', 'TERM_PREMIUM_CHANGE')
act(7, 2, 0, 'agent',    'explained',       '料率改定についてご説明します', 'TERM_PREMIUM_CHANGE')
act(8, 3, 0, 'customer', 'accept',          'わかりました')
act(9, 4, 1, 'customer', 'inquire',         '家族限定は別居の子も入ってますよね', 'COV_DRIVER_SCOPE', 'scope')
act(10,4, 1, 'customer', 'assert_belief',   '別居の子も入ってますよね', 'COV_DRIVER_SCOPE', 'scope', 'family_incl_separated_child')
act(11,5, 1, 'agent',    'explained',       '別居の未婚のお子様は含まれますが', 'COV_DRIVER_SCOPE')
act(12,6, None,'customer','express_emotion','ありがとうございました', None, None, 'gratitude')

print("--- derived ---")
rows = con.execute("SELECT issue_idx, trigger_code, motive_code, confusion_type, confusion_object_code, confusion_resolved, customer_accepted, outcome_code, aspect_code FROM v_issue_derived ORDER BY issue_idx").fetchall()
for r in rows: print(r)
exp = {0: ('received_notice','price','indirect_misread','TERM_PREMIUM_CHANGE',True,True,'resolved','amount'),
       1: ('unknown','unknown','indirect_misread','COV_DRIVER_SCOPE',None,None,'resolved','scope')}
ok = all(tuple(r[1:]) == exp[r[0]] for r in rows)
print("derived as expected:", ok)
flags = con.execute("SELECT turn_idx, flag_code FROM v_turn_flags_derived ORDER BY turn_idx").fetchall(); print("flags:", flags)
ok = ok and flags == [(1,'churn_intent'),(6,'praise')]
emo = con.execute("SELECT emotion_start, emotion_end FROM v_call_emotion_derived").fetchall(); print("emotion:", emo)
ok = ok and emo == [('negative','positive')]

print("--- analyst views (v0.3.1 column set, v0.4 values) ---")
vi = con.execute("SELECT issue_idx, confusion_type, outcome_code, motive_code, aspect_code, trigger_code FROM v_issues ORDER BY issue_idx").fetchall(); print(vi)
ok = ok and vi == [(0,'indirect_misread','resolved','price','amount','received_notice'), (1,'indirect_misread','resolved','unknown','scope','unknown')]
cf = con.execute("SELECT has_churn_intent, has_praise, n_flags FROM v_call_flags").fetchall(); print(cf); ok = ok and cf == [(True, True, 2)]
vc = con.execute("SELECT n_issues, primary_action, all_resolved, emotion_start, emotion_end FROM v_calls").fetchall(); print(vc); ok = ok and vc == [(2,'inquire',True,'negative','positive')]
aa = con.execute("SELECT issue_idx, action_code FROM v_agent_actions ORDER BY issue_idx, action_code").fetchall(); print(aa); ok = ok and aa == [(0,'explained'),(1,'explained')]

print("--- invariants (expect all empty) ---")
for v in ["chk_phase_coverage","chk_primary_issue","chk_verification_not_in_issue","chk_evidence_unverified","chk_code_validity",
          "chk_flag_evidence_unverified","chk_confusion_resolved","chk_code_validity_v031","chk_evidence_field",
          "chk_acts_unverified","chk_acts_speaker","chk_acts_value","chk_issue_placeholders"]:
    r = con.execute(f"SELECT * FROM {v}").fetchall(); print(v, r); ok = ok and not r

print("--- negative cases ---")
# v0.4 run の issues に判断を書き込む誤りは I13 が捕捉する(DuckDB は FK 参照される表の UPDATE を拒むため、別 run で再現)
con.execute("INSERT INTO annotation_runs VALUES ('R4b','llm:test','0.4','0.4','p1',now())")
con.execute("INSERT INTO calls (call_id, started_at, channel) VALUES ('C2', now(), 'voice')")
con.execute("INSERT INTO issues (run_id, call_id, issue_idx, is_primary, action_code, object_code, trigger_code, outcome_code, repeat_contact_signal, confusion_type) VALUES ('R4b','C2',0,true,'inquire','COV_DRIVER_SCOPE','received_notice','resolved',false,'direct')")
r = con.execute("SELECT COUNT(*) FROM chk_issue_placeholders").fetchone()[0]; print("I13 catches stored judgment in v0.4 run:", r == 1); ok = ok and r == 1
con.execute("DELETE FROM issues WHERE run_id = 'R4b'")
con.execute("INSERT INTO acts VALUES ('R4','C1',99,0,NULL,'customer','accept',NULL,NULL,NULL,NULL,NULL,0,3,'お電話',true)")
r = con.execute("SELECT COUNT(*) FROM chk_acts_speaker").fetchone()[0]; print("I11 catches speaker mismatch:", r == 1); ok = ok and r == 1
con.execute("DELETE FROM acts WHERE act_idx = 99")
con.execute("INSERT INTO acts VALUES ('R4','C1',98,1,0,'customer','state_reason',NULL,NULL,'bogus',NULL,NULL,0,3,'更新案',true)")
r = con.execute("SELECT COUNT(*) FROM chk_acts_value").fetchone()[0]; print("I12 catches bogus value:", r == 1); ok = ok and r == 1
con.execute("DELETE FROM acts WHERE act_idx = 98")
# 規則変更の例: known_misconceptions から family の主張を外すと、issue 1 は none になる(LLM を回さずに結果が変わる)
con.execute("UPDATE known_misconceptions SET valid_to = '0.4' WHERE claim_code = 'family_incl_separated_child'")
r = con.execute("SELECT confusion_type FROM v_issue_derived WHERE issue_idx = 1").fetchone()[0]; print("rule change flows through view:", r == 'none'); ok = ok and r == 'none'
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)

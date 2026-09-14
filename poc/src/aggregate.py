"""Tag-only aggregation demo (DuckDB). Answers goal (a) and goal (b) from the extracted table.

Usage: python -m src.aggregate --transcripts samples/transcripts.jsonl --extracted out/verified.jsonl
"""
from __future__ import annotations
import argparse, json
import duckdb, pandas as pd

pd.set_option("display.width", 200)
pd.set_option("display.max_columns", 30)


def load(transcripts: str, extracted: str) -> duckdb.DuckDBPyConnection:
    meta = pd.DataFrame([json.loads(l) for l in open(transcripts, encoding="utf-8")]).drop(columns=["transcript"])
    ext = pd.DataFrame([json.loads(l) for l in open(extracted, encoding="utf-8")])
    con = duckdb.connect()
    con.register("meta", meta)
    con.register("ext", ext)
    con.execute("""
        CREATE TABLE calls AS
        SELECT m.*, e.* EXCLUDE (call_id),
               strftime(CAST(m.call_date AS DATE), '%Y-W%V') AS week,
               CASE WHEN CAST(m.call_date AS DATE) >= DATE '2026-09-07' THEN 'spike' ELSE 'baseline' END AS period
        FROM meta m JOIN ext e USING (call_id)
    """)
    # 7日以内の再入電(同一顧客)を CRM 側の事実として付与
    con.execute("""
        CREATE TABLE calls2 AS
        SELECT c.*, EXISTS (
            SELECT 1 FROM calls n
            WHERE n.customer_id = c.customer_id AND n.call_id <> c.call_id
              AND CAST(n.call_date AS DATE) > CAST(c.call_date AS DATE)
              AND CAST(n.call_date AS DATE) <= CAST(c.call_date AS DATE) + INTERVAL 7 DAY
        ) AS repeat_within_7d
        FROM calls c
    """)
    return con


def show(con, title: str, sql: str) -> None:
    print(f"\n=== {title} ===")
    print(con.execute(sql).df().to_string(index=False))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--transcripts", default="samples/transcripts.jsonl")
    ap.add_argument("--extracted", default="out/verified.jsonl")
    a = ap.parse_args()
    con = load(a.transcripts, a.extracted)

    show(con, "0. 品質ゲート: 根拠の逐語一致", """
        SELECT COUNT(*) AS calls, SUM(CASE WHEN evidence_verified THEN 1 ELSE 0 END) AS verified,
               ROUND(AVG(CASE WHEN evidence_verified THEN 1.0 ELSE 0 END), 3) AS rate
        FROM calls2""")

    show(con, "A-1. テーマ(BILL_AMOUNT_INQUIRY)の週次件数と全体比", """
        SELECT week, COUNT(*) AS total,
               SUM(CASE WHEN reason_l2 = 'BILL_AMOUNT_INQUIRY' THEN 1 ELSE 0 END) AS theme_n,
               ROUND(AVG(CASE WHEN reason_l2 = 'BILL_AMOUNT_INQUIRY' THEN 1.0 ELSE 0 END), 2) AS theme_share
        FROM calls2 GROUP BY week ORDER BY week""")

    for col in ["trigger_code", "touchpoint_code", "confusion_touchpoint_code", "confusion_type"]:
        show(con, f"A-2. 急増期間 vs 平常期間: {col} の分布(テーマ該当のみ)", f"""
            SELECT {col},
                   SUM(CASE WHEN period='baseline' THEN 1 ELSE 0 END) AS baseline_n,
                   SUM(CASE WHEN period='spike' THEN 1 ELSE 0 END) AS spike_n,
                   ROUND(SUM(CASE WHEN period='spike' THEN 1.0 ELSE 0 END) / NULLIF(SUM(SUM(CASE WHEN period='spike' THEN 1 ELSE 0 END)) OVER (), 0), 2) AS spike_share,
                   ROUND(SUM(CASE WHEN period='baseline' THEN 1.0 ELSE 0 END) / NULLIF(SUM(SUM(CASE WHEN period='baseline' THEN 1 ELSE 0 END)) OVER (), 0), 2) AS baseline_share
            FROM calls2 WHERE reason_l2 = 'BILL_AMOUNT_INQUIRY'
            GROUP BY {col} ORDER BY spike_n DESC""")

    show(con, "A-3. 急増期間のテーマ該当通話: タグの組み合わせ(真因候補)", """
        SELECT trigger_code, confusion_type, confusion_touchpoint_code, COUNT(*) AS n
        FROM calls2 WHERE reason_l2 = 'BILL_AMOUNT_INQUIRY' AND period = 'spike'
        GROUP BY ALL ORDER BY n DESC""")

    show(con, "A-4. 根拠引用(急増期間・テーマ該当・無作為順)", """
        SELECT call_id, confusion_type, confusion_evidence
        FROM calls2 WHERE reason_l2 = 'BILL_AMOUNT_INQUIRY' AND period = 'spike'
        ORDER BY hash(call_id)""")

    show(con, "B-1. 「わかりづらい」パターン: 接点 × 訴え方 × 下流コスト", """
        SELECT confusion_touchpoint_code, confusion_type, COUNT(*) AS n,
               ROUND(AVG(handle_seconds)) AS aht_sec,
               ROUND(AVG(CASE WHEN repeat_within_7d THEN 1.0 ELSE 0 END), 2) AS repeat_7d,
               ROUND(AVG(CASE WHEN resolution_status IN ('unresolved','escalated') THEN 1.0 ELSE 0 END), 2) AS not_resolved,
               ROUND(AVG(CASE WHEN emotion_end = 'negative' THEN 1.0 ELSE 0 END), 2) AS negative_end
        FROM calls2 WHERE confusion_signal
        GROUP BY ALL ORDER BY n DESC""")

    show(con, "B-2. 混乱を含む通話の割合(全体・週次)", """
        SELECT week, COUNT(*) AS total, SUM(CASE WHEN confusion_signal THEN 1 ELSE 0 END) AS confused,
               ROUND(AVG(CASE WHEN confusion_signal THEN 1.0 ELSE 0 END), 2) AS share
        FROM calls2 GROUP BY week ORDER BY week""")

    show(con, "C-1. 外部整合: 解決状況 × 7日以内再入電(CRM 事実)", """
        SELECT resolution_status, COUNT(*) AS n,
               ROUND(AVG(CASE WHEN repeat_within_7d THEN 1.0 ELSE 0 END), 2) AS repeat_7d,
               SUM(CASE WHEN repeat_contact_signal THEN 1 ELSE 0 END) AS said_repeat
        FROM calls2 GROUP BY ALL ORDER BY n DESC""")

    show(con, "C-2. 語彙進化シグナル: other 率と other_text", """
        SELECT 'reason' AS col, SUM(CASE WHEN reason_l2='OTHER' THEN 1 ELSE 0 END) AS other_n, COUNT(*) AS n,
               string_agg(NULLIF(reason_other_text, ''), ' | ') AS other_texts FROM calls2
        UNION ALL
        SELECT 'trigger', SUM(CASE WHEN trigger_code='other' THEN 1 ELSE 0 END), COUNT(*), string_agg(NULLIF(trigger_other_text, ''), ' | ') FROM calls2
        UNION ALL
        SELECT 'touchpoint', SUM(CASE WHEN touchpoint_code='OTHER' OR confusion_touchpoint_code='OTHER' THEN 1 ELSE 0 END), COUNT(*), string_agg(NULLIF(touchpoint_other_text, ''), ' | ') FROM calls2""")

    show(con, "全通話の一覧(確認用)", """
        SELECT call_id, week, reason_l2, request_type, trigger_code, touchpoint_code, confusion_type,
               confusion_touchpoint_code, resolution_status, repeat_contact_signal AS rep, emotion_end
        FROM calls2 ORDER BY call_id""")


if __name__ == "__main__":
    main()

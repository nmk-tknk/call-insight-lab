"""Evidence verification: every *_evidence must be a verbatim substring of the transcript.

Usage: python -m src.verify_evidence --transcripts samples/transcripts.jsonl --extracted samples/extracted.jsonl
Writes out/verified.jsonl with evidence_verified (bool) and evidence_failures (list).
"""
from __future__ import annotations
import argparse, json, pathlib, unicodedata

EVIDENCE_FIELDS = ["confusion_evidence", "resolution_evidence", "repeat_evidence"]


def norm(s: str) -> str:
    # ASR 出力の表記揺れ(全角/半角)だけ吸収する。句読点・空白の差は吸収しない(逐語一致を要求)。
    return unicodedata.normalize("NFKC", s)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--transcripts", default="samples/transcripts.jsonl")
    ap.add_argument("--extracted", default="samples/extracted.jsonl")
    ap.add_argument("--out", default="out/verified.jsonl")
    a = ap.parse_args()
    tx = {json.loads(l)["call_id"]: json.loads(l)["transcript"] for l in open(a.transcripts, encoding="utf-8")}
    rows = [json.loads(l) for l in open(a.extracted, encoding="utf-8")]
    n_fields = n_ok = 0
    pathlib.Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as g:
        for r in rows:
            t = norm(tx[r["call_id"]])
            fails = []
            for f in EVIDENCE_FIELDS:
                ev = r.get(f, "")
                if not ev:
                    continue
                n_fields += 1
                if norm(ev) in t:
                    n_ok += 1
                else:
                    fails.append(f)
            r["evidence_verified"] = not fails
            r["evidence_failures"] = fails
            g.write(json.dumps(r, ensure_ascii=False) + "\n")
            if fails:
                print(f"[FAIL] {r['call_id']}: {fails}")
    print(f"evidence fields checked: {n_fields}, verbatim match: {n_ok} ({n_ok / max(n_fields, 1):.1%})")


if __name__ == "__main__":
    main()

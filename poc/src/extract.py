"""Extract structured fields from call transcripts with the Claude API.

Usage:
  python -m src.extract --in samples/transcripts.jsonl --out out/extracted.jsonl

Requires credentials (ANTHROPIC_API_KEY, or an `ant auth login` profile).
The PoC results checked into samples/extracted.jsonl were produced by running the
same prompt interactively (see samples/README.md); this script is the automated path.
"""
from __future__ import annotations
import argparse, json, pathlib, datetime
import anthropic
from .schema import CallExtraction

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODEL = "claude-opus-5"
SCHEMA_VERSION = "0.2"
VOCAB_VERSION = "0.1"
PROMPT_VERSION = "p1"


def build_system() -> str:
    vocab = (ROOT / "vocab" / f"vocab_v{VOCAB_VERSION}.yaml").read_text(encoding="utf-8")
    tmpl = (ROOT / "prompts" / "extract_system.md").read_text(encoding="utf-8")
    return tmpl.replace("{{VOCAB_YAML}}", vocab)


def extract_one(client: anthropic.Anthropic, system: str, call: dict) -> dict:
    resp = client.messages.parse(
        model=MODEL,
        max_tokens=4000,
        system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        messages=[{"role": "user", "content": "次の通話を構造化してください。\n\n" + call["transcript"]}],
        output_format=CallExtraction,
        output_config={"effort": "medium"},
    )
    parsed: CallExtraction = resp.parsed_output
    row = parsed.model_dump()
    row.update(
        call_id=call["call_id"],
        schema_version=SCHEMA_VERSION,
        vocab_version=VOCAB_VERSION,
        prompt_version=PROMPT_VERSION,
        model=resp.model,
        extracted_at=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        input_tokens=resp.usage.input_tokens,
        output_tokens=resp.usage.output_tokens,
        cache_read_input_tokens=getattr(resp.usage, "cache_read_input_tokens", 0),
    )
    return row


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", default="samples/transcripts.jsonl")
    ap.add_argument("--out", default="out/extracted.jsonl")
    args = ap.parse_args()
    client = anthropic.Anthropic()
    system = build_system()
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.inp, encoding="utf-8") as f, open(out, "w", encoding="utf-8") as g:
        for line in f:
            call = json.loads(line)
            row = extract_one(client, system, call)
            g.write(json.dumps(row, ensure_ascii=False) + "\n")
            print(call["call_id"], row["reason_l2"], row["confusion_type"], row["resolution_status"])


if __name__ == "__main__":
    main()

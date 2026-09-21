#!/usr/bin/env python3
"""PreToolUse hook: docs 配下の編集を、承認済みの決定記録に基づく「適用」のときだけ許す。

入力: stdin に Claude Code の hook JSON({tool_name, tool_input, ...})
出力: 拒否するときは hookSpecificOutput.permissionDecision = "deny" を JSON で返す。許可は何も出さない。

規則(docs/decisions/README.md と CLAUDE.md に同じことが書いてある):
  1. docs/ 配下(docs/decisions/ を除く)の書き込みは、docs/decisions/APPLY が存在し、
     その adr が承認済みで、date が今日で、対象パスがその記録の「影響を受ける文書」に含まれるときだけ許す。
  2. docs/decisions/ の既存ファイルのうち「状態: 承認済み」のものは常に書き込み禁止(「覆された:」の 1 行追記は Edit で許す)。
     草案と新規ファイル、README.md、APPLY は自由。
  3. Bash は、コマンド文字列に docs/ が現れ、かつ書き込みらしい語が含まれるとき、文字列から docs/ のパスを拾って同じ検査をする。
"""
import json, os, re, sys, datetime, pathlib

ROOT = pathlib.Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()).resolve()
DEC = ROOT / "docs" / "decisions"
APPLY = DEC / "APPLY"
WRITE_TOKENS = re.compile(r"(>>?|\bsed\s+-i|\btee\b|\bmv\b|\bcp\b|\brm\b|write_text|\bopen\(|\bPath\(|\bshutil\b|\btruncate\b|\bcat\s*>)")
DOC_PATH = re.compile(r"docs/[\w./\-]+")

def deny(reason):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": reason}}, ensure_ascii=False))
    sys.exit(0)

def rel(p):
    try:
        return str(pathlib.Path(p).resolve().relative_to(ROOT))
    except Exception:
        return None

def adr_status(path):
    m = re.search(r"^- 状態:\s*(\S+)", path.read_text(encoding="utf-8"), re.M)
    return m.group(1) if m else None

def adr_affected(path):
    txt = path.read_text(encoding="utf-8")
    m = re.search(r"## 影響を受ける文書\n(.*?)(?:\n## |\Z)", txt, re.S)
    if not m: return []
    return [ln.strip()[2:].split("(")[0].strip() for ln in m.group(1).splitlines() if ln.strip().startswith("- ")]

def load_apply():
    if not APPLY.exists(): return None, "docs/decisions/APPLY がない(議論ターン。編集は承認後の適用ターンのみ)"
    kv = {}
    for ln in APPLY.read_text(encoding="utf-8").splitlines():
        if ":" in ln:
            k, v = ln.split(":", 1); kv[k.strip()] = v.strip()
    adr = kv.get("adr"); date = kv.get("date")
    if not adr or not date: return None, "APPLY に adr: と date: が要る"
    if date != datetime.date.today().isoformat(): return None, f"APPLY の日付 {date} が今日ではない"
    cands = sorted(DEC.glob(f"{adr}-*.md"))
    if not cands: return None, f"決定記録 {adr} がない"
    if adr_status(cands[0]) != "承認済み": return None, f"決定記録 {adr} が承認済みでない"
    return cands[0], None

def allowed_by(adr_file, target):
    for a in adr_affected(adr_file):
        a = a.rstrip("/")
        if target == a or target.startswith(a + "/"): return True
    return False

def check_target(target, tool, tool_input):
    if not target or not target.startswith("docs/"): return
    if target.startswith("docs/decisions/"):
        p = ROOT / target
        if p.name in ("README.md", "APPLY", "0000-template.md"): return
        if p.exists() and adr_status(p) == "承認済み":
            # 「覆された:」の 1 行追記だけは許す
            if tool == "Edit" and re.fullmatch(r"\s*- 覆された:.*\s*", (tool_input.get("new_string") or "").replace(tool_input.get("old_string") or "", "", 1)):
                return
            deny(f"{target} は承認済みの決定記録。書き換え禁止(覆すなら新しい記録を作る)")
        return
    adr_file, err = load_apply()
    if err: deny(f"{target} の編集を拒否: {err}")
    if not allowed_by(adr_file, target):
        deny(f"{target} は決定記録 {adr_file.name} の「影響を受ける文書」にない")

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    tool = data.get("tool_name", ""); ti = data.get("tool_input", {}) or {}
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        check_target(rel(ti.get("file_path", "")), tool, ti)
    elif tool == "Bash":
        cmd = ti.get("command", "") or ""
        if "docs/" in cmd and WRITE_TOKENS.search(cmd):
            for m in sorted(set(DOC_PATH.findall(cmd))):
                check_target(m.rstrip("."), tool, ti)

if __name__ == "__main__":
    main()

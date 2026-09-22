#!/usr/bin/env python3
"""PreToolUse hook: docs 配下の編集を、依頼者がチャットで承認したターン(適用ターン)だけに限る。

入力: stdin に Claude Code の hook JSON({tool_name, tool_input, ...})
出力: 拒否するときは hookSpecificOutput.permissionDecision = "deny" を JSON で返す。許可は何も出さない。

規則(CLAUDE.md §2 と同じ):
  1. docs/ 配下の書き込みは、docs/APPLY が存在し、date が今日で、承認: に依頼者の発言が書かれているときだけ許す。
     APPLY は依頼者の承認を受けたターンで作り、コミット後に消す(.gitignore 済み)。
  2. 例外(APPLY なしで書ける): docs/APPLY 自身、docs/history.md(履歴の追記)、docs/open_issues.md(未決の追記)。
  3. Bash は、コマンド文字列に docs/ が現れ、かつ書き込みらしい語が含まれるとき、文字列から docs/ のパスを拾って同じ検査をする。
"""
import json, os, re, sys, datetime, pathlib

ROOT = pathlib.Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()).resolve()
APPLY = ROOT / "docs" / "APPLY"
EXEMPT = {"docs/APPLY", "docs/history.md", "docs/open_issues.md"}
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

def apply_error():
    if not APPLY.exists(): return "docs/APPLY がない(議論ターン。編集は依頼者がチャットで承認したターンのみ)"
    kv = {}
    for ln in APPLY.read_text(encoding="utf-8").splitlines():
        if ":" in ln:
            k, v = ln.split(":", 1); kv[k.strip()] = v.strip()
    date = kv.get("date"); approval = kv.get("承認")
    if not date or not approval: return "APPLY に date: と 承認:(依頼者の発言の引用)が要る"
    if date != datetime.date.today().isoformat(): return f"APPLY の日付 {date} が今日ではない"
    return None

def check_target(target):
    if not target or not target.startswith("docs/"): return
    if target in EXEMPT: return
    err = apply_error()
    if err: deny(f"{target} の編集を拒否: {err}")

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    tool = data.get("tool_name", ""); ti = data.get("tool_input", {}) or {}
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        check_target(rel(ti.get("file_path", "")))
    elif tool == "Bash":
        cmd = ti.get("command", "") or ""
        if "docs/" in cmd and WRITE_TOKENS.search(cmd):
            for m in sorted(set(DOC_PATH.findall(cmd))):
                check_target(m.rstrip("."))

if __name__ == "__main__":
    main()

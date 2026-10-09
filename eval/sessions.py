"""Coding-agent messages (Codex sessions) as a timeline, and how each MyType record lines up with it:
the conversation just before (the "moment" context) and the user message just after (what was actually sent)."""
import glob, json, os
from datetime import datetime, timedelta
from difflib import SequenceMatcher

def ts(s): return datetime.fromisoformat(s.replace("Z", "+00:00"))

def text_of(payload):
    parts = payload.get("content") or []
    return "".join(p.get("text", "") for p in parts if isinstance(p, dict) and p.get("type") in ("input_text", "output_text", "text"))

def codex_messages(months=("2026/04", "2026/05")):
    out = []
    for m in months:
        for f in glob.glob(os.path.expanduser(f"~/.codex/sessions/{m}/*/*.jsonl")):
            cwd = None
            for line in open(f):
                try: o = json.loads(line)
                except Exception: continue
                p = o.get("payload") or {}
                if o.get("type") == "session_meta": cwd = p.get("cwd")
                if o.get("type") == "response_item" and p.get("type") == "message" and p.get("role") in ("user", "assistant"):
                    t = text_of(p).strip()
                    if t and not t.startswith("<environment_context>") and not t.startswith("# AGENTS.md"):
                        out.append({"at": ts(o["timestamp"]), "role": p["role"], "text": t, "cwd": cwd, "file": f})
    return sorted(out, key=lambda m: m["at"])

def similar(a, b): return SequenceMatcher(None, a, b).ratio()

def align(record, messages, before=timedelta(minutes=15), after=timedelta(minutes=3)):
    """The messages in the 15 minutes before the record, and the user message within 3 minutes after that matches it."""
    at = ts(record["createdAt"])
    prior = [m for m in messages if at - before <= m["at"] <= at]
    sent = None
    for m in messages:
        if m["role"] == "user" and at <= m["at"] <= at + after:
            score = similar(m["text"][:400], record["text"][:400])
            if score > 0.5 and (sent is None or score > sent[1]): sent = (m, score)
    return prior, sent

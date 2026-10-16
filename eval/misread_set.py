"""The older half of the misread-words eval set (docs/design-misread-words.md 二, step 2): English dictations into
coding agents from April–May, whose recordings are re-recognised by today's recognizer (data/q17-vocab.jsonl,
Qwen3-ASR 1.7B with the vocabulary, as the app runs it). The last 30 days into Claude come from context_set.py.
The context is rebuilt at dictation time: the session the dictation was sent into (a Codex session, which keeps both
sides, or Claude Code's history.jsonl, which keeps only the prompts), its last prompt and answer before it, cut as
ClaudeSessionLog.Exchange.text does. Dictations not found sent anywhere have no context and are left out.
  python3 misread_set.py <out-prefix>
writes <out-prefix>-transcripts.jsonl ({"id", "text"}), -gold.jsonl ({"id", "lang", "text": what was sent}),
-context.jsonl ({"id", "context"}) — the inputs polish_bench.py takes."""
import datetime, json, os, sys
from sent_align import claude_inputs, sent_part
from sessions import codex_messages

prefix = sys.argv[1]
records = json.load(open(os.path.expanduser("~/Library/Application Support/MyType/VoiceInput/history.json")))
raw = {o["id"]: o["text"] for o in map(json.loads, open("data/q17-vocab.jsonl"))}

def tail(s, n): return s if len(s) <= n else "…" + s[-(n - 1):]

def exchange_text(prompt, answer, prompt_last, limit=1500):
    """ClaudeSessionLog.Exchange.text (as context_set.py has it)"""
    p = tail(prompt, limit // 3) if prompt else None
    a = tail(answer, limit - len(p or "")) if answer else None
    parts = [f"User: {p}" if p else None, f"Claude: {a}" if a else None]
    if prompt_last: parts.reverse()
    return "\n\n".join(x for x in parts if x) or None

def ts(s): return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
def english(s): return sum(c.isascii() and c.isalpha() for c in s) > 0.6 * max(len(s.replace(" ", "")), 1)

codex = codex_messages()
for m in codex: m["t"] = m["at"].timestamp()
claude = claude_inputs()
projects = {}  # history.jsonl prompt time → project, for the prompts before it in the same project
for line in open(os.path.expanduser("~/.claude/history.jsonl"), errors="ignore"):
    try: o = json.loads(line)
    except ValueError: continue
    projects[o["timestamp"] / 1000] = o.get("project")

out = {k: open(f"{prefix}-{k}.jsonl", "w") for k in ("transcripts", "gold", "context")}
n = 0
for r in records:
    if r["createdAt"][:7] not in ("2026-04", "2026-05") or r["id"] not in raw or not english(raw[r["id"]]): continue
    t = ts(r["createdAt"])
    context = sent = None
    hit = next((m for m in codex if m["role"] == "user" and t - 5 <= m["t"] <= t + 900 and sent_part(r["text"].strip(), m["text"])), None)
    if hit:
        sent = sent_part(r["text"].strip(), hit["text"])
        prompt = answer = None; prompt_last = False
        for m in codex:
            if m["file"] != hit["file"] or m["t"] >= t: continue
            if m["role"] == "user": prompt, prompt_last = m["text"], True
            else: answer, prompt_last = m["text"], False
        context = exchange_text(prompt, answer, prompt_last)
    else:
        at = next((at for at, text in claude if t - 5 <= at <= t + 900 and sent_part(r["text"].strip(), text)), None)
        if at is not None:
            sent = sent_part(r["text"].strip(), next(text for a, text in claude if a == at))
            before = [text for a, text in claude if a < t and projects.get(a) == projects.get(at) and t - a < 3600]
            context = exchange_text(before[-1], None, True) if before else None
    if not context: continue
    out["transcripts"].write(json.dumps({"id": r["id"], "text": raw[r["id"]]}, ensure_ascii=False) + "\n")
    out["gold"].write(json.dumps({"id": r["id"], "lang": "en", "text": sent}, ensure_ascii=False) + "\n")
    out["context"].write(json.dumps({"id": r["id"], "context": context}, ensure_ascii=False) + "\n")
    n += 1
print(f"{n} English dictations from April–May with context")

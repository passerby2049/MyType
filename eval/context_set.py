"""An eval set for polish with the conversation as context (docs/design-misread-words.md 一): MyType's dictations into
the Claude desktop app that are found in a Code session's transcript (sent_align.sent_part, within 15 minutes), with
the reference being what was sent and the context being that session's last exchange just before the dictation —
cut the way ClaudeSessionLog.Exchange.text does. The session is the one it was sent into, so this measures what the
context does to the polish when the pick is right (the pick gives no context when unsure).
  python3 context_set.py <out-prefix> [days=30]
writes <out-prefix>-transcripts.jsonl, -gold.jsonl ({"id", "lang", "text"}), -context.jsonl ({"id", "context"})"""
import datetime, glob, json, os, sys, time
from sent_align import sent_part

prefix = sys.argv[1]
days = int(sys.argv[2]) if len(sys.argv) > 2 else 30
since = time.time() - days * 86400
records = json.load(open(os.path.expanduser("~/Library/Application Support/MyType/VoiceInput/history.json")))
records = [r for r in records if r.get("targetApp") == "Claude" and r.get("rawTranscript")
           and datetime.datetime.fromisoformat(r["createdAt"].replace("Z", "+00:00")).timestamp() >= since]

def ts(s): return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()

def human_prompt(o):
    """ClaudeSessionLog.humanPrompt"""
    if o.get("type") != "user" or o.get("isMeta"): return None
    kind = (o.get("origin") or {}).get("kind")
    if kind is not None and kind != "human": return None
    c = (o.get("message") or {}).get("content")
    if isinstance(c, list):
        if any(b.get("type") == "tool_result" for b in c): return None
        c = "\n".join(b.get("text", "") for b in c if b.get("type") == "text")
    if not isinstance(c, str): return None
    while "<system-reminder>" in c and "</system-reminder>" in c:
        a = c.index("<system-reminder>"); z = c.find("</system-reminder>", a)
        if z < 0: break
        c = c[:a] + c[z + len("</system-reminder>"):]
    c = c.strip()
    if kind is None and (c.startswith("<") or c.startswith("[Request interrupted")): return None
    return c or None

def assistant_text(o):
    if o.get("type") != "assistant": return None
    t = "\n".join(b.get("text", "") for b in (o.get("message") or {}).get("content") or [] if b.get("type") == "text").strip()
    return t or None

def tail(s, n): return s if len(s) <= n else "…" + s[-(n - 1):]

def exchange_text(prompt, answer, prompt_last, limit=1500):
    """ClaudeSessionLog.Exchange.text"""
    p = tail(prompt, limit // 3) if prompt else None
    a = tail(answer, limit - len(p or "")) if answer else None
    parts = [f"User: {p}" if p else None, f"Claude: {a}" if a else None]
    if prompt_last: parts.reverse()
    return "\n\n".join(x for x in parts if x) or None

# Every desktop prompt since, with its session; and each session's lines.
sessions, prompts = {}, []
for f in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
    if os.path.getmtime(f) < since: continue
    lines = []
    for line in open(f, errors="ignore"):
        try: o = json.loads(line)
        except ValueError: continue
        if "timestamp" not in o: continue
        lines.append(o)
        if o.get("entrypoint") == "claude-desktop" and (p := human_prompt(o)):
            prompts.append((ts(o["timestamp"]), p, o["sessionId"]))
    if lines: sessions[os.path.basename(f)[:-6]] = lines
prompts.sort()

out = {k: open(f"{prefix}-{k}.jsonl", "w") for k in ("transcripts", "gold", "context")}
n = with_context = 0
for r in records:
    t = ts(r["createdAt"])
    hit = next(((p, s) for at, text, s in prompts if t - 5 <= at <= t + 900 and (p := sent_part(r["text"].strip(), text))), None)
    if not hit: continue
    sent, session = hit
    prompt = answer = None; prompt_last = False; answer_msg = None
    for o in sessions.get(session, []):
        if ts(o["timestamp"]) >= t: break
        if (p := human_prompt(o)):
            prompt, prompt_last = p, True
        elif (a := assistant_text(o)):
            mid = (o.get("message") or {}).get("id")
            answer = answer + "\n\n" + a if mid and mid == answer_msg and answer else a
            answer_msg, prompt_last = mid, False
    context = exchange_text(prompt, answer, prompt_last)
    lang = "en" if sum(c.isascii() and c.isalpha() for c in sent) > 0.6 * max(len(sent.replace(" ", "")), 1) else "zh"
    out["transcripts"].write(json.dumps({"id": r["id"], "text": r["rawTranscript"]}, ensure_ascii=False) + "\n")
    out["gold"].write(json.dumps({"id": r["id"], "lang": lang, "text": sent}, ensure_ascii=False) + "\n")
    out["context"].write(json.dumps({"id": r["id"], "context": context}, ensure_ascii=False) + "\n")
    n += 1; with_context += context is not None
print(f"{len(records)} dictations into Claude in {days} days, {n} found in a transcript, {with_context} with context")

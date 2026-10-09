"""Which MyType records were sent on to Claude Code, and what was actually sent (prototype for docs/design-voice-log.md).
Matches each record from a coding app against ~/.claude/history.jsonl — what was submitted to Claude Code in the 15 minutes
after it — and cuts out the part that corresponds to the dictation.
  python3 sent_align.py [n]   prints the counts and the first n records that were edited before sending"""
import datetime, json, os, sys
from collections import Counter
from difflib import SequenceMatcher

CODING = {"Code", "Warp", "Zed", "Terminal", "Cursor", "Ghostty", "iTerm2"}

def claude_inputs():
    out = []
    for line in open(os.path.expanduser("~/.claude/history.jsonl"), errors="ignore"):
        try: o = json.loads(line)
        except ValueError: continue
        text = o.get("display") or ""
        for key, pasted in (o.get("pastedContents") or {}).items():
            if isinstance(pasted, dict) and pasted.get("content"):
                start = text.find(f"[Pasted text #{key}")
                end = text.find("]", start)
                if start >= 0 and end > start: text = text[:start] + pasted["content"] + text[end + 1:]
        out.append((o["timestamp"] / 1000, text))
    return sorted(out)

def is_word(c): return c.isascii() and (c.isalnum() or c == "'")

def sent_part(dictated, sent):
    """The part of `sent` that is this dictation, or None when it isn't in there."""
    blocks = [b for b in SequenceMatcher(None, dictated, sent, autojunk=False).get_matching_blocks() if b.size >= 4]
    if not blocks or max(b.size for b in blocks) < min(12, len(dictated) * 0.5): return None
    if sum(b.size for b in blocks) < 0.7 * len(dictated): return None
    a = max(blocks[0].b - blocks[0].a, 0)
    z = min(blocks[-1].b + blocks[-1].size + len(dictated) - blocks[-1].a - blocks[-1].size, len(sent))
    while a > 0 and is_word(sent[a - 1]) and is_word(sent[a]): a -= 1
    while 0 < z < len(sent) and is_word(sent[z - 1]) and is_word(sent[z]): z += 1
    part = sent[a:z].strip()
    return part if len(part) <= 1.5 * len(dictated) + 10 else None

def align(records, inputs):
    for r in records:
        if (r.get("targetApp") or "") not in CODING:
            yield r, "no source", None; continue
        t = datetime.datetime.fromisoformat(r["createdAt"].replace("Z", "+00:00")).timestamp()
        found = None
        for when, sent in inputs:
            if when < t - 5: continue
            if when > t + 900: break
            found = sent_part(r["text"].strip(), sent)
            if found: break
        if found is None: yield r, "not matched", None
        else: yield r, "sent as pasted" if found == r["text"].strip() else "edited", found

if __name__ == "__main__":
    records = json.load(open(os.path.expanduser("~/Library/Application Support/MyType/VoiceInput/history.json")))
    results = list(align(records, claude_inputs()))
    if sys.argv[1:] == ["--ids"]:
        for r, kind, sent in results: print(f"{r['id']}\t{kind}\t{(sent or '').replace(chr(10), chr(92) + 'n')}")
        sys.exit()
    print(dict(Counter(kind for _, kind, _ in results)))
    for r, kind, sent in [x for x in results if x[1] == "edited"][:int(sys.argv[1]) if len(sys.argv) > 1 else 20]:
        print(f"{r['createdAt'][:16]} {r.get('targetApp')}\n  pasted {r['text'][:110]!r}\n  sent   {sent[:110]!r}")

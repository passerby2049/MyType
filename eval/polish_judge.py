"""Blind pairwise judgement of two polish runs where no hand-checked reference exists (what was sent isn't one: it is
mostly the app's own polish, left as it was). For each transcript the two runs polished differently, Opus sees the raw
transcript, the conversation on screen and the two versions in random order, and says which is closer to what the
speaker actually said — recognition errors fixed, nothing added; fillers and smoothing don't count (the Medium mode
drops them on purpose) — and whether either added words that weren't said.
  python3 polish_judge.py <transcripts.jsonl> <context.jsonl> <a.jsonl> <b.jsonl> <out.jsonl> [workers=6]
prints wins for a / b / ties and how often each added something"""
import json, os, random, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

tr, ctx, a_path, b_path, out_path = sys.argv[1:6]
workers = int(sys.argv[6]) if len(sys.argv) > 6 else 6
raw = {o["id"]: o["text"] for o in map(json.loads, open(tr))}
context = {o["id"]: o["context"] for o in map(json.loads, open(ctx))}
A = {o["id"]: o["text"].strip() for o in map(json.loads, open(a_path))}
B = {o["id"]: o["text"].strip() for o in map(json.loads, open(b_path))}
ids = [i for i in A if i in B and A[i] != B[i]]
env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL") if k in os.environ}
env["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1"
env["PATH"] = f"/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:{os.path.expanduser('~/.local/bin')}"
cwd = tempfile.mkdtemp(prefix="polish-judge-")

RULES = """You judge speech-to-text post-processing. A speaker dictated a message (Chinese, English or a mix) to an AI
coding assistant. You get the raw recognizer output, the end of the conversation the speaker was replying to, and two
cleaned-up versions, 1 and 2. The cleanup is allowed to drop fillers and repetitions (然后, 就是, 那个, uh, um) and to
smooth phrasing and punctuation: ignore all of that. Judge only the words: which version has more of the recognition
errors fixed (misheard words, wrong homophones, garbled names and terms) and fewer correctly recognized words changed
into something else, and whether either version added names, facts or content that were not said (beyond fillers).
If the versions differ only in fillers, phrasing or punctuation, it's a tie. Answer with JSON only:
{"better": 1 | 2 | 0 (tie), "added_1": true|false, "added_2": true|false, "why": "<one short line>"}"""

def judge(i):
    flip = random.Random(i).random() < 0.5
    first, second = (B[i], A[i]) if flip else (A[i], B[i])
    prompt = (f"{RULES}\n\n<conversation>\n{context.get(i) or '(none)'}\n</conversation>\n\n<raw>\n{raw[i]}\n</raw>\n\n"
              f"<version_1>\n{first}\n</version_1>\n\n<version_2>\n{second}\n</version_2>")
    p = subprocess.run(["claude", "-p", "--model", "claude-opus-5-5", "--effort", "high", "--setting-sources", "project,local",
                        "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"],
                       input=prompt, capture_output=True, text=True, cwd=cwd, env=env, timeout=300)
    text = p.stdout.strip()
    try: v = json.loads(text[text.find("{"):text.rfind("}") + 1])
    except ValueError: return {"id": i, "error": text[:200]}
    better = {0: "tie", 1: "b" if flip else "a", 2: "a" if flip else "b"}.get(v.get("better"), "tie")
    added_a, added_b = (v.get("added_2"), v.get("added_1")) if flip else (v.get("added_1"), v.get("added_2"))
    return {"id": i, "better": better, "added_a": bool(added_a), "added_b": bool(added_b), "why": v.get("why", "")}

with ThreadPoolExecutor(workers) as pool:
    results = list(pool.map(judge, ids))
with open(out_path, "w") as f:
    for r in results: f.write(json.dumps(r, ensure_ascii=False) + "\n")
ok = [r for r in results if "better" in r]
count = lambda k, v: sum(r.get(k) == v for r in ok)
print(f"{len(A)} transcripts, {len(ids)} polished differently, {len(ok)} judged: "
      f"a better {count('better', 'a')}, b better {count('better', 'b')}, tie {count('better', 'tie')}; "
      f"added words not said: a {count('added_a', True)}, b {count('added_b', True)}")

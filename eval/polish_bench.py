"""Polish the way MyType does — one warm `claude -p` session (stream-json), the rules as its appended system prompt,
one transcript per turn with the app it goes into (and the conversation on screen, from context.jsonl: {"id",
"context"}, as LLMRewriter.sessionMessage puts it) — over transcripts, timing each turn.
python3 polish_bench.py <model> <effort> <system.txt> <transcripts.jsonl> <gold.jsonl> <out.jsonl> [app] [context.jsonl]
Only the ids in gold are sent. Same flags as ClaudeCodeVoicePolishSession.spawnProcess."""
import json, os, subprocess, sys, tempfile, time

model, effort, system_path, inp, gold_path, out_path = sys.argv[1:7]
app = sys.argv[7] if len(sys.argv) > 7 else "Zed"
contexts = {o["id"]: o["context"] for o in map(json.loads, open(sys.argv[8]))} if len(sys.argv) > 8 else {}
ids = [json.loads(l)["id"] for l in open(gold_path)]
texts = {o["id"]: o["text"] for o in map(json.loads, open(inp))}
env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL") if k in os.environ}
env["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1"
env["PATH"] = f"/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:{os.path.expanduser('~/.local/bin')}"
cwd = tempfile.mkdtemp(prefix="polish-bench-")
proc = subprocess.Popen(["claude", "-p", "--model", model, "--effort", effort, "--append-system-prompt", open(system_path).read(),
                         "--setting-sources", "project,local", "--tools", "",
                         "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
                         "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, cwd=cwd, env=env)

def turn(text):
    proc.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": text}}, ensure_ascii=False) + "\n")
    proc.stdin.flush()
    out = ""
    for line in proc.stdout:
        try: ev = json.loads(line)
        except Exception: continue
        if ev.get("type") == "assistant":
            for c in ev.get("message", {}).get("content", []):
                if c.get("type") == "text": out += c["text"]
        if ev.get("type") == "result":
            return out.strip(), ev
    raise RuntimeError("claude exited")

t0 = time.time(); turn(f"<app>{app}</app>\n<raw_transcript>\ntest\n</raw_transcript>"); seed_s = time.time() - t0
with open(out_path, "w") as f:
    for i in ids:
        context = f"<context>\n{contexts[i]}\n</context>\n" if contexts.get(i) else ""
        t = time.time(); text, ev = turn(f"<app>{app}</app>\n{context}<raw_transcript>\n{texts[i]}\n</raw_transcript>"); s = time.time() - t
        f.write(json.dumps({"id": i, "text": text, "seconds": s, "api_ms": ev.get("duration_api_ms")}, ensure_ascii=False) + "\n")
proc.stdin.close(); proc.wait(timeout=30)
print(f"{model} {effort}: first turn {seed_s:.1f}s")

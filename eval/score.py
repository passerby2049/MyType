"""Scores transcripts against the references (data/gold.jsonl: {"id", "text"}).
Character error rate over CJK characters, kana and Latin letters (spaces, punctuation, fillers dropped). Term hits:
the Latin words inside Chinese / Japanese references (the mixed-in terms we keep missing), found in the hypothesis or not.
  python3 score.py data/gold.jsonl name=file.jsonl ...   (file: {"id", "text"} per line; "raw"/"polished" read history)"""
import json, os, re, sys

FILLERS = {"嗯", "呃", "啊", "额", "唔", "uh", "um", "erm", "えー", "あの"}
CJK = "぀-ヿ㐀-鿿"
DIGITS = dict(zip("0123456789", "零一二三四五六七八九"))

def tokens(s):
    """Characters, with spelling that isn't an error made equal: case, spaces inside Latin text (SwiftUI / Swift UI,
    backup / back up), digits written as Chinese numerals in CJK text (8秒 / 八秒, 3.1 / 三点一)."""
    s = s.lower()
    for f in FILLERS: s = re.sub(rf"(?<![a-z]){re.escape(f)}(?![a-z])", " ", s)
    if re.search(f"[{CJK}]", s):
        s = re.sub(r"(?<=\d)\.(?=\d)", "点", s)
        s = "".join(DIGITS.get(c, c) for c in s)
    return re.findall(f"[a-z0-9']|[{CJK}]", s)

def edits(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]

def terms(ref):
    if not re.search(r"[぀-ヿ㐀-鿿]", ref): return []
    return [t.lower() for t in re.findall(r"[A-Za-z][A-Za-z0-9.+#-]*", ref)]

def load(path):
    if path in ("raw", "polished"):
        recs = json.load(open(os.path.expanduser("~/Library/Application Support/MyType/VoiceInput/history.json")))
        return {r["id"]: (r["rawTranscript"] if path == "raw" else r["text"]) for r in recs}
    return {o["id"]: o["text"] for o in map(json.loads, open(path))}

def score(gold, hyp):
    e = n = th = tn = 0
    for gid, ref in gold.items():
        h = hyp.get(gid)
        if h is None: continue
        r, t = tokens(ref), tokens(h)
        e += edits(r, t); n += len(r)
        for term in terms(ref):
            tn += 1; th += term in h.lower()
    return e / max(n, 1), th, tn

if __name__ == "__main__":
    gold = {o["id"]: o["text"] for o in map(json.loads, open(sys.argv[1]))}
    langs = {o["id"]: o.get("lang", "?") for o in map(json.loads, open(sys.argv[1]))}
    for arg in sys.argv[2:]:
        name, path = arg.split("=", 1)
        hyp = load(path)
        row = [name]
        for lang in ("zh", "en", "ja", None):
            sub = {k: v for k, v in gold.items() if lang is None or langs[k] == lang}
            if not sub: continue
            mer, th, tn = score(sub, hyp)
            row.append(f"{lang or 'all'} {mer*100:5.1f}%" + (f" terms {th}/{tn}" if tn else ""))
        print("  ".join(row))

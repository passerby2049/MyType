"""Scores the misread-words judgment (docs/design-misread-words.md 完成标准) against hand labels.
  python3 misread_score.py [answers]     e.g. "1a 2b 3a …" from data/listen-misread (the word heard on the recording)
Labels: data/mr-labels.jsonl, one per candidate ({"id", "pair": "heard>meant", "truth"}) plus the true pronunciation
misreads the local pass can't see ("candidate": false). A label that the recording decides has "listen": n and
"by_answer": the truth for each option (null: no misread there); without an answer the "truth" written is used, and
an answer 0 (couldn't tell) leaves the item out. Judgments: data/mr-a-judge.jsonl (last 30 days into Claude, full
context) and data/mr-b-judge.jsonl (April–May, context = the previous prompt only), from misread-check judge.
Precision: of the candidates judged "sound", how many are truly pronunciation. Recall: of the true pronunciation
misreads, how many were judged "sound" (with the right word)."""
import json, sys

answers = {}
for a in (sys.argv[1].split() if len(sys.argv) > 1 else []):
    answers[int(a[:-1])] = 0 if a[-1] == "0" else ord(a[-1]) - 96

def truth(label):
    n = label.get("listen")
    if n is None or n not in answers: return label["truth"]
    if answers[n] == 0: return "skip"
    return label["by_answer"][answers[n] - 1]

labels = [json.loads(l) for l in open("data/mr-labels.jsonl")]
for s in "ab":
    judged, sentences, with_candidates = {}, 0, 0
    for o in map(json.loads, open(f"data/mr-{s}-judge.jsonl")):
        sentences += 1
        with_candidates += bool(o["candidates"])
        for c, v in zip(o["candidates"], o.get("verdicts") or []):
            judged[(o["id"], f"{c['heard']}>{c['meant']}")] = v["kind"]
    mine = [l for l in labels if any(k[0] == l["id"] for k in judged) or (l.get("candidate") is False and s == "b")]
    flagged = [l for l in mine if judged.get((l["id"], l["pair"])) == "sound" and truth(l) != "skip"]
    right = [l for l in flagged if truth(l) == "sound"]
    real = [l for l in mine if truth(l) == "sound"]
    found = [l for l in real if judged.get((l["id"], l["pair"])) == "sound"]
    unlabelled = [k for k in judged if not any((l["id"], l["pair"]) == k for l in labels)]
    print(f"set {s}: {sentences} sentences, {with_candidates} with candidates, {len(judged)} candidates"
          + (f", {len(unlabelled)} unlabelled: {unlabelled}" if unlabelled else ""))
    print(f"  precision {len(right)}/{len(flagged)}   wrong: {[l['pair'] + '=' + str(truth(l)) for l in flagged if l not in right]}")
    print(f"  recall    {len(found)}/{len(real)}   missed: {[l['pair'] + ('' if l.get('candidate', True) else ' (not a candidate)') + ' judged ' + str(judged.get((l['id'], l['pair']))) for l in real if l not in found]}")
    kinds = {}
    for l in mine:
        if l.get("candidate", True): kinds.setdefault(truth(l), []).append(judged.get((l["id"], l["pair"])))
    print("  by true kind → judged: " + "; ".join(f"{k}: " + ", ".join(f"{j} {v.count(j)}" for j in sorted(set(map(str, v)))) for k, v in sorted(kinds.items(), key=lambda kv: str(kv[0]))))

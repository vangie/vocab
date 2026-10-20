#!/usr/bin/env python3
"""Pseudo-characters for the 识字量 test (LEXTALE_CH-style): a common left radical + a common right
component that never combine in any encoded character (checked against all ⿰ decompositions in
cjkvi-ids, https://github.com/cjkvi/cjkvi-ids). Writes Resources/Data/hanzi-pseudo.tsv (left, right).

    python3 scripts/build-pseudohanzi.py ids.txt
"""
import random, re, sys
from collections import Counter

LEFT = "氵亻扌木口女纟讠钅礻忄火土日月石王米足虫"
ids = {}
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("#"): continue
    f = line.rstrip("\n").split("\t")
    if len(f) < 3: continue
    ids[f[1]] = [re.sub(r"\[[^\]]*\]", "", x) for x in f[2:]]
existing = set()
for ch, vs in ids.items():
    for v in vs:
        if len(v) == 3 and v[0] == "⿰": existing.add((v[1], v[2]))
common = [l.split("\t")[0] for l in open("Resources/Data/hanzi-freq.tsv", encoding="utf-8") if not l.startswith("#")][:3500]
cset = set(common)
rights = Counter()
for ch in common:
    for v in ids.get(ch, []):
        if len(v) == 3 and v[0] == "⿰" and v[1] in LEFT and v[2] in cset: rights[v[2]] += 1
R = [r for r, n in rights.items() if n >= 4 and r not in "十广"]
cands = [(l, r) for l in LEFT for r in R if (l, r) not in existing]
random.seed(42); random.shuffle(cands)
out = cands[:400]
with open("Resources/Data/hanzi-pseudo.tsv", "w", encoding="utf-8") as fh:
    fh.write("# Pseudo-characters: left radical + right component never combined (cjkvi-ids). scripts/build-pseudohanzi.py\n")
    fh.write("".join(f"{l}\t{r}\n" for l, r in out))
print(len(R), "right components;", len(cands), "candidates;", len(out), "written; e.g.", " ".join(l + r for l, r in out[:12]))

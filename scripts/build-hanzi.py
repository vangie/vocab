#!/usr/bin/env python3
"""Build Resources/Data/hanzi-freq.tsv: the most frequent GB2312 characters (up to 8000) of Jun Da's
Modern Chinese Character Frequency List (现代汉语单字频率列表, MTSU), in rank order, with
their readings (tone-marked pinyin from the list's CEDICT column, '/'-separated).

    python3 scripts/build-hanzi.py [jd-modern.txt] [Unihan_IRGSources.txt]

Columns: char, readings, Kangxi radical number (Unicode Unihan kRSUnicode; 0 = unknown),
short English gloss (first CEDICT sense, fallback for the meaning check).
"""
import re, sys, unicodedata, urllib.request

URL = "https://lingua.mtsu.edu/chinese-computing/statistics/char/download.php?Which=MO"
N = 8000
MARKS = {"a": "āáǎà", "e": "ēéěè", "i": "īíǐì", "o": "ōóǒò", "u": "ūúǔù", "ü": "ǖǘǚǜ"}

def mark(syl):
    m = re.fullmatch(r"([a-zü:v]+)([1-5]?)", syl.lower())
    if not m: return None
    s, t = m.group(1).replace("u:", "ü").replace("v", "ü"), int(m.group(2) or 5)
    if t == 5: return s
    for v in ("a", "e"):
        if v in s: return s.replace(v, MARKS[v][t - 1], 1)
    if "ou" in s: return s.replace("o", MARKS["o"][t - 1], 1)
    for i in range(len(s) - 1, -1, -1):
        if s[i] in MARKS: return s[:i] + MARKS[s[i]][t - 1] + s[i + 1:]
    return s

raw = open(sys.argv[1], "rb").read() if len(sys.argv) > 1 else urllib.request.urlopen(URL, timeout=60).read()
text = raw.decode("gb18030", errors="replace")
radical = {}
if len(sys.argv) > 2:
    for l in open(sys.argv[2], encoding="utf-8"):
        if "\tkRSUnicode\t" in l:
            cp, _, v = l.rstrip("\n").split("\t")
            radical[chr(int(cp[2:], 16))] = int(v.split()[0].split(".")[0].rstrip("'"))
out = []
for line in text.splitlines():
    f = line.split("\t")
    if len(f) < 5 or not f[0].strip().isdigit(): continue
    ch = f[1].strip()
    if len(ch) != 1 or not unicodedata.name(ch, "").startswith("CJK UNIFIED"): continue
    try: ch.encode("gb2312")       # simplified, in common use: drops traditional/rare tail entries
    except UnicodeEncodeError: continue
    rs = []
    for r in f[4].split("/"):
        p = mark(r.strip())
        if p and p not in rs: rs.append(p)
    gloss = f[5].split("/")[0].strip() if len(f) > 5 else ""
    gloss = re.sub(r"\s+", " ", gloss)[:40]
    out.append(f"{ch}\t{'/'.join(rs)}\t{radical.get(ch, 0)}\t{gloss}")
    if len(out) == N: break
with open("Resources/Data/hanzi-freq.tsv", "w", encoding="utf-8") as fh:
    fh.write("# Jun Da, Modern Chinese Character Frequency List (MTSU); readings from CEDICT. Rank order.\n")
    fh.write("\n".join(out) + "\n")
print(len(out), "characters;", sum(1 for l in out if l.split("\t")[1] == ""), "without reading")

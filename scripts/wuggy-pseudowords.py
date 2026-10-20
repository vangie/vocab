import sys, random
from wuggy import WuggyGenerator
g = WuggyGenerator()
g.download_language_plugin('orthographic_english', auto_download=True)
g.load('orthographic_english')
words = [w.strip() for w in open(sys.argv[1]) if w.strip()]
out = []
for w in words:
    try:
        r = g.generate_classic([w], ncandidates_per_sequence=2, max_search_time_per_sequence=2)
    except Exception as e:
        continue
    for m in r:
        p = m['pseudoword']
        if p and p.isalpha() and p not in out: out.append(p); break
    print(w, out[-1] if out else '', flush=True)
open('pseudo-en.txt', 'w').write("\n".join(out) + "\n")

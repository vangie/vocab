import csv, sqlite3, re, random, os, sys
csv.field_size_limit(10**9)
TAGS = ['zk','gk','ky','cet4','cet6','ielts','toefl','gre']
allw = set(); rows = []
for r in csv.DictReader(open('ecdict.csv', encoding='utf-8')):
    w = r['word']; allw.add(w.lower())
    if not re.fullmatch(r'[a-z][a-z\-]*[a-z]', w): continue
    tags = set(r['tag'].split())
    mask = sum(1 << i for i, t in enumerate(TAGS) if t in tags)
    bnc = int(r['bnc'] or 0); frq = int(r['frq'] or 0)
    ex = r['exchange'] or ''
    lemma = None
    for part in ex.split('/'):
        if part.startswith('0:'): lemma = part[2:]
    rank = frq or bnc
    if not mask and not (0 < rank <= 25000): continue
    zh = (r['translation'] or '').replace('\\n', '\n').split('\n')
    zh = [z for z in zh if z and not z.startswith('[网络]')]
    z = '；'.join(zh)[:60]
    rows.append((w, mask, bnc, frq, lemma if lemma and lemma != w else None, z))
out = 'wordlists.sqlite'
if os.path.exists(out): os.remove(out)
db = sqlite3.connect(out)
db.executescript('''
CREATE TABLE words(word TEXT PRIMARY KEY, tags INTEGER NOT NULL, bnc INTEGER NOT NULL, frq INTEGER NOT NULL, lemma TEXT, zh TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE pseudowords(word TEXT PRIMARY KEY) WITHOUT ROWID;
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
''')
db.executemany('INSERT INTO words VALUES(?,?,?,?,?,?)', rows)
# Pseudowords: pronounceable CVC(C)V(C) strings absent from all of ECDICT (770k entries).
random.seed(20261020)
on = ['b','bl','br','c','cl','cr','d','dr','f','fl','fr','g','gl','gr','h','j','k','l','m','n','p','pl','pr','r','s','sc','sl','sm','sn','sp','st','str','t','tr','v','w','z']
vo = ['a','e','i','o','u','ea','ai','oa','ou']
co = ['b','ck','d','f','g','l','m','n','nd','nt','p','r','rt','s','sh','st','t','th','x']
suf = ['', '', 'le', 'er', 'ish', 'ent', 'ous', 'ate', 'ive', 'ure', 'ance', 'ly']
ps = set()
while len(ps) < 400:
    w = random.choice(on) + random.choice(vo) + random.choice(co) + random.choice(suf)
    if 5 <= len(w) <= 10 and w not in allw and w not in ps: ps.add(w)
db.executemany('INSERT INTO pseudowords VALUES(?)', [(p,) for p in sorted(ps)])
db.executemany('INSERT INTO meta VALUES(?,?)', [('source','ECDICT (MIT) github.com/skywind3000/ECDICT @ bc015ed'), ('tags',' '.join(TAGS))])
db.commit(); db.execute('VACUUM'); db.close()
print(len(rows), os.path.getsize(out))

"""Fit the material capacities of Last Bridge Standing from the rounds the script recorded.

Reads  <workspace>/BridgeData/rounds.jsonl  (every lane's bridge + how long it lasted), runs src/truss.lua on each bridge to get the force each beam sees
under a unit vehicle load, then searches the capacity table that best explains who lasted longest in each round (mean Spearman correlation inside a round).

    python tools/fit_capacity.py [path/to/rounds.jsonl]
"""
import json, math, random, sys
from pathlib import Path
import numpy as np
from lupa import LuaRuntime

root = Path(__file__).resolve().parent.parent
default = Path(r"C:\Users\vared\AppData\Local\Xeno\workspace\BridgeData\rounds.jsonl")
path = Path(sys.argv[1]) if len(sys.argv) > 1 else default

lua = LuaRuntime(unpack_returned_tuples=True)
Truss = lua.execute((root / "src" / "truss.lua").read_text(encoding="utf8"))


def analyse(beams_studs):
    """beams_studs: [[ax, ay, bx, by, mat, broken], ...] in studs -> (f, sign, mats) or None for a mechanism."""
    beams = [[b[0] / 2, b[1] / 2, b[2] / 2, b[3] / 2, b[4]] for b in beams_studs]
    xs = [v for b in beams for v in (b[0], b[2])]
    x0, x1 = min(xs), max(xs)
    road_nodes = set()
    for b in beams:
        if b[4] == "road" and abs(b[2] - b[0]) > 0.1:
            road_nodes.add((round(b[0] * 8), round(b[1] * 8)))
            road_nodes.add((round(b[2] * 8), round(b[3] * 8)))
    sup = lua.eval("function(x0, x1) return function(x, y) return math.abs(x - x0) < 0.01 or math.abs(x - x1) < 0.01 end end")(x0, x1)
    load_at = lua.eval("function(set) return function(x, y) return set[math.floor(x*8+0.5)..','..math.floor(y*8+0.5)] == true end end")(
        lua.table_from({f"{a},{b}": True for a, b in road_nodes}))
    lt = lua.table_from([lua.table_from(b) for b in beams])
    r = Truss.analyze(lt, lua.table(supports=sup, loadAt=load_at))
    if not r.ok:
        return None
    n = len(beams)
    return ([r.f[i + 1] for i in range(n)], [r.sign[i + 1] for i in range(n)], [b[4] for b in beams])


rounds = []
for line in path.read_text(encoding="utf8").splitlines():
    row = json.loads(line)
    lanes = []
    for l in row["lanes"]:
        if l.get("isGhost") or not l.get("beams"):
            continue
        a = analyse(l["beams"])
        lanes.append({"name": l["name"], "rank": l["rank"], "out": l.get("outWave") or 99, "prog": l.get("progress") or 0, "an": a, "cost": l["cost"]})
    rounds.append({"layout": row["layout"], "twist": row["twist"], "lanes": lanes})
print(f"{len(rounds)} rounds, {sum(len(r['lanes']) for r in rounds)} bridges, mechanisms: {sum(1 for r in rounds for l in r['lanes'] if l['an'] is None)}")


def lam(an, cap):
    if an is None:
        return 0.0
    f, sg, mats = an
    best = math.inf
    for fi, s, m in zip(f, sg, mats):
        if fi > 1e-9:
            k = cap[m][0 if s > 0 else 1]
            best = min(best, k / fi)
    return best if best < math.inf else 0.0


def ranks(a):
    order = np.argsort(a)
    r = np.empty(len(a))
    i = 0
    a_sorted = np.asarray(a)[order]
    while i < len(a):
        j = i
        while j + 1 < len(a) and a_sorted[j + 1] == a_sorted[i]:
            j += 1
        r[order[i:j + 1]] = (i + j) / 2
        i = j + 1
    return r


def score(cap):
    tot, cnt = 0.0, 0
    for rd in rounds:
        ls = rd["lanes"]
        if len(ls) < 4:
            continue
        outcome = [l["out"] + min(l["prog"], 99) / 1000 for l in ls]
        pred = [lam(l["an"], cap) for l in ls]
        ro, rp = ranks(outcome), ranks(pred)
        if ro.std() == 0 or rp.std() == 0:
            continue
        tot += float(np.corrcoef(ro, rp)[0, 1])
        cnt += 1
    return tot / max(cnt, 1)


def sample():
    lg = lambda lo, hi: math.exp(random.uniform(math.log(lo), math.log(hi)))
    return {
        "wood": (1.0, lg(0.2, 1.5)),
        "steel": (lg(1, 10), lg(0.5, 10)),
        "cable": (lg(0.5, 10), 0.0),
        "road": (lg(0.5, 10), lg(0.3, 10)),
    }


random.seed(7)
prior = {"wood": (1.0, 0.6), "steel": (3.0, 2.5), "cable": (2.0, 0.0), "road": (1.5, 1.2)}
print("prior capacity score:", round(score(prior), 3))
best, best_s = prior, score(prior)
for i in range(6000):
    c = sample()
    s = score(c)
    if s > best_s:
        best, best_s = c, s
print("best score:", round(best_s, 3))
for m, (t, c) in best.items():
    print(f"  {m:6s} tension {t:6.2f}  compression {c:6.2f}")
print("Lua table:")
print("Truss.cap = {")
for m, (t, c) in best.items():
    print(f"\t{m} = {{ t = {t:.2f}, c = {c:.2f} }},")
print("}")

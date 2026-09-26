"""Offline: Tempo-Rundkurse im UTG-Navgraphen finden (nie live im Spiel).
Station = Aufwaertskante (hop/vault) 2.4..15 Studs -> Spiel-Vault moeglich
(+7.8 Momentum). Rundkurs = Kreis aus 2..5 Stationen, Beine <= 3 s."""
import sys, heapq, math, json
KIND = {'w':'walk','s':'step','h':'hop','o':'roll','d':'drop','v':'vault','j':'jump','c':'climb','z':'zip','p':'pad','r':'rail'}
def load(path):
    lines = open(path, encoding='utf-8').read().split('\n')
    nodes = []
    for ln in lines[1:]:
        if '>' not in ln and not ln.strip():
            continue
        head, _, rest = ln.partition('>')
        try:
            x, y, z = map(float, head.split(','))
        except ValueError:
            continue
        edges = []
        for tok in rest.split(','):
            f = tok.split(':')
            if len(f) >= 3 and f[0].isdigit():
                edges.append((int(f[0]) - 1, KIND.get(f[1], f[1]), float(f[2])))
        nodes.append(((x, y, z), edges))
    return nodes
def main(path, maxleg=4.0, top=10):
    nodes = load(path)
    st, cells = [], set()
    for i, (p, es) in enumerate(nodes):
        for to, k, c in es:
            if k in ('hop', 'vault') and 0 <= to < len(nodes):
                q = nodes[to][0]; dy = q[1] - p[1]
                if 2.4 <= dy <= 15:
                    key = (int(p[0]//6), int(p[2]//6), int(p[1]//6))
                    if key in cells: continue
                    cells.add(key)
                    dx, dz = q[0]-p[0], q[2]-p[2]; m = math.hypot(dx, dz) or 1
                    st.append(dict(a=i, b=to, dy=dy, c=c, dir=(dx/m, dz/m)))
    by_start = {}
    for j, s in enumerate(st): by_start.setdefault(s['a'], []).append(j)
    bad = {'climb','zip','pad','rail','wallrun'}
    legs = []
    for i, s in enumerate(st):
        dist = {s['b']: 0.0}; par = {}; pk = {}; h = [(0.0, s['b'])]; done = set(); L = []
        while h:
            d, u = heapq.heappop(h)
            if u in done: continue
            done.add(u)
            if u != s['b'] and u in by_start:
                pu = par.get(u)
                turn = 0.0
                if pu is not None:
                    ax, az = nodes[u][0][0]-nodes[pu][0][0], nodes[u][0][2]-nodes[pu][0][2]
                    am = math.hypot(ax, az)
                    for j in by_start[u]:
                        if j == i: continue
                        if am > 0.1:
                            dot = (ax*st[j]['dir'][0] + az*st[j]['dir'][1]) / am
                            turn = math.degrees(math.acos(max(-1, min(1, dot))))
                        L.append((j, d, turn))
            for to, k, c in nodes[u][1]:
                if k in bad or not (0 <= to < len(nodes)): continue
                nd = d + c
                if nd < maxleg and nd < dist.get(to, 1e9):
                    dist[to] = nd; par[to] = u; pk[to] = k; heapq.heappush(h, (nd, to))
        # nur die 6 kuerzesten Beine ohne harten Knick: sonst explodiert die Kreissuche
        L = sorted([x for x in L if x[2] <= 110], key=lambda x: x[1])
        best = {}
        for x in L:
            if x[0] not in best: best[x[0]] = x
        # 3 kurze + 3 lange (>= 2 s): nur kurze Beine ergeben nur winzige Schleifen
        vals = list(best.values())
        longs = [x for x in vals if x[1] >= 2.0][-3:]
        kept = vals[:3] + [x for x in longs if x not in vals[:3]]
        legs.append(kept)
        # Knotenfolge je behaltenem Bein (ohne Start b, mit Ziel a_j)
        lp = {}
        for j, _, _ in kept:
            u = st[j]['a']; seq = []
            while u != s['b']:
                seq.append((u, pk.get(u, 'walk'))); u = par[u]
            lp[j] = seq[::-1]
        s['legpath'] = lp
    found, seen = [], set()
    def rec(start, cur, path, t, turns):
        for j, lt, turn in legs[cur]:
            tt = t + lt + st[j]['c']; tp = turns + (1 if turn > 110 else 0)
            if j == start and len(path) >= 2:
                per = tt / len(path)
                key = tuple(sorted(path))
                if per <= 2.8 and tt >= 4.0 and key not in seen:
                    seen.add(key)
                    found.append(dict(path=list(path), t=tt, n=len(path), per=per, turns=tp,
                                      score=len(path)/tt - 0.15*tp))
            elif len(path) < 5 and tt < 16 and j not in path:
                path.append(j); rec(start, j, path, tt, tp); path.pop()
    for i in range(len(st)): rec(i, i, [i], st[i]['c'], 0)
    found.sort(key=lambda c: -c['score'])
    nlegs = sum(len(l) for l in legs)
    print(f"{path.split('/')[-1]}: Knoten {len(nodes)}, Stationen {len(st)}, Beine {nlegs}, Kreise {len(found)}")
    for k, c in enumerate(found[:top]):
        p = nodes[st[c['path'][0]]['a']][0]
        hs = '/'.join(f"{st[x]['dy']:.0f}" for x in c['path'])
        print(f"  #{k+1} {c['n']} Vaults in {c['t']:.1f}s ({c['per']:.2f} s/Vault) Knicke>110: {c['turns']} Hoehen {hs} bei {p[0]:.0f},{p[1]:.0f},{p[2]:.0f}")
    # steady-state Momentum grob: +7.8 je Vault, -2.5/s, Deckel 35
    if found:
        c = found[0]; m = 0.0
        for _ in range(40):
            m = min(35, m + 7.8*c['n']) ; m = max(0, m - 2.5*c['t'])
        print(f"  Momentum-Gleichgewicht bester Kreis ~{m:.1f} (Tempo ~{32+m*1.056:.0f} statt 32)")
    return nodes, st, found

def export(path, out, keep=12):
    nodes, st, found = main(path, top=3)
    chosen, centers = [], []
    rej = {}
    for c in found:
        if c['turns'] > 0:
            rej['stationsknick'] = rej.get('stationsknick', 0) + 1; continue
        pts = []
        ok = True
        for idx, i in enumerate(c['path']):
            s = st[i]; nxt = st[c['path'][(idx + 1) % len(c['path'])]]
            j = c['path'][(idx + 1) % len(c['path'])]
            pts.append(list(nodes[s['a']][0]) + ['walk'])
            pts.append(list(nodes[s['b']][0]) + ['vault'])
            leg = s.get('legpath', {}).get(j)
            if leg is None: ok = False; break
            for u, k in leg[:-1]:
                pts.append(list(nodes[u][0]) + [k])
        if not ok or len(pts) < 4: continue
        cx = sum(p[0] for p in pts) / len(pts); cz = sum(p[2] for p in pts) / len(pts)
        cy = sum(p[1] for p in pts) / len(pts)
        # Umfang und Mindestradius: kleine Schleifen schneidet der Verfolger ab
        per_len = sum(math.dist(pts[i][:3], pts[(i+1) % len(pts)][:3]) for i in range(len(pts)))
        rad = sum(math.hypot(p[0]-cx, p[2]-cz) for p in pts) / len(pts)
        if per_len < 120 or rad < 14:
            rej['klein'] = rej.get('klein', 0) + 1; continue
        # scharfe Kurven auf der ganzen Runde (Segmente >= 3 Studs)
        heads = []
        for i in range(len(pts)):
            a, b = pts[i], pts[(i+1) % len(pts)]
            dx, dz = b[0]-a[0], b[2]-a[2]
            if math.hypot(dx, dz) >= 3: heads.append(math.atan2(dz, dx))
        sharp = 0
        for i in range(len(heads)):
            d = abs((heads[(i+1) % len(heads)] - heads[i] + math.pi) % (2*math.pi) - math.pi)
            if math.degrees(d) > 115: sharp += 1
        if sharp > 1:
            rej['knick'] = rej.get('knick', 0) + 1; continue
        # offene Mitte = Abkuerzung fuer den Verfolger
        open_mid = any(abs(q[0][1]-cy) < 6 and math.hypot(q[0][0]-cx, q[0][2]-cz) < 8 for q in nodes)
        if open_mid:
            rej['mitte_offen'] = rej.get('mitte_offen', 0) + 1; continue
        if any(math.hypot(cx - a, cz - b) < 25 for a, b in centers): continue
        centers.append((cx, cz))
        chosen.append(dict(n=c['n'], t=round(c['t'], 2), per=round(c['per'], 2), umfang=round(per_len), radius=round(rad),
                           pts=[[round(p[0], 1), round(p[1], 1), round(p[2], 1), p[3]] for p in pts]))
        if len(chosen) >= keep: break
    json.dump(dict(circuits=chosen), open(out, 'w'))
    print(f"  -> {len(chosen)} Rundkurse nach {out}  verworfen: {rej}")

if __name__ == '__main__':
    if len(sys.argv) > 2:
        export(sys.argv[1], sys.argv[2])
    else:
        main(sys.argv[1])

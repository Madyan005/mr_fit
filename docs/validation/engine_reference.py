"""Reference mirror (Python) of the Dart mock + MetricsEngine core, used to choose the
golden-test tolerances in mobile/test/domain/metrics_engine_golden_test.dart while no
Flutter SDK was available. NOT the engine: the Dart code is the source of truth.
Run: python docs/validation/engine_reference.py  (stdlib only).
"""
# Throwaway Python mirror of the Dart mock + MetricsEngine core (validation only).
import math, random

D = math.pi / 180
SHIN = THIGH = 0.2; TORSO = 0.25; UA = FA = 0.15; ANKLE_Y = 0.9; AHW = 0.08; SHW = 0.1; VMAX = 0.045; MPU = 2.25


def pose(ex, fL, fR, valgus=0.0, lean_extra=0.0):
    p = {}
    if ex in ("squat", "deadlift"):
        hips = []; lean = 0
        for side, f in ((-1, fL), (1, fR)):
            ankle = (0.5 + side * AHW, ANKLE_Y)
            k = f if ex == "squat" else 0.4 * f
            sb = (0.35 if ex == "squat" else 0.5) * k * D
            dx = SHIN * math.sin(sb) - side * valgus * VMAX
            dx = max(-0.95 * SHIN, min(0.95 * SHIN, dx))
            sa = math.asin(dx / SHIN)
            knee = (ankle[0] + dx, ankle[1] - math.sqrt(SHIN ** 2 - dx ** 2))
            ta = k * D - sa
            hip = (knee[0] - THIGH * math.sin(ta), knee[1] - THIGH * math.cos(ta))
            p[('ankle', side)] = ankle; p[('knee', side)] = knee; p[('hip', side)] = hip; hips.append(hip)
            lean += 0.35 * f if ex == "squat" else f - ta / D
        lean = lean / 2 + lean_extra
        up = (math.sin(lean * D), -math.cos(lean * D))
        for i, side in enumerate((-1, 1)):
            h = hips[i]; widen = side * (SHW - AHW) if ex == "squat" else 0
            s = (h[0] + TORSO * up[0] + widen, h[1] + TORSO * up[1]); p[('shoulder', side)] = s
            if ex == "deadlift":
                p[('elbow', side)] = (s[0], s[1] + UA); p[('wrist', side)] = (s[0], s[1] + UA + FA)
            else:
                p[('elbow', side)] = (s[0] + side * 0.05, s[1] + 0.06); p[('wrist', side)] = (s[0] + side * 0.03, s[1] - 0.01)
    else:  # bench
        for side, f in ((-1, fL), (1, fR)):
            s = (0.5 + side * SHW, 0.6); a = f / 2 * D
            e = (s[0] + side * UA * math.sin(a), s[1] - UA * math.cos(a)); w = (e[0] - side * FA * math.sin(a), e[1] - FA * math.cos(a))
            p[('shoulder', side)] = s; p[('elbow', side)] = e; p[('wrist', side)] = w
            p[('hip', side)] = (0.5 + side * 0.07, 0.45); p[('knee', side)] = (0.5 + side * 0.09, 0.36); p[('ankle', side)] = (0.5 + side * 0.1, 0.3)
    return p


def tracked_y(ex, f):
    p = pose(ex, f, f); key = 'shoulder' if ex == "squat" else 'wrist'
    return (p[(key, -1)][1] + p[(key, 1)][1]) / 2


def rom_m(ex, f): return abs(tracked_y(ex, f) - tracked_y(ex, 0)) * MPU


def flex_for(ex, d, maxf):
    lo, hi = 0, maxf
    for _ in range(40):
        m = (lo + hi) / 2
        if rom_m(ex, m) < d: lo = m
        else: hi = m
    return (lo + hi) / 2


def timeline(ex, reps, pre=1.0, ecc=1.0, bp=0.15, tp=0.8):
    segs = []; t = pre
    bottom = ex == "deadlift"
    for i, (mpv, depth, faults) in enumerate(reps):
        rom = rom_m(ex, depth); con = rom / mpv
        order = (("con", con), ("tp", tp), ("ecc", ecc), ("bp", bp)) if bottom else (("ecc", ecc), ("bp", bp), ("con", con), ("tp", tp))
        for ph, du in order:
            segs.append((i, ph, t, du, rom)); t += du
    return segs, t


def state(ex, segs, end, t):
    bottom = ex == "deadlift"
    if t < segs[0][2]: return (-1, 'pre', segs[0][4] if bottom else 0, 0, segs[0][4])
    if t >= end: return (-1, 'racked', segs[-1][4] if bottom else 0, 0, segs[-1][4])
    i, ph, st, du, rom = [s for s in segs if s[2] <= t][-1]; tau = t - st; w = math.pi / du; A = math.pi * rom / (2 * du)
    if ph == "con": return (i, ph, rom - A / w * (1 - math.cos(w * tau)), A * math.sin(w * tau), rom)
    if ph == "ecc": return (i, ph, A / w * (1 - math.cos(w * tau)), -A * math.sin(w * tau), rom)
    if ph == "bp": return (i, ph, rom, 0, rom)
    return (i, ph, 0, 0, rom)


def angle(a, b, c):
    ux, uy = a[0] - b[0], a[1] - b[1]; wx, wy = c[0] - b[0], c[1] - b[1]
    cs = (ux * wx + uy * wy) / (math.hypot(ux, uy) * math.hypot(wx, wy)); return math.degrees(math.acos(max(-1, min(1, cs))))


def read(p, ex):
    J = {'squat': ('hip', 'knee', 'ankle'), 'deadlift': ('shoulder', 'hip', 'knee'), 'bench_press': ('shoulder', 'elbow', 'wrist')}[ex]
    fl = [180 - angle(p[(J[0], s)], p[(J[1], s)], p[(J[2], s)]) for s in (-1, 1)]
    ratio = abs(p[('knee', -1)][0] - p[('knee', 1)][0]) / abs(p[('ankle', -1)][0] - p[('ankle', 1)][0])
    sx = (p[('shoulder', -1)][0] + p[('shoulder', 1)][0]) / 2; sy = (p[('shoulder', -1)][1] + p[('shoulder', 1)][1]) / 2
    hx = (p[('hip', -1)][0] + p[('hip', 1)][0]) / 2; hy = (p[('hip', -1)][1] + p[('hip', 1)][1]) / 2
    lean = math.degrees(math.atan2(abs(sx - hx), hy - sy))
    return sum(fl) / 2, abs(fl[0] - fl[1]) / (sum(fl) / 2) * 100, ratio, lean


def run(name, ex, cap, reps, seed=42, vision_only=False):
    rng = random.Random(seed); segs, end = timeline(ex, reps); dur = end + 3.5
    vel = []
    if not vision_only:
        for k in range(int(dur * 100)):
            t = k / 100; vel.append((t, state(ex, segs, end, t)[3] + 0.01 * rng.gauss(0, 1)))
    frames = []
    for k in range(int(dur * 30)):
        t = k / 30; i, ph, down, v, rom = state(ex, segs, end, t)
        if i < 0:
            f = (reps[0][1] if ph == 'pre' else reps[-1][1]) if ex == "deadlift" else 0; frac = 0; faults = set()
        else:
            f = flex_for(ex, down, reps[i][1] + 5); frac = 0 if ph == "tp" else min(1, down / rom); faults = reps[i][2]
        asym = 2.0 * frac
        p = pose(ex, f + asym / 2, f - asym / 2, valgus=frac if 'valgus' in faults else 0, lean_extra=30 * frac if 'lumbar' in faults else 0)
        p = {kk: (x + 0.002 * rng.gauss(0, 1), y + 0.002 * rng.gauss(0, 1)) for kk, (x, y) in p.items()}
        frames.append((t, p))
    if vision_only:
        key = 'shoulder' if ex == "squat" else 'wrist'; ys = [(t, (p[(key, -1)][1] + p[(key, 1)][1]) / 2) for t, p in frames]
        W = 5
        def sm(e): return sum(y for _, y in ys[e - W + 1:e + 1]) / W
        for n in range(8, len(ys)):
            yA, yB = sm(n - 4), sm(n); tA, tB = ys[n - 6][0], ys[n - 2][0]
            vel.append((ys[n - 4][0], -(yB - yA) * MPU / (tB - tA), n - 4))
        zc = 0.04
    else:
        zc = 0.015
    out = []; inc = False; st = 0; below = None
    for idx, item in enumerate(vel):
        t, v = item[0], item[1]
        if not inc:
            if v > 0.10:
                i = idx
                while i > 0 and vel[i - 1][1] > zc: i -= 1
                st = i - 1 if i > 0 else 0; inc = True; below = None
            continue
        if v < 0.05:
            below = t if below is None else below
            if v <= zc or t - below >= 0.3:
                seg = vel[st:idx + 1]; inc = False
                disp = sum((seg[j][1] + seg[j - 1][1]) / 2 * (seg[j][0] - seg[j - 1][0]) for j in range(1, len(seg)))
                d = seg[-1][0] - seg[0][0]
                mean = disp / d
                if vision_only:  # same as Dart: raw displacement between window ends pulled in by 2 frames
                    a, b = seg[0][2] + 2, seg[-1][2] - 2
                    if b - a < 2: continue
                    ya = sum(y for _, y in ys[a - 1:a + 2]) / 3; yb = sum(y for _, y in ys[b - 1:b + 2]) / 3
                    disp = (ya - yb) * MPU; mean = disp / (ys[b][0] - ys[a][0])
                if d >= 0.25 and disp >= (0.15 if ex in ('squat', 'deadlift') else 0.08): out.append((seg[0][0], seg[-1][0], mean))
        else:
            below = None
    res = []; prev_end = 0
    for (s, e, m) in out:
        win = [read(p, ex) for t, p in frames if prev_end <= t <= e]
        deep = max(win, key=lambda r: r[0]); prev_end = e
        faults = []
        if ex in ('squat', 'deadlift') and deep[2] < 0.75: faults.append('valgus')
        if ex in ('squat', 'deadlift') and deep[3] > {'squat': 55, 'deadlift': 75}[ex]: faults.append('lumbar')
        if deep[0] < {'squat': 85, 'deadlift': 60, 'bench_press': 80}[ex]: faults.append('rom')
        res.append((round(m, 3), round(deep[0], 1), round(deep[1], 1), faults))
    a = max(r[0] for r in res[:2]); b = res[-1][0]; vl = (a - b) / a * 100
    worst_v = max(abs(m - r[0]) for (m, *_), r in zip(res, reps)); worst_d = max(abs(dp - r[1]) for (_, dp, *_), r in zip(res, reps))
    ok_faults = all(set(fl) == set(r[2]) for (*_, fl), r in zip(res, reps))
    print(f"{name:14} reps={len(res)}/{len(reps)} VL={vl:5.1f} (cap {cap}) max|mpv err|={worst_v:.3f} max|depth err|={worst_d:.1f} faults_ok={ok_faults} SI={[r[2] for r in res]}")


C = [(0.62, 96, set()), (0.60, 95.5, set()), (0.59, 95, set()), (0.57, 94.5, set()), (0.55, 94, set())]
F = [(0.45, 88, set()), (0.43, 87.5, set()), (0.41, 87, set()), (0.38, 86, set()), (0.36, 84, set()), (0.34, 76, {'rom'})]
V = [(0.50, 93, set()), (0.49, 92, set()), (0.47, 92.5, {'valgus'}), (0.46, 91, {'valgus'})]
for seed in (42, 7, 123, 2026):
    print(f"=== seed {seed}")
    run("clean", "squat", 30, C, seed); run("fatigue", "bench_press", 20, F, seed); run("valgus", "squat", 20, V, seed)
print("=== vision-only (no bar_vel_z), seed 42")
run("clean/vision", "squat", 30, C, 42, vision_only=True)
run("fatigue/vision", "bench_press", 20, F, 42, vision_only=True)
print("=== deadlift smoke (lumbar on rep 3)")
run("deadlift", "deadlift", 20, [(0.55, 85, set()), (0.5, 84, set()), (0.45, 85, {'lumbar'})], 42)

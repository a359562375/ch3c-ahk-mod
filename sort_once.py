"""澄海3C 物品栏自动整理（无第三方库；抓一次原始像素，内存里切格，速度≈0.3秒）

用法：
  python sort_once.py register   把当前物品栏 6 格存成"标准布局"模板
  python sort_once.py sort       识别当前物品栏，算出归位所需的拖动顺序
"""
import ctypes, time, subprocess, os, sys, itertools
from ctypes import wintypes

BASE = os.path.dirname(os.path.abspath(__file__))
INI = os.path.join(BASE, "3C改建.ini")
TPL = os.path.join(BASE, "tpl")
WORK = os.path.join(BASE, "_sort")
SIZE = 52
SLOTS = ["item1", "item2", "item3", "item4", "item5", "item6"]
u = ctypes.windll.user32


def read_pos():
    pos, sec = {}, None
    with open(INI, "r", encoding="ascii", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("[") and line.endswith("]"):
                sec = line[1:-1]
                continue
            if sec == "pos" and "=" in line:
                k, v = line.split("=", 1)
                if "," in v:
                    x, y = v.split(",")[:2]
                    pos[k.strip()] = (int(x), int(y))
    return pos


def grab_raw():
    """抓一帧整屏，直接输出 RGB 原始像素（一次 ffmpeg，约 0.25 秒）。"""
    hwnd = u.FindWindowW("Warcraft III", None)
    if not hwnd:
        return None, 0, 0
    if u.GetForegroundWindow() != hwnd:
        if u.IsIconic(hwnd):
            u.ShowWindow(hwnd, 9)
            time.sleep(0.4)
        u.SetForegroundWindow(hwnd)
        time.sleep(0.30)          # 只需等它切到前台；本身就在前台时不等
    W = u.GetSystemMetrics(0)
    H = u.GetSystemMetrics(1)
    out = os.path.join(WORK, "full.raw")
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                    "-i", "ddagrab=0:framerate=60,hwdownload,format=bgra",
                    "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-y", out],
                   capture_output=True)
    if not os.path.exists(out):
        return None, 0, 0
    buf = open(out, "rb").read()
    if len(buf) < W * H * 3:
        return None, 0, 0
    return buf, W, H


def crop(buf, W, cx, cy, size=SIZE):
    x0 = max(0, min(W - size, cx - size // 2))
    y0 = max(0, min(len(buf) // (W * 3) - size, cy - size // 2))
    rows = []
    for y in range(y0, y0 + size):
        off = (y * W + x0) * 3
        rows.append(buf[off:off + size * 3])
    return b"".join(rows)


def mad(a, b, rows_keep=36):
    """只比对上半部分：避开图标右下角的堆叠数字（2→3 会让指纹漂移）。"""
    n = min(len(a), len(b))
    step = 3 * SIZE * 3          # 每 3 行取一行，够用了
    s = 0
    cnt = 0
    limit = min(n, rows_keep * SIZE * 3)
    i = 0
    while i < limit:
        s += abs(a[i] - b[i])
        cnt += 1
        i += step
    return s / max(cnt, 1)


def do_register():
    os.makedirs(WORK, exist_ok=True)
    pos = read_pos()
    t0 = time.time()
    buf, W, H = grab_raw()
    if not buf:
        print("抓屏失败"); return
    os.makedirs(TPL, exist_ok=True)
    for i, name in enumerate(SLOTS, 1):
        x, y = pos[name]
        d = crop(buf, W, x, y)
        open(os.path.join(TPL, f"c{i}.raw"), "wb").write(d)
    print("已登记 6 格，用时 %.2fs" % (time.time() - t0))


def do_sort():
    pos = read_pos()
    t0 = time.time()
    buf, W, H = grab_raw()
    if not buf:
        print("抓屏失败"); return
    cur = [crop(buf, W, *pos[name]) for name in SLOTS]
    tpl = []
    for i in range(1, 7):
        p = os.path.join(TPL, f"c{i}.raw")
        if not os.path.exists(p):
            print("模板缺失:", p); return
        tpl.append(open(p, "rb").read())

    cost = [[mad(cur[s], tpl[t]) for t in range(6)] for s in range(6)]
    best, bestc = None, 1e18
    for perm in itertools.permutations(range(6)):
        c = sum(cost[s][perm[s]] for s in range(6))
        if c < bestc:
            bestc, best = c, perm

    where = [0] * 6
    for s, t in enumerate(best):
        where[t] = s

    moves, sim = [], where[:]
    for target in range(6):
        src = sim[target]
        if src == target:
            continue
        moves.append(f"{src+1}>{target+1}")
        sim[src], sim[target] = sim[target], sim[src]

    with open(os.path.join(BASE, "moves.txt"), "w", encoding="ascii") as f:
        f.write("\n".join(moves))
    print("匹配差:", [round(cost[s][best[s]], 1) for s in range(6)])
    print("拖动计划:", moves if moves else "无需整理")
    print("用时 %.2fs" % (time.time() - t0))


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "sort"
    do_register() if mode == "register" else do_sort()

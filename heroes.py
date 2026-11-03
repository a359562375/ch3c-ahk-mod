"""识别魔兽左上角几个英雄头像（多指标 + 空槽基准，无第三方库）

用法：
  python heroes.py count     识别，输出 heroes.txt（如 "1,1,0"）
  python heroes.py baseline  采"空槽基准"（此刻某槽没英雄时用，最准）

判定思路（不靠单一阈值）：
  1) 结构差异：把 44x44 切成 4x4 块，比较每块平均色 → 对整体明暗不敏感，只对"图案"敏感
  2) 边缘密度：头像是彩绘，有五官轮廓；空槽基本是平整的边框
  3) 饱和度：彩色头像 > 灰调空槽
  有基准时用 (1) 为主，没基准时用 (2)+(3) 兜底。
"""
import ctypes, time, subprocess, os, sys
from ctypes import wintypes

BASE = os.path.dirname(os.path.abspath(__file__))
INI = os.path.join(BASE, "3C改建.ini")
WORK = os.path.join(BASE, "_sort")
TPL = os.path.join(BASE, "tpl")
SIZE = 44
GRID = 4                      # 4x4 块
KEYS = ["hero1", "hero2", "hero3", "hero4", "hero5"]
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
    hwnd = u.FindWindowW("Warcraft III", None)
    if not hwnd:
        return None, 0
    if u.GetForegroundWindow() != hwnd:
        if u.IsIconic(hwnd):
            u.ShowWindow(hwnd, 9)
            time.sleep(0.4)
        u.SetForegroundWindow(hwnd)
        time.sleep(0.30)
    W = u.GetSystemMetrics(0)
    os.makedirs(WORK, exist_ok=True)
    out = os.path.join(WORK, "hero.raw")
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                    "-i", "ddagrab=0:framerate=60,hwdownload,format=bgra",
                    "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-y", out],
                   capture_output=True)
    if not os.path.exists(out):
        return None, 0
    buf = open(out, "rb").read()
    return (buf, W) if len(buf) > W * 100 else (None, 0)


def crop(buf, W, cx, cy, size=SIZE):
    H = len(buf) // (W * 3)
    x0 = max(0, min(W - size, cx - size // 2))
    y0 = max(0, min(H - size, cy - size // 2))
    rows = []
    for y in range(y0, y0 + size):
        off = (y * W + x0) * 3
        rows.append(buf[off:off + size * 3])
    return b"".join(rows)


def lum(d):
    return [(d[i] * 299 + d[i + 1] * 587 + d[i + 2] * 114) // 1000
            for i in range(0, len(d), 3)]


def block_means(d, size=SIZE, grid=GRID):
    """返回 grid*grid 个块的平均 RGB（扁平列表）"""
    out = []
    bs = size // grid
    for by in range(grid):
        for bx in range(grid):
            rs = gs = bs_ = 0
            n = 0
            for y in range(by * bs, (by + 1) * bs):
                row = y * size * 3
                for x in range(bx * bs, (bx + 1) * bs):
                    i = row + x * 3
                    rs += d[i]; gs += d[i + 1]; bs_ += d[i + 2]
                    n += 1
            out += [rs / n, gs / n, bs_ / n]
    return out


def edge_density(d, size=SIZE):
    L = lum(d)
    cnt = 0
    tot = 0
    for y in range(1, size):
        for x in range(1, size):
            i = y * size + x
            dx = abs(L[i] - L[i - 1])
            dy = abs(L[i] - L[i - size])
            if dx + dy > 40:
                cnt += 1
            tot += 1
    return cnt / max(tot, 1)


def mean_sat(d):
    n = len(d) // 3
    s = 0
    for i in range(0, n * 3, 3):
        r, g, b = d[i], d[i + 1], d[i + 2]
        mx, mn = max(r, g, b), min(r, g, b)
        s += 0 if mx == 0 else (mx - mn) / mx
    return s / max(n, 1)


def struct_dist(a, b):
    """两块图像的结构差异（块平均色的平均绝对差）"""
    ma, mb = block_means(a), block_means(b)
    return sum(abs(ma[i] - mb[i]) for i in range(len(ma))) / len(ma)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "count"
    pos = read_pos()
    avail = [k for k in KEYS if k in pos]        # 只处理已校准的槽，缺的跳过
    missing = [k for k in KEYS if k not in pos]
    if not avail:
        print("没有任何头像坐标 → 先按 F4 校准英雄头像")
        open(os.path.join(BASE, "heroes.txt"), "w").write("")
        return
    if missing:
        print("提示：这些槽还没校准，跳过", missing)
    buf, W = grab_raw()
    if not buf:
        print("抓屏失败")
        open(os.path.join(BASE, "heroes.txt"), "w").write("")
        return
    crops = []
    for k in avail:
        x, y = pos[k]
        crops.append(crop(buf, W, x, y))

    os.makedirs(TPL, exist_ok=True)
    bpath = os.path.join(TPL, "hero_empty.raw")

    if mode == "baseline":
        # 取三槽里"最平"的那个当空槽基准
        edges = [edge_density(c) for c in crops]
        idx = edges.index(min(edges))
        open(bpath, "wb").write(crops[idx])
        open(os.path.join(BASE, "heroes.txt"), "w").write("")
        print("已把第 %d 槽采为空槽基准  edge=%.3f" % (idx + 1, edges[idx]))
        return

    base = open(bpath, "rb").read() if os.path.exists(bpath) else None
    mask, detail = [], []
    for i, c in enumerate(crops):
        sd = struct_dist(c, base) if base else -1
        ed = edge_density(c)
        sa = mean_sat(c)
        if base:
            # 有基准：结构差异为主，边缘/饱和度为辅
            score = sd
            hit = (sd > 12.0) or (sd > 7.0 and ed > 0.16)
            detail.append("槽%d 结构差=%.1f 边缘=%.2f 饱和=%.2f %s" % (i + 1, sd, ed, sa, "有" if hit else "空"))
        else:
            hit = (ed > 0.18 and sa > 0.28)
            detail.append("槽%d 无基准 边缘=%.2f 饱和=%.2f %s" % (i + 1, ed, sa, "有" if hit else "空"))
        mask.append(1 if hit else 0)

    open(os.path.join(BASE, "heroes.txt"), "w", encoding="ascii").write(",".join(map(str, mask)))
    for line in detail:
        print(line)
    print("英雄分布:", mask)


if __name__ == "__main__":
    main()

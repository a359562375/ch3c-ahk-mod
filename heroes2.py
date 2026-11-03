"""英雄/物品名字登记与按名字找英雄（无第三方库）

用法：
  python heroes.py tag            抓一帧，把 3 个头像按 [heronames] 存成指纹
  python heroes.py find 牛头      抓一帧，找出"牛头"现在在第几槽，写入 heroes.txt
"""
import ctypes, time, subprocess, os, sys
from ctypes import wintypes

BASE = os.path.dirname(os.path.abspath(__file__))
INI = os.path.join(BASE, "3C改建.ini")
WORK = os.path.join(BASE, "_sort")
TPL = os.path.join(BASE, "tpl")
SIZE = 48
KEYS = ["hero1", "hero2", "hero3", "hero4", "hero5"]
u = ctypes.windll.user32


def ini_read(section, key, default=""):
    try:
        raw = open(INI, "rb").read()
        text = None
        for enc in ("utf-8", "ascii", "gbk", "utf-16"):
            try:
                text = raw.decode(enc)
                break
            except Exception:
                continue
        if text is None:
            return default
        cur = None
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            if line.startswith("[") and line.endswith("]"):
                cur = line[1:-1]
                continue
            if cur == section and "=" in line:
                k, v = line.split("=", 1)
                if k.strip() == key:
                    return v.strip()
    except Exception:
        pass
    return default


# 槽位 → 英文代号（ASCII，避免中文参数在命令行里乱码）
# 1=圣骑 shengqi  2=牛头 niu  3=小黑 xiaohei
DEFAULT_KEYS = ["shengqi", "niu", "xiaohei", "", ""]


def hero_keys():
    keys = []
    for i in range(1, len(KEYS) + 1):
        keys.append(ini_read("cfg", f"herokey{i}", DEFAULT_KEYS[i - 1]))
    return keys


def read_pos():
    pos = {}
    for i, k in enumerate(KEYS, 1):
        v = ini_read("pos", k, "")
        if "," in v:
            x, y = v.split(",")[:2]
            pos[k] = (int(x), int(y))
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
    out = os.path.join(WORK, "herofind.raw")
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


def block_means(d, size=SIZE, grid=4):
    out, bs = [], size // grid
    for by in range(grid):
        for bx in range(grid):
            s = n = 0
            for y in range(by * bs, (by + 1) * bs):
                row = y * size * 3
                for x in range(bx * bs, (bx + 1) * bs):
                    s += d[row + x * 3]
                    n += 1
            out.append(s / max(n, 1))
    return out


def dist(a, b):
    ma, mb = block_means(a), block_means(b)
    return sum(abs(ma[i] - mb[i]) for i in range(len(ma))) / len(ma)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "tag"
    pos = read_pos()
    if len(pos) < 3:
        print("头像未校准")
        return
    buf, W = grab_raw()
    if not buf:
        print("抓屏失败")
        return
    crops = {k: crop(buf, W, *pos[k]) for k in KEYS if k in pos}
    used = [k for k in KEYS if k in crops]
    if not crops:
        print("头像未校准")
        return
    os.makedirs(TPL, exist_ok=True)

    if mode == "tag":
        saved = []
        keys = hero_keys()
        for i, k in enumerate(KEYS, 1):
            key = keys[i - 1]
            if key and k in crops:
                p = os.path.join(TPL, f"hero_{key}.raw")
                open(p, "wb").write(crops[k])
                saved.append(f"槽{i}={key}")
        print("已登记:", "，".join(saved) if saved else "（没有代号）")
        return

    if mode == "find":
        name = sys.argv[2] if len(sys.argv) > 2 else ""
        p = os.path.join(TPL, f"hero_{name}.raw")
        if not os.path.exists(p):
            print("没有登记过:", name)
            open(os.path.join(BASE, "heroes.txt"), "w").write("0")
            return
        tpl = open(p, "rb").read()
        ds = [(int(k[4:]), round(dist(crops[k], tpl), 1)) for k in used]
        best_slot, best_diff = min(ds, key=lambda x: x[1])
        print("各槽与", name, "的差异:", ds)
        best = best_slot if best_diff <= 12 else 0
        open(os.path.join(BASE, "heroes.txt"), "w", encoding="ascii").write(str(best))
        print("→ 判定在", best, "号槽（最小差异 %.1f）" % best_diff)
        return


if __name__ == "__main__":
    main()

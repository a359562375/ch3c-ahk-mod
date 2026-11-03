"""物品图标指纹登记 / 按名字找物品（无第三方库）

用法：
  python items.py register     抓一帧，按 [cfg] itemkey1..6 存 6 格图标指纹
  python items.py find 蓝棒代号  抓一帧，找该物品在第几格，写入 items.txt
  python items.py list         抓一帧，打印 6 格分别匹配到哪个已知物品（诊断用）
"""
import ctypes, time, subprocess, os, sys
from ctypes import wintypes

BASE = os.path.dirname(os.path.abspath(__file__))
INI = os.path.join(BASE, "3C改建.ini")
WORK = os.path.join(BASE, "_sort")
TPL = os.path.join(BASE, "tpl")
SIZE = 52
SLOTS = ["item1", "item2", "item3", "item4", "item5", "item6"]
u = ctypes.windll.user32

# 代号 → 中文（仅注释用，脚本内部只用 ASCII 代号）
# 1 chuansong=传送  2 chenmo=沉默  3 chuifeng=吹风
# 4 xuebang=血棒    5 fuhuo=复活    6 lanbang=蓝棒
DEFAULT_KEYS = ["chuansong", "chenmo", "chuifeng", "xuebang", "fuhuo", "lanbang"]


def ini_read(section, key, default=""):
    try:
        raw = open(INI, "rb").read()
        text = None
        for enc in ("ascii", "utf-8", "gbk", "utf-16"):
            try:
                text = raw.decode(enc); break
            except Exception:
                continue
        if not text:
            return default
        cur = None
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            if line.startswith("[") and line.endswith("]"):
                cur = line[1:-1]; continue
            if cur == section and "=" in line:
                k, v = line.split("=", 1)
                if k.strip() == key:
                    return v.strip()
    except Exception:
        pass
    return default


def read_pos():
    pos = {}
    for k in SLOTS:
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
            u.ShowWindow(hwnd, 9); time.sleep(0.55)
        u.SetForegroundWindow(hwnd); time.sleep(0.55)
    W = u.GetSystemMetrics(0)
    os.makedirs(WORK, exist_ok=True)
    out = os.path.join(WORK, "item.raw")
    if os.path.exists(out):
        os.remove(out)                      # 先删旧帧，免得 ffmpeg 失败时读到上一次的画面
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
    return b"".join(buf[(y * W + x0) * 3:(y * W + x0 + size) * 3] for y in range(y0, y0 + size))


def block_means(d, size=SIZE, grid=4):
    out, bs = [], size // grid
    for by in range(grid):
        for bx in range(grid):
            s = n = 0
            for y in range(by * bs, (by + 1) * bs):
                row = y * size * 3
                for x in range(bx * bs, (bx + 1) * bs):
                    s += d[row + x * 3]; n += 1
            out.append(s / max(n, 1))
    return out


def dist(a, b):
    ma, mb = block_means(a), block_means(b)
    return sum(abs(ma[i] - mb[i]) for i in range(len(ma))) / len(ma)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "register"
    pos = read_pos()
    if len(pos) < 6:
        print("物品格坐标不全")
        return
    buf, W = grab_raw()
    if not buf:
        print("抓屏失败"); return
    crops = [crop(buf, W, *pos[k]) for k in SLOTS]
    os.makedirs(TPL, exist_ok=True)

    if mode == "register":
        saved = []
        for i in range(6):
            key = ini_read("cfg", f"itemkey{i+1}", DEFAULT_KEYS[i])
            if key and key != "none":
                open(os.path.join(TPL, f"item_{key}.raw"), "wb").write(crops[i])
                saved.append(f"格{i+1}={key}")
        print("已登记:", "，".join(saved))
        return

    if mode == "find":
        key = sys.argv[2] if len(sys.argv) > 2 else ""
        p = os.path.join(TPL, f"item_{key}.raw")
        if not os.path.exists(p):
            print("没有登记过:", key)
            open(os.path.join(BASE, "items.txt"), "w").write("0"); return
        tpl = open(p, "rb").read()
        ds = [round(dist(c, tpl), 1) for c in crops]
        best = ds.index(min(ds)) + 1
        if min(ds) > 12:
            best = 0
        open(os.path.join(BASE, "items.txt"), "w", encoding="ascii").write(str(best))
        print("各格差异:", ds, "→", key, "在", best, "格")
        return

    if mode == "list":
        for i in range(6):
            row = []
            for k in range(6):
                key = ini_read("cfg", f"itemkey{k+1}", DEFAULT_KEYS[k])
                p = os.path.join(TPL, f"item_{key}.raw")
                if os.path.exists(p):
                    row.append((round(dist(crops[i], open(p, "rb").read()), 1), key))
            row.sort()
            print(f"格{i+1}: " + "  ".join(f"{k}={d}" for d, k in row[:3]))
        return


if __name__ == "__main__":
    main()

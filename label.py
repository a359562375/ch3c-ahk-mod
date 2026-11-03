"""抓一帧，切出物品栏 6 格 + 英雄头像 3 格，生成两张预览图，供人工/模型识别。
用法：python label.py
输出：_sort/items.png（横排）、_sort/heroes.png（竖排）
"""
import ctypes, time, subprocess, os
from ctypes import wintypes

BASE = os.path.dirname(os.path.abspath(__file__))
INI = os.path.join(BASE, "3C改建.ini")
WORK = os.path.join(BASE, "_sort")
ITEM_SIZE, HERO_SIZE = 52, 48
ITEM_KEYS = ["item1", "item2", "item3", "item4", "item5", "item6"]
HERO_KEYS = ["hero1", "hero2", "hero3"]
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
        time.sleep(0.35)
    W = u.GetSystemMetrics(0)
    os.makedirs(WORK, exist_ok=True)
    out = os.path.join(WORK, "label.raw")
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                    "-i", "ddagrab=0:framerate=60,hwdownload,format=bgra",
                    "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-y", out],
                   capture_output=True)
    if not os.path.exists(out):
        return None, 0
    buf = open(out, "rb").read()
    return (buf, W) if len(buf) > W * 100 else (None, 0)


def crop_raw(buf, W, cx, cy, size):
    H = len(buf) // (W * 3)
    x0 = max(0, min(W - size, cx - size // 2))
    y0 = max(0, min(H - size, cy - size // 2))
    rows = []
    for y in range(y0, y0 + size):
        off = (y * W + x0) * 3
        rows.append(buf[off:off + size * 3])
    return b"".join(rows)


def raw2png(rawpath, w, h, out):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "rawvideo",
                    "-pix_fmt", "rgb24", "-s", f"{w}x{h}", "-i", rawpath, "-y", out],
                   capture_output=True)
    return out


def main():
    pos = read_pos()
    buf, W = grab_raw()
    if not buf:
        print("抓屏失败"); return
    made_i, made_h = [], []
    for i, k in enumerate(ITEM_KEYS, 1):
        if k not in pos:
            continue
        x, y = pos[k]
        rp = os.path.join(WORK, f"i{i}.raw")
        open(rp, "wb").write(crop_raw(buf, W, x, y, ITEM_SIZE))
        made_i.append(raw2png(rp, ITEM_SIZE, ITEM_SIZE, os.path.join(WORK, f"i{i}.png")))
    for i, k in enumerate(HERO_KEYS, 1):
        if k not in pos:
            continue
        x, y = pos[k]
        rp = os.path.join(WORK, f"h{i}.raw")
        open(rp, "wb").write(crop_raw(buf, W, x, y, HERO_SIZE))
        made_h.append(raw2png(rp, HERO_SIZE, HERO_SIZE, os.path.join(WORK, f"h{i}.png")))

    if made_i:
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error"]
        for p in made_i:
            cmd += ["-i", p]
        cmd += ["-filter_complex", f"hstack=inputs={len(made_i)}", "-y", os.path.join(WORK, "items.png")]
        subprocess.run(cmd, capture_output=True)
        print("物品栏预览:", os.path.join(WORK, "items.png"))
    if made_h:
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error"]
        for p in made_h:
            cmd += ["-i", p]
        # 竖排：英雄头像在屏幕上是上下排列
        cmd += ["-filter_complex", f"vstack=inputs={len(made_h)}", "-y", os.path.join(WORK, "heroes.png")]
        subprocess.run(cmd, capture_output=True)
        print("英雄头像预览:", os.path.join(WORK, "heroes.png"))
    print("物品格数:", len(made_i), " 英雄格数:", len(made_h))


if __name__ == "__main__":
    main()

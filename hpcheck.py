# -*- coding: utf-8 -*-
"""读 5 个英雄的血量（从左上角头像下方的绿色血条）。

用法：python hpcheck.py
输出 hp_state.txt：  hp1=100 hp2=85 hp3=100 hp4=42 hp5=100  min=42 slot=4 low=1

血条实测（1920x1080）：
  槽1 y=120  槽2 y=212  槽3 y=305  槽4 y=397  槽5 y=489
  x 从 9 到 100，满血宽 92 像素，高 5 像素
为兼容换分辨率，这里是动态扫描出来的，不写死 y。
"""
import ctypes
import os
import subprocess
import time

BASE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(BASE, "_sort")
OUT = os.path.join(BASE, "hp_state.txt")
FRAME = os.path.join(WORK, "hp_frame.raw")
u = ctypes.windll.user32

FULL_WIDTH = 92.0          # 满血时的绿条宽度（像素）


def grab():
    hwnd = u.FindWindowW("Warcraft III", None)
    if not hwnd:
        return None, 0, 0
    if u.IsIconic(hwnd):
        u.ShowWindow(hwnd, 9)
        time.sleep(0.45)
    if u.GetForegroundWindow() != hwnd:
        u.SetForegroundWindow(hwnd)
        time.sleep(0.55)
    W = u.GetSystemMetrics(0)
    H = u.GetSystemMetrics(1)
    os.makedirs(WORK, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
         "-i", "ddagrab=0:framerate=60,hwdownload,format=bgra",
         "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-y", FRAME],
        capture_output=True)
    if not os.path.exists(FRAME):
        return None, W, H
    buf = open(FRAME, "rb").read()
    if len(buf) < W * 100 * 3:
        return None, W, H
    return buf, W, len(buf) // (W * 3)


def green_width(buf, W, y, x0=6, x1=106):
    c = 0
    for x in range(x0, x1):
        i = (y * W + x) * 3
        r, g, b = buf[i], buf[i + 1], buf[i + 2]
        if g > 120 and r < 80 and b < 80:
            c += 1
    return c


def main():
    buf, W, H = grab()
    if not buf:
        open(OUT, "w", encoding="ascii").write("error 抓屏失败")
        print("抓屏失败")
        return

    # 扫描找所有绿条行（左侧 x=6..106）
    hits = [(y, green_width(buf, W, y)) for y in range(60, min(H, 700))]
    hits = [h for h in hits if h[1] > 15]
    if not hits:
        open(OUT, "w", encoding="ascii").write("error 没找到血条")
        print("没找到血条（游戏不在前台？）")
        return

    groups = []
    g = [hits[0]]
    for prev, cur in zip(hits, hits[1:]):
        if cur[0] - prev[0] <= 2:
            g.append(cur)
        else:
            groups.append(g)
            g = [cur]
    groups.append(g)

    vals = []
    for grp in groups[:5]:
        ys = [a for a, _ in grp]
        ym = (ys[0] + ys[-1]) // 2
        n = green_width(buf, W, ym)
        pct = max(0, min(100, round(100.0 * n / FULL_WIDTH)))
        vals.append(pct)

    while len(vals) < 5:
        vals.append(-1)          # 没这个英雄

    real = [(i + 1, v) for i, v in enumerate(vals) if v >= 0]
    mn_slot, mn_val = min(real, key=lambda x: x[1]) if real else (0, 100)
    low = sum(1 for _, v in real if v < 50)

    line = " ".join("hp%d=%d" % (i + 1, v) for i, v in enumerate(vals))
    line += "  min=%d slot=%d low=%d crit=%d" % (
        mn_val, mn_slot, low, sum(1 for _, v in real if v < 25))
    with open(OUT, "w", encoding="ascii") as f:
        f.write(line)
    print(line)


if __name__ == "__main__":
    main()

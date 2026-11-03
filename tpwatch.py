# -*- coding: utf-8 -*-
"""传送验证：判断按 Z 之后传送到底有没有真的生效。

用法：
    python tpwatch.py before    # 点击物品"之前"记一帧（物品格状态 + 整屏缩略指纹）
    python tpwatch.py verify    # 点完小地图"之后"再抓一帧，跟 before 比

输出 tp_result.txt 一行：
    ok=1 img=12.3 grid=9.8     ok=1 表示判定为"传送已生效"
    ok=0 img=2.1  grid=1.4     ok=0 表示没传（CD 中 / 物品不对 / 点击没生效）

判据（任一成立就算传了）：
    img  : 物品格 1 的画面变了（用掉了：变空或换图标）
    grid : 整屏轮廓变了（镜头跳到基地）
都没变 => 认为没传，不该切英雄。
"""
import os
import sys
import time
import ctypes
import subprocess

BASE = os.path.dirname(os.path.abspath(__file__))
INI = os.path.join(BASE, "3C改建.ini")
WORK = os.path.join(BASE, "_sort")
OUT = os.path.join(BASE, "tp_result.txt")
SIG = os.path.join(WORK, "tp_sig.bin")
ITEM = os.path.join(WORK, "tp_item.raw")
FRAME = os.path.join(WORK, "tp_frame.raw")

u = ctypes.windll.user32


def ini_read(section, key, default=""):
    try:
        raw = open(INI, "rb").read()
    except OSError:
        return default
    text = None
    for enc in ("utf-8-sig", "ascii", "gbk", "utf-16"):
        try:
            text = raw.decode(enc)
            break
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
            cur = line[1:-1]
            continue
        if cur == section and "=" in line:
            k, v = line.split("=", 1)
            if k.strip() == key:
                return v.strip()
    return default


def read_pt(key):
    v = ini_read("pos", key, "")
    if "," not in v:
        return None
    try:
        x, y = v.split(",")[:2]
        return int(x), int(y)
    except ValueError:
        return None


def grab():
    """抓一帧原始像素。返回 (buf, W, H)；失败返回 (None, 0, 0)。"""
    hwnd = u.FindWindowW("Warcraft III", None)
    if not hwnd:
        return None, 0, 0
    if u.GetForegroundWindow() != hwnd:
        if u.IsIconic(hwnd):
            u.ShowWindow(hwnd, 9)
            time.sleep(0.40)
        u.SetForegroundWindow(hwnd)
        time.sleep(0.55)          # 窗口刚切到前台时画面还在变，多等一会儿再抓
    W = u.GetSystemMetrics(0)
    os.makedirs(WORK, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
         "-i", "ddagrab=0:framerate=60,hwdownload,format=bgra",
         "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-y", FRAME],
        capture_output=True)
    if not os.path.exists(FRAME):
        return None, 0, 0
    buf = open(FRAME, "rb").read()
    if len(buf) < W * 100 * 3:
        return None, 0, 0
    return buf, W, len(buf) // (W * 3)


def sig(buf, W, H, step=32):
    """整屏稀疏采样，作为"画面轮廓指纹"。"""
    out = bytearray()
    for y in range(0, H, step):
        base = y * W * 3
        for x in range(0, W, step):
            out.append(buf[base + x * 3])
    return bytes(out)


def crop(buf, W, H, cx, cy, size=52):
    x0 = max(0, min(W - size, cx - size // 2))
    y0 = max(0, min(H - size, cy - size // 2))
    return b"".join(buf[(y * W + x0) * 3:(y * W + x0 + size) * 3]
                    for y in range(y0, y0 + size))


def mad(a, b):
    n = min(len(a), len(b))
    if n == 0:
        return 999.0
    s = 0
    for i in range(n):
        s += abs(a[i] - b[i])
    return s / n


def change_ratio(a, b, thr=25):
    """变化点占比：镜头跳转会让大半个屏都变；单位走动只有局部变。
    这个比平均差异更能分清"传送了"和"游戏在动"。"""
    n = min(len(a), len(b))
    if n == 0:
        return 0.0
    c = 0
    for i in range(n):
        if abs(a[i] - b[i]) > thr:
            c += 1
    return c / n


def write_result(ok, img, grid, note="", pct=0.0):
    txt = "ok=%d img=%.1f grid=%.1f pct=%.2f %s" % (1 if ok else 0, img, grid, pct, note)
    with open(OUT, "w", encoding="ascii") as f:
        f.write(txt)
    print(txt)


def do_before():
    buf, W, H = grab()
    if not buf:
        write_result(0, 0, 0, "抓屏失败")
        return
    os.makedirs(WORK, exist_ok=True)
    open(SIG, "wb").write(sig(buf, W, H))
    pt = read_pt("item1")
    match = -1.0
    if pt:
        c = crop(buf, W, H, pt[0], pt[1], 52)
        open(ITEM, "wb").write(c)
        tpl = os.path.join(BASE, "tpl", "item_chuansong.raw")
        if os.path.exists(tpl):
            match = mad(c, open(tpl, "rb").read())
    # tp 值：第 1 格和"传送"模板的差异，越小越像。>15 说明这格不是传送
    with open(OUT, "w", encoding="ascii") as f:
        f.write("before tp=%.1f" % match)
    print("before 已记录 %dx%d  第1格与传送模板差=%.1f" % (W, H, match))


def do_verify():
    if not os.path.exists(SIG):
        write_result(0, 0, 0, "没有before基准")
        return
    buf, W, H = grab()
    if not buf:
        write_result(0, 0, 0, "抓屏失败")
        return
    cur = sig(buf, W, H)
    ref = open(SIG, "rb").read()
    grid = mad(cur, ref)
    pct = change_ratio(cur, ref)
    img = 0.0
    pt = read_pt("item1")
    if pt and os.path.exists(ITEM):
        img = mad(crop(buf, W, H, pt[0], pt[1], 52), open(ITEM, "rb").read())
    # 判据：物品格明显变了（用掉了） 或 大半个屏都变了（镜头跳到基地）
    ok = (img > 12.0) or (pct > 0.40)
    write_result(ok, img, grid, "", pct)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "verify"
    if mode == "before":
        do_before()
    else:
        do_verify()


if __name__ == "__main__":
    main()

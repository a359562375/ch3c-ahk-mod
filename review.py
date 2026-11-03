# -*- coding: utf-8 -*-
"""抓一帧，把 6 个物品格 + 3 个英雄头像切成中文命名的图片，方便核对。
输出目录：本目录下 核对图\
"""
import ctypes, time, subprocess, os, sys
from ctypes import wintypes

BASE = os.path.dirname(os.path.abspath(__file__))
INI = os.path.join(BASE, "3C改建.ini")
WORK = os.path.join(BASE, "_sort")
OUT = os.path.join(BASE, "核对图")
u = ctypes.windll.user32

NAMES = {"chuansong":"传送","chenmo":"沉默","chuifeng":"吹风","xuebang":"血棒",
         "fuhuo":"复活","lanbang":"蓝棒","shengqi":"圣骑","niu":"牛头","xiaohei":"小黑",
         "none":"空"}

def ini_read(section, key, default=""):
    try:
        raw = open(INI,"rb").read(); text=None
        for enc in ("ascii","utf-8","gbk","utf-16"):
            try: text=raw.decode(enc); break
            except Exception: continue
        if not text: return default
        cur=None
        for line in text.splitlines():
            line=line.strip()
            if not line: continue
            if line.startswith("[") and line.endswith("]"): cur=line[1:-1]; continue
            if cur==section and "=" in line:
                k,v=line.split("=",1)
                if k.strip()==key: return v.strip()
    except Exception: pass
    return default

def grab():
    hwnd=u.FindWindowW("Warcraft III",None)
    if not hwnd: return None,0
    if u.GetForegroundWindow()!=hwnd:
        if u.IsIconic(hwnd): u.ShowWindow(hwnd,9); time.sleep(0.4)
        u.SetForegroundWindow(hwnd); time.sleep(0.35)
    W=u.GetSystemMetrics(0); os.makedirs(WORK,exist_ok=True)
    out=os.path.join(WORK,"review.raw")
    subprocess.run(["ffmpeg","-hide_banner","-loglevel","error","-f","lavfi",
        "-i","ddagrab=0:framerate=60,hwdownload,format=bgra","-frames:v","1",
        "-f","rawvideo","-pix_fmt","rgb24","-y",out],capture_output=True)
    if not os.path.exists(out): return None,0
    buf=open(out,"rb").read()
    return (buf,W) if len(buf)>W*100 else (None,0)

def crop(buf,W,cx,cy,size):
    H=len(buf)//(W*3)
    x0=max(0,min(W-size,cx-size//2)); y0=max(0,min(H-size,cy-size//2))
    return b"".join(buf[(y*W+x0)*3:(y*W+x0+size)*3] for y in range(y0,y0+size))

def save(raw,size,name):
    rp=os.path.join(WORK,"t.raw"); open(rp,"wb").write(raw)
    out=os.path.join(OUT,name)
    subprocess.run(["ffmpeg","-hide_banner","-loglevel","error","-f","rawvideo",
        "-pix_fmt","rgb24","-s",f"{size}x{size}","-i",rp,"-y",out],capture_output=True)
    return out if os.path.exists(out) else None

def block_means(d,size,grid=4):
    out,bs=[],size//grid
    for by in range(grid):
        for bx in range(grid):
            sm=0
            for yy in range(by*bs,(by+1)*bs):
                row=yy*size*3
                for xx in range(bx*bs,(bx+1)*bs):
                    sm+=d[row+xx*3]
            out.append(sm/max(bs*bs,1))
    return out

def dist(a,b,size):
    ma,mb=block_means(a,size),block_means(b,size)
    return sum(abs(ma[i]-mb[i]) for i in range(len(ma)))/len(ma)

def load_tpls(size):
    """读 tpl 里所有已登记指纹，返回 {代号: raw}"""
    out={}
    tpldir=os.path.join(BASE,"tpl")
    for fn in os.listdir(tpldir) if os.path.isdir(tpldir) else []:
        if not fn.endswith(".raw"): continue
        raw=open(os.path.join(tpldir,fn),"rb").read()
        if len(raw)!=size*size*3: continue
        if fn.startswith("item_"): out[fn[5:-4]]=raw
        elif fn.startswith("hero_"): out[fn[5:-4]]=raw
    return out

def best_match(c,size,tpls,prefix,limit=10.0):
    best=("未知",999)
    for k,v in tpls.items():
        if not os.path.exists(os.path.join(BASE,"tpl",prefix+k+".raw")): continue
        d=dist(c,v,size)
        if d<best[1]: best=(k,d)
    if best[1]>limit:            # 差太多就别硬认，直接说未知
        return ("未知",best[1])
    return best

def main():
    os.makedirs(OUT,exist_ok=True); os.makedirs(WORK,exist_ok=True)
    for f in os.listdir(OUT):
        try: os.remove(os.path.join(OUT,f))
        except Exception: pass
    buf,W=grab()
    if not buf: print("抓屏失败（游戏没开或最小化）"); return
    ip=load_tpls(52); hp=load_tpls(48)
    ok=0; lines=[]
    for i in range(1,7):
        v=ini_read("pos",f"item{i}","")
        if "," not in v: continue
        x,y=map(int,v.split(",")[:2])
        c=crop(buf,W,x,y,84)
        inner=c  # 84 裁剪，比对用中心 52
        off=(84-52)//2
        ci=b"".join(inner[(yy*84+off)*3:(yy*84+off+52)*3] for yy in range(off,off+52))
        k,d=best_match(ci,52,ip,"item_")
        nm=NAMES.get(k,k)
        fn=f"物品{i}={nm}（差{d:.1f}）.png"
        if save(c,84,fn): ok+=1
        lines.append(f"物品{i}: {nm} 差{d:.1f}")
    for i in range(1,4):
        v=ini_read("pos",f"hero{i}","")
        if "," not in v: continue
        x,y=map(int,v.split(",")[:2])
        c=crop(buf,W,x,y,96)
        off=(96-48)//2
        ci=b"".join(c[(yy*96+off)*3:(yy*96+off+48)*3] for yy in range(off,off+48))
        k,d=best_match(ci,48,hp,"hero_")
        nm=NAMES.get(k,k)
        fn=f"英雄{i}={nm}（差{d:.1f}）.png"
        if save(c,96,fn): ok+=1
        lines.append(f"英雄{i}: {nm} 差{d:.1f}")
    print("\n".join(lines))
    print(f"已生成 {ok} 张核对图 →", OUT)

if __name__=="__main__":
    main()

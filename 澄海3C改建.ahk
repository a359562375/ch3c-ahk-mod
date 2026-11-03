#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode "Mouse", "Screen"
SendMode "Input"
SetMouseDelay(0)
SetKeyDelay(-1, -1)

; 魔兽/对战平台都是管理员权限运行的，脚本不跟着提权的话，
; Windows 会静默拦掉所有模拟点击和窗口读取（表现为"按了没反应"）。
if !A_IsAdmin {
    try Run('*RunAs "' A_ScriptFullPath '"')
    ExitApp
}

;=====================================================================
;  澄海3C 改建（AutoHotkey v2）—— 替代"雨之神助"
;  原理：把 LOL 式按键映射到"点击技能栏/物品栏固定格子"，不读内存、
;        不装驱动、不联网、无后台服务，全部代码就在下面，可逐行审阅。
;
;  热键一览
;    Q W E R T   技能 1~5          （点技能栏对应格）
;    Z X C V B N 物品 1~6          （避开 A/S/D/F 这些原生指令键）
;    F           道具回城（点"回城物品格" → 点小地图本方基地）
;    G           技能回城（点"技能N格" → 点小地图本方基地，默认第1格）
;    Delete      切换 光盟 / 黑暗（决定回城落点）
;    F8          进入坐标校准（第一次用必须先做）
;    Insert      暂停 / 恢复改建（暂停时所有键原样放行，等于暂时"恢复原键"）
;    Ctrl+F10    强退魔兽（原"雨神"的 F10，加了 Ctrl 防误触）
;    F9          无边框全屏 / 还原（窗口模式下铺满屏幕，看着像全屏，鼠标不出界）
;    F6          整理物品：按『源格』数字 → 按『目标格』数字，自动把物品拖过去
;
;  固定物品栏建议（肌肉记忆比什么都值钱，尽量别换位）
;    Z 回城   X 沉默   C 吹风   V 血棒   B 蓝棒   N 临时位（捡的、要卖的）
;    托盘图标右键 也可暂停/恢复、重新校准、退出
;
;  可调参数（存在 3C改建.ini 的 [cfg] 段，直接改文本即可）
;    tp_delay=120        回城第二击前等待毫秒（网络卡就调到 200~300）
;    tp_skill_slot=1     技能回城用第几个技能格（1~5，对应 Q~T）
;    side=light          当前回城阵营 light=光盟 / dark=黑暗
;
;  第一次使用：进游戏 → 按 F8 → 按提示把鼠标移到"技能1"按钮上按空格，
;  依次记录 14 个位置（技能5格、物品6格按你的界面实际情况，没有就按 Esc 跳过）。
;  坐标存在本文件同目录的 3C改建.ini，换分辨率要重新校准。
;=====================================================================

global IniFile  := A_ScriptDir "\3C改建.ini"
global Paused   := false
global ChatMode := false
global CalIndex := 0
global Side     := IniRead(IniFile, "cfg", "side", "light")
global Borderless := false
global SortMode  := 0
global SortFrom  := 0
global ClickBusy := false
global HeroIdx   := 0
global HeroSlotCache := 0
global TpArmed := false          ; 按 Z 前是否已拍过"传送前"底片
global LastHold := 0
global BlinkBusy := false      ; 闪现连招执行中，防连按
; 滚轮→H 的日志节流用的是 LastHold（下一行）
global LogFile  := A_ScriptDir "\3C改建.log"

; 写诊断日志：热键到底有没有被收到，一看便知
Log(msg) {
    global LogFile
    try FileAppend(FormatTime(A_Now, "MM-dd HH:mm:ss") . "  " . msg . "`r`n", LogFile, "UTF-8-RAW")
}

Log("=== 脚本启动 ===  屏幕 " . A_ScreenWidth . "x" . A_ScreenHeight . "  AHK " . A_AhkVersion . "  管理员权限=" . (A_IsAdmin ? "是" : "否"))

; 首次运行生成配置文件，方便直接改参数
if !FileExist(IniFile) {
    IniWrite("120", IniFile, "cfg", "tp_delay")
    IniWrite("1", IniFile, "cfg", "tp_skill_slot")
    IniWrite("light", IniFile, "cfg", "side")
    IniWrite("msg", IniFile, "cfg", "click_method")
}

global CalList := ["技能1 (Q)", "技能2 (W)", "技能3 (E)", "技能4 (R)", "技能5 (T)"
                 , "物品1 (Z)", "物品2 (X)", "物品3 (C)", "物品4 (V)", "物品5 (B)", "物品6 (N)"
                 , "回城物品格", "小地图-光盟基地", "小地图-黑暗基地"
                 , "英雄头像1", "英雄头像2", "英雄头像3", "英雄头像4", "英雄头像5"]
global CalKeys := ["skill1", "skill2", "skill3", "skill4", "skill5"
                 , "item1", "item2", "item3", "item4", "item5", "item6"
                 , "item_tp", "base_light", "base_dark"
                 , "hero1", "hero2", "hero3", "hero4", "hero5"]

; KK 给游戏加了进程保护，进程名读不到（读取返回"拒绝访问"），
; 所以不能用 ahk_exe 识别，改用窗口类名——魔兽的类名固定是 "Warcraft III"。
GroupAdd("War3", "ahk_class Warcraft III")

;---------------------- 物品整理（把 A 格物品移到 B 格）---------------------
; 三种动作方式，ini 里 sort_click 切换：
;   right = 右键点 A 格 → 右键点 B 格（3C 里右键拿起/放下，默认）
;   left  = 左键点 A 格 → 左键点 B 格
;   drag  = 左键按住从 A 拖到 B（分步移动）
DragItem(from, to) {
    global ClickBusy, IniFile
    a := ReadPos("item" from)
    b := ReadPos("item" to)
    if (a = "" || b = "")
        return false
    if ClickBusy
        return false
    ClickBusy := true
    mode := IniRead(IniFile, "cfg", "sort_click", "right")
    gap  := Integer(IniRead(IniFile, "cfg", "sort_gap", "260"))
    MouseGetPos(&ox, &oy)
    BlockInput(true)
    try {
        if (mode = "drag") {
            MouseMove(a[1], a[2], 0)
            Sleep(40)
            MouseClick("Left", a[1], a[2], 1, 0, "D")
            Sleep(70)
            steps := 12
            loop steps {
                f := A_Index / steps
                MouseMove(Round(a[1] + (b[1] - a[1]) * f), Round(a[2] + (b[2] - a[2]) * f), 0)
                Sleep(12)
            }
            Sleep(70)
            MouseClick("Left", b[1], b[2], 1, 0, "U")
        } else {
            btn := (mode = "left") ? "Left" : "Right"
            MouseMove(a[1], a[2], 0)
            Sleep(45)
            MouseClick(btn, a[1], a[2], 1, 0)
            Sleep(gap)                     ; 等游戏把物品"拿起来"
            MouseMove(b[1], b[2], 0)
            Sleep(45)
            MouseClick(btn, b[1], b[2], 1, 0)
        }
        Sleep(90)
        MouseMove(ox, oy, 0)
    } finally {
        BlockInput(false)
        ClickBusy := false
    }
    return true
}

;----------- 自动整理：调 python 识别 → 读 moves.txt → 依次拖动 -----------
RunPythonSync(mode) {
    global IniFile
    py := IniRead(IniFile, "cfg", "python_exe", "C:\Program Files\Python312\python.exe")
    sp := A_ScriptDir . "\sort_once.py"
    if (!FileExist(py) || !FileExist(sp)) {
        Log("找不到 python 或 sort_once.py")
        return false
    }
    try {
        RunWait('"' . py . '" "' . sp . '" ' . mode . ' --keep-focus', A_ScriptDir, "Hide")
        return true
    } catch as e {
        Log("调用 python 出错：" . e.Message)
        return false
    }
}

AutoSort() {
    Log("【自动整理】开始")
    ToolTip("正在识别物品栏…")
    ok := RunPythonSync("sort")
    ToolTip()
    if !ok {
        Log("自动整理不可用，转手动模式")
        EnterSortManual()
        return
    }
    mf := A_ScriptDir . "\moves.txt"
    moves := ""
    if FileExist(mf) {
        moves := Trim(FileRead(mf, "UTF-8"))
        FileDelete(mf)
    }
    if (moves = "") {
        SoundBeep(1700, 80)
        Log("【自动整理】本来就是标准布局，无需动")
        return
    }
    Log("【自动整理】需要拖动：" . StrReplace(moves, "`n", " "))
    for line in StrSplit(moves, "`n", "`r") {
        if RegExMatch(line, "(\d)>(\d)", &m) {
            DragItem(m[1], m[2])
            Sleep(150)
        }
    }
    SoundBeep(1900, 110)
    Log("【自动整理】完成")
}

EnterSortManual() {
    global SortMode
    SortMode := 1
    SoundBeep(1200, 60)
    ToolTip("手动整理：先按『源格』数字 1-6，再按『目标格』，Esc 取消")
    Log("手动整理模式")
}

SortPick(n) {
    global SortMode, SortFrom
    if (SortMode = 1) {
        SortFrom := n
        SortMode := 2
        SoundBeep(1400, 60)
        ToolTip("从第 " n " 格 → 现在按『目标格』数字")
        return
    }
    ok := DragItem(SortFrom, n)
    Log("整理 " . SortFrom . "→" . n . " " . (ok ? "成功" : "失败（坐标缺失）"))
    SoundBeep(ok ? 1700 : 400, 90)
    SortMode := 0
    ToolTip()
}

;---------------------- 托盘菜单 ----------------------
A_TrayMenu.Delete()
A_TrayMenu.Add("暂停 / 恢复  (Insert)", (*) => TogglePause())
A_TrayMenu.Add("重新校准  (F8)", (*) => StartCal())
A_TrayMenu.Add()
A_TrayMenu.Add("退出改建脚本", (*) => ExitApp())
A_TrayMenu.Default := "暂停 / 恢复  (Insert)"
A_IconTip := "3C改建：运行中"

;---------------------- 基础函数 ----------------------
ReadPos(name) {
    global IniFile
    v := IniRead(IniFile, "pos", name, "")
    if (v = "" || !InStr(v, ","))
        return ""
    p := StrSplit(v, ",")
    return [Integer(Trim(p[1])), Integer(Trim(p[2]))]
}

; 两种点击方式：
;   msg  = 直接向游戏窗口投递点击消息，**不移动你的鼠标**，最快，也不会跟你抢鼠标（默认）
;   mouse= 移动真实光标去点，再挪回来（兼容模式，msg 无效时用）
ClickPos(name) {
    pt := ReadPos(name)
    if (pt = "")
        return false
    method := IniRead(IniFile, "cfg", "click_method", "msg")
    hwnd := WinActive("ahk_class Warcraft III")
    if !hwnd
        hwnd := WinExist("ahk_class Warcraft III")
    if (method = "msg" && hwnd)
        return ClickPosMsg(hwnd, pt)
    return ClickPosMouse(pt)
}

ClickPosMsg(hwnd, pt) {
    WinGetClientPos(&cx, &cy, &cw, &ch, hwnd)
    x := pt[1] - cx
    y := pt[2] - cy
    if (x < 0 || y < 0 || x >= cw || y >= ch)     ; 坐标不在窗口内，退回物理点击
        return ClickPosMouse(pt)
    lp := (y << 16) | (x & 0xFFFF)
    PostMessage(0x0200, 0, lp, , "ahk_id " hwnd)   ; WM_MOUSEMOVE  先把游戏内光标移过去
    Sleep(3)
    PostMessage(0x0201, 1, lp, , "ahk_id " hwnd)   ; WM_LBUTTONDOWN
    Sleep(12)
    PostMessage(0x0202, 0, lp, , "ahk_id " hwnd)   ; WM_LBUTTONUP
    return true
}

ClickPosMouse(pt) {
    global ClickBusy
    if ClickBusy                       ; 上一次还没点完，直接放弃，避免两次点击打架
        return false
    ClickBusy := true
    MouseGetPos(&ox, &oy)
    BlockInput(true)
    try {
        MouseMove(pt[1], pt[2], 0)
        Sleep(12)                      ; 先让游戏看见光标到位，再按下
        MouseClick("Left", pt[1], pt[2], 1, 0, "D")
        Sleep(35)                      ; 关键：按住至少一帧，否则魔兽会漏掉这次点击
        MouseClick("Left", pt[1], pt[2], 1, 0, "U")
        MouseMove(ox, oy, 0)
    } finally {
        BlockInput(false)
        ClickBusy := false
    }
    return true
}

WarnNotCal() {
    ToolTip("还没校准坐标，先按 F8（鼠标移到对应按钮上按空格记录）")
    SetTimer(() => ToolTip(), -2000)
}

; 返回 true 表示这次按键不执行改建动作
Blocked(rawKey := "") {
    global Paused, ChatMode
    if (Paused || ChatMode) {
        if (rawKey != "")
            Send("{Raw}" rawKey)      ; 正在打字，原样输出字符
        return true
    }
    return false
}

; F9：窗口模式下把魔兽变成"无边框全屏"——看起来是全屏，实际还是窗口，
; 所以模拟点击依然生效；鼠标也不会跑到别的窗口去。
ToggleBorderless() {
    global Borderless
    hwnd := WinExist("ahk_group War3")
    if !hwnd
        return
    if !Borderless {
        WinSetStyle("-0xC00000", hwnd)
        WinMove(0, 0, A_ScreenWidth, A_ScreenHeight, hwnd)
        Borderless := true
        ToolTip("已切无边框全屏（再按 F9 还原）")
    } else {
        WinSetStyle("+0xC00000", hwnd)
        Borderless := false
        ToolTip("已还原窗口边框")
    }
    SetTimer(() => ToolTip(), -1500)
}

TogglePause() {
    global Paused
    Paused := !Paused
    A_IconTip := Format("3C改建：{}", Paused ? "已暂停（按键恢复原样）" : "运行中")
    ToolTip(Paused ? "改建已暂停，所有按键恢复原样" : "改建已恢复（Q/W/E/R/T 放技能）")
    SetTimer(() => ToolTip(), -1200)
}

CastSkill(n, rawKey) {
    global IniFile
    if (Blocked(rawKey))
        return
    k := IniRead(IniFile, "cfg", "skill_key" n, "")   ; 若填了字母就直接发键，比点击更快
    if (k != "") {
        Send("{Blind}" k)
        Log("技能" n . " → 发送按键 " . k)
        SkillAim(n)
        return
    }
    ok := ClickPos("skill" n)
    Log("技能" n . " 触发 → 点击 " . (ok ? "成功" : "失败（无坐标）"))
    if !ok {
        WarnNotCal()
        return
    }
    SkillAim(n)
}

; 举起技能后替你点一下鼠标位置（省掉"再左键点一次"）
; 每格单独配置：skill_aimN=mouse 自动点 / none 不点（自身增益类设 none）
SkillAim(n) {
    global IniFile
    if (IniRead(IniFile, "cfg", "skill_aim" n, "mouse") != "mouse")
        return
    Sleep(Integer(IniRead(IniFile, "cfg", "skill_click_gap", "130")))
    MouseGetPos(&kx, &ky)
    ClickPoint([kx, ky])
    Log("  技能" n . " 自动补点(" . kx . "," . ky . ")")
}

UseItem(n, rawKey) {
    global IniFile, TpArmed
    if (Blocked(rawKey))
        return
    ; 点"传送"这一格之前先拍一张底片，之后拿它判断到底传没传出去
    ; （只有开了"传送后切英雄"才需要验证，否则完全是白花 0.5 秒）
    TpArmed := false
    if NeedTPVerify(n) {
        TpArmed := TPSnapshot("before")
        d := TpSlotCheck()
        if (d >= 0 && d > 15) {
            Log("警告：物品" n . " 与传送模板差 " . d . "（>15），这格放的可能不是传送")
            SoundBeep(500, 120)
        }
    }
    k := IniRead(IniFile, "cfg", "item_key" n, "")    ; 若填了按键就直接发键（如 Numpad7）
    if (k != "") {
        Send("{Blind}" k)
        Log("物品" n . " → 发送按键 " . k)
        AfterItem(n)
        return
    }
    ok := ClickPos("item" n)
    Log("物品" n . " 触发 → 点击 " . (ok ? "成功" : "失败（无坐标）"))
    if !ok {
        WarnNotCal()
        return
    }
    ; 举起物品后替你点一下鼠标位置（省掉"再左键点一次"）
    ; 每格单独配置：item_aimN=mouse 自动点 / none 不点
    if (!IsTPSlot(n) && IniRead(IniFile, "cfg", "item_aim" n, "none") = "mouse") {
        Sleep(Integer(IniRead(IniFile, "cfg", "item_click_gap", "130")))
        MouseGetPos(&ix, &iy)
        ClickPoint([ix, iy])
        Log("  物品" n . " 自动补点(" . ix . "," . iy . ")")
    }
    AfterItem(n)
}

; 这一格是不是"传送"
IsTPSlot(n) {
    global IniFile
    return (n = Integer(IniRead(IniFile, "cfg", "tp_item_slot", "1")))
}

; 要不要为这次点击做"是否真传了"的验证
; 只有「开了传送后切英雄」才值得花 0.5 秒抓帧，否则纯属白等
NeedTPVerify(n) {
    global IniFile
    if !IsTPSlot(n)
        return false
    if (Integer(IniRead(IniFile, "cfg", "tp_switch_hero", "0")) != 1)
        return false
    ; 用编队切人的话，切错了也无害（就是选中牛头），没必要花时间验证
    if (Integer(IniRead(IniFile, "cfg", "tp_hero_group", "0")) > 0)
        return false
    return (Integer(IniRead(IniFile, "cfg", "tp_verify", "1")) = 1)
}

; 传送验证：mode=before 拍底片 / mode=verify 抓帧比对
TPSnapshot(mode) {
    global IniFile
    py := IniRead(IniFile, "cfg", "python_exe", "C:\Program Files\Python312\python.exe")
    sc := A_ScriptDir . "\tpwatch.py"
    if (!FileExist(py) || !FileExist(sc)) {
        Log("传送验证不可用（缺 python 或 tpwatch.py），跳过判定")
        return false
    }
    try RunWait('"' . py . '" "' . sc . '" ' . mode, A_ScriptDir, "Hide")
    catch {
        Log("传送验证调用失败：" . mode)
        return false
    }
    return true
}

; 读 before 结果里的 tp 值（第1格与传送模板的差异），-1 表示没测到
TpSlotCheck() {
    f := A_ScriptDir . "\tp_result.txt"
    if !FileExist(f)
        return -1
    s := Trim(FileRead(f, "UTF-8"))
    FileDelete(f)
    if RegExMatch(s, "tp=(-?[\d.]+)", &m)
        return Number(m[1])
    return -1
}

; 读 tpwatch.py 的结果：ok=1 img=12.3 grid=9.8 pct=0.72
ReadTPResult() {
    f := A_ScriptDir . "\tp_result.txt"
    if !FileExist(f)
        return {ok: true, raw: "无结果，默认当作已传送"}
    s := Trim(FileRead(f, "UTF-8"))
    FileDelete(f)
    return {ok: (InStr(s, "ok=1") ? true : false), raw: s}
}

; 用完某个物品后的后续动作：用「传送」那一格时，
; 先确认传送真的生效了，再切英雄（没传就不切，免得白切一次）
AfterItem(n) {
    global IniFile, TpArmed, Side
    if !IsTPSlot(n)
        return
    ; 传送后自动切英雄默认关闭（会打断操作节奏），要开就把 tp_switch_hero 改成 1
    if (Integer(IniRead(IniFile, "cfg", "tp_switch_hero", "0")) != 1) {
        TpArmed := false
        return
    }

    ; 举起传送之后，替你把落点点掉
    ;   base  = 点小地图本方基地（回城卷轴只认这个，最可靠）
    ;   mouse = 点你鼠标所在的位置（传送权杖那种可以随便传的才用）
    aim := IniRead(IniFile, "cfg", "tp_aim", "none")
    Sleep(Integer(IniRead(IniFile, "cfg", "tp_delay", "120")))
    if (aim = "mouse") {
        MouseGetPos(&mx, &my)
        ClickPoint([mx, my])
        Log("传送落点 → 鼠标位置(" . mx . "," . my . ")")
    } else if (aim = "base") {
        target := (Side = "light") ? "base_light" : "base_dark"
        if ClickPos(target)
            Log("传送落点 → 小地图基地(" . target . ")")
        else
            Log("传送落点失败：缺 " . target . " 坐标")
    } else {
        Log("传送已举起，落点你自己点（tp_aim=none）")
    }
    ; 等落地动画走完
    Sleep(Integer(IniRead(IniFile, "cfg", "tp_hero_gap", "700")))
    if (TpArmed) {
        TpArmed := false
        ; 传送有引导时间，一次抓帧很容易抓早了。改成连抓几次，任一次看到画面跳了就算传了
        okTP := false
        tries := Integer(IniRead(IniFile, "cfg", "tp_verify_tries", "3"))
        loop tries {
            if TPSnapshot("verify") {
                r := ReadTPResult()
                if (r.ok) {
                    okTP := true
                    Log("传送已生效（第 " . A_Index . " 次检测：" . r.raw . "）")
                    break
                }
                Log("第 " . A_Index . " 次检测：还没看到传送（" . r.raw . "）")
            }
            Sleep(Integer(IniRead(IniFile, "cfg", "tp_verify_gap", "400")))
        }
        if (!okTP) {
            SoundBeep(380, 300)
            Log("传送没生效（连试 " . tries . " 次都没看到画面变化）→ 不切英雄")
            return
        }
    }

    ; 配了编队号就直接按编队切 —— 不用识别、不用抓帧，最快也最准
    grp := Integer(IniRead(IniFile, "cfg", "tp_hero_group", "0"))
    if (grp > 0) {
        Sleep(Integer(IniRead(IniFile, "cfg", "hero_pre_gap", "150")))
        ; 只按一次 = 选中牛头，不拉视角（拉视角由你自己决定）
        taps := Integer(IniRead(IniFile, "cfg", "tp_group_taps", "1"))
        loop taps {
            Send("{Blind}" . grp)
            Sleep(Integer(IniRead(IniFile, "cfg", "hero_tap_delay", "200")))
        }
        Log("传送后按编队 " . grp . " 选中牛头 ×" . taps)
        return
    }
    after := ResolveTPHero()
    if (after <= 0)
        return
    Log("传送（物品" n "）→ 切 " . after . " 号英雄")
    JumpHero(after)
}

; 英雄切换：直接发 F1/F2/F3（魔兽自带的"选中第 N 个英雄"）
SwitchHero(n, rawKey) {
    if (Blocked(rawKey))
        return
    Send("{Blind}F" . n)
    Log("切换英雄" . n)
}

; 点一个坐标（用起来比 drag 轻，单独封装）
ClickPoint(pt, btn := "Left") {
    MouseGetPos(&ox, &oy)
    BlockInput(true)
    try {
        MouseMove(pt[1], pt[2], 0)
        Sleep(25)
        MouseClick(btn, pt[1], pt[2], 1, 0)
        MouseMove(ox, oy, 0)
    } finally {
        BlockInput(false)
    }
}

; 单键循环：空格往前、Shift+空格往后。
; 已扫描过英雄（Ctrl+空格）就点头像——支持任意数量英雄，还能顺带定位视角；
; 没扫描过就退回 F 键双击。
CycleHero(step) {
    global HeroIdx, IniFile, HeroMask
    if (Blocked(" "))
        return

    ; Tab 方式（默认）：编队后按 Tab 在选中单位间循环，最稳、零延迟、不挑槽位
    if (IniRead(IniFile, "cfg", "hero_switch", "tab") = "tab") {
        TabHero(step)
        return
    }

    tap := Integer(IniRead(IniFile, "cfg", "hero_tap_delay", "120"))

    if (HeroMask != "" && ReadPos("hero1") != "") {
        total := StrLen(HeroMask)
        found := false
        loop total {
            HeroIdx += step
            if (HeroIdx > total)
                HeroIdx := 1
            if (HeroIdx < 1)
                HeroIdx := total
            if (SubStr(HeroMask, HeroIdx, 1) = "1") {
                found := true
                break
            }
            if (A_Index >= total)
                break
        }
        if (found) {
            pt := ReadPos("hero" . HeroIdx)
            ClickPoint(pt)          ; 第一次点：选中
            Sleep(tap)
            ClickPoint(pt)          ; 第二次点：视角居中（等同双击头像）
            SoundBeep(800 + HeroIdx * 200, 50)
            Log("切换英雄 → 头像" . HeroIdx . "（双击定位）")
            return
        }
        Log("头像扫描结果里没有英雄，转 F 键")
    }

    total := Integer(IniRead(IniFile, "cfg", "hero_count", "3"))
    total := Max(1, Min(total, 9))
    HeroIdx += step
    if (HeroIdx > total)
        HeroIdx := 1
    if (HeroIdx < 1)
        HeroIdx := total
    Send("{Blind}F" . HeroIdx)
    Sleep(tap)
    Send("{Blind}F" . HeroIdx)
    SoundBeep(800 + HeroIdx * 200, 50)
    Log("切换英雄 → F" . HeroIdx . "（选中+定位）")
}

; Tab 方式切英雄：魔兽里编好队后按 Tab 就能在队员之间循环，镜头会跟过去。
; 优点：不依赖槽号、不需要识别头像、零延迟；缺点：前提是英雄都编在同一队。
TabHero(step) {
    global IniFile
    tap  := Integer(IniRead(IniFile, "cfg", "hero_tab_delay", "70"))
    team := IniRead(IniFile, "cfg", "hero_team_key", "1")
    if (step > 0) {
        Send("{Blind}Tab")
        Log("Tab 切下一个英雄")
    } else {
        ; 反向：先选中队伍（回到第一个），再按 N-1 次 Tab 绕到尾端
        total := Max(1, Min(Integer(IniRead(IniFile, "cfg", "hero_count", "3")), 9))
        Send("{Blind}" team)
        Sleep(90)
        loop total - 1 {
            Send("{Blind}Tab")
            Sleep(tap)
        }
        Log("Tab 反向切英雄（" . team . " 队 + Tab×" . (total - 1) . "）")
    }
    SoundBeep(1500, 40)
}

; Ctrl+空格：扫一次头像，自动数出这一局有几个英雄
ScanHeroes() {
    global IniFile, HeroMask
    py := IniRead(IniFile, "cfg", "python_exe", "C:\Program Files\Python312\python.exe")
    hp := A_ScriptDir . "\heroes.py"
    if (!FileExist(py) || !FileExist(hp)) {
        Log("找不到 python 或 heroes.py")
        SoundBeep(400, 150)
        return
    }
    ToolTip("正在识别英雄数量…")
    try RunWait('"' . py . '" "' . hp . '"', A_ScriptDir, "Hide")
    ToolTip()
    mf := A_ScriptDir . "\heroes.txt"
    HeroMask := ""
    if FileExist(mf) {
        HeroMask := Trim(FileRead(mf, "UTF-8"))
        FileDelete(mf)
    }
    n := 0
    if (HeroMask != "")
        for v in StrSplit(HeroMask, ",")
            if (v = "1")
                n++
    Log("扫描英雄：mask=" . HeroMask . "，共 " . n . " 个")
    if (n > 0) {
        loop n {
            SoundBeep(1300, 55)
            Sleep(90)
        }
    } else {
        SoundBeep(400, 220)
    }
}

; mode = "item" 用回城道具；mode = "skill" 用技能格的传送技能
OneKeyTP(mode) {
    global Side, IniFile
    if (Blocked(mode = "item" ? "z" : "x"))
        return
    if (mode = "item") {
        first := "item_tp"
    } else {
        slot  := Integer(IniRead(IniFile, "cfg", "tp_skill_slot", "1"))
        first := "skill" . slot
    }
    if !(ClickPos(first)) {
        WarnNotCal()
        return
    }
    Sleep(Integer(IniRead(IniFile, "cfg", "tp_delay", "120")))
    target := (Side = "light") ? "base_light" : "base_dark"
    if !(ClickPos(target)) {
        WarnNotCal()
        return
    }
    ; 回城（F/G）之后不再切英雄 —— 切英雄改到"用传送物品"时触发
}

; 传送后要切到第几号英雄。tp_hero_by=name 时按名字现找，结果会缓存（同局内槽位不会变）
ResolveTPHero() {
    global IniFile, Side, HeroSlotCache
    by := IniRead(IniFile, "cfg", "tp_hero_by", "slot")
    if (by != "name")
        return Integer(IniRead(IniFile, "cfg", "tp_to_hero_" . Side, "0"))
    if (HeroSlotCache > 0)
        return HeroSlotCache
    key := IniRead(IniFile, "cfg", "tp_hero_name_" . Side, "")
    if (key = "")
        return Integer(IniRead(IniFile, "cfg", "tp_to_hero_" . Side, "0"))
    py := IniRead(IniFile, "cfg", "python_exe", "C:\Program Files\Python312\python.exe")
    hp := A_ScriptDir . "\heroes2.py"
    if (!FileExist(py) || !FileExist(hp)) {
        Log("找不到 python 或 heroes2.py，退回固定槽号")
        return Integer(IniRead(IniFile, "cfg", "tp_to_hero_" . Side, "0"))
    }
    try RunWait('"' . py . '" "' . hp . '" find ' . key, A_ScriptDir, "Hide")
    slot := 0
    f := A_ScriptDir . "\heroes.txt"
    if FileExist(f) {
        slot := Integer(Trim(FileRead(f, "UTF-8")))
        FileDelete(f)
    }
    if (slot > 0)
        HeroSlotCache := slot
    Log("按名字找 " . key . " → 第 " . slot . " 号槽")
    return (slot > 0) ? slot : Integer(IniRead(IniFile, "cfg", "tp_to_hero_" . Side, "0"))
}

; 精确切到第 n 号英雄：F 键连按两次 = 选中 + 视角居中；
; 若视角仍不过去，再补一次"双击英雄头像"（双击头像等同视角居中），双保险。
JumpHero(n) {
    global IniFile
    tap  := Integer(IniRead(IniFile, "cfg", "hero_tap_delay", "200"))
    pre  := Integer(IniRead(IniFile, "cfg", "hero_pre_gap", "150"))
    mode := IniRead(IniFile, "cfg", "hero_center", "click")

    ; 首选：直接双击第 n 个英雄头像。
    ; 这是唯一不依赖「F 键够不够」和「编队顺序」的办法——5 个英雄也能精确切。
    pt := ReadPos("hero" . n)
    if (pt != "") {
        Sleep(pre)
        ClickPoint(pt)
        Sleep(120)
        ClickPoint(pt)                ; 双击头像 = 选中 + 视角居中
        SoundBeep(700 + n * 150, 55)
        Log("双击头像 " . n . " 切英雄（选中+居中）")
        return
    }

    Sleep(pre)                       ; 没有头像坐标时，退回下面的按键方式

    ; Tab 方式：先选中队伍，再按 n-1 次 Tab 走到第 n 个（编队顺序 = 头像槽顺序）
    if (IniRead(IniFile, "cfg", "hero_switch", "tab") = "tab") {
        team := IniRead(IniFile, "cfg", "hero_team_key", "1")
        tdel := Integer(IniRead(IniFile, "cfg", "hero_tab_delay", "70"))
        Send("{Blind}" team)
        Sleep(90)
        loop n - 1 {
            Send("{Blind}Tab")
            Sleep(tdel)
        }
        ; 双击头像兜底：保证视角一定居中（Tab 只换选中，不保证镜头跟过去）
        if (mode = "click" || mode = "both") {
            pt := ReadPos("hero" . n)
            if (pt != "") {
                Sleep(120)
                ClickPoint(pt)
                Sleep(110)
                ClickPoint(pt)
                Log("Tab 切到 " . n . " 号后双击头像居中")
            }
        }
        SoundBeep(700 + n * 150, 55)
        Log("Tab 定位第 " . n . " 个英雄（" . team . " 队 + Tab×" . (n - 1) . "）")
        return
    }

    Send("{Blind}F" . n)
    Sleep(tap)
    Send("{Blind}F" . n)
    if (mode = "click" || mode = "both") {
        pt := ReadPos("hero" . n)
        if (pt != "") {
            Sleep(120)
            ClickPoint(pt)
            Sleep(110)
            ClickPoint(pt)            ; 双击头像：选中 + 视角居中
            Log("补双击头像 " . n . " 定位视角")
        }
    }
    SoundBeep(700 + n * 150, 55)
}

ToggleSide() {
    global Side, IniFile
    Side := (Side = "light") ? "dark" : "light"
    IniWrite(Side, IniFile, "cfg", "side")
    tgt := (Side = "light") ? "光盟" : "黑暗"
    nxt := Integer(IniRead(IniFile, "cfg", "tp_to_hero_" . Side, "0"))
    extra := (nxt > 0) ? "，传送后切 " . nxt . " 号英雄" : ""
    ToolTip("当前阵营：" . tgt . extra)
    SetTimer(() => ToolTip(), -1600)
    Log("阵营切到 " . Side . "（传送后切英雄=" . nxt . "）")
}

;---------------------- 坐标校准 ----------------------
StartCal() {
    global CalIndex
    t := "?", p := "?"
    try t := WinGetTitle("A")
    try p := WinGetProcessName("A")
    Log("F8 触发｜前台标题='" . t . "' 进程='" . p . "' 组匹配=" . (WinActive("ahk_group War3") ? "是" : "否"))
    CalIndex := 1
    ShowCalTip()
}

ShowCalTip() {
    global CalIndex, CalList, IniFile
    if (CalIndex > CalList.Length) {
        CalIndex := 0
        ToolTip()
        Log("=== 校准完成，14 个点已写入 " . IniFile . " ===")
        SoundBeep(1600, 90)
        Sleep(120)
        SoundBeep(1600, 90)
        Sleep(120)
        SoundBeep(1600, 160)
        return
    }
    ToolTip("【校准 " CalIndex " / " CalList.Length "】" CalList[CalIndex] "`n把鼠标移到对应位置，按 空格 记录；Esc 退出校准")
    SoundBeep(900, 60)
}

RecordCal() {
    global CalIndex, CalKeys, IniFile, CalList
    MouseGetPos(&mx, &my)
    val := mx "," my
    IniWrite(val, IniFile, "pos", CalKeys[CalIndex])
    Log("校准 " . CalIndex . "/" . CalList.Length . " " . CalKeys[CalIndex] . " = " . val)
    SoundBeep(1400, 60)
    CalIndex++
    ShowCalTip()
}

StopCal() {
    global CalIndex
    CalIndex := 0
    ToolTip()
}

;---------------------- 校准模式热键 ----------------------
#HotIf CalIndex > 0
Space::RecordCal()
Esc::StopCal()
F8::StopCal()
#HotIf

;---------------------- 全局热键 ----------------------
; F7 纯诊断：证明 AHK 到底有没有收到按键
F7:: {
    t := "?", p := "?"
    try t := WinGetTitle("A")
    try p := WinGetProcessName("A")
    Log("F7 测试键收到｜前台='" . t . "' 进程='" . p . "' 管理员=" . (A_IsAdmin ? "是" : "否"))
    ToolTip("AHK 已收到 F7（说明脚本活着）")
    SoundBeep(1800, 120)
    SetTimer(() => ToolTip(), -1500)
}

F8::StartCal()

; F4：只补校准「英雄头像」那 3 个点，不用把前面 14 个重走一遍
$*F4::StartCalFrom(15)

StartCalFrom(n) {
    global CalIndex
    CalIndex := n
    ShowCalTip()
}

; Ctrl+F7 切换"点击方式"，方便你在游戏里直接 A/B 测，不用改文件
^F7:: {
    global IniFile
    m := IniRead(IniFile, "cfg", "click_method", "msg")
    m := (m = "msg") ? "mouse" : "msg"
    IniWrite(m, IniFile, "cfg", "click_method")
    Log("点击方式切换为 " . m)
    ToolTip((m = "msg") ? "点击方式：消息投递（不移动鼠标）" : "点击方式：移动鼠标（兼容模式）")
    SoundBeep((m = "msg") ? 1500 : 900, 100)
    SetTimer(() => ToolTip(), -1500)
}

Insert::TogglePause()

^F10:: {
    if WinExist("ahk_group War3")
        WinKill("ahk_group War3")
}

SetTimer(CheckFocus, 500)
CheckFocus() {
    global ChatMode
    if !(WinActive("ahk_group War3"))
        ChatMode := false
}

;---------------------- 游戏内热键 ----------------------
#HotIf WinActive("ahk_group War3") && (CalIndex = 0)

; 技能：LOL 式 Q W E R T
$*q::CastSkill(1, "q")
$*w::CastSkill(2, "w")
$*e::CastSkill(3, "e")
$*r::CastSkill(4, "r")
$*t::CastSkill(5, "t")

; 物品：Z X C V B N
; 为什么不用 A/S/D/F：A=攻击、S=停止、D=防御，都是魔兽原生指令键，
; 按下后游戏会进入对应状态，把脚本的点击吃掉，物品用不出来。
; Z/X/C/V/B/N 在魔兽里没有原生功能，按下去不会被游戏抢先解释。
; 键 ↔ 格 的对应（按用户要求重排）：
;   C=格1传送  V=格2吹风  B=格3沉默  N=格4净化  Z=格5  X=格6
$*c::UseItem(1, "c")
$*v::UseItem(2, "v")
$*b::UseItem(3, "b")
$*n::UseItem(4, "n")
$*z::UseItem(5, "z")
$*x::UseItem(6, "x")

; 空格 = 牛头闪现 + 践踏（落点 = 你按空格那一刻鼠标所在的位置）
; 代价：空格不再"跳到最近警报"
$*Space::BlinkStomp()

; 无边框全屏：窗口模式下按 F9 铺满屏幕，看着就是全屏
$*F9::ToggleBorderless()

; F5 登记"标准布局"：把当前物品栏 6 格存成模板，以后 F6 就恢复成这样
$*F5:: {
    Log("【登记】开始")
    ToolTip("正在登记标准布局…")
    ok := RunPythonSync("register")
    ToolTip()
    SoundBeep(ok ? 1600 : 400, 110)
    Log("【登记】" . (ok ? "完成，已存 6 格模板" : "失败"))
}

; 整理物品：F6 = 自动识别并归位；Shift+F6 = 手动指定（源格数字 → 目标格数字）
$*F6::AutoSort()
$*+F6::EnterSortManual()

; 回城：F=道具回城　G=技能回城　Delete=切光/暗
$*f::OneKeyTP("item")
$*g::OneKeyTP("skill")
$*Delete::ToggleSide()

; 英雄切换：空格已还给游戏（原来发 Tab，等于假 Tab，还占了"跳警报"）。
; 现在切英雄用：游戏原生 Tab（切下一个）+ 鼠标侧键（如果鼠标有的话）
$*XButton1::CycleHero(1)      ; 鼠标侧键「前进」
$*XButton2::CycleHero(-1)     ; 鼠标侧键「后退」
^Space::ScanHeroes()

; 鼠标中键（滚轮往下按）= H（保持原位 Hold Position），英雄站住不乱追
; 想关掉：ini 里 mbutton_hold=0
$*MButton::HoldPosition()

;---------------------- 血量监测 / 一键加血 ----------------------
; F11       报血量：安全一声高音 / 有低血两声 / 有人快死三声急促低音
; Alt+Q     一键加血：自动选中圣骑 → 举加血技能 → 点血量最低的那个英雄
$*F11::CheckHP()
; Alt+Q 一键加血已按用户要求取消（魔兽那边点头像当目标的时机控制不住，不可靠）

; Alt+W：牛头闪现 + 践踏一键连招
;   ① 记住你此刻的鼠标位置（= 落点）
;   ② 切到牛头
;   ③ 点第 6 格匕首
;   ④ 点回落点（闪烁过去）
;   ⑤ 按 W 踩
; Alt+W 已取消（用户要求只用 N）

BlinkStomp() {
    global IniFile, BlinkBusy
    if (Blocked(""))
        return
    if (BlinkBusy)                     ; 连按保护：上一套没做完，忽略新的
        return
    BlinkBusy := true
    try {
        MouseGetPos(&mx, &my)                 ; 落点 = 你现在鼠标的位置

        ; 先切到牛头（不然匕首在别人身上用，闪现的就不是牛头）
        if (Integer(IniRead(IniFile, "cfg", "blink_switch_hero", "1")) = 1) {
            hs := Integer(IniRead(IniFile, "cfg", "blink_hero_slot", "4"))
            hp := ReadPos("hero" . hs)
            if (hp != "") {
                Log("闪现① 点牛头头像 " . hs . " @(" . hp[1] . "," . hp[2] . ")")
                ClickPoint(hp)                ; 单击头像 = 选中牛头
                Sleep(Integer(IniRead(IniFile, "cfg", "blink_pre_gap", "120")))
            }
        }

        ; 点匕首
        slot := Integer(IniRead(IniFile, "cfg", "blink_item_slot", "6"))
        if !(ClickPos("item" . slot)) {
            Log("闪现失败：物品" . slot . " 没有坐标")
            SoundBeep(300, 180)
            return
        }
        Log("闪现② 点匕首(物品" . slot . ")")
        Sleep(Integer(IniRead(IniFile, "cfg", "blink_dagger_gap", "80")))

        ; 点落点 —— 这一步就是原来要你自己左键点的那个
        Log("闪现③ 点落点(" . mx . "," . my . ")")
        ClickPoint([mx, my])
        Sleep(Integer(IniRead(IniFile, "cfg", "blink_land_gap", "220")))

        ; 衔接 W（践踏）
        skill := Integer(IniRead(IniFile, "cfg", "blink_stomp_skill", "2"))
        if (skill <= 0) {                      ; 设成 0 = 只闪现，不踩（用来排查）
            Log("闪现④ 按配置跳过踩（blink_stomp_skill=0）")
            MouseMove(mx, my, 0)
            SoundBeep(1600, 70)
            return
        }
        Log("闪现④ 点技能" . skill)
        ok := ClickPos("skill" . skill)
        MouseMove(mx, my, 0)                  ; 鼠标放回你原本的位置
        if (ok) {
            SoundBeep(1600, 70)
            Log("闪现+践踏：匕首(物品" . slot . ") → 落点(" . mx . "," . my . ") → 技能" . skill)
        } else {
            Log("闪现完成，但技能" . skill . " 没有坐标，W 没按出去")
            SoundBeep(500, 120)
        }
    } finally {
        BlinkBusy := false
    }
}

; 跑一次血量检测，返回 {min, slot, low, crit}
RunHP() {
    global IniFile
    py := IniRead(IniFile, "cfg", "python_exe", "C:\Program Files\Python312\python.exe")
    sc := A_ScriptDir . "\hpcheck.py"
    if (!FileExist(py) || !FileExist(sc)) {
        Log("血量检测不可用：缺 python 或 hpcheck.py")
        return ""
    }
    try RunWait('"' . py . '" "' . sc . '"', A_ScriptDir, "Hide")
    catch {
        Log("血量检测调用失败")
        return ""
    }
    f := A_ScriptDir . "\hp_state.txt"
    if !FileExist(f)
        return ""
    s := Trim(FileRead(f, "UTF-8"))
    if InStr(s, "error") {
        Log("血量检测：" . s)
        return ""
    }
    st := {min: 100, slot: 0, low: 0, crit: 0, raw: s}
    if RegExMatch(s, "min=(-?\d+)", &m1)
        st.min := Integer(m1[1])
    if RegExMatch(s, "slot=(\d+)", &m2)
        st.slot := Integer(m2[1])
    if RegExMatch(s, "low=(\d+)", &m3)
        st.low := Integer(m3[1])
    if RegExMatch(s, "crit=(\d+)", &m4)
        st.crit := Integer(m4[1])
    return st
}

; F11：只报不治
CheckHP() {
    st := RunHP()
    if (st = "") {
        SoundBeep(300, 200)
        return
    }
    Log("血量：" . st.raw)
    if (st.crit > 0) {
        loop 3 {
            SoundBeep(400, 90)
            Sleep(70)
        }
    } else if (st.low > 0) {
        loop 2 {
            SoundBeep(700, 90)
            Sleep(80)
        }
    } else {
        SoundBeep(1400, 70)
    }
}

; Alt+Q：一键加血（打给血量最低的那个英雄）
AutoHeal() {
    global IniFile
    if (Integer(IniRead(IniFile, "cfg", "auto_heal", "1")) != 1)
        return
    st := RunHP()
    if (st = "" || st.slot = 0) {
        SoundBeep(300, 180)
        return
    }
    th := Integer(IniRead(IniFile, "cfg", "heal_threshold", "60"))
    if (st.min > th) {
        Log("血量都够（最低 " . st.min . "%），不用治")
        SoundBeep(1400, 60)
        return
    }
    healSlot := Integer(IniRead(IniFile, "cfg", "heal_hero_slot", "1"))   ; 圣骑在几号槽
    healSkill := Integer(IniRead(IniFile, "cfg", "heal_skill_slot", "1")) ; 加血是技能第几格

    heroP  := ReadPos("hero" . healSlot)
    target := ReadPos("hero" . st.slot)
    if (heroP = "" || target = "") {
        Log("缺头像坐标，无法自动加血")
        SoundBeep(300, 180)
        return
    }
    Log("一键加血：槽" . st.slot . " 只有 " . st.min . "%，切圣骑(槽" . healSlot . ")施法")

    ClickPoint(heroP)          ; 选中圣骑
    Sleep(120)
    ClickPos("skill" . healSkill)   ; 举起加血技能
    Sleep(Integer(IniRead(IniFile, "cfg", "heal_gap", "160")))   ; 等游戏真的进入"选择目标"状态
    ClickPoint(target)         ; 点残血英雄的头像当目标
    Sleep(80)
    SoundBeep(1600, 70)
    Log("加血：圣骑(槽" . healSlot . ") → 槽" . st.slot . "（" . st.min . "%）")
}

HoldPosition() {
    global IniFile, LastHold
    ; 暂停或正在打字：把中键原样还回去
    if (Blocked("")) {
        Send("{Blind}{MButton}")
        return
    }
    if (Integer(IniRead(IniFile, "cfg", "mbutton_hold", "1")) != 1) {
        Send("{Blind}{MButton}")
        return
    }
    Send("{Blind}h")
    if (A_TickCount - LastHold > 800) {        ; 中键可能连按，日志别刷屏
        LastHold := A_TickCount
        Log("中键 → H 保持原位")
    }
}

; Ctrl+Alt+T：把当前 3 个头像登记成指纹（圣骑/牛头/小黑），以后能按名字找
^!t::TagHeroes()

TagHeroes() {
    global IniFile, HeroSlotCache
    py := IniRead(IniFile, "cfg", "python_exe", "C:\Program Files\Python312\python.exe")
    hp := A_ScriptDir . "\heroes2.py"
    if (!FileExist(py) || !FileExist(hp)) {
        Log("找不到 python 或 heroes2.py")
        SoundBeep(400, 150)
        return
    }
    ToolTip("正在登记英雄头像…")
    try RunWait('"' . py . '" "' . hp . '" tag', A_ScriptDir, "Hide")
    ToolTip()
    HeroSlotCache := 0          ; 重新登记后清缓存，下次传送重新找
    SoundBeep(1700, 140)
    Log("英雄头像指纹已登记")
}

; Ctrl+Alt+1/2/3：直接指定"传送后切到第几号英雄"（按当前阵营写入配置）
^!1::SetTPHero(1)
^!2::SetTPHero(2)
^!3::SetTPHero(3)

SetTPHero(n) {
    global Side, IniFile
    IniWrite(String(n), IniFile, "cfg", "tp_to_hero_" . Side)
    Log("设定 " . Side . " 传送后切 " . n . " 号英雄")
    ToolTip("已设定：" . ((Side = "light") ? "光盟" : "黑暗") . " 传送后切 " . n . " 号英雄")
    SoundBeep(1500, 90)
    SetTimer(() => ToolTip(), -1600)
}

; Ctrl+Alt+空格：采"空槽基准"（此刻有槽位空着时按，之后识别最准）
^!Space::ScanHeroBase()

ScanHeroBase() {
    global IniFile
    py := IniRead(IniFile, "cfg", "python_exe", "C:\Program Files\Python312\python.exe")
    hp := A_ScriptDir . "\heroes.py"
    if (!FileExist(py) || !FileExist(hp)) {
        Log("找不到 python 或 heroes.py")
        SoundBeep(400, 150)
        return
    }
    ToolTip("正在采集空槽基准…")
    try RunWait('"' . py . '" "' . hp . '" baseline', A_ScriptDir, "Hide")
    ToolTip()
    SoundBeep(1500, 140)
    Log("已采集空槽基准")
}

; 聊天保护：回车开/关聊天框时切换状态，Esc 也视为退出输入
~Enter:: {
    global ChatMode
    ChatMode := !ChatMode
}
~NumpadEnter:: {
    global ChatMode
    ChatMode := !ChatMode
}
~Esc:: {
    global ChatMode
    ChatMode := false
}

#HotIf

;---------------------- 整理模式（F6 之后生效）---------------------
#HotIf (SortMode > 0)
1::SortPick(1)
2::SortPick(2)
3::SortPick(3)
4::SortPick(4)
5::SortPick(5)
6::SortPick(6)
Numpad1::SortPick(1)
Numpad2::SortPick(2)
Numpad3::SortPick(3)
Numpad4::SortPick(4)
Numpad5::SortPick(5)
Numpad6::SortPick(6)
Esc:: {
    global SortMode
    SortMode := 0
    ToolTip()
    Log("整理模式：已取消")
}
#HotIf

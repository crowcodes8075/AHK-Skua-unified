#Requires AutoHotkey v2.0
#SingleInstance Force
#Include UIA.ahk

; --- Ultra-Performance Settings ---
SetWinDelay(-1)
SetControlDelay(-1)
SetKeyDelay(-1, -1)
SetStoreCapslockMode(false)
SetCapsLockState("AlwaysOff")
SetMouseDelay(-1)

; --- YOUR CUSTOM COORDINATES ---
Global OptX := 860, OptY := 567
Global LogX := 844, LogY := 460

Global LayoutFile        := A_ScriptDir "\SkuaLayout.ini"
Global ManagerLayoutFile := A_ScriptDir "\SkuaManagerLayout.ini"
Global BoundIDs := []
`::F2

ShowTip(text) {
    ToolTip(text)
    SetTimer(() => ToolTip(), -1000)
}

; --- Window Filters ---

IsRealSkuaClient(id) {
    try {
        return ControlGetHwnd("MacromediaFlashPlayerActiveX1", "ahk_id " id) != 0
    } catch {
        return false
    }
}

GetAllSkuaWindows() {
    ids := WinGetList("ahk_exe skua.exe")
    clients := [], scripts := []
    for id in ids {
        title := WinGetTitle(id)
        if InStr(title, "Skua -") && IsRealSkuaClient(id)
            clients.Push(id)
        else if InStr(title, "Load Script")
            scripts.Push(id)
    }
    return {clients: clients, scripts: scripts}
}

GetSkuaManagers() {
    return WinGetList("ahk_exe Skua.Manager.exe")
}

; --- Hotkeys ---

; CAPSLOCK + Q: Restore Forward — client 1 ends on top (top-left visible)
Capslock & q:: {
    w := GetAllSkuaWindows()
    RestoreByLayout("Client",     "forward", w.clients)
    RestoreByLayout("LoadScript", "forward", w.scripts)
}

; CAPSLOCK + W: Restore Reverse — client 4 ends on top (bottom-right visible)
Capslock & w:: {
    w := GetAllSkuaWindows()
    RestoreByLayout("Client",     "reverse", w.clients)
    RestoreByLayout("LoadScript", "reverse", w.scripts)
}

; CAPSLOCK + E: Minimize All
Capslock & e:: {
    w := GetAllSkuaWindows()
    for id in w.clients
        DllCall("ShowWindow", "Ptr", id, "Int", 6)
    for id in w.scripts
        DllCall("ShowWindow", "Ptr", id, "Int", 6)
}

; CAPSLOCK + R: Toggle Bots via UIA (Stop Script / Load Script)
Capslock & r:: {
    global UIA
    wins := GetAllSkuaWindows()

    if (wins.scripts.Length = 0) {
        ToolTip("No Load Script windows found!")
        SetTimer(() => ToolTip(), -1000)
        return
    }

    for id in wins.scripts {
        if !WinExist(id)
            continue
        try {
            root      := UIA.ElementFromHandle(id)
            statusEl  := root.FindElement({Type: "Text", MatchMode: "SubString", Name: "Status:"})
            statusText := statusEl.Name

            if InStr(statusText, "Running")
                root.FindElement({Name: "Stop Script", Type: "Button"}).Invoke()
            else
                root.FindElement({Name: "Load Script", Type: "Button"}).Invoke()
        } catch {
            try root.FindElement({Name: "Stop Script", Type: "Button"}).Invoke()
            catch
                try root.FindElement({Name: "Load Script", Type: "Button"}).Invoke()
        }
    }

    ShowTip("Bots Toggled")
}

; CAPSLOCK + 2: Logout via Flash ControlClick (no window activation needed)
Capslock & 2:: {
    ids := GetAllSkuaWindows().clients
    if (ids.Length = 0)
        return

    for id in ids {
        if !WinExist(id)
            continue
        try {
            FlashHwnd := ControlGetHwnd("MacromediaFlashPlayerActiveX1", "ahk_id " id)
            ControlClick("x" (OptX-2) " y" (OptY-58), "ahk_id " FlashHwnd,, "Left", 1, "NA")
            Sleep(400)
            ControlClick("x" (LogX-2) " y" (LogY-58), "ahk_id " FlashHwnd,, "Left", 1, "NA")
            Sleep(150)
        }
    }

    ShowTip("Logged Out Safely")
}

; CAPSLOCK + 3: Nuke (Force Close)
Capslock & 3:: {
    ids := GetAllSkuaWindows().clients
    for id in ids {
        if WinExist(id)
            PostMessage(0x0010, 0, 0,, "ahk_id " id)
    }
    ShowTip("Terminated")
}

; CAPSLOCK + 4: Lock & Save Layout (both groups)
Capslock & 4:: {
    w := GetAllSkuaWindows()
    clients := w.clients
    scripts := w.scripts

    if (clients.Length = 0 && scripts.Length = 0) {
        ShowTip("No Skua windows found!")
        return
    }

    try FileDelete(LayoutFile)

    try {
        sortedClients := SortByCoords(clients)
        global BoundIDs := sortedClients

        for index, id in sortedClients {
            WinGetPos(&x, &y, &w, &h, id)
            IniWrite(x, LayoutFile, "Client" index, "x"), IniWrite(y, LayoutFile, "Client" index, "y")
            IniWrite(w, LayoutFile, "Client" index, "w"), IniWrite(h, LayoutFile, "Client" index, "h")
        }
        IniWrite(sortedClients.Length, LayoutFile, "Meta", "clientCount")

        sortedScripts := SortByCoords(scripts)
        for index, id in sortedScripts {
            WinGetPos(&x, &y, &w, &h, id)
            IniWrite(x, LayoutFile, "LoadScript" index, "x"), IniWrite(y, LayoutFile, "LoadScript" index, "y")
            IniWrite(w, LayoutFile, "LoadScript" index, "w"), IniWrite(h, LayoutFile, "LoadScript" index, "h")
        }
        IniWrite(sortedScripts.Length, LayoutFile, "Meta", "scriptCount")

        SoundBeep(750, 100)
        ShowTip("Layout Locked (" clients.Length " clients, " scripts.Length " load scripts)")
    } catch Error as e {
        MsgBox("Error: " e.Message)
    }
}

; CAPSLOCK + 5: Lock & Save Manager Layout
Capslock & 5:: {
    managers := GetSkuaManagers()

    if (managers.Length = 0) {
        ShowTip("No Skua Manager windows found!")
        return
    }

    try FileDelete(ManagerLayoutFile)

    try {
        sortedManagers := SortByCoords(managers)
        for index, id in sortedManagers {
            WinGetPos(&x, &y, &w, &h, id)
            IniWrite(x, ManagerLayoutFile, "Manager" index, "x"), IniWrite(y, ManagerLayoutFile, "Manager" index, "y")
            IniWrite(w, ManagerLayoutFile, "Manager" index, "w"), IniWrite(h, ManagerLayoutFile, "Manager" index, "h")
        }
        IniWrite(sortedManagers.Length, ManagerLayoutFile, "Meta", "managerCount")

        SoundBeep(750, 100)
        ShowTip("Manager Layout Locked (" managers.Length " managers)")
    } catch Error as e {
        MsgBox("Error: " e.Message)
    }
}

; CAPSLOCK + 6: Live Bot Status Readout
Capslock & 6:: {
    global UIA
    wins   := GetAllSkuaWindows()
    result := ""

    for id in wins.scripts {
        if !WinExist(id)
            continue
        try {
            root     := UIA.ElementFromHandle(id)
            statusEl := root.FindElement({Type: "Text", MatchMode: "SubString", Name: "Status:"})
            result   .= WinGetTitle("ahk_id " id) " → " statusEl.Name "`n"
        } catch {
            result .= "HWND " id " → (could not read status)`n"
        }
    }

    MsgBox(result ? result : "No Load Script windows found.", "Bot Status")
}

; CAPSLOCK + Z: Restore Managers Forward — Manager 1 ends on top
Capslock & z:: RestoreManagerGroup("forward")

; CAPSLOCK + X: Restore Managers Reverse — last Manager ends on top
Capslock & x:: RestoreManagerGroup("reverse")

; CAPSLOCK + C: Minimize All Managers
Capslock & c:: {
    managers := GetSkuaManagers()
    if (managers.Length = 0) {
        ShowTip("No Skua Manager windows found!")
        return
    }
    for id in managers
        DllCall("ShowWindow", "Ptr", id, "Int", 6)
}

; CAPSLOCK + T: WindowPlacement Debug
Capslock & t:: {
    ids    := GetAllSkuaWindows().clients
    result := ""
    for id in ids {
        WP := Buffer(44, 0)
        NumPut("UInt", 44, WP, 0)
        DllCall("GetWindowPlacement", "Ptr", id, "Ptr", WP.Ptr)
        rx      := NumGet(WP, 28, "Int")
        ry      := NumGet(WP, 32, "Int")
        showCmd := NumGet(WP, 8, "UInt")
        result  .= "HWND " id " — restore x=" rx " y=" ry " showCmd=" showCmd "`n"
    }
    MsgBox(result, "WindowPlacement Debug")
}

; F4: UIA Element Inspector — focus a Load Script window first
F4:: {
    global UIA
    hwnd  := WinGetID("A")
    title := WinGetTitle("ahk_id " hwnd)

    if !InStr(title, "Load Script") {
        ToolTip("Focus on a 'Load Script' window first!")
        SetTimer(() => ToolTip(), -1000)
        return
    }

    try {
        root := UIA.ElementFromHandle(hwnd)
    } catch Error as e {
        MsgBox("UIA failed to attach: " e.Message)
        return
    }

    output  := "=== UIA Tree for: " title " ===`n`n"
    output  .= DumpUIATree(root, 0)

    logPath := A_ScriptDir "\UIA_Dump.txt"
    try FileDelete(logPath)
    FileAppend(output, logPath)

    result := MsgBox(
        "UIA tree dumped! " StrLen(output) " chars.`n`nFile: " logPath "`n`nOpen it now?",
        "UIA Dump Complete",
        "YesNo"
    )
    if (result = "Yes")
        Run("notepad.exe `"" logPath "`"")
}

DumpUIATree(el, depth) {
    indent := ""
    loop depth
        indent .= "  "

    name := "", type := "", autoId := "", cls := "", val := "", rect := ""

    try name   := el.Name
    try type   := UIA.Type[el.Type]
    try autoId := el.AutomationId
    try cls    := el.ClassName
    try val    := el.Value
    try {
        r    := el.BoundingRectangle
        rect := "x" r.l " y" r.t " w" (r.r - r.l) " h" (r.b - r.t)
    }

    line := indent
        . "[" type "]"
        . (name   ? " Name=`""   name   "`"" : "")
        . (autoId ? " AutoId=`"" autoId "`"" : "")
        . (cls    ? " Class=`""  cls    "`"" : "")
        . (val    ? " Value=`""  val    "`"" : "")
        . (rect   ? " Rect=("    rect   ")"  : "")
        . "`n"

    try {
        children := el.GetChildren()
        for child in children
            line .= DumpUIATree(child, depth + 1)
    }

    return line
}

; --- Core Engine ---

RestoreWindow(id, x, y, w, h) {
    if (WinGetMinMax("ahk_id " id) = -1)
        SetRestorePos(id, x, y, w, h)
    else
        WinMove(x, y, w, h, "ahk_id " id)
}

SetRestorePos(hwnd, x, y, w, h) {
    WP := Buffer(44, 0)
    NumPut("UInt", 44, WP,  0)
    NumPut("UInt",  0, WP,  4)
    NumPut("UInt",  2, WP,  8)
    NumPut("Int",  -1, WP, 12)
    NumPut("Int",  -1, WP, 16)
    NumPut("Int",  -1, WP, 20)
    NumPut("Int",  -1, WP, 24)
    NumPut("Int",   x, WP, 28)
    NumPut("Int",   y, WP, 32)
    NumPut("Int", x+w, WP, 36)
    NumPut("Int", y+h, WP, 40)
    DllCall("SetWindowPlacement", "Ptr", hwnd, "Ptr", WP.Ptr)
    ; removed ShowWindow(9) — WinActivate in pass 2 handles the restore
}

RestoreByLayout(group, direction, ids) {
    section := (group = "Client") ? "Client" : "LoadScript"
    metaKey := (group = "Client") ? "clientCount" : "scriptCount"
    if !FileExist(LayoutFile)
        return

    try
        count := Integer(IniRead(LayoutFile, "Meta", metaKey))
    catch
        return

    ordered := MatchWindowsToSlots(ids, section, count)

    ; Pass 1 — restore all positions first
    loop count {
        i   := A_Index
        idx := (direction = "reverse") ? (count - i + 1) : i
        if !ordered.Has(idx)
            continue
        id := ordered[idx]
        if !WinExist(id)
            continue
        try {
            x := IniRead(LayoutFile, section idx, "x")
            y := IniRead(LayoutFile, section idx, "y")
            w := IniRead(LayoutFile, section idx, "w")
            h := IniRead(LayoutFile, section idx, "h")
            RestoreWindow(id, x, y, w, h)
        } catch {
            WinRestore(id)
        }
    }

    Sleep(50)

    ; Pass 2 — activate in order so z-order stacks correctly
    loop count {
        i   := A_Index
        idx := (direction = "reverse") ? (count - i + 1) : i
        if !ordered.Has(idx)
            continue
        id := ordered[idx]
        if !WinExist(id)
            continue
        WinActivate(id)
        Sleep(10)
    }
}
MatchWindowsToSlots(ids, section, count) {
    slots := Map()
    loop count {
        try {
            x := Integer(IniRead(LayoutFile, section A_Index, "x"))
            y := Integer(IniRead(LayoutFile, section A_Index, "y"))
            slots[A_Index] := {x: x, y: y}
        }
    }

    winPositions := []
    for id in ids {
        WP := Buffer(44, 0)
        NumPut("UInt", 44, WP, 0)
        DllCall("GetWindowPlacement", "Ptr", id, "Ptr", WP.Ptr)
        rx := NumGet(WP, 28, "Int")
        ry := NumGet(WP, 32, "Int")
        winPositions.Push({id: id, x: rx, y: ry})
    }

    result := Map()
    used   := Map()
    for slotIdx, slotPos in slots {
        bestID   := 0
        bestDist := 999999
        for wp in winPositions {
            if used.Has(wp.id)
                continue
            dist := Abs(wp.x - slotPos.x) + Abs(wp.y - slotPos.y)
            if (dist < bestDist) {
                bestDist := dist
                bestID   := wp.id
            }
        }
        if bestID {
            result[slotIdx] := bestID
            used[bestID]    := true
        }
    }
    return result
}

RestoreManagerGroup(direction) {
    ids := GetSkuaManagers()
    if !FileExist(ManagerLayoutFile) {
        for id in ids
            WinRestore(id)
        return
    }

    try
        count := Integer(IniRead(ManagerLayoutFile, "Meta", "managerCount"))
    catch
        return

    slots := Map()
    loop count {
        try {
            x := Integer(IniRead(ManagerLayoutFile, "Manager" A_Index, "x"))
            y := Integer(IniRead(ManagerLayoutFile, "Manager" A_Index, "y"))
            slots[A_Index] := {x: x, y: y}
        }
    }

    winPositions := []
    for id in ids {
        WP := Buffer(44, 0)
        NumPut("UInt", 44, WP, 0)
        DllCall("GetWindowPlacement", "Ptr", id, "Ptr", WP.Ptr)
        rx := NumGet(WP, 28, "Int")
        ry := NumGet(WP, 32, "Int")
        winPositions.Push({id: id, x: rx, y: ry})
    }

    ordered := Map()
    used    := Map()
    for slotIdx, slotPos in slots {
        bestID   := 0
        bestDist := 999999
        for wp in winPositions {
            if used.Has(wp.id)
                continue
            dist := Abs(wp.x - slotPos.x) + Abs(wp.y - slotPos.y)
            if (dist < bestDist) {
                bestDist := dist
                bestID   := wp.id
            }
        }
        if bestID {
            ordered[slotIdx] := bestID
            used[bestID]     := true
        }
    }

    loop count {
        i   := A_Index
        idx := (direction = "reverse") ? (count - i + 1) : i
        if !ordered.Has(idx)
            continue
        id := ordered[idx]
        if !WinExist(id)
            continue
        try {
            x := IniRead(ManagerLayoutFile, "Manager" idx, "x")
            y := IniRead(ManagerLayoutFile, "Manager" idx, "y")
            w := IniRead(ManagerLayoutFile, "Manager" idx, "w")
            h := IniRead(ManagerLayoutFile, "Manager" idx, "h")
            RestoreWindow(id, x, y, w, h)
        } catch {
            WinRestore(id)
        }
        WinActivate(id)
    }
}

SortByCoords(ids) {
    temp := []
    for id in ids {
        if WinExist(id) {
            WinGetPos(&x, &y,,, id)
            temp.Push({id: id, x: x, y: y})
        }
    }

    loop temp.Length - 1 {
        i := A_Index
        loop temp.Length - i {
            j := A_Index
            a := temp[j], b := temp[j + 1]
            if (a.x > b.x || (a.x = b.x && a.y > b.y)) {
                temp[j]     := b
                temp[j + 1] := a
            }
        }
    }

    sorted := []
    for item in temp
        sorted.Push(item.id)
    return sorted
}

; ─── Study Hotkeys ───────────────────────────────────────────────────────────

#HotIf !WinActive("ahk_exe skua.exe")
XButton2:: Send("^+v")
XButton1:: {
    Click()
    Send("^a")
    Send("{BackSpace}")
}
CapsLock & s:: {
    Send("{Blind}{CapsLock Up}{s Up}")
    try Run("ms-screenclip:")
}
CapsLock & d:: Send("{f6}")
#HotIf

; Okular navigation
#HotIf WinActive("ahk_exe okular.exe")
s:: Send("{Up}")
d:: Send("{Down}")
q:: Send("{Up}")
w:: Send("{Down}")
#HotIf
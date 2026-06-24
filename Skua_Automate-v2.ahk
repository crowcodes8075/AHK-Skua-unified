#Requires AutoHotkey v2.0
#Include UIA.ahk

#SingleInstance Force

LayoutFile := A_ScriptDir "\SkuaLayout.ini"
global g_ManagerPID            := 0
global g_SeenHwnds             := Map()
global g_Restarting            := false
global g_PopupDuringRestart    := false
global g_NextCycleAt           := 0
global g_CycleAttempts         := 0
global g_ScreenH               := SysGet(1)
global g_LogGui                := 0
global g_LogEdit               := 0
global g_LogFile               := A_ScriptDir "\log.txt"
global g_ClientCount           := 4

global g_LogGui  := 0
global g_LogEdit := 0
global g_LogFile := A_ScriptDir "\log.txt"

global UIA_Sel := Map()

global g_LogsAllowed := false

global g_StuckConsecutive := Map()   ; clientHwnd -> consecutive stuck poll count
global g_StuckLastEntry   := Map()   ; clientHwnd -> previous last log entry text
global g_StuckLogsCache   := Map()   ; clientHwnd -> logsHwnd

global __SkuaCache_Windows := { value: "", timestamp: 0 }
global __SkuaCache_Clients  := { value: "", timestamp: 0 }
global __SkuaCache_TTL := 2000   ; milliseconds

; Clear log on each fresh script start
try FileDelete(g_LogFile)

; Start the WinEvent hook immediately — runs for the entire script lifetime
HookStart()

; ─── Tray Countdown ─────────────────────────────────────────────────────────

A_IconTip := "Skua - Idle (press F9 to start)"
SetTimer(CountdownTick, 1000)

CountdownTick() {
    global g_NextCycleAt, g_Restarting
    if g_Restarting
        return
    if g_NextCycleAt = 0
        return
    remaining := g_NextCycleAt - A_TickCount
    if remaining < 0
        remaining := 0
    ms  := Mod(remaining, 1000)
    sec := Mod(remaining // 1000, 60)
    min := Mod(remaining // 60000, 60)
    hrs := remaining // 3600000
    A_IconTip := "Skua - Running | Next cycle: "
        . Format("{:02}:{:02}:{:02}.{:03}", hrs, min, sec, ms)
}

; ─── Helpers (only those that are not in SkuaHelpers.ahk) ───────────────────

GetLogsWindows() {
    logs := []
    for id in WinGetList("ahk_exe skua.exe") {
        if (WinGetTitle("ahk_id " id) = "Logs")
            logs.Push(id)
    }
    return logs
}

AreLogsVisible(logsWindows) {
    for id in logsWindows {
        WinGetPos(&x, &y,,, "ahk_id " id)
        if (x > -1000 && y > -1000)
            return true
    }
    return false
}

; ==================================================================
; SkuaLog.ahk – Log window and enhanced logging with line numbers
; ==================================================================

LogMsg(text) {
    global g_LogGui, g_LogEdit, g_LogFile

    callerInfo := ""
    try {
        throw
    } catch as err {
        stackLines := StrSplit(err.Stack, "`n")
        if stackLines.Length >= 2 {
            callerLine := stackLines[2]
            if RegExMatch(callerLine, "\((\d+)\)\s*:\s*\[(.*?)\]", &match) {
                callerInfo := " [" match[2] ":" match[1] "]"
            } else if RegExMatch(callerLine, "\((\d+)\)", &match) {
                callerInfo := " [line " match[1] "]"
            }
        }
    }

    timestamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    line := "[" timestamp "] " text callerInfo "`n"
    FileAppend(line, g_LogFile, "UTF-8")

    if IsObject(g_LogEdit) && WinExist("ahk_id " g_LogGui.Hwnd) {
        g_LogEdit.Value .= line
        SendMessage(0x115, 7, 0, g_LogEdit)  ; scroll to bottom
    }
}

OpenLogWindow() {
    global g_LogGui, g_LogEdit, g_LogFile
    if g_LogGui && WinExist("ahk_id " g_LogGui.Hwnd) {
        WinShow("ahk_id " g_LogGui.Hwnd)
        return
    }
    g_LogGui := Gui("+Resize", "Skua Log")
    g_LogGui.OnEvent("Close", (*) => CloseLogWindow())
    g_LogGui.OnEvent("Size",  OnLogResize)
    existing := ""
    if FileExist(g_LogFile)
        existing := FileRead(g_LogFile, "UTF-8")
    g_LogEdit := g_LogGui.Add("Edit", "x5 y5 w590 h390 +ReadOnly +Multi +VScroll -Wrap", existing)
    g_LogGui.Show("w600 h400")
    SendMessage(0x115, 7, 0, g_LogEdit)
}

CloseLogWindow() {
    global g_LogGui, g_LogEdit
    if g_LogGui {
        g_LogGui.Destroy()
        g_LogGui  := 0
        g_LogEdit := 0
    }
}

OnLogResize(guiObj, minMax, width, height) {
    global g_LogEdit
    if (minMax = -1)
        return
    g_LogEdit.Move(5, 5, width - 10, height - 10)
}

; ==================================================================
; SkuaHelpers.ahk
; Centralised UIA selectors, wait functions, and cached window queries
; ==================================================================

UIA_Sel["AccountsTab"]   := {Type: 50020, Name: "Accounts"}
UIA_Sel["ScriptsTab"]    := {Type: 50020, Name: "Scripts"}
UIA_Sel["LogsTab"]       := {Type: 50020, Name: "Logs"}
UIA_Sel["FlashTab"]      := {Type: 50020, Name: "Flash"}
UIA_Sel["StopScriptBtn"] := {Name: "Stop Script", Type: "Button"}
UIA_Sel["StartSelectedBtn"] := {Name: "Start Selected"}

UIA_Selector(name) {
    global UIA_Sel
    if UIA_Sel.Has(name)
        return UIA_Sel[name]
    throw ValueError("Unknown UIA selector: " name)
}

WaitForUIElement(parent, selector, timeout := 5000, scope := 4) {
    parts := []
    if selector.HasOwnProp("Type")
        parts.Push("Type:" selector.Type)
    if selector.HasOwnProp("Name")
        parts.Push("Name:" selector.Name)
    if selector.HasOwnProp("AutomationId")
        parts.Push("AutomationId:" selector.AutomationId)
    if selector.HasOwnProp("ClassName")
        parts.Push("ClassName:" selector.ClassName)
    desc := "{" . Join(parts, ", ") . "}"
    LogMsg("Waiting for UI element: " desc " (timeout " timeout "ms)")
    el := parent.WaitElement(selector, timeout, scope)
    if !el
        throw TargetError("Element not found after " timeout "ms: " desc)
    LogMsg("  -> Element found.")
    return el
}

Join(arr, delim) {
    out := ""
    for v in arr
        out .= delim . v
    return SubStr(out, StrLen(delim)+1)
}

WaitForWindowByTitle(titlePattern, timeout := 5000) {
    endTime := A_TickCount + timeout
    while (A_TickCount < endTime) {
        if hwnd := WinExist(titlePattern)
            return hwnd
        Sleep(50)
    }
    LogMsg("Window not found: " titlePattern)
    return 0
}

ClearSkuaWindowCache() {
    global __SkuaCache_Windows, __SkuaCache_Clients
    __SkuaCache_Windows.value := ""
    __SkuaCache_Windows.timestamp := 0
    __SkuaCache_Clients.value := ""
    __SkuaCache_Clients.timestamp := 0
    LogMsg("Skua window cache cleared.")
}

GetAllSkuaWindows() {
    global __SkuaCache_Windows, __SkuaCache_TTL
    now := A_TickCount
    if (__SkuaCache_Windows.value != "" && (now - __SkuaCache_Windows.timestamp) < __SkuaCache_TTL) {
        return __SkuaCache_Windows.value
    }
    ids := WinGetList("ahk_exe skua.exe")
    clients := [], scripts := []
    for id in ids {
        title := WinGetTitle(id)
        if InStr(title, "Skua -") && IsRealSkuaClient(id) {
            clients.Push(id)
        } else if InStr(title, "Load Script") {
            scripts.Push(id)
        }
    }
    result := { clients: clients, scripts: scripts }
    __SkuaCache_Windows.value := result
    __SkuaCache_Windows.timestamp := now
    return result
}

GetRealClients() {
    global __SkuaCache_Clients, __SkuaCache_TTL
    now := A_TickCount
    if (__SkuaCache_Clients.value != "" && (now - __SkuaCache_Clients.timestamp) < __SkuaCache_TTL) {
        return __SkuaCache_Clients.value
    }
    clients := GetAllSkuaWindows().clients
    __SkuaCache_Clients.value := clients
    __SkuaCache_Clients.timestamp := now
    return clients
}

GetLoadScripts() {
    return GetAllSkuaWindows().scripts
}

IsRealSkuaClient(id) {
    try {
        return ControlGetHwnd("MacromediaFlashPlayerActiveX1", "ahk_id " id) != 0
    } catch {
        return false
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
                temp[j] := b
                temp[j + 1] := a
            }
        }
    }
    sorted := []
    for item in temp
        sorted.Push(item.id)
    return sorted
}

MinimizeToPos(hwnd, x, y, w, h) {
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
}

; ─── WinEvent Hook ──────────────────────────────────────────────────────────

IsRestartTriggerPopup(title) {
    static popups := Map(
        "SetOptions", 1
    )
    return popups.Has(title)
}

WinEventProc(hHook, event, hwnd, idObject, idChild, idThread, dwTime) {
    global g_ManagerPID, g_SeenHwnds, g_Restarting, g_PopupDuringRestart, g_NextCycleAt, g_LogsAllowed
    if (idObject != 0)
        return
    try {
        if (WinGetPID("ahk_id " hwnd) = g_ManagerPID)
            return
        if !InStr(WinGetProcessName("ahk_id " hwnd), "skua", false)
            return
    } catch {
        return
    }
    if g_SeenHwnds.Has(hwnd)
        return
    g_SeenHwnds[hwnd] := true
    title := WinGetTitle("ahk_id " hwnd)

    if InStr(title, "Load Script") {
        DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0,
            "Int", -10000, "Int", -10000, "Int", 0, "Int", 0, "UInt", 0x0015)
    }
    else if InStr(title, "Skua -") {
        DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 1,
            "Int", 0, "Int", g_ScreenH - 61, "Int", 61, "Int", 61, "UInt", 0x0010)
    }
    else if (title = "Logs") {
        if !g_LogsAllowed
            DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0,
                "Int", -2000, "Int", -2000, "Int", 0, "Int", 0, "UInt", 0x0015)
    }
    else if IsRestartTriggerPopup(title) {
        DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0,
            "Int", -2000, "Int", -2000, "Int", 0, "Int", 0, "UInt", 0x0015)
        if g_Restarting {
            g_PopupDuringRestart := true
            LogMsg("Popup during restart: '" title "' — will re-enter from Step 3 after clients appear.")
        } else if (g_NextCycleAt != 0) {
            LogMsg("Popup detected: '" title "' — restarting immediately.")
            A_IconTip := "Skua - Popup detected, restarting..."
            SetTimer(() => DoRestart(), -1)
        }
    }
}

HookStart() {
    global g_HookCallback := CallbackCreate(WinEventProc, "F", 7)
    DllCall("SetWinEventHook",
        "UInt", 0x8002,
        "UInt", 0x8002,
        "Ptr",  0,
        "Ptr",  g_HookCallback,
        "UInt", 0,
        "UInt", 0,
        "UInt", 0,
        "Ptr")
}

; ==================================================================
; SkuaStuck.ahk – Reliable stuck detection using last log entry
; ==================================================================

StuckStart(existingLogsMap := 0) {
    global g_StuckConsecutive, g_StuckLastEntry, g_StuckLogsCache
    g_StuckConsecutive := Map()
    g_StuckLastEntry   := Map()
    g_StuckLogsCache   := Map()

    if (existingLogsMap && existingLogsMap.Count > 0) {
        g_StuckLogsCache := existingLogsMap
    } else {
        for clientHwnd in GetRealClients() {
            clientPID := WinGetPID("ahk_id " clientHwnd)
            for id in WinGetList("ahk_exe skua.exe") {
                if (WinGetTitle("ahk_id " id) = "Logs") && (WinGetPID("ahk_id " id) = clientPID) {
                    g_StuckLogsCache[clientHwnd] := id
                    break
                }
            }
        }
    }

    for clientHwnd in g_StuckLogsCache {
        g_StuckConsecutive[clientHwnd] := 0
        g_StuckLastEntry[clientHwnd] := ""
    }

    SetTimer(StuckPoll, 5000)
    LogMsg("StuckMonitor — started (5s poll, threshold: 6 consecutive stuck entries, clients: " g_StuckLogsCache.Count ")")
}

StuckStop() {
    global g_StuckConsecutive, g_StuckLastEntry, g_StuckLogsCache
    SetTimer(StuckPoll, 0)
    g_StuckConsecutive := Map()
    g_StuckLastEntry   := Map()
    g_StuckLogsCache   := Map()
    LogMsg("StuckMonitor — stopped.")
}

StuckPoll() {
    global g_Restarting, g_NextCycleAt, g_StuckConsecutive, g_StuckLastEntry, g_StuckLogsCache

    if g_Restarting || g_NextCycleAt = 0
        return

    for clientHwnd, logsHwnd in g_StuckLogsCache {
        if !WinExist("ahk_id " logsHwnd)
            continue

        clientPID := WinGetPID("ahk_id " clientHwnd)
        lastEntry := StuckGetLastLogEntry(logsHwnd)
        
        if (lastEntry = "") {
            if (g_StuckConsecutive[clientHwnd] > 0) {
                LogMsg("StuckMonitor — [PID " clientPID "] log empty, resetting consecutive count.")
                g_StuckConsecutive[clientHwnd] := 0
            }
            continue
        }

        loginStuck := StuckIsLoginStuck(logsHwnd)
        if (loginStuck) {
            LogMsg("StuckMonitor — [PID " clientPID "] LOGIN STUCK detected (mcLogin + isNull). Triggering restart.")
            StuckStop()
            SetTimer(() => DoRestart(), -1)
            return
        }

        isReloadStuck := InStr(lastEntry, "world.reloadCurrentMap")

        if (isReloadStuck) {
            if (lastEntry = g_StuckLastEntry[clientHwnd]) {
                consecutive := g_StuckConsecutive[clientHwnd] + 1
                g_StuckConsecutive[clientHwnd] := consecutive
                LogMsg("StuckMonitor — [PID " clientPID "] reload stuck consecutive #" consecutive "/6")
                if (consecutive >= 6) {
                    LogMsg("StuckMonitor — [PID " clientPID "] STUCK CONFIRMED (30s of reload spam) — triggering DoRestart.")
                    StuckStop()
                    SetTimer(() => DoRestart(), -1)
                    return
                }
            } else {
                g_StuckConsecutive[clientHwnd] := 1
                LogMsg("StuckMonitor — [PID " clientPID "] new reload entry (consecutive reset to 1)")
            }
        } else {
            if (g_StuckConsecutive[clientHwnd] > 0) {
                LogMsg("StuckMonitor — [PID " clientPID "] recovered, resetting consecutive count.")
                g_StuckConsecutive[clientHwnd] := 0
            }
        }

        g_StuckLastEntry[clientHwnd] := lastEntry
    }
}

StuckGetLastLogEntry(logsHwnd) {
    try {
        root := UIA.ElementFromHandle(logsHwnd)
        items := root.FindElements({Type: "ListItem"}, 4)
        if items.Length = 0
            return ""
        lastItem := items[items.Length]
        name := lastItem.Name
        if (name != "" && !InStr(name, "LogTabViewModel"))
            return name
    } catch {
        return ""
    }
    return ""
}

StuckIsLoginStuck(logsHwnd) {
    try {
        root := UIA.ElementFromHandle(logsHwnd)
        items := root.FindElements({Type: "ListItem"}, 4)
        if items.Length < 2
            return false
        lastTwo := []
        loop 2 {
            idx := items.Length - (A_Index - 1)
            name := items[idx].Name
            if (name != "" && !InStr(name, "LogTabViewModel"))
                lastTwo.InsertAt(1, name)
        }
        if lastTwo.Length >= 2 {
            return InStr(lastTwo[1], "mcLogin") && InStr(lastTwo[2], "isNull Args[1] = {world}")
        }
    } catch {
        return false
    }
    return false
}

; ==================================================================
; SkuaRestart.ahk – Cycle timer and restart logic (improved)
; ==================================================================

CycleTick() {
    global g_Restarting
    if g_Restarting
        return
    LogMsg("70-minute cycle elapsed — triggering restart.")
    DoRestart()
}

DoRestart() {
    global g_ManagerPID, g_Restarting, g_PopupDuringRestart
    global g_NextCycleAt, g_SeenHwnds, g_CycleAttempts, g_ClientCount
    if g_Restarting
        return
    g_Restarting := true
    A_IconTip := "Skua - Restarting..."

    w := GetAllSkuaWindows()
    if (w.clients.Length > 0 || w.scripts.Length > 0) {
        LogMsg("Step 1/9 — Stopping all scripts via UIA...")
        for id in w.scripts {
            try {
                El := UIA.ElementFromHandle(id)
                stopBtn := WaitForUIElement(El, UIA_Sel["StopScriptBtn"], 3000)
                stopBtn.Invoke()
                LogMsg("  Stopped script on: " WinGetTitle(id))
            } catch
                LogMsg("  Could not stop script on: " WinGetTitle(id))
        }
        LogMsg("  Waiting 10s for saves...")
        Sleep(10000)

        LogMsg("Step 2/9 — Logging out all clients...")
        for id in w.clients {
            try {
                FlashHwnd := ControlGetHwnd("MacromediaFlashPlayerActiveX1", "ahk_id " id)
                ControlClick("x" (857-2) " y" (567-58), "ahk_id " FlashHwnd, , "Left", 1, "NA")
                Sleep(400)
                ControlClick("x" (844-2) " y" (460-58), "ahk_id " FlashHwnd, , "Left", 1, "NA")
                LogMsg("  Logged out: " WinGetTitle(id))
            }
        }
        Sleep(1000)
    } else {
        LogMsg("No clients or scripts found — skipping Steps 1-2, going straight to launch.")
    }

    loop {
        g_PopupDuringRestart := false
        g_SeenHwnds := Map()

        LogMsg("Step 3/9 — Closing all Skua windows (except Manager)...")
        nonManagerIds := []
        for id in WinGetList("ahk_exe skua.exe") {
            if InStr(WinGetTitle(id), "Skua Manager")
                continue
            nonManagerIds.Push(id)
            PostMessage(0x0010, 0, 0,, "ahk_id " id)
        }
        Sleep(2000)
        for id in nonManagerIds {
            try {
                pid := WinGetPID(id)
                if pid > 0 {
                    ProcessClose(pid)
                    if ProcessExist(pid)
                        RunWait("taskkill /F /PID " pid, , "Hide")
                }
            }
        }
        Sleep(1000)
        LogMsg("  Windows closed.")

        LogMsg("Step 4/9 — Relaunching clients via all Managers...")
        managerHwnds := []
        for id in WinGetList("ahk_exe Skua.Manager.exe") {
            if InStr(WinGetTitle(id), "Skua Manager")
                managerHwnds.Push(id)
        }

        if (managerHwnds.Length = 0) {
            g_Restarting := false
            A_IconTip := "Skua - ERROR: No Managers found"
            LogMsg("ERROR: No Skua Manager windows found.")
            return
        }

        g_ManagerPID := WinGetPID("ahk_id " managerHwnds[1])

        DllCall("LockWindowUpdate", "Ptr", DllCall("GetDesktopWindow", "Ptr"))

        launched      := false
        popupRelaunch := false

        loop 3 {
            attempt := A_Index
            LogMsg("  Launch attempt " attempt "/3...")
            try {
                prevFocus := 0
                try prevFocus := WinGetID("A")
                for managerHwnd in managerHwnds {
                    ManagerEl := UIA.ElementFromHandle(managerHwnd)
                    accountsTab := WaitForUIElement(ManagerEl, UIA_Sel["AccountsTab"], 3000)
                    accountsTab.Parent.Click()
                    Sleep(300)
                    startBtn := WaitForUIElement(ManagerEl, UIA_Sel["StartSelectedBtn"], 2000)
                    startBtn.Invoke()
                }
                if prevFocus
                    WinActivate("ahk_id " prevFocus)
            } catch Error as e {
                DllCall("LockWindowUpdate", "Ptr", 0)
                g_Restarting := false
                A_IconTip := "Skua - ERROR: Manager unavailable"
                LogMsg("ERROR: A Skua Manager was unavailable — " e.Message)
                return
            }

            seenClients := Map()
            timeout := A_TickCount + 60000
            while (A_TickCount < timeout) {
                if g_PopupDuringRestart {
                    popupRelaunch := true
                    break
                }
                for id in GetRealClients()
                    if !seenClients.Has(id)
                        seenClients[id] := true
                if (seenClients.Count >= g_ClientCount)
                    break
                Sleep(500)
            }

            if popupRelaunch
                break

            if (seenClients.Count < g_ClientCount) {
                LogMsg("  Only " seenClients.Count "/" g_ClientCount " clients appeared — retrying...")
                for id in WinGetList("ahk_exe skua.exe") {
                    if InStr(WinGetTitle(id), "Skua Manager")
                        continue
                    try {
                        pid := WinGetPID(id)
                        if pid > 0
                            ProcessClose(pid)
                    }
                }
                Sleep(2000)
                continue
            }

            launched := true
            LogMsg("  All " g_ClientCount " clients launched and Flash ready.")
            break
        }

        if popupRelaunch {
            LogMsg("  Popup during relaunch — waiting for all " g_ClientCount " clients before re-entering Step 3...")
            waitTimeout := A_TickCount + 60000
            while (A_TickCount < waitTimeout) {
                if (GetRealClients().Length >= g_ClientCount)
                    break
                Sleep(500)
            }
            LogMsg("  Clients accounted for. Re-entering from Step 3...")
            continue
        }

        if (!launched) {
            DllCall("LockWindowUpdate", "Ptr", 0)
            g_Restarting := false
            A_IconTip := "Skua - ERROR: failed to launch clients"
            LogMsg("ERROR: Failed to launch all " g_ClientCount " clients after 3 attempts.")
            return
        }

        break
    }

    LogMsg("Step 5/9 — Opening Load Script windows...")
    sortedClients := SortByCoords(GetRealClients())
    prevFocus := 0
    try prevFocus := WinGetID("A")
    for id in sortedClients {
        try {
            El := UIA.ElementFromHandle(id)
            scriptsTab := WaitForUIElement(El, UIA_Sel["ScriptsTab"], 2000)
            scriptsTab.Parent.Click()
            loadScriptHwnd := WaitForWindowByTitle("Load Script", 2000)
            if loadScriptHwnd {
                DllCall("SetWindowPos", "Ptr", loadScriptHwnd, "Ptr", 0,
                    "Int", -10000, "Int", -10000, "Int", 0, "Int", 0, "UInt", 0x0015)
            } else {
                LogMsg("  Load Script window did not appear for client " id)
            }
        } catch Error as e {
            LogMsg("  Error opening Load Script for client " id ": " e.Message)
        }
    }
    if prevFocus
        WinActivate("ahk_id " prevFocus)
    Sleep(500)
    DllCall("LockWindowUpdate", "Ptr", 0)
    LogMsg("  All " g_ClientCount " Load Script windows open.")

    LogMsg("Step 5b/9 — Opening Logs windows and switching to Flash tab...")
    logsHwnds := Map()

    prevFocus := 0
    try prevFocus := WinGetID("A")
    for clientID in sortedClients {
        try {
            El := UIA.ElementFromHandle(clientID)
            logsTab := WaitForUIElement(El, UIA_Sel["LogsTab"], 2000)
            logsTab.Parent.Click()
            logsHwnd := WaitForWindowByTitle("Logs", 2000)
            if logsHwnd {
                DllCall("SetWindowPos", "Ptr", logsHwnd, "Ptr", 0,
                    "Int", -2000, "Int", -2000, "Int", 0, "Int", 0, "UInt", 0x0015)
                logsHwnds[clientID] := logsHwnd
                LogMsg("  Logs banished for PID " WinGetPID(clientID))
            } else {
                LogMsg("  Logs window did not appear for PID " WinGetPID(clientID))
            }
        } catch Error as e {
            LogMsg("  ERROR clicking Logs for PID " WinGetPID(clientID) ": " e.Message)
        }
    }
    if prevFocus
        WinActivate("ahk_id " prevFocus)

    for clientID, logsHwnd in logsHwnds {
        clientPID := WinGetPID("ahk_id " clientID)
        try {
            LogsEl := UIA.ElementFromHandle(logsHwnd)
            flashTab := WaitForUIElement(LogsEl, UIA_Sel["FlashTab"], 2000)
            flashTab.Parent.Click()
            LogMsg("  Flash tab clicked for PID " clientPID)
        } catch Error as e {
            LogMsg("  ERROR clicking Flash tab for PID " clientPID ": " e.Message)
        }
        Sleep(100)
    }

    LogMsg("Step 6/9 — Waiting for all " g_ClientCount " scripts to start running (30s)...")
    runningCount := 0
    allRunning   := false
    scriptIds    := GetLoadScripts()
    runTimeout   := A_TickCount + 30000
    while (A_TickCount < runTimeout) {
        runningCount := 0
        for id in scriptIds {
            try {
                scriptEl := UIA.ElementFromHandle(id)
                WaitForUIElement(scriptEl, UIA_Sel["StopScriptBtn"], 1000)
                runningCount++
            } catch
                continue
        }
        if (runningCount >= g_ClientCount) {
            allRunning := true
            break
        }
        Sleep(1000)
    }

    if (!allRunning) {
        g_CycleAttempts++
        LogMsg("Step 6 failed — only " runningCount "/" g_ClientCount " scripts running. Attempt " g_CycleAttempts "/5.")
        if (g_CycleAttempts >= 5) {
            LogMsg("5 failed attempts — closing all Skua windows. Waiting 1 hour before retrying...")
            for id in WinGetList("ahk_exe skua.exe") {
                if InStr(WinGetTitle(id), "Skua Manager")
                    continue
                try PostMessage(0x0010, 0, 0,, "ahk_id " id)
            }
            Sleep(2000)
            for id in WinGetList("ahk_exe skua.exe") {
                if InStr(WinGetTitle(id), "Skua Manager")
                    continue
                try ProcessClose(WinGetPID(id))
            }
            g_CycleAttempts := 0
            g_Restarting    := false
            A_IconTip := "Skua - Cooldown (retry in 1 hour)"
            LogMsg("Cooldown started — DoRestart will fire again in 60 minutes.")
            SetTimer(() => DoRestart(), -60 * 60 * 1000)
            return
        }
        g_Restarting := false
        LogMsg("Retrying full restart...")
        DoRestart()
        return
    }
    g_CycleAttempts := 0
    LogMsg("  All " g_ClientCount " scripts confirmed running (Stop Script visible).")

    Sleep(15000)

    LogMsg("Step 7/9 — Repositioning windows from layout file...")
    scripts := GetLoadScripts()
    for index, clientID in sortedClients {
        clientPID := WinGetPID(clientID)
        DllCall("ShowWindow", "Ptr", clientID, "Int", 7)
        try {
            x := IniRead(LayoutFile, "Client" index, "x")
            y := IniRead(LayoutFile, "Client" index, "y")
            w := IniRead(LayoutFile, "Client" index, "w")
            h := IniRead(LayoutFile, "Client" index, "h")
            MinimizeToPos(clientID, x, y, w, h)
            LogMsg("  Client" index " repositioned to x=" x " y=" y)
        }
        for scriptID in scripts {
            if (WinGetPID(scriptID) = clientPID) {
                DllCall("ShowWindow", "Ptr", scriptID, "Int", 7)
                try {
                    x := IniRead(LayoutFile, "LoadScript" index, "x")
                    y := IniRead(LayoutFile, "LoadScript" index, "y")
                    w := IniRead(LayoutFile, "LoadScript" index, "w")
                    h := IniRead(LayoutFile, "LoadScript" index, "h")
                    MinimizeToPos(scriptID, x, y, w, h)
                    LogMsg("  LoadScript" index " repositioned to x=" x " y=" y)
                }
                break
            }
        }
    }

    LogMsg("Step 8/9 — Resetting 60-minute countdown.")
    cycleMs := 60 * 60 * 1000
    g_NextCycleAt := A_TickCount + cycleMs
    SetTimer(CycleTick, cycleMs)

    LogMsg("Step 9/9 — Restarting stuck monitor.")
    StuckStart(logsHwnds)

    g_Restarting := false
    A_IconTip := "Skua - Running"
    LogMsg("Restart complete. All systems go. Next cycle in 70 minutes.")
    ClearSkuaWindowCache()
}

; ─── Hotkeys ────────────────────────────────────────────────────────────────

F8:: {
    global g_LogsAllowed
    logsWindows := GetLogsWindows()

    if logsWindows.Length = 0 {
        LogMsg("F8 — no Logs windows found.")
        return
    }

    if !AreLogsVisible(logsWindows) {
        g_LogsAllowed := true
        screenW := SysGet(0)
        screenH := SysGet(1)
        winW    := 600
        winH    := 400
        baseX   := (screenW - winW) // 2
        baseY   := (screenH - winH) // 2
        for i, hwnd in logsWindows {
            x := baseX + (i - 1) * 30
            y := baseY + (i - 1) * 30
            DllCall("ShowWindow", "Ptr", hwnd, "Int", 9)
            DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0,
                "Int", x, "Int", y, "Int", winW, "Int", winH, "UInt", 0x0040)
        }
        LogMsg("F8 — Logs windows shown (" logsWindows.Length " windows).")
    } else {
        g_LogsAllowed := false
        for i, hwnd in logsWindows {
            DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0,
                "Int", -2000, "Int", -2000, "Int", 0, "Int", 0, "UInt", 0x0015)
        }
        LogMsg("F8 — Logs windows hidden.")
    }
}

F9:: {
    global g_NextCycleAt
    if g_NextCycleAt != 0
        return
    cycleMs := 60 * 60 * 1000      ; 60 minutes
    g_NextCycleAt := A_TickCount + cycleMs
    SetTimer(CycleTick, cycleMs)
    StuckStart()
    LogMsg("F9 pressed — countdown started (60 min cycle). Load and start your scripts manually.")
    MsgBox("F9 pressed, Countdown Running (60 min cycle)", "Skua Automate")
}

F10:: {
    global g_LogGui
    if (g_LogGui && WinExist("ahk_id " g_LogGui.Hwnd))
        CloseLogWindow()
    else
        OpenLogWindow()
}

F11:: {
    global g_NextCycleAt, g_Restarting
    if g_NextCycleAt = 0 {
        LogMsg("F11 pressed — nothing running.")
        return
    }
    SetTimer(CycleTick, 0)
    StuckStop()
    g_NextCycleAt := 0
    g_Restarting  := false
    A_IconTip := "Skua - Idle (press F9 to start)"
    LogMsg("F11 pressed — cycle stopped. Press F9 to start again.")
    MsgBox("F11 pressed, Terminating countdown", "Skua Automate")
}

F12:: {
    LogMsg("F12 pressed — triggering DoRestart manually.")
    MsgBox("F12 pressed, Doing a full reset", "Skua Automate")
    SetTimer(() => DoRestart(), -1)
}

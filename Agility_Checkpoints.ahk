#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn All, StdOut
; ROOFTOP ANCHOR & CHECKPOINT ENGINE -- observed teaching, no teaching controls.
;
; First launch: open ONE RuneLite Fixed Classic client, keep its cumulative
; Agility XP counter visible, and manually complete two consistent full laps.
; Start with the course's ground entrance. Hover briefly before clicking.
; Only pick up Marks during teaching; other orange items are not name-OCR'd.
;
; The engine NEVER clicks in Learn mode. Two matching confirmed lap graphs are
; saved; close/relaunch the script to Run. Launch with --learn to rebuild a new
; profile while preserving the existing ready profile until replacement validates.
; Physical left-clicks or loss of focus during Run pause input; restart to resume.
; Exit using AutoHotkey's ordinary tray menu. --selftest runs offline checks.

SendMode("Event")
SetMouseDelay(-1)
CoordMode("Mouse","Client")
SetTitleMatchMode(2)
CFG := {ox:4,oy:26,clientW:773,clientH:539,
    world:{x:4,y:4,w:512,h:334},mini:{x:641,y:85,r:68},hover:{x:6,y:7,w:358,h:16},
    xp:{x:384,y:9,w:129,h:18},profile:A_ScriptDir "\Agility_Checkpoints.ini",
    log:A_ScriptDir "\Agility_Checkpoints.log",minScene:0.88,anchorMargin:0.055,
    colorTolerance:32,centerTolerance:34,minSignature:0.90,
    roofBlack:0.45,groundBlack:0.15,blackLevel:24,
    tickMs:80,confirmMs:8000,watchdogMs:10000,stableMs:180,learnMs:25000}

; Checkpoint contract (all fields are learned from observed manual actions):
; {ID, AnchorSignature, NextObstacleBox, ExpectedXP, Proven}.
; AnchorSignature is a source-scene fingerprint with its calibrated plane.
; NextObstacleBox includes its bounds, inner click point, and uptext fingerprint.
; ExpectedXP holds visual counter thresholds and explicit arrival/plane evidence.
; It does NOT pretend that pixel differences measure a numerical XP amount.
Checkpoints := []
LootMarks := []
GroundReturns := []
E := {Hwnd:0,Running:true,Ready:false,Mode:"Learn",Busy:false,Token:0,
    Phase:"Identify",Target:0,Pending:0,ConfirmAt:0,NextInputAt:0,BlockedMarks:Map(),
    Cache:0,PreviousCache:0,CounterSince:0,Learning:0,LastProven:0,LapPath:[],LastGraph:"",ReturnTrail:[],
    LapValid:true,LapsMatched:0,LearningPlane:"ground",Module:0,GdipToken:0,
    LastStatus:"",LastLogAt:0,Completed:0,HasActed:false,Rebuild:false}
TickCallback := Tick
WatchdogCallback := Watchdog
OnExit(Shutdown)
try {
    E.Module:=DllCall("kernel32\LoadLibraryW","Str","gdiplus.dll","Ptr")
    if !E.Module
        throw Error("Cannot load GDI+.")
    E.GdipToken:=Gdip_Startup()
    if HasArgument("--selftest")
        ExitApp(RunSelfTests())
    E.Rebuild:=HasArgument("--learn")
    if !E.Rebuild
        LoadProfile()
    E.Mode:=E.Ready ? "Run" : "Learn"
    SetTimer(WatchdogCallback,500)
    SetTimer(TickCallback,-CFG.tickMs)
    TrayTip(E.Mode="Learn" ? "Observe two manual laps from the ground entrance. No engine clicks."
        : "Ready profile loaded. Focus the game to begin.","Anchor & Checkpoint engine")
} catch as startupError {
    if HasArgument("--selftest") {
        FileAppend("FAIL: " startupError.Message "`n" startupError.Stack "`n","*")
        ExitApp(1)
    }
    MsgBox(startupError.Message,"Checkpoint engine","Iconx")
    ExitApp(1)
}

; This hook observes physical game clicks; it is not a user control. Input level
; 1 ignores the engine's level-0 Click events, and ~ passes manual clicks through.
#InputLevel 1
~LButton::ObserveManualClick()
#InputLevel 0

HasArgument(value) {
    for arg in A_Args
        if arg=value
            return true
    return false
}

Tick() {
    global E,CFG,TickCallback
    if !E.Running || E.Busy
        return
    E.Busy:=true,token:=E.Token
    try {
        if !E.Hwnd
            E.Hwnd:=FindClient()
        if !E.Hwnd || !WinActive("ahk_id " E.Hwnd) {
            if E.Mode="Run" && E.HasActed
                Pause("Client lost focus")
            else
                Status("Waiting for one foreground RuneLite client")
            return
        }
        RequireClient()
        world:=Observe()
        if !IsObject(E.Cache) || E.Cache.Counter.Hash!=world.Counter.Hash
            E.CounterSince:=world.At
        E.PreviousCache:=E.Cache,E.Cache:=world
        if E.Mode="Learn" {
            ObserveLearning(world,Now())
            return
        }
        switch E.Phase {
            case "Identify":
                if Now()<E.NextInputAt
                    return
                E.BlockedMarks:=Map()
                E.Target:=ChooseTarget(world)
                if E.Target.Ready
                    E.Phase:="Act"
                else
                    Status(E.Target.Reason)
            case "Act": Act(E.Target,token)
            case "Confirm": Confirm(world,Now())
            default: Recover("Unknown phase")
        }
    } catch as err {
        if E.Token=token
            Pause(err.Message)
    } finally {
        E.Busy:=false
        if E.Running
            SetTimer(TickCallback,-CFG.tickMs)
    }
}

FindClient() {
    candidates:=[]
    for hwnd in WinGetList("RuneLite") {
        try {
            if !InStr(WinGetProcessName("ahk_id " hwnd),"AutoHotkey")
                candidates.Push(hwnd)
        }
    }
    return candidates.Length=1 ? candidates[1] : 0
}
Observe() {
    global E,CFG
    world:=WithClientFrame(E.Hwnd,Analyze)
    world.Counter.Stable:=IsObject(E.Cache) && E.Cache.Counter.Hash=world.Counter.Hash
        && world.Counter.Readable && world.At-E.CounterSince>=CFG.stableMs
    return world
}

; Every observation is copied scalar/array data from ONE scoped client capture.
Analyze(frame) {
    global E,Checkpoints,LootMarks,GroundReturns,CFG
    if frame.HasOwnProp("mx")
        mx:=frame.mx,my:=frame.my
    else
        MouseGetPos(&mx,&my)
    boxes:=FindHighlights(frame),sig:=SigFromFrame(frame),sources:=[],scores:=Map(),cp:=0
    cpBest:=0.0,cpSecond:=0.0,planeBest:=0.0,opposite:=0.0,plane:="unknown"
    ground:=0,groundBest:=0.0,groundSecond:=0.0,markMatches:=[]
    for checkpoint in Checkpoints {
        if !checkpoint.Proven
            continue
        score:=SceneFit(frame,{anchor:checkpoint.AnchorSignature}).score
        scores[checkpoint.ID]:=score
        sources.Push({Plane:checkpoint.AnchorSignature.Plane,Score:score})
        if score>cpBest
            cpSecond:=cpBest,cpBest:=score,cp:=checkpoint
        else
            cpSecond:=Max(cpSecond,score)
    }
    for mark in LootMarks {
        score:=SceneFit(frame,{anchor:mark.AnchorSignature}).score
        sources.Push({Plane:mark.AnchorSignature.Plane,Score:score})
        if score>=CFG.minScene
            markMatches.Push(mark)
    }
    for leg in GroundReturns {
        score:=SceneFit(frame,{anchor:leg.AnchorSignature}).score
        scores[leg.ID]:=score
        sources.Push({Plane:"ground",Score:score})
        if score>groundBest
            groundSecond:=groundBest,groundBest:=score,ground:=leg
        else
            groundSecond:=Max(groundSecond,score)
    }
    for source in sources
        if source.Score>planeBest
            planeBest:=source.Score,plane:=source.Plane
    for source in sources
        if source.Plane!=plane
            opposite:=Max(opposite,source.Score)
    reliable:=planeBest>=CFG.minScene && planeBest-opposite>=CFG.anchorMargin
    if !reliable
        plane:="unknown"
    if cpBest<CFG.minScene || cpBest-cpSecond<CFG.anchorMargin
        cp:=0
    if groundBest<CFG.minScene || groundBest-groundSecond<CFG.anchorMargin
        ground:=0
    black:=BlackRatio(frame)
    rawPlane:=black>=CFG.roofBlack ? "roof" : black<=CFG.groundBlack ? "ground" : "unknown"
    learning:=E.Learning,pending:=E.Pending
    needsInventory:=sig.kind="loot" || (IsObject(learning) && learning.Kind="mark" && !learning.Confirmed)
        || (IsObject(pending) && pending.Target.Kind="LootMark")
    return {At:frame.HasOwnProp("at") ? frame.at : Now(),Checkpoint:cp,Scores:scores,Plane:plane,PlaneReliable:reliable,
        RawPlane:rawPlane,Black:black,GroundReturn:ground,MarkMatches:markMatches,
        Boxes:boxes,Uptext:sig,Inventory:needsInventory ? InventorySample(frame) : {Colors:[],Numbers:Map()},
        Counter:ReadCounter(frame),Anchor:ReadSceneAnchor(frame),Mouse:{x:mx-CFG.ox,y:my-CFG.oy}}
}

; IDENTIFY scans all anchors. It does not trust an array cursor or prior action.
ChooseTarget(world,blockedMarks:=0) {
    for mark in world.MarkMatches {
        if IsObject(blockedMarks) && blockedMarks.Has(mark.ID)
            continue
        if mark.AnchorSignature.Plane!=world.Plane
            continue
        box:=FindTargetBox(world.Boxes,mark.Action.Box,true)
        if IsObject(box)
            return {Ready:true,Kind:"LootMark",ID:mark.ID,SourceID:mark.ID,
                Plane:world.Plane,Action:mark.Action,Box:box,Expected:0}
    }
    if IsObject(world.Checkpoint) {
        cp:=world.Checkpoint
        box:=FindTargetBox(world.Boxes,cp.NextObstacleBox.Box)
        if IsObject(box)
            return {Ready:true,Kind:"Obstacle",ID:cp.ID,SourceID:cp.ID,
                Plane:cp.AnchorSignature.Plane,Action:cp.NextObstacleBox,Box:box,Expected:cp.ExpectedXP}
    }
    if world.Plane="ground" && world.PlaneReliable && IsObject(world.GroundReturn) {
        leg:=world.GroundReturn
        return {Ready:true,Kind:"Navigate",ID:"Ground_Course_Start",SourceID:leg.ID,
            Plane:"ground",Point:leg.Point,Expected:NewExpected(leg.ArrivalID,"")}
    }
    return {Ready:false,Reason:"Ground_Course_Start: waiting for a verified ground recovery anchor"}
}

FindTargetBox(boxes,taught,redOnly:=false) {
    best:=0,score:=0.0,second:=0.0
    for box in boxes {
        if redOnly && box.color!="red"
            continue
        value:=GeometryScore(taught,box)
        if value>score
            second:=score,score:=value,best:=box
        else
            second:=Max(second,value)
    }
    return score>=0.55 && score-second>=0.04 ? best : 0
}

; ACT: eased pointer movement -> learned uptext check -> one left click.
Act(target,token) {
    global E,CFG
    if target.Kind="Navigate" {
        SmoothMove(target.Point,token)
        Sleep(100)
        fresh:=Observe(),again:=ChooseTarget(fresh)
        if !again.Ready || again.Kind!="Navigate" || again.SourceID!=target.SourceID {
            Recover("Ground anchor changed")
            return
        }
        CommitClick(target,fresh,token,target.Point)
        return
    }
    for uv in [[target.Action.U,target.Action.V],[0.35,0.4],[0.65,0.6]] {
        point:=SafePoint(target.Box,uv[1],uv[2])
        SmoothMove(point,token)
        Sleep(140)
        RequireInput(token)
        fresh:=Observe(),selection:=ChooseTarget(fresh,E.BlockedMarks)
        if !selection.Ready || selection.ID!=target.ID || selection.SourceID!=target.SourceID
            || fresh.Plane!=target.Plane {
            Recover("Source or priority target changed")
            return
        }
        liveBox:=FindTargetBox(fresh.Boxes,target.Box,target.Kind="LootMark")
        if !IsObject(liveBox) || !InsideSafe(point,liveBox)
            continue
        if SignatureScore(fresh.Uptext,target.Action.Uptext)<CFG.minSignature
            continue
        MouseGetPos(&mx,&my)
        if Abs(mx-CFG.ox-point.x)>1 || Abs(my-CFG.oy-point.y)>1
            throw Error("Pointer moved during verification")
        CommitClick(target,fresh,token,point)
        return
    }
    if target.Kind="LootMark" {
        ; A red obstacle that fails the Mark label must not starve valid actions.
        E.BlockedMarks[target.ID]:=true
        alternative:=ChooseTarget(fresh,E.BlockedMarks)
        if alternative.Ready {
            E.Target:=alternative
            return
        }
    }
    Recover("Uptext did not match; re-identifying")
}

CommitClick(target,before,token,point) {
    global E,CFG
    Critical("On")
    try {
        RequireInput(token)
        MouseGetPos(&mx,&my)
        if Abs(mx-CFG.ox-point.x)>1 || Abs(my-CFG.oy-point.y)>1 || GetKeyState("LButton","P")
            throw Error("Physical mouse input during final verification")
        Click()
        stamp:=Now(),E.HasActed:=true
        E.Pending:={Target:target,At:stamp,Deadline:stamp+CFG.confirmMs,
            BeforePlane:before.Plane,BeforeInventory:before.Inventory,
            BeforeScores:before.Scores,BeforeCounter:before.Counter.Stable ? before.Counter : EmptyCounter(),Evidence:"",EvidenceSince:0}
        E.ConfirmAt:=stamp,E.Phase:="Confirm"
        Status("Confirm: " target.ID)
    } finally {
        Critical("Off")
    }
}

; CONFIRM is observation-only. Timeout never advances a checkpoint.
Confirm(world,stamp) {
    global E,CFG
    p:=E.Pending
    if !IsObject(p) {
        Recover("Missing pending transaction")
        return
    }
    if stamp>=p.Deadline {
        Recover("8-second timeout: " p.Target.ID)
        return
    }
    evidence:=ConfirmationEvidence(p,world,stamp)
    if evidence="" {
        p.Evidence:="",p.EvidenceSince:=0
        return
    }
    if evidence!=p.Evidence {
        p.Evidence:=evidence,p.EvidenceSince:=stamp
        return
    }
    if stamp-p.EvidenceSince>=CFG.stableMs {
        if p.Target.Kind="Obstacle"
            E.Completed+=1
        Status("Confirmed " p.Target.ID " by " evidence)
        Recover("Identify after confirmed action",0)
    }
}
ConfirmationEvidence(p,world,stamp) {
    global CFG
    if stamp-p.At<400
        return ""
    target:=p.Target
    if target.Kind="LootMark"
        return InventoryChanged(p.BeforeInventory,world.Inventory)
            ? "inventory change:" InventoryFingerprint(world.Inventory) : ""
    expected:=target.Expected
    arrived:=IsObject(world.Checkpoint) && world.Checkpoint.ID=expected.ArrivalID
    if target.Kind="Navigate" && IsObject(world.GroundReturn) && world.GroundReturn.ID=expected.ArrivalID
        arrived:=true
    if expected.ArrivalID!="" && arrived
        && world.Scores.Has(expected.ArrivalID) && world.Scores[expected.ArrivalID]>=CFG.minScene
        && (!p.BeforeScores.Has(expected.ArrivalID) || p.BeforeScores[expected.ArrivalID]<CFG.minScene)
        return "arrival at " expected.ArrivalID
    if expected.PlaneAfter!="" && expected.PlaneAfter!=p.BeforePlane
        && world.PlaneReliable && world.Plane=expected.PlaneAfter
        return "expected plane transition"
    if stamp-p.At>=900 && CounterChanged(p.BeforeCounter,world.Counter,expected.MinAdded,expected.MinRemoved)
        return "XP counter changed:" world.Counter.Hash
    return ""
}
NewExpected(arrival,plane) => {ArrivalID:arrival,PlaneAfter:plane,MinAdded:5,MinRemoved:5}

; An independent timer can reset a stalled Confirm even when Tick is marked busy.
; AHK cannot interrupt an indefinitely blocked native API or critical section.
; The watchdog invalidates input only; the capture callback owns its own cleanup.
Watchdog() {
    global E,CFG
    if E.Running && E.Mode="Run" && E.Phase="Confirm" && Now()-E.ConfirmAt>CFG.watchdogMs
        Recover("10-second watchdog: return to Identify")
}
Recover(reason,cooldown:=1000) {
    global E
    E.Token+=1,E.Phase:="Identify",E.Target:=0,E.Pending:=0,E.ConfirmAt:=0,E.BlockedMarks:=Map()
    E.NextInputAt:=Now()+cooldown
    Status(reason)
}
Pause(reason) {
    global E,TickCallback
    E.Running:=false
    SetTimer(TickCallback,0)
    Recover(reason,0)
    TrayTip(reason "`nRestart the script to resume.","Checkpoint engine paused")
}

SmoothMove(point,token) {
    global CFG
    RequireInput(token)
    MouseGetPos(&sx,&sy)
    tx:=Round(CFG.ox+point.x),ty:=Round(CFG.oy+point.y),px:=sx,py:=sy
    Loop 12 {
        RequireInput(token)
        MouseGetPos(&mx,&my)
        if Abs(mx-px)>2 || Abs(my-py)>2
            throw Error("Manual mouse movement")
        t:=A_Index/12,ease:=t*t*(3-2*t)
        px:=Round(sx+(tx-sx)*ease),py:=Round(sy+(ty-sy)*ease)
        MouseMove(px,py,0),Sleep(12)
    }
}
SafePoint(box,u,v) {
    mx:=Max(3,Ceil((box.x2-box.x1)*0.1)),my:=Max(3,Ceil((box.y2-box.y1)*0.1))
    return {x:Round(Clamp(box.x1+u*(box.x2-box.x1),box.x1+mx,box.x2-mx)),
        y:Round(Clamp(box.y1+v*(box.y2-box.y1),box.y1+my,box.y2-my))}
}
InsideSafe(point,box) {
    mx:=Max(3,Ceil((box.x2-box.x1)*0.1)),my:=Max(3,Ceil((box.y2-box.y1)*0.1))
    return point.x>=box.x1+mx && point.x<=box.x2-mx && point.y>=box.y1+my && point.y<=box.y2-my
}
RequireInput(token) {
    global E
    if !E.Running || E.Token!=token || E.Mode!="Run"
        throw Error("Input cancelled")
    RequireClient()
}
RequireClient() {
    global E,CFG
    if !E.Hwnd || !WinActive("ahk_id " E.Hwnd) || WinGetMinMax("ahk_id " E.Hwnd)=-1
        throw Error("Bound client is not foreground")
    WinGetClientPos(&sx,&sy,&cw,&ch,"ahk_id " E.Hwnd)
    if cw!=CFG.clientW || ch!=CFG.clientH || CFG.ox<0 || CFG.oy<0 || CFG.ox+765>cw || CFG.oy+503>ch
        throw Error("Restore the calibrated Fixed Classic layout")
    if sx<SysGet(76) || sy<SysGet(77) || sx+cw>SysGet(76)+SysGet(78) || sy+ch>SysGet(77)+SysGet(79)
        throw Error("Keep the complete client on screen")
    for point in [[10,10],[510,330],[641,85],[6,7]] {
        packed:=((sy+CFG.oy+point[2])<<32)|((sx+CFG.ox+point[1])&0xFFFFFFFF)
        under:=DllCall("user32\WindowFromPoint","Int64",packed,"Ptr")
        if DllCall("user32\GetAncestor","Ptr",under,"UInt",2,"Ptr")!=E.Hwnd
            throw Error("A window/menu covers a sensor region")
    }
}

; ---------- LEARN: physical clicks + completion evidence, never engine clicks.
ObserveManualClick() {
    global E,CFG
    if !E.Running || !E.Hwnd || !WinActive("ahk_id " E.Hwnd)
        return
    if E.Mode="Run" {
        Pause("Physical click interrupted automation")
        return
    }
    try {
        RequireClient()
        w:=E.Cache,stamp:=Now()
        MouseGetPos(&mx,&my)
        point:={x:mx-CFG.ox,y:my-CFG.oy}
        if !IsObject(w) || stamp-w.At>180 || Abs(point.x-w.Mouse.x)>3 || Abs(point.y-w.Mouse.y)>3 {
            if IsObject(w) && w.Uptext.kind="obstacle" && point.x>=4 && point.x<=515 && point.y>=4 && point.y<=337
                E.LapValid:=false
            Status("Teaching click missed: hover briefly before clicking")
            return
        }
        BeginObservedLearning(w,point,stamp)
    } catch as err {
        Status("Teaching click ignored: " err.Message)
    }
}

; Separated from the physical hook so retry admission can be tested without input.
BeginObservedLearning(w,point,stamp) {
    global E,CFG
    MaybeCloseLapOnArrival(w)
    if !E.Running || E.Mode!="Learn"
        return
    if IsObject(E.Learning) && !E.Learning.Confirmed {
        ObserveLearning(w,w.At)
        if !E.Running || E.Mode!="Learn"
            return
        if IsObject(E.Learning) && !E.Learning.Confirmed {
            bi:=HoveredBox(w.Boxes,point.x,point.y)
            pending:=E.Learning
            same:=pending.HasOwnProp("Action") && bi
                && SignatureScore(pending.Action.Uptext,w.Uptext)>=CFG.minSignature
                && GeometryScore(pending.Action.Box,w.Boxes[bi])>=0.5
                && AnchorSimilarity(pending.Source.Anchor,w.Anchor)>=0.78
            if w.Uptext.kind="obstacle" && !same
                E.LapValid:=false
            Status(same ? "Teaching retry: retain original completion baseline" : "Unconfirmed distinct click: this lap cannot validate")
            return
        }
    }
    if w.Uptext.kind="none" {
        ObserveGroundClick(w,point,stamp)
        return
    }
    bi:=HoveredBox(w.Boxes,point.x,point.y)
    if !bi {
        if w.Uptext.kind="obstacle"
            E.LapValid:=false
        Status("Unbound teaching click: no recognized clickbox")
        return
    }
    if w.Anchor.mini.Length<8 || w.Anchor.world.Length<30 {
        E.LapValid:=false
        Status("Teaching source has insufficient landmarks")
        return
    }
    kind:=w.Uptext.kind="loot" ? "mark" : "checkpoint"
    if kind="mark" && (w.Boxes[bi].color!="red" || (w.PlaneReliable && w.Plane="ground"))
        return
    box:=w.Boxes[bi]
    action:={Box:box,Uptext:w.Uptext,U:Clamp((point.x-box.x1)/(box.x2-box.x1),0.12,0.88),V:Clamp((point.y-box.y1)/(box.y2-box.y1),0.12,0.88)}
    E.Learning:={Kind:kind,Source:w,Action:action,At:stamp,Deadline:stamp+CFG.learnMs,
        Baseline:w.Counter.Stable ? w.Counter : EmptyCounter(),Evidence:"",EvidenceSince:0,Confirmed:false}
}

ObserveLearning(world,stamp) {
    global E,CFG
    if MaybeCloseLapOnArrival(world)
        return
    p:=E.Learning
    if !IsObject(p) || p.Confirmed
        return
    if stamp>=p.Deadline {
        E.Learning:=0,E.LapValid:=false
        Status("Teaching action timed out; continue a clean manual lap")
        return
    }
    evidence:=""
    if p.Kind="mark" {
        if InventoryChanged(p.Source.Inventory,world.Inventory)
            evidence:="inventory:" InventoryFingerprint(world.Inventory)
    } else if p.Kind="return" {
        if AnchorSimilarity(p.Source.Anchor,world.Anchor)<0.65
            evidence:="walked"
    } else if stamp-p.At>=900 {
        if CounterChanged(p.Baseline,world.Counter)
            evidence:="xp:" world.Counter.Hash
        else if p.Source.RawPlane="ground" && world.RawPlane="roof"
            evidence:="climbed"
    }
    if evidence="" {
        p.Evidence:="",p.EvidenceSince:=0
        return
    }
    if evidence!=p.Evidence {
        p.Evidence:=evidence,p.EvidenceSince:=stamp
        return
    }
    if stamp-p.EvidenceSince<CFG.stableMs
        return
    p.Confirmed:=true
    LearnConfirmed(p,world)
}

; Returning to the proven entrance anchor closes the observed circuit without
; requiring another entrance climb. Completion still requires two matching
; confirmed checkpoint graphs; an unconfirmed obstacle cannot be skipped.
MaybeCloseLapOnArrival(world) {
    global E,CFG,Checkpoints
    rootID:="Ground_Course_Start"
    if E.Mode!="Learn" || !E.Running || world.Plane!="ground" || !world.PlaneReliable
        return false
    root:=world.Checkpoint
    if !IsObject(root) || root.ID!=rootID || !root.Proven || root.AnchorSignature.Plane!="ground"
        || !world.Scores.Has(rootID) || world.Scores[rootID]<CFG.minScene
        return false
    for checkpoint in Checkpoints
        if checkpoint.Proven && checkpoint.ID!=rootID && world.Scores.Has(checkpoint.ID)
            && world.Scores[rootID]-world.Scores[checkpoint.ID]<CFG.anchorMargin
            return false
    last:=E.LastProven,learning:=E.Learning
    if !IsObject(last) || last.ID=rootID || E.LapPath.Length<3
        return false
    if IsObject(learning) && !learning.Confirmed && learning.Kind="checkpoint"
        return false
    if IsObject(learning) && !learning.Confirmed && learning.Kind="return" {
        learning.Confirmed:=true
        LearnConfirmed(learning,world)
    }
    if last.ExpectedXP.ArrivalID!="" && last.ExpectedXP.ArrivalID!=rootID
        E.LapValid:=false
    last.ExpectedXP.ArrivalID:=rootID,last.ExpectedXP.PlaneAfter:="ground"
    PromoteGroundReturns()
    CloseTeachingLap()
    E.LapPath:=[],E.LastProven:=0,E.Learning:=0,E.LearningPlane:="ground"
    return true
}

LearnConfirmed(p,after) {
    global E,Checkpoints,LootMarks,GroundReturns
    if p.Kind="return" {
        if GroundReturns.Length+E.ReturnTrail.Length>=128
            return
        id:="Return_" Format("{:02}",GroundReturns.Length+E.ReturnTrail.Length+1)
        anchor:=p.Source.Anchor,anchor.Plane:="ground"
        ; Provisional until this same manual ground walk reaches the entrance.
        E.ReturnTrail.Push({ID:id,AnchorSignature:anchor,Point:p.Point,ArrivalID:""})
        return
    }
    if p.Kind="mark" {
        anchor:=p.Source.Anchor,anchor.Plane:=E.LearningPlane
        id:="Grace_" Format("{:02}",LootMarks.Length+1)
        if LootMarks.Length<128 && !FindLearned(LootMarks,anchor,p.Action)
            LootMarks.Push({ID:id,AnchorSignature:anchor,Action:p.Action})
        Status("Learned confirmed Mark pickup")
        return
    }
    cp:=FindLearned(Checkpoints,p.Source.Anchor,p.Action)
    if !IsObject(cp) {
        if Checkpoints.Length>=128
            throw Error("Too many distinct teaching anchors. Restart with --learn for a clean run.")
        if !Checkpoints.Length && p.Source.RawPlane!="ground" {
            E.LapValid:=false
            Status("Start teaching at the ground course entrance")
            return
        }
        id:=!Checkpoints.Length ? "Ground_Course_Start" : "Roof_" Format("{:02}",Checkpoints.Length)
        anchor:=p.Source.Anchor
        anchor.Plane:=id="Ground_Course_Start" ? "ground" : "roof"
        cp:={ID:id,AnchorSignature:anchor,NextObstacleBox:p.Action,ExpectedXP:NewExpected("",""),Proven:true}
        Checkpoints.Push(cp)
    }
    if IsObject(E.LastProven) && E.LastProven.ID!=cp.ID {
        old:=E.LastProven
        if old.ExpectedXP.ArrivalID!="" && old.ExpectedXP.ArrivalID!=cp.ID
            E.LapValid:=false
        old.ExpectedXP.ArrivalID:=cp.ID
        old.ExpectedXP.PlaneAfter:=old.AnchorSignature.Plane!=cp.AnchorSignature.Plane ? cp.AnchorSignature.Plane : ""
    }
    if cp.ID="Ground_Course_Start" && E.LapPath.Length>=3 {
        PromoteGroundReturns()
        CloseTeachingLap()
        E.LapPath:=[]
    } else if cp.ID!="Ground_Course_Start" {
        E.ReturnTrail:=[]
    }
    if !E.LapPath.Length || E.LapPath[E.LapPath.Length]!=cp.ID {
        if E.LapPath.Length>=128 {
            E.LapValid:=false
            Status("Teaching lap observation limit reached; return to the entrance")
        } else
            E.LapPath.Push(cp.ID)
    }
    E.LastProven:=cp,E.LearningPlane:="roof"
    Status("Learned confirmed checkpoint " cp.ID)
}

FindLearned(list,anchor,action) {
    best:=0,score:=0.0,second:=0.0
    for item in list {
        saved:=item.HasOwnProp("NextObstacleBox") ? item.NextObstacleBox : item.Action
        if SignatureScore(saved.Uptext,action.Uptext)<0.9
            continue
        if GeometryScore(saved.Box,action.Box)<0.5
            continue
        value:=AnchorSimilarity(anchor,item.AnchorSignature)
        if value>score
            second:=score,score:=value,best:=item
        else
            second:=Max(second,value)
    }
    return score>=0.84 && score-second>=0.04 ? best : 0
}

CloseTeachingLap() {
    global E,Checkpoints
    graph:="",seen:=Map()
    for id in E.LapPath {
        if seen.Has(id)
            E.LapValid:=false
        seen[id]:=true
        cp:=FindCheckpoint(id)
        if !IsObject(cp) || cp.ExpectedXP.ArrivalID=""
            E.LapValid:=false
        graph.=id ">" (IsObject(cp) ? cp.ExpectedXP.ArrivalID : "?") ";"
    }
    if seen.Count!=Checkpoints.Length
        E.LapValid:=false
    if E.LapValid && graph=E.LastGraph
        E.LapsMatched+=1
    else
        E.LapsMatched:=E.LapValid ? 1 : 0
    E.LastGraph:=E.LapValid ? graph : "",E.LapValid:=true
    if E.LapsMatched>=2 {
        E.Ready:=true
        SaveProfile()
        E.Running:=false,E.Mode:="Review"
        TrayTip("Two consistent teaching laps saved. Close and relaunch to run.","Learning complete")
    } else {
        SaveLearningDraft()
        Status("Teaching lap observed; matching clean laps: " E.LapsMatched "/2")
    }
}

ObserveGroundClick(world,point,stamp) {
    global E,CFG
    ; Only a calibrated ground source may teach a recovery waypoint.
    distance:=(point.x-CFG.mini.x)**2+(point.y-CFG.mini.y)**2
    grounded:=world.Plane="ground" && world.PlaneReliable
    if world.RawPlane="ground" && (E.ReturnTrail.Length || (IsObject(E.LastProven) && E.LastProven.ExpectedXP.PlaneAfter="ground"))
        grounded:=true
    if !grounded || distance<64 || distance>(CFG.mini.r*0.80)**2
        return
    if world.Anchor.mini.Length<8 || world.Anchor.world.Length<30
        return
    E.Learning:={Kind:"return",Source:world,Point:point,At:stamp,Deadline:stamp+CFG.learnMs,
        Evidence:"",EvidenceSince:0,Confirmed:false}
}

PromoteGroundReturns() {
    global E,GroundReturns
    chain:=[]
    for leg in E.ReturnTrail {
        canonical:=0
        for existing in GroundReturns
            if AnchorSimilarity(leg.AnchorSignature,existing.AnchorSignature)>=0.88
                && Sqrt((leg.Point.x-existing.Point.x)**2+(leg.Point.y-existing.Point.y)**2)<=6
                canonical:=existing
        if !IsObject(canonical) {
            canonical:=leg
            canonical.ID:="Return_" Format("{:02}",GroundReturns.Length+1)
            GroundReturns.Push(canonical)
        }
        if !chain.Length || chain[chain.Length].ID!=canonical.ID
            chain.Push(canonical)
    }
    for i,leg in chain
        leg.ArrivalID:=i<chain.Length ? chain[i+1].ID : "Ground_Course_Start"
    E.ReturnTrail:=[]
}

; Compare copied landmark sets, never cached native pixels. Exact-grid samples
; intentionally require consistent source poses across the two teaching laps.
AnchorSimilarity(a,b) {
    mini:=SampleSimilarity(a.mini,b.mini),world:=SampleSimilarity(a.world,b.world)
    return Min(mini,world)
}
SampleSimilarity(a,b) {
    global CFG
    lookup:=Map(),hits:=0,total:=0
    for p in b
        lookup[p[1] "," p[2]]:=p[3]
    for p in a {
        key:=p[1] "," p[2]
        if lookup.Has(key) {
            total+=1
            if ColorNear(p[3],lookup[key],CFG.colorTolerance)
                hits+=1
        }
    }
    return total>=Min(a.Length,b.Length)*0.65 ? hits/Max(1,total) : 0.0
}

; The counter ROI must be the stable cumulative XP display, not flying text.
; A fade removes pixels but adds none, so it cannot by itself prove completion.
ReadCounter(frame) {
    global CFG
    pixels:=Map(),hash:=2166136261,roi:=CFG.xp,shadowed:=0
    Loop roi.h-1 {
        y:=A_Index-1
        Loop roi.w-1 {
            x:=A_Index-1,p:=CanvasPixel(frame,roi.x+x,roi.y+y)
            ; Brightness alone defines membership. Shadow changes during fading
            ; therefore cannot manufacture new foreground pixels.
            if Min((p>>16)&255,(p>>8)&255,p&255)>=180 {
                key:=y*roi.w+x,pixels[key]:=true
                hash:=((hash^key)*16777619)&0xFFFFFFFF
                if Dark(CanvasPixel(frame,roi.x+x+1,roi.y+y+1),80)
                    shadowed+=1
            }
        }
    }
    return {Pixels:pixels,Count:pixels.Count,Hash:hash,Readable:pixels.Count>=8 && shadowed>=4,Stable:false}
}
EmptyCounter() => {Pixels:Map(),Count:0,Hash:0,Readable:false,Stable:false}
CounterChanged(before,after,minAdded:=5,minRemoved:=5) {
    if before.Count<8 || after.Count<8 || after.Count<before.Count*0.6
        return false
    if (before.HasOwnProp("Readable") && !before.Readable) || (after.HasOwnProp("Readable") && !after.Readable)
        return false
    added:=0,removed:=0
    for key,value in after.Pixels
        if !before.Pixels.Has(key)
            added+=1
    for key,value in before.Pixels
        if !after.Pixels.Has(key)
            removed+=1
    return added>=minAdded && removed>=minRemoved
}
InventorySample(frame) {
    samples:=[],numbers:=Map()
    Loop 64 {
        y:=208+(A_Index-1)*4
        Loop 44
            samples.Push(CanvasPixel(frame,560+(A_Index-1)*4,y))
    }
    ; Full-resolution yellow/white quantity glyphs detect a one-digit change
    ; even when the Mark stack's icon itself stays exactly the same.
    Loop 256 {
        y:=208+A_Index-1
        Loop 176 {
            x:=560+A_Index-1,p:=CanvasPixel(frame,x,y)
            r:=(p>>16)&255,g:=(p>>8)&255,b:=p&255
            if (Min(r,g,b)>=180) || (r>=180 && g>=140 && b<=140)
                numbers[(y-208)*176+x-560]:=true
        }
    }
    return {Colors:samples,Numbers:numbers}
}
InventoryChanged(before,after) {
    if before.Colors.Length!=after.Colors.Length
        return false
    changed:=0
    for i,color in before.Colors
        if !ColorNear(color,after.Colors[i],35)
            changed+=1
    if changed>=12
        return true
    added:=0,removed:=0
    for key,value in after.Numbers
        if !before.Numbers.Has(key)
            added+=1
    for key,value in before.Numbers
        if !after.Numbers.Has(key)
            removed+=1
    return added+removed>=2
}

; An unchanged fingerprint must persist through the confirmation stability
; interval. Changing animation frames cannot accumulate one generic delta proof.
; Number-mask checksums are independent of Map insertion order.
InventoryFingerprint(inventory) {
    colors:=2166136261,numberSum:=0,numberXor:=0
    for color in inventory.Colors
        colors:=((colors^(color&0xFFFFFF))*16777619)&0xFFFFFFFF
    for key,value in inventory.Numbers {
        mixed:=((key^(key>>16))*0x45D9F3B)&0xFFFFFFFF
        mixed:=((mixed^(mixed>>16))*0x45D9F3B)&0xFFFFFFFF
        mixed:=(mixed^(mixed>>16))&0xFFFFFFFF
        numberSum:=(numberSum+mixed)&0xFFFFFFFF,numberXor:=numberXor^mixed
    }
    return colors ":" inventory.Colors.Length ":" numberSum ":" numberXor ":" inventory.Numbers.Count
}

Status(message) {
    global E,CFG
    A_IconTip:=SubStr("Checkpoint engine: " message,1,127)
    if message=E.LastStatus && Now()-E.LastLogAt<5000
        return
    E.LastStatus:=message,E.LastLogAt:=Now()
    try {
        if FileExist(CFG.log) && FileGetSize(CFG.log)>1000000
            FileMove(CFG.log,CFG.log ".1",1)
        FileAppend(FormatTime(,"yyyy-MM-dd HH:mm:ss") " " message "`n",CFG.log,"UTF-8")
    } catch {
        OutputDebug(message)
    }
}
Shutdown(*) {
    global E,TickCallback,WatchdogCallback
    E.Running:=false,E.Token+=1
    SetTimer(TickCallback,0),SetTimer(WatchdogCallback,0)
    if E.GdipToken
        DllCall("gdiplus\GdiplusShutdown","UPtr",E.GdipToken)
    if E.Module
        DllCall("kernel32\FreeLibrary","Ptr",E.Module)
}
Now() => DllCall("kernel32\GetTickCount64","UInt64")
Clamp(value,lo,hi) => Max(lo,Min(hi,value))


IsGreen(p) => ((p>>8)&255) >= 160 && ((p>>16)&255) <= 100 && (p&255) <= 100
    && ((p>>8)&255)-Max((p>>16)&255,p&255) >= 90
IsRed(p) => ((p>>16)&255) >= 110 && ((p>>8)&255) <= 80 && (p&255) <= 80
    && ((p>>16)&255)-Max((p>>8)&255,p&255) >= 70
Dark(p, level:=24) => Max((p>>16)&255,(p>>8)&255,p&255) <= level
ColorNear(a,b,tolerance) => Max(Abs(((a>>16)&255)-((b>>16)&255)),
    Abs(((a>>8)&255)-((b>>8)&255)),Abs((a&255)-(b&255))) <= tolerance

FindHighlights(frame) {
    global CFG
    green := Map(), red := Map(), cell := 4, cols := 128
    ; Full-resolution scan preserves one-pixel Mark tile outlines.
    Loop CFG.world.h {
        y := CFG.world.y+A_Index-1
        Loop 512 {
            x := A_Index+3
            if x >= 364 && y <= 46
                continue
            p := CanvasPixel(frame,x,y)
            if IsGreen(p)
                AddCell(green,(y//cell)*cols+((x-4)//cell),x,y)
            else if IsRed(p)
                AddCell(red,(y//cell)*cols+((x-4)//cell),x,y)
        }
    }
    boxes := ConnectedBoxes(green,cols,"green")
    for box in ConnectedBoxes(red,cols,"red")
        boxes.Push(box)
    return boxes
}

AddCell(cells,key,x,y) {
    if cells.Has(key) {
        c := cells[key], c.n += 1
        c.x1 := Min(c.x1,x), c.y1 := Min(c.y1,y)
        c.x2 := Max(c.x2,x), c.y2 := Max(c.y2,y)
    } else
        cells[key] := {n:1,x1:x,y1:y,x2:x,y2:y}
}

ConnectedBoxes(cells,cols,color) {
    boxes := [], seen := Map()
    for key, start in cells {
        if seen.Has(key)
            continue
        seen[key] := true, queue := [key], qi := 1, box := start.Clone()
        box.n := 0, box.color := color
        while qi <= queue.Length {
            current := queue[qi], qi += 1, c := cells[current]
            box.n += c.n, box.x1 := Min(box.x1,c.x1), box.x2 := Max(box.x2,c.x2)
            box.y1 := Min(box.y1,c.y1), box.y2 := Max(box.y2,c.y2)
            rr := current//cols, cc := Mod(current,cols)
            for dy in [-1,0,1] {
                for dx in [-1,0,1] {
                    if cc+dx < 0 || cc+dx >= cols || rr+dy < 0
                        continue
                    neighbor := (rr+dy)*cols+cc+dx
                    if cells.Has(neighbor) && !seen.Has(neighbor)
                        seen[neighbor] := true, queue.Push(neighbor)
                }
            }
        }
        if box.n >= 8 && box.x2-box.x1 >= 8 && box.y2-box.y1 >= 8
            boxes.Push(box)
    }
    return boxes
}

HoveredBox(boxes,x,y) {
    best := 0, area := 1.0e20
    for i, box in boxes {
        if x >= box.x1 && x <= box.x2 && y >= box.y1 && y <= box.y2 {
            size := (box.x2-box.x1+1)*(box.y2-box.y1+1)
            if size < area
                best := i, area := size
        }
    }
    return best
}

BoxPoint(box,u,v) {
    mx := Min(3, (box.x2-box.x1)/4), my := Min(3,(box.y2-box.y1)/4)
    return {x:Round(Clamp(box.x1+u*(box.x2-box.x1),box.x1+mx,box.x2-mx)),
        y:Round(Clamp(box.y1+v*(box.y2-box.y1),box.y1+my,box.y2-my))}
}

GeometryScore(taught,live) {
    global CFG
    distance := Sqrt(((taught.x1+taught.x2-live.x1-live.x2)/2)**2
        + ((taught.y1+taught.y2-live.y1-live.y2)/2)**2)
    if distance > CFG.centerTolerance
        return 0.0
    wr := Min(taught.x2-taught.x1+1,live.x2-live.x1+1)/Max(taught.x2-taught.x1+1,live.x2-live.x1+1)
    hr := Min(taught.y2-taught.y1+1,live.y2-live.y1+1)/Max(taught.y2-taught.y1+1,live.y2-live.y1+1)
    return (1-distance/(CFG.centerTolerance*2))*Sqrt(wr*hr)
}

SameBox(a,b) => a.color = b.color && Max(Abs(a.x1-b.x1),Abs(a.y1-b.y1),Abs(a.x2-b.x2),Abs(a.y2-b.y2)) <= 3
SameBoxes(a,b) {
    if a.Length != b.Length
        return false
    for aa in a {
        found := false
        for bb in b
            if SameBox(aa,bb)
                found := true
        if !found
            return false
    }
    return true
}

SameCandidateSet(a,b) {
    if a.Length != b.Length
        return false
    for aa in a {
        found := false
        for bb in b
            if aa.id = bb.id && SameBox(aa.box,bb.box)
                found := true
        if !found
            return false
    }
    return true
}

EmptySignature() => {kind:"none", name:Map(), white:Map(), nameX:-1,nameW:0,nameN:0}

SigFromFrame(frame) {
    global CFG
    cyan := Map(), orange := Map(), white := Map()
    cn := 0, on := 0, cx1 := 999, cx2 := -1, ox1 := 999, ox2 := -1
    Loop CFG.hover.h-2 {
        y := A_Index-1
        Loop CFG.hover.w-3 {
            x := A_Index
            p := CanvasPixel(frame,CFG.hover.x+x,CFG.hover.y+y)
            r := (p>>16)&255, g := (p>>8)&255, b := p&255
            shadow := CanvasPixel(frame,CFG.hover.x+x+1,CFG.hover.y+y+1)
            if !Dark(shadow,70)
                continue
            if r <= 120 && g >= 150 && b >= 150 && Abs(g-b) <= 60 {
                AddProfile(cyan,x), cn += 1, cx1 := Min(cx1,x), cx2 := Max(cx2,x)
            } else if r >= 220 && g >= 100 && g <= 180 && b <= 100 && r-g >= 60 {
                AddProfile(orange,x), on += 1, ox1 := Min(ox1,x), ox2 := Max(ox2,x)
            } else if Min(r,g,b) >= 150 && Max(r,g,b)-Min(r,g,b) <= 40
                AddProfile(white,x)
        }
    }
    if cn >= 6
        return {kind:"obstacle",name:cyan,white:white,nameX:cx1,nameW:cx2-cx1+1,nameN:cn}
    if on >= 6 && cn < 4
        return {kind:"loot",name:orange,white:white,nameX:ox1,nameW:ox2-ox1+1,nameN:on}
    return EmptySignature()
}

AddProfile(profile,x) {
    for offset, weight in Map(-1,1,0,2,1,1) {
        k := x+offset
        profile[k] := (profile.Has(k) ? profile[k] : 0)+weight
    }
}

ProfileNorm(profile) {
    sum := 0.0
    for key, value in profile
        sum += value*value
    return Sqrt(sum)
}

ProfileCos(a,b,shift) {
    norm := ProfileNorm(a)*ProfileNorm(b)
    if !norm
        return 0.0
    sum := 0.0
    for key, value in a
        if b.Has(key+shift)
            sum += value*b[key+shift]
    return sum/norm
}

SignatureScore(a,b) {
    if a.kind != b.kind || a.kind = "none" || Abs(a.nameW-b.nameW) > 4 || Abs(a.nameX-b.nameX) > 4
        return 0.0
    best := 0.0
    Loop 9 {
        shift := A_Index-5
        score := 0.80*ProfileCos(a.name,b.name,shift)+0.20*ProfileCos(a.white,b.white,shift)
        best := Max(best,score)
    }
    return best
}

BlackRatio(frame) {
    global CFG
    count := 0, black := 0
    Loop 35 {
        dy := (A_Index-18)*3
        Loop 35 {
            dx := (A_Index-18)*3
            if dx*dx+dy*dy > (CFG.mini.r*0.82)**2 || dx*dx+dy*dy < 100
                continue
            count += 1
            if Dark(CanvasPixel(frame,CFG.mini.x+dx,CFG.mini.y+dy),CFG.blackLevel)
                black += 1
        }
    }
    return count ? black/count : 0.0
}

ReadSceneAnchor(frame) {
    global CFG
    mini := [], world := []
    Loop 15 {
        dy := (A_Index-8)*7
        Loop 15 {
            dx := (A_Index-8)*7
            if dx*dx+dy*dy > 2500 || dx*dx+dy*dy < 225
                continue
            p := CanvasPixel(frame,CFG.mini.x+dx,CFG.mini.y+dy)
            ; Black void, item dots, highlights, and player dots are poor landmarks.
            if !Dark(p,32) && !IsRed(p) && !IsGreen(p) && !BrightDot(p)
                mini.Push([dx,dy,p])
        }
    }
    Loop 8 {
        y := 62+(A_Index-1)*34
        Loop 13 {
            x := 28+(A_Index-1)*37
            if Abs(x-260) < 48 && Abs(y-170) < 65
                continue
            p := CanvasPixel(frame,x,y)
            if !IsGreen(p) && !IsRed(p) && !Dark(p,20)
                world.Push([x,y,p])
        }
    }
    return {mini:mini,world:world}
}

BrightDot(p) => Min((p>>16)&255,(p>>8)&255,p&255) >= 190

SceneFit(frame,row) {
    global CFG
    hits := 0
    for point in row.anchor.world
        if ColorNear(CanvasPixel(frame,point[1],point[2]),point[3],CFG.colorTolerance)
            hits += 1
    worldScore := hits/Max(1,row.anchor.world.Length)
    if worldScore < CFG.minScene
        return {score:0.0, mini:0.0, world:worldScore}
    bestMini := 0.0
    for dy in [-6,-3,0,3,6] {
        for dx in [-6,-3,0,3,6] {
            hits := 0
            for point in row.anchor.mini
                if ColorNear(CanvasPixel(frame,CFG.mini.x+point[1]+dx,CFG.mini.y+point[2]+dy),point[3],CFG.colorTolerance)
                    hits += 1
            bestMini := Max(bestMini,hits/Max(1,row.anchor.mini.Length))
        }
    }
    ; Both map and world must agree. A featureless roof/minimap alone cannot
    ; authorize a repeated-name obstacle on a different source roof.
    score := Min(bestMini,worldScore)
    return {score:score, mini:bestMini, world:worldScore}
}

; ============================================================================
; Strict native-resource scope. No external GDI+ library is required.
; A locked frame is a borrowed view valid ONLY during callback(frame).
; All native resources and the AHK-owned BitmapData buffer are released in finally.
; ============================================================================

Gdip_Startup() {
    input := Buffer(A_PtrSize = 8 ? 24 : 16,0), token := 0
    NumPut("UInt",1,input)
    CheckGdip(DllCall("gdiplus\GdiplusStartup","UPtr*",&token,"Ptr",input.Ptr,"Ptr",0),"GdiplusStartup")
    return token
}

Gdip_DisposeImage(image) {
    return DllCall("gdiplus\GdipDisposeImage","Ptr",image,"UInt")
}

CheckGdip(status,operation) {
    if status
        throw Error(operation " failed (GDI+ status " status ").")
}

WithClientFrame(hwnd,callback) {
    screenDC := 0, memoryDC := 0, bitmap := 0, previous := 0, image := 0
    locked := false, bitmapData := 0, frame := 0
    try {
        WinGetClientPos(&sx,&sy,&width,&height,"ahk_id " hwnd)
        if width < 1 || height < 1 || width*height > 16000000
            throw Error("Invalid capture dimensions.")
        screenDC := DllCall("user32\GetDC","Ptr",0,"Ptr")
        if !screenDC
            throw Error("GetDC failed.")
        memoryDC := DllCall("gdi32\CreateCompatibleDC","Ptr",screenDC,"Ptr")
        if !memoryDC
            throw Error("CreateCompatibleDC failed.")
        bitmap := DllCall("gdi32\CreateCompatibleBitmap","Ptr",screenDC,"Int",width,"Int",height,"Ptr")
        if !bitmap
            throw Error("CreateCompatibleBitmap failed.")
        previous := DllCall("gdi32\SelectObject","Ptr",memoryDC,"Ptr",bitmap,"Ptr")
        if !previous || previous = -1
            throw Error("SelectObject failed.")
        stamp := Now()
        MouseGetPos(&captureMX,&captureMY)
        if !DllCall("gdi32\BitBlt","Ptr",memoryDC,"Int",0,"Int",0,"Int",width,"Int",height,
            "Ptr",screenDC,"Int",sx,"Int",sy,"UInt",0x40CC0020)
            throw Error("BitBlt failed.")
        DllCall("gdi32\SelectObject","Ptr",memoryDC,"Ptr",previous,"Ptr")
        previous := 0
        CheckGdip(DllCall("gdiplus\GdipCreateBitmapFromHBITMAP","Ptr",bitmap,"Ptr",0,"Ptr*",&image),"CreateBitmapFromHBITMAP")
        rect := Buffer(16,0)
        NumPut("Int",0,"Int",0,"Int",width,"Int",height,rect)
        bitmapData := Buffer(A_PtrSize = 8 ? 32 : 24,0)
        CheckGdip(DllCall("gdiplus\GdipBitmapLockBits","Ptr",image,"Ptr",rect.Ptr,
            "UInt",1,"Int",0x26200A,"Ptr",bitmapData.Ptr),"LockBits")
        locked := true
        frame := {ptr:NumGet(bitmapData,16,"Ptr"),stride:NumGet(bitmapData,8,"Int"),w:width,h:height,at:stamp,mx:captureMX,my:captureMY}
        if !frame.ptr || Abs(frame.stride) < width*4
            throw Error("Invalid locked pixel buffer.")
        return callback.Call(frame)
    } finally {
        ; Do not let a cleanup failure bypass later releases.
        if IsObject(frame)
            frame.ptr := 0
        if locked
            DllCall("gdiplus\GdipBitmapUnlockBits","Ptr",image,"Ptr",bitmapData.Ptr)
        if image
            Gdip_DisposeImage(image)
        if previous && previous != -1 && memoryDC
            DllCall("gdi32\SelectObject","Ptr",memoryDC,"Ptr",previous,"Ptr")
        if bitmap
            DllCall("gdi32\DeleteObject","Ptr",bitmap)
        if memoryDC
            DllCall("gdi32\DeleteDC","Ptr",memoryDC)
        if screenDC
            DllCall("user32\ReleaseDC","Ptr",0,"Ptr",screenDC)
        bitmapData := 0, frame := 0
    }
}

CanvasPixel(frame,x,y) {
    global CFG
    x += CFG.ox, y += CFG.oy
    if x < 0 || y < 0 || x >= frame.w || y >= frame.h || !frame.ptr
        throw Error("Pixel read outside the captured frame.")
    ; Scan0 denotes row zero; adding a signed stride also supports bottom-up data.
    return NumGet(frame.ptr+y*frame.stride+x*4,"UInt") & 0xFFFFFF
}



; ---------- Versioned learned profile. No executable text is evaluated.
FindCheckpoint(id) {
    global Checkpoints
    for cp in Checkpoints
        if cp.ID=id
            return cp
    return 0
}
SaveLearningDraft() {
    global CFG
    SaveProfile(CFG.profile ".learning")
}
SaveProfile(path:="") {
    global E,CFG,Checkpoints,LootMarks,GroundReturns
    path:=path="" ? CFG.profile : path
    staged:=path ".tmp"
    text:="[Engine]`nVersion=1`nReady=" (E.Ready ? 1 : 0) "`nOrigin=" CFG.ox "," CFG.oy
        . "`nClient=" CFG.clientW "," CFG.clientH "`nXP=" CFG.xp.x "," CFG.xp.y "," CFG.xp.w "," CFG.xp.h "`n"
    for cp in Checkpoints {
        text.="`n[Checkpoint." cp.ID "]`n" AnchorText(cp.AnchorSignature)
            . ActionText(cp.NextObstacleBox) "Arrival=" cp.ExpectedXP.ArrivalID
            . "`nPlaneAfter=" cp.ExpectedXP.PlaneAfter "`nProven=" (cp.Proven ? 1 : 0) "`n"
    }
    for mark in LootMarks
        text.="`n[Mark." mark.ID "]`n" AnchorText(mark.AnchorSignature) ActionText(mark.Action)
    for leg in GroundReturns
        text.="`n[Return." leg.ID "]`n" AnchorText(leg.AnchorSignature) "Point=" leg.Point.x "," leg.Point.y "`nArrival=" leg.ArrivalID "`n"
    try {
        handle:=FileOpen(staged,"w","UTF-16")
        try handle.Write(text)
        finally handle.Close()
        if FileExist(path)
            FileCopy(path,path ".bak",1)
        FileMove(staged,path,1)
    } finally {
        if FileExist(staged)
            FileDelete(staged)
    }
}
AnchorText(anchor) => "Plane=" anchor.Plane "`nMini=" EncodePoints(anchor.mini) "`nWorld=" EncodePoints(anchor.world) "`n"
ActionText(action) => "Box=" action.Box.x1 "," action.Box.y1 "," action.Box.x2 "," action.Box.y2 "," action.Box.color
    . "`nUV=" action.U "," action.V "`nUptext=" EncodeSignature(action.Uptext) "`n"

LoadProfile() {
    global E,CFG,Checkpoints,LootMarks,GroundReturns
    path:=CFG.profile
    if !FileExist(path)
        return
    if FileGetSize(path)>2000000 || IniRead(path,"Engine","Version","")!="1"
        throw Error("Invalid/unsupported checkpoint profile")
    if IniRead(path,"Engine","Ready","0")!="1"
        return
    origin:=ReadNumbers(IniRead(path,"Engine","Origin"),2)
    client:=ReadNumbers(IniRead(path,"Engine","Client"),2)
    xp:=ReadNumbers(IniRead(path,"Engine","XP"),4)
    if origin[1]<0 || origin[2]<0 || client[1]<765 || client[2]<503 || client[1]>8000 || client[2]>8000
        throw Error("Invalid stored layout")
    CFG.ox:=Integer(origin[1]),CFG.oy:=Integer(origin[2]),CFG.clientW:=Integer(client[1]),CFG.clientH:=Integer(client[2])
    CFG.xp:={x:Integer(xp[1]),y:Integer(xp[2]),w:Integer(xp[3]),h:Integer(xp[4])}
    if CFG.xp.x<0 || CFG.xp.y<0 || CFG.xp.w<3 || CFG.xp.h<3 || CFG.xp.x+CFG.xp.w>765 || CFG.xp.y+CFG.xp.h>503
        throw Error("Invalid stored XP region")
    checkpointsLoaded:=[],marksLoaded:=[],returnsLoaded:=[]
    for section in StrSplit(IniRead(path),"`n") {
        parts:=StrSplit(section,".")
        if parts.Length!=2
            continue
        kind:=parts[1],id:=parts[2]
        if kind!="Checkpoint" && kind!="Mark" && kind!="Return"
            continue
        if !RegExMatch(id,"^[A-Za-z][A-Za-z0-9_]{0,63}$")
            throw Error("Invalid checkpoint ID")
        anchor:=ReadAnchor(path,section)
        if kind="Checkpoint" {
            if checkpointsLoaded.Length>=128
                throw Error("Checkpoint limit exceeded")
            arrival:=IniRead(path,section,"Arrival",""),planeAfter:=IniRead(path,section,"PlaneAfter","")
            if arrival!="" && !RegExMatch(arrival,"^[A-Za-z][A-Za-z0-9_]{0,63}$")
                throw Error("Invalid arrival ID")
            if planeAfter!="" && planeAfter!="ground" && planeAfter!="roof"
                throw Error("Invalid expected plane")
            checkpointsLoaded.Push({ID:id,AnchorSignature:anchor,NextObstacleBox:ReadAction(path,section),
                ExpectedXP:NewExpected(arrival,planeAfter),Proven:IniRead(path,section,"Proven","0")="1"})
        } else if kind="Mark" {
            if marksLoaded.Length>=128
                throw Error("Mark limit exceeded")
            action:=ReadAction(path,section)
            if action.Uptext.kind!="loot" || action.Box.color!="red"
                throw Error("Invalid Mark signature")
            marksLoaded.Push({ID:id,AnchorSignature:anchor,Action:action})
        } else {
            if returnsLoaded.Length>=128 || anchor.Plane!="ground"
                throw Error("Invalid ground recovery rule")
            point:=ReadNumbers(IniRead(path,section,"Point"),2)
            distance:=(point[1]-CFG.mini.x)**2+(point[2]-CFG.mini.y)**2
            if distance<64 || distance>(CFG.mini.r*0.80)**2
                throw Error("Invalid minimap waypoint")
            returnsLoaded.Push({ID:id,AnchorSignature:anchor,Point:{x:point[1],y:point[2]},ArrivalID:IniRead(path,section,"Arrival")})
        }
    }
    if checkpointsLoaded.Length<3
        throw Error("Ready profile must contain at least three checkpoints")
    for cp in checkpointsLoaded {
        found:=false
        if !cp.Proven || cp.NextObstacleBox.Uptext.kind!="obstacle"
            throw Error("Unproven checkpoint in ready profile")
        for destination in checkpointsLoaded
            if destination.ID=cp.ExpectedXP.ArrivalID
                found:=true
        if !found
            throw Error("Missing arrival checkpoint for " cp.ID)
    }
    for leg in returnsLoaded {
        found:=leg.ArrivalID="Ground_Course_Start"
        for nextLeg in returnsLoaded
            if nextLeg.ID=leg.ArrivalID && nextLeg.ID!=leg.ID
                found:=true
        if !found
            throw Error("Missing ground-return destination")
    }
    Checkpoints:=checkpointsLoaded,LootMarks:=marksLoaded,GroundReturns:=returnsLoaded,E.Ready:=true
}
ReadAnchor(path,section) {
    plane:=IniRead(path,section,"Plane")
    if plane!="ground" && plane!="roof"
        throw Error("Invalid anchor plane")
    anchor:={Plane:plane,mini:DecodePoints(IniRead(path,section,"Mini")),world:DecodePoints(IniRead(path,section,"World"))}
    if anchor.mini.Length<8 || anchor.world.Length<30
        throw Error("Insufficient anchor landmarks")
    return anchor
}
ReadAction(path,section) {
    f:=StrSplit(IniRead(path,section,"Box"),",")
    if f.Length!=5
        throw Error("Invalid obstacle bounds")
    box:={x1:Integer(f[1]),y1:Integer(f[2]),x2:Integer(f[3]),y2:Integer(f[4]),color:f[5]}
    uv:=ReadNumbers(IniRead(path,section,"UV"),2)
    if box.x1<4 || box.y1<4 || box.x2>515 || box.y2>337 || box.x2-box.x1<8 || box.y2-box.y1<8
        || (box.color!="green" && box.color!="red") || uv[1]<0.1 || uv[1]>0.9 || uv[2]<0.1 || uv[2]>0.9
        throw Error("Unsafe stored clickbox")
    return {Box:box,U:uv[1],V:uv[2],Uptext:DecodeSignature(IniRead(path,section,"Uptext"))}
}


EncodePoints(points) {
    text := ""
    for p in points
        text .= (text = "" ? "" : ";") p[1] "," p[2] "," p[3]
    return text
}
DecodePoints(text) {
    out := []
    for entry in StrSplit(text,";") {
        p := ReadNumbers(entry,3)
        if Abs(p[1]) > 765 || Abs(p[2]) > 503 || p[3] < 0 || p[3] > 0xFFFFFF || out.Length >= 300
            throw Error("Invalid landmark data.")
        out.Push([Integer(p[1]),Integer(p[2]),Integer(p[3])])
    }
    return out
}
EncodeProfile(profile) {
    text := ""
    for key, value in profile
        text .= (text = "" ? "" : ";") key "," value
    return text
}
DecodeProfile(text) {
    profile := Map()
    if text = ""
        return profile
    for entry in StrSplit(text,";") {
        pair := ReadNumbers(entry,2)
        if pair[1] < 0 || pair[1] > 358 || pair[2] < 0 || pair[2] > 100 || profile.Count >= 359
            throw Error("Invalid signature profile.")
        profile[Integer(pair[1])] := Integer(pair[2])
    }
    return profile
}
EncodeSignature(sig) => sig.kind "|" sig.nameX "|" sig.nameW "|" sig.nameN "|" EncodeProfile(sig.name) "|" EncodeProfile(sig.white)
DecodeSignature(text) {
    fields := StrSplit(text,"|")
    if fields.Length != 6 || !InStr("|none|obstacle|loot|","|" fields[1] "|")
        throw Error("Invalid signature.")
    return {kind:fields[1],nameX:Integer(fields[2]),nameW:Integer(fields[3]),nameN:Integer(fields[4]),
        name:DecodeProfile(fields[5]),white:DecodeProfile(fields[6])}
}
ReadNumbers(text,count) {
    fields := StrSplit(text,","), values := []
    if fields.Length != count
        throw Error("Invalid numeric field count.")
    for field in fields {
        if !RegExMatch(field,"^-?\d+(\.\d+)?$")
            throw Error("Invalid numeric data.")
        values.Push(Number(field))
    }
    return values
}



; Offline self-tests. Never invoke Act, CommitClick, SmoothMove, or game input.
RunSelfTests() {
    global E,CFG,Checkpoints,LootMarks,GroundReturns,CT_COUNT,CT_BORROWED
    CT_COUNT:=0,CT_BORROWED:=0
    savedE:=E.Clone(),savedCFG:=CFG.Clone(),savedCP:=Checkpoints,savedMarks:=LootMarks,savedReturns:=GroundReturns
    testDir:=A_ScriptDir "\selftest_" DllCall("kernel32\GetCurrentProcessId","UInt") "_" Now()
    DirCreate(testDir)
    CFG.profile:=testDir "\profile.ini",CFG.log:=testDir "\events.log"
    try {
        CTChooseTarget()
        CTCounterAndConfirmation()
        CTInventoryEvidence()
        CTRecoveryAndWatchdog()
        CTSafePoints()
        CTLearningAndProfile()
        CTPassiveLapClosure()
        CTWithFrame(CTAnchorOrdering)
        CTWithFrame(CTCounterPixelsAndInventory)
        CTNativeScopes()
        FileAppend("PASS: " CT_COUNT " assertions (anchors, confirmation, learning, graph storage, native cleanup).`n","*")
        return 0
    } catch as testError {
        FileAppend("FAIL: " testError.Message "`n" testError.Stack "`n","*")
        return 1
    } finally {
        E:=savedE,CFG:=savedCFG,Checkpoints:=savedCP,LootMarks:=savedMarks,GroundReturns:=savedReturns
        CT_BORROWED:=0
        DirDelete(testDir,true)
    }
}
CTAssert(condition,message) {
    global CT_COUNT
    if !condition
        throw Error("Self-test: " message)
    CT_COUNT+=1
}
CTThrows(callback,message) {
    caught:=false
    try callback.Call()
    catch {
        caught:=true
    }
    CTAssert(caught,message)
}
CTBox(x:=40,y:=70,color:="green") => {x1:x,y1:y,x2:x+40,y2:y+30,color:color}
CTSignature(kind:="obstacle") => {kind:kind,nameX:20,nameW:30,nameN:12,name:Map(20,3,23,7,31,5,49,2),white:Map(2,3,5,2,11,4)}
CTAction(box:=0,kind:="obstacle") => {Box:IsObject(box)?box:CTBox(),U:0.5,V:0.5,Uptext:CTSignature(kind)}
CTAnchor(color:=0x606070,plane:="roof") {
    mini:=[],world:=[]
    Loop 30 {
        mini.Push([Mod(A_Index-1,6)*7-21,Floor((A_Index-1)/6)*7-14,color])
        world.Push([20+Mod(A_Index-1,6)*60,60+Floor((A_Index-1)/6)*45,color])
    }
    return {mini:mini,world:world,Plane:plane}
}
CTCheckpoint(id,arrival:="",plane:="roof",color:=0x606070) => {ID:id,Proven:true,AnchorSignature:CTAnchor(color,plane),NextObstacleBox:CTAction(),ExpectedXP:NewExpected(arrival,"")}
CTInventory(first:=0) {
    colors:=[],numbers:=Map()
    Loop 16
        colors.Push(0x404040)
    Loop 4
        numbers[first+A_Index-1]:=true
    return {Colors:colors,Numbers:numbers}
}
CTCounter(first:=0,count:=20) {
    pixels:=Map(),hash:=2166136261
    Loop count {
        key:=first+A_Index-1,pixels[key]:=true
        hash:=((hash^key)*16777619)&0xFFFFFFFF
    }
    return {Pixels:pixels,Count:pixels.Count,Hash:hash,Readable:true,Stable:true}
}
CTWorld(cp:=0,plane:="roof") => {At:10000,Checkpoint:cp,Scores:Map(),Plane:plane,PlaneReliable:true,
    RawPlane:plane,Black:0,GroundReturn:0,MarkMatches:[],Boxes:[CTBox()],Uptext:CTSignature(),
    Inventory:CTInventory(),Counter:CTCounter(),Anchor:CTAnchor(),Mouse:{x:60,y:85}}
CTPending(kind:="Obstacle",at:=10000) {
    global CFG
    target:={Kind:kind,ID:"Roof_A",Expected:NewExpected("","")}
    return {Target:target,At:at,Deadline:at+CFG.confirmMs,BeforePlane:"roof",
        BeforeInventory:CTInventory(),BeforeScores:Map(),BeforeCounter:CTCounter(),Evidence:"",EvidenceSince:0}
}

CTChooseTarget() {
    cp:=CTCheckpoint("Roof_Current"),world:=CTWorld(cp)
    target:=ChooseTarget(world)
    CTAssert(target.Ready && target.ID="Roof_Current", "visible current checkpoint selects its own action")
    mark:={ID:"Grace_A",AnchorSignature:CTAnchor(),Action:CTAction(CTBox(150,90,"red"),"loot")}
    world.MarkMatches:=[mark],world.Boxes.Push(mark.Action.Box)
    CTAssert(ChooseTarget(world).Kind="LootMark", "reachable active-plane loot preempts obstacle")
    CTAssert(ChooseTarget(world,Map("Grace_A",true)).Kind="Obstacle", "rejected Mark signature cannot starve a valid obstacle")
    mark.AnchorSignature.Plane:="ground"
    CTAssert(ChooseTarget(world).Kind="Obstacle", "wrong-plane Mark cannot preempt obstacle")
    world:=CTWorld(0,"ground"),world.Boxes:=[]
    world.GroundReturn:={ID:"Return_A",ArrivalID:"Ground_Course_Start",Point:{x:660,y:95},AnchorSignature:CTAnchor(0x606070,"ground")}
    CTAssert(ChooseTarget(world).Kind="Navigate", "verified ground anchor selects course-start navigation")
    world.PlaneReliable:=false
    CTAssert(!ChooseTarget(world).Ready, "unreliable ground plane blocks recovery navigation")
    world.PlaneReliable:=true,world.Plane:="roof"
    CTAssert(!ChooseTarget(world).Ready, "roof cannot use a ground return leg")
    world.Plane:="unknown"
    CTAssert(!ChooseTarget(world).Ready, "unknown plane waits without navigation")
    ambiguous:=[CTBox(),CTBox(41,70)]
    CTAssert(!IsObject(FindTargetBox(ambiguous,CTBox())), "ambiguous overlapping target boxes are rejected")
}

CTCounterAndConfirmation() {
    global E,CFG
    baseline:=CTCounter(0,20),changed:=CTCounter(10,20)
    CTAssert(CounterChanged(baseline,changed), "counter requires substantial added and removed foreground")
    CTAssert(!CounterChanged(baseline,CTCounter(0,12)), "fading counter cannot prove XP")
    CTAssert(!CounterChanged(baseline,CTCounter(0,30)), "added-only overlay cannot prove XP")
    CTAssert(!CounterChanged(baseline,baseline), "unchanged counter cannot prove XP")
    CTAssert(!CounterChanged(EmptyCounter(),changed), "disabled baseline prevents stale XP completion")
    CTAssert(!CounterChanged(CTCounter(0,4),changed), "insufficient baseline foreground cannot prove XP")
    p:=CTPending(),world:=CTWorld(),world.Counter:=changed
    CTAssert(ConfirmationEvidence(p,world,10899)="", "XP evidence is ignored before 900 ms")
    CTAssert(InStr(ConfirmationEvidence(p,world,10900),"XP counter changed:")=1, "counter proof becomes eligible at 900 ms")
    arrival:=CTCheckpoint("Roof_B"),world.Checkpoint:=arrival,world.Scores["Roof_B"]:=0.99
    p.Target.Expected:=NewExpected("Roof_B","")
    CTAssert(ConfirmationEvidence(p,world,10400)="arrival at Roof_B", "new matched arrival anchor confirms transition")
    p.BeforeScores["Roof_B"]:=0.99
    world.Counter:=baseline
    CTAssert(ConfirmationEvidence(p,world,11000)="", "pre-existing arrival match cannot reconfirm departure")
    p:=CTPending(),p.Target.Expected:=NewExpected("","ground"),world:=CTWorld(0,"ground")
    CTAssert(ConfirmationEvidence(p,world,10400)="expected plane transition", "configured plane transition is explicit evidence")
    world.PlaneReliable:=false
    CTAssert(ConfirmationEvidence(p,world,10400)="", "unreliable plane cannot confirm arrival")
    p:=CTPending("Navigate"),p.Target.Expected:=NewExpected("Return_B","")
    world:=CTWorld(0,"ground"),world.GroundReturn:={ID:"Return_B"},world.Scores["Return_B"]:=0.99
    CTAssert(ConfirmationEvidence(p,world,10400)="arrival at Return_B", "ground navigation confirms its learned next return anchor")
    p:=CTPending("LootMark"),world:=CTWorld(),world.Inventory:=CTInventory(10)
    CTAssert(ConfirmationEvidence(p,world,10400)="inventory change:" InventoryFingerprint(world.Inventory), "Mark confirmation detects quantity glyph change with unchanged icon")
    E.Completed:=0,E.Phase:="Confirm",E.Pending:=CTPending(),E.ConfirmAt:=10000
    world:=CTWorld(),world.Counter:=changed
    Confirm(world,11000)
    CTAssert(E.Completed=0 && E.Phase="Confirm", "first changed counter frame does not log completion")
    logBefore:=FileExist(CFG.log) ? FileRead(CFG.log) : ""
    CTAssert(!InStr(logBefore,"Confirmed Roof_A"), "completion log waits for stable evidence")
    world.Counter:=CTCounter(20,20)
    Confirm(world,11100)
    CTAssert(E.Pending.EvidenceSince=11100, "changing counter hash restarts the stability window")
    Confirm(world,11100+CFG.stableMs-1)
    CTAssert(E.Completed=0, "completion waits through the full stability interval")
    Confirm(world,11100+CFG.stableMs)
    CTAssert(E.Completed=1 && E.Phase="Identify" && !IsObject(E.Pending), "stable confirmation counts once then identifies afresh")
    CTAssert(InStr(FileRead(CFG.log),"Confirmed Roof_A by XP counter changed:"), "only confirmed action receives completion log entry")
    Confirm(world,12000)
    CTAssert(E.Completed=1, "a cleared transaction cannot increment completion again")
}

CTInventoryEvidence() {
    global E,CFG,LootMarks
    baseline:=CTInventory(),addedOnly:=CTInventory(),removedOnly:=CTInventory()
    addedOnly.Numbers[20]:=true,addedOnly.Numbers[21]:=true
    removedOnly.Numbers.Delete(0),removedOnly.Numbers.Delete(1)
    CTAssert(InventoryChanged(baseline,addedOnly), "added-only quantity glyph change confirms a stack pickup")
    CTAssert(InventoryChanged(baseline,removedOnly), "removed-only quantity glyph change confirms a stack pickup")
    onePixel:=CTInventory(),onePixel.Numbers[20]:=true
    CTAssert(!InventoryChanged(baseline,onePixel), "one changed quantity pixel remains below evidence threshold")
    reordered:=CTInventory(),reordered.Numbers:=Map(3,true,2,true,1,true,0,true)
    CTAssert(InventoryFingerprint(baseline)=InventoryFingerprint(reordered), "inventory fingerprint is independent of number-mask insertion order")
    CTAssert(InventoryFingerprint(addedOnly)!=InventoryFingerprint(removedOnly), "different quantity shapes have different evidence keys")
    E.Completed:=9,E.Phase:="Confirm",E.Pending:=CTPending("LootMark")
    world:=CTWorld(),world.Inventory:=addedOnly
    Confirm(world,11000)
    world.Inventory:=removedOnly
    Confirm(world,11100)
    CTAssert(E.Phase="Confirm" && E.Pending.EvidenceSince=11100, "changing inventory animation resets runtime evidence stability")
    Confirm(world,11100+CFG.stableMs-1)
    CTAssert(E.Phase="Confirm", "inventory proof waits for the full unchanged-fingerprint interval")
    Confirm(world,11100+CFG.stableMs)
    CTAssert(E.Phase="Identify" && !IsObject(E.Pending) && E.Completed=9, "stable inventory proof confirms loot without counting an obstacle")
    source:=CTWorld(),source.Inventory:=baseline
    pending:={Kind:"mark",Source:source,Action:CTAction(CTBox(150,90,"red"),"loot"),At:10000,Deadline:35000,
        Baseline:source.Counter,Evidence:"",EvidenceSince:0,Confirmed:false}
    E.Learning:=pending,E.LearningPlane:="roof"
    learnedBefore:=LootMarks.Length,world.Inventory:=addedOnly
    ObserveLearning(world,11000)
    world.Inventory:=removedOnly
    ObserveLearning(world,11100)
    CTAssert(!pending.Confirmed && pending.EvidenceSince=11100 && LootMarks.Length=learnedBefore, "changing inventory animation cannot complete manual teaching")
    ObserveLearning(world,11100+CFG.stableMs)
    CTAssert(pending.Confirmed && LootMarks.Length=learnedBefore+1, "stable inventory fingerprint teaches one confirmed Mark")
    E.Learning:=0
}

CTRecoveryAndWatchdog() {
    global E,CFG
    E.Completed:=7,E.Phase:="Confirm",E.Pending:=CTPending(),E.ConfirmAt:=10000
    E.Pending.Evidence:="XP counter changed:" CTCounter(10,20).Hash,E.Pending.EvidenceSince:=11000
    world:=CTWorld(),world.Counter:=CTCounter(10,20),oldToken:=E.Token
    Confirm(world,10000+CFG.confirmMs)
    CTAssert(E.Phase="Identify" && !IsObject(E.Pending), "exact 8-second boundary discards pending transaction")
    CTAssert(E.Completed=7 && E.Token>oldToken, "timeout invalidates input without advancing completion")
    E.Running:=true,E.Mode:="Run",E.Busy:=true,E.Phase:="Confirm",E.Pending:=CTPending()
    E.ConfirmAt:=Now()-CFG.watchdogMs-1,oldToken:=E.Token
    Watchdog()
    CTAssert(E.Phase="Identify" && !IsObject(E.Pending) && E.Token>oldToken, "watchdog resets Confirm independently of busy tick")
    CTAssert(E.Busy && E.Completed=7, "watchdog neither owns busy state nor increments progress")
    E.Busy:=false,E.Phase:="Confirm",E.Pending:=CTPending(),E.ConfirmAt:=Now()
    Watchdog()
    CTAssert(E.Phase="Confirm", "watchdog leaves an unexpired transaction alone")
    Recover("Self-test reset",0)
}

CTSafePoints() {
    box:=CTBox(20,60)
    for uv in [[0,0],[1,1],[0.5,0.5],[-2,3]] {
        point:=SafePoint(box,uv[1],uv[2])
        CTAssert(InsideSafe(point,box), "all computed points remain inside the inner 80 percent")
        CTAssert(point.x>=24 && point.x<=56 && point.y>=63 && point.y<=87, "minimum interior margins are retained")
    }
    CTAssert(!InsideSafe({x:20,y:60},box), "outline pixels are excluded from safe clicks")
}

CTLearningAndProfile() {
    global E,CFG,Checkpoints,LootMarks,GroundReturns
    E.Mode:="Learn",E.Running:=true,E.Ready:=false,E.LapsMatched:=0,E.LastGraph:="",E.LapValid:=true
    start:=CTCheckpoint("Ground_Course_Start","Roof_A","ground")
    first:=CTCheckpoint("Roof_A","Roof_B")
    last:=CTCheckpoint("Roof_B","Ground_Course_Start")
    Checkpoints:=[last,start,first],LootMarks:=[],GroundReturns:=[]
    E.ReturnTrail:=[{ID:"Provisional_A",AnchorSignature:CTAnchor(0x606070,"ground"),Point:{x:660,y:95},ArrivalID:""},
        {ID:"Provisional_B",AnchorSignature:CTAnchor(0x203090,"ground"),Point:{x:650,y:100},ArrivalID:""}]
    CTAssert(GroundReturns.Length=0, "observed ground walk remains provisional before entrance closure")
    PromoteGroundReturns()
    CTAssert(GroundReturns.Length=2 && E.ReturnTrail.Length=0, "entrance closure promotes copied ground return observations")
    CTAssert(GroundReturns[1].ArrivalID=GroundReturns[2].ID && GroundReturns[2].ArrivalID="Ground_Course_Start", "promoted ground legs retain observed arrival chain")
    E.LapPath:=[start.ID,first.ID,last.ID]
    CloseTeachingLap()
    CTAssert(E.LapsMatched=1 && !E.Ready && E.Mode="Learn", "one closed confirmed graph never starts automation")
    E.LapPath:=[start.ID,first.ID,last.ID],E.LapValid:=true
    CloseTeachingLap()
    CTAssert(E.LapsMatched=2 && E.Ready && E.Mode="Review" && !E.Running, "two matching graphs require review/relaunch without auto-run")
    CTAssert(FileExist(CFG.profile), "two verified laps save a ready profile")
    Checkpoints:=[],LootMarks:=[],GroundReturns:=[],E.Ready:=false
    LoadProfile()
    CTAssert(E.Ready && Checkpoints.Length=3, "ready graph profile round trips")
    CTAssert(GroundReturns.Length=2 && GroundReturns[1].ArrivalID=GroundReturns[2].ID, "ground navigation arrival graph round trips")
    CTAssert(FindCheckpoint("Ground_Course_Start").ExpectedXP.ArrivalID="Roof_A", "graph serialization preserves ground successor")
    CTAssert(FindCheckpoint("Roof_B").ExpectedXP.ArrivalID="Ground_Course_Start", "graph serialization preserves course closure")
    action:=FindCheckpoint("Roof_A").NextObstacleBox
    CTAssert(SignatureScore(action.Uptext,CTSignature())>0.999999, "profile serialization preserves learned uptext")
    source:=CTWorld(),source.Counter:=CTCounter()
    learning:={Kind:"checkpoint",Source:source,Action:CTAction(),At:10000,Deadline:35000,Baseline:source.Counter,Evidence:"",EvidenceSince:0,Confirmed:false}
    E.Learning:=learning,E.LapValid:=true
    noProof:=CTWorld(),noProof.Counter:=CTCounter(0,12)
    ObserveLearning(noProof,11000)
    CTAssert(E.Learning=learning && !learning.Confirmed && learning.At=10000 && learning.Deadline=35000, "waiting for XP preserves original learning transaction and deadline")
    E.Learning:=0,E.Mode:="Learn",E.Running:=true,E.LapValid:=true
    source:=CTWorld(),source.At:=10000,source.Counter.Stable:=true
    BeginObservedLearning(source,{x:60,y:85},10000)
    admitted:=E.Learning,originalBaseline:=admitted.Baseline
    retry:=CTWorld(),retry.At:=11000
    BeginObservedLearning(retry,{x:60,y:85},11000)
    CTAssert(E.Learning=admitted && admitted.Deadline=10000+CFG.learnMs && admitted.At=10000, "identical teaching retry never extends its original deadline")
    CTAssert(admitted.Baseline=originalBaseline && E.LapValid, "identical retry preserves completion baseline and valid lap")
    distinct:=CTWorld(),distinct.At:=12000,distinct.Boxes:=[CTBox(150,70)]
    BeginObservedLearning(distinct,{x:170,y:85},12000)
    CTAssert(E.Learning=admitted && !E.LapValid, "distinct unconfirmed obstacle invalidates lap without replacing pending action")
    E.Learning:=0,source.Counter.Stable:=false
    BeginObservedLearning(source,{x:60,y:85},10000)
    CTAssert(E.Learning.Baseline.Count=0, "unstable pre-click XP counter is disabled as completion baseline")
    E.Learning:=learning
    ObserveLearning(noProof,35000)
    CTAssert(!IsObject(E.Learning) && !E.LapValid, "learning deadline abandons observation without creating a checkpoint")
}

CTPrepareArrivalLap() {
    global E,Checkpoints,LootMarks,GroundReturns
    root:=CTCheckpoint("Ground_Course_Start","Roof_A","ground",0x606070)
    first:=CTCheckpoint("Roof_A","Roof_B","roof",0x203090)
    last:=CTCheckpoint("Roof_B","","roof",0x804020)
    Checkpoints:=[last,root,first],LootMarks:=[],GroundReturns:=[]
    E.Mode:="Learn",E.Running:=true,E.Ready:=false,E.LapsMatched:=0,E.LastGraph:="",E.LapValid:=true
    E.LapPath:=[root.ID,first.ID,last.ID],E.LastProven:=last,E.LearningPlane:="roof",E.ReturnTrail:=[]
    E.Learning:={Kind:"checkpoint",Confirmed:true}
    world:=CTWorld(root,"ground"),world.Scores[root.ID]:=0.99,world.Anchor:=root.AnchorSignature
    return {Root:root,First:first,Last:last,World:world}
}

CTPassiveLapClosure() {
    global E,Checkpoints,GroundReturns
    fixture:=CTPrepareArrivalLap()
    ObserveLearning(fixture.World,10000)
    CTAssert(E.LapsMatched=1 && !E.Ready && E.Mode="Learn", "passive entrance arrival closes the first circuit without another climb")
    CTAssert(E.LapPath.Length=0 && !IsObject(E.LastProven) && !IsObject(E.Learning) && E.LearningPlane="ground", "passive closure clears prior lap transaction state")
    CTAssert(fixture.Last.ExpectedXP.ArrivalID=fixture.Root.ID && fixture.Last.ExpectedXP.PlaneAfter="ground", "verified entrance arrival links the final checkpoint to ground")
    E.LapPath:=[fixture.Root.ID,fixture.First.ID,fixture.Last.ID],E.LastProven:=fixture.Last
    E.Learning:={Kind:"checkpoint",Confirmed:true}
    ObserveLearning(fixture.World,20000)
    CTAssert(E.LapsMatched=2 && E.Ready && E.Mode="Review" && !E.Running, "two passive circuit arrivals reach Review without a third entrance action")
    fixture:=CTPrepareArrivalLap()
    source:=CTWorld(),source.RawPlane:="roof"
    pending:={Kind:"checkpoint",Confirmed:false,Source:source,Action:CTAction(),Baseline:source.Counter,
        At:10000,Deadline:35000,Evidence:"",EvidenceSince:0}
    E.Learning:=pending
    ObserveLearning(fixture.World,11000)
    CTAssert(E.LapsMatched=0 && E.LapPath.Length=3 && E.Learning=pending && !pending.Confirmed, "entrance arrival cannot skip an unconfirmed checkpoint action")
    fixture:=CTPrepareArrivalLap()
    fixture.Last.ExpectedXP.ArrivalID:=fixture.First.ID
    E.LapsMatched:=1,E.LastGraph:="Ground_Course_Start>Roof_A;Roof_A>Roof_B;Roof_B>Ground_Course_Start;"
    ObserveLearning(fixture.World,10000)
    CTAssert(E.LapsMatched=0 && !E.Ready && E.Mode="Learn", "conflicting prior arrival invalidates this candidate lap")
    fixture:=CTPrepareArrivalLap()
    source:=CTWorld(0,"ground"),source.Anchor:=CTAnchor(0x203090,"ground")
    E.Learning:={Kind:"return",Source:source,Point:{x:660,y:95},At:9000,Deadline:34000,Confirmed:false}
    ObserveLearning(fixture.World,10000)
    CTAssert(E.LapsMatched=1 && GroundReturns.Length=1 && GroundReturns[1].ArrivalID=fixture.Root.ID, "proven entrance arrival finalizes and promotes a pending ground return")
    fixture:=CTPrepareArrivalLap()
    fixture.World.Scores[fixture.First.ID]:=0.98
    CTAssert(!MaybeCloseLapOnArrival(fixture.World) && E.LapsMatched=0, "ambiguous entrance anchor cannot close a lap")
    fixture.World.Scores.Delete(fixture.First.ID),fixture.World.PlaneReliable:=false
    CTAssert(!MaybeCloseLapOnArrival(fixture.World) && E.LapsMatched=0, "unreliable ground plane cannot close a lap")
    fixture:=CTPrepareArrivalLap()
    BeginObservedLearning(fixture.World,{x:60,y:85},12345)
    CTAssert(E.LapsMatched=1 && IsObject(E.Learning) && E.Learning.Kind="checkpoint" && E.Learning.At=12345, "entrance click first closes arrival then admits the next circuit action")
    fixture:=CTPrepareArrivalLap()
    E.LapPath:=[],E.LastProven:=0
    Loop 64
        E.LapPath.Push(fixture.First.ID),E.LapPath.Push(fixture.Last.ID)
    source:=CTWorld(),source.Anchor:=fixture.First.AnchorSignature
    pending:={Kind:"checkpoint",Source:source,Action:fixture.First.NextObstacleBox}
    LearnConfirmed(pending,source)
    CTAssert(E.LapPath.Length=128 && !E.LapValid && Checkpoints.Length=3, "long manual teaching caps candidate path without accepting a shortened lap or discarding checkpoints")
    E.LapPath:=[],E.LastProven:=0,E.Learning:=0
}

CTWithFrame(callback) {
    global CFG
    pixels:=0,frame:=0
    try {
        pixels:=Buffer(CFG.clientW*CFG.clientH*4,0)
        frame:={ptr:pixels.Ptr,stride:CFG.clientW*4,w:CFG.clientW,h:CFG.clientH}
        return callback.Call(frame)
    } finally {
        if IsObject(frame)
            frame.ptr:=0
        frame:=0,pixels:=0
    }
}
CTSetPixel(frame,x,y,color) {
    global CFG
    NumPut("UInt",color,frame.ptr+(y+CFG.oy)*frame.stride+(x+CFG.ox)*4)
}
CTAnchorOrdering(frame) {
    global Checkpoints,LootMarks,GroundReturns,CFG
    current:=CTCheckpoint("Roof_Current"),other:=CTCheckpoint("Roof_Other","","roof",0x203090)
    for p in current.AnchorSignature.mini
        CTSetPixel(frame,CFG.mini.x+p[1],CFG.mini.y+p[2],p[3])
    for p in current.AnchorSignature.world
        CTSetPixel(frame,p[1],p[2],p[3])
    box:=current.NextObstacleBox.Box
    Loop box.x2-box.x1+1 {
        x:=box.x1+A_Index-1
        CTSetPixel(frame,x,box.y1,0x00FF00),CTSetPixel(frame,x,box.y2,0x00FF00)
    }
    Loop box.y2-box.y1+1 {
        y:=box.y1+A_Index-1
        CTSetPixel(frame,box.x1,y,0x00FF00),CTSetPixel(frame,box.x2,y,0x00FF00)
    }
    LootMarks:=[],GroundReturns:=[]
    for order in [[other,current],[current,other]] {
        Checkpoints:=order
        world:=Analyze(frame)
        CTAssert(IsObject(world.Checkpoint) && world.Checkpoint.ID="Roof_Current", "matching pixels override checkpoint array ordering")
        CTAssert(ChooseTarget(world).ID="Roof_Current", "same current anchor selects the same target after reorder/restart")
    }
}

CTCounterPixelsAndInventory(frame) {
    global CFG
    Loop 20 {
        x:=CFG.xp.x+3*(A_Index-1)+2,y:=CFG.xp.y+2
        CTSetPixel(frame,x,y,0xE6E6E6)
        if A_Index<=10
            CTSetPixel(frame,x+1,y+1,0x909090)
    }
    before:=ReadCounter(frame)
    CTAssert(before.Count=20 && before.Readable, "counter foreground mask contains all bright glyph pixels independently of shadows")
    Loop 20 {
        x:=CFG.xp.x+3*(A_Index-1)+2,y:=CFG.xp.y+2
        CTSetPixel(frame,x,y,0xC8C8C8),CTSetPixel(frame,x+1,y+1,0x464646)
    }
    shadowFade:=ReadCounter(frame)
    CTAssert(shadowFade.Count=before.Count && !CounterChanged(before,shadowFade), "darkening shadows cannot manufacture added foreground XP pixels")
    Loop 8
        CTSetPixel(frame,CFG.xp.x+3*(A_Index-1)+2,CFG.xp.y+2,0xAAAAAA)
    foregroundFade:=ReadCounter(frame)
    CTAssert(foregroundFade.Count=12 && !CounterChanged(before,foregroundFade), "foreground fading is a strict mask subset and cannot confirm XP")
    CTSetPixel(frame,562,210,0xFFFF00),CTSetPixel(frame,564,210,0xFFFF00)
    inventoryBefore:=InventorySample(frame)
    CTSetPixel(frame,562,210,0),CTSetPixel(frame,564,210,0)
    CTSetPixel(frame,566,210,0xFFFF00),CTSetPixel(frame,568,210,0xFFFF00)
    inventoryAfter:=InventorySample(frame)
    CTAssert(InventoryChanged(inventoryBefore,inventoryAfter), "two-pixel quantity glyph delta confirms stack change with unchanged coarse inventory")
}

CTNativeScopes() {
    global CFG,E,CT_BORROWED
    fixture:=Gui("-Caption +ToolWindow +AlwaysOnTop","Checkpoint capture self-test")
    fixture.BackColor:="243648"
    fixture.SetFont("s8 cFFFFFF","Arial")
    fixture.AddText("x" CFG.ox+CFG.xp.x+4 " y" CFG.oy+CFG.xp.y " w120 h18 BackgroundTrans","1234567890123")
    try {
        fixture.Show("NA x40 y40 w" CFG.clientW " h" CFG.clientH)
        Sleep(100)
        metadata:=WithClientFrame(fixture.Hwnd,CTCaptureMetadata)
        CTAssert(metadata.At=metadata.CapturedAt && metadata.After-metadata.At>=35, "observation keeps capture-time timestamp across delayed analysis")
        CTAssert(metadata.MouseX=metadata.CaptureMouseX-CFG.ox && metadata.MouseY=metadata.CaptureMouseY-CFG.oy, "observation uses mouse coordinates sampled with captured pixels")
        Loop 6
            WithClientFrame(fixture.Hwnd,frame=>frame.w)
        E.Hwnd:=fixture.Hwnd,E.Cache:=0,E.CounterSince:=0
        firstObserved:=Observe()
        CTAssert(firstObserved.Counter.Readable && !firstObserved.Counter.Stable, "first readable native counter capture is not yet a stable baseline")
        E.Cache:=firstObserved,E.CounterSince:=firstObserved.At-CFG.stableMs
        secondObserved:=Observe()
        CTAssert(secondObserved.Counter.Stable, "unchanged readable counter becomes stable after observation interval")
        beforeGdi:=CTGdiCount(),beforeBytes:=CTPrivateBytes()
        Loop 20 {
            CTThrows(()=>WithClientFrame(fixture.Hwnd,CTThrowCapture),"capture propagates callback exception")
            CTAssert(IsObject(CT_BORROWED) && CT_BORROWED.ptr=0,"finally invalidates borrowed pixel view")
            CTAssert(WithClientFrame(fixture.Hwnd,frame=>frame.h)=CFG.clientH,"capture recovers after callback exception")
        }
        afterGdi:=CTGdiCount(),afterBytes:=CTPrivateBytes()
        CTAssert(afterGdi<=beforeGdi+2,"native success/failure scopes do not accumulate GDI handles")
        if beforeBytes && afterBytes
            CTAssert(afterBytes-beforeBytes<16777216,"exception scopes do not retain bitmap-sized native allocations")
    } finally {
        fixture.Destroy(),CT_BORROWED:=0
    }
}
CTThrowCapture(frame) {
    global CT_BORROWED
    CT_BORROWED:=frame
    throw Error("Intentional capture callback failure")
}
CTCaptureMetadata(frame) {
    Sleep(35)
    world:=Analyze(frame)
    return {At:world.At,CapturedAt:frame.at,After:Now(),MouseX:world.Mouse.x,MouseY:world.Mouse.y,
        CaptureMouseX:frame.mx,CaptureMouseY:frame.my}
}
CTGdiCount() => DllCall("user32\GetGuiResources","Ptr",DllCall("kernel32\GetCurrentProcess","Ptr"),"UInt",0,"UInt")
CTPrivateBytes() {
    size:=A_PtrSize=8?80:44,counters:=Buffer(size,0)
    NumPut("UInt",size,counters)
    if !DllCall("psapi\GetProcessMemoryInfo","Ptr",DllCall("kernel32\GetCurrentProcess","Ptr"),"Ptr",counters.Ptr,"UInt",size)
        return 0
    return NumGet(counters,A_PtrSize=8?72:40,"UPtr")
}

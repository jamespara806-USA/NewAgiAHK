#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn All, StdOut

; Stateless Agility Engine 1.0
; Windows / AutoHotkey v2 / Fixed Classic client.
;
; Decisions use current pixels and an UNORDERED calibration matrix.
; No course index, next pointer, completed-obstacle list, or inferred advances.
;
; F6       Bind active client
; F2       Teach forward obstacle
; F3       Teach reachable Mark of grace
; F4       Teach ground recovery waypoint
; F8       Start / pause
; F9       Pause
; F10      Pause and toggle dry run / actual clicking
; F12      Inspect current sensors
; Ctrl+Esc Exit
;
; Optional:
; AutoHotkey64.exe Agility_Stateless.ahk --selftest

SendMode("Event")
SetMouseDelay(-1)
CoordMode("Mouse", "Client")
InstallMouseHook()

CFG := DefaultConfig()
MATRIX := Map()
ENGINE := {
    hwnd:0, running:false, busy:false, epoch:0, dryRun:true,
    lastId:"", lastAt:0, repeats:0, runAt:0,
    token:0, gdipModule:0, lastStatus:"", lastLogAt:0
}
TICK_FN := Tick
OnExit(Shutdown)

try {
    ENGINE.gdipModule := DllCall(
        "kernel32\LoadLibraryW",
        "Str", "gdiplus.dll",
        "Ptr"
    )
    if !ENGINE.gdipModule
        throw Error("Cannot load GDI+.")

    ENGINE.token := Gdip_Startup()

    if A_Args.Length && A_Args[1] = "--selftest"
        ExitApp(RunSelfTests())

    LoadProfile()
    Status("Paused. F6 binds client; F2 obstacle; F3 mark; F4 ground leg; F8 starts.")
} catch as startupError {
    if A_Args.Length && A_Args[1] = "--selftest" {
        FileAppend(
            "FAIL startup: " startupError.Message
            " at line " startupError.Line "`n",
            "*"
        )
        ExitApp(1)
    }
    MsgBox(startupError.Message, "Stateless Agility: startup error", "Iconx")
    ExitApp(1)
}

F2::Teach("obstacle")
F3::Teach("loot")
F4::Teach("groundfallback")
F6::BindClient()
F8::ToggleRun()
F9::PauseEngine("Paused by F9")
F10::ToggleDryRun()
F12::Inspect()
^Esc::ExitApp()

DefaultConfig() {
    return {
        profile:A_ScriptDir "\Agility_Stateless.ini",
        log:A_ScriptDir "\Agility_Stateless.log",
        ox:4, oy:26, clientW:773, clientH:539,
        world:{x:4,y:4,w:512,h:334},
        mini:{x:641,y:85,r:68},
        hover:{x:6,y:7,w:358,h:16},
        tickMs:160, hoverMs:140,
        scanBudgetMs:6000, maxProbes:12,
        minScene:0.88, minSignature:0.90, minGeometry:0.50,
        planeMargin:0.06, actionMargin:0.045,
        colorTolerance:32, centerTolerance:34,
        maxSceneDrift:0.075,
        roofBlack:0.45, groundBlack:0.15, blackLevel:24,
        maxSessionMs:14400000, repeatLimit:3, logBytes:1000000
    }
}

; ============================================================================
; SENSOR FUSION
;
; Every call captures the entire client once. Plane evidence, scene landmarks,
; bounding boxes, and the current hover signature come from the same bitmap.
;
; The game exposes only ONE hover label at a time. Checking several targets
; therefore requires several complete snapshots, followed by final validation.
;
; Returned observations contain copied values, never pixel buffers/pointers.
; ============================================================================

EvaluateWorldState() {
    global ENGINE
    return WithClientFrame(ENGINE.hwnd, AnalyzeFrame)
}

AnalyzeFrame(frame) {
    global CFG, MATRIX

    MouseGetPos(&mx, &my)
    boxes := FindHighlights(frame)
    signature := SigFromFrame(frame)
    black := BlackRatio(frame)

    sources := []
    best := 0.0
    other := 0.0
    plane := "unknown"
    rawPlane := black >= CFG.roofBlack
        ? "roof"
        : black <= CFG.groundBlack ? "ground" : "unknown"

    for id, row in MATRIX {
        fit := SceneFit(frame, row)
        sources.Push({row:row, fit:fit})
        if fit.score > best
            best := fit.score, plane := row.plane
    }

    for source in sources
        if source.row.plane != plane
            other := Max(other, source.fit.score)

    ; A calibrated source can identify a roof with a ground-like black ratio.
    ; Opposing-plane source matches must be clearly separated.
    if best < CFG.minScene
        plane := rawPlane
    else if best - other < CFG.planeMargin
        plane := "unknown"

    world := {
        at:Now(), plane:plane, rawPlane:rawPlane, black:black,
        sourceScore:best, boxes:boxes, signature:signature,
        candidates:[], groundLegs:[]
    }

    hovered := HoveredBox(boxes, mx-CFG.ox, my-CFG.oy)

    for source in sources {
        row := source.row
        fit := source.fit

        if plane = "unknown"
            || row.plane != plane
            || fit.score < CFG.minScene
            continue

        if row.kind = "groundfallback" {
            if plane = "ground"
                world.groundLegs.Push({
                    id:row.id, kind:row.kind, plane:plane,
                    point:row.point, confidence:fit.score,
                    holdMs:row.holdMs
                })
            continue
        }

        for bi, box in boxes {
            if row.kind = "loot" && box.color != "red"
                continue

            geometry := GeometryScore(row.box, box)
            if geometry < CFG.minGeometry
                continue

            point := BoxPoint(box, row.u, row.v)
            sim := bi = hovered
                ? SignatureScore(signature, row.signature)
                : 0.0

            verified := sim >= CFG.minSignature
                && signature.kind = row.kind

            world.candidates.Push({
                id:row.id, kind:row.kind, plane:row.plane,
                box:box, point:point, u:row.u, v:row.v,
                scene:fit.score, geometry:geometry,
                sigScore:sim, verified:verified,
                confidence:0.50*fit.score + 0.20*geometry + 0.30*sim,
                holdMs:row.holdMs
            })
        }
    }

    return world
}

; Pure resolver:
; - no clock reads
; - no global reads
; - no mutation
; - no knowledge of previous clicks or course position

ResolveAction(world) {
    marks := []
    obstacles := []

    for candidate in world.candidates {
        if !candidate.verified || candidate.plane != world.plane
            continue

        if candidate.kind = "loot"
            marks.Push(candidate)
        else if candidate.kind = "obstacle"
            obstacles.Push(candidate)
    }

    if marks.Length
        return {
            kind:"loot",
            target:BestCandidate(marks),
            reason:"verified active-plane Mark"
        }

    if obstacles.Length
        return {
            kind:"obstacle",
            target:BestCandidate(obstacles),
            reason:"highest-confidence permitted obstacle"
        }

    ; Fallback resolution is automatic when no verified target exists.
    ; Sending a waypoint requires ground and a matching ground-source rule.
    if world.plane = "ground" && world.groundLegs.Length
        return {
            kind:"GroundFallback",
            target:BestCandidate(world.groundLegs),
            reason:"matched ground navigation leg"
        }

    return {
        kind:"GroundFallback",
        target:0,
        reason:world.plane = "roof"
            ? "roof: no ground navigation is valid here"
            : "no unambiguous ground navigation anchor"
    }
}

BestCandidate(list) {
    best := list[1]
    for candidate in list
        if CandidateBefore(candidate, best)
            best := candidate
    return best
}

CandidateBefore(a, b) {
    if Abs(a.confidence-b.confidence) > 0.000001
        return a.confidence > b.confidence

    cmp := StrCompare(a.id, b.id, true)
    if cmp
        return cmp < 0

    if a.point.x != b.point.x
        return a.point.x < b.point.x

    return a.point.y < b.point.y
}

; ============================================================================
; SCHEDULER AND ACTUATOR
;
; Operational memory only: cancellation, reentrancy, input rate limits and
; bounded retries. None of it selects or advances the player's course position.
; ============================================================================

Tick() {
    global ENGINE, CFG, TICK_FN

    if ENGINE.busy || !ENGINE.running
        return

    ENGINE.busy := true
    epoch := ENGINE.epoch

    try {
        RequireInput(epoch)

        if Now()-ENGINE.runAt > CFG.maxSessionMs
            throw Error("Session time limit reached.")

        initial := EvaluateWorldState()

        if Now()-ENGINE.lastAt < 650
            return

        verified := ScanCandidates(initial, epoch)

        if !ENGINE.running || epoch != ENGINE.epoch
            return

        if !verified.complete {
            Status("Sensor scan incomplete; no click: " verified.reason)
            return
        }

        fused := {
            plane:verified.latest.plane,
            candidates:verified.candidates,
            groundLegs:verified.latest.groundLegs
        }

        action := ResolveAction(fused)

        if !IsObject(action.target) {
            Status("GroundFallback waiting: " action.reason)
            return
        }

        if action.kind != "loot" && HasConflictingAction(action, fused)
            throw Error("Ambiguous matrix rows. Refine source scenes or target boxes.")

        if ENGINE.lastId = action.target.id
            && Now()-ENGINE.lastAt < action.target.holdMs
            return

        ; Avoid ground recovery input during the previous action's settle fence.
        if action.kind = "GroundFallback" && Now()-ENGINE.lastAt < 2500
            return

        ExecuteAction(action, initial, epoch)
    } catch as err {
        if ENGINE.epoch = epoch
            PauseEngine(err.Message)
    } finally {
        ENGINE.busy := false
        if ENGINE.running
            SetTimer(TICK_FN, -CFG.tickMs)
    }
}

ScanCandidates(initial, epoch) {
    global CFG

    plan := ProbePlan(initial.candidates)
    verified := []
    latest := initial
    started := Now()

    if plan.Length > CFG.maxProbes
        return {
            complete:false, latest:latest, candidates:[],
            reason:"too many candidate boxes; refine calibration"
        }

    for probe in plan {
        if Now()-started > CFG.scanBudgetMs
            return {
                complete:false, latest:latest, candidates:[],
                reason:"scan budget exhausted"
            }

        found := false

        ; Thin targets may need alternate interior points.
        ; Every accepted point still requires the calibrated hover signature.
        for uv in [[probe.u,probe.v],[0.35,0.40],[0.65,0.60]] {
            pt := BoxPoint(probe.box, uv[1], uv[2])
            MoveForProbe(pt, epoch)
            latest := EvaluateWorldState()

            if latest.plane != initial.plane
                || !SameBoxes(initial.boxes, latest.boxes)
                return {
                    complete:false, latest:latest, candidates:[],
                    reason:"scene changed during hover scan"
                }

            for candidate in latest.candidates {
                if candidate.verified && SameBox(candidate.box, probe.box) {
                    candidate.point := pt
                    candidate.u := uv[1]
                    candidate.v := uv[2]
                    verified.Push(candidate)
                    found := true

                    if candidate.kind = "loot"
                        return {
                            complete:true, latest:latest,
                            candidates:verified,
                            reason:"verified Mark: immediate resolution"
                        }
                }
            }

            if found
                break
        }
    }

    return {
        complete:true, latest:latest,
        candidates:verified, reason:""
    }
}

ProbePlan(candidates) {
    plan := []

    for candidate in candidates {
        exists := false

        for saved in plan {
            if SameBox(saved.box, candidate.box) {
                exists := true
                if candidate.kind = "loot"
                    saved.kind := "loot"
                break
            }
        }

        if exists
            continue

        at := plan.Length+1

        for i, saved in plan {
            if (candidate.kind = "loot" && saved.kind != "loot")
                || (candidate.kind = saved.kind
                    && CandidateBefore(candidate, saved)) {
                at := i
                break
            }
        }

        plan.InsertAt(at, candidate.Clone())
    }

    return plan
}

HasConflictingAction(action, fused) {
    global CFG

    list := action.kind = "GroundFallback"
        ? fused.groundLegs
        : fused.candidates

    for other in list {
        if other.id = action.target.id
            || (other.HasOwnProp("verified") && !other.verified)
            continue

        if other.kind != action.target.kind
            continue

        distance := Sqrt(
            (other.point.x-action.target.point.x)**2
            + (other.point.y-action.target.point.y)**2
        )

        if distance > 12
            && action.target.confidence-other.confidence < CFG.actionMargin
            return true
    }

    return false
}

ExecuteAction(action, initial, epoch) {
    global ENGINE, CFG

    target := action.target
    MoveForProbe(target.point, epoch)
    fresh := EvaluateWorldState()

    if fresh.plane != target.plane
        || !SameBoxes(initial.boxes, fresh.boxes)
        return

    live := 0

    if action.kind = "GroundFallback" {
        if !SameCandidateSet(initial.candidates, fresh.candidates)
            return

        reconsidered := ResolveAction({
            plane:fresh.plane,
            candidates:[],
            groundLegs:fresh.groundLegs
        })

        if !IsObject(reconsidered.target)
            || reconsidered.target.id != target.id
            || HasConflictingAction(
                reconsidered,
                {groundLegs:fresh.groundLegs,candidates:[]}
            )
            return

        live := reconsidered.target
    } else {
        for candidate in fresh.candidates
            if candidate.id = target.id
                && candidate.verified
                && SameBox(candidate.box, target.box)
                live := candidate

        if !IsObject(live)
            || live.scene+CFG.maxSceneDrift < target.scene
            return
    }

    if !IsObject(live)
        return

    RequireInput(epoch)
    MouseGetPos(&mx, &my)

    if Abs(mx-(CFG.ox+target.point.x)) > 1
        || Abs(my-(CFG.oy+target.point.y)) > 1
        throw Error("Pointer moved during validation; paused.")

    if ENGINE.lastId = target.id && ENGINE.repeats >= CFG.repeatLimit
        throw Error(
            "Unchanged action repeated " CFG.repeatLimit " times: "
            target.id ". Recalibrate or inspect the client."
        )

    Critical("On")
    try {
        RequireInput(epoch)

        if !ENGINE.dryRun
            Click()

        ENGINE.repeats := ENGINE.lastId = target.id
            ? ENGINE.repeats+1
            : 1

        ENGINE.lastId := target.id
        ENGINE.lastAt := Now()
    } finally {
        Critical("Off")
    }

    Status(
        (ENGINE.dryRun ? "DRY RUN " : "CLICK ")
        action.kind " " target.id
        " confidence=" Round(live.confidence,3)
    )
}

MoveForProbe(point, epoch) {
    global CFG

    RequireInput(epoch)
    MouseMove(CFG.ox+point.x, CFG.oy+point.y, 0)

    hoverDeadline := Now()+CFG.hoverMs
    while Now() < hoverDeadline {
        Sleep(20)
        RequireInput(epoch)
    }

    MouseGetPos(&mx, &my)

    if Abs(mx-CFG.ox-point.x) > 1
        || Abs(my-CFG.oy-point.y) > 1
        throw Error("Manual pointer movement detected; paused.")
}

RequireInput(epoch) {
    global ENGINE, CFG

    if !ENGINE.running || ENGINE.epoch != epoch
        throw Error("Input cancelled.")

    if !ENGINE.hwnd || !WinActive("ahk_id " ENGINE.hwnd)
        throw Error("Bound client lost focus; paused.")

    ValidateClient(ENGINE.hwnd)
}

ValidateClient(hwnd) {
    global CFG

    if !WinExist("ahk_id " hwnd)
        || WinGetMinMax("ahk_id " hwnd) = -1
        throw Error("Bound client is unavailable.")

    WinGetClientPos(&sx, &sy, &cw, &ch, "ahk_id " hwnd)

    if cw != CFG.clientW || ch != CFG.clientH
        throw Error("Client size changed. Restore layout or bind again with F6.")

    if CFG.ox < 0 || CFG.oy < 0
        || CFG.ox+765 > cw || CFG.oy+503 > ch
        throw Error("Canvas does not fit the client. Correct its origin using F6.")

    vx := SysGet(76)
    vy := SysGet(77)
    vw := SysGet(78)
    vh := SysGet(79)

    if sx < vx || sy < vy || sx+cw > vx+vw || sy+ch > vy+vh
        throw Error("Keep the complete client on screen.")

    for pt in [[10,10],[510,10],[10,330],[510,330],[641,85],[6,7]] {
        packed := ((sy+CFG.oy+pt[2]) << 32)
            | ((sx+CFG.ox+pt[1]) & 0xFFFFFFFF)

        under := DllCall(
            "user32\WindowFromPoint",
            "Int64", packed,
            "Ptr"
        )
        root := DllCall(
            "user32\GetAncestor",
            "Ptr", under,
            "UInt", 2,
            "Ptr"
        )

        if root != hwnd
            throw Error("A window or menu covers a sensor region; paused.")
    }
}

ToggleRun() {
    global ENGINE, MATRIX, CFG, TICK_FN

    if ENGINE.running {
        PauseEngine("Paused by F8")
        return
    }

    if !ENGINE.hwnd || !MATRIX.Count {
        MsgBox("Bind the client with F6 and teach at least one source rule first.")
        return
    }

    ENGINE.epoch += 1
    ENGINE.running := true
    ENGINE.runAt := Now()
    ENGINE.lastId := ""
    ENGINE.lastAt := 0
    ENGINE.repeats := 0

    Status(
        ENGINE.dryRun
        ? "Running in DRY RUN: hover and log only."
        : "Running with clicks enabled."
    )

    SetTimer(TICK_FN, -CFG.tickMs)
}

PauseEngine(reason) {
    global ENGINE, TICK_FN
    ENGINE.running := false
    ENGINE.epoch += 1
    SetTimer(TICK_FN, 0)
    Status(reason)
}

ToggleDryRun() {
    global ENGINE
    PauseEngine("Paused to change click mode")
    ENGINE.dryRun := !ENGINE.dryRun
    MsgBox(
        ENGINE.dryRun
        ? "DRY RUN enabled: mouse hovers only."
        : "Clicks enabled. F8 starts; F9 pauses."
    )
}

BindClient() {
    global ENGINE, CFG, MATRIX

    PauseEngine("Binding client")
    hwnd := WinExist("A")

    result := InputBox(
        "Fixed Classic game CANVAS origin inside the active client (X,Y).`n"
        "Original client commonly uses 4,26. This is the canvas border, not the world view.`n"
        "Keep camera, pitch, zoom, plugins, and display scaling fixed after teaching.",
        "Bind the active game client",
        "w520 h200",
        CFG.ox "," CFG.oy
    )

    if result.Result != "OK"
        return

    try {
        parts := StrSplit(result.Value, ",")
        if parts.Length != 2
            throw Error("Enter X,Y.")

        ox := Integer(Trim(parts[1]))
        oy := Integer(Trim(parts[2]))

        WinGetClientPos(,, &cw, &ch, "ahk_id " hwnd)

        if ox < 0 || oy < 0 || ox+765 > cw || oy+503 > ch
            throw Error("765x503 canvas does not fit this client.")

        changed := ox != CFG.ox || oy != CFG.oy
            || cw != CFG.clientW || ch != CFG.clientH

        if changed && MATRIX.Count
            throw Error(
                "Layout differs from calibration. Restore it or use a new profile/script folder."
            )

        CFG.ox := ox
        CFG.oy := oy
        CFG.clientW := cw
        CFG.clientH := ch
        ENGINE.hwnd := hwnd

        SaveProfile()
        Status("Bound client. Focus it before teaching or starting.")
    } catch as err {
        MsgBox(err.Message, "Bind failed", "Iconx")
    }
}

Teach(kind) {
    global ENGINE, CFG, MATRIX

    PauseEngine("Capturing calibration")

    try {
        if !ENGINE.hwnd || !WinActive("ahk_id " ENGINE.hwnd)
            throw Error("Focus the bound client first. F6 binds it.")

        ValidateClient(ENGINE.hwnd)

        ; Capture before the dialog changes focus and hover text.
        sample := WithClientFrame(
            ENGINE.hwnd,
            frame => CaptureTeachingSample(frame, kind)
        )

        instructions := kind = "groundfallback"
            ? "Standing on GROUND, point inside the minimap toward the course start."
            : kind = "loot"
                ? "Hover a reachable Mark of grace on your active plane."
                : "Hover the FORWARD obstacle from this source location."

        result := InputBox(
            instructions
            "`nCaptured before this dialog. Enter a unique rule-id,plane."
            "`nPlane must be ground or roof. IDs describe places; there is no course order."
            "`nUse another ID to add a source pose; reuse an ID to replace it.",
            "Teach " kind,
            "w550 h235",
            kind = "groundfallback" ? "home-leg,ground" : "source-target,roof"
        )

        if result.Result != "OK"
            return

        fields := StrSplit(result.Value, ",")

        if fields.Length != 2
            || !RegExMatch(Trim(fields[1]), "^[A-Za-z][A-Za-z0-9_-]{0,63}$")
            throw Error(
                "Use a letter-led ID (letters, numbers, _ or -), then ,ground or ,roof."
            )

        id := Trim(fields[1])
        plane := StrLower(Trim(fields[2]))

        if plane != "ground" && plane != "roof"
            throw Error("Plane must be ground or roof.")

        if kind = "groundfallback" && plane != "ground"
            throw Error("GroundFallback rows must be taught on the ground.")

        sample.id := id
        sample.kind := kind
        sample.plane := plane
        sample.holdMs := kind = "obstacle"
            ? 12000
            : kind = "loot" ? 5000 : 4000

        MATRIX[id] := sample
        SaveProfile()
        Status("Saved unordered rule: " id " (" kind ", " plane ")")
    } catch as err {
        MsgBox(err.Message, "Calibration failed", "Iconx")
    }
}

CaptureTeachingSample(frame, kind) {
    global CFG

    MouseGetPos(&mx, &my)
    x := mx-CFG.ox
    y := my-CFG.oy

    row := {
        anchor:ReadSceneAnchor(frame),
        black:BlackRatio(frame),
        signature:EmptySignature(),
        box:{x1:0,y1:0,x2:0,y2:0,color:""},
        point:{x:x,y:y},
        u:0.5,v:0.5
    }

    if row.anchor.mini.Length < 25 || row.anchor.world.Length < 30
        throw Error("Not enough visible landmarks to teach a discriminating scene.")

    if kind = "groundfallback" {
        if (x-CFG.mini.x)**2 + (y-CFG.mini.y)**2
            > (CFG.mini.r*0.80)**2
            throw Error("Point within the inner minimap at a walkable waypoint toward the start.")

        if (x-CFG.mini.x)**2 + (y-CFG.mini.y)**2 < 64
            throw Error("Waypoint is too close to the player marker.")

        return row
    }

    boxes := FindHighlights(frame)
    bi := HoveredBox(boxes,x,y)

    if !bi
        throw Error("Pointer is not inside a recognized green/red clickbox.")

    row.box := boxes[bi]
    row.signature := SigFromFrame(frame)

    if row.signature.kind != kind
        throw Error(
            kind = "loot"
            ? "Expected an orange Mark hover label over a red tile."
            : "Expected a cyan obstacle name. Let the hover label settle first."
        )

    if kind = "loot" && row.box.color != "red"
        throw Error("Mark calibration needs its red highlighted tile.")

    row.u := Clamp(
        (x-row.box.x1)/Max(1,row.box.x2-row.box.x1),
        0.12,0.88
    )
    row.v := Clamp(
        (y-row.box.y1)/Max(1,row.box.y2-row.box.y1),
        0.12,0.88
    )
    row.point := {x:x,y:y}
    return row
}

Inspect() {
    global ENGINE

    PauseEngine("Inspecting current sensors")

    try {
        if !ENGINE.hwnd || !WinActive("ahk_id " ENGINE.hwnd)
            throw Error("Focus the bound client first.")

        ValidateClient(ENGINE.hwnd)
        world := EvaluateWorldState()
        action := ResolveAction(world)

        MsgBox(
            "Plane: " world.plane
            " (raw black heuristic: " world.rawPlane ")"
            "`nBlack fraction: " Round(world.black,3)
            "`nBest source: " Round(world.sourceScore,3)
            "`nBoxes: " world.boxes.Length
            "`nMatrix candidates: " world.candidates.Length
            "`nCurrent hover: " world.signature.kind
            "`nResolver: " action.kind " / " action.reason,
            "Current-frame sensors"
        )
    } catch as err {
        MsgBox(err.Message)
    }
}

; ============================================================================
; VISUAL SENSORS
; Coordinates in returned values are canvas-relative.
; ============================================================================

IsGreen(p) => ((p>>8)&255) >= 160
    && ((p>>16)&255) <= 100
    && (p&255) <= 100
    && ((p>>8)&255)-Max((p>>16)&255,p&255) >= 90

IsRed(p) => ((p>>16)&255) >= 110
    && ((p>>8)&255) <= 80
    && (p&255) <= 80
    && ((p>>16)&255)-Max((p>>8)&255,p&255) >= 70

Dark(p, level:=24) => Max(
    (p>>16)&255,
    (p>>8)&255,
    p&255
) <= level

ColorNear(a,b,tolerance) => Max(
    Abs(((a>>16)&255)-((b>>16)&255)),
    Abs(((a>>8)&255)-((b>>8)&255)),
    Abs((a&255)-(b&255))
) <= tolerance

FindHighlights(frame) {
    global CFG

    green := Map()
    red := Map()
    cell := 4
    cols := 128

    ; Full resolution preserves one-pixel tile outlines.
    Loop CFG.world.h {
        y := CFG.world.y+A_Index-1
        Loop 512 {
            x := A_Index+3

            ; Exclude XP overlay.
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
        c := cells[key]
        c.n += 1
        c.x1 := Min(c.x1,x)
        c.y1 := Min(c.y1,y)
        c.x2 := Max(c.x2,x)
        c.y2 := Max(c.y2,y)
    } else
        cells[key] := {n:1,x1:x,y1:y,x2:x,y2:y}
}

ConnectedBoxes(cells,cols,color) {
    boxes := []
    seen := Map()

    for key, start in cells {
        if seen.Has(key)
            continue

        seen[key] := true
        queue := [key]
        qi := 1
        box := start.Clone()
        box.n := 0
        box.color := color

        while qi <= queue.Length {
            current := queue[qi]
            qi += 1
            c := cells[current]

            box.n += c.n
            box.x1 := Min(box.x1,c.x1)
            box.x2 := Max(box.x2,c.x2)
            box.y1 := Min(box.y1,c.y1)
            box.y2 := Max(box.y2,c.y2)

            rr := current//cols
            cc := Mod(current,cols)

            for dy in [-1,0,1] {
                for dx in [-1,0,1] {
                    if cc+dx < 0 || cc+dx >= cols || rr+dy < 0
                        continue

                    neighbor := (rr+dy)*cols+cc+dx

                    if cells.Has(neighbor) && !seen.Has(neighbor) {
                        seen[neighbor] := true
                        queue.Push(neighbor)
                    }
                }
            }
        }

        if box.n >= 8
            && box.x2-box.x1 >= 8
            && box.y2-box.y1 >= 8
            boxes.Push(box)
    }

    return boxes
}

HoveredBox(boxes,x,y) {
    best := 0
    area := 1.0e20

    for i, box in boxes {
        if x >= box.x1 && x <= box.x2
            && y >= box.y1 && y <= box.y2 {
            size := (box.x2-box.x1+1)*(box.y2-box.y1+1)
            if size < area
                best := i, area := size
        }
    }

    return best
}

BoxPoint(box,u,v) {
    mx := Min(3,(box.x2-box.x1)/4)
    my := Min(3,(box.y2-box.y1)/4)

    return {
        x:Round(Clamp(
            box.x1+u*(box.x2-box.x1),
            box.x1+mx,box.x2-mx
        )),
        y:Round(Clamp(
            box.y1+v*(box.y2-box.y1),
            box.y1+my,box.y2-my
        ))
    }
}

GeometryScore(taught,live) {
    global CFG

    distance := Sqrt(
        ((taught.x1+taught.x2-live.x1-live.x2)/2)**2
        + ((taught.y1+taught.y2-live.y1-live.y2)/2)**2
    )

    if distance > CFG.centerTolerance
        return 0.0

    wr := Min(taught.x2-taught.x1+1,live.x2-live.x1+1)
        / Max(taught.x2-taught.x1+1,live.x2-live.x1+1)

    hr := Min(taught.y2-taught.y1+1,live.y2-live.y1+1)
        / Max(taught.y2-taught.y1+1,live.y2-live.y1+1)

    return (1-distance/(CFG.centerTolerance*2))*Sqrt(wr*hr)
}

SameBox(a,b) => a.color = b.color
    && Max(
        Abs(a.x1-b.x1),
        Abs(a.y1-b.y1),
        Abs(a.x2-b.x2),
        Abs(a.y2-b.y2)
    ) <= 3

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

EmptySignature() => {
    kind:"none", name:Map(), white:Map(),
    nameX:-1,nameW:0,nameN:0
}

SigFromFrame(frame) {
    global CFG

    cyan := Map()
    orange := Map()
    white := Map()
    cn := 0
    on := 0
    cx1 := 999
    cx2 := -1
    ox1 := 999
    ox2 := -1

    Loop CFG.hover.h-2 {
        y := A_Index-1

        Loop CFG.hover.w-3 {
            x := A_Index
            p := CanvasPixel(frame,CFG.hover.x+x,CFG.hover.y+y)
            r := (p>>16)&255
            g := (p>>8)&255
            b := p&255

            shadow := CanvasPixel(
                frame,
                CFG.hover.x+x+1,
                CFG.hover.y+y+1
            )

            if !Dark(shadow,70)
                continue

            if r <= 120 && g >= 150 && b >= 150 && Abs(g-b) <= 60 {
                AddProfile(cyan,x)
                cn += 1
                cx1 := Min(cx1,x)
                cx2 := Max(cx2,x)
            } else if r >= 220 && g >= 100 && g <= 180
                && b <= 100 && r-g >= 60 {
                AddProfile(orange,x)
                on += 1
                ox1 := Min(ox1,x)
                ox2 := Max(ox2,x)
            } else if Min(r,g,b) >= 150 && Max(r,g,b)-Min(r,g,b) <= 40
                AddProfile(white,x)
        }
    }

    if cn >= 6
        return {
            kind:"obstacle",name:cyan,white:white,
            nameX:cx1,nameW:cx2-cx1+1,nameN:cn
        }

    if on >= 6 && cn < 4
        return {
            kind:"loot",name:orange,white:white,
            nameX:ox1,nameW:ox2-ox1+1,nameN:on
        }

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
    if a.kind != b.kind
        || a.kind = "none"
        || Abs(a.nameW-b.nameW) > 4
        || Abs(a.nameX-b.nameX) > 4
        return 0.0

    best := 0.0

    Loop 9 {
        shift := A_Index-5
        score := 0.80*ProfileCos(a.name,b.name,shift)
            + 0.20*ProfileCos(a.white,b.white,shift)
        best := Max(best,score)
    }

    return best
}

BlackRatio(frame) {
    global CFG

    count := 0
    black := 0

    Loop 35 {
        dy := (A_Index-18)*3

        Loop 35 {
            dx := (A_Index-18)*3

            if dx*dx+dy*dy > (CFG.mini.r*0.82)**2
                || dx*dx+dy*dy < 100
                continue

            count += 1

            if Dark(
                CanvasPixel(frame,CFG.mini.x+dx,CFG.mini.y+dy),
                CFG.blackLevel
            )
                black += 1
        }
    }

    return count ? black/count : 0.0
}

ReadSceneAnchor(frame) {
    global CFG

    mini := []
    world := []

    Loop 15 {
        dy := (A_Index-8)*7

        Loop 15 {
            dx := (A_Index-8)*7

            if dx*dx+dy*dy > 2500 || dx*dx+dy*dy < 225
                continue

            p := CanvasPixel(frame,CFG.mini.x+dx,CFG.mini.y+dy)

            if !Dark(p,32)
                && !IsRed(p)
                && !IsGreen(p)
                && !BrightDot(p)
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

BrightDot(p) => Min(
    (p>>16)&255,
    (p>>8)&255,
    p&255
) >= 190

SceneFit(frame,row) {
    global CFG

    hits := 0
    for point in row.anchor.world
        if ColorNear(
            CanvasPixel(frame,point[1],point[2]),
            point[3],
            CFG.colorTolerance
        )
            hits += 1

    worldScore := hits/Max(1,row.anchor.world.Length)

    if worldScore < CFG.minScene
        return {score:0.0, mini:0.0, world:worldScore}

    bestMini := 0.0

    for dy in [-6,-3,0,3,6] {
        for dx in [-6,-3,0,3,6] {
            hits := 0

            for point in row.anchor.mini
                if ColorNear(
                    CanvasPixel(
                        frame,
                        CFG.mini.x+point[1]+dx,
                        CFG.mini.y+point[2]+dy
                    ),
                    point[3],
                    CFG.colorTolerance
                )
                    hits += 1

            bestMini := Max(
                bestMini,
                hits/Max(1,row.anchor.mini.Length)
            )
        }
    }

    return {
        score:Min(bestMini,worldScore),
        mini:bestMini,
        world:worldScore
    }
}

; ============================================================================
; NATIVE CAPTURE OWNERSHIP
;
; GDI+ stays loaded for the engine lifetime.
; The locked pixel view is valid only during callback(frame).
; No external GDI+ library is needed.
; ============================================================================

Gdip_Startup() {
    input := Buffer(A_PtrSize = 8 ? 24 : 16,0)
    token := 0
    NumPut("UInt",1,input)

    CheckGdip(
        DllCall(
            "gdiplus\GdiplusStartup",
            "UPtr*",&token,
            "Ptr",input.Ptr,
            "Ptr",0
        ),
        "GdiplusStartup"
    )

    return token
}

Gdip_DisposeImage(image) {
    return DllCall(
        "gdiplus\GdipDisposeImage",
        "Ptr",image,
        "UInt"
    )
}

CheckGdip(status,operation) {
    if status
        throw Error(operation " failed (GDI+ status " status ").")
}

WithClientFrame(hwnd,callback) {
    screenDC := 0
    memoryDC := 0
    bitmap := 0
    previous := 0
    image := 0
    locked := false
    bitmapData := 0
    frame := 0

    try {
        WinGetClientPos(&sx,&sy,&width,&height,"ahk_id " hwnd)

        if width < 1 || height < 1 || width*height > 16000000
            throw Error("Invalid capture dimensions.")

        screenDC := DllCall("user32\GetDC","Ptr",0,"Ptr")
        if !screenDC
            throw Error("GetDC failed.")

        memoryDC := DllCall(
            "gdi32\CreateCompatibleDC",
            "Ptr",screenDC,
            "Ptr"
        )
        if !memoryDC
            throw Error("CreateCompatibleDC failed.")

        bitmap := DllCall(
            "gdi32\CreateCompatibleBitmap",
            "Ptr",screenDC,
            "Int",width,
            "Int",height,
            "Ptr"
        )
        if !bitmap
            throw Error("CreateCompatibleBitmap failed.")

        previous := DllCall(
            "gdi32\SelectObject",
            "Ptr",memoryDC,
            "Ptr",bitmap,
            "Ptr"
        )
        if !previous || previous = -1
            throw Error("SelectObject failed.")

        if !DllCall(
            "gdi32\BitBlt",
            "Ptr",memoryDC,
            "Int",0,"Int",0,
            "Int",width,"Int",height,
            "Ptr",screenDC,
            "Int",sx,"Int",sy,
            "UInt",0x40CC0020
        )
            throw Error("BitBlt failed.")

        DllCall(
            "gdi32\SelectObject",
            "Ptr",memoryDC,
            "Ptr",previous,
            "Ptr"
        )
        previous := 0

        CheckGdip(
            DllCall(
                "gdiplus\GdipCreateBitmapFromHBITMAP",
                "Ptr",bitmap,
                "Ptr",0,
                "Ptr*",&image
            ),
            "CreateBitmapFromHBITMAP"
        )

        rect := Buffer(16,0)
        NumPut("Int",0,"Int",0,"Int",width,"Int",height,rect)

        bitmapData := Buffer(A_PtrSize = 8 ? 32 : 24,0)

        CheckGdip(
            DllCall(
                "gdiplus\GdipBitmapLockBits",
                "Ptr",image,
                "Ptr",rect.Ptr,
                "UInt",1,
                "Int",0x26200A,
                "Ptr",bitmapData.Ptr
            ),
            "LockBits"
        )

        locked := true

        frame := {
            ptr:NumGet(bitmapData,16,"Ptr"),
            stride:NumGet(bitmapData,8,"Int"),
            w:width,
            h:height
        }

        if !frame.ptr || Abs(frame.stride) < width*4
            throw Error("Invalid locked pixel buffer.")

        return callback.Call(frame)
    } finally {
        if IsObject(frame)
            frame.ptr := 0

        if locked
            DllCall(
                "gdiplus\GdipBitmapUnlockBits",
                "Ptr",image,
                "Ptr",bitmapData.Ptr
            )

        if image
            Gdip_DisposeImage(image)

        if previous && previous != -1 && memoryDC
            DllCall(
                "gdi32\SelectObject",
                "Ptr",memoryDC,
                "Ptr",previous,
                "Ptr"
            )

        if bitmap
            DllCall("gdi32\DeleteObject","Ptr",bitmap)

        if memoryDC
            DllCall("gdi32\DeleteDC","Ptr",memoryDC)

        if screenDC
            DllCall("user32\ReleaseDC","Ptr",0,"Ptr",screenDC)

        bitmapData := 0
        frame := 0
    }
}

CanvasPixel(frame,x,y) {
    global CFG

    x += CFG.ox
    y += CFG.oy

    if x < 0 || y < 0
        || x >= frame.w || y >= frame.h || !frame.ptr
        throw Error("Pixel read outside the captured frame.")

    return NumGet(
        frame.ptr+y*frame.stride+x*4,
        "UInt"
    ) & 0xFFFFFF
}

; ============================================================================
; CALIBRATION STORAGE
; Versioned text, bounded reads, staged replacement and backup.
; ============================================================================

SaveProfile() {
    global CFG, MATRIX

    path := CFG.profile
    staged := path ".tmp"

    text := "[Engine]`nVersion=1`nOrigin="
        . CFG.ox "," CFG.oy
        . "`nClient=" CFG.clientW "," CFG.clientH "`n"

    for id, row in MATRIX {
        text .= "`n[Rule." id "]`nKind=" row.kind
            . "`nPlane=" row.plane
            . "`nBlack=" row.black
            . "`nHoldMs=" row.holdMs
            . "`nPoint=" row.point.x "," row.point.y
            . "`nUV=" row.u "," row.v
            . "`nBox=" row.box.x1 "," row.box.y1 ","
                row.box.x2 "," row.box.y2 "," row.box.color
            . "`nMini=" EncodePoints(row.anchor.mini)
            . "`nWorld=" EncodePoints(row.anchor.world)
            . "`nSignature=" EncodeSignature(row.signature) "`n"
    }

    try {
        handle := FileOpen(staged,"w","UTF-16")
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

LoadProfile() {
    global CFG, MATRIX

    if !FileExist(CFG.profile)
        return

    if FileGetSize(CFG.profile) > 2000000
        throw Error("Calibration file exceeds 2 MB.")

    if IniRead(CFG.profile,"Engine","Version","") != "1"
        throw Error(
            "Unsupported calibration version. Legacy sequential profiles are not loaded."
        )

    origin := ReadNumbers(
        IniRead(CFG.profile,"Engine","Origin"),
        2
    )
    client := ReadNumbers(
        IniRead(CFG.profile,"Engine","Client"),
        2
    )

    CFG.ox := Integer(origin[1])
    CFG.oy := Integer(origin[2])
    CFG.clientW := Integer(client[1])
    CFG.clientH := Integer(client[2])

    loaded := Map()

    for section in StrSplit(IniRead(CFG.profile),"`n") {
        if SubStr(section,1,5) != "Rule."
            continue

        id := SubStr(section,6)

        if !RegExMatch(id,"^[A-Za-z][A-Za-z0-9_-]{0,63}$")
            || loaded.Count >= 200
            throw Error("Invalid rule ID or too many rules.")

        kind := IniRead(CFG.profile,section,"Kind")
        plane := IniRead(CFG.profile,section,"Plane")

        if !InStr("|obstacle|loot|groundfallback|","|" kind "|")
            || !InStr("|ground|roof|","|" plane "|")
            throw Error("Invalid rule kind or plane: " id)

        if kind = "groundfallback" && plane != "ground"
            throw Error("Invalid rule plane: " id)

        point := ReadNumbers(
            IniRead(CFG.profile,section,"Point"),
            2
        )
        uv := ReadNumbers(
            IniRead(CFG.profile,section,"UV"),
            2
        )
        box := StrSplit(
            IniRead(CFG.profile,section,"Box"),
            ","
        )

        if box.Length != 5
            throw Error("Invalid box: " id)

        row := {
            id:id,kind:kind,plane:plane,
            point:{x:point[1],y:point[2]},
            u:uv[1],v:uv[2],
            holdMs:Integer(IniRead(CFG.profile,section,"HoldMs")),
            black:Float(IniRead(CFG.profile,section,"Black")),
            box:{
                x1:Integer(box[1]),y1:Integer(box[2]),
                x2:Integer(box[3]),y2:Integer(box[4]),
                color:box[5]
            },
            anchor:{
                mini:DecodePoints(IniRead(CFG.profile,section,"Mini")),
                world:DecodePoints(IniRead(CFG.profile,section,"World"))
            },
            signature:DecodeSignature(
                IniRead(CFG.profile,section,"Signature")
            )
        }

        ValidateRule(row)
        loaded[id] := row
    }

    MATRIX := loaded
}

ValidateRule(row) {
    if row.holdMs < 650 || row.holdMs > 30000
        || row.anchor.mini.Length < 25
        || row.anchor.world.Length < 30
        throw Error("Invalid timing/landmarks: " row.id)

    if row.u < 0.1 || row.u > 0.9 || row.v < 0.1 || row.v > 0.9
        throw Error("Invalid interior hover point: " row.id)

    if row.kind != "groundfallback" && row.signature.kind != row.kind
        throw Error("Signature kind does not match rule: " row.id)

    if row.point.x < 0 || row.point.x > 764
        || row.point.y < 0 || row.point.y > 502
        throw Error("Invalid canvas coordinate: " row.id)

    if row.kind = "groundfallback" {
        global CFG

        radius2 := (row.point.x-CFG.mini.x)**2
            + (row.point.y-CFG.mini.y)**2

        if radius2 < 64 || radius2 > (CFG.mini.r*0.80)**2
            throw Error(
                "Ground waypoint lies outside the safe minimap region: " row.id
            )
    } else if row.box.x1 < 4 || row.box.y1 < 4
        || row.box.x2 > 515 || row.box.y2 > 337
        || row.box.x2 <= row.box.x1 || row.box.y2 <= row.box.y1
        throw Error("Invalid world clickbox: " row.id)
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

        if Abs(p[1]) > 765 || Abs(p[2]) > 503
            || p[3] < 0 || p[3] > 0xFFFFFF || out.Length >= 300
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

        if pair[1] < 0 || pair[1] > 358
            || pair[2] < 0 || pair[2] > 100 || profile.Count >= 359
            throw Error("Invalid signature profile.")

        profile[Integer(pair[1])] := Integer(pair[2])
    }

    return profile
}

EncodeSignature(sig) => sig.kind "|"
    sig.nameX "|" sig.nameW "|" sig.nameN "|"
    EncodeProfile(sig.name) "|" EncodeProfile(sig.white)

DecodeSignature(text) {
    fields := StrSplit(text,"|")

    if fields.Length != 6
        || !InStr("|none|obstacle|loot|","|" fields[1] "|")
        throw Error("Invalid signature.")

    return {
        kind:fields[1],
        nameX:Integer(fields[2]),
        nameW:Integer(fields[3]),
        nameN:Integer(fields[4]),
        name:DecodeProfile(fields[5]),
        white:DecodeProfile(fields[6])
    }
}

ReadNumbers(text,count) {
    fields := StrSplit(text,",")
    values := []

    if fields.Length != count
        throw Error("Invalid numeric field count.")

    for field in fields {
        if !RegExMatch(field,"^-?\d+(\.\d+)?$")
            throw Error("Invalid numeric data.")
        values.Push(Number(field))
    }

    return values
}

Status(message) {
    global ENGINE, CFG

    A_IconTip := SubStr("Stateless Agility: " message,1,127)

    if message = ENGINE.lastStatus && Now()-ENGINE.lastLogAt < 5000
        return

    ENGINE.lastStatus := message
    ENGINE.lastLogAt := Now()

    try {
        if FileExist(CFG.log) && FileGetSize(CFG.log) > CFG.logBytes
            FileMove(CFG.log,CFG.log ".1",1)

        FileAppend(
            FormatTime(,"yyyy-MM-dd HH:mm:ss") " " message "`n",
            CFG.log,
            "UTF-8"
        )
    } catch {
        OutputDebug(message)
    }
}

Shutdown(*) {
    global ENGINE, TICK_FN

    ENGINE.running := false
    ENGINE.epoch += 1
    SetTimer(TICK_FN,0)

    if ENGINE.token {
        DllCall(
            "gdiplus\GdiplusShutdown",
            "UPtr",ENGINE.token
        )
        ENGINE.token := 0
    }

    if ENGINE.gdipModule {
        DllCall(
            "kernel32\FreeLibrary",
            "Ptr",ENGINE.gdipModule
        )
        ENGINE.gdipModule := 0
    }
}

Clamp(value,lo,hi) => Max(lo,Min(hi,value))
Now() => DllCall("kernel32\GetTickCount64","UInt64")

; ============================================================================
; SELF-TESTS
; --selftest never moves the pointer or clicks the client.
; ============================================================================

RunSelfTests() {
    global TEST_ASSERTIONS, TEST_BORROWED_FRAME

    TEST_ASSERTIONS := 0
    TEST_BORROWED_FRAME := 0

    try {
        TestResolver()
        TestSignatures()
        TestPersistence()
        TestGeometry()
        WithTestFrame(TestSyntheticSensors)
        TestNativeFrameScope()

        FileAppend(
            "PASS: " TEST_ASSERTIONS
            " assertions (resolver, signatures, segmentation, fusion, native resource scopes).`n",
            "*"
        )
        return 0
    } catch as testError {
        FileAppend(
            "FAIL: " testError.Message "`n" testError.Stack "`n",
            "*"
        )
        return 1
    }
}

TestAssert(condition, message) {
    global TEST_ASSERTIONS

    if !condition
        throw Error("Self-test: " message)

    TEST_ASSERTIONS += 1
}

TestThrows(callback, message) {
    caught := false

    try callback.Call()
    catch {
        caught := true
    }

    TestAssert(caught, message)
}

TestCandidate(
    id,
    kind:="obstacle",
    plane:="roof",
    confidence:=0.95,
    x:=100,
    y:=100
) {
    return {
        id:id,kind:kind,plane:plane,
        confidence:confidence,verified:true,
        point:{x:x,y:y},
        box:{
            x1:x-10,y1:y-10,x2:x+10,y2:y+10,
            color:kind="loot"?"red":"green"
        },
        u:0.5,v:0.5,
        scene:1.0,geometry:1.0,sigScore:1.0,holdMs:1000
    }
}

TestResolver() {
    global ENGINE

    obstacle := TestCandidate("forward","obstacle","roof",0.999)
    mark := TestCandidate("grace","loot","roof",0.55)

    action := ResolveAction({
        plane:"roof",candidates:[obstacle,mark],groundLegs:[]
    })
    TestAssert(
        action.kind="loot" && action.target.id="grace",
        "active-plane loot beats higher-confidence obstacle"
    )

    lowerMark := TestCandidate("other-grace","loot","roof",0.51)
    TestAssert(
        ResolveAction({
            plane:"roof",
            candidates:[lowerMark,obstacle,mark],
            groundLegs:[]
        }).target.id="grace",
        "highest-confidence active mark wins"
    )

    foreign := TestCandidate("foreign","loot","ground",1.0)
    unverified := TestCandidate("unverified","loot","roof",1.0)
    unverified.verified := false

    action := ResolveAction({
        plane:"roof",
        candidates:[foreign,unverified,obstacle],
        groundLegs:[]
    })
    TestAssert(
        action.kind="obstacle" && action.target.id="forward",
        "wrong-plane and unverified marks are rejected"
    )

    low := TestCandidate("low","obstacle","roof",0.8)
    for list in [[low,obstacle],[obstacle,low]]
        TestAssert(
            ResolveAction({
                plane:"roof",candidates:list,groundLegs:[]
            }).target.id="forward",
            "obstacle confidence is independent of list order"
        )

    alpha := TestCandidate("alpha")
    zulu := TestCandidate("zulu")

    for list in [[zulu,alpha],[alpha,zulu]]
        TestAssert(
            ResolveAction({
                plane:"roof",candidates:list,groundLegs:[]
            }).target.id="alpha",
            "equal confidence uses stable lexical tie break"
        )

    left := TestCandidate("same","obstacle","roof",0.95,80,100)
    right := TestCandidate("same","obstacle","roof",0.95,90,100)
    TestAssert(
        BestCandidate([right,left]).point.x=80,
        "equal IDs use x-coordinate tie break"
    )

    upper := TestCandidate("same","obstacle","roof",0.95,80,90)
    TestAssert(
        BestCandidate([left,upper]).point.y=90,
        "equal IDs and x use y-coordinate tie break"
    )

    leg := TestCandidate("home","groundfallback","ground",0.96,650,95)
    action := ResolveAction({
        plane:"ground",candidates:[],groundLegs:[leg]
    })
    TestAssert(
        action.kind="GroundFallback" && action.target.id="home",
        "ground with a matched leg resolves navigation"
    )

    for plane in ["roof","unknown"] {
        action := ResolveAction({
            plane:plane,candidates:[],groundLegs:[leg]
        })
        TestAssert(
            action.kind="GroundFallback" && !IsObject(action.target),
            "non-ground plane never navigates"
        )
    }

    action := ResolveAction({
        plane:"ground",candidates:[],groundLegs:[]
    })
    TestAssert(
        action.kind="GroundFallback" && !IsObject(action.target),
        "missing ground anchor waits without a coordinate"
    )

    entrance := TestCandidate("entrance","obstacle","ground",0.91)
    TestAssert(
        ResolveAction({
            plane:"ground",candidates:[entrance],groundLegs:[leg]
        }).kind="obstacle",
        "valid obstacle suppresses ground recovery"
    )

    savedEngine := ENGINE.Clone()

    try {
        ENGINE.lastId := "unrelated-last-click"
        ENGINE.repeats := 999
        ENGINE.epoch := 12345
        ENGINE.running := false
        ENGINE.lastAt := 999999999

        TestAssert(
            ResolveAction({
                plane:"roof",candidates:[obstacle,mark],groundLegs:[]
            }).target.id="grace",
            "operational memory cannot select course position"
        )

        ENGINE.lastId := ""
        ENGINE.repeats := 0
        ENGINE.lastAt := 0

        TestAssert(
            ResolveAction({
                plane:"roof",candidates:[obstacle,mark],groundLegs:[]
            }).target.id="grace",
            "restart in the same visible world selects the same action"
        )
    } finally {
        ENGINE := savedEngine
    }

    duplicate := obstacle.Clone()
    plan := ProbePlan([obstacle,duplicate,mark])

    TestAssert(
        plan.Length=2 && plan[1].kind="loot",
        "probe plan deduplicates clickboxes and checks potential loot first"
    )
}

TestSignatures() {
    sig := {
        kind:"obstacle",nameX:20,nameW:30,nameN:12,
        name:Map(20,3,23,7,31,5,49,2),
        white:Map(2,3,5,2,11,4)
    }

    decoded := DecodeSignature(EncodeSignature(sig))

    TestAssert(
        Abs(SignatureScore(sig,decoded)-1.0)<0.000001,
        "signature serialization preserves its score"
    )
    TestAssert(
        decoded.name.Count=sig.name.Count && decoded.nameN=sig.nameN,
        "signature metadata and bins round trip"
    )

    shifted := {
        kind:sig.kind,
        nameX:sig.nameX+2,nameW:sig.nameW,nameN:sig.nameN,
        name:Map(),white:Map()
    }

    for key,value in sig.name
        shifted.name[key+2] := value
    for key,value in sig.white
        shifted.white[key+2] := value

    TestAssert(
        Abs(SignatureScore(sig,shifted)-1.0)<0.000001,
        "small text shifts preserve a full match"
    )

    shifted.nameX += 5

    TestAssert(
        SignatureScore(sig,shifted)=0,
        "large text displacement rejects signature"
    )

    wrong := decoded.Clone()
    wrong.kind := "loot"

    TestAssert(
        SignatureScore(sig,wrong)=0,
        "obstacle and loot signatures never match"
    )
    TestAssert(
        SignatureScore(sig,EmptySignature())=0,
        "empty signature never verifies a target"
    )
    TestAssert(
        ProfileCos(Map(),Map(),0)=0,
        "zero-norm profiles have a defined score"
    )

    points := [[-12,4,0x123456],[24,-7,0xABCDEF]]
    roundTrip := DecodePoints(EncodePoints(points))

    TestAssert(
        roundTrip.Length=2
            && roundTrip[2][2]=-7
            && roundTrip[2][3]=0xABCDEF,
        "scene landmarks round trip"
    )

    TestThrows(
        () => DecodeSignature("bogus|0|0|0||"),
        "invalid signature kind rejected"
    )
    TestThrows(
        () => DecodeProfile("4,101"),
        "oversized signature bin rejected"
    )
    TestThrows(
        () => DecodePoints("1,2,16777216"),
        "out-of-range landmark color rejected"
    )
    TestThrows(
        () => ReadNumbers("1,expression()",2),
        "calibration numeric parser rejects executable text"
    )
}

TestGeometry() {
    box := {x1:20,y1:60,x2:60,y2:100,color:"green"}

    TestAssert(
        Abs(GeometryScore(box,box)-1.0)<0.000001,
        "identical geometry scores one"
    )

    distant := {x1:220,y1:60,x2:260,y2:100,color:"green"}
    TestAssert(
        GeometryScore(box,distant)=0,
        "distant boxes reject geometry"
    )

    point := BoxPoint(box,0,1)
    TestAssert(
        point.x>box.x1 && point.y<box.y2,
        "interior point clamps away from outline"
    )

    inner := {x1:30,y1:70,x2:50,y2:90,color:"red"}

    TestAssert(
        HoveredBox([box,inner],40,80)=2,
        "nested hover uses smallest containing box"
    )
    TestAssert(
        HoveredBox([box],5,5)=0,
        "background hover has no clickbox"
    )
    TestAssert(
        SameBoxes([box,inner],[inner,box]),
        "box-set comparison is unordered"
    )
}

TestPersistence() {
    global CFG, MATRIX

    savedConfig := CFG.Clone()
    savedMatrix := MATRIX
    testDir := A_Temp "\StatelessAgilityTest_"
        . DllCall("kernel32\GetCurrentProcessId","UInt")
        . "_" Now()

    DirCreate(testDir)

    try {
        CFG.profile := testDir "\profile.ini"
        mini := []
        scenery := []

        Loop 30 {
            mini.Push([
                Mod(A_Index,7)*6-21,
                (A_Index//7)*6-21,
                0x606070
            ])
            scenery.Push([
                20+Mod(A_Index,10)*35,
                60+(A_Index//10)*30,
                0x404050
            ])
        }

        row := {
            id:"source-forward",kind:"obstacle",plane:"roof",
            black:0.6,holdMs:12000,
            point:{x:110,y:110},u:0.5,v:0.5,
            box:{x1:90,y1:90,x2:130,y2:130,color:"green"},
            anchor:{mini:mini,world:scenery},
            signature:{
                kind:"obstacle",nameX:20,nameW:30,nameN:12,
                name:Map(20,3,23,7,31,5,49,2),
                white:Map(2,3,5,2,11,4)
            }
        }

        mark := row.Clone()
        mark.id := "ground-grace"
        mark.kind := "loot"
        mark.plane := "ground"
        mark.signature := row.signature.Clone()
        mark.signature.kind := "loot"
        mark.box := row.box.Clone()
        mark.box.color := "red"

        leg := row.Clone()
        leg.id := "home-leg"
        leg.kind := "groundfallback"
        leg.plane := "ground"
        leg.point := {x:650,y:95}
        leg.signature := EmptySignature()

        MATRIX := Map(row.id,row,mark.id,mark,leg.id,leg)

        SaveProfile()
        MATRIX := Map()
        LoadProfile()

        TestAssert(MATRIX.Count=3,"all independent matrix rows persist")

        loaded := MATRIX[row.id]

        TestAssert(
            loaded.kind="obstacle"
                && loaded.plane="roof"
                && loaded.holdMs=12000,
            "rule semantics round trip"
        )
        TestAssert(
            loaded.box.x1=90
                && loaded.point.x=110
                && loaded.anchor.mini.Length=30,
            "box, hover point and scene landmarks persist"
        )
        TestAssert(
            SignatureScore(loaded.signature,row.signature)>0.999999,
            "persisted hover signature preserves verification"
        )
        TestAssert(
            MATRIX[mark.id].plane="ground"
                && MATRIX[mark.id].signature.kind="loot",
            "ground-plane Mark rules are supported"
        )
        TestAssert(
            MATRIX[leg.id].point.y=95
                && MATRIX[leg.id].kind="groundfallback",
            "ground navigation point persists"
        )

        SaveProfile()

        TestAssert(
            FileExist(CFG.profile ".bak")
                && !FileExist(CFG.profile ".tmp"),
            "profile replacement makes a backup and releases staging file"
        )

        invalid := loaded.Clone()
        invalid.point := {x:-1,y:80}

        TestThrows(
            () => ValidateRule(invalid),
            "invalid persisted coordinates are rejected"
        )
    } finally {
        CFG := savedConfig
        MATRIX := savedMatrix
        DirDelete(testDir,true)
    }
}

WithTestFrame(callback) {
    global CFG

    pixels := 0
    frame := 0

    try {
        pixels := Buffer(CFG.clientW*CFG.clientH*4,0)
        frame := {
            ptr:pixels.Ptr,
            stride:CFG.clientW*4,
            w:CFG.clientW,
            h:CFG.clientH
        }
        return callback.Call(frame)
    } finally {
        if IsObject(frame)
            frame.ptr := 0
        frame := 0
        pixels := 0
    }
}

TestSetPixel(frame,x,y,color) {
    global CFG
    NumPut(
        "UInt",color,
        frame.ptr+(y+CFG.oy)*frame.stride+(x+CFG.ox)*4
    )
}

TestOutline(frame,x1,y1,x2,y2,color) {
    Loop x2-x1+1 {
        x := x1+A_Index-1
        TestSetPixel(frame,x,y1,color)
        TestSetPixel(frame,x,y2,color)
    }
    Loop y2-y1+1 {
        y := y1+A_Index-1
        TestSetPixel(frame,x1,y,color)
        TestSetPixel(frame,x2,y,color)
    }
}

TestPaintSignature(frame,color) {
    global CFG

    for i,x in [20,24,29,35,42,50]
        TestSetPixel(
            frame,
            CFG.hover.x+x,
            CFG.hover.y+Mod(i*2,12),
            color
        )

    for i,x in [2,6,10]
        TestSetPixel(
            frame,
            CFG.hover.x+x,
            CFG.hover.y+Mod(i*3,12),
            0xFFFFFF
        )
}

TestSyntheticSensors(frame) {
    global CFG, MATRIX

    TestAssert(
        BlackRatio(frame)=1.0,
        "black minimap yields a roof-like raw sensor"
    )

    TestOutline(frame,20,60,60,100,0x00FF00)
    TestOutline(frame,150,80,170,100,0xFF0000)
    TestSetPixel(frame,500,300,0x00FF00)

    boxes := FindHighlights(frame)

    TestAssert(
        boxes.Length=2,
        "one-pixel colored outlines survive segmentation; isolated noise is discarded"
    )
    TestAssert(
        boxes[1].color="green"
            && boxes[1].x1=20
            && boxes[1].x2=60,
        "green outline retains exact bounds"
    )
    TestAssert(
        boxes[2].color="red"
            && boxes[2].y1=80
            && boxes[2].y2=100,
        "red Mark outline remains separate"
    )

    TestPaintSignature(frame,0x00FFFF)
    obstacleSig := SigFromFrame(frame)

    TestAssert(
        obstacleSig.kind="obstacle" && obstacleSig.nameN=6,
        "cyan hover pixels identify obstacle signature"
    )

    TestPaintSignature(frame,0xFF981F)
    lootSig := SigFromFrame(frame)

    TestAssert(
        lootSig.kind="loot" && lootSig.nameN=6,
        "orange hover pixels identify item signature"
    )
    TestAssert(
        SignatureScore(
            lootSig,
            DecodeSignature(EncodeSignature(lootSig))
        )>0.999999,
        "captured hover signature round trips"
    )

    Loop 137 {
        y := CFG.mini.y-68+A_Index-1
        Loop 137
            TestSetPixel(
                frame,
                CFG.mini.x-68+A_Index-1,
                y,
                0x606070
            )
    }

    TestAssert(
        BlackRatio(frame)=0.0,
        "visible minimap yields a ground-like raw sensor"
    )

    Loop 8 {
        y := 62+(A_Index-1)*34
        Loop 13
            TestSetPixel(
                frame,
                28+(A_Index-1)*37,
                y,
                0x606070
            )
    }

    anchor := ReadSceneAnchor(frame)

    TestAssert(
        anchor.mini.Length>=25 && anchor.world.Length>=30,
        "synthetic source has discriminating landmarks"
    )

    row := {
        id:"source-roof",kind:"obstacle",plane:"roof",
        anchor:anchor,box:boxes[1],
        u:0.5,v:0.5,signature:obstacleSig,holdMs:12000
    }

    TestAssert(
        SceneFit(frame,row).score=1.0,
        "matching minimap and world both authorize source scene"
    )

    savedMatrix := MATRIX

    try {
        MATRIX := Map(row.id,row)
        world := AnalyzeFrame(frame)

        TestAssert(
            world.rawPlane="ground" && world.plane="roof",
            "calibrated source disambiguates roof with ground-like minimap"
        )

        opposing := row.Clone()
        opposing.id := "source-ground"
        opposing.plane := "ground"
        MATRIX[opposing.id] := opposing

        world := AnalyzeFrame(frame)

        TestAssert(
            world.plane="unknown" && world.candidates.Length=0,
            "opposing-plane source tie rejects all targets"
        )
    } finally {
        MATRIX := savedMatrix
    }

    TestThrows(
        () => CanvasPixel(frame,-CFG.ox-1,0),
        "pixel reader rejects out-of-frame coordinates"
    )
}

TestNativeFrameScope() {
    global CFG, TEST_BORROWED_FRAME

    fixture := Gui(
        "-Caption +ToolWindow +AlwaysOnTop",
        "Stateless capture self-test"
    )
    fixture.BackColor := "243648"

    try {
        fixture.Show(
            "NA x40 y40 w" CFG.clientW " h" CFG.clientH
        )
        Sleep(100)

        Loop 6
            WithClientFrame(fixture.Hwnd, frame => frame.w)

        beforeGdi := TestGdiCount()
        beforeBytes := TestPrivateBytes()

        TestAssert(
            WithClientFrame(
                fixture.Hwnd,
                frame => frame.w
            )=CFG.clientW,
            "native client capture returns expected width"
        )

        Loop 24 {
            TestThrows(
                () => WithClientFrame(
                    fixture.Hwnd,
                    TestThrowCapture
                ),
                "capture propagates callback exception"
            )
            TestAssert(
                IsObject(TEST_BORROWED_FRAME)
                    && TEST_BORROWED_FRAME.ptr=0,
                "finally invalidates borrowed pixels after exception"
            )
            TestAssert(
                WithClientFrame(
                    fixture.Hwnd,
                    frame => frame.h
                )=CFG.clientH,
                "capture remains usable after exceptional cleanup"
            )
        }

        afterGdi := TestGdiCount()
        afterBytes := TestPrivateBytes()

        TestAssert(
            afterGdi<=beforeGdi+2,
            "repeated success/failure captures do not accumulate GDI handles"
        )

        if beforeBytes && afterBytes
            TestAssert(
                afterBytes-beforeBytes<16777216,
                "repeated capture exceptions do not retain bitmap-sized native allocations"
            )

        TEST_BORROWED_FRAME := 0
    } finally {
        fixture.Destroy()
    }
}

TestThrowCapture(frame) {
    global TEST_BORROWED_FRAME
    TEST_BORROWED_FRAME := frame
    throw Error("Intentional callback exception")
}

TestGdiCount() => DllCall(
    "user32\GetGuiResources",
    "Ptr",DllCall("kernel32\GetCurrentProcess","Ptr"),
    "UInt",0,
    "UInt"
)

TestPrivateBytes() {
    size := A_PtrSize=8 ? 80 : 44
    counters := Buffer(size,0)
    NumPut("UInt",size,counters)

    if !DllCall(
        "psapi\GetProcessMemoryInfo",
        "Ptr",DllCall("kernel32\GetCurrentProcess","Ptr"),
        "Ptr",counters.Ptr,
        "UInt",size
    )
        return 0

    return NumGet(counters,A_PtrSize=8 ? 72 : 40,"UPtr")
}
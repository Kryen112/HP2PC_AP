// On-screen AP toasts: colourised multi-segment item lines ("X sent Y to Z",
// "X found their Y" with the location on a second line) plus single-colour
// system/lifecycle lines. Spawned per level from APGameInfo.InitGame; registers
// with HPHud's propArray so its RenderHud
// gets called every frame the HUD draws (including during cutscenes — vanilla
// only suppresses propArray rendering when the in-game menu is up).
//
// Why extend HProp: HPHud's propArray is `Array<HProp>` (HPHud.uc:20), so the
// only way to get into the per-frame Canvas render loop is to be an HProp.
// We override RenderHud to draw text instead of the inherited
// `Canvas.DrawActor(self, False, True)` (which would try to render the actor
// as a 3D mesh in HUD space). The actor itself is hidden, non-colliding, and
// has no physics.
//
// Lifetime: per level. NOT bGameRelevant — each level transition destroys
// the toast and the next InitGame (or APLevelSetup.TrySpawnClassroomBlockers
// on save-load) spawns a fresh one. Class-default `LatestInstance` lets
// APGameInfo.ApplyGrant reach the active toast via GetInstance().
//
// Queue: a flat segment pool plus parallel per-toast arrays (see ToastSegs).
// When full, drops the OLDEST toast to make room for a new one. Newer info
// matters more during a resync flood. Entries decay over `TOAST_DURATION` then
// auto-remove.
class APHUDToast extends HProp;

const MAX_QUEUE = 8;
const STRIDE = 10;        // max segments one toast can hold (richest line is 9)
const TOAST_DURATION = 5.0;
const TICK_INTERVAL = 0.1;

// Segment colour codes. The client sends a role letter per segment; the mod
// resolves it to one of these and maps it to an RGB in RoleColor. NEWLINE is a
// layout marker (empty text) that breaks to the next rendered line.
//   0 yellow (system)  1 white (connective/brackets/lifecycle)  2 self slot
//   3 other slot  4 progression  5 useful  6 trap  7 filler  8 location
//   9 newline
const COL_YELLOW = 0;
const COL_WHITE = 1;
const COL_NEWLINE = 9;

struct ToastSeg
{
    var string Text;
    var byte ColorCode;
};

// Flat segment pool: toast i owns segments [i*STRIDE .. i*STRIDE+ToastSegN[i]).
// 80 = MAX_QUEUE * STRIDE (the array dim must be an integer literal in M212).
// transient: per-session UI, never part of the .usa save. All value types with
// no actor refs, so the save graph stays clean even where M212 ignores transient.
var transient ToastSeg ToastSegs[80];
var transient int ToastSegN[8];
var transient float ToastRemaining[8];
var transient int ToastCount;
// HPHud we're currently registered with. `transient` so a saved-state
// deserialized toast doesn't bring back a stale ref that fools the dedupe
// path into thinking we're already in propArray when we aren't. Each new
// instance (freshly spawned OR deserialized) starts with RegisteredHud=None
// and registers via TryRegisterWithHUD on its first Timer tick.
var transient HPHud RegisteredHud;

// Background texture drawn behind each toast line. `HGame.Icons.leftPanel`
// is the same panel CutSceneManager uses for its cutscene border bars and
// FEFolioPage uses for the description-text backdrop — known-good translucent
// panel that reads well on top of arbitrary scene content.
var Texture ToastBackground;
// "Whoosh" played per toast — same sound vanilla plays when a vendor card
// flies out into the world (Characters.uc:698 PlaySound `vendor_spawn_WC`).
var Sound ToastSound;

// Singleton pointer lives ONLY on the class default (`default.LatestInstance`).
// The per-instance copy of this field must always be None — otherwise the save
// graph walks it and trips on a cross-package ref: a freshly-spawned toast in
// (say) Entryhall_hub initializes its instance copy from the class default at
// spawn time, which is the very first toast that ran PreBeginPlay this process
// (e.g. Entry.APHUDToast0 at app launch). Saving Entryhall_hub then aborts with
// "Graph is linked to external private object APHUDToast Entry.APHUDToast0",
// the .usa is never written, and the player's progress silently rolls back on
// the next load. PreBeginPlay clears it for fresh spawns; Timer clears it
// defensively every tick for deserialized toasts (which skip PreBeginPlay).
// `transient` is intentionally omitted — M212 does not honor it, so the explicit
// clear is the load-bearing piece.
var APHUDToast LatestInstance;

static function APHUDToast GetInstance()
{
    if (default.LatestInstance != None && !default.LatestInstance.bDeleteMe)
    {
        return default.LatestInstance;
    }
    return None;
}

event PreBeginPlay()
{
    Super.PreBeginPlay();

    // Critical save-graph hygiene — see the comment above the LatestInstance
    // declaration. Spawn() seeds this instance copy from the class default
    // (which may point at a previous-level / Entry toast), so clear it before
    // any SaveGame can run.
    LatestInstance = None;

    default.LatestInstance = self;
    SetTimer(TICK_INTERVAL, true);

    // Lazy-load the panel texture once. baseWarning/CutSceneManager show this
    // same texture works at runtime for HUD draws.
    if (ToastBackground == None)
    {
        ToastBackground = Texture(DynamicLoadObject("HGame.Icons.leftPanel", class'Texture'));
    }
    if (ToastSound == None)
    {
        ToastSound = Sound(DynamicLoadObject("HPSounds.Magic_sfx.vendor_spawn_WC", class'Sound'));
    }

    Log("[Archipelago] APHUDToast.PreBeginPlay - registered as singleton");
}

event Destroyed()
{
    // Leave the HUD's propArray cleanly. HPHud.RenderHud iterates
    // `propArray[I].RenderHud(Canvas)` with NO None-guard, so a destroyed
    // toast still referenced there is an Accessed-None every frame. Matters
    // when EnsureFreshToast destroys a stale toast while its HUD lives;
    // harmless on normal per-level teardown (the bDeleteMe guard skips a
    // HUD that is dying with the level).
    if (RegisteredHud != None && !RegisteredHud.bDeleteMe)
    {
        RegisteredHud.UnregisterPickupProp(self);
    }
    RegisteredHud = None;
    if (default.LatestInstance == self)
    {
        default.LatestInstance = None;
    }
    Super.Destroyed();
}

// Try to register with the live HPHud. May fail on early ticks before harry
// is fully spawned; Timer retries until success. Idempotent on repeat calls
// against the same HPHud (cheap ref compare). When harry's myHUD points at a
// different HPHud than the one we previously registered with (level/save-load
// rebuilt it), re-register with the new instance.
//
// Cross-package guard: refuse if this toast's package (self.Level) doesn't match
// the live harry's package (h.Level). In M212 `Level.PlayerHarryActor` resolves
// to the *current* player pawn even from a stale-package actor's perspective,
// so Entry.APHUDToast0 (alive forever in the title-screen map's package) would
// otherwise reach the live Entryhall_hub harry and register itself into
// Entryhall_hub.HPHud.propArray. That cross-package ref is exactly what the
// SaveGame conform aborts on ("Graph is linked to external private object
// APHUDToast Entry.APHUDToast0") — keeping the .usa from updating after a drain.
function bool TryRegisterWithHUD()
{
    local harry h;
    local HPHud hud;

    h = harry(Level.PlayerHarryActor);
    if (h == None) return False;
    if (Level != h.Level)
    {
        return False;
    }
    hud = HPHud(h.myHUD);
    if (hud == None) return False;

    if (RegisteredHud == hud) return True;

    hud.RegisterPickupProp(self);
    RegisteredHud = hud;
    Log("[Archipelago] APHUDToast registered with HPHud (" $ string(hud) $ ")");
    return True;
}

// Shift the toast at `idx` out of the queue, sliding every later toast (and its
// segment block) down one slot. Backs both expiry and the queue-full drop.
function RemoveToastAt(int idx)
{
    local int j, k;

    for (j = idx; j < ToastCount - 1; j++)
    {
        ToastSegN[j] = ToastSegN[j + 1];
        ToastRemaining[j] = ToastRemaining[j + 1];
        for (k = 0; k < STRIDE; k++)
        {
            ToastSegs[j * STRIDE + k] = ToastSegs[(j + 1) * STRIDE + k];
        }
    }
    ToastSegN[ToastCount - 1] = 0;
    ToastRemaining[ToastCount - 1] = 0.0;
    ToastCount--;
}

// Reserve the next queue slot (dropping the oldest when full) and return its
// index. The caller fills segments via AddSeg, then finalizes with CommitToast.
// Not visible to RenderHud/Timer until CommitToast bumps ToastCount; safe
// because the whole build runs synchronously within one enqueue call.
function int BeginToast()
{
    local int idx;

    if (ToastCount >= MAX_QUEUE)
    {
        RemoveToastAt(0);
    }
    idx = ToastCount;
    ToastSegN[idx] = 0;
    ToastRemaining[idx] = TOAST_DURATION;
    return idx;
}

// Append one segment to the in-progress toast. Silently drops overflow past
// STRIDE so a malformed long record can never scribble into the next toast.
function AddSeg(int toastIdx, string text, byte code)
{
    local int n;

    n = ToastSegN[toastIdx];
    if (n >= STRIDE) return;
    ToastSegs[toastIdx * STRIDE + n].Text = text;
    ToastSegs[toastIdx * STRIDE + n].ColorCode = code;
    ToastSegN[toastIdx] = n + 1;
}

// Finalize the in-progress toast: make it visible and play the cue. Play
// through harry so it's at the camera (UI-loud), not this hidden actor's world
// position. `overrideSound` (e.g. the chocolate-frog ribbit) plays in place of
// the default vendor-whoosh; None falls back to ToastSound.
function CommitToast(optional Sound overrideSound)
{
    local harry h;
    local Sound soundToPlay;

    ToastCount++;

    if (overrideSound != None)
    {
        soundToPlay = overrideSound;
    }
    else
    {
        soundToPlay = ToastSound;
    }
    if (soundToPlay != None)
    {
        h = harry(Level.PlayerHarryActor);
        if (h != None)
        {
            h.PlaySound(soundToPlay);
        }
    }
}

// Single-colour, single-line toast (HP2 system status in yellow, multiworld
// lifecycle in white).
function EnqueuePlainToast(string text, byte code, optional Sound overrideSound)
{
    local int idx;

    if (text == "") return;
    idx = BeginToast();
    AddSeg(idx, text, code);
    Log("[Archipelago] APHUDToast plain toast: '" $ text $ "'");
    CommitToast(overrideSound);
}

// Back-compat: a bare toast is a yellow system line.
function EnqueueToast(string text, optional Sound overrideSound)
{
    EnqueuePlainToast(text, COL_YELLOW, overrideSound);
}

// Colourised multi-segment toast. `record` is the client-built segment record:
// `<roleChar><text>` segments joined by Chr(30). The role letter resolves to a
// colour code; an "n" role is a line break (empty text). Parsed once into the
// segment pool here, never re-parsed at render time.
function EnqueueSegmentToast(string record, optional Sound overrideSound)
{
    local int idx, sepIdx;
    local string seg, rest;

    if (record == "") return;
    idx = BeginToast();

    rest = record;
    while (rest != "")
    {
        sepIdx = InStr(rest, Chr(30));
        if (sepIdx < 0)
        {
            seg = rest;
            rest = "";
        }
        else
        {
            seg = Left(rest, sepIdx);
            rest = Mid(rest, sepIdx + 1);
        }
        if (seg == "") continue;
        AddSeg(idx, Mid(seg, 1), RoleCharToCode(Left(seg, 1)));
    }

    Log("[Archipelago] APHUDToast segment toast (segs=" $ ToastSegN[idx] $ ")");
    CommitToast(overrideSound);
}

// Map a client role letter to a stored colour code (see the legend up top).
function byte RoleCharToCode(string ch)
{
    if (ch == "w") return 1;
    if (ch == "s") return 2;
    if (ch == "o") return 3;
    if (ch == "g") return 4;
    if (ch == "u") return 5;
    if (ch == "t") return 6;
    if (ch == "f") return 7;
    if (ch == "l") return 8;
    if (ch == "n") return 9;
    return 0;
}

event Timer()
{
    local int i;

    // Save-graph hygiene — the instance copy of LatestInstance must never hold
    // a real ref (see the comment above the field declaration). A deserialized
    // toast comes back with whatever value the .usa serialized, often a
    // cross-package toast that would abort the next SaveGame.
    if (LatestInstance != None)
    {
        LatestInstance = None;
    }

    // Defensive: a deserialized toast (from .usa save) doesn't run PreBeginPlay
    // so default.LatestInstance may be None when its Timer first fires. Claim
    // it here so GetInstance() returns us and ApplyGrant routes to the right
    // place. Logs once when it kicks in.
    if (default.LatestInstance == None || default.LatestInstance.bDeleteMe)
    {
        default.LatestInstance = self;
        Log("[Archipelago] APHUDToast.Timer: reclaimed default.LatestInstance -> self");
    }

    // TryRegisterWithHUD self-dedupes against RegisteredHud so a no-op call
    // is cheap, and a changed HPHud (post-travel) re-registers.
    TryRegisterWithHUD();

    i = 0;
    while (i < ToastCount)
    {
        ToastRemaining[i] -= TICK_INTERVAL;
        if (ToastRemaining[i] <= 0)
        {
            RemoveToastAt(i);
        }
        else
        {
            i++;
        }
    }
}

// Map a stored colour code to its RGB (legend at the top of the class).
// NEWLINE never reaches here (RenderHud handles it as a layout break).
function Color RoleColor(byte code)
{
    local Color c;

    switch (code)
    {
        case 1: c.R = 230; c.G = 230; c.B = 230; break;   // white
        case 2: c.R = 238; c.G = 0;   c.B = 238; break;   // self slot (magenta)
        case 3: c.R = 238; c.G = 232; c.B = 205; break;   // other slot (cream)
        case 4: c.R = 159; c.G = 121; c.B = 238; break;   // progression
        case 5: c.R = 79;  c.G = 148; c.B = 205; break;   // useful
        case 6: c.R = 237; c.G = 123; c.B = 110; break;   // trap
        case 7: c.R = 9;   c.G = 203; c.B = 203; break;   // filler
        case 8: c.R = 50;  c.G = 205; c.B = 50;  break;   // location (green)
        default: c.R = 255; c.G = 220; c.B = 100; break;  // yellow (system)
    }
    return c;
}

// Measure toast `toastIdx`: its widest rendered line and its line count (split
// on NEWLINE segments). Each line is measured as one concatenated string so the
// width matches what DrawShadowText actually renders. TextSize is exact per
// string, but summing it per segment drifts and spreads the words apart.
function ComputeToastDims(Canvas C, int toastIdx, out float maxW, out int lineCount)
{
    local int j, n, baseIdx;
    local float w, h;
    local string lineText;

    n = ToastSegN[toastIdx];
    baseIdx = toastIdx * STRIDE;
    maxW = 0.0;
    lineCount = 1;
    lineText = "";

    for (j = 0; j < n; j++)
    {
        if (ToastSegs[baseIdx + j].ColorCode == COL_NEWLINE)
        {
            C.TextSize(lineText, w, h);
            if (w > maxW) maxW = w;
            lineText = "";
            lineCount++;
        }
        else
        {
            lineText = lineText $ ToastSegs[baseIdx + j].Text;
        }
    }
    C.TextSize(lineText, w, h);
    if (w > maxW) maxW = w;
}

function RenderHud(Canvas C)
{
    local int i, j, n, baseIdx, lineCount;
    local float baseY, lineHeight, scale, marginX, padX, padY;
    local float maxLineW, prefixW, prefixH, tmpW;
    local float boxX, boxY, boxW, boxH, curX, curY, runningY;
    local Color colorShadow, colorSave, segColor;
    local int styleSave;
    local harry h;
    local string txt, lineText;
    local byte code;

    if (C == None) return;

    // Banner first so it draws regardless of whether the toast queue is empty.
    // Each pass is independently gated; the banner runs whenever a Tradersanity
    // vendor is engaged, the toast loop runs whenever ToastCount > 0.
    DrawTradersanityAPLabel(C);

    if (ToastCount <= 0) return;

    h = harry(Level.PlayerHarryActor);
    if (h == None || h.Player == None) return;

    scale = C.GetHudScaleFactor();
    baseY = 90 * scale;
    marginX = 16 * scale;
    padX = 8 * scale;
    padY = 4 * scale;

    C.Font = baseConsole(h.Player.Console).LocalBigFont;

    // Line height comes from the font's own pixel height (LocalBigFont is a
    // fixed-size font, NOT scaled by GetHudScaleFactor) plus a little leading.
    // A scale-derived constant here is what blew the toast up vertically.
    C.TextSize("Ay", tmpW, lineHeight);
    lineHeight = lineHeight * 1.2;

    colorShadow.R = 0;
    colorShadow.G = 0;
    colorShadow.B = 0;

    colorSave = C.DrawColor;
    styleSave = C.Style;
    runningY = baseY;

    for (i = 0; i < ToastCount; i++)
    {
        n = ToastSegN[i];
        if (n <= 0) continue;
        baseIdx = i * STRIDE;

        ComputeToastDims(C, i, maxLineW, lineCount);

        boxW = maxLineW + padX * 2;
        boxH = lineCount * lineHeight + padY * 2;
        boxX = C.SizeX - boxW - marginX;
        boxY = runningY;

        // Translucent background panel spanning every line of this toast.
        if (ToastBackground != None)
        {
            C.Style = 2; // STY_Translucent (matches CutSceneManager border draw)
            C.DrawColor.R = 80;
            C.DrawColor.G = 80;
            C.DrawColor.B = 80;
            C.SetPos(boxX, boxY);
            C.DrawTile(ToastBackground, boxW, boxH, 0.0, 0.0, ToastBackground.USize, ToastBackground.VSize);
        }

        // Segments on top. Each segment's X is the measured width of the line
        // text drawn before it (one TextSize on the running prefix), so spacing
        // matches a single-string render exactly and never accumulates drift.
        C.Style = styleSave;
        C.DrawColor = colorSave;
        curY = boxY + padY;
        lineText = "";
        for (j = 0; j < n; j++)
        {
            code = ToastSegs[baseIdx + j].ColorCode;
            if (code == COL_NEWLINE)
            {
                curY += lineHeight;
                lineText = "";
                continue;
            }
            txt = ToastSegs[baseIdx + j].Text;
            if (lineText == "")
            {
                prefixW = 0.0;
            }
            else
            {
                C.TextSize(lineText, prefixW, prefixH);
            }
            curX = boxX + padX + prefixW;
            if (txt != "")
            {
                segColor = RoleColor(code);
                C.SetPos(curX, curY);
                C.DrawShadowText(txt, segColor, colorShadow);
            }
            lineText = lineText $ txt;
        }

        runningY += boxH + (2 * scale);
    }

    C.DrawColor = colorSave;
    C.Style = styleSave;
}

// Top-of-screen label that names the current vendor's offer as an Archipelago
// check. Visible while Harry has a vendor engaged (CurrVendorManager set
// after Bump), the vendor is an AP-active check in this seed (13 generic
// Tradersanity vendors gated on TradersanityMode, plus Fred/George gated on
// bQuidditchUpgrades, see APVendorController.GetActiveAPVendorLocationId), the
// AP location is still unchecked, AND the player hasn't already clicked Yes
// in this engagement (TraderPurchased). Hidden once any of those flips. The
// label text is the hinted item name when the apworld has cached one for
// this vendor (HINT IPC); otherwise the generic "Archipelago Item" fallback
// for off-hint seeds. Foreign-game item names come through unchanged — the
// apworld resolves them against slot_info.
function DrawTradersanityAPLabel(Canvas C)
{
    local harry h;
    local VendorManager vm;
    local Characters engagedVendor;
    local int locId, slot;
    local string lvl;
    local string label, hintName;
    local float textW, textH, labelX, labelY;
    local Color colorText, colorShadow, colorSave;
    local Font fontSave;

    // Helper internally gates the 13 generic vendors on TradersanityMode and
    // the Weasley brothers on bQuidditchUpgrades, so the banner appears on
    // Fred/George in quidditch-upgrades seeds even when Tradersanity is off.
    h = harry(Level.PlayerHarryActor);
    if (h == None || h.Player == None) return;

    vm = h.CurrVendorManager;
    if (vm == None || vm.Vendor == None) return;

    engagedVendor = vm.Vendor;
    lvl = string(Level.Outer.Name);
    locId = class'APVendorController'.static.GetActiveAPVendorLocationId(engagedVendor, lvl);
    if (locId <= 0) return;

    slot = locId - 5760000;
    if (slot < 0 || slot >= 1024) return;
    if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) return;
    if (class'APVendorController'.default.TraderPurchased[slot] == 1) return;

    hintName = class'APVendorController'.default.TraderHintItemName[slot];
    if (hintName != "")
    {
        label = hintName;
    }
    else
    {
        label = "Archipelago Item";
    }

    fontSave = C.Font;
    colorSave = C.DrawColor;
    // Font scales with content: a generic "Archipelago Item" reads as
    // marketing fluff and stays subtle; the hinted "<player>'s <item>"
    // form is the load-bearing info the player walked in to see, so it
    // gets the bigger LocalBigFont. baseConsole defines the family
    // small -> med -> big -> huge.
    if (hintName != "")
    {
        C.Font = baseConsole(h.Player.Console).LocalBigFont;
    }
    else
    {
        C.Font = baseConsole(h.Player.Console).LocalSmallFont;
    }

    // Archipelago-yellow on black shadow, matching the toast palette.
    colorText.R = 255;
    colorText.G = 220;
    colorText.B = 100;
    colorShadow.R = 0;
    colorShadow.G = 0;
    colorShadow.B = 0;

    C.TextSize(label, textW, textH);
    labelX = (C.SizeX - textW) / 2.0;
    // Place just above the trade bar (VendorManager's fVENDORBAR_Y=20 then
    // the bar texture's own height). A small margin so the label is clearly
    // separated from the bar.
    labelY = 2.0;
    C.SetPos(labelX, labelY);
    C.DrawShadowText(label, colorText, colorShadow);

    C.Font = fontSave;
    C.DrawColor = colorSave;
}

defaultproperties
{
    bHidden=True
    DrawType=DT_None
    bCollideActors=False
    bCollideWorld=False
    bBlockActors=False
    bBlockPlayers=False
    Physics=PHYS_None
    // bGameRelevant=False is REQUIRED, not inherited: HProp→HPawn→Pawn
    // defaults bGameRelevant=True, which would persist the toast across level
    // travel. A persisted toast is a per-package private actor that the HP2
    // conformal save graph then links to (e.g. Entry.APHUDToast0), aborting
    // the whole level-entry autosave ("Graph is linked to external private
    // object"). It also keeps the singleton clean: a per-level toast cannot
    // leave a stale Entry/old-level instance fighting the live one for
    // default.LatestInstance. The toast is a per-level HUD widget: each
    // level gets a fresh one via APGameInfo.InitGame, and via
    // APLevelSetup.TrySpawnClassroomBlockers on save-load (skips InitGame).
    bGameRelevant=False
}

// On-screen AP toasts: colourised multi-segment item lines ("X sent Y to Z",
// "X found their Y" with the location on a second line) plus single-colour
// system/lifecycle lines. Spawned per level from APGameInfo.InitGame; registers
// with HPHud's propArray so its RenderHud
// gets called every frame the HUD draws (including during cutscenes; vanilla
// only suppresses propArray rendering when the in-game menu is up).
//
// Why extend HProp: HPHud's propArray is `Array<HProp>` (HPHud.uc:20), so the
// only way to get into the per-frame Canvas render loop is to be an HProp.
// We override RenderHud to draw text instead of the inherited
// `Canvas.DrawActor(self, False, True)` (which would try to render the actor
// as a 3D mesh in HUD space). The actor itself is hidden, non-colliding, and
// has no physics.
//
// Lifetime: per level. NOT bGameRelevant, each level transition destroys
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

// Fixed toast box width. Every toast draws to one width so the column is uniform
// and the text floats left; a line longer than this ellipsizes rather than
// widening the box. The width is measured at render time from the wider of these
// two worst-case normal lines (own-game item / location, 7-char name): line 1 is
// the two-name "sent" phrasing with the longest item, line 2 the longest location
// in parentheses. Foreign item / location names and longer player names exceed it
// and get the ellipsis. If the real names drift, the clamp shifts slightly and the
// ellipsis absorbs it.
const TOAST_SAMPLE_LINE1 = "Playerr sent Bronze Card - Marjoribanks to Playerr";
const TOAST_SAMPLE_LINE2 = "(Slytherin Common Room - Flobberworm Mucous Jar)";
const TOAST_ELLIPSIS = "...";

// Minimum life (seconds) a carried-over toast resumes with in the next level, so
// a near-expired one still gets read time. See the carry buffer below.
const CARRY_MIN_REMAINING = 2.0;

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

// Cross-level carry buffer. Lives ONLY on the class default so it survives the
// per-level toast teardown/respawn: the actor is garbage-collected on level
// travel (its Destroyed event does NOT fire, the whole level package is just
// unloaded), but the class object stays loaded for the whole process, so
// default.* persists across a loading zone. The active toast mirrors its
// on-screen queue here every Timer tick (MirrorQueueToCarry), and the relay
// appends records that arrive while no live toast exists (the loading-gap drop).
// The next level's fresh toast drains it once it registers (DrainCarryToQueue),
// silently, so a level-complete send fired right at a loading zone is still
// readable. Mirrors the live-queue layout (CarrySegs is MAX_QUEUE*STRIDE). Pure
// value types like the live arrays, so the save graph stays clean. Instance
// copies are unused; only default.* matters.
var transient ToastSeg CarrySegs[80];
var transient int CarrySegN[8];
var transient float CarryRemaining[8];
var transient int CarryCount;
// Per-instance: this toast has replayed the carried buffer from the previous
// level. Set the moment it first registers (so carried toasts do not decay
// during the pre-registration load window). Gates MirrorQueueToCarry too: the
// buffer is left untouched until the drain, then this toast owns it.
var transient bool bDrainedCarry;

// HPHud we're currently registered with. `transient` so a saved-state
// deserialized toast doesn't bring back a stale ref that fools the dedupe
// path into thinking we're already in propArray when we aren't. Each new
// instance (freshly spawned OR deserialized) starts with RegisteredHud=None
// and registers via TryRegisterWithHUD on its first Timer tick.
var transient HPHud RegisteredHud;

// Background texture drawn behind each toast. `HGame.Icons.FEInGameBackTexture1`
// is frame 1 of the pause menu's animated backdrop (FEBook.InGameBackground): the
// top ~40% is a golden header frame, the rest clean starry sky. The toast draws
// only the clean-sky part, opaque, so it reads like a slice of the folio screen
// without the header band.
var Texture ToastBackground;
// "Whoosh" played per toast, the same sound vanilla plays when a vendor card
// flies out into the world (Characters.uc:698 PlaySound `vendor_spawn_WC`).
var Sound ToastSound;

// Singleton pointer lives ONLY on the class default (`default.LatestInstance`).
// The per-instance copy of this field must always be None. Otherwise the save
// graph walks it and trips on a cross-package ref: a freshly-spawned toast in
// (say) Entryhall_hub initializes its instance copy from the class default at
// spawn time, which is the very first toast that ran PreBeginPlay this process
// (e.g. Entry.APHUDToast0 at app launch). Saving Entryhall_hub then aborts with
// "Graph is linked to external private object APHUDToast Entry.APHUDToast0",
// the .usa is never written, and the player's progress silently rolls back on
// the next load. PreBeginPlay clears it for fresh spawns; Timer clears it
// defensively every tick for deserialized toasts (which skip PreBeginPlay).
// `transient` is intentionally omitted. M212 does not honor it, so the explicit
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

    // Critical save-graph hygiene. See the comment above the LatestInstance
    // declaration. Spawn() seeds this instance copy from the class default
    // (which may point at a previous-level / Entry toast), so clear it before
    // any SaveGame can run.
    LatestInstance = None;

    // Fresh instance: it has not yet drained the previous level's carry buffer.
    bDrainedCarry = False;

    default.LatestInstance = self;
    SetTimer(TICK_INTERVAL, true);

    // Lazy-load the panel texture once. baseWarning/CutSceneManager show this
    // same texture works at runtime for HUD draws.
    if (ToastBackground == None)
    {
        ToastBackground = Texture(DynamicLoadObject("HGame.Icons.FEInGameBackTexture1", class'Texture'));
    }
    if (ToastSound == None)
    {
        ToastSound = Sound(DynamicLoadObject("HPSounds.Magic_sfx.vendor_spawn_WC", class'Sound'));
    }

    Log("[Archipelago] APHUDToast.PreBeginPlay - registered as singleton");
}

event Destroyed()
{
    // Note: on level travel this does NOT run (the level package is unloaded and
    // the toast is garbage-collected without a Destroyed event). The cross-level
    // carry buffer is therefore maintained from Timer (MirrorQueueToCarry), not
    // here. This still fires on an explicit Destroy() (e.g. a stale toast being
    // replaced), where the propArray cleanup below matters.

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
// APHUDToast Entry.APHUDToast0"), keeping the .usa from updating after a drain.
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

// True when the on-screen queue has a free slot, so a newly committed toast will
// not push the oldest off. The grant drain reads this to pace a received-item
// burst to the panel's capacity (APIPCActor.TryDrainPendingGrants).
function bool HasToastRoom()
{
    return ToastCount < MAX_QUEUE;
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

    // Mirror the carry buffer the instant a toast is added, so a toast committed
    // in the last fraction of a second before a loading zone is carried even if
    // no Timer tick fires before the level is unloaded. Same gating as the Timer
    // mirror: only after this toast has drained the previous buffer, active only.
    if (bDrainedCarry && default.LatestInstance == self)
    {
        MirrorQueueToCarry();
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
    local int idx;
    local string seg, rest;

    if (record == "") return;
    idx = BeginToast();

    rest = record;
    while (rest != "")
    {
        seg = class'APCsvCodec'.static.NextTokenUpTo(rest, Chr(30));
        if (seg == "") continue;
        AddSeg(idx, Mid(seg, 1), class'APHUDToast'.static.RoleCharToCode(Left(seg, 1)));
    }

    Log("[Archipelago] APHUDToast segment toast (segs=" $ ToastSegN[idx] $ ")");
    CommitToast(overrideSound);
}

// ---- Cross-level carry buffer ----------------------------------------------
// Capture toasts so they survive a loading zone. Two producers feed the
// class-default buffer: MirrorQueueToCarry (the active toast continuously mirrors
// its on-screen queue here, since the actor is GC'd on travel with no Destroyed
// event) and BufferSegmentRecord/BufferPlainRecord (records that reached the
// relay while no live toast existed). DrainCarryToQueue (next level's fresh
// toast) is the single consumer. The buffer-fill helpers are static so the
// relay can reach them with no live instance.

// Reserve the next carry slot, dropping the oldest carried toast when full
// (newer info matters more, mirroring BeginToast). Returns the slot index with
// CarrySegN cleared and CarryRemaining seeded to a full duration; producers that
// carry a partially-elapsed toast (the teardown snapshot) overwrite the latter.
static function int BeginCarryEntry()
{
    local int idx, j, k;

    if (default.CarryCount >= MAX_QUEUE)
    {
        for (j = 0; j < MAX_QUEUE - 1; j++)
        {
            default.CarrySegN[j] = default.CarrySegN[j + 1];
            default.CarryRemaining[j] = default.CarryRemaining[j + 1];
            for (k = 0; k < STRIDE; k++)
            {
                default.CarrySegs[j * STRIDE + k] = default.CarrySegs[(j + 1) * STRIDE + k];
            }
        }
        default.CarryCount = MAX_QUEUE - 1;
    }
    idx = default.CarryCount;
    default.CarrySegN[idx] = 0;
    default.CarryRemaining[idx] = TOAST_DURATION;
    default.CarryCount++;
    return idx;
}

// Append one segment to carry entry `carryIdx`. Whole-struct assignment (not a
// member write on a default array element) keeps it to lvalue forms M212 is
// known to accept. Silently drops overflow past STRIDE, like AddSeg.
static function AddCarrySeg(int carryIdx, string text, byte code)
{
    local int n;
    local ToastSeg seg;

    n = default.CarrySegN[carryIdx];
    if (n >= STRIDE) return;
    seg.Text = text;
    seg.ColorCode = code;
    default.CarrySegs[carryIdx * STRIDE + n] = seg;
    default.CarrySegN[carryIdx] = n + 1;
}

// Parse a colourised segment record (the SENT / item form) straight into a new
// carry entry at full duration. Mirrors EnqueueSegmentToast's tokenizer but
// targets the class-default buffer; used when a "we sent X to Y" record arrives
// during the loading gap with no live toast to show it.
static function BufferSegmentRecord(string record)
{
    local int idx;
    local string seg, rest;

    if (record == "") return;
    idx = BeginCarryEntry();

    rest = record;
    while (rest != "")
    {
        seg = class'APCsvCodec'.static.NextTokenUpTo(rest, Chr(30));
        if (seg == "") continue;
        AddCarrySeg(idx, Mid(seg, 1), RoleCharToCode(Left(seg, 1)));
    }

    Log("[Archipelago] APHUDToast.BufferSegmentRecord: buffered late record (carryCount=" $ default.CarryCount $ ")");
}

// Single-segment plain toast (system/lifecycle line) buffered for the loading
// gap. Counterpart to BufferSegmentRecord for the TOAST / TOASTW relay path.
static function BufferPlainRecord(string text, byte code)
{
    local int idx;

    if (text == "") return;
    idx = BeginCarryEntry();
    AddCarrySeg(idx, text, code);
    Log("[Archipelago] APHUDToast.BufferPlainRecord: buffered late toast '" $ text $ "'");
}

// Mirror the active toast's on-screen queue into the carry buffer. Called every
// Timer tick (after the drain) so the class default always reflects exactly what
// is on screen right now, with each toast's current remaining time. This is the
// teardown-survival mechanism: the actor is GC'd on travel without a Destroyed
// event, so there is no snapshot-at-teardown; the continuously-updated class
// default is what the next level reads. Full overwrite (resets CarryCount), so
// the live queue is the single source of truth. The live queue already self-
// prunes expired toasts, so an empty queue correctly empties the buffer. No Log:
// this runs at 10 Hz.
function MirrorQueueToCarry()
{
    local int i, k, srcBase, dstBase;

    default.CarryCount = 0;
    for (i = 0; i < ToastCount; i++)
    {
        if (default.CarryCount >= MAX_QUEUE) break;
        srcBase = i * STRIDE;
        dstBase = default.CarryCount * STRIDE;
        default.CarrySegN[default.CarryCount] = ToastSegN[i];
        default.CarryRemaining[default.CarryCount] = ToastRemaining[i];
        for (k = 0; k < STRIDE; k++)
        {
            default.CarrySegs[dstBase + k] = ToastSegs[srcBase + k];
        }
        default.CarryCount++;
    }
}

// Replay the previous level's carry buffer into this toast's live queue, then
// clear it. A direct array copy, never CommitToast, so there is no whoosh and no
// inter-toast wait (every carried toast lands in one pass and renders stacked).
// Each resumes at its carried remaining, floored to CARRY_MIN_REMAINING. Called
// exactly once per toast (Timer guards on bDrainedCarry), the moment it first
// registers, so carried toasts only start decaying when they can actually
// render. The clear is defensive: this toast's own MirrorQueueToCarry repopulates
// the buffer the same tick, but clearing first means no other instance can
// re-drain this same content.
function DrainCarryToQueue()
{
    local int i, k, srcBase, dstBase;
    local float remaining;

    if (default.CarryCount <= 0) return;

    for (i = 0; i < default.CarryCount; i++)
    {
        if (ToastCount >= MAX_QUEUE) break;
        srcBase = i * STRIDE;
        dstBase = ToastCount * STRIDE;
        ToastSegN[ToastCount] = default.CarrySegN[i];
        remaining = default.CarryRemaining[i];
        if (remaining < CARRY_MIN_REMAINING)
        {
            remaining = CARRY_MIN_REMAINING;
        }
        ToastRemaining[ToastCount] = remaining;
        for (k = 0; k < STRIDE; k++)
        {
            ToastSegs[dstBase + k] = default.CarrySegs[srcBase + k];
        }
        ToastCount++;
    }

    Log("[Archipelago] APHUDToast.DrainCarryToQueue: replayed " $ default.CarryCount $ " carried toast(s)");

    for (i = 0; i < MAX_QUEUE; i++)
    {
        default.CarrySegN[i] = 0;
        default.CarryRemaining[i] = 0.0;
    }
    default.CarryCount = 0;
}

// Map a client role letter to a stored colour code (see the legend up top).
// Static so the carry-buffer fill path (BufferSegmentRecord, called from the
// relay with no live instance) can reuse it. Callers use the qualified
// class'APHUDToast'.static form.
static function byte RoleCharToCode(string ch)
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

    // Save-graph hygiene. The instance copy of LatestInstance must never hold
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
    // is cheap, and a changed HPHud (post-travel) re-registers. The first time it
    // registers, replay the toasts carried across the loading zone (once, gated on
    // bDrainedCarry). Gated on registration so carried toasts only begin decaying
    // once they can actually render.
    if (TryRegisterWithHUD() && !bDrainedCarry)
    {
        bDrainedCarry = True;
        DrainCarryToQueue();
    }

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

    // Keep the cross-level carry buffer current with what is on screen. The actor
    // is GC'd on travel without a Destroyed event, so this continuous mirror (not
    // a teardown snapshot) is what survives into the next level. Held off until
    // this toast has drained the previous buffer, and only the active instance
    // writes it.
    if (bDrainedCarry && default.LatestInstance == self)
    {
        MirrorQueueToCarry();
    }
}

// AP UI colour palette. One place for every colour the toasts and the pause-menu
// goal panel draw, so the brand and role colours can't drift across call sites.
// (A stays 0, matching the fresh local Colors these replace.)
static function Color RGB(int r, int g, int b)
{
    local Color c;
    c.R = r;
    c.G = g;
    c.B = b;
    return c;
}

static function Color APYellow()          { return RGB(255, 220, 100); }  // system / brand
static function Color APWhite()           { return RGB(255, 255, 255); }  // true white (goal panel)
static function Color APBlack()           { return RGB(0,   0,   0);   }  // text shadow
static function Color APGoalGreen()       { return RGB(60,  220, 90);  }  // goal-met (goal panel)
static function Color APRoleWhite()       { return RGB(230, 230, 230); }  // toast white
static function Color APRoleSelfSlot()    { return RGB(238, 0,   238); }  // self slot (magenta)
static function Color APRoleOtherSlot()   { return RGB(238, 232, 205); }  // other slot (cream)
static function Color APRoleProgression() { return RGB(159, 121, 238); }
static function Color APRoleUseful()      { return RGB(79,  148, 205); }
static function Color APRoleTrap()        { return RGB(237, 123, 110); }
static function Color APRoleFiller()      { return RGB(9,   203, 203); }
static function Color APRoleLocation()    { return RGB(50,  205, 50);  }  // toast green

// Map a stored colour code to its RGB (legend at the top of the class).
// NEWLINE never reaches here (RenderHud handles it as a layout break).
function Color RoleColor(byte code)
{
    local Color c;

    switch (code)
    {
        case 1: c = APRoleWhite();       break;   // white
        case 2: c = APRoleSelfSlot();    break;   // self slot (magenta)
        case 3: c = APRoleOtherSlot();   break;   // other slot (cream)
        case 4: c = APRoleProgression(); break;
        case 5: c = APRoleUseful();      break;
        case 6: c = APRoleTrap();        break;
        case 7: c = APRoleFiller();      break;
        case 8: c = APRoleLocation();    break;   // location (green)
        default: c = APYellow();         break;   // yellow (system)
    }
    return c;
}

// Longest prefix of `s` that, with the ellipsis appended, fits within `maxW`
// pixels. Used to cut an overflowing toast line down to the fixed box width. Only
// runs on a line that actually overflows, so the per-character walk is cheap.
function string TruncateWithEllipsis(Canvas C, string s, float maxW)
{
    local float w, hh;

    while (Len(s) > 0)
    {
        C.TextSize(s $ TOAST_ELLIPSIS, w, hh);
        if (w <= maxW) return s $ TOAST_ELLIPSIS;
        s = Left(s, Len(s) - 1);
    }
    return TOAST_ELLIPSIS;
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
    local float maxContentW, sampleW, skyV0, skyVL;
    local float boxX, boxY, boxW, boxH, curX, curY, runningY;
    local Color colorShadow, colorSave, segColor;
    local int styleSave;
    local bool lineFull;
    local harry h;
    local string txt, lineText;
    local byte code;

    if (C == None) return;

    // Banner and trap status first so they draw regardless of whether the toast
    // queue is empty. Each pass is independently gated: the banner runs whenever a
    // Tradersanity vendor is engaged, the trap status whenever an invisible-effect
    // trap is live, the toast loop whenever ToastCount > 0.
    DrawTradersanityAPLabel(C);
    DrawTrapStatus(C);

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

    // One fixed content width for every toast: the wider of the two worst-case
    // normal lines. Boxes share this width (uniform left column) and longer lines
    // ellipsize instead of stretching the box. Clamped to the screen so a low
    // resolution / high HUD scale never pushes the box off the right edge.
    C.TextSize(TOAST_SAMPLE_LINE1, maxContentW, tmpW);
    C.TextSize(TOAST_SAMPLE_LINE2, sampleW, tmpW);
    if (sampleW > maxContentW) maxContentW = sampleW;
    if (maxContentW > C.SizeX - marginX * 2 - padX * 2)
        maxContentW = C.SizeX - marginX * 2 - padX * 2;

    colorShadow = APBlack();

    colorSave = C.DrawColor;
    styleSave = C.Style;
    runningY = baseY;

    for (i = 0; i < ToastCount; i++)
    {
        n = ToastSegN[i];
        if (n <= 0) continue;
        baseIdx = i * STRIDE;

        // Line count still comes from the segments; the width is fixed, not
        // content-derived, so every box matches. The holder stays on the right
        // (uniform right edge); the text floats left inside each box.
        ComputeToastDims(C, i, maxLineW, lineCount);

        boxW = maxContentW + padX * 2;
        boxH = lineCount * lineHeight + padY * 2;
        boxX = C.SizeX - boxW - marginX;
        boxY = runningY;

        // Menu-sky background spanning every line: a crop of the pause menu's
        // backdrop, taken below its golden header frame (the texture's top ~40%) and
        // drawn opaque (styleSave is the opaque text style saved above). The crop
        // height tracks the box aspect, so the sky scales uniformly instead of
        // smearing into horizontal streaks.
        if (ToastBackground != None)
        {
            skyVL = ToastBackground.VSize * boxH / boxW;
            skyV0 = ToastBackground.VSize * 0.52;
            if (skyV0 + skyVL > ToastBackground.VSize)
                skyV0 = ToastBackground.VSize - skyVL;
            C.Style = styleSave;
            C.DrawColor.R = 255;
            C.DrawColor.G = 255;
            C.DrawColor.B = 255;
            C.SetPos(boxX, boxY);
            C.DrawTile(ToastBackground, boxW, boxH, 0.0, skyV0, ToastBackground.USize, skyVL);
        }

        // Segments on top. Each segment's X is the measured width of the line
        // text drawn before it (one TextSize on the running prefix), so spacing
        // matches a single-string render exactly and never accumulates drift. A
        // line whose text passes the fixed content width is cut with an ellipsis
        // and the rest of that line is skipped.
        C.Style = styleSave;
        C.DrawColor = colorSave;
        curY = boxY + padY;
        lineText = "";
        lineFull = False;
        for (j = 0; j < n; j++)
        {
            code = ToastSegs[baseIdx + j].ColorCode;
            if (code == COL_NEWLINE)
            {
                curY += lineHeight;
                lineText = "";
                lineFull = False;
                continue;
            }
            if (lineFull) continue;   // remainder of an already-ellipsized line
            txt = ToastSegs[baseIdx + j].Text;
            if (txt == "") continue;

            if (lineText == "")
            {
                prefixW = 0.0;
            }
            else
            {
                C.TextSize(lineText, prefixW, prefixH);
            }
            curX = boxX + padX + prefixW;
            segColor = RoleColor(code);

            C.TextSize(lineText $ txt, tmpW, prefixH);
            if (tmpW <= maxContentW)
            {
                C.SetPos(curX, curY);
                C.DrawShadowText(txt, segColor, colorShadow);
                lineText = lineText $ txt;
            }
            else
            {
                // Overflow: draw the largest fitting slice of this segment plus the
                // ellipsis, then skip the rest of this line.
                txt = TruncateWithEllipsis(C, txt, maxContentW - prefixW);
                C.SetPos(curX, curY);
                C.DrawShadowText(txt, segColor, colorShadow);
                lineFull = True;
            }
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
// for off-hint seeds. Foreign-game item names come through unchanged, the
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
    local Texture apIcon;

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

    slot = class'APLocationRegistry'.static.SlotForApId(locId);
    if (slot < 0) return;
    if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) return;
    if (class'APVendorController'.default.TraderPurchased[slot] == 1) return;

    // Swap the trade-bar icon to the AP logo here, per frame, so it is instant on
    // engagement instead of lagging up to one Timer tick behind the bar opening.
    // Past the unchecked + unpurchased guards, this is exactly the window the AP
    // icon should show. The Timer's TradersanityIconSwapPass still owns the restore
    // to the vanilla icon once the location is checked or purchased. The texture is
    // cached, so this adds no per-frame load.
    if (vm.textureItemToSell != None)
    {
        apIcon = class'APAppearanceMath'.static.GetAPItemTextureStatic();
        if (apIcon != None && vm.textureItemToSell != apIcon)
        {
            vm.textureItemToSell = apIcon;
        }
    }

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
    colorText = APYellow();
    colorShadow = APBlack();

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

// Persistent on-screen countdown, one row per active timed trap: Confundus
// (inverted look), Obliviate (spellbook sealed), Engorgio / Reducio (size),
// Levicorpus (upside down), Jelly-Legs (jump hijack), and Drowsiness (sleepy
// slow). The invisible traps need the cue to be seen at all; the visible ones
// read out how long is left. Gated on the live APTrapController class-default
// flags. The first four count down a Level.TimeSeconds expiry, Jelly-Legs the
// watcher's 0.25s tick countdown, and Drowsiness the engine's own once-per-
// second sleepy countdown. Drawn each frame like the Tradersanity banner,
// independent of the toast queue, so it stays up the whole effect. Trap-red on
// a black shadow, top-centre, clear of the vendor banner above it.
function DrawTrapStatus(Canvas C)
{
    local harry h;
    local HPHud hud;
    local bool bConfundus, bObliviate, bSize, bLevicorpus, bJellyLegs, bDrowsiness;
    local float now, rem, textW, textH, rowY, scale;
    local Color colorText, colorShadow, colorSave;
    local Font fontSave;
    local string label;

    bConfundus  = (class'APTrapController'.default.bConfundusTrapActive == 1);
    bObliviate  = (class'APTrapController'.default.bSpellTrapActive == 1);
    bSize       = (class'APTrapController'.default.bSizeTrapActive == 1);
    bLevicorpus = (class'APTrapController'.default.bLevicorpusTrapActive == 1);
    bJellyLegs  = (class'APTrapController'.default.bJellyLegsTrapActive == 1);
    bDrowsiness = (class'APTrapController'.default.bDrowsinessTrapActive == 1);
    if (!bConfundus && !bObliviate && !bSize && !bLevicorpus && !bJellyLegs && !bDrowsiness) return;

    h = harry(Level.PlayerHarryActor);
    if (h == None || h.Player == None) return;

    now = h.Level.TimeSeconds;
    scale = C.GetHudScaleFactor();

    fontSave = C.Font;
    colorSave = C.DrawColor;
    C.Font = baseConsole(h.Player.Console).LocalBigFont;
    colorText = APRoleTrap();
    colorShadow = APBlack();

    // First row sits below the very top, clear of the Tradersanity vendor banner
    // (drawn by the same RenderHud at y~2).
    rowY = 28.0 * scale;

    // A live spell challenge parks its score/timer icon dead-centre at the very
    // top, so the top-centre trap rows land right on the hourglass. When that icon
    // is up, drop the rows just below its boxes so both stay readable. Cheap pointer
    // read off the HUD, not an AllActors scan (this runs every frame).
    hud = HPHud(h.myHUD);
    if (hud != None && hud.managerChallenge != None
        && hud.managerChallenge.IsInState('ChallengeInProgress'))
    {
        rowY = ChallengeIconContentBottom(C);
    }

    if (bConfundus)
    {
        rem = class'APTrapController'.default.ConfundusTrapExpiry - now;
        label = "Confunded!  " $ string(CeilSeconds(rem)) $ "s";
        C.TextSize(label, textW, textH);
        C.SetPos((C.SizeX - textW) / 2.0, rowY);
        C.DrawShadowText(label, colorText, colorShadow);
        rowY += textH * 1.15;
    }

    if (bObliviate)
    {
        rem = class'APTrapController'.default.SpellTrapExpiry - now;
        label = "Obliviated: spells sealed  " $ string(CeilSeconds(rem)) $ "s";
        C.TextSize(label, textW, textH);
        C.SetPos((C.SizeX - textW) / 2.0, rowY);
        C.DrawShadowText(label, colorText, colorShadow);
        rowY += textH * 1.15;
    }

    if (bSize)
    {
        rem = class'APTrapController'.default.SizeTrapExpiry - now;
        // The controller records the trap's target scale, so the row names the
        // spell even while a refused grow keeps the pawn at the old size.
        if (class'APTrapController'.default.SizeTrapScale > h.Default.DrawScale)
        {
            label = "Engorgio!  " $ string(CeilSeconds(rem)) $ "s";
        }
        else
        {
            label = "Reducio!  " $ string(CeilSeconds(rem)) $ "s";
        }
        C.TextSize(label, textW, textH);
        C.SetPos((C.SizeX - textW) / 2.0, rowY);
        C.DrawShadowText(label, colorText, colorShadow);
        rowY += textH * 1.15;
    }

    if (bLevicorpus)
    {
        rem = class'APTrapController'.default.LevicorpusTrapExpiry - now;
        label = "Levicorpus!  " $ string(CeilSeconds(rem)) $ "s";
        C.TextSize(label, textW, textH);
        C.SetPos((C.SizeX - textW) / 2.0, rowY);
        C.DrawShadowText(label, colorText, colorShadow);
        rowY += textH * 1.15;
    }

    if (bJellyLegs)
    {
        // Tick countdown, 0.25s per watcher Timer tick.
        rem = class'APTrapController'.default.JellyLegsTicksLeft * 0.25;
        label = "Jelly-Legs!  " $ string(CeilSeconds(rem)) $ "s";
        C.TextSize(label, textW, textH);
        C.SetPos((C.SizeX - textW) / 2.0, rowY);
        C.DrawShadowText(label, colorText, colorShadow);
        rowY += textH * 1.15;
    }

    if (bDrowsiness)
    {
        // The engine's own sleepy countdown, whole seconds.
        rem = float(h.iSleepyAnimTimer);
        label = "Drowsy!  " $ string(CeilSeconds(rem)) $ "s";
        C.TextSize(label, textW, textH);
        C.SetPos((C.SizeX - textW) / 2.0, rowY);
        C.DrawShadowText(label, colorText, colorShadow);
        rowY += textH * 1.15;
    }

    C.Font = fontSave;
    C.DrawColor = colorSave;
}

// Y coordinate, in canvas pixels, just under the challenge score icon's visible
// content. ChallengeScoreManager parks the 128x128 HP2ChallengeScore icon with
// its top at 4 units, scaled by SizeX/640 and the aspect height scale. The
// hourglass and score boxes fill only the top 76 texture rows (the rest is
// transparent), so anchoring to row 76 plus a small gap drops the trap rows just
// beneath the boxes instead of below the empty padding.
static function float ChallengeIconContentBottom(Canvas C)
{
    local float fScaleFactor, heightScale;

    fScaleFactor = C.SizeX / 640.0;
    heightScale  = class'M212HScale'.static.CanvasGetHeightScale(C);
    return (4.0 + 76.0 + 6.0) * fScaleFactor * heightScale;
}

// Whole seconds remaining, rounded up, floored at 0. Keeps the countdown from
// reading 0 while the effect is still live and never shows a negative if a tick
// lands just past the expiry before the trap flag clears.
static function int CeilSeconds(float remaining)
{
    local int s;

    if (remaining <= 0.0) return 0;
    s = int(remaining);
    if (remaining > float(s)) s++;
    return s;
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

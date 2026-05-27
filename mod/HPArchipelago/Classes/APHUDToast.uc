// On-screen "Received: <item>" notification for AP grants. Spawned per level
// from APGameInfo.InitGame; registers with HPHud's propArray so its RenderHud
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
// the toast and the next InitGame (or APCardWatcher.TrySpawnClassroomBlockers
// on save-load) spawns a fresh one. Class-default `LatestInstance` lets
// APGameInfo.ApplyGrant reach the active toast via GetInstance().
//
// Queue: parallel arrays. When full, drops the OLDEST toast to make room for
// a new one — newer info matters more during a resync flood. Entries decay
// over `TOAST_DURATION` then auto-remove.
class APHUDToast extends HProp;

const MAX_QUEUE = 8;
const TOAST_DURATION = 5.0;
const TICK_INTERVAL = 0.1;

var string ToastText[8];
var float ToastRemaining[8];
var int ToastCount;
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
function bool TryRegisterWithHUD()
{
    local harry h;
    local HPHud hud;

    h = harry(Level.PlayerHarryActor);
    if (h == None) return False;
    hud = HPHud(h.myHUD);
    if (hud == None) return False;

    if (RegisteredHud == hud) return True;

    hud.RegisterPickupProp(self);
    RegisteredHud = hud;
    Log("[Archipelago] APHUDToast registered with HPHud (" $ string(hud) $ ")");
    return True;
}

// `overrideSound` (optional) plays in place of the default vendor-whoosh —
// caller passes per-item flavor (e.g. chocolate frog ribbit for the Chocolate
// Frog grant) without losing the toast's HUD-level audio cue. Null override
// falls back to ToastSound.
function EnqueueToast(string text, optional Sound overrideSound)
{
    local int i;
    local harry h;
    local Sound soundToPlay;

    if (text == "") return;

    if (ToastCount >= MAX_QUEUE)
    {
        // Queue full: drop oldest (index 0), shift everything down.
        for (i = 0; i < MAX_QUEUE - 1; i++)
        {
            ToastText[i] = ToastText[i + 1];
            ToastRemaining[i] = ToastRemaining[i + 1];
        }
        ToastCount = MAX_QUEUE - 1;
    }
    ToastText[ToastCount] = text;
    ToastRemaining[ToastCount] = TOAST_DURATION;
    ToastCount++;
    Log("[Archipelago] APHUDToast.EnqueueToast: '" $ text $ "' (queue=" $ ToastCount $ ")");

    // Audio feedback. Play through harry so it's at the camera (UI-loud)
    // rather than from this hidden actor's world position.
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

event Timer()
{
    local int i, j;

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
            // Expired: shift everything after [i] down one slot.
            for (j = i; j < ToastCount - 1; j++)
            {
                ToastText[j] = ToastText[j + 1];
                ToastRemaining[j] = ToastRemaining[j + 1];
            }
            ToastText[ToastCount - 1] = "";
            ToastRemaining[ToastCount - 1] = 0.0;
            ToastCount--;
        }
        else
        {
            i++;
        }
    }
}

function RenderHud(Canvas C)
{
    local int i;
    local float baseY, lineHeight, scale, marginX, padX, padY;
    local float textW, textH;
    local float boxX, boxY, boxW, boxH;
    local Color colorText, colorShadow, colorSave;
    local int styleSave;
    local harry h;
    local string s;

    if (C == None) return;

    // Banner first so it draws regardless of whether the toast queue is empty.
    // Each pass is independently gated; the banner runs whenever a Tradersanity
    // vendor is engaged, the toast loop runs whenever ToastCount > 0.
    DrawTradersanityAPLabel(C);

    if (ToastCount <= 0) return;

    h = harry(Level.PlayerHarryActor);
    if (h == None || h.Player == None) return;

    scale = C.GetHudScaleFactor();
    lineHeight = 28 * scale;
    baseY = 90 * scale;
    marginX = 16 * scale;
    padX = 8 * scale;
    padY = 4 * scale;

    C.Font = baseConsole(h.Player.Console).LocalMedFont;

    // Archipelago-yellow text on black shadow.
    colorText.R = 255;
    colorText.G = 220;
    colorText.B = 100;
    colorShadow.R = 0;
    colorShadow.G = 0;
    colorShadow.B = 0;

    colorSave = C.DrawColor;
    styleSave = C.Style;

    for (i = 0; i < ToastCount; i++)
    {
        s = ToastText[i];
        if (s == "") continue;
        C.TextSize(s, textW, textH);

        boxW = textW + padX * 2;
        boxH = textH + padY * 2;
        boxX = C.SizeX - boxW - marginX;
        boxY = baseY + (i * lineHeight);

        // Background panel — translucent, slightly dimmed via DrawColor so
        // the text reads cleanly on top.
        if (ToastBackground != None)
        {
            C.Style = 2; // STY_Translucent (matches CutSceneManager border draw)
            C.DrawColor.R = 80;
            C.DrawColor.G = 80;
            C.DrawColor.B = 80;
            C.SetPos(boxX, boxY);
            C.DrawTile(ToastBackground, boxW, boxH, 0.0, 0.0, ToastBackground.USize, ToastBackground.VSize);
        }

        // Text on top of the panel.
        C.Style = styleSave;
        C.DrawColor = colorSave;
        C.SetPos(boxX + padX, boxY + padY);
        C.DrawShadowText(s, colorText, colorShadow);
    }

    C.DrawColor = colorSave;
    C.Style = styleSave;
}

// Top-of-screen label that names the current vendor's offer as an Archipelago
// check. Visible while Harry has a vendor engaged (CurrVendorManager set
// after Bump), the vendor is an AP-active check in this seed (13 generic
// Tradersanity vendors gated on TradersanityMode, plus Fred/George gated on
// bQuidditchUpgrades — see APCardWatcher.GetActiveAPVendorLocationId), the
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
    locId = class'APCardWatcher'.static.GetActiveAPVendorLocationId(engagedVendor, lvl);
    if (locId <= 0) return;

    slot = locId - 5760000;
    if (slot < 0 || slot >= 1024) return;
    if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) return;
    if (class'APCardWatcher'.default.TraderPurchased[slot] == 1) return;

    hintName = class'APCardWatcher'.default.TraderHintItemName[slot];
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
    // APCardWatcher.TrySpawnClassroomBlockers on save-load (skips InitGame).
    bGameRelevant=False
}

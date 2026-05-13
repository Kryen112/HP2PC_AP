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
// Lifetime: per level. Class-default `LatestInstance` lets APGameInfo.ApplyGrant
// reach us via `class'APHUDToast'.static.GetInstance()` regardless of whether
// it's the per-level GameInfo or a post-save-load instance with no spawn ref.
//
// Queue: simple parallel arrays (UScript has no nice struct vec). When full,
// drops the OLDEST toast to make room for a new one — newer info matters more
// during a resync flood. Entries decay over `TOAST_DURATION` then auto-remove.
class APHUDToast extends HProp;

const MAX_QUEUE = 8;
const TOAST_DURATION = 5.0;
const TICK_INTERVAL = 0.1;

var string ToastText[8];
var float ToastRemaining[8];
var int ToastCount;
var bool bRegisteredWithHUD;

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
    if (default.LatestInstance == self)
    {
        default.LatestInstance = None;
    }
    Super.Destroyed();
}

// Try to register with the live HPHud. May fail on early ticks before harry
// is fully spawned; Timer retries until success.
function bool TryRegisterWithHUD()
{
    local harry h;
    local HPHud hud;

    if (bRegisteredWithHUD) return True;
    h = harry(Level.PlayerHarryActor);
    if (h == None) return False;
    hud = HPHud(h.myHUD);
    if (hud == None) return False;

    hud.RegisterPickupProp(self);
    bRegisteredWithHUD = True;
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

    if (!bRegisteredWithHUD)
    {
        TryRegisterWithHUD();
    }

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

    if (ToastCount <= 0) return;
    if (C == None) return;

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

defaultproperties
{
    bHidden=True
    DrawType=DT_None
    bCollideActors=False
    bCollideWorld=False
    bBlockActors=False
    bBlockPlayers=False
    Physics=PHYS_None
    bGameRelevant=True
}

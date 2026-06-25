//=============================================================================
// APFEInGamePage - pause-menu page with a "Return to Hub" button and an
// open-castle goal-progress widget (right-side strip, see Paint).
//
// Recovers from one-way softlocks where Harry has the AP key for a challenge,
// partially clears it, then can't progress while the doors behind him have
// trigger-locked. The button teleports to Entryhall_Hub through harry.LoadLevel,
// the same path the in-world TriggerChangeLevel volumes use, so the level being
// left first commits its persistent-actor state (found secrets, picked-up beans,
// world cards, dropped chest loot) via SavePActors and snapshots persistent NPCs.
// Inventory and quest state still carry over via Travel's bItems flag.
//
// Injection: APCardWatcher.Timer swaps menuBook.InGamePage for an instance of
// this subclass once on first observation. The stock InGamePage is left as a
// hidden orphan window (one-time leak of one UWindow node, harmless).
//
// Visuals: reuses HP2_Menu.Icons.HP2MenuBackToGame so the button shape
// matches the "Resume Game" (BackPageButton) aesthetic. The goal-progress
// widget mirrors the AP-yellow palette of the HUD toast and Tradersanity
// banner so all three AP-info surfaces read as one family.
//
// Unlocked panel: a right-gutter grid of icons for the spells and level keys
// the player has received (column 1 spells, columns 2-3 keys), shown in all AP
// modes. Received items pack top-down in acquisition order with no gaps, so the
// newest spell or key appears at the bottom of its group. All 14 keys share one
// downscaled key sprite (APKeyIcon) that the hover tooltip disambiguates. Glyphs
// are scaled small and centered inside a larger HGameButton, so the icon reads
// small while the whole cell stays hoverable; the FE framework renders each
// button's ToolTipString in the bottom strip.
//
// Button suppression: the button is hidden while a cutscene is active (the HUD
// cutscene/popup flags plus any CutScene actor still bPlaying, which covers the
// level-load opening scene before CAPTURE fires) and while harry's iGameState
// is below 20. The gstate floor only bites the vanilla intro; open-castle loads
// at gstate 180, so the button stays available there. Hiding mid-cutscene stops
// players bailing to the hub before the level has settled. Visibility
// re-evaluates in PreSwitchPage (each menu open) and in Paint (per frame, so a
// cutscene starting with the menu already open is caught); the apply step only
// toggles on a state change.
//=============================================================================

class APFEInGamePage extends FEInGamePage;

// Icon textures for the "Unlocked" panel, imported as P8 masked textures via the
// same magenta chroma-key recipe as APLogoMesh's skins. The source PNGs are
// pre-flattened onto magenta 255,0,255 with the glyph scaled down and centered
// inside a transparent margin, so each icon reads small inside a larger hover
// cell. APKeyIcon is a downscaled copy of HP2_Menu.Icons.HP2SilverCardKey,
// shared by all 14 keys.
#exec Texture Import File=Textures\APSpellAlohomora.png   Name=APSpellAlohomora   COMPRESSION=P8 UPSCALE=1 Mips=1 Flags=2 MaskedOverride=(R=255,G=0,B=255,A=255) Group=Icons
#exec Texture Import File=Textures\APSpellDiffindo.png    Name=APSpellDiffindo    COMPRESSION=P8 UPSCALE=1 Mips=1 Flags=2 MaskedOverride=(R=255,G=0,B=255,A=255) Group=Icons
#exec Texture Import File=Textures\APSpellFlipendo.png    Name=APSpellFlipendo    COMPRESSION=P8 UPSCALE=1 Mips=1 Flags=2 MaskedOverride=(R=255,G=0,B=255,A=255) Group=Icons
#exec Texture Import File=Textures\APSpellLumos.png       Name=APSpellLumos       COMPRESSION=P8 UPSCALE=1 Mips=1 Flags=2 MaskedOverride=(R=255,G=0,B=255,A=255) Group=Icons
#exec Texture Import File=Textures\APSpellRictusempra.png Name=APSpellRictusempra COMPRESSION=P8 UPSCALE=1 Mips=1 Flags=2 MaskedOverride=(R=255,G=0,B=255,A=255) Group=Icons
#exec Texture Import File=Textures\APSpellSkurge.png      Name=APSpellSkurge      COMPRESSION=P8 UPSCALE=1 Mips=1 Flags=2 MaskedOverride=(R=255,G=0,B=255,A=255) Group=Icons
#exec Texture Import File=Textures\APSpellSpongify.png    Name=APSpellSpongify    COMPRESSION=P8 UPSCALE=1 Mips=1 Flags=2 MaskedOverride=(R=255,G=0,B=255,A=255) Group=Icons
#exec Texture Import File=Textures\APKeyIcon.png         Name=APKeyIcon         COMPRESSION=P8 UPSCALE=1 Mips=1 Flags=2 MaskedOverride=(R=255,G=0,B=255,A=255) Group=Icons

var HGameButton HomeButton;
var Texture textureHomeNorm;
var Texture textureHomeRO;
var bool bHomeHideApplied;

// "Unlocked" panel. SpellSlot/KeySlot are fixed row positions (spells down
// column 1, keys filling the 2-wide block in columns 2-3). Received items are
// assigned into the slots packed top-down in acquisition order, so a group
// fills with no gaps and the newest item lands at the bottom. The texture and
// name caches are indexed by spell/key index. The order sequences and counter
// are class-default so the packing order survives panel rebuilds and level
// transitions within a session (instance arrays reset per rebuild). The Last*
// counts gate slot reassignment to when the received set actually grows.
var HGameButton SpellSlot[7];
var HGameButton KeySlot[14];
var Texture textureKeyIcon;
var Texture spellTexCache[7];
var string spellNameCache[7];
var string keyNameCache[14];
var int SpellOrderSeq[7];
var int KeyOrderSeq[14];
var int UnlockedOrderCounter;
var int LastSpellShownCount;
var int LastKeyShownCount;
var bool bUnlockedIconsBuilt;

function Created()
{
    Super.Created();

    if (textureHomeNorm == None)
    {
        textureHomeNorm = Texture(DynamicLoadObject("HP2_Menu.Icons.HP2MenuBackToGame", Class'Texture'));
        textureHomeRO   = Texture(DynamicLoadObject("HP2_Menu.Icons.HP2MenuBackToGameWet", Class'WetTexture'));
    }

    // AT_Center with raw x=296 puts the 48x48 button at canvas-center x=320
    // (the Folio Magi column); y=338 lands it in the bottom button row's empty
    // middle column, alongside Quit/Input/SoundVideo/BackPage.
    HomeButton = HGameButton(CreateAlignedControl(Class'HGameButton', 296.0, 338.0, 48.0, 48.0, , AT_Center));
    HomeButton.ToolTipString = "Return to Entry Hall";
    HomeButton.UpTexture     = textureHomeNorm;
    HomeButton.OverTexture   = textureHomeNorm;
    HomeButton.DownTexture   = textureHomeNorm;
    HomeButton.DownSound     = soundBottomClick;

    BuildUnlockedPanel();
}

// Open-castle goal-progress widget — 5-row mirror of the client /progress
// command, drawn in the empty right-side strip of the pause menu so the
// player can check goal status without alt-tabbing. Vanilla-mode seeds and
// pre-GOALCFG state short-circuit before draw (see DrawGoalProgressPanel).
function Paint(Canvas C, float X, float Y)
{
    Super.Paint(C, X, Y);
    ApplyHomeButtonVisibility();
    DrawGoalProgressPanel(C);
    ApplyUnlockedIconVisibility();
    DrawUnlockedPanel(C);
}

function DrawGoalProgressPanel(Canvas C)
{
    local float fScaleFactor, hScale;
    local Font fontSave, rowFont, headerFont;
    local Color colorSave, colorWhite, colorYellow, colorGreen, colorShadow;
    local int styleSave;
    local harry h;
    local int xLeft, yLine, lineH;
    local int cards, spells, levels, duels, quid;
    local int cardsNeed, spellsNeed, levelsNeed, duelsNeed, quidNeed;

    if (class'APModeDetector'.default.bOpenCastleMode == 0) return;
    if (C == None || Root == None || Root.Console == None) return;
    if (Root.Console.Viewport == None || Root.Console.Viewport.Actor == None) return;

    h = harry(Root.Console.Viewport.Actor);
    if (h == None || h.Player == None) return;

    fScaleFactor = C.SizeX / WinWidth;
    hScale = Class'M212HScale'.Static.UWindowGetHeightScale(Root);
    rowFont    = baseConsole(h.Player.Console).LocalBigFont;
    headerFont = baseConsole(h.Player.Console).LocalBigFont;

    // Archipelago-yellow for in-progress, green for completed, white for header
    // black shadow throughout. Yellow matches the HUD toast / vendor banner so
    // all three AP-info surfaces read as one family.
    colorWhite.R = 255; colorWhite.G = 255; colorWhite.B = 255;
    colorYellow.R = 255; colorYellow.G = 220; colorYellow.B = 100;
    colorGreen.R  =  60; colorGreen.G  = 220; colorGreen.B  =  90;
    colorShadow.R =   0; colorShadow.G =   0; colorShadow.B =   0;

    fontSave  = C.Font;
    colorSave = C.DrawColor;
    styleSave = C.Style;

    // Left strip in 640x480 WinWidth/WinHeight units, x-aligned with the
    // QuitButton (AT_Left x=12) so the panel reads as part of the bottom-left
    // column. yLine moves down with each drawn row; clauses with need==0 are
    // skipped so the panel only shows goals the seed actually rolled.
    xLeft = 12;
    yLine = 150;
    lineH = 26;

    C.Font = headerFont;
    C.SetPos(xLeft * fScaleFactor, yLine * fScaleFactor * hScale);
    C.DrawShadowText("Goal progress:", colorWhite, colorShadow);
    yLine += lineH + 4;

    cardsNeed  = class'APGoalTracker'.default.GoalCards;
    spellsNeed = class'APGoalTracker'.default.GoalSpells;
    levelsNeed = class'APGoalTracker'.default.GoalLevels;
    // GoalDuels / GoalQuidditch are 0/1 enable flags (the win condition is
    // "all duels" / "all matches"), so map an enabled flag to the full set
    // size for the have/need row: 10 duels, 6 Quidditch matches.
    duelsNeed  = class'APGoalTracker'.default.GoalDuels;
    quidNeed   = class'APGoalTracker'.default.GoalQuidditch;
    if (duelsNeed > 0) duelsNeed = 10;
    if (quidNeed  > 0) quidNeed  = 6;

    // Pre-HELLO: GOALCFG hasn't arrived; an early-game pause would otherwise
    // show an empty panel under the header.
    if (cardsNeed == 0 && spellsNeed == 0 && levelsNeed == 0
        && duelsNeed == 0 && quidNeed == 0)
    {
        C.Font = rowFont;
        C.SetPos(xLeft * fScaleFactor, yLine * fScaleFactor * hScale);
        C.DrawShadowText("waiting on AP", colorYellow, colorShadow);
        C.Font = fontSave;
        C.DrawColor = colorSave;
        C.Style = styleSave;
        return;
    }

    cards  = class'APGoalTracker'.static.GetOwnedCardCount();
    spells = class'APGoalTracker'.static.GetGrantedSpellCount();
    levels = class'APGoalTracker'.static.GetCheckedLevelObjectiveCount();
    duels  = class'APGoalTracker'.static.GetCheckedDuelCount();
    quid   = class'APGoalTracker'.static.GetCheckedQuidditchMatchCount();

    C.Font = rowFont;
    if (cardsNeed  > 0) { DrawProgressRow(C, fScaleFactor, hScale, xLeft, yLine, "Cards",     cards,  cardsNeed,  colorYellow, colorGreen, colorShadow); yLine += lineH; }
    if (spellsNeed > 0) { DrawProgressRow(C, fScaleFactor, hScale, xLeft, yLine, "Spells",    spells, spellsNeed, colorYellow, colorGreen, colorShadow); yLine += lineH; }
    if (levelsNeed > 0) { DrawProgressRow(C, fScaleFactor, hScale, xLeft, yLine, "Levels",    levels, levelsNeed, colorYellow, colorGreen, colorShadow); yLine += lineH; }
    if (duelsNeed  > 0) { DrawProgressRow(C, fScaleFactor, hScale, xLeft, yLine, "Duels",     duels,  duelsNeed,  colorYellow, colorGreen, colorShadow); yLine += lineH; }
    if (quidNeed   > 0) { DrawProgressRow(C, fScaleFactor, hScale, xLeft, yLine, "Quidditch", quid,   quidNeed,   colorYellow, colorGreen, colorShadow); yLine += lineH; }

    // Footer names the endpoint, shown only once every clause is satisfied and
    // the Great Hall has opened. Hidden until then so the panel reads as pure
    // clause progress and the endpoint appears only when it is the next step.
    if (class'APCardWatcher'.default.WasGoalUnlocked == 1)
    {
        yLine += 6;
        C.SetPos(xLeft * fScaleFactor, yLine * fScaleFactor * hScale);
        C.DrawShadowText("Great Hall open - go finish!", colorGreen, colorShadow);
    }

    C.Font = fontSave;
    C.DrawColor = colorSave;
    C.Style = styleSave;
}

function DrawProgressRow(Canvas C, float fScaleFactor, float hScale, int x, int y,
    string label, int have, int need, Color colWaiting, Color colDone, Color colS)
{
    local string row;
    local Color colT;
    if (have >= need) colT = colDone;
    else colT = colWaiting;
    row = label @ string(have) $ "/" $ string(need);
    C.SetPos(x * fScaleFactor, y * fScaleFactor * hScale);
    C.DrawShadowText(row, colT, colS);
}

// Creates the fixed slot buttons once, hidden and without art. Spell slots run
// down column 1; key slots fill the 2-wide block (columns 2-3) left-to-right,
// top-to-bottom. Item textures and names are cached here by item index and are
// assigned to slots later, in acquisition order, by ApplyUnlockedIconVisibility.
// Coordinates are virtual 640x480 units. The slots are APUnlockedSlotButtons,
// which pin WinLeft to that raw design x and so skip the "Menu Centering" 4:3
// correction, matching the canvas-drawn DrawGoalProgressPanel on the left.
function BuildUnlockedPanel()
{
    local int i;
    local float keyX, keyY;
    local APCardWatcher w;

    if (bUnlockedIconsBuilt) return;
    bUnlockedIconsBuilt = True;

    textureKeyIcon = Texture(DynamicLoadObject("HPArchipelago.Icons.APKeyIcon", Class'Texture'));
    w = class'APCardWatcher'.static.GetLatest();

    for (i = 0; i < 7; i++)
    {
        spellTexCache[i] = SpellIconTexture(i);
        if (w != None) spellNameCache[i] = w.SpellNames[i];
        SpellSlot[i] = HGameButton(CreateControl(Class'APUnlockedSlotButton', 508.0, 138.0 + i * 27.0, 32.0, 32.0));
        SpellSlot[i].DownSound = None;
        SpellSlot[i].HideWindow();
    }

    for (i = 0; i < 14; i++)
    {
        if ((i % 2) == 0) keyX = 556.0;
        else keyX = 588.0;
        keyY = 138.0 + (i / 2) * 27.0;
        if (w != None) keyNameCache[i] = w.BlockerKeyNames[i];
        KeySlot[i] = HGameButton(CreateControl(Class'APUnlockedSlotButton', keyX, keyY, 32.0, 32.0));
        KeySlot[i].DownSound = None;
        KeySlot[i].HideWindow();
    }
}

// Skins a slot with an item's icon and name and shows it.
function AssignSlot(HGameButton btn, Texture tex, string nm)
{
    if (btn == None) return;
    btn.UpTexture     = tex;
    btn.OverTexture   = tex;
    btn.DownTexture   = tex;
    btn.DownSound     = None;
    btn.ToolTipString = nm;
    btn.ShowWindow();
}

// Imported per-spell icon (HPArchipelago.Icons.APSpell*). The stock packages
// have no clean per-spell icon, only procedural wet gesture textures, so the
// poptracker art is imported instead.
function Texture SpellIconTexture(int i)
{
    return Texture(DynamicLoadObject("HPArchipelago.Icons." $ SpellPngName(i), Class'Texture'));
}

function string SpellPngName(int i)
{
    switch (i)
    {
        case 0: return "APSpellAlohomora";
        case 1: return "APSpellDiffindo";
        case 2: return "APSpellFlipendo";
        case 3: return "APSpellLumos";
        case 4: return "APSpellRictusempra";
        case 5: return "APSpellSkurge";
        case 6: return "APSpellSpongify";
    }
    return "";
}

// Stamps acquisition order onto each newly received item (class-default, so the
// order survives panel rebuilds within a session) and packs received items into
// the slots: an item takes the row equal to how many received items in its group
// have an earlier sequence, so the group fills top-down with no gaps and the
// newest item sits at the bottom. Items are only ever added, so reassigning only
// when a count grows keeps the layout correct without per-frame churn. A paused
// menu still updates because Paint calls this every frame.
function ApplyUnlockedIconVisibility()
{
    local int i, j, rank, sCount, kCount;

    for (i = 0; i < 7; i++)
        if (class'APGoalTracker'.static.IsSpellGranted(i) && default.SpellOrderSeq[i] == 0)
        {
            default.UnlockedOrderCounter = default.UnlockedOrderCounter + 1;
            default.SpellOrderSeq[i] = default.UnlockedOrderCounter;
        }
    for (i = 0; i < 14; i++)
        if (class'APGoalTracker'.static.IsBlockerKeyGranted(i) && default.KeyOrderSeq[i] == 0)
        {
            default.UnlockedOrderCounter = default.UnlockedOrderCounter + 1;
            default.KeyOrderSeq[i] = default.UnlockedOrderCounter;
        }

    sCount = 0;
    for (i = 0; i < 7; i++)
        if (class'APGoalTracker'.static.IsSpellGranted(i)) sCount++;
    kCount = 0;
    for (i = 0; i < 14; i++)
        if (class'APGoalTracker'.static.IsBlockerKeyGranted(i)) kCount++;

    if (sCount == LastSpellShownCount && kCount == LastKeyShownCount) return;
    LastSpellShownCount = sCount;
    LastKeyShownCount = kCount;

    for (i = 0; i < 7; i++)
    {
        if (!class'APGoalTracker'.static.IsSpellGranted(i)) continue;
        rank = 0;
        for (j = 0; j < 7; j++)
            if (j != i && class'APGoalTracker'.static.IsSpellGranted(j)
                && default.SpellOrderSeq[j] < default.SpellOrderSeq[i]) rank++;
        AssignSlot(SpellSlot[rank], spellTexCache[i], spellNameCache[i]);
    }
    for (i = sCount; i < 7; i++)
        if (SpellSlot[i] != None) SpellSlot[i].HideWindow();

    for (i = 0; i < 14; i++)
    {
        if (!class'APGoalTracker'.static.IsBlockerKeyGranted(i)) continue;
        rank = 0;
        for (j = 0; j < 14; j++)
            if (j != i && class'APGoalTracker'.static.IsBlockerKeyGranted(j)
                && default.KeyOrderSeq[j] < default.KeyOrderSeq[i]) rank++;
        AssignSlot(KeySlot[rank], textureKeyIcon, keyNameCache[i]);
    }
    for (i = kCount; i < 14; i++)
        if (KeySlot[i] != None) KeySlot[i].HideWindow();
}

// Right-gutter frame text: the "Unlocked" title centered over all three icon
// columns, and the "Spells" / "Keys" subheaders centered over their column(s).
// Drawn manually with the same scale convention as DrawGoalProgressPanel
// (fScaleFactor on x, fScaleFactor*hScale on y) so the text lines up over the
// framework-positioned columns. No mode gate: the panel shows in every AP mode,
// and an absent category simply leaves its column empty under the subheader.
function DrawUnlockedPanel(Canvas C)
{
    local float fScaleFactor, hScale;
    local float spellC, keysC, unlockedC;
    local Font fontSave, bigFont;
    local Color colorSave, colorWhite, colorShadow;
    local int styleSave;
    local harry h;

    if (C == None || Root == None || Root.Console == None) return;
    if (Root.Console.Viewport == None || Root.Console.Viewport.Actor == None) return;
    h = harry(Root.Console.Viewport.Actor);
    if (h == None || h.Player == None) return;

    fScaleFactor = C.SizeX / WinWidth;
    hScale = Class'M212HScale'.Static.UWindowGetHeightScale(Root);
    bigFont = baseConsole(h.Player.Console).LocalBigFont;

    colorWhite.R = 255; colorWhite.G = 255; colorWhite.B = 255;
    colorShadow.R =   0; colorShadow.G =   0; colorShadow.B =   0;

    fontSave  = C.Font;
    colorSave = C.DrawColor;
    styleSave = C.Style;

    // Center each label over its column(s) using the buttons' live WinLeft/
    // WinWidth. APUnlockedSlotButton pins WinLeft to the raw design x (no Menu
    // Centering correction), so the labels track the icons and share the panel's
    // pure-proportional, slider-immune placement. "Spells" centers on the spell
    // column, "Keys" on the midpoint of the two key columns, "Unlocked" on the
    // midpoint of the spell and right-key columns. Falls back to design-space
    // centers if the slots are not built yet.
    if (SpellSlot[0] != None && KeySlot[0] != None && KeySlot[1] != None)
    {
        spellC    = SpellSlot[0].WinLeft + SpellSlot[0].WinWidth * 0.5;
        keysC     = (KeySlot[0].WinLeft + KeySlot[0].WinWidth * 0.5
                   + KeySlot[1].WinLeft + KeySlot[1].WinWidth * 0.5) * 0.5;
        unlockedC = (spellC + KeySlot[1].WinLeft + KeySlot[1].WinWidth * 0.5) * 0.5;
    }
    else
    {
        spellC    = 524.0;
        keysC     = 588.0;
        unlockedC = 564.0;
    }

    C.Font = bigFont;
    DrawCenteredShadowText(C, "Unlocked", unlockedC,  96.0, fScaleFactor, hScale, colorWhite, colorShadow);
    DrawCenteredShadowText(C, "Spells",   spellC,    120.0, fScaleFactor, hScale, colorWhite, colorShadow);
    DrawCenteredShadowText(C, "Keys",     keysC,     120.0, fScaleFactor, hScale, colorWhite, colorShadow);

    C.Font      = fontSave;
    C.DrawColor = colorSave;
    C.Style     = styleSave;
}

// Draws shadowed text horizontally centered on centerX. centerX is a framework
// x (control WinLeft space) that maps to screen by * fScaleFactor, the same as
// the Y maps by * fScaleFactor * hScale. Uses the current C.Font to measure, so
// set the font before calling.
function DrawCenteredShadowText(Canvas C, string s, float centerX, float y,
    float fScaleFactor, float hScale, Color colText, Color colShadow)
{
    local float tw, th;
    C.TextSize(s, tw, th);
    C.SetPos(centerX * fScaleFactor - tw / 2.0, y * fScaleFactor * hScale);
    C.DrawShadowText(s, colText, colShadow);
}

function PreSwitchPage()
{
    Super.PreSwitchPage();
    ApplyHomeButtonVisibility();
    ApplyUnlockedIconVisibility();
}

// Hidden during the vanilla intro (iGameState < 20) and during any active
// cutscene. The cutscene check is two-tier: the HUD flags only flip after a
// cutscene issues CAPTURE, so a CutScene actor still bPlaying covers the
// level-load opening scene before that. Reuses APGameInfo's iterator so
// "active cutscene" has one definition.
function bool ShouldHideHomeButton()
{
    local harry h;
    local HPHud hud;
    local string ignored;

    if (Root == None || Root.Console == None) return False;
    if (Root.Console.Viewport == None) return False;
    h = harry(Root.Console.Viewport.Actor);
    if (h == None) return False;

    if (h.iGameState < 20) return True;

    hud = HPHud(h.myHUD);
    if (hud != None && hud.IsCutSceneOrPopupInProgress()) return True;
    if (class'APGameInfo'.static.HasActiveCutScene(h, ignored)) return True;

    return False;
}

// Only calls Show/HideWindow on a transition: Paint runs every frame and a
// relayout per frame is wasteful.
function ApplyHomeButtonVisibility()
{
    local bool bHide;

    if (HomeButton == None) return;
    bHide = ShouldHideHomeButton();
    if (bHide == bHomeHideApplied) return;
    if (bHide) HomeButton.HideWindow();
    else HomeButton.ShowWindow();
    bHomeHideApplied = bHide;
}

function Notify(UWindowDialogControl C, byte E)
{
    if (C == HomeButton)
    {
        if (E == DE_Click)
        {
            TeleportToHub();
            return;
        }
        if (E == DE_MouseEnter)
        {
            SetRollover(HomeButton, textureHomeRO, soundBottomRO, True);
            return;
        }
        if (E == DE_MouseLeave)
        {
            ClearRollover();
            return;
        }
    }
    Super.Notify(C, E);
}

function TeleportToHub()
{
    local HPConsole console;
    local harry h;
    local APCardWatcher w;
    local APLocationScanner ls;

    if (book == None || book.Root == None || book.Root.Console == None)
    {
        Log("[Archipelago] APFEInGamePage.TeleportToHub: missing book/Root/Console; aborting");
        return;
    }
    console = HPConsole(book.Root.Console);
    if (console == None)
    {
        Log("[Archipelago] APFEInGamePage.TeleportToHub: Root.Console is not HPConsole; aborting");
        return;
    }
    if (console.Viewport != None)
        h = harry(console.Viewport.Actor);
    // Close the book before changing levels: it closes naturally as the level
    // tears down, but closing it explicitly first avoids the pause overlay
    // flickering during the travel transition.
    FEBook(book).CloseBook();
    // Tell APCardWatcher.CheckExitedLevelObjective this exit is a menu-bail,
    // not a Mechanism-C completion, so leaving Willow/Slytherin this way does
    // not falsely credit the clause-3 objective. Keyed to the level being left
    // so a later genuine completion of the same level still counts.
    if (h != None)
        class'APCardWatcher'.default.MenuReturnFromLevelCaps =
            Caps(string(h.Level.Outer.Name));
    // Mirror the vanilla challenge exits (entrance door, time-up, death-reload),
    // which end the challenge before leaving. This button travels straight through
    // harry.LoadLevel, so without this the bPersistent ChallengeScoreManager rides
    // to the hub still in ChallengeInProgress and the next entry resumes the old
    // timer instead of restarting it. Routed through the watcher because this menu
    // page is not an Actor and cannot iterate AllActors.
    w = class'APCardWatcher'.static.GetLatest();
    if (w != None)
    {
        ls = class'APLocationScanner'.static.GetInstance(w);
        if (ls != None) ls.EndBailedSpellChallenge();
    }
    // Bailing from stateDead via R2EH enters the hub still dead; suppress
    // the first post-travel stateDead so it is treated as the bail-out,
    // not an organic death. 40 ticks ~ 10s at 0.25s/tick mirrors
    // APCardWatcher.DEATH_SUPPRESS_TIMEOUT_TICKS (M212 consts are not
    // accessible cross-class, so the literal is used).
    class'APCardWatcher'.default.bSuppressNextDeathBroadcast = 1;
    class'APCardWatcher'.default.DeathSuppressTicksLeft = 40;
    // Leave through harry.LoadLevel (the path TriggerChangeLevel volumes use)
    // so the bailed level commits its persistent-actor state first: SavePActors
    // saves found secrets, picked-up beans, world cards and dropped chest loot
    // that a raw ChangeLevel would discard. LoadLevel still travels bItems=True.
    if (h != None)
    {
        Log("[Archipelago] APFEInGamePage.TeleportToHub: harry.LoadLevel('Entryhall_Hub')");
        h.LoadLevel("Entryhall_Hub");
    }
    else
    {
        Log("[Archipelago] APFEInGamePage.TeleportToHub: no harry; ChangeLevel('Entryhall_Hub', True)");
        console.ChangeLevel("Entryhall_Hub", True);
    }
}

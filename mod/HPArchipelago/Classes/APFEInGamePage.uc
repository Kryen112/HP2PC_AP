//=============================================================================
// APFEInGamePage - pause-menu page with a "Return to Hub" button and an
// open-castle goal-progress widget (right-side strip, see Paint).
//
// Recovers from one-way softlocks where Harry has the AP key for a challenge,
// partially clears it, then can't progress while the doors behind him have
// trigger-locked. The button teleports to Entryhall_Hub via the same code
// path harry.uc uses for normal level transitions, preserving inventory and
// quest state via Travel's bItems flag.
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
// Spell-challenge suppression: in vanilla mode (APCardWatcher.bOpenCastleMode
// == 0), the button is hidden on the four spell-challenge levels
// (Ch1Rictusempra, Ch2Skurge, Ch3Diffindo, Ch4Spongify) so the player cannot
// bail out of a mandatory story-progression challenge for free. Those levels
// are documented as terminal (APCardWatcher.uc CheckExitedLevelObjective) -
// a failed run restarts in place via EventTimeUpRestart, so the soft-lock-
// recovery purpose of the button does not apply there. Open-castle mode
// keeps the button available everywhere. PreSwitchPage runs each time the
// pause menu opens, so the hide/show re-evaluates across level transitions.
//=============================================================================

class APFEInGamePage extends FEInGamePage;

var HGameButton HomeButton;
var Texture textureHomeNorm;
var Texture textureHomeRO;

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
}

// Open-castle goal-progress widget — 5-row mirror of the client /progress
// command, drawn in the empty right-side strip of the pause menu so the
// player can check goal status without alt-tabbing. Vanilla-mode seeds and
// pre-GOALCFG state short-circuit before draw (see DrawGoalProgressPanel).
function Paint(Canvas C, float X, float Y)
{
    Super.Paint(C, X, Y);
    DrawGoalProgressPanel(C);
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

    if (class'APCardWatcher'.default.bOpenCastleMode == 0) return;
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

    cardsNeed  = class'APCardWatcher'.default.GoalCards;
    spellsNeed = class'APCardWatcher'.default.GoalSpells;
    levelsNeed = class'APCardWatcher'.default.GoalLevels;
    duelsNeed  = class'APCardWatcher'.default.GoalDuels;
    quidNeed   = class'APCardWatcher'.default.GoalQuidditch;

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

    cards  = class'APCardWatcher'.static.GetOwnedCardCount();
    spells = class'APCardWatcher'.static.GetGrantedSpellCount();
    levels = class'APCardWatcher'.static.GetCheckedLevelObjectiveCount();
    duels  = class'APCardWatcher'.static.GetCheckedDuelCount();
    quid   = class'APCardWatcher'.static.GetCheckedQuidditchMatchCount();

    C.Font = rowFont;
    if (cardsNeed  > 0) { DrawProgressRow(C, fScaleFactor, hScale, xLeft, yLine, "Cards",     cards,  cardsNeed,  colorYellow, colorGreen, colorShadow); yLine += lineH; }
    if (spellsNeed > 0) { DrawProgressRow(C, fScaleFactor, hScale, xLeft, yLine, "Spells",    spells, spellsNeed, colorYellow, colorGreen, colorShadow); yLine += lineH; }
    if (levelsNeed > 0) { DrawProgressRow(C, fScaleFactor, hScale, xLeft, yLine, "Levels",    levels, levelsNeed, colorYellow, colorGreen, colorShadow); yLine += lineH; }
    if (duelsNeed  > 0) { DrawProgressRow(C, fScaleFactor, hScale, xLeft, yLine, "Duels",     duels,  duelsNeed,  colorYellow, colorGreen, colorShadow); yLine += lineH; }
    if (quidNeed   > 0) { DrawProgressRow(C, fScaleFactor, hScale, xLeft, yLine, "Quidditch", quid,   quidNeed,   colorYellow, colorGreen, colorShadow); }

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

function PreSwitchPage()
{
    local Actor playerActor;
    local string curLevelCaps;

    Super.PreSwitchPage();

    if (HomeButton == None) return;
    if (book == None || book.Root == None || book.Root.Console == None) return;
    if (book.Root.Console.Viewport == None || book.Root.Console.Viewport.Actor == None) return;

    playerActor = book.Root.Console.Viewport.Actor;
    curLevelCaps = Caps(string(playerActor.Level.Outer.Name));

    // Commented because softlocks could still happen due to bugs, might be reimplemented later
    // if (class'APCardWatcher'.default.bOpenCastleMode == 0
    //     && (curLevelCaps == "CH1RICTUSEMPRA" || curLevelCaps == "CH2SKURGE"
    //         || curLevelCaps == "CH3DIFFINDO"  || curLevelCaps == "CH4SPONGIFY"))
    // {
    //     HomeButton.HideWindow();
    // }
    // else
    // {
    //     HomeButton.ShowWindow();
    // }
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
    // Close the book before changing levels: it closes naturally as the level
    // tears down, but closing it explicitly first avoids the pause overlay
    // flickering during the travel transition.
    FEBook(book).CloseBook();
    // Tell APCardWatcher.CheckExitedLevelObjective this exit is a menu-bail,
    // not a Mechanism-C completion, so leaving Willow/Slytherin this way does
    // not falsely credit the clause-3 objective. Keyed to the level being left
    // so a later genuine completion of the same level still counts.
    if (console.Viewport != None && console.Viewport.Actor != None)
        class'APCardWatcher'.default.MenuReturnFromLevelCaps =
            Caps(string(console.Viewport.Actor.Level.Outer.Name));
    // Bailing from stateDead via R2EH enters the hub still dead; suppress
    // the first post-travel stateDead so it is treated as the bail-out,
    // not an organic death. 40 ticks ~ 10s at 0.25s/tick mirrors
    // APCardWatcher.DEATH_SUPPRESS_TIMEOUT_TICKS (M212 consts are not
    // accessible cross-class, so the literal is used).
    class'APCardWatcher'.default.bSuppressNextDeathBroadcast = 1;
    class'APCardWatcher'.default.DeathSuppressTicksLeft = 40;
    Log("[Archipelago] APFEInGamePage.TeleportToHub: ChangeLevel('Entryhall_Hub', True)");
    console.ChangeLevel("Entryhall_Hub", True);
}

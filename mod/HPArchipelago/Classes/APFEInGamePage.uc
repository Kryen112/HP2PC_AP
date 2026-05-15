//=============================================================================
// APFEInGamePage - pause-menu page with a "Return to Hub" button.
//
// Recovers from one-way softlocks where Harry has the AP key for a challenge
// (e.g. Spongify), partially clears it, then can't progress AND the doors
// behind him have trigger-locked - so there's no way out without abandoning
// save progress. The button teleports to Entryhall_Hub via the same code path
// harry.uc uses for normal level transitions, preserving inventory + quest
// state via Travel's bItems flag.
//
// Injection: APCardWatcher.Timer swaps menuBook.InGamePage for an instance of
// this subclass once on first observation. The stock InGamePage is left as a
// hidden orphan window - one-time leak of ~one UWindow node, harmless.
//
// Visuals: re-uses HP2_Menu.Icons.HP2MenuBackToGame so the button shape
// matches the "Resume Game" (BackPageButton) aesthetic.
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

    // Centered horizontally under the Folio Magi (folio at x=252 w=136 has its
    // center at canvas x=320; folio bottom is y=302). AT_Center alignment with
    // raw x=296 puts the 48x48 button at canvas-center x=320 - same column as
    // the folio, y=338 puts it in the bottom button row alongside the existing
    // Quit/Input/SoundVideo/BackPage entries (whose middle column is empty).
    HomeButton = HGameButton(CreateAlignedControl(Class'HGameButton', 296.0, 338.0, 48.0, 48.0, , AT_Center));
    HomeButton.ToolTipString = "Return to Entry Hall";
    HomeButton.UpTexture     = textureHomeNorm;
    HomeButton.OverTexture   = textureHomeNorm;
    HomeButton.DownTexture   = textureHomeNorm;
    HomeButton.DownSound     = soundBottomClick;
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
    // Close the book before changing levels - mirrors how the level-load path
    // in FEBook (line 436) hands off to ChangeLevel: the book closes naturally
    // as the level tears down, but closing it explicitly first avoids the
    // pause overlay flickering during the travel transition.
    FEBook(book).CloseBook();
    // Tell APCardWatcher.CheckExitedLevelObjective this exit is a menu-bail,
    // not a Mechanism-C completion, so leaving Willow/Slytherin this way does
    // not falsely credit the clause-3 objective. Keyed to the level being left
    // so a later genuine completion of the same level still counts.
    if (console.Viewport != None && console.Viewport.Actor != None)
        class'APCardWatcher'.default.MenuReturnFromLevelCaps =
            Caps(string(console.Viewport.Actor.Level.Outer.Name));
    Log("[Archipelago] APFEInGamePage.TeleportToHub: ChangeLevel('Entryhall_Hub', True)");
    console.ChangeLevel("Entryhall_Hub", True);
}

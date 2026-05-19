//=============================================================================
// APFEInGamePage - pause-menu page with a "Return to Hub" button.
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
    Log("[Archipelago] APFEInGamePage.TeleportToHub: ChangeLevel('Entryhall_Hub', True)");
    console.ChangeLevel("Entryhall_Hub", True);
}

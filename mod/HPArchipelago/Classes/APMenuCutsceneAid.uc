// Engine/UI-state aid, not AP card logic: inject the mod's pause-menu page and
// recover from save-restored cutscene softlocks. Pure static helpers operating
// on the passed harry + the engine's menu / cutscene / HUD actors; no persistent
// state. The watcher's DriveTick / Snapshot call these instead of owning them.
class APMenuCutsceneAid extends Object;

// One-shot menu patch: replace menuBook.InGamePage with an APFEInGamePage
// instance so the pause menu gets the Return-to-Hub button. Self-healing -
// detects the stock subclass via class-cast, so if a fresh menuBook ever
// appears in this process we re-inject. The previous (stock) InGamePage is
// left as a hidden orphan child of menuBook; this is a one-instance leak per
// inject, acceptable because the inject runs at most a handful of times per
// process lifetime (usually exactly once).
static function EnsureHomeMenuInjected(harry h)
{
    local HPConsole console;
    local FEBook book;
    local APFEInGamePage newPage;

    if (h == None || h.Player == None)
    {
        return;
    }
    console = HPConsole(h.Player.Console);
    if (console == None || console.menuBook == None)
    {
        return;
    }
    book = console.menuBook;
    if (book.InGamePage == None)
    {
        return;
    }
    if (APFEInGamePage(book.InGamePage) != None)
    {
        return;
    }
    newPage = APFEInGamePage(book.CreateWindow(Class'APFEInGamePage', 0.0, 0.0, book.WinWidth, book.WinHeight));
    if (newPage == None)
    {
        Log("[Archipelago] APMenuCutsceneAid.EnsureHomeMenuInjected: CreateWindow returned None; aborting");
        return;
    }
    newPage.book = book;
    newPage.HideWindow();
    book.InGamePage = newPage;
    Log("[Archipelago] APMenuCutsceneAid.EnsureHomeMenuInjected: replaced menuBook.InGamePage with APFEInGamePage");
}

// Post-snapshot recovery for two related save/delta-cache corruptions that
// leave the player softlocked (forced black screen, frozen input, hidden HUD)
// on a level the engine restores from a persistent cache:
//
// 1) CutScene actor stuck in (bPlaying=False, bFastForwarding=True) in
//    UnrealScript state 'FastForwarding'. This pair is unreachable via the
//    normal CutScene state machine (FastForwarding clears bFastForwarding
//    before GotoState('Finished'), which sets bPlaying=False). It is baked
//    into Save0.usa when a victory cutscene's own `ChangeLevel` fires from
//    inside its fast-forward tick (Aragog/Basilisk wrap-up) and the
//    FastForwarding->Finished latent transition does not survive the save
//    round-trip; it re-appears on every load of that save.
//
// 2) CutSceneManager.bPopupBorderActive (or bBothBordersActive) stuck True
//    with no CutScene bPlaying. The manager flag is set by SlideIn's
//    BeginState (CutSceneManager.uc:177-188) on every StartCutScene call;
//    it's cleared only when SlideOut completes inside RenderHudItemManager
//    (line 213-216), which requires an EndCutScene to trigger SlideOut. If
//    the player exits the level mid-Hold (level-entry cutscene running, no
//    text-clear or EnablePlayerInput fired yet), the delta-cache write saves
//    Hold-state and on re-entry no fresh cutscene slides it out.
//
// The actual unfreeze (clear bForceBlackScreen, re-enable input, end the
// manager cutscene, unmute) is performed by HPConsole.HandleFastForward
// (HPConsole.uc:694-726), gated on HPConsole.bFastForwarding. harry only
// re-arms that console flag post-load when the restored save had
// managerCutScene.bShowFF==True (harry.uc:1025-1028) - true on a boss-kill
// direct travel, false on a player save+quit from the still-broken hub. So
// clearing the FF flag alone unlocks only on the direct-travel path; on the
// save+quit path HandleFastForward never runs and the flag clear heals
// nothing. On a detected corruption signature this asserts the unlocked
// end-state directly (ForceCutsceneUnlock), independent of that chain. Gated
// on actually-detected corruption so normal level-intro captures (which are
// briefly bPlaying=False at the early Snapshot tick) are never disturbed.
static function RecoverStuckCutsceneState(harry h)
{
    local CutScene cs;
    local int playingCount, ffCorruptCount;
    local HPHud hud;

    if (h == None)
    {
        return;
    }

    foreach h.AllActors(class'CutScene', cs)
    {
        if (cs.bPlaying)
        {
            playingCount++;
            continue;
        }
        if (cs.bFastForwarding)
        {
            Log("[Archipelago] APMenuCutsceneAid.RecoverStuckCutsceneState: clearing invalid bFastForwarding=True on "
                $ string(cs.Name) $ " (FN='" $ cs.FileName $ "', bPlaying=False) - forcing GotoState('Finished')");
            cs.bFastForwarding = False;
            // Push the actor out of the dead 'FastForwarding' state so a clean
            // save no longer round-trips it. Finished's Begin sets
            // bPlaying=False, deletes threads and idles; bPlayOnce story
            // cutscenes stay Finished, so the already-played wrap-up never
            // replays. The numScriptsPlaying-- in Finished's Begin is inert:
            // the engine only ever writes that class default, never reads it.
            cs.GotoState('Finished');
            ffCorruptCount++;
        }
    }

    if (playingCount > 0)
    {
        if (ffCorruptCount > 0)
        {
            Log("[Archipelago] APMenuCutsceneAid.RecoverStuckCutsceneState: cleared " $ ffCorruptCount
                $ " stale FF flag(s); active CutScene(s) present (count=" $ playingCount
                $ "), leaving player capture + CutSceneManager alone");
        }
        return;
    }

    if (ffCorruptCount > 0)
    {
        ForceCutsceneUnlock(h, "stuck FastForwarding CutScene (count=" $ ffCorruptCount $ ")");
        return;
    }

    hud = HPHud(h.myHUD);
    if (hud == None || hud.managerCutScene == None)
    {
        return;
    }
    if (!hud.managerCutScene.bPopupBorderActive && !hud.managerCutScene.bBothBordersActive)
    {
        return;
    }

    ForceCutsceneUnlock(h, "CutSceneManager borders up with no CutScene bPlaying"
        $ " (bPopupBorderActive=" $ hud.managerCutScene.bPopupBorderActive
        $ " bBothBordersActive=" $ hud.managerCutScene.bBothBordersActive $ ")");
}

// Assert the post-cutscene unlocked state directly. Does NOT depend on
// HPConsole.HandleFastForward (gated on HPConsole.bFastForwarding, which the
// player save+quit path never re-arms). harry.EnablePlayerInput clears
// bIsCaptured/bKeepStationary, calls HPHud.EndCutScene (manager SlideOut +
// bCutSceneMode/bCutPopupMode clear) and releases captured pawns;
// bForceBlackScreen and the sound mute are the two HandleFastForward-only
// effects, restored here explicitly. myHUD is guarded because
// EnablePlayerInput dereferences it (always set on a possessed gameplay
// harry; the guard only matters in degenerate teardown).
static function ForceCutsceneUnlock(harry h, string reason)
{
    Log("[Archipelago] APMenuCutsceneAid.ForceCutsceneUnlock: " $ reason
        $ " - asserting unlock (clear bForceBlackScreen + EnablePlayerInput + unmute)");
    h.bForceBlackScreen = False;
    if (h.myHUD != None)
    {
        h.EnablePlayerInput();
    }
    h.ConsoleCommand("UNMUTESOUNDS");
}

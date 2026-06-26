// Runtime check detection: the per-tick pollers that observe live game state
// (secrets found, duels/matches won, spell challenges mastered, bosses killed)
// and fire the AP CHECK, plus the gold-card-curtain and stuck-ectoplasm world
// reconciliations and the spell-challenge score-honesty pass. A logic-only
// singleton (GetInstance), per-level (bGameRelevant=False) so the per-visit
// latches (bSawFinalStarThisLevel / bAwardedFinalStarThisLevel) reset with the
// fresh per-level singleton; the genuine-score table, the curtain latch, and the
// challenge-seed flag are class-default and persist for the process. The watcher's
// Timer drives the pollers, passing its IPC singleton and bound HarryRef; the
// dedupe ledger (NonCardLocationChecked) and the StatusItem refs live on
// APCardWatcher and are read cross-class. DeathLink stays in the watcher (its
// state is shared with the watcher's level-exit / drain logic).
class APLocationScanner extends Info;

// Mirror APCardWatcher's id constants (the pollers index its NonCardLocationChecked
// ledger cross-class by apId - LOC_BASE).
const LOC_BASE = 5760000;
const NONCARD_LOC_WINDOW = 2048;

// Process-wide singleton pointer (class-default). Instance copy kept None for
// save-graph hygiene.
var APLocationScanner LatestInstance;

// Spell-challenge score honesty. ChallengeGenuineBest[i] is the player's real best
// end score (the shipped engine seeds nHighScore to par, which would falsely read
// as Mastered); bChallengeGenuineSeeded latches the one-time seed from the
// travel-saved value. Class-default + sticky.
var int ChallengeGenuineBest[4];
var byte bChallengeGenuineSeeded;

// Class-default tracking of which WCn curtain events DropOwnedGoldCardCurtains has
// already fired this session. The Ch6WizardCard curtain movers are TriggerToggle
// and HP2 preserves their state across level exits in a session, so a second fire
// toggles a curtain back closed; this latch keeps it to one fire per WCn.
var byte WCnFiredThisSession[12];

// Per-visit (instance) FinalStar latches. bSawFinalStarThisLevel rises once an
// alive FinalStar is observed in-level; bAwardedFinalStarThisLevel latches the
// credit so the present -> absent (pickup) transition fires the completion exactly
// once per visit. Reset by the fresh per-level singleton.
var byte bSawFinalStarThisLevel;
var byte bAwardedFinalStarThisLevel;

// Found-or-spawned singleton accessor. Lazily spawns one via the caller's context
// on first use of a level. Logic-only (no mesh) so runtime spawn is safe.
static function APLocationScanner GetInstance(Actor ctx)
{
    if (default.LatestInstance != None && !default.LatestInstance.bDeleteMe)
        return default.LatestInstance;
    if (ctx == None) return None;
    return ctx.Spawn(class'APLocationScanner');
}

event PreBeginPlay()
{
    Super.PreBeginPlay();
    // Only default.LatestInstance is the singleton pointer; Spawn seeds the
    // instance copy from the class default, so clear it.
    LatestInstance = None;
    default.LatestInstance = self;
}

// Ch6WizardCard gold-card-id -> curtain mover number (WCn). WC1 = WCBott confirmed
// via Dispatcher13; WC2..WC11 are physical-walking-order best-guess.
static function int WCNumForGoldCardId(int id)
{
    // Gold-card game ids (the Goldcards subset of the card markers' CardLocationId).
    switch (id)
    {
        case 69:  return 1;  // WCBott        (entrance, confirmed)
        case 101: return 2;  // WCDumbledore  (Y=-1264)
        case 41:  return 3;  // WCGriffindor  (Y=-3002)
        case 11:  return 4;  // WCHerpo       (Y=-4224)
        case 48:  return 5;  // WCSlytherin   (Y=-5529, right side)
        case 72:  return 6;  // WCHufflepuff  (Y=-5505, left side)
        case 74:  return 7;  // WCKnightley   (Y=-4733)
        case 15:  return 8;  // WCParacelsus  (Y=-4237, X=-4780)
        case 40:  return 9;  // WCPinkstone   (Y=-1824)
        case 82:  return 10; // WCRavenclaw   (Y=-515)
        case 100: return 11; // WCPotter      (Y=2879, far behind)
    }
    return 0;
}

// Fire the per-card curtain event for each gold card Harry currently owns.
// Iterates the APCardMarker actors in the current level, looks up the WC mover tag
// via WCNumForGoldCardId, fires TriggerEvent(WCn). The curtain movers in
// Ch6WizardCard are TriggerToggle; WCnFiredThisSession keeps each WCn to one fire
// per session so the curtain stays open. No-op outside Ch6WizardCard (no WCn movers).
function DropOwnedGoldCardCurtains()
{
    local APCardMarker marker;
    local int wcN, firedCount;
    local name evtName;
    local APCardWatcher w;

    w = class'APCardWatcher'.static.GetLatest();
    Log("[Archipelago] DropOwnedGoldCardCurtains: entry, siGold=" $ string(w.siGold));
    if (w == None || w.siGold == None) return;

    firedCount = 0;
    foreach AllActors(class'APCardMarker', marker)
    {
        if (marker.CardLocationId <= 0 || marker.CardLocationId > 101) continue;
        if (!w.siGold.IsOwnedByHarry(marker.CardLocationId)) continue;
        wcN = WCNumForGoldCardId(marker.CardLocationId);
        if (wcN <= 0)
        {
            Log("[Archipelago] DropOwnedGoldCardCurtains: id=" $ marker.CardLocationId $ " (" $ string(marker.Class.Name) $ ") owned but no WC mapping");
            continue;
        }
        if (default.WCnFiredThisSession[wcN] == 1)
        {
            Log("[Archipelago] DropOwnedGoldCardCurtains: WC" $ wcN $ " (id " $ marker.CardLocationId $ ") already fired this session, skipping to preserve open state");
            continue;
        }
        evtName = name("WC" $ string(wcN));
        Log("[Archipelago] DropOwnedGoldCardCurtains: id=" $ marker.CardLocationId $ " (" $ string(marker.Class.Name) $ ") owned - firing TriggerEvent(" $ string(evtName) $ ")");
        TriggerEvent(evtName, self, None);
        default.WCnFiredThisSession[wcN] = 1;
        firedCount++;
    }
    Log("[Archipelago] DropOwnedGoldCardCurtains: done - " $ firedCount $ " WCn event(s) fired");
}

// Per-tick poll of SecretAreaMarker actors. When bFound and the marker maps to a
// registered AP location id, fire CHECK_LOCID once (the watcher's class-default
// NonCardLocationChecked dedupes across re-entries; SecretAreaMarker is
// bPersistent so bFound stays True). Markers not in the registry are skipped.
function ScanSecretMarkers(APIPCActor ipc)
{
    local SecretAreaMarker marker;
    local string levelName;
    local int locId;
    local int slot;

    levelName = string(Level.Outer.Name);
    foreach AllActors(class'SecretAreaMarker', marker)
    {
        if (!marker.bFound) continue;
        locId = class'APLocationRegistry'.static.GetSecretLocationId(levelName, string(marker.Name));
        if (locId == 0) continue;
        slot = locId - LOC_BASE;
        if (slot < 0 || slot >= NONCARD_LOC_WINDOW) continue;
        if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) continue;
        class'APCardWatcher'.default.NonCardLocationChecked[slot] = 1;
        Log("[Archipelago] APLocationScanner: secret bFound in " $ levelName
            $ " marker=" $ string(marker.Name) $ " - firing CHECK_LOCID " $ locId);
        if (ipc != None) ipc.SendCheckLocationId(locId);
    }
}

// Per-tick poll of harry.DuelRankHarry. Vanilla increments it by 1 per duel win,
// so at any moment the won ranks are {1..DuelRankHarry-1}. Fire CHECK_LOCID once
// per rank not yet checked. AP id = 5760600 + (rank - 1).
function ScanDuelWins(APIPCActor ipc, harry h)
{
    local int rank, locId, slot;

    if (h == None) return;

    for (rank = 1; rank < h.DuelRankHarry && rank <= 10; rank++)
    {
        locId = 5760600 + (rank - 1);
        slot = locId - LOC_BASE;
        if (slot < 0 || slot >= NONCARD_LOC_WINDOW) continue;
        if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) continue;
        class'APCardWatcher'.default.NonCardLocationChecked[slot] = 1;
        Log("[Archipelago] APLocationScanner: duel rank " $ rank
            $ " won (DuelRankHarry=" $ h.DuelRankHarry
            $ ") - firing CHECK_LOCID " $ locId);
        if (ipc != None) ipc.SendCheckLocationId(locId);
    }
}

// Per-tick poll of harry.quidGameResults[0..5].bWon. Index 5 is the final match.
// AP id = 5760620 + match_index.
function ScanMatchWins(APIPCActor ipc, harry h)
{
    local int i, locId, slot;

    if (h == None) return;

    for (i = 0; i < 6; i++)
    {
        if (!h.quidGameResults[i].bWon) continue;
        locId = 5760620 + i;
        slot = locId - LOC_BASE;
        if (slot < 0 || slot >= NONCARD_LOC_WINDOW) continue;
        if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) continue;
        class'APCardWatcher'.default.NonCardLocationChecked[slot] = 1;
        Log("[Archipelago] APLocationScanner: quidditch match " $ (i + 1)
            $ " won (vs " $ h.quidGameResults[i].Opponent
            $ ") - firing CHECK_LOCID " $ locId);
        if (ipc != None) ipc.SendCheckLocationId(locId);
    }
}

// Keep harry.ChallengeScores[].nHighScore honest against the engine's par-seed.
// Seeds the genuine table once per session from the travel-saved values (max), then
// each tick forces harry's high score back to the captured genuine best so the
// Report Card and ScanChallengeMastery never read the seeded par.
function EnforceGenuineChallengeScores(harry h)
{
    local int i;

    if (h == None) return;

    if (default.bChallengeGenuineSeeded == 0)
    {
        default.bChallengeGenuineSeeded = 1;
        for (i = 0; i < 4; i++)
        {
            if (h.ChallengeScores[i].nHighScore > default.ChallengeGenuineBest[i])
            {
                default.ChallengeGenuineBest[i] = h.ChallengeScores[i].nHighScore;
            }
        }
    }

    for (i = 0; i < 4; i++)
    {
        if (default.ChallengeGenuineBest[i] <= 0) continue;
        if (h.ChallengeScores[i].nHighScore != default.ChallengeGenuineBest[i])
        {
            h.ChallengeScores[i].nHighScore = default.ChallengeGenuineBest[i];
        }
    }
}

// Capture the player's real end score for a spell challenge at the instant the
// final star is consumed: the challenge has just ended (ChallengeScoreManager in
// Idle with nCurrScore frozen at the finishing value, before the corrupting tally
// runs). Folds it into the genuine best.
function CaptureSpellChallengeScore(int parIdx)
{
    local ChallengeScoreManager mgr;

    if (parIdx < 0 || parIdx > 3) return;

    foreach AllActors(class'ChallengeScoreManager', mgr)
    {
        break;
    }
    if (mgr == None) return;

    if (mgr.nCurrScore > default.ChallengeGenuineBest[parIdx])
    {
        default.ChallengeGenuineBest[parIdx] = mgr.nCurrScore;
    }
    Log("[Archipelago] APLocationScanner.CaptureSpellChallengeScore: challenge " $ parIdx
        $ " end score=" $ mgr.nCurrScore $ " par=" $ mgr.nMaxScore
        $ " -> genuine best=" $ default.ChallengeGenuineBest[parIdx]);
}

// End an in-progress spell challenge when the player bails to the hub via the mod's
// Return-to-Hub button, mirroring every vanilla exit. The button leaves through
// harry.LoadLevel and skips the challenge end path, so the ChallengeScoreManager
// rides to the hub still in ChallengeInProgress and the timer carries over (one
// free star per re-entry). EndChallenge() is the canonical end (no tally, no score,
// GotoState('Idle')); called synchronously from APFEInGamePage.TeleportToHub before
// travel (the pause-menu page is not an Actor and cannot iterate AllActors).
function EndBailedSpellChallenge()
{
    local ChallengeScoreManager mgr;

    foreach AllActors(class'ChallengeScoreManager', mgr)
    {
        break;
    }
    if (mgr == None) return;
    if (!mgr.IsInState('ChallengeInProgress')) return;

    Log("[Archipelago] APLocationScanner.EndBailedSpellChallenge: Return-to-Hub bail with a"
        $ " challenge active (nCurrScore=" $ mgr.nCurrScore $ ") - ending it so the next"
        $ " entry restarts clean");
    mgr.EndChallenge();
}

// Per-tick poll of harry.ChallengeScores[0..3]. Mastered once nHighScore >=
// nMaxScore (par); meaningful only because EnforceGenuineChallengeScores (run
// earlier this tick) overwrote nHighScore with the real end score. The nMaxScore>0
// guard rejects a never-played challenge. AP id = 5760630 + i.
function ScanChallengeMastery(APIPCActor ipc, harry h)
{
    local int i, locId, slot;

    if (h == None) return;

    for (i = 0; i < 4; i++)
    {
        if (h.ChallengeScores[i].nMaxScore <= 0) continue;
        if (h.ChallengeScores[i].nHighScore < h.ChallengeScores[i].nMaxScore) continue;
        locId = 5760630 + i;
        slot = locId - LOC_BASE;
        if (slot < 0 || slot >= NONCARD_LOC_WINDOW) continue;
        if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) continue;
        class'APCardWatcher'.default.NonCardLocationChecked[slot] = 1;
        Log("[Archipelago] APLocationScanner: spell challenge " $ i $ " mastered (high="
            $ h.ChallengeScores[i].nHighScore $ " par="
            $ h.ChallengeScores[i].nMaxScore $ ") - firing CHECK_LOCID " $ locId);
        if (ipc != None) ipc.SendCheckLocationId(locId);
    }
}

// Mechanism D (challenges 7-11): credit the LevelCompletion check on an observed
// FinalStar pickup in-level, not on exit (players can leave a challenge without
// completing it). FinalStar.PickupProp.EndState is the only path that Destroy()'s
// the actor, so observing AllActors transition present -> absent in-level is an
// unambiguous pickup signal. bAwardedFinalStarThisLevel prevents a re-fire within
// this visit; NotifyLevelObjective is sticky across visits via NonCardLocationChecked.
function ScanFinalStarCompletion()
{
    local FinalStar fs;
    local int idx;
    local bool found;

    if (bAwardedFinalStarThisLevel == 1) return;
    idx = class'APGoalTracker'.static.LevelObjectiveIndexFor(Caps(string(Level.Outer.Name)));
    if (idx < 7 || idx > 11) return;

    foreach AllActors(class'FinalStar', fs)
    {
        if (fs == None || fs.bDeleteMe) continue;
        found = True;
        break;
    }

    if (found)
    {
        if (bSawFinalStarThisLevel == 0)
        {
            bSawFinalStarThisLevel = 1;
            Log("[Archipelago] APLocationScanner.ScanFinalStarCompletion: FinalStar observed in "
                $ string(Level.Outer.Name) $ " (idx=" $ idx $ ")");
        }
    }
    else if (bSawFinalStarThisLevel == 1)
    {
        bAwardedFinalStarThisLevel = 1;
        Log("[Archipelago] APLocationScanner.ScanFinalStarCompletion: FinalStar consumed in "
            $ string(Level.Outer.Name) $ " (idx=" $ idx $ ") - crediting completion");
        class'APGoalTracker'.static.NotifyLevelObjective(idx);
        // idx 7..10 are the four spell challenges (Rictusempra..Spongify); par
        // index = idx - 7. Capture the real end score now, before the engine's
        // tally overwrites harry.ChallengeScores with max(par, actual).
        if (idx >= 7 && idx <= 10) CaptureSpellChallengeScore(idx - 7);
    }
}

// Boss-kill detector for the two open-castle goal levels. Level-gated so it never
// scans unrelated maps. Idempotent via NotifyLevelObjective's dedupe.
function ScanBossKills(harry h)
{
    local string lvl;
    local Aragog ag;
    local Basilisk bs;

    if (h == None) return;
    lvl = Caps(string(Level.Outer.Name));

    if (lvl == "ADV9ARAGOG")
    {
        foreach AllActors(class'Aragog', ag)
        {
            if (ag.IsInState('stateBeatAragog'))
            {
                class'APGoalTracker'.static.NotifyLevelObjective(3);
                break;
            }
        }
    }
    else if (lvl == "ADV12CHAMBER")
    {
        foreach AllActors(class'Basilisk', bs)
        {
            if (bs.bBasilFinishedForGood)
            {
                class'APGoalTracker'.static.NotifyLevelObjective(4);
                break;
            }
        }
    }
}

// Generous cylinder-overlap test: True when the pawn is anywhere inside the slime's
// collision volume, widened on both axes so a player genuinely standing in the
// slime is never falsely reported as outside (the safety property that makes
// ScanStuckEctoplasm unable to cancel legitimate ectoplasm damage).
static function bool PawnInEctoVolume(Ectoplasma ecto, Actor pawn)
{
    local float dx, dy, rSum, dz, zLimit;

    dx = pawn.Location.X - ecto.Location.X;
    dy = pawn.Location.Y - ecto.Location.Y;
    rSum = ecto.CollisionRadius + pawn.CollisionRadius + 24.0;
    if (dx * dx + dy * dy > rSum * rSum)
        return False;

    zLimit = ecto.CollisionHeight + pawn.CollisionHeight + 80.0;
    dz = pawn.Location.Z - ecto.Location.Z;
    if (dz > zLimit || dz < -zLimit)
        return False;

    return True;
}

// Release ectoplasm still draining Harry from a distance. A phase-through glitch
// can carry Harry out of a slime's collision without the engine firing UnTouch, so
// its aSlimedHPawn stays bound and the damage Timer keeps hitting him anywhere in
// the level (and the stuck claim serialises across save/travel/death). Any slime
// claiming a Harry no longer inside its volume is released and that Harry's ecto
// ref decremented so EctoRefSub's 1->0 cleanup runs. EctoplasmaBIG / Ectoblob both
// extend Ectoplasma, so one scan covers all.
function ScanStuckEctoplasm()
{
    local Ectoplasma ecto;
    local harry slimed;

    foreach AllActors(class'Ectoplasma', ecto)
    {
        slimed = harry(ecto.aSlimedHPawn);
        if (slimed == None) continue;
        if (PawnInEctoVolume(ecto, slimed)) continue;

        ecto.aSlimedHPawn = None;
        slimed.EctoRefSub();
        Log("[Archipelago] APLocationScanner.ScanStuckEctoplasm: released stuck "
            $ string(ecto) $ " claim on " $ string(slimed)
            $ " (phase-through, no UnTouch fired)");
    }
}

defaultproperties
{
    // Logic-only, no render/collision. bGameRelevant=False so each level transition
    // destroys this singleton: the FinalStar per-visit latches reset on the next
    // level's fresh instance. The genuine-score table, curtain latch and seed flag
    // are class-default and persist.
    bHidden=True
    bGameRelevant=False
    bCollideActors=False
    bBlockActors=False
}

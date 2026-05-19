class APGameInfo extends GameInfo;

var APIPCActor IPCActor;

// Per-classroom offset applied to the cutscene's Location when spawning the
// blocker. Lets us nudge the bookshelf without recompiling the cutscene
// lookup.
//
// RictaBlockerOffset is interpreted in WORLD coords (hand-tuned for the
// 02060DADARictaInt cutscene's specific Rotation in Grandstaircase_hub).
//
// SkurgeBlockerOffset is interpreted in the cutscene's LOCAL coords (rotated
// into world via `>>` at spawn time) — (X=180, Y=0, Z=0) means "180 units
// forward in whichever direction the cutscene faces." We don't have ground
// truth for Flitwick's cutscene Rotation so the rotation-relative model is
// safer: positive local X is always "forward from the cutscene's facing."
var Vector RictaBlockerOffset;
var Vector SkurgeBlockerOffset;
// Spongify's intro cutscene fires in Lockhart's DADA classroom (same room as
// Rictusempra) but only after the Slytherin Common Room story beat. Vanilla
// gates it via iGameState >= SpongifyGameStateGate; we mirror that gate so
// the bookcase blocker only spawns once Spongify actually becomes the next
// quest spell, instead of locking the player out of DADA from the start.
// Threshold value (130 for stock HP2) determined empirically by logging
// HarryRef.iGameState transitions through a vanilla playthrough until the
// game prompted "go to DADA to learn Spongify".
//
// Spongify shares the DADA doorway chokepoint with Rictusempra, so we anchor
// the blocker to the SAME cutscene actor as Ricta (`02060DADARictaInt`) — the
// `13040SpongeIntro` cutscene actor exists but is parked off-path in the
// level (its Location isn't a meaningful chokepoint). Offset is in WORLD
// coords (mirroring RictaBlockerOffset). Set to a tiny delta from Ricta so a
// not-yet-removed Ricta blocker doesn't encroach this spawn.
var Vector SpongifyBlockerOffset;
var int SpongifyGameStateGate;
// Sprout's herbology classroom entrance is wide enough that one bookcase
// doesn't cover it. Each slot in `DiffindoBlockerOffsets` is the spawn
// position for one bookcase, in WORLD coords relative to the cutscene
// actor (no rotation transformation — added directly to cs.Location).
// World coords match what you see in spawnLoc log lines and let you step
// purely along a world axis to follow a doorway. Array size = number of
// bookcases spawned. The bookcase ORIENTATION is still derived from the
// cutscene rotation (Yaw + 32768 so it faces Harry); only position is
// world-coords. Tune each slot independently — they don't have to be
// collinear.
var Vector DiffindoBlockerOffsets[3];

// Class-default reference to the spawned blocker. Set after a successful
// Spawn in BlockXxxClassroomIfMissing, used by RemoveXxxBlocker for an
// O(1) destroy without needing a per-level watcher in the right UWorld.
// Cleared in RemoveXxxBlocker. Auto-invalidates via bDeleteMe when the
// level it lives in is unloaded.
var Actor RictaBlockerInstance;
var Actor SkurgeBlockerInstance;
var Actor DiffindoBlockerInstance;
var Actor SpongifyBlockerInstance;

// Spawn point for the visible Slytherin Common Room end star
// (Adv7SlythComRoom). WORLD coords, hand-tuned in-game via the APConsole
// LogPos dev command the same way the *BlockerOffset literals were captured.
// Rotation is cosmetically irrelevant (the star self-spins via PHYS_Rotating).
var Vector SlytherinEndStarLocation;
var Rotator SlytherinEndStarRotation;

event InitGame(string Options, out string Error)
{
    local class<Actor> cls;

    Super.InitGame(Options, Error);
    Log("[Archipelago] APGameInfo.InitGame - subclass active");

    IPCActor = class'APIPCActor'.static.GetInstance();
    if (IPCActor != None)
    {
        Log("[Archipelago] APGameInfo: reusing existing APIPCActor singleton");
    }
    else
    {
        cls = class<Actor>(DynamicLoadObject("HPArchipelago.APIPCActor", class'Class'));
        if (cls != None)
        {
            IPCActor = APIPCActor(Spawn(cls));
            Log("[Archipelago] APGameInfo: APIPCActor spawned (new singleton)");
        }
        else
        {
            Log("[Archipelago] APGameInfo: APIPCActor class load FAILED");
        }
    }

    cls = class<Actor>(DynamicLoadObject("HPArchipelago.APCardWatcher", class'Class'));
    if (cls != None)
    {
        Spawn(cls);
        Log("[Archipelago] APGameInfo: APCardWatcher spawned (per-level)");
    }
    else
    {
        Log("[Archipelago] APGameInfo: APCardWatcher class load FAILED");
    }

    // APHUDToast is per-level (not bGameRelevant) so each InitGame spawns a
    // fresh one. Save-load (ProcessServerTravel) skips InitGame; the fallback
    // spawn for that path lives in APCardWatcher.TrySpawnClassroomBlockers.
    SpawnAPHUDToastIfMissing();

    ReplaceCardChests();
    DestroyUnobtainableSecretMarkers();
    // Durable bingo detection runs pre-Harry so DestroyGryffindorSpellGiver's
    // bBingoMode gate is reliable even on a cold load into a sentinel-less
    // level (no MGBingo actor in Ch7Gryffindor).
    class'APCardWatcher'.static.EnsureBingoModeDetected();
    DestroyGryffindorSpellGiver();
    ForceCutScenesSkippable();
    BlockRictaClassroomIfMissing();
    BlockSkurgeClassroomIfMissing();
    BlockDiffindoClassroomIfMissing();
    BlockSpongifyClassroomIfMissing();
    SpawnAllBingoBlockers();
}

// Spawn an APHUDToast in the current level if one isn't already here. Called
// from APGameInfo.InitGame (the launch / level / area-transition path).
// Save-load (which bypasses InitGame) is handled by APCardWatcher.Ensure-
// FreshToast, which also replaces a stale cross-package toast — a case this
// in-level check can't see. Idempotent: an in-level instance is a no-op.
function SpawnAPHUDToastIfMissing()
{
    local class<Actor> cls;
    local APHUDToast existing;

    existing = class'APHUDToast'.static.GetInstance();
    if (existing != None && existing.Level == Level)
    {
        return;
    }

    cls = class<Actor>(DynamicLoadObject("HPArchipelago.APHUDToast", class'Class'));
    if (cls != None)
    {
        Spawn(cls);
        Log("[Archipelago] APGameInfo: APHUDToast spawned (per-level)");
    }
    else
    {
        Log("[Archipelago] APGameInfo: APHUDToast class load FAILED");
    }
}

// Minimal-touch cutscene skip policy:
//   1. WHITELIST (force bSkipAllowed=True): a handful of intro cutscenes
//      that the bingo distribution ships as non-skippable but we want
//      skippable (Privet/Dobby opening etc.). Matched by FileName substring
//      via IsCutSceneAllowedToSkip.
//   2. BLACKLIST (force bSkipAllowed=False): specific cutscenes that
//      soft-lock the game when their fastforward path runs (e.g.
//      Grandstaircase_hub.CutScene40 secret-opening cutscene). Matched by
//      (level name, cutscene Name) via IsCutSceneBlocked.
//   3. DEFAULT: leave bSkipAllowed alone. Most cutscenes ship with the
//      correct skip behaviour and the player needs them skippable for
//      sane play.
//
// Per-level: called from both APGameInfo.InitGame (initial game) AND
// APCardWatcher.TrySpawnClassroomBlockers (post-save-load path that bypasses
// InitGame). Idempotent — re-applying the same bSkipAllowed value is a no-op.
function ForceCutScenesSkippable()
{
    local CutScene cs;
    local int allowed, denied;
    local string levelName, csName;

    levelName = Caps(string(Level.Outer.Name));

    foreach AllActors(class'CutScene', cs)
    {
        csName = string(cs.Name);
        if (IsCutSceneAllowedToSkip(cs.FileName))
        {
            if (!cs.bSkipAllowed)
            {
                cs.bSkipAllowed = True;
                allowed++;
                Log("[Archipelago] ForceCutScenesSkippable: ALLOW skip on " $ levelName $ "." $ csName $ " FileName='" $ cs.FileName $ "' (whitelisted)");
            }
        }
        else if (IsCutSceneBlocked(levelName, csName))
        {
            if (cs.bSkipAllowed)
            {
                cs.bSkipAllowed = False;
                denied++;
                Log("[Archipelago] ForceCutScenesSkippable: DENY skip on " $ levelName $ "." $ csName $ " FileName='" $ cs.FileName $ "' (blacklisted - known softlock)");
            }
        }
        // Else: leave bSkipAllowed at the map-shipped value.
    }
    if (allowed > 0 || denied > 0)
    {
        Log("[Archipelago] ForceCutScenesSkippable: " $ allowed $ " allowed, " $ denied $ " denied");
    }
}

// FileName-substring whitelist for cutscenes that bingo ships as non-skippable
// but we want skippable. Substring-match so all parts of a multi-part intro
// (00001PrivetIntro / 00001PrivetIntroPart2 / 00001PrivetIntroPart3) flip
// together. Add patterns here as we identify more safe-to-skip cutscenes.
function bool IsCutSceneAllowedToSkip(string FileName)
{
    if (InStr(FileName, "PrivetIntro") >= 0) return True;  // Dobby opening (3 parts)
    return False;
}

// Per-(level, cutscene-name) blacklist of cutscenes that softlock the game
// when their fastforward path runs. Names are stable per map-save. Level
// name comparison is uppercase (caller already Caps()'d it) so casing drift
// between bingo versions doesn't matter. Add entries as Stefan identifies
// more softlock-prone cutscenes from gameplay.
function bool IsCutSceneBlocked(string LevelNameUpper, string CutSceneName)
{
    // Grand Staircase secret-opening cutscenes with empty FileName — confirmed
    // softlocks on skip during bingo playtest 2026-05-14.
    if (LevelNameUpper == "GRANDSTAIRCASE_HUB")
    {
        if (CutSceneName == "CutScene12") return True;
        if (CutSceneName == "CutScene14") return True;
        if (CutSceneName == "CutScene39") return True;
        if (CutSceneName == "CutScene40") return True;
        if (CutSceneName == "CutScene63") return True;
    }
    return False;
}

// Destroy SecretAreaMarker instances that AP dropped from the catalogue
// because they're unobtainable in normal play. Vanilla's pause menu counts
// secrets via AllActors(Class'SecretAreaMarker') in FEInGamePage.GetSecretsCount,
// so leaving the marker in the level inflates the denominator (e.g. Chamber
// of Secrets Part 2 would show X/4 when only 3 are actually findable).
// Destroying at level entry removes them from the AllActors enumeration.
function DestroyUnobtainableSecretMarkers()
{
    local SecretAreaMarker m;
    local string levelName;

    levelName = Caps(string(Level.Outer.Name));
    if (levelName == "ADV11BSECRETS")
    {
        foreach AllActors(class'SecretAreaMarker', m)
        {
            if (m.Name == 'SecretAreaMarker0')
            {
                Log("[Archipelago] DestroyUnobtainableSecretMarkers: " $ levelName $ "." $ string(m.Name) $ " - destroying so pause menu shows X/3 not X/4");
                m.Destroy();
            }
        }
    }
}

// Ch7Gryffindor (bingo-only challenge level) ships a vanilla
// TriggerTurnOnAllSpells (tag Givespells) that, on its first Touch/Trigger,
// sets harry.bNoSpellBookCheck=True — making harry.IsInSpellBook return True
// for EVERY spell (harry.uc:568), so the player can cast everything and the
// watcher's revert loop can never clear a spell. The level-start dispatcher
// fires it almost immediately, before the per-level watcher's Snapshot runs,
// so the actor must die HERE in InitGame (pre-Harry, pre-level-scripts), not
// in Snapshot. The watcher also clears the flag every tick to cover a save
// reloaded inside the room (ProcessServerTravel skips InitGame). Bingo-only;
// vanilla never enters this level so the giver is left intact there.
function DestroyGryffindorSpellGiver()
{
    local Actor a;
    local int n;

    if (Caps(string(Level.Outer.Name)) != "CH7GRYFFINDOR") return;
    if (class'APCardWatcher'.default.bBingoMode != 1) return;

    foreach AllActors(class'Actor', a)
    {
        if (a != None && !a.bDeleteMe
            && string(a.Class.Name) == "TriggerTurnOnAllSpells")
        {
            a.Destroy();
            n++;
        }
    }
    if (n > 0)
    {
        Log("[Archipelago] DestroyGryffindorSpellGiver: destroyed " $ n
            $ " TriggerTurnOnAllSpells actor(s) at InitGame (CH7GRYFFINDOR bingo)");
    }
}

// If the player doesn't already own Rictusempra (per APCardWatcher's AP-grant
// flag), spawn a bookshelf at the location of the lesson-intro cutscene
// (`02060DADARictaInt`). The cutscene's actor location is the chokepoint
// where Lockhart's intro fires when Harry walks up; blocking it prevents the
// whole softlock chain (intro -> wand minigame -> changegamestate ->
// LevelChange Ch1Rictusempra) without disturbing the eventual real run-through
// once AP grants the spell.
function BlockRictaClassroomIfMissing()
{
    local CutScene cs;
    local Actor blocker, existing;
    local Vector spawnLoc;
    local Rotator spawnRot;
    local bool found;

    // Bingo mode supersedes this helper with BlockBingoRictusempraEntryIfMissing
    // (level-transition bookcase in Entryhall_hub, gated on the Rictusempra
    // Challenge Key item rather than on the spell). Skip the cutscene-anchored
    // blocker so we don't double up in Entryhall_hub.
    if (class'APCardWatcher'.default.bBingoMode == 1)
    {
        return;
    }

    if (class'APCardWatcher'.default.APGrantedSpell[4] == 1)
    {
        Log("[Archipelago] BlockRicta: player has Rictusempra (APGrantedSpell[4]=1) - no blocker needed");
        return;
    }

    // Idempotency: if a tagged blocker already exists in this level (either
    // from a prior InitGame this session or restored from .usa save),
    // capture its ref and skip the spawn. Same path is called from both
    // APGameInfo.InitGame AND APCardWatcher.EnsureLatestRegistration so
    // this guard prevents double-spawn.
    foreach AllActors(class'Actor', existing)
    {
        if (existing.Tag == 'APRictaBlocker' && !existing.bDeleteMe)
        {
            default.RictaBlockerInstance = existing;
            Log("[Archipelago] BlockRicta: blocker already in level (tag-scan hit " $ string(existing) $ ") - skipping spawn");
            return;
        }
    }

    foreach AllActors(class'CutScene', cs)
    {
        if (cs.FileName == "02060DADARictaInt")
        {
            spawnLoc = cs.Location + RictaBlockerOffset;
            spawnRot = cs.Rotation;
            Log("[Archipelago] BlockRicta: cutscene=" $ string(cs.Name)
                $ " FileName=" $ cs.FileName
                $ " Loc=" $ string(cs.Location)
                $ " Rot=" $ string(cs.Rotation)
                $ " offset=" $ string(RictaBlockerOffset)
                $ " spawnLoc=" $ string(spawnLoc));
            blocker = Spawn(class'BookcaseGlassDoors', , , spawnLoc, spawnRot);
            if (blocker == None)
            {
                Log("[Archipelago] BlockRicta: Spawn returned None (encroachment likely - try a non-zero RictaBlockerOffset.Z)");
            }
            else
            {
                blocker.Tag = 'APRictaBlocker';
                default.RictaBlockerInstance = blocker;
                Log("[Archipelago] BlockRicta: spawned " $ string(blocker)
                    $ " bCollideActors=" $ string(blocker.bCollideActors)
                    $ " bBlockActors=" $ string(blocker.bBlockActors)
                    $ " bBlockPlayers=" $ string(blocker.bBlockPlayers)
                    $ " (tracked as default.RictaBlockerInstance)");
            }
            found = True;
            break;
        }
    }
    if (!found)
    {
        Log("[Archipelago] BlockRicta: 02060DADARictaInt cutscene not present in this level (expected only in Grandstaircase_hub)");
    }
}

// Live removal: destroy any blocker we previously spawned. Called when AP
// grants Rictusempra mid-session.
//
// Two paths:
//  1) Direct ref via default.RictaBlockerInstance (set when BlockRicta
//     spawned the blocker THIS session). O(1), works across UWorlds.
//  2) Fallback: iterate via the latest watcher's UWorld looking for any
//     actor tagged 'APRictaBlocker' (covers the case where the blocker
//     was saved into a .usa and restored in a fresh session, so our
//     class-default ref is None but a tagged actor still exists).
function RemoveRictaBlocker()
{
    local Actor b, a, scanActor;
    local APCardWatcher w;
    local int n;

    b = default.RictaBlockerInstance;
    if (b != None && !b.bDeleteMe)
    {
        Log("[Archipelago] RemoveRictaBlocker: destroying tracked blocker " $ string(b) $ " at " $ string(b.Location) $ " (in level " $ string(b.Level) $ ")");
        b.Destroy();
        default.RictaBlockerInstance = None;
        return;
    }
    if (b != None)
    {
        Log("[Archipelago] RemoveRictaBlocker: tracked ref was already bDeleteMe - clearing");
        default.RictaBlockerInstance = None;
    }

    // Fallback: scan via watcher's UWorld for any tagged blocker.
    w = class'APCardWatcher'.static.GetLatest();
    if (w == None)
    {
        Log("[Archipelago] RemoveRictaBlocker: no tracked ref AND no watcher to scan - giving up (nothing to destroy)");
        return;
    }
    if (w.HarryRef != None && !w.HarryRef.bDeleteMe)
    {
        scanActor = w.HarryRef;
    }
    else
    {
        scanActor = w;
    }
    n = 0;
    foreach scanActor.AllActors(class'Actor', a)
    {
        if (a.Tag == 'APRictaBlocker' && !a.bDeleteMe)
        {
            Log("[Archipelago] RemoveRictaBlocker: tag-scan found " $ string(a) $ " in " $ string(scanActor.Level) $ " - destroying");
            a.Destroy();
            n++;
        }
    }
    if (n == 0)
    {
        Log("[Archipelago] RemoveRictaBlocker: tag-scan in " $ string(scanActor.Level) $ " found 0 blockers (player likely not in Grandstaircase_hub)");
    }
}

// Mirror of BlockRictaClassroomIfMissing for Flitwick's Skurge classroom.
// Same level (Grandstaircase_hub) but a different cutscene — the FileName
// isn't in the UScript decompile (lives in the .unr), so we use a heuristic:
// the Skurge intro cutscene's FileName contains "Skurge" and ends "Int"
// (mirroring `02060DADARictaInt`'s structure). If the heuristic finds nothing,
// the fallback path dumps every cutscene FileName in the level so we can
// identify the right one on the next run.
function BlockSkurgeClassroomIfMissing()
{
    local CutScene cs, candidate;
    local Actor blocker, existing;
    local Vector spawnLoc;
    local Rotator spawnRot;
    local string fn;
    local int nameLen;

    // Bingo mode: superseded by BlockBingoSkurgeEntryIfMissing.
    if (class'APCardWatcher'.default.bBingoMode == 1)
    {
        return;
    }

    if (class'APCardWatcher'.default.APGrantedSpell[5] == 1)
    {
        Log("[Archipelago] BlockSkurge: player has Skurge (APGrantedSpell[5]=1) - no blocker needed");
        return;
    }

    // Idempotency: see BlockRictaClassroomIfMissing.
    foreach AllActors(class'Actor', existing)
    {
        if (existing.Tag == 'APSkurgeBlocker' && !existing.bDeleteMe)
        {
            default.SkurgeBlockerInstance = existing;
            Log("[Archipelago] BlockSkurge: blocker already in level (tag-scan hit " $ string(existing) $ ") - skipping spawn");
            return;
        }
    }

    foreach AllActors(class'CutScene', cs)
    {
        fn = cs.FileName;
        if (fn == "")
        {
            continue;
        }
        nameLen = Len(fn);
        if (nameLen >= 3 && Mid(fn, nameLen - 3) == "Int" && InStr(fn, "Skurge") >= 0)
        {
            candidate = cs;
            break;
        }
    }

    if (candidate == None)
    {
        Log("[Archipelago] BlockSkurge: heuristic ('Skurge' + 'Int' suffix) found no match. Dumping all cutscenes in this level for identification:");
        foreach AllActors(class'CutScene', cs)
        {
            Log("[Archipelago] BlockSkurge:   - " $ string(cs.Name) $ " FileName='" $ cs.FileName $ "'");
        }
        return;
    }

    // SkurgeBlockerOffset is interpreted in the cutscene's LOCAL coords —
    // (X=180, Y=0, Z=0) means "180 units forward in whichever direction the
    // cutscene actor is facing." This removes the need to guess the
    // Skurge cutscene's world Rotation (Ricta's offset is in world coords,
    // hand-tuned for that specific cutscene's orientation; we don't have
    // the equivalent ground truth for the Flitwick one). `vector >> rotator`
    // is UE1's rotate-into-world operator.
    //
    // Yaw +32768 = 180° in UE1's 16-bit-rotator space. The Flitwick cutscene
    // faces away from Harry's approach direction, so we flip the bookcase to
    // face Harry instead (verified visually in Grandstaircase_hub).
    spawnRot = candidate.Rotation;
    spawnRot.Yaw = spawnRot.Yaw + 32768;
    spawnLoc = candidate.Location + (SkurgeBlockerOffset >> candidate.Rotation);
    Log("[Archipelago] BlockSkurge: candidate=" $ string(candidate.Name)
        $ " FileName=" $ candidate.FileName
        $ " Loc=" $ string(candidate.Location)
        $ " Rot=" $ string(candidate.Rotation)
        $ " localOffset=" $ string(SkurgeBlockerOffset)
        $ " worldDelta=" $ string(SkurgeBlockerOffset >> candidate.Rotation)
        $ " spawnLoc=" $ string(spawnLoc));

    blocker = Spawn(class'BookcaseGlassDoors', , , spawnLoc, spawnRot);
    if (blocker == None)
    {
        Log("[Archipelago] BlockSkurge: Spawn returned None (encroachment likely - try a non-zero SkurgeBlockerOffset.Z)");
        return;
    }
    blocker.Tag = 'APSkurgeBlocker';
    default.SkurgeBlockerInstance = blocker;
    Log("[Archipelago] BlockSkurge: spawned " $ string(blocker)
        $ " bCollideActors=" $ string(blocker.bCollideActors)
        $ " bBlockActors=" $ string(blocker.bBlockActors)
        $ " bBlockPlayers=" $ string(blocker.bBlockPlayers)
        $ " (tracked as default.SkurgeBlockerInstance)");
}

// Live removal mirror of RemoveRictaBlocker. Two paths: direct class-default
// ref (O(1), works across UWorlds) and tag-scan fallback for save-load
// restored blockers whose default ref was reset to None on game boot.
function RemoveSkurgeBlocker()
{
    local Actor b, a, scanActor;
    local APCardWatcher w;
    local int n;

    b = default.SkurgeBlockerInstance;
    if (b != None && !b.bDeleteMe)
    {
        Log("[Archipelago] RemoveSkurgeBlocker: destroying tracked blocker " $ string(b) $ " at " $ string(b.Location) $ " (in level " $ string(b.Level) $ ")");
        b.Destroy();
        default.SkurgeBlockerInstance = None;
        return;
    }
    if (b != None)
    {
        Log("[Archipelago] RemoveSkurgeBlocker: tracked ref was already bDeleteMe - clearing");
        default.SkurgeBlockerInstance = None;
    }

    w = class'APCardWatcher'.static.GetLatest();
    if (w == None)
    {
        Log("[Archipelago] RemoveSkurgeBlocker: no tracked ref AND no watcher to scan - giving up");
        return;
    }
    if (w.HarryRef != None && !w.HarryRef.bDeleteMe)
    {
        scanActor = w.HarryRef;
    }
    else
    {
        scanActor = w;
    }
    n = 0;
    foreach scanActor.AllActors(class'Actor', a)
    {
        if (a.Tag == 'APSkurgeBlocker' && !a.bDeleteMe)
        {
            Log("[Archipelago] RemoveSkurgeBlocker: tag-scan found " $ string(a) $ " in " $ string(scanActor.Level) $ " - destroying");
            a.Destroy();
            n++;
        }
    }
    if (n == 0)
    {
        Log("[Archipelago] RemoveSkurgeBlocker: tag-scan in " $ string(scanActor.Level) $ " found 0 blockers (player likely not in Grandstaircase_hub)");
    }
}

// Mirror of BlockSkurgeClassroomIfMissing for Sprout's Diffindo classroom.
// Cutscene FileName resolved via same heuristic ("Diffindo" + "Int" suffix);
// fallback dumps every cutscene FileName if no match.
function BlockDiffindoClassroomIfMissing()
{
    local CutScene cs, candidate;
    local Actor blocker;
    local Vector spawnLoc, worldOffset;
    local Rotator spawnRot;
    local int i, spawned;

    // Bingo mode: superseded by BlockBingoDiffindoEntryIfMissing.
    if (class'APCardWatcher'.default.bBingoMode == 1)
    {
        return;
    }

    if (class'APCardWatcher'.default.APGrantedSpell[1] == 1)
    {
        Log("[Archipelago] BlockDiffindo: player has Diffindo (APGrantedSpell[1]=1) - no blocker needed");
        return;
    }

    // Exact match — discovered via the heuristic-fallback dump. Sprout's
    // Diffindo intro doesn't follow the same naming convention as Ricta /
    // Skurge: it uses "Diff" (abbreviated) and the suffix is "Intro" not
    // "Int". So we hard-code the name like Ricta does.
    foreach AllActors(class'CutScene', cs)
    {
        if (cs.FileName == "08040HerbDiffIntro")
        {
            candidate = cs;
            break;
        }
    }

    if (candidate == None)
    {
        Log("[Archipelago] BlockDiffindo: 08040HerbDiffIntro cutscene not present in this level (expected only in Grounds_hub)");
        return;
    }

    // Sprout's classroom entrance is wider than one bookcase. Spawn one
    // bookcase per slot in DiffindoBlockerOffsets — each is a WORLD offset
    // from the cutscene actor (no rotation transformation). Slots are
    // independent; tune each one's X/Y/Z separately to match the doorway
    // geometry. Bookcase ORIENTATION still tracks the cutscene rotation
    // (Yaw + 32768 to face Harry). No idempotency tag-scan up front — if
    // previous bookcases are still in the level (restored from .usa),
    // Spawn returns None on encroachment and we just skip that slot.
    // RemoveDiffindoBlocker's tag-scan destroys every tagged blocker on
    // AP grant.
    spawnRot = candidate.Rotation;
    spawnRot.Yaw = spawnRot.Yaw + 32768;

    Log("[Archipelago] BlockDiffindo: candidate=" $ string(candidate.Name)
        $ " FileName=" $ candidate.FileName
        $ " Loc=" $ string(candidate.Location)
        $ " Rot=" $ string(candidate.Rotation)
        $ " count=" $ string(ArrayCount(DiffindoBlockerOffsets)));

    spawned = 0;
    for (i = 0; i < ArrayCount(DiffindoBlockerOffsets); i++)
    {
        worldOffset = DiffindoBlockerOffsets[i];
        spawnLoc = candidate.Location + worldOffset;
        Log("[Archipelago] BlockDiffindo[" $ string(i) $ "]: worldOffset=" $ string(worldOffset)
            $ " spawnLoc=" $ string(spawnLoc));

        blocker = Spawn(class'BookcaseGlassDoors', , , spawnLoc, spawnRot);
        if (blocker == None)
        {
            Log("[Archipelago] BlockDiffindo[" $ string(i) $ "]: Spawn returned None (encroachment - tweak DiffindoBlockerOffsets[" $ string(i) $ "], or this slot is already filled by a restored save actor)");
            continue;
        }
        blocker.Tag = 'APDiffindoBlocker';
        if (default.DiffindoBlockerInstance == None)
        {
            default.DiffindoBlockerInstance = blocker;
        }
        spawned++;
        Log("[Archipelago] BlockDiffindo[" $ string(i) $ "]: spawned " $ string(blocker));
    }

    Log("[Archipelago] BlockDiffindo: spawned " $ string(spawned) $ " of " $ string(ArrayCount(DiffindoBlockerOffsets)) $ " bookcases");
}

function RemoveDiffindoBlocker()
{
    local Actor a, scanActor;
    local APCardWatcher w;
    local int n;

    // Diffindo spawns a row of bookcases (one per DiffindoBlockerOffsets
    // slot) to cover the wide herbology entrance. Always tag-scan and
    // destroy every matching actor — the direct-ref shortcut used by
    // Ricta/Skurge would only destroy the first one and leak the others.
    default.DiffindoBlockerInstance = None;

    w = class'APCardWatcher'.static.GetLatest();
    if (w == None)
    {
        Log("[Archipelago] RemoveDiffindoBlocker: no watcher to scan - giving up");
        return;
    }
    if (w.HarryRef != None && !w.HarryRef.bDeleteMe)
    {
        scanActor = w.HarryRef;
    }
    else
    {
        scanActor = w;
    }
    n = 0;
    foreach scanActor.AllActors(class'Actor', a)
    {
        if (a.Tag == 'APDiffindoBlocker' && !a.bDeleteMe)
        {
            Log("[Archipelago] RemoveDiffindoBlocker: tag-scan found " $ string(a) $ " in " $ string(scanActor.Level) $ " - destroying");
            a.Destroy();
            n++;
        }
    }
    if (n == 0)
    {
        Log("[Archipelago] RemoveDiffindoBlocker: tag-scan in " $ string(scanActor.Level) $ " found 0 blockers");
    }
    else
    {
        Log("[Archipelago] RemoveDiffindoBlocker: destroyed " $ string(n) $ " bookcase(s)");
    }
}

// Mirror of BlockRictaClassroomIfMissing for Lockhart's Spongify lesson.
// Spongify is the second lesson Lockhart teaches in the DADA classroom (after
// Rictusempra) and vanilla only enables its intro cutscene once iGameState
// reaches SpongifyGameStateGate (130 in stock HP2 — post-Slytherin Common
// Room). Spawning the blocker before that point would lock Harry out of DADA
// for no reason, so we early-return when iGameState is below the gate.
//
// Anchored to the Rictusempra cutscene actor (`02060DADARictaInt`) — same
// physical doorway chokepoint as the Ricta blocker. The `13040SpongeIntro`
// cutscene actor IS in the level but its position is not at the doorway
// (cutscene actors can be parked anywhere; only their trigger location
// matters for activation). Offset is WORLD coords like Ricta; small Y delta
// from RictaBlockerOffset prevents encroachment-failure when both blockers
// are up at the same time (e.g., Rictusempra not yet AP-granted at the
// moment iGameState crosses 130).
function BlockSpongifyClassroomIfMissing()
{
    local CutScene cs, candidate;
    local Actor blocker, existing;
    local Vector spawnLoc;
    local Rotator spawnRot;
    local harry h;

    // Bingo mode: superseded by BlockBingoSpongifyEntryIfMissing.
    if (class'APCardWatcher'.default.bBingoMode == 1)
    {
        return;
    }

    if (class'APCardWatcher'.default.APGrantedSpell[6] == 1)
    {
        Log("[Archipelago] BlockSpongify: player has Spongify (APGrantedSpell[6]=1) - no blocker needed");
        return;
    }

    h = harry(Level.PlayerHarryActor);
    if (h == None || h.iGameState < SpongifyGameStateGate)
    {
        // Story not yet at the point where Spongify intro becomes valid in
        // DADA. Quiet return — this fires every InitGame / TrySpawnClassroom
        // call before the gate; logging would be noise.
        return;
    }

    foreach AllActors(class'Actor', existing)
    {
        if (existing.Tag == 'APSpongifyBlocker' && !existing.bDeleteMe)
        {
            default.SpongifyBlockerInstance = existing;
            Log("[Archipelago] BlockSpongify: blocker already in level (tag-scan hit " $ string(existing) $ ") - skipping spawn");
            return;
        }
    }

    foreach AllActors(class'CutScene', cs)
    {
        if (cs.FileName == "02060DADARictaInt")
        {
            candidate = cs;
            break;
        }
    }

    if (candidate == None)
    {
        Log("[Archipelago] BlockSpongify: 02060DADARictaInt cutscene not present in this level (expected only in Grandstaircase_hub)");
        return;
    }

    // SpongifyBlockerOffset is in WORLD coords (mirrors RictaBlockerOffset).
    // Rotation comes straight from the cutscene actor (no Yaw flip — Ricta
    // doesn't flip either; the Ricta blocker has been verified facing the
    // right way at this same anchor).
    spawnLoc = candidate.Location + SpongifyBlockerOffset;
    spawnRot = candidate.Rotation;
    Log("[Archipelago] BlockSpongify: candidate=" $ string(candidate.Name)
        $ " FileName=" $ candidate.FileName
        $ " Loc=" $ string(candidate.Location)
        $ " Rot=" $ string(candidate.Rotation)
        $ " offset=" $ string(SpongifyBlockerOffset)
        $ " spawnLoc=" $ string(spawnLoc));

    blocker = Spawn(class'BookcaseGlassDoors', , , spawnLoc, spawnRot);
    if (blocker == None)
    {
        Log("[Archipelago] BlockSpongify: Spawn returned None (encroachment likely - Ricta blocker may still be present at this spot; tweak SpongifyBlockerOffset)");
        return;
    }
    blocker.Tag = 'APSpongifyBlocker';
    default.SpongifyBlockerInstance = blocker;
    Log("[Archipelago] BlockSpongify: spawned " $ string(blocker)
        $ " bCollideActors=" $ string(blocker.bCollideActors)
        $ " bBlockActors=" $ string(blocker.bBlockActors)
        $ " bBlockPlayers=" $ string(blocker.bBlockPlayers)
        $ " (tracked as default.SpongifyBlockerInstance)");
}

function RemoveSpongifyBlocker()
{
    local Actor b, a, scanActor;
    local APCardWatcher w;
    local int n;

    b = default.SpongifyBlockerInstance;
    if (b != None && !b.bDeleteMe)
    {
        Log("[Archipelago] RemoveSpongifyBlocker: destroying tracked blocker " $ string(b) $ " at " $ string(b.Location) $ " (in level " $ string(b.Level) $ ")");
        b.Destroy();
        default.SpongifyBlockerInstance = None;
        return;
    }
    if (b != None)
    {
        Log("[Archipelago] RemoveSpongifyBlocker: tracked ref was already bDeleteMe - clearing");
        default.SpongifyBlockerInstance = None;
    }

    w = class'APCardWatcher'.static.GetLatest();
    if (w == None)
    {
        Log("[Archipelago] RemoveSpongifyBlocker: no tracked ref AND no watcher to scan - giving up");
        return;
    }
    if (w.HarryRef != None && !w.HarryRef.bDeleteMe)
    {
        scanActor = w.HarryRef;
    }
    else
    {
        scanActor = w;
    }
    n = 0;
    foreach scanActor.AllActors(class'Actor', a)
    {
        if (a.Tag == 'APSpongifyBlocker' && !a.bDeleteMe)
        {
            Log("[Archipelago] RemoveSpongifyBlocker: tag-scan found " $ string(a) $ " in " $ string(scanActor.Level) $ " - destroying");
            a.Destroy();
            n++;
        }
    }
    if (n == 0)
    {
        Log("[Archipelago] RemoveSpongifyBlocker: tag-scan in " $ string(scanActor.Level) $ " found 0 blockers (player likely not in Grandstaircase_hub)");
    }
}

//=============================================================================
// Bingo-mode level-entry bookcases.
//
// 13 keys, 17 bookcases. Each helper is level-scoped (early-returns when
// Level.Outer.Name doesn't match) so InitGame can call all 13 unconditionally
// and let each one decide. APGrantedBingoKey[i] on APCardWatcher tracks which
// keys the player has received this session — Block helpers early-return on
// granted, Remove helpers tag-scan + Destroy. Idempotent on re-entry via the
// tag check.
//
// Shared utilities below dedupe the per-helper boilerplate. The actual
// Location/Rotation literals were captured via the dev console PlaceBookcase
// exec (APConsole.uc) in the bingo install and transcribed here.
//=============================================================================

function bool BingoLevelIs(string CapsName)
{
    return Caps(string(Level.Outer.Name)) == CapsName;
}

function bool BingoLevelIsAnyOf(string CapsA, string CapsB)
{
    local string lvl;
    lvl = Caps(string(Level.Outer.Name));
    return lvl == CapsA || lvl == CapsB;
}

function bool BingoKeyGranted(int idx)
{
    return class'APCardWatcher'.default.APGrantedBingoKey[idx] == 1;
}

// Vanilla gates 7 regions behind a bookcase (same actor + coords + level as
// bingo, since the levels are identical between distributions). The 5 level
// regions form a cumulative chain in linear story order — a region's bookcase
// clears only once its own key AND every earlier level key are granted;
// Duelling and Quidditch are standalone (own key only). Returns True while the
// bookcase for OwnKeyIdx must still block; False for any key not in the 7
// (those regions have no vanilla bookcase — spells/story/precollection gate
// them). Chain order: Bicorn(10) -> Boomslang(5) -> Goyle(9) ->
// Slytherin(8) -> ForbiddenForest(7).
function bool VanillaBlockerShouldBlock(int OwnKeyIdx)
{
    if (OwnKeyIdx == 10)        // Bicorn
        return !BingoKeyGranted(10);
    if (OwnKeyIdx == 5)         // Boomslang
        return !(BingoKeyGranted(10) && BingoKeyGranted(5));
    if (OwnKeyIdx == 9)         // Goyle
        return !(BingoKeyGranted(10) && BingoKeyGranted(5) && BingoKeyGranted(9));
    if (OwnKeyIdx == 8)         // Slytherin Common Room
        return !(BingoKeyGranted(10) && BingoKeyGranted(5) && BingoKeyGranted(9) && BingoKeyGranted(8));
    if (OwnKeyIdx == 7)         // Forbidden Forest
        return !(BingoKeyGranted(10) && BingoKeyGranted(5) && BingoKeyGranted(9) && BingoKeyGranted(8) && BingoKeyGranted(7));
    if (OwnKeyIdx == 11)        // Duelling (standalone)
        return !BingoKeyGranted(11);
    if (OwnKeyIdx == 12)        // Quidditch (standalone)
        return !BingoKeyGranted(12);
    return false;               // not a vanilla-blocked region
}

// Returns True if a bookcase with this tag should be spawned in the current
// level. Idempotent (skips if a tagged actor already exists). Bingo: spawn
// while the single key is ungranted. Vanilla: spawn while the cumulative key
// requirement for this region is unmet (and only for the 7 vanilla regions).
function bool ShouldSpawnBingoBlocker(name Tag, int KeyIdx)
{
    local Actor existing;

    foreach AllActors(class'Actor', existing)
    {
        if (existing.Tag == Tag && !existing.bDeleteMe)
        {
            return False;
        }
    }
    if (class'APCardWatcher'.default.bBingoMode == 1)
    {
        return !BingoKeyGranted(KeyIdx);
    }
    return VanillaBlockerShouldBlock(KeyIdx);
}

function Actor SpawnBingoBookcase(name Tag, Vector Loc, Rotator Rot)
{
    local Actor blocker;

    blocker = Spawn(class'BookcaseGlassDoors', None, Tag, Loc, Rot);
    if (blocker == None)
    {
        // Encroachment: an actor (typically an ambient hub NPC such as Percy)
        // is sitting in the footprint, so Spawn returns None and the doorway/
        // corridor stays open. Clear non-Harry pawns at the spot and retry
        // once. Only runs on an actual failure, so it never disturbs NPCs /
        // Tradersanity vendors standing near a bookcase that spawned fine.
        ClearBookcaseEncroachers(Loc, 120.0);
        blocker = Spawn(class'BookcaseGlassDoors', None, Tag, Loc, Rot);
    }
    if (blocker != None)
    {
        Log("[Archipelago] " $ string(Tag) $ ": spawned at " $ string(Loc) $ " Rotation=" $ string(Rot));
    }
    else
    {
        Log("[Archipelago] " $ string(Tag) $ ": Spawn returned None at " $ string(Loc) $ " (encroachment persists after clearing pawns; coords may need a tweak)");
    }
    return blocker;
}

function DestroyTaggedBingoBlockers(name Tag)
{
    local Actor a, scanActor;
    local APCardWatcher w;
    local int n;

    // Mirror RemoveRictaBlocker's pattern: scan from the watcher's harry if
    // available, so we hit the gameplay UWorld actors (Entry's harry has
    // Player=None and is in a different UWorld).
    w = class'APCardWatcher'.static.GetLatest();
    if (w != None && w.HarryRef != None && !w.HarryRef.bDeleteMe)
    {
        scanActor = w.HarryRef;
    }
    else
    {
        scanActor = self;
    }
    foreach scanActor.AllActors(class'Actor', a)
    {
        if (a.Tag == Tag && !a.bDeleteMe)
        {
            a.Destroy();
            n++;
        }
    }
    if (n > 0)
    {
        Log("[Archipelago] Remove " $ string(Tag) $ ": destroyed " $ n $ " blocker(s)");
    }
}

// ----- 1. Chamber of Secrets (Grandstaircase_hub) -----
function BlockBingoChamberEntryIfMissing()
{
    local Vector loc;
    local Rotator rot;
    if (!BingoLevelIs("GRANDSTAIRCASE_HUB")) return;
    if (!ShouldSpawnBingoBlocker('APBingoChamberBlocker', 0)) return;
    loc.X = 1598.02;  loc.Y = -7624.80; loc.Z = 1196.50;
    rot.Yaw = 93;
    SpawnBingoBookcase('APBingoChamberBlocker', loc, rot);
}
function RemoveBingoChamberBlocker()       { DestroyTaggedBingoBlockers('APBingoChamberBlocker'); }

// ----- 2. Spongify classroom entry (Entryhall_hub) -----
function BlockBingoSpongifyEntryIfMissing()
{
    local Vector loc;
    local Rotator rot;
    if (!BingoLevelIs("ENTRYHALL_HUB")) return;
    if (!ShouldSpawnBingoBlocker('APBingoSpongifyBlocker', 1)) return;
    loc.X = -1985.10; loc.Y = -2817.36; loc.Z = 108.50;
    rot.Yaw = 49144;  rot.Roll = 65532;
    SpawnBingoBookcase('APBingoSpongifyBlocker', loc, rot);
}
function RemoveBingoSpongifyBlocker()      { DestroyTaggedBingoBlockers('APBingoSpongifyBlocker'); }

// ----- 3. Skurge classroom entry (Entryhall_hub) -----
function BlockBingoSkurgeEntryIfMissing()
{
    local Vector loc;
    local Rotator rot;
    if (!BingoLevelIs("ENTRYHALL_HUB")) return;
    if (!ShouldSpawnBingoBlocker('APBingoSkurgeBlocker', 2)) return;
    loc.X = 575.69;   loc.Y = -2818.14; loc.Z = 108.50;
    rot.Yaw = 16384;
    SpawnBingoBookcase('APBingoSkurgeBlocker', loc, rot);
}
function RemoveBingoSkurgeBlocker()        { DestroyTaggedBingoBlockers('APBingoSkurgeBlocker'); }

// ----- 4. Rictusempra classroom entry (Entryhall_hub) -----
function BlockBingoRictusempraEntryIfMissing()
{
    local Vector loc;
    local Rotator rot;
    if (!BingoLevelIs("ENTRYHALL_HUB")) return;
    if (!ShouldSpawnBingoBlocker('APBingoRictusempraBlocker', 3)) return;
    loc.X = 255.65;   loc.Y = -1407.09; loc.Z = -19.50;
    rot.Yaw = 16468;  rot.Roll = 65535;
    SpawnBingoBookcase('APBingoRictusempraBlocker', loc, rot);
}
function RemoveBingoRictusempraBlocker()   { DestroyTaggedBingoBlockers('APBingoRictusempraBlocker'); }

// ----- 5. Diffindo classroom entry (Grounds_hub + Grounds_Night) -----
function BlockBingoDiffindoEntryIfMissing()
{
    local Vector loc;
    local Rotator rot;
    if (!BingoLevelIsAnyOf("GROUNDS_HUB", "GROUNDS_NIGHT")) return;
    if (!ShouldSpawnBingoBlocker('APBingoDiffindoBlocker', 4)) return;
    loc.X = -1335.32; loc.Y = -771.42;  loc.Z = -211.50;
    rot.Yaw = 41494;
    SpawnBingoBookcase('APBingoDiffindoBlocker', loc, rot);
}
function RemoveBingoDiffindoBlocker()      { DestroyTaggedBingoBlockers('APBingoDiffindoBlocker'); }

// ----- 6. Boomslang level entry (Grounds_hub + Grounds_Night) -----
function BlockBingoBoomslangEntryIfMissing()
{
    local Vector loc;
    local Rotator rot;
    if (!BingoLevelIsAnyOf("GROUNDS_HUB", "GROUNDS_NIGHT")) return;
    if (!ShouldSpawnBingoBlocker('APBingoBoomslangBlocker', 5)) return;
    loc.X = -4421.24; loc.Y = 1100.93;  loc.Z = 44.50;
    rot.Yaw = 49153;
    SpawnBingoBookcase('APBingoBoomslangBlocker', loc, rot);
}
function RemoveBingoBoomslangBlocker()     { DestroyTaggedBingoBlockers('APBingoBoomslangBlocker'); }

// ----- 7. Whomping Willow entry (Grounds_hub + Grounds_Night) -----
function BlockBingoWillowEntryIfMissing()
{
    local Vector loc;
    local Rotator rot;
    if (!BingoLevelIsAnyOf("GROUNDS_HUB", "GROUNDS_NIGHT")) return;
    if (!ShouldSpawnBingoBlocker('APBingoWillowBlocker', 6)) return;
    loc.X = -0.42;    loc.Y = 1579.53;  loc.Z = 300.50;
    rot.Yaw = 32687;
    SpawnBingoBookcase('APBingoWillowBlocker', loc, rot);
}
function RemoveBingoWillowBlocker()        { DestroyTaggedBingoBlockers('APBingoWillowBlocker'); }

// ----- 8. Forbidden Forest entry (Grounds_hub + Grounds_Night). 2 stacked bookcases. -----
function BlockBingoForbiddenForestEntryIfMissing()
{
    local Vector loc;
    local Rotator rot;
    if (!BingoLevelIsAnyOf("GROUNDS_HUB", "GROUNDS_NIGHT")) return;
    if (!ShouldSpawnBingoBlocker('APBingoForbiddenForestBlocker', 7)) return;
    // FF1 at ground level.
    loc.X = 3928.45;  loc.Y = 3438.30;  loc.Z = -211.31;
    rot.Yaw = 17288;  rot.Roll = 65532;
    SpawnBingoBookcase('APBingoForbiddenForestBlocker', loc, rot);
    loc.Z = -35.31;
    SpawnBingoBookcase('APBingoForbiddenForestBlocker', loc, rot);
}
function RemoveBingoForbiddenForestBlocker() { DestroyTaggedBingoBlockers('APBingoForbiddenForestBlocker'); }

// ----- 9. Slytherin Common Room entry (Entryhall_hub) -----
function BlockBingoSlytherinEntryIfMissing()
{
    local Vector loc;
    local Rotator rot;
    if (!BingoLevelIs("ENTRYHALL_HUB")) return;
    if (!ShouldSpawnBingoBlocker('APBingoSlytherinBlocker', 8)) return;
    loc.X = -2526.16; loc.Y = -3019.69; loc.Z = -595.50;
    rot.Yaw = 65333;  rot.Roll = 65535;
    SpawnBingoBookcase('APBingoSlytherinBlocker', loc, rot);
}
function RemoveBingoSlytherinBlocker()     { DestroyTaggedBingoBlockers('APBingoSlytherinBlocker'); }

// ----- 10. Goyle level entry (Entryhall_hub) -----
function BlockBingoGoyleEntryIfMissing()
{
    local Vector loc;
    local Rotator rot;
    if (!BingoLevelIs("ENTRYHALL_HUB")) return;
    if (!ShouldSpawnBingoBlocker('APBingoGoyleBlocker', 9)) return;
    loc.X = -5192.51; loc.Y = -2368.72; loc.Z = -227.50;
    rot.Yaw = 49578;
    SpawnBingoBookcase('APBingoGoyleBlocker', loc, rot);
}
function RemoveBingoGoyleBlocker()         { DestroyTaggedBingoBlockers('APBingoGoyleBlocker'); }

// ----- 11. Bicorn level entry (Entryhall_hub) -----
function BlockBingoBicornEntryIfMissing()
{
    local Vector loc;
    local Rotator rot;
    if (!BingoLevelIs("ENTRYHALL_HUB")) return;
    if (!ShouldSpawnBingoBlocker('APBingoBicornBlocker', 10)) return;
    loc.X = -5194.33; loc.Y = -958.79;  loc.Z = -467.50;
    rot.Yaw = 48862;
    SpawnBingoBookcase('APBingoBicornBlocker', loc, rot);
}
function RemoveBingoBicornBlocker()        { DestroyTaggedBingoBlockers('APBingoBicornBlocker'); }

// ----- 12. Duelling Club entry (Entryhall_hub). 2 bookcases side by side. -----
function BlockBingoDuellingEntryIfMissing()
{
    local Vector loc;
    local Rotator rot;
    if (!BingoLevelIs("ENTRYHALL_HUB")) return;
    if (!ShouldSpawnBingoBlocker('APBingoDuellingBlocker', 11)) return;
    rot.Yaw = 138;
    loc.X = 486.01;   loc.Y = -1345.50; loc.Z = -371.50;
    SpawnBingoBookcase('APBingoDuellingBlocker', loc, rot);
    loc.X = 665.40;
    SpawnBingoBookcase('APBingoDuellingBlocker', loc, rot);
}
function RemoveBingoDuellingBlocker()      { DestroyTaggedBingoBlockers('APBingoDuellingBlocker'); }

// ----- 13. Quidditch Pitch entry (Grounds_hub + Grounds_Night). 2 bookcases. -----
function BlockBingoQuidditchEntryIfMissing()
{
    local Vector loc;
    local Rotator rot;
    if (!BingoLevelIsAnyOf("GROUNDS_HUB", "GROUNDS_NIGHT")) return;
    if (!ShouldSpawnBingoBlocker('APBingoQuidditchBlocker', 12)) return;
    loc.X = 1506.36;  loc.Y = 165.71;   loc.Z = 44.50;
    rot.Yaw = 33272;  rot.Roll = 0;
    SpawnBingoBookcase('APBingoQuidditchBlocker', loc, rot);
    loc.X = 1382.72;  loc.Y = 234.64;
    rot.Yaw = 16564;  rot.Roll = 65535;
    SpawnBingoBookcase('APBingoQuidditchBlocker', loc, rot);
}
function RemoveBingoQuidditchBlocker()     { DestroyTaggedBingoBlockers('APBingoQuidditchBlocker'); }

// A hub ambient NPC (Percy in particular, sometimes a student) can idle
// exactly where a bookcase spawns; a Pawn in the footprint makes Spawn return
// None (encroachment), leaving the doorway/corridor open. SpawnBingoBookcase
// calls this on a failed spawn to destroy any non-Harry Pawn within Radius of
// Loc, then retries. Hub NPCs are ambient in bingo and restored fresh from
// the persistent-actor cache on every level entry, so removing the one in the
// way each load is cosmetically harmless and reliably keeps the seal. Used by
// every bookcase blocker (all spawn through SpawnBingoBookcase).
function ClearBookcaseEncroachers(Vector Loc, float Radius)
{
    local Pawn p;
    local int n;

    foreach AllActors(class'Pawn', p)
    {
        if (p == None || p.bDeleteMe) continue;
        if (harry(p) != None) continue;            // never touch Harry
        // Never destroy a Tradersanity vendor: its check is keyed on this
        // actor by (level, Name), so removing it would break that vendor's
        // sale until hub re-entry. Data-driven via the same registry the
        // Tradersanity feature uses, so it cannot drift. (A vendor that ever
        // truly blocks a bookcase leaves a transient gap that visit — an
        // accepted, ~never-hit trade-off given ~360uu vendor/bookcase spacing.)
        if (class'APLocationRegistry'.static.GetVendorLocationId(
                string(Level.Outer.Name), string(p.Name)) != 0) continue;
        if (VSize(p.Location - Loc) <= Radius)
        {
            p.Destroy();
            n++;
        }
    }
    if (n > 0)
    {
        Log("[Archipelago] ClearBookcaseEncroachers: removed " $ n
            $ " pawn(s) within " $ Radius $ " of " $ string(Loc));
    }
}

// ----- 14. Gryffindor challenge entry (Entryhall_hub). 2 bookcases. -----
function BlockBingoGryffindorEntryIfMissing()
{
    local Vector loc;
    local Rotator rot;
    if (!BingoLevelIs("ENTRYHALL_HUB")) return;
    if (!ShouldSpawnBingoBlocker('APBingoGryffindorBlocker', 13)) return;
    loc.X = 2641.93;  loc.Y = -1884.27; loc.Z = 620.50;
    rot.Yaw = 302;    rot.Roll = 65535;
    SpawnBingoBookcase('APBingoGryffindorBlocker', loc, rot);
    loc.X = 2636.15;  loc.Y = -1838.34; loc.Z = 620.50;
    rot.Yaw = 375;    rot.Roll = 0;
    SpawnBingoBookcase('APBingoGryffindorBlocker', loc, rot);
}
function RemoveBingoGryffindorBlocker()    { DestroyTaggedBingoBlockers('APBingoGryffindorBlocker'); }

// ----- Great Hall goal gate (EntryHall_Hub; 1 bookcase — goal_plan.md §3) -----
// NOT keyed by an APGrantedBingoKey: this one is gated by the 5-clause goal
// evaluator, so it does not use ShouldSpawnBingoBlocker (which checks
// BingoKeyGranted). Spawn while the goal is unmet; APCardWatcher.Timer calls
// RemoveBingoGreatHallBlocker the tick GoalSatisfied() first passes and sets
// the sticky WasGoalUnlocked, after which this early-returns so it never
// respawns. There is exactly one concrete way into the Great Hall; these
// corridor bookcases are the sole route to the bInEndGame credits cutscene.
function BlockBingoGreatHallEntryIfMissing()
{
    local Vector loc;
    local Rotator rot;
    local Actor existing;

    if (class'APCardWatcher'.default.bBingoMode == 0) return;
    if (!BingoLevelIs("ENTRYHALL_HUB")) return;
    if (class'APCardWatcher'.default.WasGoalUnlocked == 1) return;  // already opened
    foreach AllActors(class'Actor', existing)
        if (existing.Tag == 'APBingoGreatHallBlocker' && !existing.bDeleteMe) return;

    // Five hand-tuned bookcase positions spanning the Great Hall corridor at
    // Z=-273. A single spawn point can be occupied by an idling NPC at
    // level-load (Spawn returns None on encroachment), which would leave the
    // corridor open, so the spread keeps it sealed when one slot is blocked.
    // All share the tag, so RemoveBingoGreatHallBlocker clears every one at
    // goal unlock. First coord is the §3 Phase-0 PlaceBookcase capture.
    loc.X = 1061.760376; loc.Y = -831.163818; loc.Z = -273;
    rot.Yaw = 16321;  rot.Roll = 0;
    SpawnBingoBookcase('APBingoGreatHallBlocker', loc, rot);
    loc.X = 913.5; loc.y = -835.;
    SpawnBingoBookcase('APBingoGreatHallBlocker', loc, rot);
    loc.X = 946.71; loc.y = -838.7;
    SpawnBingoBookcase('APBingoGreatHallBlocker', loc, rot);
    loc.X = 1035.612; loc.y = -838.383;
    SpawnBingoBookcase('APBingoGreatHallBlocker', loc, rot);
    loc.X = 853.645; loc.y = -837.000;
    SpawnBingoBookcase('APBingoGreatHallBlocker', loc, rot);
}
function RemoveBingoGreatHallBlocker()     { DestroyTaggedBingoBlockers('APBingoGreatHallBlocker'); }

// Convenience aggregator called from InitGame and from
// APCardWatcher.TrySpawnClassroomBlockers (post-save-load path that bypasses
// InitGame). Each helper is level-scoped and key-gated, so unconditional
// iteration is safe in both modes — a Grounds bookcase in Entryhall_hub just
// early-returns, and the per-region gate decides spawn/skip per mode. Bingo
// may spawn all 13 (each behind its own key); vanilla spawns only the 7
// chain/standalone level regions (the other 6 are gated by spells/story).
function SpawnAllBingoBlockers()
{
    BlockBingoChamberEntryIfMissing();
    BlockBingoSpongifyEntryIfMissing();
    BlockBingoSkurgeEntryIfMissing();
    BlockBingoRictusempraEntryIfMissing();
    BlockBingoDiffindoEntryIfMissing();
    BlockBingoBoomslangEntryIfMissing();
    BlockBingoWillowEntryIfMissing();
    BlockBingoForbiddenForestEntryIfMissing();
    BlockBingoSlytherinEntryIfMissing();
    BlockBingoGoyleEntryIfMissing();
    BlockBingoBicornEntryIfMissing();
    BlockBingoDuellingEntryIfMissing();
    BlockBingoQuidditchEntryIfMissing();
    BlockBingoGryffindorEntryIfMissing();
    BlockBingoGreatHallEntryIfMissing();
}

// Spawn the visible end star in the Slytherin Common Room so the level's
// objective is reachable without solving the full rotating-room puzzle, and so
// it stays permanently available as the level's exit (like the challenge
// FinalStar) - spawned on every entry, NOT gated on completion.
// NotifyLevelObjective is idempotent, so re-touching a completed room never
// re-fires the AP check; it just travels the player back to the hub. Driven
// from APCardWatcher.Snapshot (post-Bind, so the HProp's PreBeginPlay resolves
// a valid PlayerHarry) - spawning from APGameInfo.InitGame is too early
// (PlayerHarry==None, so HProp.CanPickupNow can never fire). Level-gated to
// ADV7SLYTHCOMROOM. Any prior instance (including one serialized into a save
// by an earlier build) is destroyed and a fresh one respawned, so the live
// actor is always correctly initialised - one destroy+respawn per level bind
// (Snapshot runs once per bind), the same pattern as ReplaceChallengeStars.
function SpawnSlytherinEndStarIfMissing()
{
    local Actor existing;
    local APSlytherinEndStar star;
    local int destroyed;

    if (Caps(string(Level.Outer.Name)) != "ADV7SLYTHCOMROOM") return;

    foreach AllActors(class'Actor', existing)
    {
        if (existing.Tag == 'APSlytherinEndStar' && !existing.bDeleteMe)
        {
            existing.Destroy();
            destroyed++;
        }
    }
    if (destroyed > 0)
    {
        Log("[Archipelago] SpawnSlytherinEndStar: destroyed " $ destroyed
            $ " prior instance(s) before respawn");
    }

    star = Spawn(class'APSlytherinEndStar', None,
        'APSlytherinEndStar', SlytherinEndStarLocation, SlytherinEndStarRotation);
    if (star != None)
    {
        Log("[Archipelago] SpawnSlytherinEndStar: spawned at "
            $ string(SlytherinEndStarLocation));
    }
    else
    {
        Log("[Archipelago] SpawnSlytherinEndStar: Spawn returned None at "
            $ string(SlytherinEndStarLocation) $ " (encroachment? coords may need tweak)");
    }
}

// Replace every card-class reference in chests/cauldrons (and every loose
// WizardCardIcon actor in the level) with the corresponding APCardMarker_<class>
// subclass. Called from InitGame on every level entry.
//
// Why this exists: vanilla harry.uc:977 calls RemoveHarryOwnedCardsFromLevel(None)
// on level entry, which bean-swaps any chest holding a card the player already
// owns. That makes those AP locations unreachable. Our markers carry a sentinel
// Id that vanilla never matches, so they survive the sweep.
function ReplaceCardChests()
{
    local chestbronze chest;
    local bronzecauldron cauldron;
    local WizardCardIcon wci;
    local class<Actor> markerClass;
    local class<APCardMarker> slotMarkerCls;
    local Actor spawned;
    local Vector looseLoc;
    local Rotator looseRot;
    local name looseTag;
    local Actor looseBase;
    local int i;
    local int totalReplaced;
    local bool hasUnchecked;

    totalReplaced = 0;

    foreach AllActors(class'chestbronze', chest)
    {
        for (i = 0; i < ArrayCount(chest.EjectedObjects); i++)
        {
            if (TryReplaceCardSlot(chest.EjectedObjects[i], markerClass))
            {
                Log("[Archipelago] ReplaceCardChests: chest=" $ string(chest) $ " slot=" $ i $ " was=" $ string(chest.EjectedObjects[i]) $ " -> " $ string(markerClass));
                chest.EjectedObjects[i] = markerClass;
                totalReplaced++;
            }
        }
        if (chest.bOpened)
        {
            hasUnchecked = False;
            for (i = 0; i < ArrayCount(chest.EjectedObjects); i++)
            {
                if (chest.EjectedObjects[i] != None
                    && ClassIsChildOf(chest.EjectedObjects[i], class'APCardMarker'))
                {
                    slotMarkerCls = class<APCardMarker>(chest.EjectedObjects[i]);
                    if (slotMarkerCls.default.CardLocationId > 0
                        && slotMarkerCls.default.CardLocationId <= 101
                        && class'APCardWatcher'.default.LocationChecked[slotMarkerCls.default.CardLocationId] == 0)
                    {
                        hasUnchecked = True;
                        break;
                    }
                }
            }
            if (hasUnchecked)
            {
                Log("[Archipelago] ReplaceCardChests: chest=" $ string(chest) $ " was opened but has an unchecked APCardMarker slot - resetting bOpened so player can re-open and pick up");
                chest.bOpened = False;
                // Restore spell-targetability. stillOpen state had set these to
                // non-targetable (bProjTarget=False, eVulnerableToSpell=SPELL_None);
                // GotoState alone won't restore them, so Alohomora wouldn't hit
                // and the chest would stay shut after our "reset". Defaults are
                // bProjTarget=True, eVulnerableToSpell=SPELL_Alohomora on
                // chestbronze (and its ChestWood/Iron/Gold subclasses inherit).
                chest.bProjTarget = class'chestbronze'.default.bProjTarget;
                chest.eVulnerableToSpell = class'chestbronze'.default.eVulnerableToSpell;
                chest.GotoState('waitforspell');
            }
        }
    }

    foreach AllActors(class'bronzecauldron', cauldron)
    {
        for (i = 0; i < ArrayCount(cauldron.EjectedObjects); i++)
        {
            if (TryReplaceCardSlot(cauldron.EjectedObjects[i], markerClass))
            {
                Log("[Archipelago] ReplaceCardChests: cauldron=" $ string(cauldron) $ " slot=" $ i $ " was=" $ string(cauldron.EjectedObjects[i]) $ " -> " $ string(markerClass));
                cauldron.EjectedObjects[i] = markerClass;
                totalReplaced++;
            }
        }
        if (cauldron.bOpened)
        {
            hasUnchecked = False;
            for (i = 0; i < ArrayCount(cauldron.EjectedObjects); i++)
            {
                if (cauldron.EjectedObjects[i] != None
                    && ClassIsChildOf(cauldron.EjectedObjects[i], class'APCardMarker'))
                {
                    slotMarkerCls = class<APCardMarker>(cauldron.EjectedObjects[i]);
                    if (slotMarkerCls.default.CardLocationId > 0
                        && slotMarkerCls.default.CardLocationId <= 101
                        && class'APCardWatcher'.default.LocationChecked[slotMarkerCls.default.CardLocationId] == 0)
                    {
                        hasUnchecked = True;
                        break;
                    }
                }
            }
            if (hasUnchecked)
            {
                Log("[Archipelago] ReplaceCardChests: cauldron=" $ string(cauldron) $ " was opened but has an unchecked APCardMarker slot - resetting bOpened so player can re-open and pick up");
                cauldron.bOpened = False;
                // Same flag-restore as the chest path. Cauldron is Flipendo-opened.
                cauldron.bProjTarget = class'bronzecauldron'.default.bProjTarget;
                cauldron.eVulnerableToSpell = class'bronzecauldron'.default.eVulnerableToSpell;
                cauldron.GotoState('waitforspell');
            }
        }
    }

    foreach AllActors(class'WizardCardIcon', wci)
    {
        if (wci.IsA('APCardMarker')) continue;

        // If this loose icon's location has already been checked this session,
        // just destroy the vanilla wci and don't spawn a replacement. Avoids
        // the "ghost sprite" Stefan saw after day/night transitions: the
        // freshly-spawned APCardMarker_<X> would self-destroy in PostBeginPlay
        // due to the LocationChecked[] guard, but the brief lifetime + render
        // timing could leave a visible-but-untouchable card icon behind.
        // Chest path uses Jellybean swap; loose path has no surrounding
        // container so empty space is the cleanest result.
        if (wci.Id > 0 && wci.Id <= 101
            && class'APCardWatcher'.default.LocationChecked[wci.Id] == 1)
        {
            Log("[Archipelago] ReplaceCardChests: loose icon=" $ string(wci) $ " location " $ wci.Id $ " already checked - destroying vanilla wci with no replacement");
            wci.Destroy();
            continue;
        }

        markerClass = class<Actor>(DynamicLoadObject("HPArchipelago.APCardMarker_" $ string(wci.Class.Name), class'Class'));
        if (markerClass != None)
        {
            // Capture location/rotation/tag/base before destroying wci. We must
            // destroy wci FIRST — Spawn at the same coords with wci still present
            // causes encroachment, the engine destroys the new marker and returns
            // None.
            //
            // Tag and Base get copied so the new marker keeps any mover
            // attachment the level designer set up. In UE1, movers attach actors
            // via their `AttachTag` field in `PostBeginPlay` (which runs AFTER
            // InitGame, i.e. AFTER this function); a Tag-match on our new marker
            // makes that scan attach us. Base is copied too in case the editor
            // set it directly on the wci (rare but cheap to handle).
            //
            // Concrete case this fixes: Chamber-of-Secrets II has a freestanding
            // card on a descending platform. Pre-fix, the marker stayed at its
            // original Z while the platform dropped because PHYS_None pins to
            // world coords. With Tag inherited, the mover's PostBeginPlay scan
            // SetBases the marker so it follows the platform down.
            looseLoc = wci.Location;
            looseRot = wci.Rotation;
            looseTag = wci.Tag;
            looseBase = wci.Base;
            Log("[Archipelago] ReplaceCardChests: loose icon=" $ string(wci) $ " (class=" $ string(wci.Class.Name) $ ") at " $ string(looseLoc) $ " Tag=" $ string(looseTag) $ " Base=" $ string(looseBase) $ " -> spawn " $ string(markerClass));
            wci.Destroy();
            spawned = Spawn(markerClass, , , looseLoc, looseRot);
            if (spawned == None)
            {
                Log("[Archipelago] ReplaceCardChests: Spawn STILL returned None for " $ string(markerClass) $ " at " $ string(looseLoc));
            }
            else
            {
                if (looseTag != 'None')
                {
                    spawned.Tag = looseTag;
                }
                if (looseBase != None)
                {
                    spawned.SetBase(looseBase);
                }
                APCardMarker(spawned).MarkAsLoose();
                Log("[Archipelago] ReplaceCardChests: spawned " $ string(spawned) $ " at " $ string(spawned.Location) $ " Tag=" $ string(spawned.Tag) $ " Base=" $ string(spawned.Base) $ " (loose, gravity disabled)");
            }
            totalReplaced++;
        }
        else
        {
            Log("[Archipelago] ReplaceCardChests: loose icon=" $ string(wci) $ " (class=" $ string(wci.Class.Name) $ ") - no APCardMarker_<class> found, leaving alone");
        }
    }

    if (totalReplaced > 0)
    {
        Log("[Archipelago] ReplaceCardChests: replaced " $ totalReplaced $ " card slot(s) / loose icon(s) with APCardMarker subclasses");
    }
}

// Helper: if `slot` is a WizardCardIcon subclass that isn't already our marker,
// resolve the corresponding APCardMarker_<ClassName> and write it to outClass.
// Returns true if a replacement was found.
//
// If the card's location is already checked this session, swap to `Jellybean`
// instead — mimics vanilla StatusGroupWizardCards.RemoveHarryOwnedCardsFromLevel
// which bean-swaps chest slots whose card the player already owns. Without
// this swap, re-opening a looted chest would spawn an APCardMarker whose
// PostBeginPlay sees LocationChecked[id]==1 and self-destroys, leaving the
// player with chest particles + sound but no item ("ghost chest" bug).
//
// Handles two slot states:
//   1) Vanilla WCxxx — read .default.Id from the vanilla class.
//   2) Already-replaced APCardMarker_xxx (restored from a persistent delta
//      actor cache on re-entry) — read .default.CardLocationId from the marker
//      class. Without this branch, a card collected in a level twin (e.g.
//      Wadcock in Grounds_Night) would leave Grounds_hub's chest's
//      EjectedObjects[0] stuck as the marker class, and the marker's
//      PostBeginPlay self-destroy produces the ghost chest.
function bool TryReplaceCardSlot(class<Actor> slot, out class<Actor> outClass)
{
    local class<WizardCardIcon> cardCls;
    local class<APCardMarker> markerCls;
    local int locationId;

    if (slot == None) return False;
    if (!ClassIsChildOf(slot, class'WizardCardIcon')) return False;

    if (ClassIsChildOf(slot, class'APCardMarker'))
    {
        markerCls = class<APCardMarker>(slot);
        locationId = markerCls.default.CardLocationId;
        if (locationId > 0 && locationId <= 101
            && class'APCardWatcher'.default.LocationChecked[locationId] == 1)
        {
            Log("[Archipelago] ReplaceCardChests: location " $ locationId $ " already checked - bean-swapping cached APCardMarker " $ string(slot.Name) $ " to Jellybean");
            outClass = class'Jellybean';
            return True;
        }
        return False;
    }

    cardCls = class<WizardCardIcon>(slot);
    locationId = cardCls.default.Id;
    if (locationId > 0 && locationId <= 101
        && class'APCardWatcher'.default.LocationChecked[locationId] == 1)
    {
        Log("[Archipelago] ReplaceCardChests: location " $ locationId $ " already checked - bean-swapping " $ string(slot.Name) $ " slot to Jellybean");
        outClass = class'Jellybean';
        return True;
    }

    outClass = class<Actor>(DynamicLoadObject("HPArchipelago.APCardMarker_" $ string(slot.Name), class'Class'));
    if (outClass == None)
    {
        Log("[Archipelago] ReplaceCardChests: no APCardMarker_" $ string(slot.Name) $ " - leaving slot alone");
        return False;
    }
    return True;
}

function bool IsKnownSpellName(string Name)
{
    return Name == "Alohomora" || Name == "Diffindo" || Name == "Flipendo"
        || Name == "Lumos" || Name == "Rictusempra" || Name == "Skurge"
        || Name == "Spongify";
}

function bool TryApplyCard(string ItemName, harry h)
{
    local class<WizardCardIcon> cardClass;
    local class<StatusItemWizardCards> siClass;
    local StatusGroupWizardCards sgCards;
    local StatusItemWizardCards siCard;
    local int nOldCardCount;
    local int nNewCardCount;

    cardClass = class<WizardCardIcon>(DynamicLoadObject("HGame." $ ItemName, class'Class'));
    if (cardClass == None)
    {
        return False;
    }

    if (ClassIsChildOf(cardClass, class'BronzeCards'))
    {
        siClass = class'StatusItemBronzeCards';
    }
    else if (ClassIsChildOf(cardClass, class'SilverCards'))
    {
        siClass = class'StatusItemSilverCards';
    }
    else if (ClassIsChildOf(cardClass, class'Goldcards'))
    {
        siClass = class'StatusItemGoldCards';
    }
    else
    {
        Log("[Archipelago] ApplyGrant: " $ ItemName $ " is not a recognized card tier");
        return False;
    }

    if (h.managerStatus == None)
    {
        Log("[Archipelago] ApplyGrant: harry.managerStatus is None, cannot grant card");
        return False;
    }
    sgCards = StatusGroupWizardCards(h.managerStatus.GetStatusGroup(class'StatusGroupWizardCards'));
    if (sgCards == None)
    {
        Log("[Archipelago] ApplyGrant: StatusGroupWizardCards not found");
        return False;
    }
    siCard = StatusItemWizardCards(sgCards.GetStatusItem(siClass));
    if (siCard == None)
    {
        Log("[Archipelago] ApplyGrant: StatusItem for " $ string(siClass) $ " not found");
        return False;
    }

    if (class'APCardWatcher'.static.GetLatest() != None)
    {
        class'APCardWatcher'.static.GetLatest().MarkAsGranted(cardClass.default.Id);
    }
    nOldCardCount = siCard.nCount;
    siCard.SetCardOwner(cardClass.default.Id, siCard.ECardOwner.CardOwner_Harry);
    nNewCardCount = siCard.nCount;
    PlayCardRewardFX(h, cardClass, nOldCardCount, nNewCardCount);
    // NOTE: vanilla Touch chain ends with sgCards.RemoveHarryOwnedCardsFromLevel(self)
    // to clean up the picked-up icon and replace duplicate-card chest contents
    // with Jellybeans. We deliberately DO NOT call it here. For an AP grant we
    // have no in-level icon to clean up, and the chest-mutation side effect
    // makes the player unable to visit those card locations later (the chest
    // would spawn a bean instead of the card icon). Trade-off documented in
    // ../DESIGN.md v2 parking lot.
    Log("[Archipelago] ApplyGrant: granted card " $ ItemName $ " (Id=" $ cardClass.default.Id $ ")");
    return True;
}

function PlayCardRewardFX(harry h, class<WizardCardIcon> cardClass, int nOldCardCount, int nNewCardCount)
{
    local Rotator rotPickupFX;

    if (h == None || nOldCardCount == nNewCardCount)
    {
        return;
    }

    rotPickupFX.Pitch = 16464;
    rotPickupFX.Yaw = 0;
    rotPickupFX.Roll = 0;

    if (ClassIsChildOf(cardClass, class'BronzeCards'))
    {
        if (nNewCardCount % 10 == 0)
        {
            FancySpawn(class'BronzeStamina',,,, rotPickupFX);
            h.DoCelebrateCardSet(True);
        }
        else
        {
            FancySpawn(class'BronzePickup',,,, rotPickupFX);
        }
        return;
    }

    if (ClassIsChildOf(cardClass, class'SilverCards'))
    {
        if (nNewCardCount % 10 == 0)
        {
            FancySpawn(class'SilverUnlock',,,, rotPickupFX);
            h.DoCelebrateCardSet(False);
        }
        else
        {
            FancySpawn(class'SilverPickup',,,, rotPickupFX);
        }
        return;
    }

    if (ClassIsChildOf(cardClass, class'Goldcards'))
    {
        FancySpawn(class'GoldPickup',,,, rotPickupFX);
    }
}

// Quidditch equipment grants — Nimbus 2001 (Fred) and Quidditch Armour (George).
// Both items live in StatusGroupQGear (StatusItemNimbus / StatusItemQArmor)
// and are gated on harry.bHaveNimbus2001 / bHaveQArmor for gameplay logic
// (Quidditch readiness, vendor "out of stock" checks, etc.). Idempotent —
// re-grants are no-ops, mirroring TryApplyKeyItem's already-owned guard.
function bool TryApplyEquipment(string Name, harry h)
{
    if (h == None || h.managerStatus == None) return False;
    if (Name != "Nimbus 2001" && Name != "Quidditch Armour") return False;

    if (Name == "Nimbus 2001")
    {
        if (h.bHaveNimbus2001)
        {
            Log("[Archipelago] ApplyGrant: Nimbus 2001 already owned - no-op");
            return True;
        }
        h.managerStatus.AddNimbus(1);
        h.bHaveNimbus2001 = True;
        Log("[Archipelago] ApplyGrant: granted Nimbus 2001 (bHaveNimbus2001=True, StatusItemNimbus+1)");
        return True;
    }
    if (Name == "Quidditch Armour")
    {
        if (h.bHaveQArmor)
        {
            Log("[Archipelago] ApplyGrant: Quidditch Armour already owned - no-op");
            return True;
        }
        h.managerStatus.AddQArmor(1);
        h.bHaveQArmor = True;
        Log("[Archipelago] ApplyGrant: granted Quidditch Armour (bHaveQArmor=True, StatusItemQArmor+1)");
        return True;
    }
    return False;
}

function bool TryApplyKeyItem(string Name, harry h)
{
    local APCardWatcher watcher;
    local StatusItem siKey;

    if (h == None || h.managerStatus == None) return False;
    if (Name != "Boomslang" && Name != "Bicorn" && Name != "BitOGoyle") return False;

    class'APCardWatcher'.static.MarkKeyItemAsAPGrantedDefault(Name);
    watcher = class'APCardWatcher'.static.GetLatest();
    if (watcher != None)
    {
        watcher.MarkKeyItemAsGranted(Name);
    }

    if (Name == "Boomslang")
    {
        siKey = h.managerStatus.GetStatusItem(class'StatusGroupPolyIngr', class'StatusItemBoomslang');
        if (siKey != None && siKey.nCount > 0)
        {
            Log("[Archipelago] ApplyGrant: Boomslang already owned - no-op");
            return True;
        }
        h.managerStatus.AddBoomslang(1);
        Log("[Archipelago] ApplyGrant: granted Boomslang via AddBoomslang(1)");
        return True;
    }
    if (Name == "Bicorn")
    {
        siKey = h.managerStatus.GetStatusItem(class'StatusGroupPolyIngr', class'StatusItemBicorn');
        if (siKey != None && siKey.nCount > 0)
        {
            Log("[Archipelago] ApplyGrant: Bicorn already owned - no-op");
            return True;
        }
        h.managerStatus.AddBicorn(1);
        Log("[Archipelago] ApplyGrant: granted Bicorn via AddBicorn(1)");
        return True;
    }
    if (Name == "BitOGoyle")
    {
        siKey = h.managerStatus.GetStatusItem(class'StatusGroupPolyIngr', class'StatusItemBitOGoyle');
        if (siKey == None)
        {
            siKey = h.managerStatus.GetStatusItem(class'StatusGroupPotionIngr', class'StatusItemBitOGoyle');
        }
        if (siKey != None && siKey.nCount > 0)
        {
            Log("[Archipelago] ApplyGrant: BitOGoyle already owned - no-op");
            return True;
        }
        h.managerStatus.IncrementCount(class'StatusGroupPolyIngr', class'StatusItemBitOGoyle', 1);
        Log("[Archipelago] ApplyGrant: granted BitOGoyle via IncrementCount");
        return True;
    }
    return False;
}

// Bingo-only level-entry key. Stamps the class-default APGrantedBingoKey flag
// (so future BlockBingo<X>EntryIfMissing helpers early-return for this key) and
// dispatches to the matching RemoveBingo<X>Blocker to destroy any bookcase
// already in the level. Returns True if the item name matched a known bingo
// key, regardless of whether a blocker was actually present.
function bool TryApplyBingoKey(string Name)
{
    local int idx;

    idx = class'APCardWatcher'.static.BingoKeyIndexFromName(Name);
    if (idx < 0)
    {
        return False;
    }

    class'APCardWatcher'.static.MarkBingoKeyAsAPGrantedDefault(Name);

    if (class'APCardWatcher'.default.bBingoMode == 1)
    {
        if (idx == 0)       RemoveBingoChamberBlocker();
        else if (idx == 1)  RemoveBingoSpongifyBlocker();
        else if (idx == 2)  RemoveBingoSkurgeBlocker();
        else if (idx == 3)  RemoveBingoRictusempraBlocker();
        else if (idx == 4)  RemoveBingoDiffindoBlocker();
        else if (idx == 5)  RemoveBingoBoomslangBlocker();
        else if (idx == 6)  RemoveBingoWillowBlocker();
        else if (idx == 7)  RemoveBingoForbiddenForestBlocker();
        else if (idx == 8)  RemoveBingoSlytherinBlocker();
        else if (idx == 9)  RemoveBingoGoyleBlocker();
        else if (idx == 10) RemoveBingoBicornBlocker();
        else if (idx == 11) RemoveBingoDuellingBlocker();
        else if (idx == 12) RemoveBingoQuidditchBlocker();
        else if (idx == 13) RemoveBingoGryffindorBlocker();
    }
    else
    {
        RefreshVanillaBlockers();
    }

    Log("[Archipelago] ApplyGrant: granted bingo key " $ Name $ " (idx=" $ idx $ ")");
    return True;
}

// Vanilla: one granted key can satisfy several cumulative chain regions at
// once (e.g. the final missing earlier key clears its region and every later
// region whose other keys are already in hand). Re-evaluate all 7 and drop
// each bookcase whose full cumulative requirement is now met. DestroyTagged is
// a no-op when the bookcase is absent or in another level, so this is safe to
// call from any level on every grant.
function RefreshVanillaBlockers()
{
    if (!VanillaBlockerShouldBlock(10)) RemoveBingoBicornBlocker();
    if (!VanillaBlockerShouldBlock(5))  RemoveBingoBoomslangBlocker();
    if (!VanillaBlockerShouldBlock(9))  RemoveBingoGoyleBlocker();
    if (!VanillaBlockerShouldBlock(8))  RemoveBingoSlytherinBlocker();
    if (!VanillaBlockerShouldBlock(7))  RemoveBingoForbiddenForestBlocker();
    if (!VanillaBlockerShouldBlock(11)) RemoveBingoDuellingBlocker();
    if (!VanillaBlockerShouldBlock(12)) RemoveBingoQuidditchBlocker();
}

static function harry FindActiveHarry(Actor caller)
{
    local APCardWatcher watcher;
    local harry h, fallback;

    watcher = class'APCardWatcher'.static.GetLatest();
    if (watcher != None)
    {
        h = TryGetViewportHarry(harry(watcher.Level.PlayerHarryActor));
        if (h != None)
        {
            return h;
        }
        h = harry(watcher.Level.PlayerHarryActor);
        if (h != None && !h.bDeleteMe)
        {
            return h;
        }
        if (watcher.HarryRef != None && !watcher.HarryRef.bDeleteMe)
        {
            return watcher.HarryRef;
        }
    }

    h = TryGetViewportHarry(harry(caller.Level.PlayerHarryActor));
    if (h != None)
    {
        return h;
    }

    h = harry(caller.Level.PlayerHarryActor);
    if (h != None && !h.bDeleteMe)
    {
        return h;
    }

    foreach caller.AllActors(class'harry', h)
    {
        if (h.bDeleteMe)
        {
            continue;
        }
        if (fallback == None)
        {
            fallback = h;
        }
    }
    return fallback;
}

static function harry TryGetViewportHarry(harry SourceHarry)
{
    local HPConsole Console;
    local harry ViewportHarry;

    if (SourceHarry == None || SourceHarry.Player == None)
    {
        return None;
    }

    Console = HPConsole(SourceHarry.Player.Console);
    if (Console == None || Console.Viewport == None)
    {
        return None;
    }

    ViewportHarry = harry(Console.Viewport.Actor);
    if (ViewportHarry != None && !ViewportHarry.bDeleteMe)
    {
        return ViewportHarry;
    }
    return None;
}

// Authoritative "Harry is actually playing right now" check. Layered on top
// of the Level.Pauser / FindGrantReadyHarry / watcher.bSnapshotted gates in
// APIPCActor.TryDrainPendingGrants. Only PlayerWalking grants —
// every other state (stateCutIdle, SpellLearning, harryfrozen, stateDead,
// GameEnded, exittoMenu, stateInactive, Mounting / MountFinish, Quidditch,
// dueling, statePickupItem, statePotionMixing*, wingspell, LookAtActor,
// ChessDeath, CelebrateCardSet, etc.) defers. The grant queue drains the
// moment Harry returns to PlayerWalking. HUD cutscene/popup check covers
// the tick-window between cutscene start and stateCutIdle transition (and
// the cutscene-skip path where bBothBordersActive animates while Harry's
// state hasn't transitioned yet).
// bAllowInGameMenu (optional, default False): when True the in-game pause
// menu (menuBook.bIsOpen) is NOT a blocking reason. Only RingLink's bean
// drain passes True — a bean apply is pure data (StatusItem.nCount) with no
// UI-instantiating side effects, so it is safe mid-menu. The GRANT drain
// leaves it False: spell/card grants do heavy work that can race the menu.
static function bool IsPlayerInPlayableState(harry h, out string DeferReason, optional bool bAllowInGameMenu)
{
    local string stateName;
    local HPHud hud;

    if (h == None || h.bDeleteMe)
    {
        DeferReason = "harry None/deleted";
        return False;
    }
    if (h.Player == None)
    {
        DeferReason = "harry has no Player (transitional)";
        return False;
    }

    stateName = string(h.GetStateName());
    if (stateName != "PlayerWalking")
    {
        DeferReason = "harry state=" $ stateName $ " (only PlayerWalking grants)";
        return False;
    }

    if (h.bIsCaptured)
    {
        DeferReason = "harry bIsCaptured";
        return False;
    }
    if (h.bKeepStationary)
    {
        DeferReason = "harry bKeepStationary (vendor)";
        return False;
    }

    hud = HPHud(h.myHUD);
    if (hud != None && hud.IsCutSceneOrPopupInProgress())
    {
        DeferReason = "HUD cutscene/popup in progress";
        return False;
    }

    // In-game pause menu (FEBook on the console). `bIsOpen` is True from
    // OpenBook (FEBook.uc:840) until CloseBook (FEBook.uc:880), covering
    // both the in-game pause menu (TogglePauseMenu → OpenBook("INGAME"))
    // and any other menu page. `bGamePlaying` was the wrong gate — it only
    // flips False on MainPage (title screen), not on the in-game menu.
    if (!bAllowInGameMenu
        && HPConsole(h.Player.Console) != None
        && HPConsole(h.Player.Console).menuBook != None
        && HPConsole(h.Player.Console).menuBook.bIsOpen)
    {
        DeferReason = "menuBook.bIsOpen=True (in-game menu open)";
        return False;
    }

    // Direct cutscene-actor check. `IsCutSceneOrPopupInProgress` only returns
    // True after the cutscene script has executed CAPTURE (which calls
    // HPHud.StartCutScene to flip bCutSceneMode/bCutPopupMode). For
    // bLevelLoadStarts cutscenes (the opening scenes that fire on level entry),
    // there's a window between "cutscene actor enters Running state" and
    // "cutscene script issues CAPTURE" where harry is briefly in PlayerWalking
    // with bIsCaptured=False and HUD cutscene mode is False — and our drain
    // would fire, applying start_inventory items mid-intro. Iterating active
    // CutScene actors closes that gap: any cutscene currently `bPlaying` means
    // we wait. Bounded N (a level holds <100 cutscene actors).
    if (HasActiveCutScene(h, DeferReason))
    {
        return False;
    }

    DeferReason = "";
    return True;
}

static function bool HasActiveCutScene(harry h, out string DeferReason)
{
    local CutScene cs;

    if (h == None) return False;
    foreach h.AllActors(class'CutScene', cs)
    {
        if (cs.bPlaying)
        {
            DeferReason = "CutScene playing: " $ cs.FileName;
            return True;
        }
    }
    return False;
}

static function harry FindGrantReadyHarry(Actor caller)
{
    local APCardWatcher watcher;
    local harry h;

    watcher = class'APCardWatcher'.static.GetLatest();
    if (watcher != None)
    {
        h = TryGetViewportHarry(watcher.HarryRef);
        if (h != None)
        {
            return h;
        }

        h = TryGetViewportHarry(harry(watcher.Level.PlayerHarryActor));
        if (h != None)
        {
            return h;
        }

        if (watcher.HarryRef != None && watcher.HarryRef.Player != None && !watcher.HarryRef.bDeleteMe)
        {
            return watcher.HarryRef;
        }

        h = harry(watcher.Level.PlayerHarryActor);
        if (h != None && h.Player != None && !h.bDeleteMe)
        {
            return h;
        }
    }

    h = TryGetViewportHarry(harry(caller.Level.PlayerHarryActor));
    if (h != None)
    {
        return h;
    }

    h = harry(caller.Level.PlayerHarryActor);
    if (h != None && h.Player != None && !h.bDeleteMe)
    {
        return h;
    }

    return None;
}

// Player-facing string for the HUD toast. Echoes the AP display name as-is —
// for cards, that name lives on the generated APCardMarker_<X>.DisplayName
// defaultprop (sourced from items.yaml, e.g. "Silver Card - Duke"); for
// non-cards, the GRANT payload itself already IS the AP item name.
// `Sender` is empty when the IPC payload had no sender field (older client
// builds, or any path that bypasses the GRANT pipe-encoded format).
function string FormatGrantText(string ItemName, string Sender)
{
    local class<APCardMarker> markerCls;
    local string display, base;

    display = ItemName;
    if (Left(ItemName, 2) == "WC")
    {
        markerCls = class<APCardMarker>(DynamicLoadObject("HPArchipelago.APCardMarker_" $ ItemName, class'Class'));
        if (markerCls != None && markerCls.default.DisplayName != "")
        {
            display = markerCls.default.DisplayName;
        }
    }
    base = "Received " $ display;
    if (Sender != "")
    {
        base = base $ " from " $ Sender;
    }
    return base;
}

// AP-granted bean filler must not be mirrored by RingLink: the recipient
// already received the AP item, so broadcasting the AddBeans as an organic
// delta would double-count it across every linked slot. Route every AP
// bean grant through the persistent APIPCActor's no-broadcast helper, which
// resyncs the RingLink baseline after mutating so the next poll sees a zero
// delta. Direct AddBeans fallback only if the IPC actor is somehow absent —
// beans must never be silently dropped.
function GrantBeansNoBroadcast(harry h, int Amount)
{
    local APIPCActor ipc;

    if (h == None || h.managerStatus == None)
    {
        return;
    }
    ipc = class'APIPCActor'.static.GetInstance();
    if (ipc != None)
    {
        ipc.MutateBeansNoBroadcast(h, Amount);
    }
    else
    {
        h.managerStatus.AddBeans(Amount);
    }
}

// Archipelago trap items (ItemClassification.trap). All grant-driven, fired
// from the GRANT line exactly like the bean/potion filler branches. One-shot:
// Client.NON_DURABLE_ITEM_NAMES keeps a trap from re-firing on reconnect /
// durable resync. Each trap self-terminates:
//   Bean Thief    - instant, permanent by design (beans clamp at 0).
//   Goyle         - reverts on the next level's fresh (bIsGoyle=false) pawn.
//   Forgetfulness - APCardWatcher restores the spellbook on a timer or the
//                   next level transition, whichever comes first.
//
// Spider Swarm and Peeves were cut from v1: they require an ad-hoc visible
// world actor spawned mid-level, which this M212 bingo build does not render
// (proven by a card-marker-clone bisect - a free-standing actor with the
// exact mesh the card markers render with stayed invisible solely because it
// was Spawn()'d at runtime rather than built during level bring-up).
function bool TryApplyTrap(string Name, harry h)
{
    local int beans, lost;

    if (h == None)
    {
        return False;
    }

    if (Name == "Bean Thief Trap")
    {
        if (h.managerStatus != None)
        {
            beans = h.managerStatus.GetBeanCount();
            // Steal amount. min(N, current) so the count never goes negative
            // (StatusItem.SetCount also floors at 0 — belt-and-suspenders).
            // Per-trap tuning/weighting is a documented v2 extension.
            lost = 200;
            if (lost > beans)
            {
                lost = beans;
            }
            if (lost > 0)
            {
                // Route the decrement through RingLink's shared no-broadcast
                // bean helper (04-ringlink.md §6.0) so the steal stays LOCAL
                // (not mirrored room-wide like every other trap) and the
                // RingLink poll baseline is resynced. Degrades to a clamped
                // AddBeans when the IPC actor is absent — same call site
                // either way, so enabling RingLink later needs no change here.
                GrantBeansNoBroadcast(h, -lost);
            }
            Log("[Archipelago] ApplyGrant: Bean Thief Trap - stole " $ lost $ " beans (had " $ beans $ ")");
        }
        return True;
    }

    if (Name == "Goyle Transformation Trap")
    {
        // Model swap only (harry.uc:4136 SetNewMesh swaps the mesh when
        // bIsGoyle flips). The next level loads a fresh pawn with the default
        // bIsGoyle=false, so this reverts naturally — the watcher sticky just
        // records it and clears on the level change.
        h.bIsGoyle = True;
        h.SetNewMesh();
        class'APCardWatcher'.static.MarkGoyleTrapActiveDefault(h);
        Log("[Archipelago] ApplyGrant: Goyle Transformation Trap - applied (reverts next level)");
        return True;
    }

    if (Name == "Forgetfulness Trap")
    {
        // Back up the spellbook into an APCardWatcher class-default (survives
        // the per-level watcher respawn and save-load) then clear it. The
        // watcher restores on a timer or the next level transition, whichever
        // comes first, so spells are never permanently lost.
        class'APCardWatcher'.static.BackupAndClearSpellBook(h);
        Log("[Archipelago] ApplyGrant: Forgetfulness Trap - spellbook backed up + cleared");
        return True;
    }

    return False;
}

function ApplyGrant(string Body)
{
    local harry h;
    local APHUDToast toast;
    local string ItemName, Sender;
    local int pipeIdx;

    // Body is `<itemname>` (legacy) or `<itemname>|<sender>` (client
    // post-2026-05-12 sends the AP slot name as the sender). Parse out
    // both so the toast can include "from <sender>" without the rest of
    // ApplyGrant caring.
    pipeIdx = InStr(Body, "|");
    if (pipeIdx >= 0)
    {
        ItemName = Left(Body, pipeIdx);
        Sender = Mid(Body, pipeIdx + 1);
    }
    else
    {
        ItemName = Body;
        Sender = "";
    }

    Log("[Archipelago] APGameInfo.ApplyGrant: " $ ItemName $ " (sender='" $ Sender $ "')");

    h = FindGrantReadyHarry(self);
    if (h == None)
    {
        Log("[Archipelago] ApplyGrant: no ready gameplay harry to deliver to");
        return;
    }
    Log("[Archipelago] ApplyGrant: targeting harry=" $ string(h) $ " managerStatus=" $ string(h.managerStatus));

    // HUD toast feedback. Fires once per successful grant arrival — past
    // FindGrantReadyHarry means delivery is happening (or about to). The
    // grant queue's drain spacing (0.75s) prevents toast flooding.
    // Chocolate Frog gets a per-item override sound (the vanilla frog
    // pickup ribbit) instead of the generic vendor whoosh.
    toast = class'APHUDToast'.static.GetInstance();
    if (toast != None)
    {
        toast.EnqueueToast(FormatGrantText(ItemName, Sender), GetGrantSoundForItem(ItemName));
    }

    if (IsKnownSpellName(ItemName))
    {
        Log("[Archipelago] ApplyGrant: spell " $ ItemName $ " - marking AP-granted + AddToSpellBookByString");
        // Always set the class-default flag — works even when no watcher
        // instance is alive (e.g. during Save0.usa load gap). Next level's
        // watcher PreBeginPlay will copy default -> instance.
        class'APCardWatcher'.static.MarkSpellAsAPGrantedDefault(ItemName);
        if (class'APCardWatcher'.static.GetLatest() != None)
        {
            class'APCardWatcher'.static.GetLatest().MarkSpellAsGranted(ItemName);
        }
        h.AddToSpellBookByString(ItemName);
        if (ItemName == "Rictusempra")
        {
            RemoveRictaBlocker();
        }
        else if (ItemName == "Skurge")
        {
            RemoveSkurgeBlocker();
        }
        else if (ItemName == "Diffindo")
        {
            RemoveDiffindoBlocker();
        }
        else if (ItemName == "Spongify")
        {
            RemoveSpongifyBlocker();
        }
        return;
    }

    if (TryApplyKeyItem(ItemName, h))
    {
        return;
    }

    if (TryApplyBingoKey(ItemName))
    {
        return;
    }

    if (TryApplyEquipment(ItemName, h))
    {
        return;
    }

    if (ItemName == "Small Pile of Beans")
    {
        GrantBeansNoBroadcast(h, 25);
        Log("[Archipelago] ApplyGrant: granted Small Pile of Beans (+25)");
        return;
    }
    if (ItemName == "Medium Pile of Beans")
    {
        GrantBeansNoBroadcast(h, 50);
        Log("[Archipelago] ApplyGrant: granted Medium Pile of Beans (+50)");
        return;
    }
    if (ItemName == "Large Pile of Beans")
    {
        GrantBeansNoBroadcast(h, 100);
        Log("[Archipelago] ApplyGrant: granted Large Pile of Beans (+100)");
        return;
    }
    if (ItemName == "Massive Pile of Beans")
    {
        GrantBeansNoBroadcast(h, 250);
        Log("[Archipelago] ApplyGrant: granted Massive Pile of Beans (+250)");
        return;
    }
    // Small bean denominations — same no-broadcast bean path as the Piles,
    // just tiny amounts so common filler barely moves the bean total.
    if (ItemName == "1 Bean")
    {
        GrantBeansNoBroadcast(h, 1);
        Log("[Archipelago] ApplyGrant: granted 1 Bean (+1)");
        return;
    }
    if (ItemName == "5 Beans")
    {
        GrantBeansNoBroadcast(h, 5);
        Log("[Archipelago] ApplyGrant: granted 5 Beans (+5)");
        return;
    }
    if (ItemName == "10 Beans")
    {
        GrantBeansNoBroadcast(h, 10);
        Log("[Archipelago] ApplyGrant: granted 10 Beans (+10)");
        return;
    }
    // Wiggenweld Potion: usable inventory item that auto-refills HP at low
    // health (and is manually-usable from the in-game menu). Mirrors vanilla
    // `harry.AddWiggenwellPotion` path which calls IncrementCount on
    // StatusGroupPotions/StatusItemWiggenwell. Adds +1 to the held-potion count.
    if (ItemName == "Wiggenweld Potion")
    {
        h.managerStatus.IncrementCount(class'StatusGroupPotions', class'StatusItemWiggenwell', 1);
        Log("[Archipelago] ApplyGrant: granted Wiggenweld Potion (+1 to StatusItemWiggenwell)");
        return;
    }
    // Wiggentree Bark + Flobberworm Mucous: cauldron-brewing ingredients held
    // in the StatusGroupPotionIngr inventory. Mirrors StatusManager.AddBark /
    // AddMucus (StatusManager.uc:248-263). Adds +1 to the ingredient stack;
    // player can then brew a Wiggenweld Potion from a cauldron when they have
    // both ingredients.
    if (ItemName == "Wiggentree Bark")
    {
        h.managerStatus.IncrementCount(class'StatusGroupPotionIngr', class'StatusItemWiggenBark', 1);
        Log("[Archipelago] ApplyGrant: granted Wiggentree Bark (+1 to StatusItemWiggenBark)");
        return;
    }
    if (ItemName == "Flobberworm Mucous")
    {
        h.managerStatus.IncrementCount(class'StatusGroupPotionIngr', class'StatusItemFlobberMucus', 1);
        Log("[Archipelago] ApplyGrant: granted Flobberworm Mucous (+1 to StatusItemFlobberMucus)");
        return;
    }
    // Chocolate Frog: partial HP refill. Vanilla `ChocolateFrog.nPickupIncrement=40`
    // on a StatusGroupHealth/StatusItemHealth pickup — we replicate that by
    // calling managerStatus.AddHealth(40), which caps at the current max.
    if (ItemName == "Chocolate Frog")
    {
        h.managerStatus.AddHealth(40);
        Log("[Archipelago] ApplyGrant: granted Chocolate Frog (+40 HP)");
        return;
    }

    if (TryApplyCard(ItemName, h))
    {
        return;
    }

    if (TryApplyTrap(ItemName, h))
    {
        return;
    }

    Log("[Archipelago] ApplyGrant: unknown item " $ ItemName);
}

// Returns a per-item toast sound override so audible feedback matches the
// granted item's flavor instead of the generic vendor whoosh. None for items
// without a flavor sound — the toast falls back to its default ToastSound.
function Sound GetGrantSoundForItem(string ItemName)
{
    if (ItemName == "Chocolate Frog")
    {
        return Sound(DynamicLoadObject("HPSounds.Critters_sfx.pickup_frog", class'Sound'));
    }
    return None;
}

defaultproperties
{
    RictaBlockerOffset=(X=-15.000000,Y=130.000000,Z=0.000000)
    SkurgeBlockerOffset=(X=7.000000,Y=-230.000000,Z=-20.000000)
    SpongifyBlockerOffset=(X=-15.000000,Y=131.000000,Z=0.000000)
    SpongifyGameStateGate=130
    DiffindoBlockerOffsets(0)=(X=50.000000,Y=-172.000000,Z=-20.000000)
    DiffindoBlockerOffsets(1)=(X=50.000000,Y=-5.000000,Z=-20.000000)
    DiffindoBlockerOffsets(2)=(X=50.000000,Y=162.000000,Z=-20.000000)
    SlytherinEndStarLocation=(X=-206.795639,Y=-11138.078125,Z=-379.500000)
    SlytherinEndStarRotation=(Pitch=0,Yaw=0,Roll=0)
}

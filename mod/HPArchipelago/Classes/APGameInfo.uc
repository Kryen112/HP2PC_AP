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

    ReplaceCardChests();
    BlockRictaClassroomIfMissing();
    BlockSkurgeClassroomIfMissing();
    BlockDiffindoClassroomIfMissing();
    BlockSpongifyClassroomIfMissing();
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
            Log("[Archipelago] FindActiveHarry: using watcher console Viewport.Actor=" $ string(h) $ " (watcher.Level=" $ string(watcher.Level) $ ")");
            return h;
        }
        h = harry(watcher.Level.PlayerHarryActor);
        if (h != None && !h.bDeleteMe)
        {
            Log("[Archipelago] FindActiveHarry: using watcher.Level.PlayerHarryActor=" $ string(h) $ " (watcher.Level=" $ string(watcher.Level) $ ")");
            return h;
        }
        if (watcher.HarryRef != None && !watcher.HarryRef.bDeleteMe)
        {
            Log("[Archipelago] FindActiveHarry: using watcher.HarryRef=" $ string(watcher.HarryRef));
            return watcher.HarryRef;
        }
    }

    h = TryGetViewportHarry(harry(caller.Level.PlayerHarryActor));
    if (h != None)
    {
        Log("[Archipelago] FindActiveHarry: using caller console Viewport.Actor=" $ string(h));
        return h;
    }

    h = harry(caller.Level.PlayerHarryActor);
    if (h != None && !h.bDeleteMe)
    {
        Log("[Archipelago] FindActiveHarry: fallback to caller.Level.PlayerHarryActor=" $ string(h));
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
    if (fallback != None)
    {
        Log("[Archipelago] FindActiveHarry: last-resort foreach fallback=" $ string(fallback));
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
static function bool IsPlayerInPlayableState(harry h, out string DeferReason)
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
            Log("[Archipelago] FindGrantReadyHarry: using watcher.HarryRef console Viewport.Actor=" $ string(h));
            return h;
        }

        h = TryGetViewportHarry(harry(watcher.Level.PlayerHarryActor));
        if (h != None)
        {
            Log("[Archipelago] FindGrantReadyHarry: using watcher.Level.PlayerHarryActor console Viewport.Actor=" $ string(h));
            return h;
        }

        if (watcher.HarryRef != None && watcher.HarryRef.Player != None && !watcher.HarryRef.bDeleteMe)
        {
            Log("[Archipelago] FindGrantReadyHarry: using watcher.HarryRef=" $ string(watcher.HarryRef));
            return watcher.HarryRef;
        }

        h = harry(watcher.Level.PlayerHarryActor);
        if (h != None && h.Player != None && !h.bDeleteMe)
        {
            Log("[Archipelago] FindGrantReadyHarry: using watcher.Level.PlayerHarryActor=" $ string(h));
            return h;
        }
    }

    h = TryGetViewportHarry(harry(caller.Level.PlayerHarryActor));
    if (h != None)
    {
        Log("[Archipelago] FindGrantReadyHarry: using caller console Viewport.Actor=" $ string(h));
        return h;
    }

    h = harry(caller.Level.PlayerHarryActor);
    if (h != None && h.Player != None && !h.bDeleteMe)
    {
        Log("[Archipelago] FindGrantReadyHarry: using caller.Level.PlayerHarryActor=" $ string(h));
        return h;
    }

    return None;
}

// Player-facing string for the HUD toast. Builds "Received <tier> card: X
// from <Y>" for cards (tier read from the corresponding APCardMarker_<X>
// subclass's MarkerTier defaultprop), translates
// bean tiers to counts, and otherwise passes the raw item name through.
// `Sender` is empty when the IPC payload had no sender field (older client
// builds, or any path that bypasses the GRANT pipe-encoded format).
function string FormatGrantText(string ItemName, string Sender)
{
    local class<APCardMarker> markerCls;
    local string base, tier;

    if (Left(ItemName, 2) == "WC")
    {
        markerCls = class<APCardMarker>(DynamicLoadObject("HPArchipelago.APCardMarker_" $ ItemName, class'Class'));
        if (markerCls != None)
        {
            if      (markerCls.default.MarkerTier == "Bronze") tier = "bronze ";
            else if (markerCls.default.MarkerTier == "Silver") tier = "silver ";
            else if (markerCls.default.MarkerTier == "Gold")   tier = "gold ";
            else                                                tier = "";
        }
        base = "Received " $ tier $ "card " $ Mid(ItemName, 2);
    }
    else                                base = "Received " $ ItemName;

    if (Sender != "")
    {
        base = base $ " from " $ Sender;
    }
    return base;
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
    toast = class'APHUDToast'.static.GetInstance();
    if (toast != None)
    {
        toast.EnqueueToast(FormatGrantText(ItemName, Sender));
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

    if (TryApplyEquipment(ItemName, h))
    {
        return;
    }

    if (ItemName == "Small Pile of Beans")
    {
        h.managerStatus.AddBeans(25);
        Log("[Archipelago] ApplyGrant: granted Small Pile of Beans (+25)");
        return;
    }
    if (ItemName == "Medium Pile of Beans")
    {
        h.managerStatus.AddBeans(50);
        Log("[Archipelago] ApplyGrant: granted Medium Pile of Beans (+50)");
        return;
    }
    if (ItemName == "Large Pile of Beans")
    {
        h.managerStatus.AddBeans(100);
        Log("[Archipelago] ApplyGrant: granted Large Pile of Beans (+100)");
        return;
    }

    if (TryApplyCard(ItemName, h))
    {
        return;
    }

    Log("[Archipelago] ApplyGrant: unknown item " $ ItemName);
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
}

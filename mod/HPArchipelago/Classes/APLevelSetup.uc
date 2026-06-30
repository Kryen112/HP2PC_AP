// Per-level world-object swaps, run once per Snapshot: subclass-replace the
// challenge stars / Gryffindor end star / Gold Card Room end trigger with their
// AP-aware variants, neutralise the open-castle Gryffindor spell giver, and
// (re)spawn the classroom blockers + per-level HUD toast on the save-load path
// that skips APGameInfo.InitGame. Pure static helpers: each takes the caller's
// Actor as context for Level / AllActors / Spawn, and a harry where it touches
// the pawn, so they are safe to call from the watcher's PreBeginPlay with no
// helper actor to spawn. All idempotent via world-state guards (ClassIsChildOf
// on the already-swapped actor, the watcher's NonCardLocationChecked ledger, or
// the blockers' own tag scan).
class APLevelSetup extends Object;

// Snapshot-time: subclass-replace each unchecked vanilla ChallengeStar with
// an APChallengeStarMarker carrying the AP location id baked in. The marker
// inherits the entire ChallengeStar pickup pipeline (mesh, sound, fly-to-HUD,
// PickedUpStar score increment via PickupProp.EndState's Super call); it only
// adds the CHECK_LOCID fire. Already-checked locations are left as vanilla
// stars so level replay still grants vanilla score but never re-fires AP.
// Skips actors already of our subclass so re-running is idempotent.
static function ReplaceChallengeStars(Actor ctx)
{
    local ChallengeStar star;
    local APChallengeStarMarker apStar;
    local Vector loc;
    local Rotator rot;
    local Actor vanillaBase;
    local Name vanillaTag;
    local string levelName, markerName;
    local int locId, slot, replaced;
    local APMorphRegistry mr;

    levelName = string(ctx.Level.Outer.Name);
    replaced = 0;
    foreach ctx.AllActors(class'ChallengeStar', star)
    {
        if (ClassIsChildOf(star.Class, class'APChallengeStarMarker')) continue;

        markerName = string(star.Name);
        locId = class'APLocationRegistry'.static.GetStarLocationId(levelName, markerName);
        if (locId == 0) continue;
        slot = class'APLocationRegistry'.static.SlotForApId(locId);
        if (slot < 0) continue;
        if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) continue;

        // Capture mover-attachment state before destroying the vanilla star.
        // Many challenge-level stars ride moving platforms. The mover wires
        // each star's Base at level load by matching its AttachTag against
        // the star's Tag. A naive Destroy + Spawn at the same Location/
        // Rotation drops the Base linkage, leaving the new actor sitting
        // stationary while its platform travels off. Copying Tag (defensive,
        // for any system that later inspects it) and re-running SetBase on
        // the replacement restores the linkage so the engine carries the
        // replacement along with the platform every tick like vanilla.
        loc = star.Location;
        rot = star.Rotation;
        vanillaBase = star.Base;
        vanillaTag = star.Tag;
        star.Destroy();
        apStar = ctx.Spawn(class'APChallengeStarMarker', , , loc, rot);
        if (apStar == None)
        {
            Log("[Archipelago] APLevelSetup.ReplaceChallengeStars: Spawn returned None at "
                $ string(loc) $ " for AP id " $ locId);
            continue;
        }
        apStar.CheckLocationId = locId;
        // Id is now known: opt this marker into the appearance sweep and
        // best-effort morph it (no-op until the table arrives).
        mr = class'APMorphRegistry'.static.GetInstance(ctx);
        if (mr != None) mr.RegisterMorphMarker(apStar, locId);
        apStar.ApplyAPAppearance();
        if (vanillaTag != 'None')
        {
            apStar.Tag = vanillaTag;
        }
        if (vanillaBase != None)
        {
            apStar.SetBase(vanillaBase);
        }
        replaced++;
    }
    if (replaced > 0)
    {
        Log("[Archipelago] APLevelSetup.ReplaceChallengeStars: replaced " $ replaced
            $ " vanilla star(s) with AP markers in " $ levelName);
    }
}

// Open-castle-only Snapshot-path safety net for the Gryffindor spell giver. The
// PRIMARY kill is APGameInfo.DestroyGryffindorSpellGiver (InitGame, pre-Harry).
// By Snapshot the level-start dispatcher has usually already fired the
// TriggerTurnOnAllSpells and set harry.bNoSpellBookCheck=True. This still
// destroys any surviving giver (covers the save-load path, where
// ProcessServerTravel skips InitGame and the level package re-instantiates
// the actor) AND clears bNoSpellBookCheck so IsInSpellBook stops reporting
// every spell as owned (harry.uc:568). The per-tick clear in the reconcile
// loop is the continuous guarantee. Class match is by class-name string (no
// hard ref). Vanilla never enters this level so the giver is left intact.
static function NeutralizeGryffindorSpellGiver(Actor ctx, harry h)
{
    local Actor a;
    local int n;

    if (Caps(string(ctx.Level.Outer.Name)) != "CH7GRYFFINDOR") return;
    if (class'APModeDetector'.default.bOpenCastleMode != 1) return;

    foreach ctx.AllActors(class'Actor', a)
    {
        if (!a.bDeleteMe && string(a.Class.Name) == "TriggerTurnOnAllSpells")
        {
            a.Destroy();
            n++;
        }
    }
    if (h != None)
    {
        h.bNoSpellBookCheck = False;
    }
    Log("[Archipelago] NeutralizeGryffindorSpellGiver: destroyed " $ n
        $ " TriggerTurnOnAllSpells actor(s) + cleared bNoSpellBookCheck (CH7GRYFFINDOR open castle)");
}

// Ch7Gryffindor ships a FinalStar that is present from level start but NO
// ChallengeScoreManager, so picking it up travels to the hub on the same frame it
// is destroyed - APLocationScanner.ScanFinalStarCompletion's present->absent poll
// never catches it (see APGryffindorEndStar). Swap the placed FinalStar for an
// AP-aware end star that credits the completion in EndState before travelling, the
// same destroy+respawn pattern as ReplaceChallengeStars. Level-gated to
// CH7GRYFFINDOR; runs in both game modes (the "Gryffindor Challenge - Complete"
// check exists in both).
static function ReplaceGryffindorEndStar(Actor ctx)
{
    local FinalStar fs;
    local APGryffindorEndStar apStar;
    local Vector loc;
    local Rotator rot;
    local int replaced;

    if (Caps(string(ctx.Level.Outer.Name)) != "CH7GRYFFINDOR") return;

    foreach ctx.AllActors(class'FinalStar', fs)
    {
        if (fs == None || fs.bDeleteMe) continue;
        // Skip a replacement from a prior Snapshot this level so a second bind
        // does not destroy+respawn the AP star (and so the freshly Spawned one
        // below is never revisited by this same iteration).
        if (ClassIsChildOf(fs.Class, class'APGryffindorEndStar')) continue;

        loc = fs.Location;
        rot = fs.Rotation;
        fs.Destroy();
        apStar = ctx.Spawn(class'APGryffindorEndStar', None, 'APGryffindorEndStar', loc, rot);
        if (apStar == None)
        {
            Log("[Archipelago] APLevelSetup.ReplaceGryffindorEndStar: Spawn returned None at "
                $ string(loc));
            continue;
        }
        replaced++;
    }
    if (replaced > 0)
    {
        Log("[Archipelago] APLevelSetup.ReplaceGryffindorEndStar: replaced " $ replaced
            $ " vanilla FinalStar(s) with AP end star in CH7GRYFFINDOR");
    }
}

// Subclass-replace Ch6WizardCard's far-end TriggerChangeLevel (tag changelevel1)
// with an APTriggerChangeLevel so reaching the end of the Gold Card Room credits
// clause-3 objective idx 12 (the room's 13th level-completion). The room's OTHER
// TriggerChangeLevel (tag TriggerChangeLevel, by the entrance) bails to the hub
// and must stay vanilla, so we key on the tag, not the class. The end trigger
// reloads the same level, so the exit-credit path never sees it; the AP subclass
// fires the check before the stock reload. CollisionRadius/Height are copied so
// the swapped-in volume covers the same spot. No-op outside CH6WIZARDCARD; runs
// in both modes (the completion is a real AP location in vanilla too).
static function ReplaceGoldRoomEndTrigger(Actor ctx)
{
    local TriggerChangeLevel tcl;
    local APTriggerChangeLevel apTcl;
    local Vector loc;
    local Rotator rot;
    local string mapName;
    local float colRadius, colHeight;
    local int replaced;

    if (Caps(string(ctx.Level.Outer.Name)) != "CH6WIZARDCARD") return;

    foreach ctx.AllActors(class'TriggerChangeLevel', tcl)
    {
        if (tcl == None || tcl.bDeleteMe) continue;
        if (tcl.Tag != 'changelevel1') continue;  // end trigger only, not the entrance one
        // Skip a replacement from a prior Snapshot this level so a second bind
        // does not destroy+respawn the AP trigger.
        if (ClassIsChildOf(tcl.Class, class'APTriggerChangeLevel')) continue;

        loc = tcl.Location;
        rot = tcl.Rotation;
        mapName = tcl.NewMapName;
        colRadius = tcl.CollisionRadius;
        colHeight = tcl.CollisionHeight;
        tcl.Destroy();
        apTcl = ctx.Spawn(class'APTriggerChangeLevel', None, 'changelevel1', loc, rot);
        if (apTcl == None)
        {
            Log("[Archipelago] APLevelSetup.ReplaceGoldRoomEndTrigger: Spawn returned None at "
                $ string(loc));
            continue;
        }
        apTcl.NewMapName = mapName;
        apTcl.SetCollisionSize(colRadius, colHeight);
        replaced++;
    }
    if (replaced > 0)
    {
        Log("[Archipelago] APLevelSetup.ReplaceGoldRoomEndTrigger: replaced " $ replaced
            $ " end trigger(s) (tag changelevel1) with AP trigger in CH6WIZARDCARD");
    }
}

// Per-level (re)spawn of the classroom blockers, cutscene-skip policy, and HUD
// toast via APGameInfo. InitGame does this on a fresh level entry; this path
// covers save-load (ProcessServerTravel skips InitGame). Every Block* is
// idempotent via its own tag scan, so calling here in addition to InitGame can
// never double-spawn.
static function TrySpawnClassroomBlockers(Actor ctx)
{
    local APGameInfo gi;
    gi = APGameInfo(ctx.Level.Game);
    if (gi == None)
    {
        Log("[Archipelago] APLevelSetup: can't spawn classroom blockers - Level.Game is not APGameInfo");
        return;
    }
    gi.BlockRictaClassroomIfMissing();
    gi.BlockSkurgeClassroomIfMissing();
    gi.BlockDiffindoClassroomIfMissing();
    gi.BlockSpongifyClassroomIfMissing();
    gi.SpawnAllOpenCastleBlockers();
    // Re-apply per-level so save-load (which skips APGameInfo.InitGame)
    // still gets cutscene skip policy enforced for the freshly-loaded level.
    gi.ForceCutScenesSkippable();
    // APHUDToast is per-level; save-load needs it spawned here since
    // APGameInfo.InitGame doesn't run on that path.
    gi.SpawnAPHUDToastIfMissing();
}

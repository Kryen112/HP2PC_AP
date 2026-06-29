//=============================================================================
// APConsole. Dev-only console subclass for bookcase placement.
//
// Activated by patching Modded\system\Default.ini:
//   [Engine.Engine]
//   Console=HPArchipelago.APConsole   ; default: HGame.HPConsole
//
// Adds exec commands callable from the in-game console (~ key):
//
//   LogPos          one-shot log of harry's Location + Rotation to Game.log.
//                     Complements stock HP2's ShowPos (which only shows X/Y/Z
//                     on the HUD); LogPos captures Rotation too, in the same
//                     pretty-printed form a Block<X>IfMissing helper expects.
//
//   Note            free-form label line in Game.log next to nearby LogPos /
//                     PlaceBookcase output, so one grep recovers a spot's name.
//
//   DumpActors      log every actor (optionally class-name-substring-filtered)
//                     with class/name/tag/location. Used to identify the boss
//                     and level-exit-trigger classes the §6 goal detector keys
//                     off.
//
//   PlaceBookcase   spawns a BookcaseGlassDoors at harry's current Location,
//                     facing the same direction harry is looking. Stand at the
//                     spot, look in the direction you want the bookcase's front
//                     to face, fire the command. Bookcase is tagged
//                     APDebugBookcase so it's idempotent / removable. Location +
//                     Rotation get logged for later transcription.
//
//   ClearBookcases  destroys every APDebugBookcase-tagged actor in the level.
//                     For wiping a misplaced preview before respawning.
//
// Freecam keys (debug mode on; Delete toggles the freecam):
//   WASD: fly the freecam, mirroring the stock arrow keys. Forward follows where
//     the camera looks, so mouse-aim plus WASD covers full movement. The arrow
//     keys and numpad still work.
//   Shift (hold): fly faster. Harry is frozen during freecam, so this never
//     spends beans the way the in-game shift-to-run sprint does.
//
// Release builds ship with Default.ini's Console= line unchanged, so end users
// never instantiate this subclass. The .u compiles it in but the engine picks
// HGame.HPConsole and never sees these execs.
//=============================================================================

class APConsole extends HPConsole;

// Shift-to-run speed multiplier for the freecam.
const FREECAM_BOOST_MULTIPLIER = 3.0;

// Pre-boost freecam move speed, captured when Shift goes down so the exact cruise
// speed is restored on release (preserves any manual Cam_MoveSpeed tweak).
var float FreeCamBaseSpeed;
// 1 while the Shift speed boost is applied. Guards against re-capturing the
// already-boosted speed on a repeated press.
var byte bFreeCamBoosted;

// Print a string to both Game.log AND the in-game chat overlay. Without the
// ClientMessage path the player has no visible feedback from these execs.
// LogPos and PlaceBookcase appear to do nothing when invoked, because all
// their output lands in Game.log which the player has to alt-tab to read.
function DevPrint(string msg)
{
    Log("[Archipelago] " $ msg);
    if (Viewport != None && Viewport.Actor != None)
    {
        Viewport.Actor.ClientMessage(msg);
    }
}

// Freecam WASD + Shift-to-run. The stock freecam (Delete in debug mode) flies on
// baseConsole's bForwardKeyDown / bBackKeyDown / bLeftKeyDown / bRightKeyDown
// flags, which HPConsole only sets from the arrow keys and the numpad. Mirror
// WASD onto the same four flags so the freecam also flies on WASD. The flags are
// set unconditionally, exactly like the arrow keys: only StateFreeCam reads them,
// so they stay inert outside the freecam. Shift raises the freecam speed while
// held; the boost is gated to CM_Free so it cannot disturb any other camera mode.
// Everything else defers to the parent, whose return value is passed through.
event bool KeyEvent (EInputKey Key, EInputAction Action, float Delta)
{
    if (Action == IST_Press)
    {
        switch (Key)
        {
            case IK_W:      bForwardKeyDown = True;  break;
            case IK_S:      bBackKeyDown    = True;  break;
            case IK_A:      bLeftKeyDown    = True;  break;
            case IK_D:      bRightKeyDown   = True;  break;
            case IK_Shift:  ApplyFreeCamBoost();     break;
        }
    }
    else if (Action == IST_Release)
    {
        switch (Key)
        {
            case IK_W:       bForwardKeyDown = False;  break;
            case IK_S:       bBackKeyDown    = False;  break;
            case IK_A:       bLeftKeyDown    = False;  break;
            case IK_D:       bRightKeyDown   = False;  break;
            case IK_Shift:   RemoveFreeCamBoost();     break;
            // Toggling the freecam resets the boost latch so a held Shift can
            // re-engage cleanly in the next freecam session.
            case IK_Delete:  bFreeCamBoosted = 0;      break;
        }
    }
    return Super.KeyEvent(Key, Action, Delta);
}

// Raise the freecam move speed while Shift is held. Captures the live speed first
// so a manual Cam_MoveSpeed tweak survives the boost. No-op outside the freecam
// or when the boost is already applied.
function ApplyFreeCamBoost()
{
    local harry h;

    if (Viewport == None || Viewport.Actor == None)
    {
        return;
    }
    h = harry(Viewport.Actor);
    if (h == None || h.Cam == None)
    {
        return;
    }
    if (h.Cam.CameraMode != h.Cam.ECamMode.CM_Free || bFreeCamBoosted == 1)
    {
        return;
    }
    FreeCamBaseSpeed = h.Cam.CurrentSet.fMoveSpeed;
    h.Cam.SetMoveSpeed(FreeCamBaseSpeed * FREECAM_BOOST_MULTIPLIER);
    bFreeCamBoosted = 1;
}

// Restore the pre-boost freecam speed when Shift is released. Clears the latch
// even if the camera already left the freecam, so a later Shift boosts again.
function RemoveFreeCamBoost()
{
    local harry h;

    if (bFreeCamBoosted == 0)
    {
        return;
    }
    bFreeCamBoosted = 0;
    if (Viewport == None || Viewport.Actor == None)
    {
        return;
    }
    h = harry(Viewport.Actor);
    if (h == None || h.Cam == None)
    {
        return;
    }
    if (h.Cam.CameraMode == h.Cam.ECamMode.CM_Free)
    {
        h.Cam.SetMoveSpeed(FreeCamBaseSpeed);
    }
}

// Free-form annotation. Call as e.g.
//   Note GreenhouseEntry
//   Note "Greenhouse entry, north door, gate on Alohomora"
// The string lands in Game.log next to whatever PlaceBookcase / LogPos lines
// you fire around the same time, so a single grep recovers the spot's label.
exec function Note(string Msg)
{
    DevPrint("Note: " $ Msg);
}

exec function LogPos()
{
    if (Viewport == None || Viewport.Actor == None)
    {
        Log("[Archipelago] APConsole.LogPos: no Viewport.Actor");
        return;
    }
    DevPrint("LogPos: Location=" $ string(Viewport.Actor.Location) $ " Rotation=" $ string(Viewport.Actor.Rotation));
}

// Actor identification for Phase 4 auto-detection: find the
// per-level actors the detector keys off: boss classes for Forbidden Forest /
// Chamber, and the level-exit / level-change trigger for the challenges +
// Whomping Willow + Slytherin Common Room. Stand in the level and fire:
//   DumpActors            every actor (verbose; large in hub levels)
//   DumpActors TRIGGER    only classes whose name contains "TRIGGER"
//   DumpActors BASILISK   substring match on the class name
// Per-actor lines go to Game.log only (could be hundreds); the header/footer
// echo to the chat overlay so the player sees it ran. Level name is the Caps'd
// map name OpenCastleLevelIs() compares against.
exec function DumpActors(optional string Filter)
{
    local Actor a;
    local string cf;
    local int n;

    if (Viewport == None || Viewport.Actor == None)
    {
        Log("[Archipelago] APConsole.DumpActors: no Viewport.Actor");
        return;
    }
    cf = Caps(Filter);
    DevPrint("DumpActors Level=" $ Caps(string(Viewport.Actor.Level.Outer.Name))
        $ " Filter='" $ Filter $ "' - see Game.log");
    foreach Viewport.Actor.AllActors(class'Actor', a)
    {
        if (cf != "" && InStr(Caps(string(a.Class.Name)), cf) < 0)
        {
            continue;
        }
        Log("[Archipelago]   actor class=" $ string(a.Class.Name)
            $ " name=" $ string(a.Name)
            $ " tag=" $ string(a.Tag)
            $ " loc=" $ string(a.Location));
        n++;
    }
    DevPrint("DumpActors: " $ n $ " actor(s) logged");
}

// containersanity census. Log every in-scope bean-dropping container in the
// current level with the fields the codegen needs: level, family, class,
// Name (the stable key the runtime resolves via GetContainerLocationId), tag,
// opening spell (eVulnerableToSpell ordinal: 0=None, 1=Alohomora, 13=Flipendo),
// lives, whether it already hosts a wizard card, the classes it ejects, and
// location. The parser keeps only true bean-droppers: it drops hascard=1 (those
// stay CARD locations), spell=0 (decorative props that can't be opened), and
// non-bean spawners (ingredient Bark/Mucus, etc.) by inspecting drops=. Per-
// container lines go to Game.log; the header/footer echo to chat. Run once on
// fresh entry to each level (walk the whole castle to cover every map;
// GenericSpawner toggles its own spell mid-hit, so a fresh level reads the true
// opening spell):
//   DumpContainers
exec function DumpContainers()
{
    local chestbronze chest;
    local BronzeCauldron bcaul;
    local HCauldron hcaul;
    local GenericSpawner gs;
    local HFlipendo vase;
    local string lvl, cn, drops;
    local int n, hasCard;

    if (Viewport == None || Viewport.Actor == None)
    {
        Log("[Archipelago] APConsole.DumpContainers: no Viewport.Actor");
        return;
    }
    lvl = Caps(string(Viewport.Actor.Level.Outer.Name));
    DevPrint("DumpContainers Level=" $ lvl $ " - see Game.log");

    // chestbronze covers ChestGold/Iron/Wood; BronzeCauldron and HCauldron
    // (CauldronSmall/Student/Teacher) are sibling cauldron trees; GenericSpawner
    // covers cigar/decanter/jewel/music/oil can/plant pot AND non-bean spawners
    // (Bark/Mucus/Invisible/Knight) the parser filters on drops=; HFlipendo
    // covers the vases. Only BronzeCauldron/chestbronze host cards.
    foreach Viewport.Actor.AllActors(class'chestbronze', chest)
    {
        drops = EjectorDrops_Chest(chest, hasCard);
        LogContainer(lvl, "chest", chest, hasCard, 1, drops);
        n++;
    }
    foreach Viewport.Actor.AllActors(class'BronzeCauldron', bcaul)
    {
        drops = EjectorDrops_Cauldron(bcaul, hasCard);
        LogContainer(lvl, "cauldron", bcaul, hasCard, 1, drops);
        n++;
    }
    foreach Viewport.Actor.AllActors(class'HCauldron', hcaul)
    {
        LogContainer(lvl, "cauldron", hcaul, 0, 1, "");
        n++;
    }
    foreach Viewport.Actor.AllActors(class'GenericSpawner', gs)
    {
        drops = EjectorDrops_Spawner(gs);
        LogContainer(lvl, "spawner", gs, 0, gs.Lives, drops);
        n++;
    }
    foreach Viewport.Actor.AllActors(class'HFlipendo', vase)
    {
        cn = Caps(string(vase.Class.Name));
        if (InStr(cn, "BROKEN") >= 0 || InStr(cn, "SHARD") >= 0)
        {
            continue;  // post-break debris, not an openable container
        }
        LogContainer(lvl, "vase", vase, 0, 1, "");
        n++;
    }
    DevPrint("DumpContainers: " $ n $ " container(s) logged (see Game.log)");
}

// One parseable census line per container. `name=` is the engine actor Name
// the runtime watcher resolves via APLocationRegistry.GetContainerLocationId;
// `spell=` reads the Pawn eVulnerableToSpell ordinal every family inherits;
// `drops=` is the de-duplicated list of ejected classes so the parser keeps
// only bean-droppers.
function LogContainer(string lvl, string fam, Actor c, int hasCard, int lives, string drops)
{
    Log("[Archipelago]   container level=" $ lvl
        $ " family=" $ fam
        $ " class=" $ string(c.Class.Name)
        $ " name=" $ string(c.Name)
        $ " tag=" $ string(c.Tag)
        $ " spell=" $ string(HPawn(c).eVulnerableToSpell)
        $ " lives=" $ string(lives)
        $ " hascard=" $ string(hasCard)
        $ " drops=" $ drops
        $ " loc=" $ string(c.Location));
}

// Distinct ejected classes of a chest; sets hasCard if any slot is a
// WizardCardIcon child. The AP card markers are WizardCardIcon subclasses, so
// this stays true after ReplaceCardChests swaps the slot. Card chests are
// reliably flagged whether or not the swap has run yet.
function string EjectorDrops_Chest(chestbronze chest, out int hasCard)
{
    local int i;
    local string s, cn;

    hasCard = 0;
    for (i = 0; i < ArrayCount(chest.EjectedObjects); i++)
    {
        if (chest.EjectedObjects[i] == None) continue;
        if (ClassIsChildOf(chest.EjectedObjects[i], class'WizardCardIcon')) hasCard = 1;
        cn = string(chest.EjectedObjects[i]);
        if (InStr(s, cn) < 0) s = s $ cn $ ";";
    }
    return s;
}

function string EjectorDrops_Cauldron(BronzeCauldron caul, out int hasCard)
{
    local int i;
    local string s, cn;

    hasCard = 0;
    for (i = 0; i < ArrayCount(caul.EjectedObjects); i++)
    {
        if (caul.EjectedObjects[i] == None) continue;
        if (ClassIsChildOf(caul.EjectedObjects[i], class'WizardCardIcon')) hasCard = 1;
        cn = string(caul.EjectedObjects[i]);
        if (InStr(s, cn) < 0) s = s $ cn $ ";";
    }
    return s;
}

function string EjectorDrops_Spawner(GenericSpawner gs)
{
    local int i;
    local string s, cn;

    for (i = 0; i < ArrayCount(gs.GoodieToSpawn); i++)
    {
        if (gs.GoodieToSpawn[i] == None) continue;
        cn = string(gs.GoodieToSpawn[i]);
        if (InStr(s, cn) < 0) s = s $ cn $ ";";
    }
    return s;
}

// Non-standard container census: the decoration props (statues, skeletons, dragons,
// plant dragons) DumpContainers cannot see because they carry no native break or
// eject. Sweeps the two inert trees, HDecoration and HPlants, and logs one parseable
// line per actor with the fields a containersanity entry needs: level, family, class,
// Name (the stable key the runtime resolves via GetContainerLocationId), tag,
// eVulnerableToSpell (SPELL_None = inert, so a new Flipendo-break subclass is needed;
// a Flipendo value = the placed actor already breaks and only wants wiring), mesh (to
// tell apart several statues sharing one class), draw scale, collision cylinder, and
// location. Anything outside these two trees (e.g. an HChar skeleton) is found with
// DumpActors <substring>. Run once on fresh entry to each level:
//   DumpDecorations
exec function DumpDecorations()
{
    local HDecoration deco;
    local HPlants plnt;
    local string lvl;
    local int n;

    if (Viewport == None || Viewport.Actor == None)
    {
        Log("[Archipelago] APConsole.DumpDecorations: no Viewport.Actor");
        return;
    }
    lvl = Caps(string(Viewport.Actor.Level.Outer.Name));
    DevPrint("DumpDecorations Level=" $ lvl $ " - see Game.log");

    foreach Viewport.Actor.AllActors(class'HDecoration', deco)
    {
        LogDecoration(lvl, "decoration", deco);
        n++;
    }
    foreach Viewport.Actor.AllActors(class'HPlants', plnt)
    {
        LogDecoration(lvl, "plant", plnt);
        n++;
    }
    DevPrint("DumpDecorations: " $ n $ " decoration(s) logged (see Game.log)");
}

// One parseable census line per decoration prop. `name=` is the engine actor Name the
// runtime watcher would resolve; `spell=` reads the inherited Pawn vulnerability
// (SPELL_None = inert); `mesh=` disambiguates which statue or dragon it is.
function LogDecoration(string lvl, string fam, HPawn d)
{
    Log("[Archipelago]   decoration level=" $ lvl
        $ " family=" $ fam
        $ " class=" $ string(d.Class.Name)
        $ " name=" $ string(d.Name)
        $ " tag=" $ string(d.Tag)
        $ " spell=" $ string(d.eVulnerableToSpell)
        $ " mesh=" $ string(d.Mesh)
        $ " drawscale=" $ string(d.DrawScale)
        $ " colradius=" $ string(d.CollisionRadius)
        $ " colheight=" $ string(d.CollisionHeight)
        $ " loc=" $ string(d.Location));
}

exec function PlaceBookcase(optional float Forward)
{
    local Vector loc, fwd;
    local Rotator rot;
    local Actor blocker;

    if (Viewport == None || Viewport.Actor == None)
    {
        Log("[Archipelago] APConsole.PlaceBookcase: no Viewport.Actor");
        return;
    }
    // Default: drop the bookcase 48 units in front of Harry. Spawning at his
    // exact Location always fails encroachment because his own collision
    // cylinder occupies that space. Pass a float to override (e.g.
    // `PlaceBookcase 96` for further, `PlaceBookcase 200` for further still).
    if (Forward == 0.0)
    {
        Forward = 48.0;
    }
    rot = Viewport.Actor.Rotation;
    fwd = Vector(rot);
    loc = Viewport.Actor.Location + Forward * fwd;
    // Bookcase model's "front" sits along its local +Y, but we want it facing
    // Harry along his +X (the direction he's looking). 90° yaw twist aligns the
    // doors with the doorway. UE1 yaw units: 16384 = 90°.
    rot.Yaw += 16384;
    blocker = Viewport.Actor.Spawn(class'BookcaseGlassDoors', None, 'APDebugBookcase', loc, rot);
    if (blocker != None)
    {
        DevPrint("PlaceBookcase: spawned at Location=" $ string(loc) $ " Rotation=" $ string(rot) $ " (Forward=" $ Forward $ ")");
    }
    else
    {
        DevPrint("PlaceBookcase: Spawn returned None at " $ string(loc) $ " (encroachment; try a different Forward or step back)");
    }
}

exec function ClearBookcases()
{
    local Actor a;
    local int destroyed;

    if (Viewport == None || Viewport.Actor == None)
    {
        return;
    }
    foreach Viewport.Actor.AllActors(class'Actor', a)
    {
        if (a.Tag == 'APDebugBookcase' && !a.bDeleteMe)
        {
            a.Destroy();
            destroyed++;
        }
    }
    DevPrint("ClearBookcases: destroyed " $ destroyed $ " debug bookcase(s)");
}

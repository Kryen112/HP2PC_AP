//=============================================================================
// APConsole — dev-only console subclass for bookcase placement.
//
// Activated by patching Modded\system\Default.ini:
//   [Engine.Engine]
//   Console=HPArchipelago.APConsole   ; default: HGame.HPConsole
//
// Adds exec commands callable from the in-game console (~ key):
//
//   LogPos          — one-shot log of harry's Location + Rotation to Game.log.
//                     Complements stock HP2's ShowPos (which only shows X/Y/Z
//                     on the HUD); LogPos captures Rotation too, in the same
//                     pretty-printed form a Block<X>IfMissing helper expects.
//
//   Note            — free-form label line in Game.log next to nearby LogPos /
//                     PlaceBookcase output, so one grep recovers a spot's name.
//
//   DumpActors      — log every actor (optionally class-name-substring-filtered)
//                     with class/name/tag/location. Used to identify the boss
//                     and level-exit-trigger classes the §6 goal detector keys
//                     off.
//
//   PlaceBookcase   — spawns a BookcaseGlassDoors at harry's current Location,
//                     facing the same direction harry is looking. Stand at the
//                     spot, look in the direction you want the bookcase's front
//                     to face, fire the command. Bookcase is tagged
//                     APDebugBookcase so it's idempotent / removable. Location +
//                     Rotation get logged for later transcription.
//
//   ClearBookcases  — destroys every APDebugBookcase-tagged actor in the level.
//                     For wiping a misplaced preview before respawning.
//
// Release builds ship with Default.ini's Console= line unchanged, so end users
// never instantiate this subclass — the .u compiles it in but the engine picks
// HGame.HPConsole and never sees these execs.
//=============================================================================

class APConsole extends HPConsole;

// Print a string to both Game.log AND the in-game chat overlay. Without the
// ClientMessage path the player has no visible feedback from these execs —
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
// per-level actors the detector keys off — boss classes for Forbidden Forest /
// Chamber, and the level-exit / level-change trigger for the challenges +
// Whomping Willow + Slytherin Common Room. Stand in the level and fire:
//   DumpActors            — every actor (verbose; large in hub levels)
//   DumpActors TRIGGER    — only classes whose name contains "TRIGGER"
//   DumpActors BASILISK   — substring match on the class name
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

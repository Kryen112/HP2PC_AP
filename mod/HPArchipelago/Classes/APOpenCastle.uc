// Open castle on a stock install. The open castle game runs the story in game
// state 180 (every story gate already passed) from the first trip to Hogwarts,
// with level edits for what that state leaves closed: extra level links,
// triggers that open level doors and bars, moved gates and links, spell
// targets, and arrival points. On an install without the open castle maps the
// mod makes the same changes at runtime. Each level's edits run once per level
// load: spawned actors carry the APOpenCastle tag, and a level that has one is
// not edited again.
class APOpenCastle extends Object;

// The story state open castle plays in.
const OPEN_CASTLE_GAME_STATE = "GSTATE180";
const OPEN_CASTLE_GAME_STATE_NUMBER = 180;
// Cutscene threads and lines read when rewriting a script.
const MAX_CUTSCENE_THREADS = 20;
const MAX_CUTSCENE_LINES = 400;

// Whether the runtime edits apply: an open castle seed.
static function bool Needed()
{
    return class'APModeDetector'.default.bOpenCastleMode == 1;
}

// Edits that must land before any cutscene starts. Runs from
// APGameInfo.InitGame, before the level's actors begin play.
static function ApplyAtInitGame(APGameInfo gi)
{
    if (gi == None || !Needed()) return;
    if (gi.MapName != "PRIVETDR" && gi.MapName != "STARTUP" && gi.MapName != "ENTRY")
    {
        StripGameStateChanges(gi);
    }
    // The open gate's spot is where the Forest blocker stands, so the gate
    // moves before APGameInfo spawns the blockers.
    if (gi.MapName == "GROUNDS_HUB")
    {
        OpenForestGate(gi);
    }
}

// The Forbidden Forest gate on the Grounds lies open, as in the open castle game.
static function OpenForestGate(Actor ctx)
{
    local Mover gate;

    foreach ctx.AllActors(class'Mover', gate)
    {
        if (gate.Name == 'Mover17')
        {
            OpenGate(gate, vect(4080.9, 3458.1, -209), rot(-13136, -297, -1126));
        }
    }
}

// The vanilla classroom blockers, which a save loaded before the seed's mode
// arrived can carry into an open castle game.
static function RemoveVanillaClassroomBlockers(Actor ctx)
{
    local Actor other;

    foreach ctx.AllActors(class'Actor', other)
    {
        if (other.Tag == 'APRictaBlocker' || other.Tag == 'APSkurgeBlocker'
            || other.Tag == 'APSpongifyBlocker' || other.Tag == 'APDiffindoBlocker')
        {
            other.Destroy();
        }
    }
}

// Edits that need the bound Harry or spawn actors. Runs from
// APCardWatcher.Snapshot, which also follows a save-load.
static function ApplyAtSnapshot(Actor ctx, harry h)
{
    local string map;

    if (ctx == None || !Needed()) return;
    map = class'APGameInfo'.static.CurrentMapName(ctx);
    if (map == "FLYINGFORDCUTSCENE")
    {
        ApplyFlyingFord(ctx, h);
        return;
    }
    RemoveVanillaClassroomBlockers(ctx);
    PlaceArrival(ctx, h, map);
    if (HasTag(ctx, 'APOpenCastle')) return;
    switch (map)
    {
        case "ENTRYHALL_HUB": ApplyEntryHall(ctx); break;
        case "GROUNDS_HUB": ApplyGrounds(ctx); break;
        case "GROUNDS_NIGHT": ApplyGroundsNight(ctx, h); break;
        case "GRANDSTAIRCASE_HUB": ApplyGrandStaircase(ctx); break;
        case "ADV7SLYTHCOMROOM": ApplySlytherinCommonRoom(ctx, h); break;
        case "CH1RICTUSEMPRA": ApplyRictusempra(ctx); break;
        case "ADV11BSECRETS": ApplySecrets(ctx); break;
        default: return;
    }
    // Marks the level as edited when the edits spawned nothing.
    if (!HasTag(ctx, 'APOpenCastle'))
    {
        SpawnMarker(ctx);
    }
    Log("[Archipelago] APOpenCastle: " $ map $ " edits applied");
}

// The trip to Hogwarts: the story jumps to the open castle state and the
// cutscene's closing level change goes to the Grand Staircase instead of the
// Whomping Willow (which is reached from the Grounds).
static function ApplyFlyingFord(Actor ctx, harry h)
{
    local TriggerChangeLevel link;

    if (h != None && h.ConvertGameStateToNumber() < OPEN_CASTLE_GAME_STATE_NUMBER)
    {
        h.SetGameState(OPEN_CASTLE_GAME_STATE);
        Log("[Archipelago] APOpenCastle: game state set to " $ OPEN_CASTLE_GAME_STATE);
    }
    foreach ctx.AllActors(class'TriggerChangeLevel', link)
    {
        if (link.Tag == 'ChangeToWhompingWillow' && link.NewMapName != "Grandstaircase_Hub")
        {
            link.NewMapName = "Grandstaircase_Hub";
            Log("[Archipelago] APOpenCastle: flying car now arrives at the Grand Staircase");
        }
    }
}

// Places Harry at the open castle arrival point after level travel from a
// level whose stock arrival point is elsewhere. Arrival points are static
// navigation points, so Harry is moved instead. Runs once per travel: a
// save-load keeps Harry where the save put him.
static function PlaceArrival(Actor ctx, harry h, string map)
{
    local APGameInfo gi;
    local string from;

    gi = APGameInfo(ctx.Level.Game);
    if (gi == None || h == None || !gi.bEnteredByTravel) return;
    gi.bEnteredByTravel = False;
    from = Caps(gi.ArrivedFrom);
    Log("[Archipelago] APOpenCastle: entered " $ map $ " from '" $ gi.ArrivedFrom $ "'");
    if (map == "ENTRYHALL_HUB" && InStr(from, "ADV7SLYTHCOMROOM") >= 0)
    {
        MoveHarry(h, vect(415, -1887, -24), rot(0, -16440, 0), true);
    }
    else if (map == "ADV7SLYTHCOMROOM" && InStr(from, "ENTRYHALL") >= 0)
    {
        // Past the entry doors, where the story's arrival scene walks Harry.
        MoveHarry(h, vect(31.8, -1334.1, -45.9), rot(0, -16384, 0), true);
    }
    else if (map == "ADV8FOREST" && InStr(from, "GROUNDS_NIGHT") >= 0)
    {
        MoveHarry(h, vect(-6350.1, -5292.4, -727.9), rot(0, 0, 0), false);
    }
    else if (map == "ADV8FOREST" && InStr(from, "GROUNDS_HUB") >= 0)
    {
        MoveHarry(h, vect(-6356.8, -5269.6, -724.9), rot(0, 0, 0), false);
    }
    else if (map == "CH7GRYFFINDOR" && InStr(from, "ENTRYHALL") >= 0)
    {
        MoveHarry(h, vect(3.8, 926.9, 808.1), rot(0, -16384, 0), true);
    }
}

static function MoveHarry(harry h, vector where, rotator facing, bool turn)
{
    h.SetLocation(where);
    if (turn)
    {
        h.SetRotation(facing);
        h.ClientSetRotation(facing);
    }
    Log("[Archipelago] APOpenCastle: arrival at " $ where);
}

// Entry Hall: the Bicorn (dungeon) and Goyle level doors and bars open on
// approach, the Goyle level gets its own level link, the dungeon link stays
// usable, the Slytherin door opens on approach and its level link sits in the
// doorway, and the Gryffindor challenge opens from a plain trigger.
static function ApplyEntryHall(Actor ctx)
{
    local TriggerChangeLevel link;
    local Actor other;
    local Dispatcher dispatch;
    local ElevatorTrigger lift;

    foreach ctx.AllActors(class'TriggerChangeLevel', link)
    {
        if (link.NewMapName ~= "Adv3DungeonQuest")
        {
            link.bTriggerOnceOnly = False;
        }
        else if (link.Tag == 'ChangeLevelAdv7SCR')
        {
            link.SetLocation(vect(-2518, -3482, -521));
        }
    }
    foreach ctx.AllActors(class'Actor', other)
    {
        if (other.IsA('EkocTrigger') && other.Event == 'openGrifChall')
        {
            other.Event = '';
        }
    }

    SpawnTrigger(ctx, vect(-4864, -1328, -432), 64, 8, 80, 'OpenCastle_Bicorn');
    dispatch = SpawnDispatcher(ctx, vect(-4843, -1233, -358), 'OpenCastle_Bicorn');
    if (dispatch != None)
    {
        dispatch.OutEvents[0] = 'OpenADV3DungIng';
        dispatch.OutEvents[1] = 'Open_Adv3Bars';
    }

    SpawnTrigger(ctx, vect(-5128, -2368, -184), 8, 64, 80, 'OpenCastle_Goyle');
    dispatch = SpawnDispatcher(ctx, vect(-5217, -2323, -91), 'OpenCastle_Goyle');
    if (dispatch != None)
    {
        dispatch.OutEvents[0] = 'Adv6_Bars';
        dispatch.OutEvents[1] = 'OpenCastle_Adv6_Door';
    }
    lift = ctx.Spawn(class'ElevatorTrigger', None, 'OpenCastle_Adv6_Door', vect(-5240, -2299, -100));
    if (lift != None)
    {
        lift.Event = 'Adv6_Door';
        lift.GotoKeyframe = 1;
        lift.MoveTime = 2.0;
        lift.SetCollision(False, False, False);
    }
    SpawnChangeLevel(ctx, vect(-5400, -2368, -160), 20, 60, 100, "Adv6Goyle");

    SpawnTrigger(ctx, vect(-2530, -2937, -579), 120, 100, 60, 'SlythDoor');
    SpawnTrigger(ctx, vect(2646, -1874, 616), 70, 0, 0, 'openGrifChall');
}

// Grounds: a Spongify pad on a stone slab and a high level link lead to the
// Whomping Willow, the Forbidden Forest gate stands open with a level link
// behind it, the Greenhouse (Boomslang) bars and door open on approach and its
// link stays usable, and the Quidditch gate swings the other way.
static function ApplyGrounds(Actor ctx)
{
    local SpongifyPad pad;
    local Dispatcher dispatch;
    local TriggerChangeLevel link;
    local Mover gate;
    local Actor other;

    ctx.Spawn(class'APSpongifySlab', None, 'APOpenCastle', vect(-552, 712, -23), rot(0, 16384, 0));
    pad = ctx.Spawn(class'SpongifyPad', None, 'APOpenCastle', vect(-552, 712, 8));
    if (pad != None)
    {
        pad.PadDir = vect(0.1, 0, 0.9);
        pad.PadSpeed = 608;
    }
    else
    {
        Log("[Archipelago] APOpenCastle: Willow Spongify pad did not spawn");
    }
    SpawnChangeLevel(ctx, vect(0, 1680, 336), 64, 8, 80, "Adv1Willow");

    OpenForestGate(ctx);
    foreach ctx.AllActors(class'Mover', gate)
    {
        if (gate.Tag == 'QGate')
        {
            gate.KeyRot[1] = rot(0, -7168, 0);
        }
    }
    SpawnChangeLevel(ctx, vect(4015.7, 3426.1, -115.2), 32, 256, 128, "Adv8Forest");

    SpawnTrigger(ctx, vect(-4504, 1104, 80), 8, 64, 64, 'OpenCastle_Boomslang');
    dispatch = SpawnDispatcher(ctx, vect(-4520, 1128, 104), 'OpenCastle_Boomslang');
    if (dispatch != None)
    {
        dispatch.OutEvents[0] = 'Adv4_BarsOpen';
        dispatch.OutEvents[1] = 'Adv4Door';
    }
    foreach ctx.AllActors(class'TriggerChangeLevel', link)
    {
        if (link.NewMapName ~= "Adv4Greenhouse.unr")
        {
            link.bTriggerOnceOnly = False;
        }
    }
    foreach ctx.AllActors(class'Actor', other)
    {
        if (other.Tag == 'SwapQGate')
        {
            other.SetLocation(vect(1771.8, -0.7, 40.1));
        }
        else if (other.Name == 'CutScene26')
        {
            other.SetLocation(vect(1950, -44, 89));
        }
    }
}

// Grounds at night: the Quidditch and Forbidden Forest gates stand open,
// Hagrid's hut opens as on the story's night, and the trigger back into the
// Entry Hall works in the open castle state.
static function ApplyGroundsNight(Actor ctx, harry h)
{
    local Mover gate;
    local Actor other;
    local APOpenCastleTrigger back;

    foreach ctx.AllActors(class'Mover', gate)
    {
        if (gate.Tag == 'QGate')
        {
            gate.KeyRot[1] = rot(0, -10240, 0);
            gate.KeyNum = 1;
            gate.SetRotation(rot(0, 22528, 0));
        }
        else if (gate.Tag == 'ForestGate')
        {
            gate.KeyNum = 1;
            gate.SetRotation(rot(0, -13312, 0));
        }
    }
    foreach ctx.AllActors(class'Actor', other)
    {
        if (other.Tag == 'SwapQGate')
        {
            other.SetLocation(vect(1796.2, 2.5, 40.1));
        }
    }
    back = SpawnTrigger(ctx, vect(-2.3, -2360.4, 96), 128, 24, 40, 'ChangeLevelEntranceHall');
    if (back != None)
    {
        back.bTriggerOnceOnly = False;
    }
    TriggerTag(ctx, h, 'OpenHagridHut');
}

// Grand Staircase: Alohomora opens the Chamber of Secrets entrance and
// Dumbledore's office in the open castle state, three blockers close gaps the
// open state leaves, and the Gold Card Room's lower three bars share one lock,
// so the first silver card threshold opens all three.
static function ApplyGrandStaircase(Actor ctx)
{
    local Mover bars;

    SpawnSpellTarget(ctx, vect(1600, -8147.3, 1227.1), 48, 16, 64, 'Dis2');
    SpawnSpellTarget(ctx, vect(-2288, -6528, 1512), 24, 32, 36, 'dragondis');
    SpawnBlocker(ctx, vect(1600, -8136, 1120), 48, 48, 32);
    SpawnBlocker(ctx, vect(-2320, -6528, 1392), 48, 64, 16);
    SpawnBlocker(ctx, vect(-2336, -6608, 1536), 32, 16, 128);
    foreach ctx.AllActors(class'Mover', bars)
    {
        if (bars.Tag == 'CardLock3' || bars.Tag == 'CardLock4')
        {
            bars.Tag = 'CardLock2';
        }
    }
}

// Slytherin common room: the open castle state skips the story's arrival and
// dormitory scenes, so the bridge is raised on arrival (PlaceArrival walks
// Harry past the entry doors, which stay open), and a level link at the far
// end leads back to the Entry Hall.
static function ApplySlytherinCommonRoom(Actor ctx, harry h)
{
    local Actor other;

    foreach ctx.AllActors(class'Actor', other)
    {
        if (other.IsA('CutScene') && (other.Name == 'CutScene0' || other.Name == 'CutScene9'))
        {
            other.GotoState('Disabled');
        }
    }
    TriggerTag(ctx, h, 'SwingUp');
    SpawnChangeLevel(ctx, vect(456, -11552, -112), 8, 64, 96, "Entryhall_Hub");
}

// Rictusempra challenge: the entry bars stay open behind Harry, so the
// challenge can be left the way it was entered.
static function ApplyRictusempra(Actor ctx)
{
    local Mover bars;

    foreach ctx.AllActors(class'Mover', bars)
    {
        if (bars.Tag == 'EntryBars')
        {
            bars.Tag = 'APOpenCastleEntryBars';
        }
    }
}

// Secrets level: the one secret area the open castle game drops.
static function ApplySecrets(Actor ctx)
{
    local Actor other;

    foreach ctx.AllActors(class'Actor', other)
    {
        if (other.IsA('SecretAreaMarker') && other.Name == 'SecretAreaMarker0')
        {
            other.Destroy();
        }
    }
}

// Rewrites every cutscene script of the level without its ChangeGameState
// commands, so no scene moves the story out of the open castle state. A
// script read from a cutscene file is copied inline first; scenes with no
// state change are left untouched.
static function StripGameStateChanges(Actor ctx)
{
    local CutScene scene;
    local int thread, rewritten;
    local string script, kept;

    foreach ctx.AllActors(class'CutScene', scene)
    {
        if (scene.FileName != "")
        {
            if (!FileHasGameStateChange(scene.FileName)) continue;
            for (thread = 0; thread < MAX_CUTSCENE_THREADS; thread++)
            {
                scene.aThreadScripts[thread] = WithoutGameStateChanges(ReadFileThread(scene.FileName, thread));
            }
            scene.FileName = "";
            rewritten++;
            continue;
        }
        for (thread = 0; thread < MAX_CUTSCENE_THREADS; thread++)
        {
            script = scene.aThreadScripts[thread];
            if (InStr(Caps(script), "CHANGEGAMESTATE") < 0) continue;
            kept = WithoutGameStateChanges(script);
            scene.aThreadScripts[thread] = kept;
            rewritten++;
        }
    }
    if (rewritten > 0)
    {
        Log("[Archipelago] APOpenCastle: removed game state changes from " $ rewritten $ " cutscene script(s)");
    }
}

static function bool FileHasGameStateChange(string fileName)
{
    local int thread;

    for (thread = 0; thread < MAX_CUTSCENE_THREADS; thread++)
    {
        if (InStr(Caps(ReadFileThread(fileName, thread)), "CHANGEGAMESTATE") >= 0) return true;
    }
    return false;
}

// One thread of a cutscene file, lines joined with line breaks, or "" when the
// file has no such thread.
static function string ReadFileThread(string fileName, int thread)
{
    local int index;
    local string line, script;

    for (index = 0; index < MAX_CUTSCENE_LINES; index++)
    {
        line = Localize("thread_" $ thread, "line_" $ index, "Cutscenes\\" $ fileName);
        if (InStr(line, "<?") >= 0) break;
        script = script $ line $ Chr(13) $ Chr(10);
    }
    return script;
}

static function string WithoutGameStateChanges(string script)
{
    local string rest, line, kept;
    local int split;

    rest = script;
    while (rest != "")
    {
        split = InStr(rest, Chr(10));
        if (split < 0)
        {
            line = rest;
            rest = "";
        }
        else
        {
            line = Left(rest, split);
            rest = Mid(rest, split + 1);
        }
        if (Right(line, 1) == Chr(13)) line = Left(line, Len(line) - 1);
        if (InStr(Caps(line), "CHANGEGAMESTATE") >= 0 && Left(WithoutLeadingSpace(line), 2) != "//")
        {
            continue;
        }
        kept = kept $ line $ Chr(13) $ Chr(10);
    }
    return kept;
}

static function string WithoutLeadingSpace(string line)
{
    while (Left(line, 1) == " " || Left(line, 1) == Chr(9))
    {
        line = Mid(line, 1);
    }
    return line;
}

// A once-only box trigger that fires eventName on Harry's approach. A zero width
// keeps the stock cylinder shape.
static function APOpenCastleTrigger SpawnTrigger(Actor ctx, vector where, float radius, float width, float height, name eventName)
{
    local APOpenCastleTrigger trigger;

    trigger = ctx.Spawn(class'APOpenCastleTrigger', None, 'APOpenCastle', where);
    if (trigger == None)
    {
        Log("[Archipelago] APOpenCastle: trigger for " $ eventName $ " did not spawn at " $ where);
        return None;
    }
    trigger.Event = eventName;
    trigger.bTriggerOnceOnly = True;
    if (width > 0)
    {
        trigger.SetCollisionSize(radius, height, width);
    }
    else
    {
        trigger.SetCollisionSize(radius, height);
    }
    return trigger;
}

// A box target that fires eventName when hit by Alohomora.
static function SpawnSpellTarget(Actor ctx, vector where, float radius, float width, float height, name eventName)
{
    local APOpenCastleSpellTrigger target;

    target = ctx.Spawn(class'APOpenCastleSpellTrigger', None, 'APOpenCastle', where);
    if (target == None)
    {
        Log("[Archipelago] APOpenCastle: spell target for " $ eventName $ " did not spawn at " $ where);
        return;
    }
    target.Event = eventName;
    target.eVulnerableToSpell = SPELL_Alohomora;
    target.bTriggerOnceOnly = True;
    target.SetCollisionSize(radius, height, width);
}

static function SpawnBlocker(Actor ctx, vector where, float radius, float width, float height)
{
    local APOpenCastleBlockPlayer blocker;

    blocker = ctx.Spawn(class'APOpenCastleBlockPlayer', None, 'APOpenCastle', where);
    if (blocker == None)
    {
        Log("[Archipelago] APOpenCastle: player blocker did not spawn at " $ where);
        return;
    }
    blocker.SetCollisionSize(radius, height, width);
    blocker.SetCollision(True, False, True);
}

static function Dispatcher SpawnDispatcher(Actor ctx, vector where, name tag)
{
    local Dispatcher dispatch;

    dispatch = ctx.Spawn(class'Dispatcher', None, tag, where);
    if (dispatch == None)
    {
        Log("[Archipelago] APOpenCastle: dispatcher " $ tag $ " did not spawn at " $ where);
    }
    return dispatch;
}

static function SpawnChangeLevel(Actor ctx, vector where, float radius, float width, float height, string map)
{
    local APOpenCastleChangeLevel link;

    link = ctx.Spawn(class'APOpenCastleChangeLevel', None, 'APOpenCastle', where);
    if (link == None)
    {
        Log("[Archipelago] APOpenCastle: level link to " $ map $ " did not spawn at " $ where);
        return;
    }
    link.NewMapName = map;
    link.SetCollisionSize(radius, height, width);
    link.SetCollision(True, False, False);
}

// An invisible marker that records the level's edits as applied.
static function SpawnMarker(Actor ctx)
{
    local APOpenCastleTrigger marker;

    marker = ctx.Spawn(class'APOpenCastleTrigger', None, 'APOpenCastle', ctx.Location);
    if (marker != None)
    {
        marker.SetCollision(False, False, False);
    }
}

// Opens a stock gate mover by placing it in the open position.
static function OpenGate(Mover gate, vector where, rotator facing)
{
    gate.BasePos = where;
    gate.BaseRot = facing;
    gate.SetLocation(where);
    gate.SetRotation(facing);
}

// Fires every actor tagged tag, as a cutscene's Trigger command does.
static function TriggerTag(Actor ctx, harry h, name tag)
{
    local Actor other;

    foreach ctx.AllActors(class'Actor', other, tag)
    {
        other.Trigger(ctx, h);
    }
}

static function bool HasTag(Actor ctx, name tag)
{
    local Actor other;

    foreach ctx.AllActors(class'Actor', other, tag)
    {
        if (!other.bDeleteMe) return true;
    }
    return false;
}

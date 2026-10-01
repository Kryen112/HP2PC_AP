//================================================================================
// APGhostRegistry.
//
// Per-level home of the ghost players feature. Outbound: samples the local
// Harry ten times a second and ships a POS frame over the bridge whenever he
// moved, turned, changed animation or scale, plus a heartbeat every two
// seconds. Inbound: PEER frames from the client become APGhostPawn ghosts, one
// per slot on this map, moved and animated per sample; PEERGONE or four
// seconds of silence destroy one. Ghosts hide during a captured cutscene.
// Hosted on APGameInfo like the morph registry, so nothing here is reachable
// from a class default at level teardown.
//
// Sample fields, bar-separated, after the map name (POS) or the slot and name
// (PEER): x, y, z, pitch, yaw, roll, body sequence, body frame, body loops,
// body combine (Harry's blend type while his channel is live), channel
// sequence, channel frame, channel loops, draw scale, body mesh, wand mesh
// ("None" for an empty hand).
//================================================================================

class APGhostRegistry extends Actor;

const MAX_GHOSTS           = 16;
const SAMPLE_INTERVAL_SECS = 0.1;
const HEARTBEAT_SECS       = 2.0;
const PEER_TIMEOUT_SECS    = 4.0;
const MOVE_EPSILON         = 1.0;
const TURN_EPSILON         = 64;
const RESTART_FRAME_DROP   = 30;
// Where the GhostFake peer stands relative to Harry, and the slot it borrows.
const FAKE_PEER_OFFSET     = 120.0;
const FAKE_PEER_SLOT       = 9999;

// Ghosts on this map, parallel to the slot each one draws. Dimension literals
// mirror MAX_GHOSTS (M212 array dims take an integer literal).
var APGhostPawn Ghosts[16];
var int         GhostSlots[16];
var int         GhostCount;

// Outbound sampler state: what the last POS frame carried.
var float   SampleAccumulator;
var float   LastSendTime;
var Vector  LastSentLocation;
var Rotator LastSentRotation;
var name    LastSentBody;
var name    LastSentChannel;
var int     LastSentBodyFrame;
var int     LastSentChannelFrame;
var bool    bLastSentBodyCombine;
var float   LastSentScale;
var string  LastSentMeshName;
var string  LastSentWandMeshName;
var byte    bSentOnce;
// Dev aid (APConsole GhostFake): feed the local Harry back in as a peer standing
// ahead of him, so the ghost pawn, its channel and its wand can be checked alone.
var byte bFakePeer;

// Found-or-spawned per-level singleton, hosted on APGameInfo.
static function APGhostRegistry GetInstance(Actor ctx)
{
    local APGameInfo gi;

    if (ctx == None) return None;
    gi = APGameInfo(ctx.Level.Game);
    if (gi == None) return None;
    if (gi.GhostRegistry != None && !gi.GhostRegistry.bDeleteMe)
        return gi.GhostRegistry;
    return ctx.Spawn(class'APGhostRegistry');
}

event PreBeginPlay()
{
    Super.PreBeginPlay();
    if (APGameInfo(Level.Game) != None)
        APGameInfo(Level.Game).GhostRegistry = self;
    SweepUntrackedGhosts();
}

// A ghost saved with the level comes back on load with no registry entry and
// would stand there for good. A fresh registry owns no ghosts yet, so every
// ghost pawn it finds is stale.
function SweepUntrackedGhosts()
{
    local APGhostPawn g;
    local int swept;

    foreach AllActors(class'APGhostPawn', g)
    {
        g.Destroy();
        swept++;
    }
    if (swept > 0)
    {
        Log("[Archipelago] Ghosts: swept " $ swept $ " stale ghost(s) left by a save");
    }
}

function Tick(float fTimeDelta)
{
    local harry h;

    Super.Tick(fTimeDelta);
    h = class'APGameInfo'.static.FindGrantReadyHarry(self);
    // The harry lookup is static and finds the live Harry from any level, so a
    // registry in another level package (the persistent startup map, a save's
    // stale actor) would sample him under its own map name and drive the map
    // reported over the bridge back and forth. Only the live level's registry acts.
    if (h == None || h.Level != Level) return;

    SampleAccumulator += fTimeDelta;
    if (SampleAccumulator >= SAMPLE_INTERVAL_SECS)
    {
        SampleAccumulator = 0.0;
        Sample(h);
    }
    ExpireSilentPeers();
    HideDuringCutscene(h);
}

// Outbound.

// Ship a POS frame when anything a ghost would show has changed, else every
// HEARTBEAT_SECS so a standing Harry stays alive on the other side. A frame
// dropping back on either track is a change too: that is how a receiver tells a
// repeated one-shot from one still playing.
function Sample(harry h)
{
    local APIPCActor ipc;
    local name body, channel;
    local int bodyFrame, channelFrame;
    local bool bChanged, bBodyCombine;
    local string meshName, wandMeshName;

    body = h.AnimSequence;
    bodyFrame = FrameOf(h.AnimFrame);
    bBodyCombine = h.HarryAnimType == AT_Combine;
    if (h.HarryAnimChannel != None)
    {
        channel = h.HarryAnimChannel.AnimSequence;
        channelFrame = FrameOf(h.HarryAnimChannel.AnimFrame);
    }
    meshName = string(h.Mesh);
    wandMeshName = WandMeshToken(h);

    bChanged = bSentOnce == 0
        || meshName != LastSentMeshName
        || wandMeshName != LastSentWandMeshName
        || VSize(h.Location - LastSentLocation) > MOVE_EPSILON
        || Abs(class'APGhostPawn'.static.WrapDelta(h.Rotation.Yaw - LastSentRotation.Yaw)) > TURN_EPSILON
        || Abs(class'APGhostPawn'.static.WrapDelta(h.Rotation.Roll - LastSentRotation.Roll)) > TURN_EPSILON
        || body != LastSentBody
        || channel != LastSentChannel
        || bBodyCombine != bLastSentBodyCombine
        || bodyFrame + RESTART_FRAME_DROP < LastSentBodyFrame
        || channelFrame + RESTART_FRAME_DROP < LastSentChannelFrame
        || Abs(h.DrawScale - LastSentScale) > 0.01;
    if (!bChanged && Level.TimeSeconds - LastSendTime < HEARTBEAT_SECS) return;

    LastSentLocation     = h.Location;
    LastSentRotation     = h.Rotation;
    LastSentBody         = body;
    LastSentChannel      = channel;
    LastSentBodyFrame    = bodyFrame;
    LastSentChannelFrame = channelFrame;
    bLastSentBodyCombine = bBodyCombine;
    LastSentScale        = h.DrawScale;
    LastSentMeshName     = meshName;
    LastSentWandMeshName = wandMeshName;
    LastSendTime         = Level.TimeSeconds;
    bSentOnce            = 1;

    ipc = class'APIPCActor'.static.GetInstance();
    if (ipc != None && ipc.IsLinkConnected())
    {
        ipc.SendLine("POS " $ Caps(string(Level.Outer.Name)) $ "|"
            $ SampleFields(h, h.Location, h.Rotation) $ Chr(10));
    }

    if (bFakePeer == 1)
    {
        FeedFakePeer(h);
    }
}

// The mesh the held wand wears, or "None" for an empty hand.
static function string WandMeshToken(harry h)
{
    if (baseWand(h.Weapon) == None || baseWand(h.Weapon).Mesh == None) return "None";
    return string(baseWand(h.Weapon).Mesh);
}

// The sixteen sample fields for Harry's state at a given place.
function string SampleFields(harry h, Vector loc, Rotator rot)
{
    local name channel;
    local int channelFrame;

    if (h.HarryAnimChannel != None)
    {
        channel = h.HarryAnimChannel.AnimSequence;
        channelFrame = FrameOf(h.HarryAnimChannel.AnimFrame);
    }
    return int(loc.X) $ "|" $ int(loc.Y) $ "|" $ int(loc.Z)
        $ "|" $ (rot.Pitch & 65535) $ "|" $ (rot.Yaw & 65535) $ "|" $ (rot.Roll & 65535)
        $ "|" $ string(h.AnimSequence) $ "|" $ FrameOf(h.AnimFrame) $ "|" $ BoolToken(h.bAnimLoop)
        $ "|" $ BoolToken(h.HarryAnimType == AT_Combine)
        $ "|" $ string(channel) $ "|" $ channelFrame $ "|" $ BoolToken(ChannelSequenceLoops(channel))
        $ "|" $ string(h.DrawScale)
        $ "|" $ string(h.Mesh) $ "|" $ WandMeshToken(h);
}

static function int FrameOf(float animFrame)
{
    return Clamp(int(animFrame * 100.0), 0, 100);
}

static function string BoolToken(bool b)
{
    if (b) return "1";
    return "0";
}

// The channel sequences Harry's casting channel loops (everything else it plays
// once): aiming, charging a duel spell, and holding a carried object.
static function bool ChannelSequenceLoops(name seq)
{
    return seq == 'CastAim' || seq == 'swordaim' || seq == 'duel_charge' || seq == 'throwhold';
}

// The GhostFake dev aid on or off; off also removes the fake ghost.
function SetFakePeer(bool bOn)
{
    if (bOn) bFakePeer = 1;
    else     bFakePeer = 0;
    if (!bOn) RemovePeer(FAKE_PEER_SLOT);
}

// The GhostFake dev aid: the local Harry as a peer standing ahead, facing him.
function FeedFakePeer(harry h)
{
    local Vector loc;
    local Rotator flat, facing;

    flat = h.Rotation;
    flat.Pitch = 0;
    flat.Roll = 0;
    loc = h.Location + FAKE_PEER_OFFSET * Vector(flat);
    facing = h.Rotation;
    facing.Yaw += 32768;
    ApplyPeer(FAKE_PEER_SLOT $ "|Ghost|" $ SampleFields(h, loc, facing));
}

// Inbound.

// Body is `<slot>|<name>|<sample fields>`. Draws or moves that slot's ghost.
function ApplyPeer(string body)
{
    local harry h;
    local APGhostPawn g;
    local string rest, peerName, bodySequence, channelSequence, meshName, wandMeshName;
    local int slot, bodyFrame, channelFrame;
    local bool bBodyLoops, bBodyCombine, bChannelLoops;
    local float scale;
    local Vector loc;
    local Rotator rot;

    h = class'APGameInfo'.static.FindGrantReadyHarry(self);
    if (h == None) return;

    rest = body;
    slot = int(NextField(rest));
    peerName = NextField(rest);
    loc.X = float(NextField(rest));
    loc.Y = float(NextField(rest));
    loc.Z = float(NextField(rest));
    rot.Pitch = int(NextField(rest));
    rot.Yaw   = int(NextField(rest));
    rot.Roll  = int(NextField(rest));
    bodySequence  = NextField(rest);
    bodyFrame     = int(NextField(rest));
    bBodyLoops    = NextField(rest) == "1";
    bBodyCombine  = NextField(rest) == "1";
    channelSequence = NextField(rest);
    channelFrame    = int(NextField(rest));
    bChannelLoops   = NextField(rest) == "1";
    scale = float(NextField(rest));
    meshName = NextField(rest);
    wandMeshName = NextField(rest);

    g = FindGhost(slot);
    if (g == None)
    {
        if (GhostCount >= MAX_GHOSTS) return;
        g = Spawn(class'APGhostPawn', , , loc, rot);
        if (g == None)
        {
            Log("[Archipelago] Ghosts: Spawn failed for slot " $ slot $ " at " $ string(loc));
            return;
        }
        g.SetupPeer(slot, peerName);
        Ghosts[GhostCount] = g;
        GhostSlots[GhostCount] = slot;
        GhostCount++;
        Log("[Archipelago] Ghosts: " $ peerName $ " (slot " $ slot $ ") appeared on "
            $ Caps(string(Level.Outer.Name)) $ " at " $ string(loc));
    }
    g.LastSeenTime = Level.TimeSeconds;
    g.ApplyMeshes(meshName, wandMeshName);
    g.SetTarget(loc, rot, scale);
    g.ApplyAnimation(h, bodySequence, bodyFrame, bBodyLoops, bBodyCombine,
                     channelSequence, channelFrame, bChannelLoops);
}

function RemovePeer(int slot)
{
    local int i;

    for (i = 0; i < GhostCount; i++)
    {
        if (GhostSlots[i] == slot)
        {
            RemoveAt(i);
            return;
        }
    }
}

function RemoveAt(int index)
{
    local int i;

    if (Ghosts[index] != None && !Ghosts[index].bDeleteMe)
    {
        Log("[Archipelago] Ghosts: " $ Ghosts[index].PeerName $ " (slot " $ GhostSlots[index] $ ") left");
        Ghosts[index].Destroy();
    }
    for (i = index; i < GhostCount - 1; i++)
    {
        Ghosts[i] = Ghosts[i + 1];
        GhostSlots[i] = GhostSlots[i + 1];
    }
    GhostCount--;
    Ghosts[GhostCount] = None;
    GhostSlots[GhostCount] = 0;
}

function ExpireSilentPeers()
{
    local int i;

    for (i = GhostCount - 1; i >= 0; i--)
    {
        if (Ghosts[i] == None || Ghosts[i].bDeleteMe
            || Level.TimeSeconds - Ghosts[i].LastSeenTime > PEER_TIMEOUT_SECS)
        {
            RemoveAt(i);
        }
    }
}

function APGhostPawn FindGhost(int slot)
{
    local int i;

    for (i = 0; i < GhostCount; i++)
    {
        if (GhostSlots[i] == slot && Ghosts[i] != None && !Ghosts[i].bDeleteMe)
            return Ghosts[i];
    }
    return None;
}

// Ghosts step out of a captured cutscene. Same full-cut test the grant gate
// uses: the HUD's cutscene mode or the full borders, never a dialogue popup.
function HideDuringCutscene(harry h)
{
    local HPHud hud;
    local bool bHide;
    local int i;

    hud = HPHud(h.myHUD);
    bHide = h.bIsCaptured
        || (hud != None && hud.managerCutScene != None
            && (hud.bCutSceneMode || hud.managerCutScene.bBothBordersActive));
    for (i = 0; i < GhostCount; i++)
    {
        if (Ghosts[i] != None && !Ghosts[i].bDeleteMe && Ghosts[i].bHidden != bHide)
            Ghosts[i].SetGhostHidden(bHide);
    }
}

// Split off the field before the next bar; the last field takes the remainder.
static function string NextField(out string rest)
{
    local int bar;
    local string field;

    bar = InStr(rest, "|");
    if (bar < 0)
    {
        field = rest;
        rest = "";
        return field;
    }
    field = Left(rest, bar);
    rest = Mid(rest, bar + 1);
    return field;
}

// Screen position of a world point through the view the player sees: the
// ViewTarget when one is set (the game parks its camera there), else the camera
// actor. Harry's field of view is the width of a 4:3 view; a wider screen
// extends the view sideways, so the pixel scale follows the screen height.
// False when the point is behind the camera or off screen.
static function bool ProjectToScreen(Canvas C, harry h, Vector world, out float sx, out float sy)
{
    local Actor view;
    local Vector camX, camY, camZ, rel;
    local float depth, pixelsPerUnit;

    view = h.ViewTarget;
    if (view == None) view = h.Cam;
    if (view == None) return False;
    GetAxes(view.Rotation, camX, camY, camZ);
    rel = world - view.Location;
    depth = rel dot camX;
    if (depth < 16.0) return False;
    pixelsPerUnit = (C.SizeY * 2.0 / 3.0) / Tan(h.FOVAngle * Pi / 360.0);
    sx = C.SizeX * 0.5 + (rel dot camY) * pixelsPerUnit / depth;
    sy = C.SizeY * 0.5 - (rel dot camZ) * pixelsPerUnit / depth;
    return sx >= 0.0 && sx <= C.SizeX && sy >= 0.0 && sy <= C.SizeY;
}

// Logs every ghost next to the local Harry, so a height difference between a
// ghost and Harry standing on the same floor reads straight off the log.
function LogPeers()
{
    local harry h;
    local int i;

    h = class'APGameInfo'.static.FindGrantReadyHarry(self);
    Log("[Archipelago] Ghosts: " $ GhostCount $ " ghost(s) on " $ Caps(string(Level.Outer.Name))
        $ " zoffset=" $ class'APGhostPawn'.default.ZOffset);
    if (h != None)
    {
        Log("[Archipelago] Ghosts:   local Harry loc=" $ string(h.Location)
            $ " colheight=" $ h.CollisionHeight $ " physics=" $ string(h.Physics));
    }
    for (i = 0; i < GhostCount; i++)
    {
        if (Ghosts[i] == None) continue;
        Log("[Archipelago] Ghosts:   slot " $ GhostSlots[i] $ " " $ Ghosts[i].PeerName
            $ " hidden=" $ string(Ghosts[i].bHidden) $ " loc=" $ string(Ghosts[i].Location)
            $ " target=" $ string(Ghosts[i].TargetLocation)
            $ " colheight=" $ Ghosts[i].CollisionHeight $ " physics=" $ string(Ghosts[i].Physics)
            $ " body=" $ string(Ghosts[i].AnimSequence)
            $ " seen " $ (Level.TimeSeconds - Ghosts[i].LastSeenTime) $ "s ago");
    }
}

defaultproperties
{
    bHidden=True
}

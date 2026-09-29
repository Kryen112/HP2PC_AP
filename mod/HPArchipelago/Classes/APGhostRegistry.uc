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
// channel sequence, channel frame, channel loops, draw scale.
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
var float   LastSentScale;
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
}

function Tick(float fTimeDelta)
{
    local harry h;

    Super.Tick(fTimeDelta);
    h = class'APGameInfo'.static.FindGrantReadyHarry(self);
    if (h == None) return;

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
    local bool bChanged;

    body = h.AnimSequence;
    bodyFrame = FrameOf(h.AnimFrame);
    if (h.HarryAnimChannel != None)
    {
        channel = h.HarryAnimChannel.AnimSequence;
        channelFrame = FrameOf(h.HarryAnimChannel.AnimFrame);
    }

    bChanged = bSentOnce == 0
        || VSize(h.Location - LastSentLocation) > MOVE_EPSILON
        || Abs(class'APGhostPawn'.static.WrapDelta(h.Rotation.Yaw - LastSentRotation.Yaw)) > TURN_EPSILON
        || Abs(class'APGhostPawn'.static.WrapDelta(h.Rotation.Roll - LastSentRotation.Roll)) > TURN_EPSILON
        || body != LastSentBody
        || channel != LastSentChannel
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
    LastSentScale        = h.DrawScale;
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

// The thirteen sample fields for Harry's animation state at a given place.
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
        $ "|" $ string(channel) $ "|" $ channelFrame $ "|" $ BoolToken(ChannelSequenceLoops(channel))
        $ "|" $ string(h.DrawScale);
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
    local string rest, peerName, bodySequence, channelSequence;
    local int slot, bodyFrame, channelFrame;
    local bool bBodyLoops, bChannelLoops;
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
    channelSequence = NextField(rest);
    channelFrame    = int(NextField(rest));
    bChannelLoops   = NextField(rest) == "1";
    scale = float(NextField(rest));

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
            $ Caps(string(Level.Outer.Name)));
    }
    g.LastSeenTime = Level.TimeSeconds;
    g.SetTarget(loc, rot, scale);
    g.ApplyAnimation(h, bodySequence, bodyFrame, bBodyLoops, channelSequence, channelFrame, bChannelLoops);
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

function LogPeers()
{
    local int i;

    Log("[Archipelago] Ghosts: " $ GhostCount $ " ghost(s) on " $ Caps(string(Level.Outer.Name)));
    for (i = 0; i < GhostCount; i++)
    {
        if (Ghosts[i] == None) continue;
        Log("[Archipelago] Ghosts:   slot " $ GhostSlots[i] $ " " $ Ghosts[i].PeerName
            $ " hidden=" $ string(Ghosts[i].bHidden) $ " loc=" $ string(Ghosts[i].Location)
            $ " body=" $ string(Ghosts[i].AnimSequence)
            $ " seen " $ (Level.TimeSeconds - Ghosts[i].LastSeenTime) $ "s ago");
    }
}

defaultproperties
{
    bHidden=True
}

//================================================================================
// APGhostSpikeDriver.
//
// Dev-only render spike for the ghost-players feature. It answers one question:
// does a translucent Harry-mesh actor render when created at runtime, and if
// not, does one built hidden at level bring-up render once un-hidden? The
// APConsole GhostSpike exec picks a variant; this per-level driver spawns or
// reveals the ghost, then keeps it in front of Harry each tick while mirroring
// his animation sequence, which is exactly what a peer ghost needs. Hosted on
// APGameInfo like the morph registry, so nothing here is reachable from a class
// default at level teardown. Every step logs a "GhostSpike" line to Game.log.
//================================================================================

class APGhostSpikeDriver extends Actor;

const GHOST_SLOTS  = 8;
const FRONT_OFFSET = 120.0;

// Ghosts registered by GhostSpike, in registration order. Dimension literal
// mirrors GHOST_SLOTS (M212 array dims take an integer literal).
var Actor Ghosts[8];
// 1 while the ghost tracks Harry each tick. 0 leaves it where it was placed.
var byte  GhostFollow[8];
var int   GhostCount;
// Built hidden on the InitGame path by APGameInfo, one per base class, so the
// reveal variants have an actor that existed when the level came up.
var Actor PoolActor;
var Actor PoolPawn;

// Found-or-spawned per-level singleton, hosted on APGameInfo.
static function APGhostSpikeDriver GetInstance(Actor ctx)
{
    local APGameInfo gi;

    if (ctx == None) return None;
    gi = APGameInfo(ctx.Level.Game);
    if (gi == None) return None;
    if (gi.GhostSpikeDriver != None && !gi.GhostSpikeDriver.bDeleteMe)
        return gi.GhostSpikeDriver;
    return ctx.Spawn(class'APGhostSpikeDriver');
}

event PreBeginPlay()
{
    Super.PreBeginPlay();
    if (APGameInfo(Level.Game) != None)
        APGameInfo(Level.Game).GhostSpikeDriver = self;
}

// Level bring-up only: one hidden ghost per base class.
function BuildPool()
{
    PoolActor = Spawn(class'APGhostSpikeActor');
    if (PoolActor != None) PoolActor.bHidden = True;
    LogGhost("pool built (Actor base)", PoolActor);

    PoolPawn = Spawn(class'APGhostSpikePawn');
    if (PoolPawn != None) PoolPawn.bHidden = True;
    LogGhost("pool built (HPawn base)", PoolPawn);
}

// Create a ghost of cls in front of Harry right now.
function Actor SpawnGhost(class<Actor> cls, harry h, bool bFollow)
{
    local Actor g;
    local Vector loc;
    local Rotator rot;

    FrontOfHarry(h, loc, rot);
    g = Spawn(cls, , , loc, rot);
    if (g == None)
    {
        Log("[Archipelago] GhostSpike: Spawn(" $ string(cls) $ ") returned None at " $ string(loc));
        return None;
    }
    Register(g, h, bFollow);
    return g;
}

// Reveal an init-built pool ghost in front of Harry.
function Actor RevealPoolGhost(bool bPawn, harry h)
{
    local Actor g;

    if (bPawn) g = PoolPawn;
    else       g = PoolActor;
    if (g == None || g.bDeleteMe)
    {
        Log("[Archipelago] GhostSpike: no pool ghost in this level (the pool is built on the InitGame path only, not after a save load)");
        return None;
    }
    LogGhost("pool reveal, before", g);
    g.bHidden = False;
    Register(g, h, True);
    return g;
}

function Register(Actor g, harry h, bool bFollow)
{
    local Vector loc;
    local Rotator rot;

    if (GhostCount >= GHOST_SLOTS)
    {
        Log("[Archipelago] GhostSpike: all " $ GHOST_SLOTS $ " slots in use, GhostSpikeClear first");
        return;
    }
    Ghosts[GhostCount] = g;
    if (bFollow) GhostFollow[GhostCount] = 1;
    else         GhostFollow[GhostCount] = 0;
    GhostCount++;

    g.SetPhysics(PHYS_None);
    g.SetCollision(False, False, False);
    FrontOfHarry(h, loc, rot);
    g.SetRotation(rot);
    g.SetLocation(loc);
    MirrorAnimation(g, h);
    LogGhost("registered (follow=" $ string(bFollow) $ ")", g);
}

function Tick(float fTimeDelta)
{
    local harry h;
    local int i;
    local Vector loc;
    local Rotator rot;

    Super.Tick(fTimeDelta);
    if (GhostCount == 0) return;
    h = class'APGameInfo'.static.FindGrantReadyHarry(self);
    if (h == None) return;

    FrontOfHarry(h, loc, rot);
    for (i = 0; i < GhostCount; i++)
    {
        if (Ghosts[i] == None || Ghosts[i].bDeleteMe || GhostFollow[i] == 0) continue;
        Ghosts[i].SetRotation(rot);
        Ghosts[i].SetLocation(loc);
        MirrorAnimation(Ghosts[i], h);
    }
}

// The spot FRONT_OFFSET units ahead of Harry on his floor, and a rotation that
// faces him.
function FrontOfHarry(harry h, out Vector loc, out Rotator rot)
{
    local Rotator flat;

    flat = h.Rotation;
    flat.Pitch = 0;
    flat.Roll = 0;
    loc = h.Location + FRONT_OFFSET * Vector(flat);
    rot = flat;
    rot.Yaw += 32768;
}

// Same mesh, same sequence names: replaying Harry's current sequence by name
// is all a peer ghost needs.
function MirrorAnimation(Actor g, harry h)
{
    if (h.AnimSequence == '' || g.AnimSequence == h.AnimSequence) return;
    g.LoopAnim(h.AnimSequence);
}

// Destroy the runtime ghosts, re-hide the pooled ones.
function ClearAll()
{
    local int i;

    for (i = 0; i < GhostCount; i++)
    {
        if (Ghosts[i] != None && !Ghosts[i].bDeleteMe)
        {
            if (Ghosts[i] == PoolActor || Ghosts[i] == PoolPawn)
                Ghosts[i].bHidden = True;
            else
                Ghosts[i].Destroy();
        }
        Ghosts[i] = None;
        GhostFollow[i] = 0;
    }
    GhostCount = 0;
}

function LogGhost(string label, Actor g)
{
    if (g == None)
    {
        Log("[Archipelago] GhostSpike: " $ label $ ": None");
        return;
    }
    Log("[Archipelago] GhostSpike: " $ label $ " " $ string(g.Class.Name) $ " " $ string(g.Name)
        $ " hidden=" $ string(g.bHidden) $ " style=" $ string(g.Style)
        $ " mesh=" $ string(g.Mesh) $ " scale=" $ string(g.DrawScale)
        $ " physics=" $ string(g.Physics) $ " loc=" $ string(g.Location)
        $ " zone=" $ string(g.Region.Zone) $ " leaf=" $ string(g.Region.iLeaf)
        $ " anim=" $ string(g.AnimSequence));
}

defaultproperties
{
    bHidden=True
}

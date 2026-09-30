//================================================================================
// APGhostPawn.
//
// Another slot's Harry, drawn as a translucent ghost. APGhostRegistry creates
// one per peer on this map, feeds it that peer's samples, and destroys it when
// the peer leaves or goes silent. The ghost glides toward the latest sample and
// replays the peer's animation sequences by name: the body track on the pawn
// itself and the casting track on an upper-body channel rooted at the spine
// bone, the same split Harry uses. A wand rides the hand bone the way a
// duellist's does. No collision, no physics, not a spell target: it can never
// affect play. Style and glow mirror Moaning Myrtle, the shipped translucent
// character.
//================================================================================

class APGhostPawn extends HPawn;

var int    PeerSlot;
var string PeerName;
var Vector  TargetLocation;
var Rotator TargetRotation;
var byte    bHasTarget;
// Level.TimeSeconds of the last sample, for the registry's silence expiry.
var float   LastSeenTime;
var APGhostAnimChannel Channel;
var Weapon  Wand;
// Last sequence and frame per track, to tell a fresh one-shot from the same
// one still playing.
var name LastBodySequence;
var int  LastBodyFrame;
var name LastChannelSequence;
var int  LastChannelFrame;
// Whether the body last played in combine mode (the peer's channel was live).
var bool bLastBodyCombine;
// Added to every sample's height before it is applied. A class default, so the
// APConsole GhostZOffset exec can tune it live against a standing ghost.
var float ZOffset;

// Per second. About 80 ms behind the latest sample, which hides the ten-hertz steps.
const GLIDE_RATE = 12.0;
// A sample farther away than this is a teleport (map entry, a fall), not motion.
const SNAP_DISTANCE = 600.0;
// A frame this far below the last one means the same sequence started over.
const RESTART_FRAME_DROP = 30;
// A one-shot reported at or past this frame has finished; starting it would show
// a cast that is not happening.
const FINISHED_FRAME = 99;

function SetupPeer(int slot, string displayName)
{
    PeerSlot = slot;
    PeerName = displayName;
    SetPhysics(PHYS_None);
    SetCollision(False, False, False);
    Channel = APGhostAnimChannel(CreateAnimChannel(class'APGhostAnimChannel', AT_Replace, 'bip01 Spine1'));
    if (Channel != None)
    {
        Channel.SetOwner(self);
    }
    // The recipe Duellist uses to hold a wand.
    Wand = Spawn(class'baseWand', self);
    if (Wand != None)
    {
        Wand.BecomeItem();
        Wand.WeaponSet(self);
        Wand.GiveAmmo(self);
        Wand.Style = STY_Translucent;
    }
}

function SetTarget(Vector loc, Rotator rot, float scale)
{
    loc.Z += default.ZOffset;
    if (bHasTarget == 0 || VSize(loc - Location) > SNAP_DISTANCE)
    {
        SetLocation(loc);
        SetRotation(rot);
    }
    TargetLocation = loc;
    TargetRotation = rot;
    bHasTarget = 1;
    if (scale > 0.0)
    {
        DrawScale = scale;
    }
}

function SetGhostHidden(bool bHide)
{
    bHidden = bHide;
    if (Wand != None)
    {
        Wand.bHidden = bHide;
    }
}

function Tick(float fTimeDelta)
{
    local float alpha;

    Super.Tick(fTimeDelta);
    if (bHasTarget == 0 || bHidden) return;
    alpha = FMin(1.0, fTimeDelta * GLIDE_RATE);
    SetLocation(Location + (TargetLocation - Location) * alpha);
    SetRotation(GlideRotation(Rotation, TargetRotation, alpha));
}

// Shortest-arc step from one rotation toward another; each axis wraps at 65536.
static function Rotator GlideRotation(Rotator current, Rotator target, float alpha)
{
    local Rotator stepped;

    stepped.Pitch = current.Pitch + int(WrapDelta(target.Pitch - current.Pitch) * alpha);
    stepped.Yaw   = current.Yaw   + int(WrapDelta(target.Yaw   - current.Yaw)   * alpha);
    stepped.Roll  = current.Roll  + int(WrapDelta(target.Roll  - current.Roll)  * alpha);
    return stepped;
}

static function int WrapDelta(int delta)
{
    delta = delta & 65535;
    if (delta > 32767) delta -= 65536;
    return delta;
}

// Replay the peer's two tracks by name. The body plays with the peer's blend
// type: AT_Combine while his casting channel is live, so a body change leaves
// the channel showing, and AT_Replace once it is done, which is what clears the
// upper body back to the body's pose (Harry's own PlayIdle does the same). A
// type flip replays the body even when the sequence did not change. The peer's
// channel keeps reporting its last sequence after it finishes, so a finished
// one-shot there is left alone; a repeated one-shot replays only when its frame
// drops back.
function ApplyAnimation(harry h, string bodySequence, int bodyFrame, bool bBodyLoops, bool bBodyCombine,
                        string channelSequence, int channelFrame, bool bChannelLoops)
{
    local name seq;
    local EAnimType bodyType;

    if (bBodyCombine) bodyType = AT_Combine;
    else              bodyType = AT_Replace;

    seq = h.StringToAnimName(bodySequence);
    if (seq != '' && HasAnim(seq))
    {
        if (seq != LastBodySequence
            || bBodyCombine != bLastBodyCombine
            || (!bBodyLoops && bodyFrame + RESTART_FRAME_DROP < LastBodyFrame))
        {
            if (bBodyLoops) LoopAnim(seq, , , , bodyType);
            else            PlayAnim(seq, , , bodyType);
        }
        LastBodySequence = seq;
        LastBodyFrame    = bodyFrame;
        bLastBodyCombine = bBodyCombine;
    }

    if (Channel == None) return;
    seq = h.StringToAnimName(channelSequence);
    if (seq != '' && HasAnim(seq))
    {
        if (seq != LastChannelSequence
            || (!bChannelLoops && channelFrame + RESTART_FRAME_DROP < LastChannelFrame))
        {
            if (bChannelLoops)                      Channel.LoopAnim(seq);
            else if (channelFrame < FINISHED_FRAME) Channel.PlayAnim(seq, ChannelSequenceRate(seq), 0.1);
        }
        LastChannelSequence = seq;
        LastChannelFrame    = channelFrame;
    }
}

// The rates Harry's casting channel plays its one-shots at, so the ghost's wave
// finishes when his does and the body's reset does not cut it short.
static function float ChannelSequenceRate(name seq)
{
    if (seq == 'Cast') return 2.0;
    if (seq == 'SwordCast' || seq == 'throw') return 1.5;
    return 1.0;
}

defaultproperties
{
    DrawType=DT_Mesh
    Mesh=SkeletalMesh'HPModels.skharryMesh'
    Style=STY_Translucent
    AmbientGlow=65
    ShadowClass=None
    bPlayRunAnim=False
    Physics=PHYS_None
    bCollideActors=False
    bCollideWorld=False
    bBlockActors=False
    bBlockPlayers=False
    bProjTarget=False
    eVulnerableToSpell=SPELL_None
    CollisionRadius=15.00
    CollisionHeight=42.00
}

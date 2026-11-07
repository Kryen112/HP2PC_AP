//================================================================================
// APGhostGlasses.
//
// A dark pair of glasses on a ghost's face. The ghost itself draws translucent,
// which cannot show dark colours, so its own glasses fade away. This separate
// model draws solid, in a grey blue that matches the ghost's tint, and follows
// the bone where Harry's glasses sit every tick. It
// hides with the ghost and whenever the ghost wears a mesh other than Harry's,
// and removes itself once its ghost is gone.
//
// Where it sits is a head-relative offset and turn, class defaults so the
// APConsole GhostGlasses exec can tune them live against a standing ghost.
//================================================================================

class APGhostGlasses extends Actor;

const HEAD_BONE = 'bip01 Head';
// Harry's skeleton carries a bone where his own glasses sit.
const GLASSES_BONE = 'glasses';

var APGhostPawn Ghost;

// In the followed bone's own axes, scaled with the ghost.
var float OffsetX, OffsetY, OffsetZ;
// Turn from the followed bone's axes to the model's (rotator units).
var int TurnPitch, TurnYaw, TurnRoll;
var float GlassesScale;
// 1 to follow the glasses bone, 0 for the head bone.
var byte bFollowGlassesBone;

function PostBeginPlay()
{
    Super.PostBeginPlay();
    Mesh = class'APAppearanceMath'.static.LoadMesh("HPArchipelago.APGhostGlassesModel");
    if (Mesh == None)
    {
        Log("[Archipelago] Ghosts: the glasses mesh failed to load");
    }
}

function AttachToGhost(APGhostPawn g)
{
    Ghost = g;
    SetOwner(g);
    TickParent = g;
    FollowHead();
}

function Tick(float fTimeDelta)
{
    Super.Tick(fTimeDelta);
    if (Ghost == None || Ghost.bDeleteMe)
    {
        Destroy();
        return;
    }
    FollowHead();
}

function FollowHead()
{
    local Rotator head, turn;
    local Vector offset;
    local float scale;

    bHidden = Ghost.bHidden || Mesh == None || !Ghost.WearsHarryMesh();
    if (bHidden) return;
    scale = Ghost.DrawScale;
    if (scale <= 0.0) scale = 1.0;
    head = Ghost.BoneRot(FollowedBone());
    offset.X = default.OffsetX;
    offset.Y = default.OffsetY;
    offset.Z = default.OffsetZ;
    SetLocation(Ghost.BonePos(FollowedBone()) + ((offset * scale) >> head));
    turn.Pitch = default.TurnPitch;
    turn.Yaw = default.TurnYaw;
    turn.Roll = default.TurnRoll;
    SetRotation(ComposeRotation(head, turn));
    DrawScale = default.GlassesScale * scale;
}

static function name FollowedBone()
{
    if (default.bFollowGlassesBone == 1) return GLASSES_BONE;
    return HEAD_BONE;
}

// The rotation that applies inner first and then outer.
static function Rotator ComposeRotation(Rotator outer, Rotator inner)
{
    local Vector X, Y, Z;

    GetAxes(inner, X, Y, Z);
    return AxesToRotation(X >> outer, Y >> outer, Z >> outer);
}

// The rotator whose axes are X, Y and Z. Pitch and yaw come from X; roll is the
// turn about X that carries the unrolled Y onto the given Y, with its sign
// checked against the engine's own convention.
static function Rotator AxesToRotation(Vector X, Vector Y, Vector Z)
{
    local Rotator r;
    local Vector X0, Y0, Z0, X1, Y1, Z1;
    local int roll;

    r = Rotator(X);
    r.Roll = 0;
    GetAxes(r, X0, Y0, Z0);
    roll = int(Atan2(Y Dot Z0, Y Dot Y0) * 32768.0 / Pi);
    r.Roll = roll;
    GetAxes(r, X1, Y1, Z1);
    if ((Y1 Dot Y) < 0.99)
    {
        r.Roll = -roll;
    }
    return r;
}

static function float Atan2(float y, float x)
{
    if (x > 0.0) return Atan(y / x);
    if (x < 0.0)
    {
        if (y >= 0.0) return Atan(y / x) + Pi;
        return Atan(y / x) - Pi;
    }
    if (y > 0.0) return Pi / 2.0;
    if (y < 0.0) return -Pi / 2.0;
    return 0.0;
}

// A bone's axes and position in the ghost's own frame, for tuning.
function string DescribeBone(name bone)
{
    local Vector X, Y, Z, forward, side, up, rel;

    if (Ghost == None) return "no ghost";
    GetAxes(Ghost.Rotation, forward, side, up);
    GetAxes(Ghost.BoneRot(bone), X, Y, Z);
    rel = Ghost.BonePos(bone) - Ghost.Location;
    return string(bone) $ " at (fwd " $ (rel Dot forward) $ ", side " $ (rel Dot side) $ ", up " $ (rel Dot up) $ ")"
        $ " X=(" $ (X Dot forward) $ "," $ (X Dot side) $ "," $ (X Dot up) $ ")"
        $ " Y=(" $ (Y Dot forward) $ "," $ (Y Dot side) $ "," $ (Y Dot up) $ ")"
        $ " Z=(" $ (Z Dot forward) $ "," $ (Z Dot side) $ "," $ (Z Dot up) $ ")";
}

defaultproperties
{
    DrawType=DT_Mesh
    Style=STY_Normal
    bUnlit=True
    bCollideActors=False
    bCollideWorld=False
    bBlockActors=False
    bBlockPlayers=False
    bProjTarget=False
    Physics=PHYS_None
    RemoteRole=ROLE_None
    bFollowGlassesBone=1
    // The glasses bone's axes: X to Harry's left, Y backward, Z down. The model
    // faces +X with +Z up.
    OffsetY=-0.5
    OffsetZ=-0.5
    TurnYaw=-16384
    TurnRoll=32768
    GlassesScale=1.0
}

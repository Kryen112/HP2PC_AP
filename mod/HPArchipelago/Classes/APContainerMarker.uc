// AP token for a containersanity location (a bean / ingredient / Peeves / gnome
// container). Two eject paths:
//
//   QUEUE (chests/cauldrons): gen_apworld emits a per-location subclass
//   APContainerMarker_<offset> with CheckLocationId baked into defaults. The
//   swapped APContainerChest_<Leaf> injects that class as the first item in the
//   container's own eject queue, so the container's loop spits it out first with
//   bean velocity and the inter-bean delay. The baked id is known in
//   PostBeginPlay, so this BASE class self-registers its appearance there.
//
//   SWAP (GenericSpawner family): the APContainerSpawner_<Leaf> subclass spawns
//   this BASE class (CheckLocationId 0 at spawn) on the opening hit and stamps +
//   appearance-applies it right after Spawn.
//
// Either way Touch fires CHECK_LOCID (a non-card AP location) and dedupes via
// APCardWatcher.NonCardLocationChecked[], exactly like APVendorMarker_Trader.
//
// Extends HProp (the prop/pickup base), NOT WizardCardIcon: vanilla card-
// management sweeps only touch WizardCardIcon, so as a plain HProp this marker is
// ignored by them and no Id sentinel is needed. The appearance sweep morphs it to
// the placed item's look (it only touches Actor-level draw fields).
class APContainerMarker extends HProp;

const LOC_BASE = 5760000;
// Mirrors NONCARD_LOC_WINDOW in APCardWatcher.uc / APVendorMarker_Trader.uc /
// gen_apworld.py; all must hold the same value (M212 can't cross-reference a
// const, and guards take an integer literal anyway).
const NONCARD_LOC_WINDOW = 2048;

var int CheckLocationId;

function PostBeginPlay()
{
    local APCardWatcher w;
    local int slot;

    Super.PostBeginPlay();

    // Both eject paths spawn a per-location APContainerMarker_<offset> subclass
    // with CheckLocationId baked into its default, so it is known here -- the
    // chest/cauldron queue and the spawner goodie-slot both DynamicLoadObject it
    // by offset. Self-destroy a stale already-checked ghost, then register for
    // the appearance sweep and apply the placed item's look.
    if (CheckLocationId > LOC_BASE)
    {
        slot = CheckLocationId - LOC_BASE;
        if (slot >= 0 && slot < NONCARD_LOC_WINDOW
            && class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1)
        {
            Destroy();
            return;
        }
        w = class'APCardWatcher'.static.GetLatest();
        if (w != None)
        {
            w.RegisterMorphMarker(self, CheckLocationId);
        }
        ApplyAPAppearance();
    }

    // bPersistent is left as the container set it (newSpawn.bPersistent =
    // bMakeSpawnPersistent, True for every bean container), so an uncollected
    // token survives a hub leave/re-enter exactly like the beans beside it.
}

// Eject behaviour mirrors a wizard card: drop with PHYS_Falling, bounce off
// surfaces (dampening) until it settles on the floor, then spin in place. The
// visible default mesh + pickup collision come from defaultproperties; the
// appearance sweep morphs the mesh to the placed item.
function Spawned()
{
    SetPhysics(PHYS_Falling);
    GotoState('bouncing');
}

// Bounce + spin until a floor-ish hit, then settle. Mirrors WizardCardIcon.bouncing.
state bouncing
{
    function HitWall(Vector HitNormal, Actor Wall)
    {
        // Dampen + reflect off the surface, bouncing (like a bean) until the
        // speed drops below the settle threshold, then come to rest and spin.
        Velocity *= 0.6;
        Velocity = MirrorVectorByNormal(Velocity, HitNormal);
        if (VSize(Velocity) < 50.0)
        {
            Velocity = vect(0.0, 0.0, 0.0);
            GotoState('Wait');
        }
    }

    function Tick(float Delta)
    {
        local Rotator newRot;

        newRot = Rotation;
        newRot.Yaw = newRot.Yaw + (50000 * Delta);
        SetRotation(newRot);
    }
}

// Settled: keep spinning in place (no HitWall override, so it rests on the
// floor under gravity). Mirrors WizardCardIcon.Wait.
auto state Wait
{
    function Tick(float Delta)
    {
        local Rotator newRot;

        newRot = Rotation;
        newRot.Yaw = newRot.Yaw + (50000 * Delta);
        SetRotation(newRot);
    }

begin:
    Sleep(1.0);
    goto ('Begin');
}

// `event` (not `function`) to match HProp.Touch's declaration; overriding with a
// mismatched keyword is an M212 hazard. No Super: the vanilla pickup/grant path
// never runs -- this fires the AP check instead.
event Touch(Actor Other)
{
    local APIPCActor ipc;
    local Rotator rotPickupFX;
    local int slot;

    if (harry(Other) == None) return;
    if (CheckLocationId <= 0) return;

    slot = CheckLocationId - LOC_BASE;
    if (slot < 0 || slot >= NONCARD_LOC_WINDOW) return;

    if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1)
    {
        Log("[Archipelago] APContainerMarker.Touch: location " $ CheckLocationId
            $ " already checked - destroying stale duplicate");
        Destroy();
        return;
    }

    class'APCardWatcher'.default.NonCardLocationChecked[slot] = 1;
    Log("[Archipelago] APContainerMarker.Touch: firing CHECK_LOCID " $ CheckLocationId);

    if (soundPickup != None)
    {
        PlaySound(soundPickup);
    }

    // AP pickup burst, matching APCardMarker / APVendorMarker_Trader styling.
    // Pitch=16464 emits the stars upward.
    rotPickupFX.Pitch = 16464;
    rotPickupFX.Yaw = 0;
    rotPickupFX.Roll = 0;
    Spawn(class'APStarsRed',    , , Location, rotPickupFX);
    Spawn(class'APStarsOrange', , , Location, rotPickupFX);
    Spawn(class'APStarsYellow', , , Location, rotPickupFX);
    Spawn(class'APStarsGreen',  , , Location, rotPickupFX);
    Spawn(class'APStarsBlue',   , , Location, rotPickupFX);
    Spawn(class'APStarsPurple', , , Location, rotPickupFX);

    ipc = class'APIPCActor'.static.GetInstance();
    if (ipc != None)
    {
        ipc.SendCheckLocationId(CheckLocationId);
    }

    Destroy();
}

// Appearance capability contract: CheckLocationId is the resolvable AP id; the
// sweep morphs this marker to whatever item the seed placed here.
function ApplyAPAppearance()
{
    if (CheckLocationId <= 0) return;
    class'APCardWatcher'.static.ApplyAppearanceTo(self,
        class'APCardWatcher'.static.AppearanceForApId(CheckLocationId));
}

defaultproperties
{
    bPickupOnTouch=True
    PickupFlyTo=FT_HudPosition
    classStatusGroup=None
    classStatusItem=None
    bCollideWhenPlacing=False
    // Distinctive AP pickup cue: the wizard-card collect sound, not the bean
    // sound, so grabbing an AP item reads clearly.
    soundPickup=Sound'HPSounds.Magic_sfx.pickup_WC_bronze'
    // Pickup collision + look copied from WizardCardIcon (same HProp parent): a
    // small cylinder that does NOT block the player (so Harry overlaps it ->
    // Touch fires) and does not block the camera. bCollideWorld stays True, so it
    // still falls and lands on the floor.
    Mesh=SkeletalMesh'HProps.skWizardCardIconMesh'
    DrawScale=2.00
    AmbientGlow=250
    // Small cylinder (bean-sized) so it fits the tight spots spawners sit in
    // and still touches Harry; bRotateToDesired=False frees the Tick spin.
    CollisionRadius=8.00
    CollisionHeight=12.00
    // bBlockActors=False is REQUIRED, not cosmetic: HProp/HPawn default it True,
    // and a blocking actor spawned inside the container's own collision cylinder
    // fails the engine encroachment check (Spawn returns None) even with
    // bCollideWhenPlacing=False. A real bean (Jellybean) ships bBlockActors=False
    // for exactly this reason, so the marker must too or tall/low-eject containers
    // (cauldrons, knights, cigar/music boxes, decanters) never eject a token.
    bBlockActors=False
    bBlockPlayers=False
    bBlockCamera=False
    bCantStandOnMe=True
    bBounce=True
    bRotateToDesired=False
}

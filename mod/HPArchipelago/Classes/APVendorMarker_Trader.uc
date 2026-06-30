// AP-aware drop-in replacement for the card / ingredient a generic vendor
// spawns on its first Tradersanity sale. One class covers every vendor type
// (Bronze/Silver card, Wiggentree Bark, Flobberworm Mucus); the actual look
// is resolved at runtime by the appearance sweep, not baked here.
//
// Extends WizardCardIcon (the APCardMarker base) rather than a specific sale
// item because a Trader marker stands in for four different vanilla items, so
// there is no single item to inherit. WizardCardIcon supplies the AP-pickup
// behaviour: a visible default card mesh (so it never renders invisible even
// if the appearance table never arrives, e.g. AP offline), the fly-to-HUD
// spin, and the Id=200 sentinel that keeps vanilla card-management
// (RemoveHarryOwnedCardsFromLevel / AssignVendorCards) from touching it. The
// appearance subsystem then morphs it to the real held item / AP-logo plate.
//
// Semantics differ from APCardMarker: this is a non-card AP location (band
// 800-812), so Touch dedupes via NonCardLocationChecked[] and fires
// SendCheckLocationId (a non-card AP location), not SendCheck.
//
// Spawned by APVendorController.TradersanityPass when it sees a freshly-sold item
// next to an unchecked Tradersanity vendor; CheckLocationId is stamped after
// Spawn with that vendor's AP location id (APLocationRegistry.GetVendorLocationId).
class APVendorMarker_Trader extends WizardCardIcon;

const LOC_BASE = 5760000;
// Mirrors APCardWatcher.NONCARD_LOC_WINDOW
// (and APContainerMarker); all must hold the same value (M212 UScript can't
// reference another class's const, and array dims / guards take an integer
// literal anyway). The Tradersanity band (800-812) is well inside this window.
const NONCARD_LOC_WINDOW = 2048;

var int CheckLocationId;

// Drop straight down and settle, skipping WizardCardIcon.Spawned's
// bounce-around state (which would carry the marker away from the vendor).
// Mirrors APCardMarker.Spawned.
function Spawned()
{
    SetPhysics(PHYS_Falling);
    bBouncingState = False;
    GotoState('Wait');
}

// Settle on the landing surface and spin in place. Mirrors APCardMarker's
// Wait state; UE1 needs the begin: entry point.
auto state Wait
{
    function HitWall(Vector HitNormal, Actor Wall)
    {
        Velocity = vect(0, 0, 0);
    }

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

// `function` (not `event`) to match WizardCardIcon.Touch's declaration, the
// same as APCardMarker; overriding with a mismatched keyword is an M212
// hazard. No Super call: the vanilla card-grant path never runs.
function Touch(Actor Other)
{
    local APIPCActor ipc;
    local int slot;

    if (harry(Other) == None) return;
    if (CheckLocationId <= 0) return;

    slot = CheckLocationId - LOC_BASE;
    if (slot < 0 || slot >= NONCARD_LOC_WINDOW) return;

    if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1)
    {
        Log("[Archipelago] APVendorMarker_Trader.Touch: location " $ CheckLocationId
            $ " already checked - destroying stale duplicate marker");
        Destroy();
        return;
    }

    class'APCardWatcher'.default.NonCardLocationChecked[slot] = 1;
    Log("[Archipelago] APVendorMarker_Trader.Touch: firing CHECK_LOCID " $ CheckLocationId);

    if (soundPickup != None)
    {
        PlaySound(soundPickup);
    }

    // AP pickup burst.
    class'APStarsBase'.static.SpawnPickupBurst(self, Location);

    ipc = class'APIPCActor'.static.GetInstance();
    if (ipc != None)
    {
        ipc.SendCheckLocationId(CheckLocationId);
    }

    Destroy();
}

// Appearance capability contract. CheckLocationId (stamped after Spawn by
// APVendorController.TradersanityPass) is the resolvable AP location id; the sweep
// morphs this marker to whatever item the seed placed here.
function ApplyAPAppearance()
{
    if (CheckLocationId <= 0) return;
    class'APAppearanceMath'.static.ApplyAppearanceTo(self,
        class'APMorphRegistry'.static.AppearanceForApId(CheckLocationId));
}

defaultproperties
{
    // Id=200 is the WizardCards[] sentinel APCardMarker uses so vanilla
    // card-owner sweeps skip this marker. classStatusGroup/Item cleared so no
    // inherited HProp pickup pipeline grants inventory on touch (Touch never
    // calls Super anyway; defensive).
    Id=200
    bPickupOnTouch=True
    PickupFlyTo=FT_HudPosition
    classStatusGroup=None
    classStatusItem=None
    // The sold item often comes to rest against geometry before the watcher
    // tick swaps it; with placement-collision on, Spawn() at that spot
    // returns None and the swap loses the item. Placement collision is not
    // needed (PHYS_Falling + the Wait HitWall settle it anyway), so off.
    bCollideWhenPlacing=False
}

// Placeholder card-style marker for non-card AP locations whose vendor sale
// (or other vanilla pickup chain) needs a visual swap. Currently used for the
// two Quidditch vendor purchases — Fred (Nimbus 2001) and George (Quidditch
// Armour) — where vanilla spawns VendorNimbusBroom / QArmor and we want the
// player to see an AP-flavoured card pickup instead of the unique vanilla
// item, so the sale looks "properly randomized".
//
// Differs from the per-card APCardMarker_<X> subclasses in two ways:
//   1. Carries CheckLocationId in the full id_offset domain (locations.yaml
//      base + offset → e.g. 5 / 6 for Quidditch purchases), NOT the
//      card-domain CardLocationId (1..101). The parent's CardLocationId is
//      left at 0 so APCardMarker.Touch's card-domain bounds check (`<= 0 ||
//      > 101`) short-circuits and we skip the card-only side effects
//      (vendor ClearVendorOwnership, AP-stars FX, card pickup sound).
//   2. Spawned at runtime by APCardWatcher's vendor-flow interception (TODO:
//      ReplaceVendorSpawnedQuidditchGear, mirrors ReplaceVendorSpawnedCards
//      Phase B for cards). CheckLocationId is set on the spawned instance
//      from a (vendor_class, vanilla_sells) → location-id lookup generated
//      by gen_apworld.py from data/locations.yaml's quidditch_purchases
//      section.
//
// TODO — wiring still needed before this class fires anything in-game:
//   - APCardWatcher: add a non-card `VendorLocationChecked[8]` (or similarly
//     sized) byte array so PostBeginPlay / Touch can dedupe per-location
//     without colliding with the existing card-domain LocationChecked[102].
//   - APCardWatcher: add `ReplaceVendorSpawnedQuidditchGear()` mirroring
//     `ReplaceVendorSpawnedCards()` — scan AllActors for VendorNimbusBroom
//     and QArmor, destroy them, Spawn APCardMarker_PHCard at the same
//     Location/Rotation with CheckLocationId set from the registry lookup.
//   - APCardWatcher: detect harry.bHaveNimbus2001 / bHaveQArmor transitioning
//     False→True without a matching AP-granted flag, revert to False, so the
//     player doesn't pocket the local item on top of whatever AP delivers.
//   - gen_apworld.py: emit the (vendor_class, vanilla_sells) → CheckLocationId
//     registry into a generated UScript file (e.g. APVendorRegistry.uc).
//
// Until that wiring lands this class compiles and lives in the package but
// is never spawned. The data side (items.yaml/locations.yaml) is in place so
// generation produces stable ids the moment the watcher catches up.
class APCardMarker_PHCard extends APCardMarker;

// Full-domain AP location id (locations.yaml id_offset). Set by the spawner
// at vendor-sale interception time; left at 0 on the class default so a
// stray editor placement does nothing harmful.
var int CheckLocationId;

function PostBeginPlay()
{
    // Skip the parent's card-domain LocationChecked[] self-destroy guard
    // (CardLocationId stays 0 so the parent treats this as out-of-range and
    // bypasses the check). Once VendorLocationChecked[] exists in
    // APCardWatcher we should add a parallel guard here:
    //
    //     if (CheckLocationId > 0
    //         && class'APCardWatcher'.default.VendorLocationChecked[CheckLocationId] == 1)
    //     {
    //         Destroy();
    //         return;
    //     }
    //
    // For now: fall through to parent, which only handles the bPersistent
    // timer + the card-domain guard.
    Super.PostBeginPlay();

    Log("[Archipelago] APCardMarker_PHCard.PostBeginPlay: " $ string(self)
        $ " CheckLocationId=" $ CheckLocationId $ " at " $ string(Location));
}

function Touch(Actor Other)
{
    local APIPCActor ipc;
    local harry h;
    local Rotator rotPickupFX;

    h = harry(Other);
    if (h == None) return;
    if (CheckLocationId <= 0) return;

    // TODO — wire VendorLocationChecked dedupe once that array exists:
    //     if (class'APCardWatcher'.default.VendorLocationChecked[CheckLocationId] == 1)
    //     {
    //         Destroy();
    //         return;
    //     }
    //     class'APCardWatcher'.default.VendorLocationChecked[CheckLocationId] = 1;

    Log("[Archipelago] APCardMarker_PHCard.Touch: firing CHECK " $ CheckLocationId);

    ipc = class'APIPCActor'.static.GetInstance();
    if (ipc != None)
    {
        ipc.SendCheck(CheckLocationId);
    }
    else
    {
        Log("[Archipelago] APCardMarker_PHCard.Touch: APIPCActor singleton is None - CHECK " $ CheckLocationId $ " dropped");
    }

    // AP-themed pickup feedback — same star burst as APCardMarker so the
    // visual lands "this was an AP item" regardless of what vanilla would
    // have spawned at this slot.
    rotPickupFX.Pitch = 16464;
    rotPickupFX.Yaw = 0;
    rotPickupFX.Roll = 0;
    Spawn(class'APStarsRed',    , , Location, rotPickupFX);
    Spawn(class'APStarsOrange', , , Location, rotPickupFX);
    Spawn(class'APStarsYellow', , , Location, rotPickupFX);
    Spawn(class'APStarsGreen',  , , Location, rotPickupFX);
    Spawn(class'APStarsBlue',   , , Location, rotPickupFX);
    Spawn(class'APStarsPurple', , , Location, rotPickupFX);

    if (soundPickup != None)
    {
        PlaySound(soundPickup);
    }

    Destroy();
}

defaultproperties
{
    // CheckLocationId left at 0 by default; spawner stamps the real id.
    // CardLocationId inherited as 0 (parent default) — keeps APCardMarker's
    // card-domain Touch path inert.
    // Bronze card pickup sound for now; spawner can override if a tier-specific
    // sound is desired per equipment type.
    soundPickup=Sound'HPSounds.Magic_sfx.pickup_WC_bronze'
    MarkerTier="Bronze"
}

// AP-aware drop-in replacement for the VendorNimbusBroom that Fred Weasley
// spawns on a Nimbus 2001 purchase. Inherits the vanilla broom mesh, sound,
// physics, and "bounce into place" behavior so visually it's identical to
// what vanilla would have spawned.
//
// Differences vs vanilla:
//   - classStatusGroup / classStatusItem cleared so the inherited HProp
//     pickup pipeline does not increment StatusItemNimbus. The player keeps
//     the bHaveNimbus2001 flag that MakePurchase set (vendor stops offering),
//     but no inventory item is granted; the AP grant of "Nimbus 2001"
//     elsewhere in the seed populates StatusItemNimbus.
//   - Touch is overridden to bypass PickupProp entirely (vanilla's begin:
//     fly-to-HUD relies on a valid classStatusItem position lookup, which
//     would return garbage with classStatusItem=None). Instead it plays the
//     inherited soundPickup, spawns the AP rainbow burst (matching
//     APCardMarker pickup feedback), fires CHECK_LOCID, and Destroys.
//
// Spawned by APCardWatcher.ReplaceVendorEquipment when it sees a freshly
// MakePurchase'd VendorNimbusBroom in AllActors. CheckLocationId is stamped
// at spawn time with the AP id for "Castle Exterior - Nimbus 2001" (5760005).
class APVendorMarker_Nimbus extends VendorNimbusBroom;

const LOC_BASE = 5760000;

var int CheckLocationId;

event Touch(Actor Other)
{
    local APIPCActor ipc;
    local Rotator rotPickupFX;
    local int slot;

    if (harry(Other) == None) return;
    if (CheckLocationId <= 0) return;

    slot = CheckLocationId - LOC_BASE;
    if (slot < 0 || slot >= 700) return;

    if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1)
    {
        Log("[Archipelago] APVendorMarker_Nimbus.Touch: location " $ CheckLocationId
            $ " already checked - destroying stale duplicate marker");
        Destroy();
        return;
    }

    class'APCardWatcher'.default.NonCardLocationChecked[slot] = 1;
    Log("[Archipelago] APVendorMarker_Nimbus.Touch: firing CHECK_LOCID " $ CheckLocationId);

    if (soundPickup != None)
    {
        PlaySound(soundPickup);
    }

    // AP pickup burst, matching APCardMarker.Touch styling so vendor markers
    // read as AP-aware to the player. Pitch=16464 emits stars upward.
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

// Appearance capability contract. CheckLocationId (5760005, stamped after
// Spawn by APCardWatcher.ReplaceVendorEquipment) is the resolvable AP id.
function ApplyAPAppearance()
{
    if (CheckLocationId <= 0) return;
    class'APCardWatcher'.static.ApplyAppearanceTo(self,
        class'APCardWatcher'.static.AppearanceForApId(CheckLocationId));
}

defaultproperties
{
    // Override inherited StatusGroupQGear / StatusItemNimbus to prevent the
    // managerStatus.PickupItem path from incrementing inventory on touch.
    classStatusGroup=None
    classStatusItem=None
}

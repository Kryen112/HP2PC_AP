// AP-aware drop-in replacement for the QArmor that George Weasley spawns on
// a Quidditch Armour purchase. Mirrors APVendorMarker_Nimbus — see that file
// for the rationale. Stamped at spawn time with the AP id for
// "Castle Exterior - Quidditch Armour" (5760006).
class APVendorMarker_QArmor extends QArmor;

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
        Log("[Archipelago] APVendorMarker_QArmor.Touch: location " $ CheckLocationId
            $ " already checked - destroying stale duplicate marker");
        Destroy();
        return;
    }

    class'APCardWatcher'.default.NonCardLocationChecked[slot] = 1;
    Log("[Archipelago] APVendorMarker_QArmor.Touch: firing CHECK_LOCID " $ CheckLocationId);

    if (soundPickup != None)
    {
        PlaySound(soundPickup);
    }

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

// Appearance capability contract. CheckLocationId (5760006, stamped after
// Spawn by APCardWatcher.ReplaceVendorEquipment) is the resolvable AP id.
function ApplyAPAppearance()
{
    if (CheckLocationId <= 0) return;
    class'APCardWatcher'.static.ApplyAppearanceTo(self,
        class'APCardWatcher'.static.AppearanceForApId(CheckLocationId));
}

defaultproperties
{
    classStatusGroup=None
    classStatusItem=None
}

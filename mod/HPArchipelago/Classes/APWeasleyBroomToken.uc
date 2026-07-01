// AP pickup token for Fred's Nimbus 2001 sale: the swapped-in stand-in for the
// thrown vanilla VendorNimbusBroom. Touch fires CHECK_LOCID the instant the player
// grabs it, instead of waiting for FireWeasleyCheck's per-tick bDeleteMe poll.
//
// Extends VendorNimbusBroom (not a plain HProp) so APVendorController's
// `foreach AllActors(class'VendorNimbusBroom')` still finds it after a hub
// re-entry and re-binds WeasleyToken[0]. Without that re-bind, FireWeasleyCheck's
// bPaidNoToken safety net would fire the check the moment the player re-enters,
// while the token still sits uncollected. Inherits the broom mesh, collision box,
// and the native bounce, so the thrown arc and grab feel match vanilla. The grant
// is nulled (the vanilla purchase already gave the broom); the AP item arrives
// over the wire.
class APWeasleyBroomToken extends VendorNimbusBroom;

var int CheckLocationId;

event Touch(Actor Other)
{
    // Mirror the vanilla pickup grace period (HProp.CanPickupNow): no grab while
    // still engaged with the vendor, so the thrown broom flies through Harry and is
    // collected once he disengages, exactly like the vanilla drop. VendorNimbusBroom
    // sets bPickupOnTouch, so this passes.
    if (!CanPickupNow(Other)) return;
    class'APVendorTokenFire'.static.FireAndConsume(self, CheckLocationId);
}

defaultproperties
{
    classStatusGroup=None
    classStatusItem=None
    // The swap Spawn can catch the thrown broom the tick it drops at the vendor,
    // so a blocking token fails the encroachment check there. VendorNimbusBroom
    // leaves bBlockActors at the Pawn default (True); clear it. bCollideWorld and
    // bBlockPlayers stay as the base sets them, so it still lands and stays grabbable.
    bBlockActors=False
}

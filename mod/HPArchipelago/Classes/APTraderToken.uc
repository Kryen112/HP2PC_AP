// AP pickup token a Tradersanity vendor drops when sold: the swapped-in stand-in
// for the vanilla PotionIngredients the trade drops. Touch fires CHECK_LOCID the
// instant the player grabs it, instead of waiting for APVendorController's
// per-tick bDeleteMe poll.
//
// Extends PotionIngredients (not a plain HProp) so the TradersanityPass morph
// sweep still finds it via its foreach AllActors(class'PotionIngredients') after a
// hub re-entry and its swap-skip guard recognises it. APVendorController swaps it
// in, stamps CheckLocationId, and applies the AP item appearance. The grant fields
// are nulled so picking it up adds no ingredient; the AP item arrives over the wire
// and the vanilla purchase already paid out.
//
// The pickup collision and bounce come from THIS class's defaults, not the base.
// The bare PotionIngredients carries none of them (only the concrete WiggentreeBark
// / FlobberwormMucus subclasses set bBlockPlayers, bBounceIntoPlace, and a pickup
// cylinder). Without them the token would inherit the engine Pawn defaults, so it
// would block the player (Harry bumps it, Touch never fires, uncollectable), never
// fall or settle (no bounce, it hangs where the sale prop was), and its swap Spawn
// would fail the encroachment check next to the vendor (bBlockActors). Mirror the
// sibling AP pickup token APContainerMarker.
class APTraderToken extends PotionIngredients;

var int CheckLocationId;

event Touch(Actor Other)
{
    // Mirror the vanilla pickup grace period (HProp.CanPickupNow): no grab while
    // still engaged with the vendor or mixing a potion, so a freshly thrown item
    // flies through Harry and is collected once he disengages, exactly like a
    // vanilla ingredient drop. bPickupOnTouch is set in defaults so this passes.
    if (!CanPickupNow(Other)) return;
    class'APVendorTokenFire'.static.FireAndConsume(self, CheckLocationId);
}

defaultproperties
{
    // Grant nulled: the vanilla purchase already paid out; the AP item arrives
    // over the wire.
    classStatusGroup=None
    classStatusItem=None
    // Pickup collision and bounce, mirrored from APContainerMarker. bBlockActors
    // False lets the swap Spawn clear the vendor cylinder; bBlockPlayers False lets
    // Harry overlap it so Touch fires; bBounceIntoPlace drops and settles it on the
    // floor. bCollideWorld stays True so it still lands.
    bPickupOnTouch=True
    bBlockActors=False
    bBlockPlayers=False
    bBlockCamera=False
    bCantStandOnMe=True
    CollisionRadius=8.00
    CollisionHeight=12.00
    bBounce=True
    bBounceIntoPlace=True
    soundBounce=Sound'HPSounds.Magic_sfx.bean_bounce'
    soundPickup=Sound'HPSounds.Magic_sfx.pickup_WC_bronze'
}

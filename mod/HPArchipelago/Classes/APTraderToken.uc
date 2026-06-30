// AP pickup token a Tradersanity vendor drops when sold: the swapped-in stand-in
// for the vanilla PotionIngredients the trade drops. Touch fires CHECK_LOCID the
// instant the player grabs it, instead of waiting for APVendorController's
// per-tick bDeleteMe poll.
//
// Extends PotionIngredients (not a plain HProp) so the TradersanityPass morph
// sweep still finds it via its `foreach AllActors(class'PotionIngredients')` after
// a hub re-entry, and so it bounces and rests exactly like the vanilla drop.
// APVendorController swaps it in and stamps CheckLocationId plus the AP item
// appearance. The grant fields are nulled so picking it up adds no ingredient; the
// AP item itself arrives over the wire, and the vanilla purchase already paid out.
class APTraderToken extends PotionIngredients;

var int CheckLocationId;

event Touch(Actor Other)
{
    if (harry(Other) == None) return;
    class'APVendorTokenFire'.static.FireAndConsume(self, CheckLocationId);
}

defaultproperties
{
    classStatusGroup=None
    classStatusItem=None
}

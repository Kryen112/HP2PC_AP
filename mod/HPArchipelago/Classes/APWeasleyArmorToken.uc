// AP pickup token for George's Quidditch Armour sale: the swapped-in stand-in for
// the thrown vanilla QArmor. Touch fires CHECK_LOCID the instant the player grabs
// it, instead of waiting for FireWeasleyCheck's per-tick bDeleteMe poll.
//
// Extends QArmor (not a plain HProp) so APVendorController's
// `foreach AllActors(class'QArmor')` still finds it after a hub re-entry and
// re-binds WeasleyToken[1]. Without that re-bind, FireWeasleyCheck's bPaidNoToken
// safety net would fire the check on re-entry while the token sits uncollected.
// Inherits the armour mesh, collision, and native bounce so the thrown arc and
// grab feel match vanilla. The grant is nulled (the vanilla purchase already gave
// the armour); the AP item arrives over the wire.
class APWeasleyArmorToken extends QArmor;

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

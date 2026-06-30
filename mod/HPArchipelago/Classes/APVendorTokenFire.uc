// Shared instant-check fire for the vendor pickup tokens (APTraderToken,
// APWeasleyBroomToken, APWeasleyArmorToken). Those three extend three different
// vanilla prop bases (PotionIngredients / VendorNimbusBroom / QArmor) so they
// cannot share an AP base class; this static helper holds the one Touch behaviour
// they share. Mirrors APContainerMarker.Touch: fire CHECK_LOCID once, dedupe via
// NonCardLocationChecked, play the AP pickup cue, then destroy.
//
// The grant on each token is already nulled (its defaults set classStatusItem to
// None), so there is no vanilla pickup to suppress here. APVendorController's
// per-tick bDeleteMe poll stays as the safety net: this fire sets the same latch,
// so whichever path reaches the location first wins and the other no-ops.
class APVendorTokenFire extends Object;

static function FireAndConsume(HProp token, int checkLocationId)
{
    local APIPCActor ipc;
    local int slot;

    if (token == None) return;
    if (checkLocationId <= 0) return;
    slot = class'APLocationRegistry'.static.SlotForApId(checkLocationId);
    if (slot < 0) return;

    if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1)
    {
        // Already credited (the poll beat us, or a stale duplicate token): remove
        // it so it is not an intangible ghost the player walks through.
        token.Destroy();
        return;
    }

    class'APCardWatcher'.default.NonCardLocationChecked[slot] = 1;
    Log("[Archipelago] APVendorTokenFire.FireAndConsume: firing CHECK_LOCID " $ checkLocationId);

    class'APStarsBase'.static.SpawnPickupBurst(token, token.Location);
    if (token.soundPickup != None)
    {
        token.PlaySound(token.soundPickup);
    }

    ipc = class'APIPCActor'.static.GetInstance();
    if (ipc != None)
    {
        ipc.SendCheckLocationId(checkLocationId);
    }

    token.Destroy();
}

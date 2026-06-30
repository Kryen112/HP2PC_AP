// AP-aware drop-in replacement for a vanilla ChallengeStar. Visually and
// behaviourally identical to vanilla; inherits mesh, glow, rotation, sound,
// and the entire PickupProp pickup pipeline (sound, fly-to-HUD, score). The
// only additions are:
//   - CheckLocationId carries the AP location id baked in at Spawn time.
//   - PickupProp.EndState calls Super.EndState() (vanilla score increment via
//     ChallengeScoreManager.PickedUpStar) THEN fires CHECK_LOCID.
//
// Lifecycle: APLevelSetup.ReplaceChallengeStars destroys each unchecked
// vanilla ChallengeStar at level entry and Spawns one of these in its place
// at the same Location/Rotation, stamped with the AP id from
// APLocationRegistry.GetStarLocationId. Already-AP-checked spots are left as
// vanilla stars on level replay: the player still gets score, the watcher
// fires no AP CHECK for them.
class APChallengeStarMarker extends ChallengeStar;

var int CheckLocationId;

state PickupProp
{
    function EndState()
    {
        local APIPCActor ipc;
        local int slot;

        Super.EndState();

        if (CheckLocationId <= 0) return;
        slot = class'APLocationRegistry'.static.SlotForApId(CheckLocationId);
        if (slot < 0) return;
        if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) return;

        class'APCardWatcher'.default.NonCardLocationChecked[slot] = 1;
        Log("[Archipelago] APChallengeStarMarker.EndState: firing CHECK_LOCID " $ CheckLocationId);

        ipc = class'APIPCActor'.static.GetInstance();
        if (ipc != None)
        {
            ipc.SendCheckLocationId(CheckLocationId);
        }
    }
}

// Appearance capability contract. CheckLocationId is a full AP location id
// (stamped by APLevelSetup.ReplaceChallengeStars after Spawn), so the
// resolvable id is that value directly. The watcher registers + best-effort
// applies right after stamping; RestampMarkerAppearance is the authoritative
// re-stamp.
function ApplyAPAppearance()
{
    if (CheckLocationId <= 0) return;
    class'APAppearanceMath'.static.ApplyAppearanceTo(self,
        class'APMorphRegistry'.static.AppearanceForApId(CheckLocationId));
}

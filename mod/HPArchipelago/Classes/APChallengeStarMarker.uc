// AP-aware drop-in replacement for a vanilla ChallengeStar. Visually and
// behaviourally identical to vanilla — inherits mesh, glow, rotation, sound,
// and the entire PickupProp pickup pipeline (sound, fly-to-HUD, score). The
// only additions are:
//   - CheckLocationId carries the AP location id baked in at Spawn time.
//   - PickupProp.EndState calls Super.EndState() (vanilla score increment via
//     ChallengeScoreManager.PickedUpStar) THEN fires CHECK_LOCID.
//
// Lifecycle: APCardWatcher.ReplaceChallengeStars destroys each unchecked
// vanilla ChallengeStar at level entry and Spawns one of these in its place
// at the same Location/Rotation, stamped with the AP id from
// APLocationRegistry.GetStarLocationId. Already-AP-checked spots are left as
// vanilla stars on level replay — the player still gets score, the watcher
// fires no AP CHECK for them.
class APChallengeStarMarker extends ChallengeStar;

// 5760000 = locations.yaml `base_id`. Duplicated here as a literal because UE1
// UScript const access across classes is awkward; the watcher's LOC_BASE
// const is the source of truth — keep these in sync.
const LOC_BASE = 5760000;

var int CheckLocationId;

state PickupProp
{
    function EndState()
    {
        local APIPCActor ipc;
        local int slot;

        Super.EndState();

        if (CheckLocationId <= 0) return;
        slot = CheckLocationId - LOC_BASE;
        if (slot < 0 || slot >= 700) return;
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

// #3 capability contract. CheckLocationId is a full AP location id (stamped by
// APCardWatcher.ReplaceChallengeStars AFTER Spawn), so the resolvable id is
// that value directly. The watcher registers + best-effort applies right
// after stamping; RestampMarkerAppearance is the authoritative re-stamp.
function ApplyAPAppearance()
{
    if (CheckLocationId <= 0) return;
    class'APCardWatcher'.static.ApplyAppearanceTo(self,
        class'APCardWatcher'.static.AppearanceForApId(CheckLocationId));
}

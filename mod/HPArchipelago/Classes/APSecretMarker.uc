// AP-aware drop-in replacement for a vanilla SecretAreaMarker. Inherits the
// entire vanilla "found" pipeline (bFound latch, the "Secret Area Found"
// message, the found music) via Super.OnFound; the only addition is an instant
// CHECK_LOCID the moment the area is entered, instead of waiting for
// APLocationScanner.ScanSecretMarkers' per-tick bFound poll.
//
// OnFound is the single hook both entry paths funnel through: SecretAreaMarker
// fires it from Touch (bUseCollision secrets the player walks into) and from
// Trigger (secrets armed by a separate trigger volume via the marker's Tag).
// Overriding it once covers both.
//
// Lifecycle: APLevelSetup.ReplaceSecretMarkers swaps this in for each registered,
// unfound, unchecked vanilla marker at Snapshot, baking the AP location id into
// LocationId. The poll stays as the safety net and reads LocationId straight off
// this subclass (the swapped actor's Name no longer matches the registry).
class APSecretMarker extends SecretAreaMarker;

// AP location id baked at swap time (a full 5760xxx id, not a card id).
var int LocationId;

function OnFound()
{
    local APIPCActor ipc;
    local int slot;

    // Vanilla feedback first: sets bFound, prints the message, plays the music.
    Super.OnFound();

    if (LocationId <= 0) return;
    slot = class'APLocationRegistry'.static.SlotForApId(LocationId);
    if (slot < 0) return;
    // Idempotent: a re-entry (bFound already True) skips Super's message but still
    // reaches here, and the poll may have fired first. The latch makes either win.
    if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) return;

    class'APCardWatcher'.default.NonCardLocationChecked[slot] = 1;
    Log("[Archipelago] APSecretMarker.OnFound: firing CHECK_LOCID " $ LocationId);

    ipc = class'APIPCActor'.static.GetInstance();
    if (ipc != None)
    {
        ipc.SendCheckLocationId(LocationId);
    }
}

// Open castle mode flag. The seed's "MODE open_castle" line latches it.
// Class-default + static so every level reads it with no live instance. A level
// loaded before the line arrives reads 0; APIPCActor applies that level's open
// castle edits when the line lands.
class APModeDetector extends Object;

// Mirrors APCardWatcher's spell-ledger width for the entry-time wipe below.
const NUM_SPELLS = 7;

// Sticky open-castle-mode flag: the mod's authoritative mode signal, read by
// APGameInfo gameplay logic, the in-game UI page, the IPC layer and the watcher.
// Set by the seed's mode line; persists for the session via class-default write
// and is never cleared (one-way). Drives the mode-specific bookcase / blocker
// logic in APGameInfo.
var byte bOpenCastleMode;

// One-way-sticky open-castle-mode transition. Static so the IPC layer can enter
// open castle mode without a live instance. On the FIRST transition it wipes the
// watcher's stale APGrantedSpell ledger so the open castle revert loop can't keep
// a prior vanilla seed's precollected Lumos/Flipendo/Alohomora; the AP client's
// durable resync re-sets the flag over IPC for spells THIS seed grants.
// Idempotent: a second call (already open castle) is a no-op, so reconnect /
// save-load that already has AP-granted spells does NOT re-wipe them.
// bOpenCastleMode is never cleared (one-way).
static function EnterOpenCastleMode(string reason)
{
    local int i;

    if (default.bOpenCastleMode == 1) return;
    default.bOpenCastleMode = 1;
    Log("[Archipelago] APModeDetector: entering open castle mode (sticky) - " $ reason);
    for (i = 0; i < NUM_SPELLS; i++)
    {
        class'APCardWatcher'.default.APGrantedSpell[i] = 0;
    }
    Log("[Archipelago] APModeDetector: reset APGrantedSpell[] (AP grants this session will re-set as they arrive)");
}

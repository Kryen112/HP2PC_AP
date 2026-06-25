// Open-castle mode detection and the install fingerprint. Owns the sticky
// class-default mode flag the whole mod reads, plus the separate signals a
// seed/install mismatch is derived from. All class-default + static so the
// pre-Harry / pre-IPC entry paths (APGameInfo.InitGame, APCardWatcher.
// PreBeginPlay, APIPCActor) can detect and latch the mode with no live instance.
class APModeDetector extends Object;

// Mirrors APCardWatcher's spell-ledger width for the entry-time wipe below.
const NUM_SPELLS = 7;

// Sticky open-castle-mode flag: the mod's authoritative mode signal, read by
// APGameInfo gameplay logic, the in-game UI page, the IPC layer and the watcher.
// Set once a detection path finds the open-castle install/seed; persists for the
// session via class-default write and is never cleared (one-way). Drives the
// mode-specific bookcase / blocker logic in APGameInfo.
var byte bOpenCastleMode;

// Seed/install mismatch sources. bOpenCastleMode is a sticky OR of two sources
// (the install's MGBingo probe AND the seed's "MODE open_castle" IPC line), so
// it cannot tell you what the INSTALL physically is once the IPC line has set it.
// These record the two sources separately so a mismatch is detectable:
//   bInstallProbed       1 once ProbeInstall has run the MGBingo DLO (so a 0
//                        result positively means "vanilla install", not "not yet
//                        checked"). Class-default sticky.
//   bInstallIsOpenCastle 1 iff the MGBingo package is present (the Bingo
//                        open-castle maps). Set only by the DLO probe, never by
//                        the IPC line. Class-default sticky.
//   SeedDeclaredMode     the seed's declared game_mode from the client's
//                        "MODE <mode>" line: 0 unknown / 1 vanilla / 2 open
//                        castle. Class-default sticky.
// APCardWatcher's Timer compares these and toasts on a mismatch.
var byte bInstallProbed;
var byte bInstallIsOpenCastle;
var byte SeedDeclaredMode;

// One-way-sticky open-castle-mode transition, shared by every entry path (durable
// DLO probe, in-level MGBingo actor scan, IPC `MODE open_castle`). Static so the
// pre-Harry / pre-IPC callers can enter open castle mode without a live instance.
// On the FIRST transition it wipes the watcher's stale APGrantedSpell ledger so
// the open castle revert loop can't keep a prior vanilla-seed's precollected
// Lumos/Flipendo/Alohomora; the AP client's durable resync re-sets the flag over
// IPC for spells THIS seed grants. Idempotent: a second call (already open
// castle) is a no-op, so reconnect / save-load that already has AP-granted spells
// does NOT re-wipe them. bOpenCastleMode is never cleared (one-way).
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

// Durable, level-independent open castle probe. The HP2 Bingo install is the only
// one that ships the MGBingo package; a soft DynamicLoadObject (MayFail=true, so
// no error and no hard reference that would block HPArchipelago.u loading on
// vanilla) returns non-None there and None on the vanilla/Modded install. Works
// pre-Harry / pre-IPC and on a cold load into a sentinel-less level (e.g.
// Ch7Gryffindor) where the in-level actor scan misses. Self-latching: runs the
// DLO once, then records the result in class-defaults that survive every level.
// Distinct from EnterOpenCastleMode so the install signal stays separable from
// the seed's "MODE open_castle" IPC line (which also sets bOpenCastleMode).
static function ProbeInstall()
{
    if (default.bInstallProbed == 1) return;
    default.bInstallProbed = 1;
    if (DynamicLoadObject("MGBingo.MGBingoLearnAllSpells", class'Class', true) != None)
    {
        default.bInstallIsOpenCastle = 1;
        Log("[Archipelago] APModeDetector.ProbeInstall: install is open castle (MGBingo present)");
    }
    else
    {
        Log("[Archipelago] APModeDetector.ProbeInstall: install is vanilla (MGBingo absent)");
    }
}

// Record the seed's declared game_mode from the client's "MODE <mode>" line.
// Positive in both modes (1 vanilla / 2 open castle) so Timer can compare it
// against ProbeInstall's result. Does NOT touch bOpenCastleMode: the caller
// latches that separately for "open_castle" only.
static function SetSeedDeclaredMode(string mode)
{
    if (mode == "open_castle") default.SeedDeclaredMode = 2;
    else if (mode == "vanilla") default.SeedDeclaredMode = 1;
}

static function EnsureOpenCastleModeDetected()
{
    // Always probe the install first, even when bOpenCastleMode is already 1
    // (e.g. the seed's IPC line set it on a vanilla install): the mismatch check
    // still needs the separate install signal recorded.
    ProbeInstall();
    if (default.bOpenCastleMode == 1) return;
    if (default.bInstallIsOpenCastle == 1)
    {
        EnterOpenCastleMode("DLO MGBingo package present");
    }
}

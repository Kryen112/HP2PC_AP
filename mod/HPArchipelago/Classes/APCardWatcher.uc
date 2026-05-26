class APCardWatcher extends Actor;

const MAX_CARD_ID = 101;
const NUM_SPELLS = 7;
const NUM_KEY_ITEMS = 3;
const NUM_BLOCKER_KEYS = 14;

// Story state when the player first gains control in the Great Hall after
// the opening sequence — the checkpoint where vanilla assigns silver wizard
// cards to vendors, reached in both vanilla and open castle. The one-time startup
// safety save fires at the first playable tick at or after this state.
const STARTUP_SAFETY_SAVE_GAMESTATE = 180;

// AP location base id (locations.yaml `base_id`). Used to index
// NonCardLocationChecked[] by `apId - LOC_BASE` for secrets/stars/etc.
// Mirrors `BASE_ID` in apworld/locations.py.
const LOC_BASE = 5760000;
// Window size for the non-card-location dedupe array and every `slot` guard
// below. Mirrors `NONCARD_LOC_WINDOW` in gen_apworld.py — the two MUST hold
// the same value; gen_apworld.py fails generation if any non-card location
// id_offset >= this. Sized generously to cover every band with headroom.
const NONCARD_LOC_WINDOW = 1024;
// Class-default dedup for non-card AP locations (secrets, stars, vendors,
// duels, matches, level completions). Indexed by `apId - LOC_BASE`.
// Class-default so it persists across level transitions in a session, like
// LocationChecked[]. The dimension literal MUST equal NONCARD_LOC_WINDOW:
// M212 UnrealScript array dimensions take an integer literal, not a const
// (no vanilla array in the decompiled retail source uses a const/enum dim),
// so the constant cannot be referenced here directly.
var byte NonCardLocationChecked[1024];

// #3 marker-appearance subsystem. Per-AP-location appearance code, indexed by
// `apId - LOC_BASE` exactly like NonCardLocationChecked[] (same dedupe-window
// math, same cross-level class-default persistence). Values: 0 = leave the
// marker's native vanilla look (also the async-safe default until the table
// arrives); 1..101 = HP2 card (value is the game card id); 1000+spellIdx =
// HP2 spell (wand-target gesture art on the card mesh); 2001..2011 = HP2
// filler; 3001..3002 = HP2 equipment (Nimbus / Quidditch Armour); 3003 = HP2
// open castle level/challenge key (the vanilla silver-key FX sprite); 9000 = foreign
// filler/useful (AP-logo plain); 9001 = foreign progression/trap (AP-logo
// arrow). Dimension literal MUST equal NONCARD_LOC_WINDOW (M212 array dims
// take an integer literal, not a const — see NonCardLocationChecked[] above).
var int AppearanceCode[1024];
// Set once SetAppearanceCSV has ingested a table this process. The sweep and
// every marker self-apply early-return until then so a pre-table marker keeps
// its native look instead of going blank.
var byte bAppearanceReceived;
// Per-level (instance) one-shot guard so Timer() runs the convergence sweep
// exactly once after the table is present in a given level; resets with each
// fresh per-level watcher instance.
var byte bAppearanceRestampedThisLevel;

// Morphable-marker registry (the #3 capability contract). A marker opts in by
// calling RegisterMorphMarker(self, apId) on the live per-level watcher when
// its AP location id is known (cards in PostBeginPlay; stars/vendors right
// after the watcher stamps their CheckLocationId). The sweep applies the table
// generically via ApplyAppearanceTo(Actor,code) — which only touches
// Actor-level draw fields — so NO marker class is named here and a future
// check marker (Tradersanity's APVendorMarker_Trader, etc.) opts in with the
// same one call, no watcher edit.
//
// INSTANCE state, NOT class-default. A class-default array of Actor refs is a
// fatal M212 hazard: the class default object outlives every level, so on
// level cleanup ULevel::CleanupDestroyed walks the persistent ObjectProperty
// array and asserts (Obj->IsValid) on a freed marker from the torn-down level
// — the chest FancySpawn (18 copies) + pickup-Destroy pattern guarantees stale
// slots. As instance state it dies with the per-level watcher; markers
// re-register into each level's fresh watcher, with the PostBeginPlay
// self-apply as the independent safety net since AppearanceCode[] IS
// class-default (only Object refs are unsafe there). MORPH_REGISTRY_SIZE is
// generous: a level holds at most a handful of card chests + the chest
// FancySpawn burst + ≤6 stars + 2 vendors.
const MORPH_REGISTRY_SIZE = 256;
var Actor MorphActor[256];
var int   MorphApId[256];

// --- Tradersanity ------------------------------------------------------------
// Price mode from the apworld slot_data, pushed via the TRADECFG IPC line
// (mirrors GOALCFG / bOpenCastleMode). Class-default so it survives level
// transitions in a session; resent every HELLO so it is sticky. Values mirror
// the apworld Tradersanity Choice.
const TRADER_OFF           = 0;
const TRADER_PRICE_VANILLA = 1;
const TRADER_PRICE_RANDOM  = 2;
const TRADER_PRICE_LOW     = 3;
var int TradersanityMode;
// Price constants for the non-vanilla modes (retune freely). price_low clamps
// to a flat value; price_random blends a per-vendor factor (TraderRolledFactor
// below) across [LO, HI]; price_vanilla on a card vendor blends the SAME
// factor across the vendor's own [min,max], so an ingredient vendor in
// price_vanilla mode keeps its single snapshotted price.
const TRADER_PRICE_LOW_BEANS  = 10;
const TRADER_PRICE_RAND_LO    = 10;
const TRADER_PRICE_RAND_HI    = 250;
// Per-Tradersanity-location price factor (byte 0..255) pre-rolled in the
// apworld from the seeded RNG and shipped via the "TRADERPRICES" IPC line.
// Class-default class-array keyed by `apId - LOC_BASE` (parallels
// NonCardLocationChecked[] / AppearanceCode[] — same dedupe-window math).
// Sticky for the seed: resent every HELLO, so the rolled price for a vendor
// survives both level transitions (class-default carries cross-level in
// session) and save/exit (re-armed from slot_data on the next HELLO).
// Replaces a per-level RandRange that re-rolled on every hub re-entry.
// Dimension MUST be the integer literal 1024 (== NONCARD_LOC_WINDOW); M212
// array dims take an integer literal, not a const.
var byte TraderRolledFactor[1024];
// A freshly-sold item spawns within ~CollisionRadius+10 of its vendor and is
// caught within ≤0.25s, so it is always far nearer its own vendor than the
// closest neighbouring vendor (census min separation ≈ 210uu). Match the
// NEAREST eligible unchecked Tradersanity vendor within this cap.
const TRADER_MATCH_RADIUS = 256.0;
// Per-level Tradersanity registry. INSTANCE, not class-default: holds
// Characters refs and the per-level watcher is torn down the safe same-level
// way (see MorphActor[]). A level holds ≤6 eligible vendors; 16 is generous.
//
// Card vendors are turned INTO ingredient vendors while their check is
// pending: HP2 card-vendor stock is tier-global and MakePurchase spawns a
// real card (cardsanity cross-fire), but ingredient stock (nCurrIngrCount)
// is PER-VENDOR and MakePurchase spawns a plain prop. So a Tradersanity card
// vendor gets CharacterSells := Sells_WBark while pending; the existing
// ingredient swap path handles it; on collection CharacterSells is restored
// and it is a vanilla card vendor again.
//   TraderOrigSells   SELLS_* from the GENERATED registry (not the mutated
//                     actor) so card-vendor restore survives save/load.
//   TraderSavedLo/Hi  original sale-price range (card: min/max; ingredient:
//                     the single price twice) for price_vanilla / revert.
//   TraderApplied     price mode applied this visit (once).
//   TraderRestored    post-collect cleanup (price + CharacterSells) done.
//   TraderDispensed   the sold prop has been morphed + claimed as this
//                     vendor's AP pickup token (check fires on its pickup);
//                     resets with the per-level watcher so an uncollected
//                     check re-arms on re-entry.
//   TraderToken       the morphed PotionIngredients prop acting as the AP
//                     pickup; when it goes None/bDeleteMe (picked up or
//                     unloaded) the check fires. Instance storage only —
//                     actor refs in class-default crash level cleanup.
//   TraderWait        ticks spent sold-but-untokenised; a safety counter so
//                     a prop grabbed before we could morph it can't stick.
//   TraderSavedIngr   the vendor's vanilla nCurrIngrCount at registration,
//                     restored on revert so a genuine ingredient vendor
//                     restocks immediately instead of sitting at the pinned
//                     zero until a game-state change / hub reload.
const TRADER_REG_SIZE = 16;
// Sold-but-no-token ticks before the check fires anyway (the prop was picked
// up before the morph pass saw it, or never appeared). The morph pass below
// the vendor sweep normally claims the prop the same tick the sale lands, so
// this only trips in the rare instant-grab race.
const TRADER_PICKUP_WAIT_TICKS = 20;
var Characters TraderVendor[16];
var int  TraderOrigSells[16];
var int  TraderSavedLo[16];
var int  TraderSavedHi[16];
var byte TraderApplied[16];
var byte TraderRestored[16];
var byte TraderDispensed[16];
var Actor TraderToken[16];
var byte TraderWait[16];
var int  TraderSavedIngr[16];
// AP location id of the Tradersanity vendor whose dialogue was engaged at
// the last poll. 0 = no engagement. Rising-edge discriminator for the
// VENDOR_OPENED IPC so a held-open dialogue fires the hint exactly once
// per engagement; the client dedupes again per-seed in Data Storage.
var int TraderHintLastEngagedLocId;
// Characters.ESells ordinal values (stable in the decompiled retail enum).
// Used only to record/branch a vendor's ORIGINAL sell type from the
// registry; live vendor comparisons still use the c.ESells.Sells_* idiom.
const SELLS_WBARK  = 2;
const SELLS_FMUCUS = 3;
const SELLS_BRONZE = 4;
const SELLS_SILVER = 5;

var harry HarryRef;
var StatusItemWizardCards siBronze;
var StatusItemWizardCards siSilver;
var StatusItemWizardCards siGold;
var byte WasOwnedByHarry[102];
var bool bSnapshotted;
var int LastBronzeCount;
var int LastSilverCount;
var int LastGoldCount;
var int HeartbeatCounter;
var int LastGameState;

var class<baseSpell> SpellClasses[7];
var string SpellNames[7];
var byte WasSpellOwned[7];
var byte APGrantedSpell[7];
// Lesson-start hook dedupe. Mirrors LocationChecked[] but for the 4 spell-
// tutorial locations. Separate from WasSpellOwned[] because Snapshot baselines
// WasSpellOwned=1 for spells Harry already has at watcher init (so the
// IsInSpellBook revert loop doesn't fire on a legitimately-AP-granted spell);
// the lesson-start hook needs to fire even when Harry already has the spell.
// Class-default so it persists across watcher instances within a session.
var byte LessonCheckFired[7];

// Spell-cast chat flavor. LastSeenCastedSpell holds the
// baseWand.LastCastedSpell reference observed last tick; its identity
// changing is the "≥1 new cast happened" signal. PLAIN per-level instance
// var (NOT class-default/travel) — re-spawned each level like the
// WasSpellOwned baseline, so a harmless one-time re-trigger after load is
// acceptable. NextSpellSayEarliest is the Level.TimeSeconds anti-flood
// floor; SaySpellChance is the per-detected-cast roll (defaultproperties).
var baseSpell LastSeenCastedSpell;
var float NextSpellSayEarliest;
var float SaySpellChance;

var StatusItem KeyItemStatus[3];
var string KeyItemNames[3];
var byte WasKeyItemOwned[3];
var byte APGrantedKeyItem[3];

// Per-watcher latches for challenge-completion detection (LevelObjectiveIndexFor
// idx 7-11 — Ch1Rictusempra / Ch2Skurge / Ch3Diffindo / Ch4Spongify /
// Ch7Gryffindor). bSawFinalStarThisLevel rises once an alive FinalStar is
// observed in-level; bAwardedFinalStarThisLevel latches the credit so a
// same-tick disappearance can't double-fire. Reset implicitly per level
// because the watcher is per-level. See ScanFinalStarCompletion.
var byte bSawFinalStarThisLevel;
var byte bAwardedFinalStarThisLevel;

// Bookcase-blocker keys. 14 progression items, each gating one or more
// bookcases the mod spawns in the hub levels (Entryhall_hub / Grandstaircase_hub
// / Grounds_hub + Grounds_Night). Used in BOTH game modes: open castle puts all
// 14 in the AP pool, vanilla puts the 7 in VANILLA_BLOCKED_KEY_NAMES in the
// pool (cumulative chain + Duelling/Quidditch standalone) and precollects the
// rest. APGrantedBlockerKey[i]==1 means the matching key has been delivered by
// AP — the BlockOpenCastle<X>EntryIfMissing helpers early-return when their
// flag is set, and RemoveOpenCastle<X>Blocker tag-scans the level to destroy
// any still-present bookcase. Class-default writes via MarkBlockerKeyAsAPGranted-
// Default keep the flag sticky across save/load and across the per-level watcher
// instance lifecycle. Index → name mapping in BlockerKeyNames[] below; new
// entries here must mirror items.yaml blocker_keys.
// Dimension literal MUST be the integer 14, not NUM_BLOCKER_KEYS (M212 array
// dims take an integer literal, not a const) — keep in sync with the const.
var string BlockerKeyNames[14];
var byte APGrantedBlockerKey[14];

// M7 goal detection: 1 once GOAL_COMPLETE has fired this session. Class-default
// so it survives level transitions (the credits flow stays in the same level
// instance; class-default is the defensive belt).
var byte WasInEndGame;

var APCardWatcher LatestInstance;

// Class-default array. Survives level transitions in a session (default vars are
// process-wide). APCardMarker.Touch sets LocationChecked[id]=1 after firing its
// CHECK; APCardMarker.PostBeginPlay self-destroys if its id is already checked.
var byte LocationChecked[102];

// Class-default tracking of which WCn curtain events DropOwnedGoldCardCurtains
// has fired this session. The Ch6WizardCard curtain movers are
// InitialState=TriggerToggle and HP2 preserves mover keyframe state across
// level exits within a session, so refiring a TriggerEvent('WCn') on
// re-entry toggles the mover BACK to closed. Tracking once-fired-per-session
// here keeps each curtain stably open after the first fire. On a fresh game
// launch this resets to all zeros, so if the save preserved the mover position
// as open from a prior session, the first re-entry toggles it back to closed
// once before stabilising — a known edge case.
var byte WCnFiredThisSession[12];

// Sticky open-castle-mode flag. Set once Snapshot finds an MGBingoLearnAllSpells
// actor in any level; persists for the rest of the session via class-default
// write. Snapshot never baselines vanilla-engine grants (harry.uc:335-337
// Flipendo/Lumos/Alohomora; MGBingo's open castle R/Sk/D/Sp) as AP-granted in
// either mode — AP must deliver every spell the user marked in starting_spells.
// The flag still drives mode-specific bookcase / blocker logic in APGameInfo.
var byte bOpenCastleMode;

// Seed/install mismatch detection. bOpenCastleMode is a sticky OR of two
// sources (the install's MGBingo probe AND the seed's "MODE open_castle" IPC
// line), so it can't tell you what the INSTALL physically is once the IPC line
// has set it. These three record the two sources separately so a mismatch is
// detectable:
//   bInstallProbed       — 1 once ProbeInstall has run the MGBingo DLO (so a
//                          0 result positively means "vanilla install", not
//                          "not yet checked"). Class-default sticky.
//   bInstallIsOpenCastle — 1 iff the MGBingo package is present (the Bingo
//                          open-castle maps). Set only by the DLO probe, never
//                          by the IPC line. Class-default sticky.
//   SeedDeclaredMode     — the seed's declared game_mode from the client's
//                          "MODE <mode>" line: 0 unknown / 1 vanilla / 2 open
//                          castle. Class-default sticky.
// Timer() compares them and toasts on a mismatch. The shown-latch
// (bModeMismatchToastShown) is a plain INSTANCE var, NOT a class default, so it
// re-arms on each per-level watcher respawn — the warning re-shows every level
// until the player fixes the install.
var byte bInstallProbed;
var byte bInstallIsOpenCastle;
var byte SeedDeclaredMode;
var byte bModeMismatchToastShown;

// Durable resync handshake. Set by ApplyResyncSpells the first time the client
// delivers the AP-Data-Storage spell ledger ("RESYNC_SPELLS <csv>") — at which
// point default.APGrantedSpell[] reflects every spell this slot has ever
// received from AP. The revert loop gates its wipe branch on this flag so a
// fresh process / save-load can never wipe AP-granted spells before the client
// has had a chance to re-assert them. Sticky for the lifetime of the process
// (never cleared); a reconnect / late client launch re-arms it on arrival.
var byte bResyncReceived;

// Open castle Great Hall key config. Delivered once per process by the client as
// "GOALCFG c,s,l,d,q,mask" (from apworld slot_data) → SetGoalConfigCSV writes
// these class-defaults; sticky across level transitions / save-load like
// bOpenCastleMode and APGrantedBlockerKey. GoalSatisfied() (Phase 2) reads them; the
// Great Hall bookcase (Phase 3) clears when every enabled clause passes. A
// clause of 0 / off drops out of the AND (apworld already applied the
// all-off → all-spells fallback, so this is never a no-gate config in open castle).
var byte bGoalConfigured;
var int  GoalCards;
var int  GoalSpells;
var int  GoalLevels;
// Int (not byte) so the int return of NextCsvInt assigns without a coercion
// question; only ever 0/1.
var int  GoalDuels;
var int  GoalQuidditch;
var int  GoalLevelMask;
// Clause-3 objective bitset (11 objectives), set by the
// Phase-4 detectors. Class-default sticky.
var byte GoalLevelDone[16];
// One-shot: set when the clauses are first all satisfied. Gates the Great
// Hall bookcase removal AND the bInEndGame GOAL_COMPLETE fire in open castle.
var byte WasGoalUnlocked;
// Caps'd name of the adventure level abandoned via the Return-to-Hub menu
// (stamped by APFEInGamePage.TeleportToHub). CheckExitedLevelObjective uses
// it to tell a menu-bail apart from a real Mechanism-C completion; cleared on
// any bind back inside a Mechanism-C level (a fresh attempt supersedes a bail).
var string MenuReturnFromLevelCaps;
// Caps'd name of the level Harry was in when he entered stateDead (stamped by
// ScanDeathLink, organic OR induced DeathLink). HP2's death penalty is
// LoadGame 0, which reloads the autosave and so travels OUT of the level —
// CheckExitedLevelObjective uses this to tell a death-reload apart from a real
// completion (same role as MenuReturnFromLevelCaps for the Return-to-Hub bail).
var string DeathExitFromLevelCaps;
// Caps'd name of the level the watcher was last bound in. Mechanism-C credits
// off OUR own per-level bind history, NOT harry.PreviousLevelName: the return
// SmartStart auto-saves, and harry.PreSaveGame wipes PreviousLevelName before
// Snapshot ever runs. Class-default sticky.
var string LastBoundLevelCaps;

// Per-spell flag for the in-progress-lesson detection. Set to 1 each tick the
// watcher sees `HarryRef.CurrSpellLesson` resolve to a known lesson shape; on
// the next tick where `CurrSpellLesson` is None, the flag's spell index fires
// CHECK_SPELL and the flag clears. Class-default so the transition survives
// the level change between EndLesson() and the auto-teleport to the
// matching challenge level (vanilla EndLesson clears CurrSpellLesson, then
// TriggerEvent likely fires the teleport on the same frame — the new
// watcher in the challenge level still observes the cleared flag and the
// stamped InLessonForSpell entry, and fires the check there).
var byte InLessonForSpell[7];

// "Connected to host:port" startup toast. ConnectedAddress is the AP server
// address the Python client resolved (scheme stripped), delivered via the
// sticky CONNECTED IPC line on AP Connected and re-sent every HELLO — same
// class-default + sticky convention as GOALCFG / TRADECFG. Empty until the
// client is AP-connected. bConnToastShown is the fire latch: armed (0) at
// process start (class-defaults are compiled, never from .usa), set to 1 once
// the toast has fired so an area/level transition can't re-toast, and re-armed
// (0) on a save-load so it shows again.
//
// Fire is delayed ~1s after the first playable tick the address is known so
// it doesn't pop the instant control returns: the first eligible tick sets
// bConnToastScheduled=1 / ConnToastTicksLeft=CONN_TOAST_DELAY_TICKS, then each
// watcher tick decrements until it fires. Tick-counted, not Level.TimeSeconds-
// stamped, so it survives the per-level watcher respawn and the per-level
// clock reset if a transition lands inside the window.
//
// Save-load re-arm is owned by EnsureFreshToast: a save-load is the only
// source of a stale cross-package toast, so the tick it replaces one is
// exactly a save-load and it clears bConnToastShown there.
// Watcher Timer is SetTimer(0.25, true), so 4 ticks ≈ 1.0s.
const CONN_TOAST_DELAY_TICKS = 4;
var string ConnectedAddress;
var byte bConnToastShown;
var byte bConnToastScheduled;
var int ConnToastTicksLeft;

// --- Archipelago trap lifetime state (05-trap-items.md §8) ---------------
// All class-default + sticky like bOpenCastleMode / APGrantedSpell: the backup
// and flags MUST survive the per-level watcher respawn and save-load, or a
// cleared spellbook would travel to the next level with no way to restore
// it. APGameInfo.TryApplyTrap sets these via the static helpers below;
// TrapTick() (called from Timer) terminates them.
//
// Forgetfulness Trap: SpellTrapBackup holds harry.SpellBook[0..31] (the
// engine array is class<baseSpell> SpellBook[32], harry.uc:156). bSpell-
// TrapActive==1 while spells are withheld; restored when Level.TimeSeconds
// reaches SpellTrapExpiry OR the level changes, whichever comes first, so
// spells are never permanently lost.
const SPELL_TRAP_DURATION = 30.0;
var byte bSpellTrapActive;
var float SpellTrapExpiry;
var class<baseSpell> SpellTrapBackup[32];
// Goyle Transformation Trap: the pawn reverts naturally on the next level's
// fresh (bIsGoyle=false) pawn; this sticky just records the active state and
// is cleared on the level change so it stays accurate.
var byte bGoyleTrapActive;
// Level the watcher last observed (Level.Outer.Name). A trap helper stamps
// the apply-level here; TrapTick compares each tick and treats any change as
// the "left the level" boundary that ends the Goyle/spell traps. Level NAME
// (not watcher instance) is the discriminator so open castle's streamed-sublevel
// watcher churn never false-triggers.
var name TrapLastLevelName;

// --- DeathLink state. All class-default + sticky: an induced kill runs
// GotoState('stateDead') → ConsoleCommand("LoadGame 0"), which destroys the
// current Harry + watcher and spawns fresh ones, so an instance var would not
// survive the reload. ----------------------------------------------------
// Rising-edge latch for the outgoing detector: 1 while Harry is in stateDead
// so a death broadcasts exactly once; cleared when Harry is alive again
// (post-reload PlayerWalking), which re-arms the edge.
var byte bWasDead;
// One-shot deterministic loop-prevention: set at incoming-kill time so the
// outgoing edge detector consumes it and does NOT rebroadcast the induced
// death back to the room.
var byte bSuppressNextDeathBroadcast;
// Inbound linked death awaiting application. Set by SetPendingDeathLink (the
// IPC DEATHLINK line); ScanDeathLink consumes it once Harry is playable, or
// holds it across a cutscene/menu/load until control returns.
var byte bPendingDeathLink;
// Latch-timeout insurance: ticks left before bSuppressNextDeathBroadcast
// auto-clears when no stateDead was observed, so a missed GotoState cannot
// wrongly suppress a later natural death. 0 = disarmed. ~10s at 0.25s/tick.
var int DeathSuppressTicksLeft;
const DEATH_SUPPRESS_TIMEOUT_TICKS = 40;

static function APCardWatcher GetLatest()
{
    if (default.LatestInstance != None && !default.LatestInstance.bDeleteMe)
    {
        return default.LatestInstance;
    }
    return None;
}

function MarkAsGranted(int id)
{
    if (id >= 0 && id <= MAX_CARD_ID)
    {
        WasOwnedByHarry[id] = 1;
        Log("[Archipelago] APCardWatcher.MarkAsGranted: id=" $ id $ " (suppresses vanilla-revert + CHECK echo)");
    }
}

function MarkSpellAsGranted(string SpellName)
{
    local int i;
    for (i = 0; i < NUM_SPELLS; i++)
    {
        if (SpellNames[i] == SpellName)
        {
            APGrantedSpell[i] = 1;
            WasSpellOwned[i] = 1;
            // Mirror to class default so the flag survives level transitions —
            // each level spawns a fresh watcher with zeroed instance arrays,
            // and APGameInfo.InitGame reads this value before Snapshot has run.
            default.APGrantedSpell[i] = 1;
            Log("[Archipelago] APCardWatcher.MarkSpellAsGranted: " $ SpellName);
            return;
        }
    }
}

function MarkKeyItemAsGranted(string KeyItemName)
{
    local int i;
    for (i = 0; i < NUM_KEY_ITEMS; i++)
    {
        if (KeyItemNames[i] == KeyItemName)
        {
            APGrantedKeyItem[i] = 1;
            WasKeyItemOwned[i] = 1;
            default.APGrantedKeyItem[i] = 1;
            Log("[Archipelago] APCardWatcher.MarkKeyItemAsGranted: " $ KeyItemName);
            return;
        }
    }
}

// True if Harry's ingredient-i StatusItem nCount is >0. Only reliable for
// Boomslang(0) (a working PotionIngredients pickup); it gives an early
// in-level fire there. Bicorn(1) and BitOGoyle(2) never raise nCount in this
// build (broken Adv3DungeonQuest Bicorn prop / orphaned StatusItemBitOGoyle,
// §12 #16/#17) - they are credited by leaving their terminal level instead
// (CheckExitedLevelObjective). Kept as a fast-path; the exit detector is the
// robust source of truth for all three.
function bool HasKeyItem(int i)
{
    return KeyItemStatus[i] != None && KeyItemStatus[i].nCount > 0;
}

// Phase A of vendor support: clear vendor ownership of an AP-checked card
// location. Without this, vanilla `AssignVendorCards` (run from
// `harry.CopyCardStatusFromManagerToHarry` on every save / level transition,
// plus `AssignAllSilverToVendors` at iGameState >= 180) re-assigns AP-checked
// cards to vendors because our markers never set Harry-owned ownership.
// Vendors then offer them for sale — wasting beans for a duplicate CHECK that
// AP dedupes. Cleared cards are CardOwner_None, which `GetFirstVendorCardId`
// skips. Called from APCardMarker.Touch (per-pickup) and from the watcher's
// fallback polling path (if a vanilla wci pickup slipped past Phase B).
function ClearVendorOwnershipForLocation(int id)
{
    if (id <= 0 || id > MAX_CARD_ID) return;
    if (siBronze != None && siBronze.GetCardOwner(id) == siBronze.ECardOwner.CardOwner_Vendor)
    {
        siBronze.SetCardOwner(id, siBronze.ECardOwner.CardOwner_None);
        Log("[Archipelago] APCardWatcher.ClearVendorOwnership: Bronze[" $ id $ "] vendor -> none (location AP-checked)");
        return;
    }
    if (siSilver != None && siSilver.GetCardOwner(id) == siSilver.ECardOwner.CardOwner_Vendor)
    {
        siSilver.SetCardOwner(id, siSilver.ECardOwner.CardOwner_None);
        Log("[Archipelago] APCardWatcher.ClearVendorOwnership: Silver[" $ id $ "] vendor -> none (location AP-checked)");
        return;
    }
    if (siGold != None && siGold.GetCardOwner(id) == siGold.ECardOwner.CardOwner_Vendor)
    {
        siGold.SetCardOwner(id, siGold.ECardOwner.CardOwner_None);
        Log("[Archipelago] APCardWatcher.ClearVendorOwnership: Gold[" $ id $ "] vendor -> none (location AP-checked)");
        return;
    }
}

// Snapshot-time / rebind sweep: walk every AP-checked location and clear any
// vendor ownership that vanilla just stamped during save load or level
// transition. This catches the case where the player was mid-game with N
// AP-checked cards, transitioned levels (vanilla AssignVendorCards re-assigned
// them all), and the new level's watcher needs to undo that.
function SweepVendorAssignments()
{
    local int id, cleared;
    cleared = 0;
    for (id = 1; id <= MAX_CARD_ID; id++)
    {
        if (default.LocationChecked[id] == 1)
        {
            ClearVendorOwnershipForLocation(id);
            cleared++;
        }
    }
    if (cleared > 0)
    {
        Log("[Archipelago] APCardWatcher.SweepVendorAssignments: re-asserted CardOwner_None on " $ cleared $ " AP-checked location(s)");
    }
}

// Open castle only: every wizard card is an AP location reachable by replaying its
// (infinitely repeatable) level, so no card should ever sit in vendor stock.
// Vanilla `AssignVendorCards` / `AssignAllSilverToVendors` still stamp
// CardOwner_Vendor on level transition / iGameState >= 180; undo it for every
// id. CardOwner_None is what `GetFirstVendorCardId` skips, so the vendor has
// nothing to offer.
function ClearAllVendorOwnership()
{
    local int id, cleared;
    cleared = 0;
    for (id = 1; id <= MAX_CARD_ID; id++)
    {
        if (siBronze != None && siBronze.GetCardOwner(id) == siBronze.ECardOwner.CardOwner_Vendor)
        {
            siBronze.SetCardOwner(id, siBronze.ECardOwner.CardOwner_None);
            cleared++;
        }
        if (siSilver != None && siSilver.GetCardOwner(id) == siSilver.ECardOwner.CardOwner_Vendor)
        {
            siSilver.SetCardOwner(id, siSilver.ECardOwner.CardOwner_None);
            cleared++;
        }
        if (siGold != None && siGold.GetCardOwner(id) == siGold.ECardOwner.CardOwner_Vendor)
        {
            siGold.SetCardOwner(id, siGold.ECardOwner.CardOwner_None);
            cleared++;
        }
    }
    if (cleared > 0)
    {
        Log("[Archipelago] APCardWatcher.ClearAllVendorOwnership: cleared " $ cleared $ " card(s) from vendor stock (open castle: every card is a replayable AP location)");
    }
}

function RevertVanillaPickup(int id)
{
    if (siBronze != None && siBronze.IsOwnedByHarry(id))
    {
        siBronze.SetCardOwner(id, siBronze.ECardOwner.CardOwner_None);
        Log("[Archipelago] APCardWatcher.RevertVanillaPickup: cleared Bronze[" $ id $ "]");
        return;
    }
    if (siSilver != None && siSilver.IsOwnedByHarry(id))
    {
        siSilver.SetCardOwner(id, siSilver.ECardOwner.CardOwner_None);
        Log("[Archipelago] APCardWatcher.RevertVanillaPickup: cleared Silver[" $ id $ "]");
        return;
    }
    if (siGold != None && siGold.IsOwnedByHarry(id))
    {
        siGold.SetCardOwner(id, siGold.ECardOwner.CardOwner_None);
        Log("[Archipelago] APCardWatcher.RevertVanillaPickup: cleared Gold[" $ id $ "]");
        return;
    }
}

event PreBeginPlay()
{
    local int i;
    Super.PreBeginPlay();
    Log("[Archipelago] APCardWatcher.PreBeginPlay - starting timer (Level=" $ string(Level)
        $ " Level.Outer.Name=" $ string(Level.Outer.Name) $ ")");
    default.LatestInstance = self;
    SetTimer(0.25, true);

    // Durable open castle detection BEFORE the default->instance copy loops below,
    // so on the HP2 Bingo install they see the wiped default.APGrantedSpell[].
    // Works on the save-load path (ProcessServerTravel skips InitGame) since
    // it needs no instance/level/IPC.
    class'APCardWatcher'.static.EnsureOpenCastleModeDetected();

    SpellClasses[0] = class'spellAlohomora';   SpellNames[0] = "Alohomora";
    SpellClasses[1] = class'spellDiffindo';    SpellNames[1] = "Diffindo";
    SpellClasses[2] = class'spellFlipendo';    SpellNames[2] = "Flipendo";
    SpellClasses[3] = class'spellLumos';       SpellNames[3] = "Lumos";
    SpellClasses[4] = class'spellRictusempra'; SpellNames[4] = "Rictusempra";
    SpellClasses[5] = class'spellSkurge';      SpellNames[5] = "Skurge";
    SpellClasses[6] = class'spellSpongify';    SpellNames[6] = "Spongify";

    KeyItemNames[0] = "Boomslang";
    KeyItemNames[1] = "Bicorn";
    KeyItemNames[2] = "BitOGoyle";

    // Bookcase-blocker keys (shared by open castle and vanilla). Order matters
    // — APGrantedBlockerKey[] is indexed by this. Keep in sync with items.yaml
    // blocker_keys section and with TryApplyBlockerKey / RemoveOpenCastle<X>Blocker
    // dispatch in APGameInfo.
    BlockerKeyNames[0]  = "Chamber of Secrets Key";
    BlockerKeyNames[1]  = "Spongify Challenge Key";
    BlockerKeyNames[2]  = "Skurge Challenge Key";
    BlockerKeyNames[3]  = "Rictusempra Challenge Key";
    BlockerKeyNames[4]  = "Diffindo Challenge Key";
    BlockerKeyNames[5]  = "Boomslang Level Key";
    BlockerKeyNames[6]  = "Whomping Willow Key";
    BlockerKeyNames[7]  = "Forbidden Forest Key";
    BlockerKeyNames[8]  = "Slytherin Common Room Key";
    BlockerKeyNames[9]  = "Goyle Level Key";
    BlockerKeyNames[10] = "Bicorn Level Key";
    BlockerKeyNames[11] = "Duelling Key";
    BlockerKeyNames[12] = "Quidditch Key";
    BlockerKeyNames[13] = "Gryffindor Challenge Key";

    // Inherit cross-session AP-grant flags from class default so a freshly
    // spawned watcher (e.g. after a save-load while AP grants arrived
    // mid-flight) doesn't think these are vanilla pickups and revert them.
    for (i = 0; i < NUM_SPELLS; i++)
    {
        if (default.APGrantedSpell[i] == 1)
        {
            APGrantedSpell[i] = 1;
            WasSpellOwned[i] = 1;
        }
    }
    for (i = 0; i < NUM_KEY_ITEMS; i++)
    {
        if (default.APGrantedKeyItem[i] == 1)
        {
            APGrantedKeyItem[i] = 1;
            WasKeyItemOwned[i] = 1;
        }
    }
    for (i = 0; i < NUM_BLOCKER_KEYS; i++)
    {
        if (default.APGrantedBlockerKey[i] == 1)
        {
            APGrantedBlockerKey[i] = 1;
        }
    }

    // Close the save-load-inside-Ch7Gryffindor window: ProcessServerTravel
    // skips APGameInfo.InitGame (so its DestroyGryffindorSpellGiver never
    // runs), but this per-level watcher's PreBeginPlay still fires pre-Harry,
    // before the level begin-dispatcher triggers Givespells. No-op outside
    // CH7GRYFFINDOR / non-open castle (guarded inside).
    NeutralizeGryffindorSpellGiver();
}

// Class-default-only marker so APGameInfo.ApplyGrant can mark a spell as
// AP-granted even when no watcher instance is alive (e.g. during the gap
// between the startup watcher dying and the next level's watcher PreBeginPlay).
// PreBeginPlay copies these flags into each new instance.
static function MarkSpellAsAPGrantedDefault(string SpellName)
{
    if      (SpellName == "Alohomora")   default.APGrantedSpell[0] = 1;
    else if (SpellName == "Diffindo")    default.APGrantedSpell[1] = 1;
    else if (SpellName == "Flipendo")    default.APGrantedSpell[2] = 1;
    else if (SpellName == "Lumos")       default.APGrantedSpell[3] = 1;
    else if (SpellName == "Rictusempra") default.APGrantedSpell[4] = 1;
    else if (SpellName == "Skurge")      default.APGrantedSpell[5] = 1;
    else if (SpellName == "Spongify")    default.APGrantedSpell[6] = 1;
    else return;
    Log("[Archipelago] APCardWatcher.MarkSpellAsAPGrantedDefault: " $ SpellName $ " (class default set)");
}

static function MarkKeyItemAsAPGrantedDefault(string KeyItemName)
{
    if      (KeyItemName == "Boomslang") default.APGrantedKeyItem[0] = 1;
    else if (KeyItemName == "Bicorn")    default.APGrantedKeyItem[1] = 1;
    else if (KeyItemName == "BitOGoyle") default.APGrantedKeyItem[2] = 1;
    else return;
    Log("[Archipelago] APCardWatcher.MarkKeyItemAsAPGrantedDefault: " $ KeyItemName $ " (class default set)");
}

// Durable resync entry point. The client's AP-Data-Storage spell ledger arrives
// as a comma-separated list of AP item names this slot has ever received
// (RESYNC_SPELLS line in APIPCActor.HandleLine, sent on every Connected and on
// every game HELLO). Re-asserts each spell as AP-granted so the revert loop's
// wipe branch never wipes a legitimate prior-session grant, AND re-adds it to
// Harry's spellbook so an .usa save-load that dropped the class reference
// recovers. Always sets default.bResyncReceived so the wipe gate opens even
// when the resync list is empty (a slot that has not yet received any spells
// still gets the gate, so vanilla-engine F/L/A get correctly reverted).
// Idempotent: AddToSpellBook early-outs when the slot is non-None, and the
// MarkSpellAs* helpers are flag writes.
static function ApplyResyncSpells(string CsvNames)
{
    local int p;
    local string rest, name;
    local APCardWatcher w;
    local harry h;

    default.bResyncReceived = 1;
    Log("[Archipelago] APCardWatcher.ApplyResyncSpells: csv='" $ CsvNames $ "'");

    w = class'APCardWatcher'.static.GetLatest();
    h = None;
    if (w != None)
    {
        h = w.HarryRef;
        if (h == None) h = harry(w.Level.PlayerHarryActor);
    }

    rest = CsvNames;
    while (rest != "")
    {
        p = InStr(rest, ",");
        if (p < 0)
        {
            name = rest;
            rest = "";
        }
        else
        {
            name = Left(rest, p);
            rest = Mid(rest, p + 1);
        }
        if (name == "") continue;

        MarkSpellAsAPGrantedDefault(name);
        if (w != None)
        {
            w.MarkSpellAsGranted(name);
        }
        if (h != None)
        {
            h.AddToSpellBookByString(name);
        }
    }
}

// Bookcase-blocker-key resync entry point. Mirrors ApplyResyncSpells for the
// 14 region keys: the client's `RESYNC_BLOCKERKEYS <csv>` (sent on every
// Connected and every game HELLO) carries every key name this slot has ever
// received from AP. For each one we route through APGameInfo.TryApplyBlockerKey
// so the class-default flag is stamped AND any live bookcase blocker in the
// current level is destroyed — the consumed-indices ledger blocks GRANT replay,
// so without this a cold load with wiped class-defaults strands the slot.
// Falls back to the class-default-only marker when no GameInfo is reachable
// (resync arrived before any level Game exists).
static function ApplyResyncBlockerKeys(string CsvNames)
{
    local int p;
    local string rest, name;
    local APCardWatcher w;
    local APGameInfo gi;

    Log("[Archipelago] APCardWatcher.ApplyResyncBlockerKeys: csv='" $ CsvNames $ "'");

    w = class'APCardWatcher'.static.GetLatest();
    gi = None;
    if (w != None && w.Level != None)
    {
        gi = APGameInfo(w.Level.Game);
    }

    rest = CsvNames;
    while (rest != "")
    {
        p = InStr(rest, ",");
        if (p < 0)
        {
            name = rest;
            rest = "";
        }
        else
        {
            name = Left(rest, p);
            rest = Mid(rest, p + 1);
        }
        if (name == "") continue;

        if (gi != None)
        {
            gi.TryApplyBlockerKey(name);
        }
        else
        {
            MarkBlockerKeyAsAPGrantedDefault(name);
        }
    }
}

// Potion-key-item resync entry point. Mirrors ApplyResyncBlockerKeys for
// Boomslang/Bicorn/BitOGoyle. Today the csv is always empty (none of the three
// are AP items in items.yaml); kept in lockstep so a future randomization gets
// the same save-load survivability without further wiring. Routes through
// APGameInfo.TryApplyKeyItem so flag + watcher instance + harry inventory are
// all restored when the .usa never saw the AP grant.
static function ApplyResyncKeyItems(string CsvNames)
{
    local int p;
    local string rest, name;
    local APCardWatcher w;
    local APGameInfo gi;
    local harry h;

    Log("[Archipelago] APCardWatcher.ApplyResyncKeyItems: csv='" $ CsvNames $ "'");

    w = class'APCardWatcher'.static.GetLatest();
    h = None;
    gi = None;
    if (w != None)
    {
        h = w.HarryRef;
        if (h == None && w.Level != None) h = harry(w.Level.PlayerHarryActor);
        if (w.Level != None) gi = APGameInfo(w.Level.Game);
    }

    rest = CsvNames;
    while (rest != "")
    {
        p = InStr(rest, ",");
        if (p < 0)
        {
            name = rest;
            rest = "";
        }
        else
        {
            name = Left(rest, p);
            rest = Mid(rest, p + 1);
        }
        if (name == "") continue;

        if (gi != None && h != None)
        {
            gi.TryApplyKeyItem(name, h);
        }
        else
        {
            MarkKeyItemAsAPGrantedDefault(name);
        }
    }
}

// Bookcase-blocker-key dispatch. Returns the BlockerKeyNames[] index, or -1 if
// the string doesn't match a known key. APGameInfo.TryApplyBlockerKey uses this
// both to stamp the class-default flag and to dispatch to the right
// RemoveOpenCastle<X>Blocker helper.
static function int BlockerKeyIndexFromName(string KeyName)
{
    if (KeyName == "Chamber of Secrets Key")    return 0;
    if (KeyName == "Spongify Challenge Key")    return 1;
    if (KeyName == "Skurge Challenge Key")      return 2;
    if (KeyName == "Rictusempra Challenge Key") return 3;
    if (KeyName == "Diffindo Challenge Key")    return 4;
    if (KeyName == "Boomslang Level Key")       return 5;
    if (KeyName == "Whomping Willow Key")       return 6;
    if (KeyName == "Forbidden Forest Key")      return 7;
    if (KeyName == "Slytherin Common Room Key") return 8;
    if (KeyName == "Goyle Level Key")           return 9;
    if (KeyName == "Bicorn Level Key")          return 10;
    if (KeyName == "Duelling Key")              return 11;
    if (KeyName == "Quidditch Key")             return 12;
    if (KeyName == "Gryffindor Challenge Key")  return 13;
    return -1;
}

static function MarkBlockerKeyAsAPGrantedDefault(string KeyName)
{
    local int idx;
    idx = BlockerKeyIndexFromName(KeyName);
    if (idx < 0)
    {
        return;
    }
    default.APGrantedBlockerKey[idx] = 1;
    Log("[Archipelago] APCardWatcher.MarkBlockerKeyAsAPGrantedDefault: " $ KeyName $ " (idx=" $ idx $ " class default set)");
}

// Forgetfulness Trap entry point (called from APGameInfo.TryApplyTrap). Backs
// the full spellbook up into the class-default array, arms the restore timer
// + level-change record, then clears Harry's spellbook. Static + class-default
// so it works even when no watcher instance is alive (mirrors
// MarkSpellAsAPGrantedDefault); TrapTick() does the matching restore.
static function BackupAndClearSpellBook(harry h)
{
    local int i;

    if (h == None)
    {
        return;
    }
    // Stacking guard: a second Forgetfulness while one is still active must
    // NOT re-snapshot the spellbook — it is already cleared, so backing it up
    // again would capture an empty book and the timer would "restore" nothing
    // (spells lost permanently). Just extend the expiry; the original backup
    // (the real spells) is preserved and restored when it finally ends.
    if (default.bSpellTrapActive == 1)
    {
        default.SpellTrapExpiry = h.Level.TimeSeconds + SPELL_TRAP_DURATION;
        Log("[Archipelago] APCardWatcher.BackupAndClearSpellBook: already active - extended expiry to Level.TimeSeconds " $ string(default.SpellTrapExpiry) $ ", original backup preserved");
        return;
    }
    // 32 == harry.MAX_NUM_SPELLS / the SpellBook[32] dimension. Back up all
    // slots (a superset of what ClearSpellBook wipes) so the restore is exact.
    for (i = 0; i < 32; i++)
    {
        default.SpellTrapBackup[i] = h.SpellBook[i];
    }
    default.bSpellTrapActive  = 1;
    default.SpellTrapExpiry   = h.Level.TimeSeconds + SPELL_TRAP_DURATION;
    default.TrapLastLevelName = h.Level.Outer.Name;
    h.ClearSpellBook();
    Log("[Archipelago] APCardWatcher.BackupAndClearSpellBook: spellbook backed up + cleared (expires at Level.TimeSeconds " $ string(default.SpellTrapExpiry) $ " or on level change)");
}

// Goyle Transformation Trap bookkeeping (called from APGameInfo.TryApplyTrap
// after it flips bIsGoyle + SetNewMesh). The mesh reverts for free on the next
// level's fresh pawn; this sticky just records the active state and the
// apply-level so TrapTick can clear it on the level change.
static function MarkGoyleTrapActiveDefault(harry h)
{
    default.bGoyleTrapActive = 1;
    if (h != None)
    {
        default.TrapLastLevelName = h.Level.Outer.Name;
    }
    Log("[Archipelago] APCardWatcher.MarkGoyleTrapActiveDefault: Goyle trap active (reverts on next level)");
}

// Called once per Timer() tick (after Snapshot, HarryRef valid). Terminates
// the Goyle and Forgetfulness traps: Goyle clears on the level change (pawn
// already reverted); Forgetfulness restores the backed-up spellbook on the
// SpellTrapExpiry timeout OR the level change, whichever comes first, so
// spells are never permanently lost (a cleared SpellBook travels to the next
// level). Level NAME is the change discriminator — robust against open castle's
// per-sublevel watcher respawn (Level.Outer.Name is stable across those).
function TrapTick()
{
    local int i;
    local name curLevel;
    local bool bLevelChanged;

    curLevel = Level.Outer.Name;
    // Only meaningful while a trap is active, where a helper has stamped
    // TrapLastLevelName to a real apply-level; the pre-trap '' -> levelname
    // transition is harmless because both guarded blocks check their flag.
    bLevelChanged = (default.TrapLastLevelName != curLevel);

    if (default.bGoyleTrapActive == 1 && bLevelChanged)
    {
        default.bGoyleTrapActive = 0;
        Log("[Archipelago] APCardWatcher.TrapTick: Goyle trap cleared on level change (pawn already reverted)");
    }

    if (default.bSpellTrapActive == 1
        && (bLevelChanged || Level.TimeSeconds >= default.SpellTrapExpiry))
    {
        if (HarryRef != None)
        {
            for (i = 0; i < 32; i++)
            {
                HarryRef.SpellBook[i] = default.SpellTrapBackup[i];
            }
        }
        default.bSpellTrapActive = 0;
        if (bLevelChanged)
        {
            Log("[Archipelago] APCardWatcher.TrapTick: Forgetfulness trap ended on level change - spellbook restored");
        }
        else
        {
            Log("[Archipelago] APCardWatcher.TrapTick: Forgetfulness trap ended on timer - spellbook restored");
        }
    }

    default.TrapLastLevelName = curLevel;
}

// Pop the leading comma-delimited integer off `rest` (consumes it, including
// the comma). Last field has no trailing comma — take the whole remainder.
// UE1 UScript has no string split and forbids fixed-size locals, so this is
// the per-field primitive SetGoalConfigCSV iterates.
static function int NextCsvInt(out string rest)
{
    local int comma, val;
    comma = InStr(rest, ",");
    if (comma >= 0)
    {
        val = int(Left(rest, comma));
        rest = Mid(rest, comma + 1);
    }
    else
    {
        val = int(rest);
        rest = "";
    }
    return val;
}

// Ingest "cards,spells,levels,duels,quidditch,mask" from the client (apworld
// slot_data, sent every HELLO). Class-default + sticky like bOpenCastleMode /
// APGrantedBlockerKey; idempotent (re-parsing the same csv re-asserts the same
// values). The apworld already applied the all-off → all-spells fallback, so
// a open castle seed never delivers an all-zero (no-gate) config.
static function SetGoalConfigCSV(string csv)
{
    local string rest;

    rest = csv;
    default.GoalCards     = NextCsvInt(rest);
    default.GoalSpells    = NextCsvInt(rest);
    default.GoalLevels    = NextCsvInt(rest);
    default.GoalDuels     = NextCsvInt(rest);
    default.GoalQuidditch = NextCsvInt(rest);
    default.GoalLevelMask = NextCsvInt(rest);
    default.bGoalConfigured = 1;

    Log("[Archipelago] APCardWatcher.SetGoalConfigCSV: cards=" $ default.GoalCards
        $ " spells=" $ default.GoalSpells $ " levels=" $ default.GoalLevels
        $ " duels=" $ default.GoalDuels $ " quidditch=" $ default.GoalQuidditch
        $ " mask=" $ default.GoalLevelMask);
}

// Tradersanity price mode from the apworld slot_data (TRADECFG IPC line).
// Class-default + sticky, mirroring SetGoalConfigCSV; idempotent.
static function SetTradersanityMode(int m)
{
    default.TradersanityMode = m;
    Log("[Archipelago] APCardWatcher.SetTradersanityMode: mode=" $ default.TradersanityMode);
}

// Per-vendor Tradersanity price factors from the apworld slot_data
// (TRADERPRICES IPC line), as `locId:factor,locId:factor,...` (factor =
// byte 0..255). Pre-rolled in the apworld with self.random so the same AP
// seed always yields the same per-vendor prices; the mod blends each
// factor into the active price range in ApplyVendorPrice. Class-default +
// sticky, mirroring SetAppearanceCSV; idempotent. Wipes the table first so
// a later seed without Tradersanity (or with fewer entries) can't leak
// stale factors from a prior session.
static function SetTraderRolledFactors(string csv)
{
    local string rest;
    local int apId, factor, slot, n;

    for (slot = 0; slot < NONCARD_LOC_WINDOW; slot++)
    {
        default.TraderRolledFactor[slot] = 0;
    }

    rest = csv;
    n = 0;
    while (rest != "")
    {
        apId   = NextCsvIntUpTo(rest, ":");
        factor = NextCsvIntUpTo(rest, ",");
        slot = apId - LOC_BASE;
        if (slot >= 0 && slot < NONCARD_LOC_WINDOW)
        {
            if (factor < 0)   factor = 0;
            if (factor > 255) factor = 255;
            default.TraderRolledFactor[slot] = byte(factor);
            n++;
        }
    }
    Log("[Archipelago] APCardWatcher.SetTraderRolledFactors: ingested " $ n $ " factor entry(ies)");
}

// Inbound DeathLink arm (DEATHLINK IPC line). Class-default + sticky like the
// other setters; ScanDeathLink applies it on the next playable tick. Setting
// 1 over an already-pending 1 is idempotent (a death you can't act on yet
// collapses to a single kill on return — correct, you only die once).
static function SetPendingDeathLink()
{
    default.bPendingDeathLink = 1;
    Log("[Archipelago] APCardWatcher.SetPendingDeathLink: inbound DeathLink armed");
}

// AP server address for the startup "Connected to host:port" toast (CONNECTED
// IPC line, client-formatted with scheme stripped). Class-default + sticky
// like the other setters; idempotent (the client resends the same address
// every HELLO). Does NOT touch bConnToastShown — arming/firing is owned by
// the Timer / EnsureLatestRegistration so a resend of the same address on a
// mid-session HELLO can never re-trigger the toast.
static function SetConnectedAddress(string addr)
{
    if (addr == "") return;
    default.ConnectedAddress = addr;
    Log("[Archipelago] APCardWatcher.SetConnectedAddress: '" $ default.ConnectedAddress $ "'");
}

// Ingest the client's CHECKED resync (comma-separated AP location ids the
// server already has as checked for this slot). Stamps card apIds into
// default.LocationChecked[cardId] and everything else into
// default.NonCardLocationChecked[apId - LOC_BASE], so the mod's
// process-lifetime dedupe arrays match the AP server's source of truth across
// game close+reload (class-defaults are compiled, never read from the .usa).
// Level-completion apIds (5760700..5760711 → slot 700..711) additionally
// re-stamp default.GoalLevelDone[idx], so a cold load can't leave the
// open-castle goal evaluator stranded — the bookcase / hub Timer re-evaluates
// GoalSatisfied() on the next tick and self-opens the Great Hall via the
// existing WasGoalUnlocked path. Class-default + sticky like the other
// setters; idempotent (a check can never be "uncollected"). Resent every
// HELLO. The follow-up convergence sweep that bean-swaps already-checked
// chest slots is owned by ReSweepCheckedChests, called from APIPCActor's
// CHECKED handler.
static function SetCheckedLocationsCSV(string csv)
{
    local string rest;
    local int apId, slot, cardId, nCard, nNonCard, nGoalLevel;

    rest = csv;
    while (rest != "")
    {
        apId = NextCsvInt(rest);
        slot = apId - LOC_BASE;
        // Card location band is id_offset 100-200.
        // Within the band the cardId -> apId mapping is scrambled (see
        // APCardAppearance.CardIdToApId), so a 101-iteration linear reverse
        // scan resolves it. Cheap: <= ~10k ops per HELLO worst case
        // (101 cards * 101 scan).
        if (slot >= 100 && slot <= 200)
        {
            for (cardId = 1; cardId <= 101; cardId++)
            {
                if (class'APCardAppearance'.static.CardIdToApId(cardId) == apId)
                {
                    default.LocationChecked[cardId] = 1;
                    nCard++;
                    break;
                }
            }
        }
        else if (slot >= 0 && slot < NONCARD_LOC_WINDOW)
        {
            default.NonCardLocationChecked[slot] = 1;
            nNonCard++;
            // Level completions double-stamp the clause-3 goal bitset
            // (mirrors NotifyLevelObjective which sets both alongside each
            // CHECK_LOCID fire). Slot 700..(700+15) maps to GoalLevelDone
            // index 0..15; the array dim allows 16 objectives, 12 are wired
            // today (see LevelObjectiveIndexFor).
            if (slot >= 700 && (slot - 700) < 16)
            {
                default.GoalLevelDone[slot - 700] = 1;
                nGoalLevel++;
            }
        }
    }
    Log("[Archipelago] APCardWatcher.SetCheckedLocationsCSV: stamped "
        $ nCard $ " card check(s) + " $ nNonCard $ " non-card check(s) ("
        $ nGoalLevel $ " level completion(s) → GoalLevelDone[])");
}

// ---------------------------------------------------------------------------
// #3 marker-appearance subsystem
// ---------------------------------------------------------------------------

// Like NextCsvInt but the field separator is a parameter, so the APPEARANCE
// payload's `apId:code,apId:code` form parses with one primitive (`:` then
// `,`). Last field has no trailing separator → take the whole remainder.
static function int NextCsvIntUpTo(out string rest, string sep)
{
    local int p, val;
    p = InStr(rest, sep);
    if (p >= 0)
    {
        val = int(Left(rest, p));
        rest = Mid(rest, p + 1);
    }
    else
    {
        val = int(rest);
        rest = "";
    }
    return val;
}

// Ingest the client's "apId:code,apId:code,…" appearance table. Full AP
// location ids on the wire (same convention as CHECK_LOCID); stored at
// `apId - LOC_BASE`. Clears the whole table first so a resend is authoritative
// (a location that dropped out of the table reverts to native). Class-default
// + sticky like the goal config; idempotent. Sets bAppearanceReceived so the
// sweep / self-apply paths come alive.
static function SetAppearanceCSV(string csv)
{
    local string rest;
    local int apId, code, slot, n;

    for (slot = 0; slot < NONCARD_LOC_WINDOW; slot++)
    {
        default.AppearanceCode[slot] = 0;
    }

    rest = csv;
    n = 0;
    while (rest != "")
    {
        apId = NextCsvIntUpTo(rest, ":");
        code = NextCsvIntUpTo(rest, ",");
        slot = apId - LOC_BASE;
        if (slot >= 0 && slot < NONCARD_LOC_WINDOW)
        {
            default.AppearanceCode[slot] = code;
            n++;
        }
    }
    default.bAppearanceReceived = 1;
    Log("[Archipelago] APCardWatcher.SetAppearanceCSV: ingested " $ n $ " appearance entry(ies)");
}

// Table lookup. 0 (native / unknown / out-of-window) is the safe default.
static function int AppearanceForApId(int apId)
{
    local int slot;
    slot = apId - LOC_BASE;
    if (slot < 0 || slot >= NONCARD_LOC_WINDOW) return 0;
    return default.AppearanceCode[slot];
}

// Vanilla in-world DrawScale read from a pickup class default at runtime
// (each vanilla prop tunes its own; hardcoding one value mis-sized them).
// Same proven `.default` reflection as cardCls.default.Skin
// (APGameInfo.uc:1448). `fallback` if the class can't resolve (async-safe).
static function float VanillaDrawScale(string clsName, float fallback)
{
    local class<Actor> ac;
    ac = class<Actor>(DynamicLoadObject("HGame." $ clsName, class'Class'));
    if (ac == None) return fallback;
    return ac.default.DrawScale;
}

// AP defines four bean-pile sizes but vanilla has ONE jar mesh/class
// (JarBeans). Anchor on JarBeans' real DrawScale (`base`, read at runtime via
// VanillaDrawScale) and spread the four AP sizes around it so they stay
// proportional to the vanilla jar. Multipliers are the cosmetic dial-in the
// plan defers; "Large" == the vanilla jar size.
static function float BeanScale(int code, float base)
{
    if (code == 2001) return base * 0.60; // Small
    if (code == 2002) return base * 0.80; // Medium
    if (code == 2003) return base * 1.00; // Large  (== vanilla JarBeans)
    return base * 1.25;                    // 2004 Massive
}

// The per-spell wand-target gesture sprite (the shape SpellCursor draws on a
// locked target, SpellCursor.uc:84-108) by spell index (0 Alohomora,
// 1 Diffindo, 2 Flipendo, 3 Lumos, 4 Rictusempra, 5 Skurge, 6 Spongify — same
// order as SpellNames[]). WetTexture is-a Texture, so it loads cleanly as
// class'Texture'. None for an unknown index keeps the marker's native look.
static function Texture SpellGestureTextureForIndex(int idx)
{
    if (idx == 0) return Texture(DynamicLoadObject("SpellShapes.SpellFX.AlohomoraWet1", class'Texture'));
    if (idx == 1) return Texture(DynamicLoadObject("SpellShapes.SpellFX.DiffindoWet1", class'Texture'));
    if (idx == 2) return Texture(DynamicLoadObject("SpellShapes.SpellFX.FlipendoWet1", class'Texture'));
    if (idx == 3) return Texture(DynamicLoadObject("SpellShapes.SpellFX.LumosWet1", class'Texture'));
    if (idx == 4) return Texture(DynamicLoadObject("SpellShapes.SpellFX.RictusWet1", class'Texture'));
    if (idx == 5) return Texture(DynamicLoadObject("SpellShapes.SpellFX.SkurgeWet1", class'Texture'));
    if (idx == 6) return Texture(DynamicLoadObject("SpellShapes.SpellFX.SpongifyWet1", class'Texture'));
    return None;
}

// A random Bertie Bott's bean skin for the loose-bean fillers (1 / 5 Bean) so
// the pickup is a different colour each time it is stamped instead of one
// static texture. All 12 are vanilla HProps single-bean skins (the set
// Jellybean.uc's subclasses use). Re-rolled on every appearance re-stamp.
static function Texture RandomBeanTexture()
{
    local int i;
    i = Rand(12);
    if (i == 0)  return Texture(DynamicLoadObject("HProps.skJellybeanTex0",     class'Texture'));
    if (i == 1)  return Texture(DynamicLoadObject("HProps.skBeanRedTex0",       class'Texture'));
    if (i == 2)  return Texture(DynamicLoadObject("HProps.skBeanBlueSpotTex0",  class'Texture'));
    if (i == 3)  return Texture(DynamicLoadObject("HProps.skBeanBlackTex0",     class'Texture'));
    if (i == 4)  return Texture(DynamicLoadObject("HProps.skBeanPurpleTex0",    class'Texture'));
    if (i == 5)  return Texture(DynamicLoadObject("HProps.skBeanDarkGreenTex0", class'Texture'));
    if (i == 6)  return Texture(DynamicLoadObject("HProps.skBeanBogieTex0",     class'Texture'));
    if (i == 7)  return Texture(DynamicLoadObject("HProps.skBeanBrownTex0",     class'Texture'));
    if (i == 8)  return Texture(DynamicLoadObject("HProps.skBeanDkBlueTex0",    class'Texture'));
    if (i == 9)  return Texture(DynamicLoadObject("HProps.skBeanMauveTex0",     class'Texture'));
    if (i == 10) return Texture(DynamicLoadObject("HProps.skBeanOrngeTex0",     class'Texture'));
    return Texture(DynamicLoadObject("HProps.skBeanYellowyTex0", class'Texture'));
}

// Stamp mesh + (optionally) skin + draw fields onto any Actor (runtime Mesh/
// Skin/DrawType reassignment is engine-supported, Characters.uc:991-1034). If
// the mesh can't resolve, nothing is touched → marker keeps its native look
// (async-safe). 3-skin filler meshes pass bSetSkin=False (baked materials).
// bLogoStyle = the foreign AP-logo: STY_Masked for the magenta chroma-key
// transparency (see APLogoMesh.uc), unlit + full glow for constant brightness.
static function ApplyMeshSkin(Actor a, Mesh m, Material tex, bool bSetSkin, float scale, bool bLogoStyle)
{
    if (a == None || m == None) return;
    a.Mesh = m;
    a.DrawType = DT_Mesh;
    a.DrawScale = scale;
    if (bSetSkin && tex != None)
    {
        a.Skin = tex;
        a.MultiSkins[0] = tex;
    }
    if (bLogoStyle)
    {
        a.Style = STY_Masked;
        a.bUnlit = True;
        a.AmbientGlow = 255;
    }
    else
    {
        a.Style = STY_Normal;
        a.bUnlit = False;
    }
}

// The resolver. Morphs `a` to the vanilla art of whatever the location holds,
// per the appearance code. code 0 ⇒ leave the marker's own native look (do
// nothing). All asset objects are resolved by name via DynamicLoadObject so
// there is no hard package link and a not-yet-loaded asset degrades to
// "native" rather than failing. The per-card face is read from
// <cardClass>.default.Skin (proven pattern, APGameInfo.uc:1448) so the
// Griffindor/Gryffindor skin-name irregularity is auto-correct.
static function ApplyAppearanceTo(Actor a, int code)
{
    local Mesh m;
    // Actor.Skin / MultiSkins[] and WizardCardIcon.default.Skin are typed
    // Material in this engine (Texture extends Material), so the skin handle
    // must be Material — a Texture from DynamicLoadObject up-casts cleanly.
    local Material tex;
    local class<WizardCardIcon> cc;
    local string cn;
    local float sc;          // resolved per-prop vanilla DrawScale
    local Rotator r;         // 3003 key: 180° roll fix

    if (a == None || code == 0) return;

    if (code >= 1 && code <= 101)
    {
        m = Mesh(DynamicLoadObject("HProps.skWizardCardIconMesh", class'Mesh'));
        sc = 2.0; // WizardCardIcon.defaultproperties DrawScale (fallback)
        cn = class'APCardAppearance'.static.CardClassNameForId(code);
        if (cn != "")
        {
            cc = class<WizardCardIcon>(DynamicLoadObject("HGame." $ cn, class'Class'));
            if (cc != None)
            {
                tex = cc.default.Skin;
                sc  = cc.default.DrawScale; // per-card vanilla size (== 2.0)
            }
        }
        ApplyMeshSkin(a, m, tex, True, sc, False);
    }
    else if (code >= 1000 && code <= 1006)
    {
        // Spells are learned, not dropped — no vanilla world prop to anchor
        // on. Put the wand-target gesture art (the shape the player already
        // reads as "this spell") on the flat wizard-card mesh so a spell
        // pickup spins like a card pickup in the same chest (the card actor's
        // own Tick drives the Yaw spin). DrawScale 3.0 is deliberately above
        // the WizardCardIcon default of 2.0 so the gesture glyph reads at a
        // glance.
        m = Mesh(DynamicLoadObject("HProps.skWizardCardIconMesh", class'Mesh'));
        tex = SpellGestureTextureForIndex(code - 1000);
        ApplyMeshSkin(a, m, tex, True, 3.0, False);
    }
    else if (code >= 2001 && code <= 2004)
    {
        m = Mesh(DynamicLoadObject("HProps.skJarBeansMesh", class'Mesh'));
        tex = Texture(DynamicLoadObject("HProps.skJarBeansTex0", class'Texture'));
        ApplyMeshSkin(a, m, tex, True,
            BeanScale(code, VanillaDrawScale("JarBeans", 2.5)), False);
    }
    else if (code == 2005)
    {
        m = Mesh(DynamicLoadObject("HProps.skBottlePotionGreen1Mesh", class'Mesh'));
        tex = Texture(DynamicLoadObject("HProps.skBottlePotionGreen1Tex0", class'Texture'));
        ApplyMeshSkin(a, m, tex, True,
            VanillaDrawScale("BottlePotionGreen1", 1.0), False);
    }
    else if (code == 2006)
    {
        // 3-skin mesh — set Mesh only so the baked materials render.
        m = Mesh(DynamicLoadObject("HProps.skJarWiggentreeBarkMesh", class'Mesh'));
        ApplyMeshSkin(a, m, None, False,
            VanillaDrawScale("JarWiggentreeBark", 1.2), False);
    }
    else if (code == 2007)
    {
        // 3-skin mesh — set Mesh only.
        m = Mesh(DynamicLoadObject("HProps.skJarFlobberwormMucusMesh", class'Mesh'));
        ApplyMeshSkin(a, m, None, False,
            VanillaDrawScale("JarFlobberwormMucus", 1.2), False);
    }
    else if (code == 2008)
    {
        m = Mesh(DynamicLoadObject("HProps.skChocolateFrogMesh", class'Mesh'));
        tex = Texture(DynamicLoadObject("HProps.skChocolateFrogTex0", class'Texture'));
        ApplyMeshSkin(a, m, tex, True,
            VanillaDrawScale("ChocolateFrog", 0.5), False);
    }
    else if (code == 2009)
    {
        // 1 Bean — the vanilla jellybean prop, random colour per stamp.
        // Smallest of the bean ladder so a single bean reads as the lowest
        // reward.
        m = Mesh(DynamicLoadObject("HProps.skJellybeanMesh", class'Mesh'));
        tex = RandomBeanTexture();
        ApplyMeshSkin(a, m, tex, True, 1.5, False);
    }
    else if (code == 2010)
    {
        // 5 Beans — same bean mesh, random colour per stamp, larger than
        // 1 Bean so the two read apart by size.
        m = Mesh(DynamicLoadObject("HProps.skJellybeanMesh", class'Mesh'));
        tex = RandomBeanTexture();
        ApplyMeshSkin(a, m, tex, True, 2.0, False);
    }
    else if (code == 2011)
    {
        // 10 Beans — the bean jar, below the Small Pile (0.60) so the size
        // ladder reads loose bean -> small jar -> the Piles.
        m = Mesh(DynamicLoadObject("HProps.skJarBeansMesh", class'Mesh'));
        tex = Texture(DynamicLoadObject("HProps.skJarBeansTex0", class'Texture'));
        ApplyMeshSkin(a, m, tex, True,
            VanillaDrawScale("JarBeans", 2.5) * 0.45, False);
    }
    else if (code == 3001)
    {
        // Nimbus 2001 — vanilla VendorNimbusBroom look (single baked skin,
        // set Mesh only).
        m = Mesh(DynamicLoadObject("HProps.skBroomQudditchMesh", class'Mesh'));
        ApplyMeshSkin(a, m, None, False,
            VanillaDrawScale("VendorNimbusBroom", 1.0), False);
    }
    else if (code == 3002)
    {
        // Quidditch Armour — vanilla QArmor look.
        m = Mesh(DynamicLoadObject("HProps.skQuidArmorMesh", class'Mesh'));
        ApplyMeshSkin(a, m, None, False,
            VanillaDrawScale("QArmor", 1.0), False);
    }
    else if (code == 3003)
    {
        // Open castle level/challenge bookcase key — the vanilla "silver key" FX
        // sprite (HPParticle.hp_fx.Particles.Key3, the texture SilverUnlock
        // spawns on every 10th silver card). It is a light-on-black additive
        // particle texture: the masked chroma-key (bLogoStyle) cannot key
        // black, so override to STY_Translucent — black drops to transparent
        // and the key glows. Card-sized on the flat card quad (DrawScale 2.0).
        m   = Mesh(DynamicLoadObject("HProps.skWizardCardIconMesh", class'Mesh'));
        tex = Texture(DynamicLoadObject("HPParticle.hp_fx.Particles.Key3", class'Texture'));
        ApplyMeshSkin(a, m, tex, True, 2.0, True);
        a.Style = STY_Translucent;
        // Key3 maps onto the card quad upside down; roll 180° (32768 = 180°
        // in Rotator units). Absolute set, not an increment, so repeated
        // morph passes stay idempotent; the Wait-state spin animates Yaw
        // only, so this Roll persists.
        r = a.Rotation;
        r.Roll = 32768;
        a.SetRotation(r);
    }
    else if (code == 9000)
    {
        // Foreign plain (per-orb AP-logo coins). Textures live in the `Skins`
        // group so they MUST be loaded group-qualified (group-less DLO returns
        // None, which would drop 9001 back to the baked plain skin). DrawScale
        // 1.65 ≈ card-sized (tunable).
        m = Mesh(DynamicLoadObject("HPArchipelago.APLogoMesh", class'Mesh'));
        tex = Texture(DynamicLoadObject("HPArchipelago.Skins.APLogoTex0", class'Texture'));
        ApplyMeshSkin(a, m, tex, True, 1.65, True);
    }
    else if (code == 9001)
    {
        m = Mesh(DynamicLoadObject("HPArchipelago.APLogoMesh", class'Mesh'));
        tex = Texture(DynamicLoadObject("HPArchipelago.Skins.APLogoArrowTex0", class'Texture'));
        ApplyMeshSkin(a, m, tex, True, 1.65, True);
    }
}

// Capability-contract entry point. A morphable marker calls this on the live
// per-level watcher (class'APCardWatcher'.static.GetLatest()) with itself and
// its AP location id once that id is known. Instance (NOT static / NOT
// class-default) — see the registry declaration: actor refs in class-default
// storage crash the engine at level cleanup. Idempotent per actor (updates in
// place). Registry-full just means this marker relies on its PostBeginPlay
// self-apply for this level; never fatal.
function RegisterMorphMarker(Actor a, int apId)
{
    local int i, free;

    if (a == None) return;

    free = -1;
    for (i = 0; i < MORPH_REGISTRY_SIZE; i++)
    {
        if (MorphActor[i] == a)
        {
            MorphApId[i] = apId;
            return;
        }
        if (free < 0 && (MorphActor[i] == None || MorphActor[i].bDeleteMe))
        {
            free = i;
        }
    }
    if (free < 0) return;
    MorphActor[free] = a;
    MorphApId[free]  = apId;
}

// Convergence sweep after a CHECKED resync. Walks the current level's
// chest / cauldron slots and live APCardMarker actors and bean-swaps /
// destroys the ones whose location is now (post-stamp) in
// default.LocationChecked[].
//
// Why this exists: ReplaceCardChests only runs in InitGame, but the CHECKED
// IPC line arrives asynchronously some hundreds of ms after the game's HELLO
// — by then InitGame has long finished. Without this sweep the chests stay
// in their save-restored "APCardMarker in slot" state until the next level
// transition. Idempotent: a slot already Jellybean (or one whose location
// is still unchecked) is left alone. Mirrors the
// APPEARANCE → RestampMarkerAppearance pattern.
//
// Scope: cards only. chest.bOpened is deliberately NOT restored to True
// here: same-session ReplaceCardChests' bean-swap path doesn't touch
// bOpened either (it only resets when hasUnchecked is true), so leaving it
// matches that behaviour — a chest re-Alohomora'd post-sweep dispenses a
// Jellybean from the swapped slot, which is the same outcome as a
// co-op-pre-collected chest the player opens for the first time.
function ReSweepCheckedChests()
{
    local Actor scanActor;
    local chestbronze chest;
    local bronzecauldron cauldron;
    local APCardMarker marker;
    local class<APCardMarker> slotMarkerCls;
    local int i, nBean, nDestroy;

    // Watcher's HarryRef is the gameplay UWorld anchor (matches the pattern
    // RemoveRictaBlocker / DestroyTaggedOpenCastleBlockers use). Falls back
    // to self when no Harry is bound yet (pre-Snapshot tick); the early HELLO
    // window is rare but the fallback keeps the sweep useful even then.
    if (HarryRef != None && !HarryRef.bDeleteMe)
    {
        scanActor = HarryRef;
    }
    else
    {
        scanActor = self;
    }

    foreach scanActor.AllActors(class'chestbronze', chest)
    {
        if (chest == None || chest.bDeleteMe) continue;
        for (i = 0; i < ArrayCount(chest.EjectedObjects); i++)
        {
            if (chest.EjectedObjects[i] == None) continue;
            if (!ClassIsChildOf(chest.EjectedObjects[i], class'APCardMarker')) continue;
            slotMarkerCls = class<APCardMarker>(chest.EjectedObjects[i]);
            if (slotMarkerCls.default.CardLocationId <= 0
                || slotMarkerCls.default.CardLocationId > 101) continue;
            if (default.LocationChecked[slotMarkerCls.default.CardLocationId] != 1) continue;
            Log("[Archipelago] ReSweepCheckedChests: chest=" $ string(chest)
                $ " slot=" $ i $ " was=" $ string(chest.EjectedObjects[i])
                $ " location " $ slotMarkerCls.default.CardLocationId
                $ " checked - bean-swapping to Jellybean");
            chest.EjectedObjects[i] = class'Jellybean';
            nBean++;
        }
    }

    foreach scanActor.AllActors(class'bronzecauldron', cauldron)
    {
        if (cauldron == None || cauldron.bDeleteMe) continue;
        for (i = 0; i < ArrayCount(cauldron.EjectedObjects); i++)
        {
            if (cauldron.EjectedObjects[i] == None) continue;
            if (!ClassIsChildOf(cauldron.EjectedObjects[i], class'APCardMarker')) continue;
            slotMarkerCls = class<APCardMarker>(cauldron.EjectedObjects[i]);
            if (slotMarkerCls.default.CardLocationId <= 0
                || slotMarkerCls.default.CardLocationId > 101) continue;
            if (default.LocationChecked[slotMarkerCls.default.CardLocationId] != 1) continue;
            Log("[Archipelago] ReSweepCheckedChests: cauldron=" $ string(cauldron)
                $ " slot=" $ i $ " was=" $ string(cauldron.EjectedObjects[i])
                $ " location " $ slotMarkerCls.default.CardLocationId
                $ " checked - bean-swapping to Jellybean");
            cauldron.EjectedObjects[i] = class'Jellybean';
            nBean++;
        }
    }

    // Live in-level APCardMarker actors (loose-spawn placements; or a marker
    // spawned by a chest's generateobject before the resync landed). Their
    // PostBeginPlay self-destroy guard already covers fresh spawns; this
    // covers the ones that exist right now, post-RCC and pre-CHECKED.
    foreach scanActor.AllActors(class'APCardMarker', marker)
    {
        if (marker == None || marker.bDeleteMe) continue;
        if (marker.CardLocationId <= 0 || marker.CardLocationId > 101) continue;
        if (default.LocationChecked[marker.CardLocationId] != 1) continue;
        Log("[Archipelago] ReSweepCheckedChests: marker=" $ string(marker)
            $ " location " $ marker.CardLocationId $ " checked - destroying");
        marker.Destroy();
        nDestroy++;
    }

    if (nBean > 0 || nDestroy > 0)
    {
        Log("[Archipelago] ReSweepCheckedChests: bean-swapped " $ nBean
            $ " slot(s), destroyed " $ nDestroy $ " live marker(s) in "
            $ string(Level.Outer.Name));
    }
}

// Convergence sweep: re-stamp every registered marker from the live table.
// Authoritative for stars/vendors (id stamped after Spawn) and the catch-up
// after an async table arrival. Native-safe: early return until a table
// exists; empty/dead slots skipped. Instance; the registry is per-level
// instance state so there is no cross-level entry to filter.
function RestampMarkerAppearance()
{
    local int i, applied;
    local Actor a;

    if (default.bAppearanceReceived == 0) return;

    applied = 0;
    for (i = 0; i < MORPH_REGISTRY_SIZE; i++)
    {
        a = MorphActor[i];
        if (a == None) continue;
        if (a.bDeleteMe) continue;
        ApplyAppearanceTo(a, AppearanceForApId(MorphApId[i]));
        applied++;
    }
    if (applied > 0)
    {
        Log("[Archipelago] APCardWatcher.RestampMarkerAppearance: applied appearance to "
            $ applied $ " marker(s) in " $ string(Level.Outer.Name));
    }
}

// Clause-3 objective index for a Caps'd map name. The 3
// key-item ingredient levels (idx 0-2) are listed too: their StatusItem nCount
// path is unreliable in this build (orphaned StatusItemBitOGoyle; the
// Adv3DungeonQuest Bicorn prop has null class refs so PickupItem early-returns),
// so they are credited the robust Willow/Slytherin way: by
// leaving the (terminal, single-objective) level. -1 = not a clause-3 level.
static function int LevelObjectiveIndexFor(string CapsLevelName)
{
    if (CapsLevelName == "ADV4GREENHOUSE")   return 0;  // Boomslang Skin
    if (CapsLevelName == "ADV3DUNGEONQUEST") return 1;  // Bicorn Horn
    if (CapsLevelName == "ADV6GOYLE")        return 2;  // Bit O' Goyle
    if (CapsLevelName == "ADV9ARAGOG")       return 3;  // Forbidden Forest (Aragog)
    if (CapsLevelName == "ADV12CHAMBER")     return 4;  // Chamber (Basilisk)
    if (CapsLevelName == "ADV1WILLOW")       return 5;  // Whomping Willow
    if (CapsLevelName == "ADV7SLYTHCOMROOM") return 6;  // Slytherin Common Room
    if (CapsLevelName == "CH1RICTUSEMPRA")   return 7;
    if (CapsLevelName == "CH2SKURGE")        return 8;
    if (CapsLevelName == "CH3DIFFINDO")      return 9;
    if (CapsLevelName == "CH4SPONGIFY")      return 10;
    if (CapsLevelName == "CH7GRYFFINDOR")    return 11;  // Gryffindor challenge
    return -1;
}

// Mark a clause-3 level objective complete. Dedupe is uniform with
// stars/duels/quidditch via NonCardLocationChecked[apId-LOC_BASE], and the
// sticky GoalLevelDone[idx] bit (the clause-3 gate state GoalSatisfied()
// reads) is also set. Fires the "X Level Complete" CHECK_LOCID 5760700+idx.
// Shared by Mechanisms A (key-item), B (boss), C (exit probe), D (end star).
static function NotifyLevelObjective(int idx)
{
    local APIPCActor ipc;
    local int locId, slot;

    if (idx < 0 || idx >= 16) return;
    locId = 5760700 + idx;
    slot = locId - LOC_BASE;
    if (slot < 0 || slot >= NONCARD_LOC_WINDOW) return;
    if (default.NonCardLocationChecked[slot] == 1) return;
    default.NonCardLocationChecked[slot] = 1;
    default.GoalLevelDone[idx] = 1;
    Log("[Archipelago] APCardWatcher.NotifyLevelObjective: clause-3 objective idx="
        $ idx $ " complete - firing CHECK_LOCID " $ locId);
    ipc = class'APIPCActor'.static.GetInstance();
    if (ipc != None) ipc.SendCheckLocationId(locId);
}

// True when every ENABLED open castle Great Hall key clause passes. A clause with a
// 0 / off threshold drops out of the AND. Reads class-default thresholds vs
// live state. Clause 3 (GoalLevelDone[]) is populated by the Phase-4
// detectors; until those land a non-zero GoalLevels simply keeps the gate
// shut, which is the safe direction.
function bool GoalSatisfied()
{
    local int i, n;

    if (default.bGoalConfigured == 0) return False;  // never unlock un-configured

    // Clause 1 — wizard cards Harry owns.
    if (default.GoalCards > 0)
    {
        if (siBronze == None || siSilver == None || siGold == None) return False;
        if (siBronze.nCount + siSilver.nCount + siGold.nCount < default.GoalCards)
            return False;
    }

    // Clause 2 — spells received (APGrantedSpell is the sticky class-default
    // stamped on every AP spell grant; 0..NUM_SPELLS-1).
    if (default.GoalSpells > 0)
    {
        n = 0;
        for (i = 0; i < NUM_SPELLS; i++)
            if (default.APGrantedSpell[i] == 1) n++;
        if (n < default.GoalSpells) return False;
    }

    // Clause 3 — level objectives (Phase-4 detectors set GoalLevelDone[];
    // GoalLevelMask selects which indices count).
    if (default.GoalLevels > 0)
    {
        n = 0;
        for (i = 0; i < 16; i++)
            if (((default.GoalLevelMask >> i) & 1) == 1 && default.GoalLevelDone[i] == 1)
                n++;
        if (n < default.GoalLevels) return False;
    }

    // Clause 4 — all 10 duels (ScanDuelWins: ranks 1..DuelRankHarry-1 are won).
    if (default.GoalDuels == 1)
    {
        if (HarryRef == None || HarryRef.DuelRankHarry < 11) return False;
    }

    // Clause 5 — all 6 Quidditch matches.
    if (default.GoalQuidditch == 1)
    {
        if (HarryRef == None) return False;
        for (i = 0; i < 6; i++)
            if (!HarryRef.quidGameResults[i].bWon) return False;
    }

    return True;
}

event Timer()
{
    local int id, i;
    local APIPCActor ipc;
    local HPConsole console;
    local FEBook book;
    local harry viewportHarry;
    local harry saveHarry;
    local string deferReason;
    local APGameInfo gi;
    local baseWand wand;
    local baseSpell cur;
    local int idx;
    local APHUDToast connToast;
    local bool seedIsOpenCastle;

    EnsureLatestRegistration();
    if (default.LatestInstance != self)
    {
        return;
    }

    if (!bSnapshotted)
    {
        if (!Bind())
        {
            return;
        }
        Snapshot();
        bSnapshotted = True;
        // Run the trap lifetime check on this first post-Bind tick too, so a
        // level transition restores the Forgetfulness spellbook immediately
        // (HarryRef is valid here) instead of one tick later — and before the
        // spell-revert loop, which we return short of, can run. Idempotent
        // with the TrapTick() below; only acts when a trap is active.
        TrapTick();
        return;
    }

    viewportHarry = class'APGameInfo'.static.TryGetViewportHarry(HarryRef);
    if (viewportHarry != None && viewportHarry != HarryRef)
    {
        Log("[Archipelago] APCardWatcher: detected Viewport.Actor switch " $ string(HarryRef) $ " -> " $ string(viewportHarry) $ " - rebinding");
        if (!Bind())
        {
            return;
        }
        Snapshot();
    }

    // Use the singleton directly instead of Level.Game.IPCActor. Save-load
    // skips APGameInfo.InitGame, leaving the post-save GameInfo with
    // IPCActor=None even though the persistent singleton is still alive, so
    // Level.Game.IPCActor would drop every game->client CHECK after a save-load.
    ipc = class'APIPCActor'.static.GetInstance();

    // Cheap once-per-process patch (no-op after the first successful inject).
    EnsureHomeMenuInjected();

    // Terminate the Goyle / Forgetfulness traps on their timer or the level
    // change. Runs before the spell-revert loop so a same-tick restore is
    // visible to it (and bSpellTrapActive is cleared before that loop checks).
    TrapTick();

    for (id = 1; id <= MAX_CARD_ID; id++)
    {
        if (WasOwnedByHarry[id] == 0 && IsHarryOwned(id))
        {
            WasOwnedByHarry[id] = 1;
            Log("[Archipelago] APCardWatcher: new vanilla card pickup detected, id=" $ id);
            if (ipc != None)
            {
                ipc.SendCheck(id);
            }
            RevertVanillaPickup(id);
            // Stamp LocationChecked + clear vendor ownership so a future level
            // re-entry doesn't re-offer this card. Mirrors what APCardMarker.Touch
            // does when the marker path catches the pickup.
            default.LocationChecked[id] = 1;
            ClearVendorOwnershipForLocation(id);
        }
    }

    // ReplaceVendorEquipment carries the Tradersanity pass. It is independent
    // of ReplaceVendorSpawnedCards (Tradersanity vendors sell a plain
    // ingredient prop, never a WizardCardIcon), so order does not matter.
    ReplaceVendorEquipment();
    ReplaceVendorSpawnedCards();
    ScanSecretMarkers(ipc);
    ScanDuelWins(ipc);
    ScanMatchWins(ipc);
    ScanChallengeMastery(ipc);
    ScanBossKills(ipc);
    ScanDeathLink(ipc);
    ScanFinalStarCompletion();

    // Lesson-end hook for the four spell-tutorial location checks.
    // Fires CHECK_SPELL the tick after harry.CurrSpellLesson transitions from
    // a valid lesson to None — which vanilla `harry.EndSpellLearning()` does
    // inside `SpellLessonTrigger.EndLesson()` (uc:842-879), right after
    // `AddToSpellBook(...)` and before the teleport-to-challenge-level event.
    // The transition is what the player perceives as "minigame finished".
    //
    // When AP has already granted the spell (e.g. start_inventory_from_pool),
    // the IsInSpellBook poll below cannot fire on the lesson because there's no
    // not-having → having transition. Detecting the CurrSpellLesson clear is
    // independent of spell ownership, so this hook still fires the check.
    //
    // Class-default InLessonForSpell[] is set every tick the lesson is
    // active; the next tick CurrSpellLesson is None we fire + clear. Storing
    // class-default lets the transition span the watcher death between the
    // classroom level and the challenge level — the new watcher inherits
    // InLessonForSpell[i] = 1 and fires there if it missed the transition
    // before the level change.
    if (HarryRef.CurrSpellLesson != None)
    {
        i = LessonShapeToSpellIndex(HarryRef.CurrSpellLesson);
        if (i >= 0)
        {
            default.InLessonForSpell[i] = 1;
        }
    }
    else
    {
        for (i = 0; i < NUM_SPELLS; i++)
        {
            if (default.InLessonForSpell[i] == 0) continue;
            default.InLessonForSpell[i] = 0;
            if (default.LessonCheckFired[i] == 1) continue;
            default.LessonCheckFired[i] = 1;
            // Mark WasSpellOwned baseline so the IsInSpellBook poll below
            // doesn't re-fire CHECK_SPELL for the same spell on this same
            // tick (vanilla AddToSpellBook in EndLesson sets IsInSpellBook
            // True simultaneously with CurrSpellLesson going None). Revert
            // path still runs because it's outside the WasSpellOwned guard.
            WasSpellOwned[i] = 1;
            Log("[Archipelago] APCardWatcher: SpellLessonTrigger ended for " $ SpellNames[i] $ " - firing CHECK_SPELL (lesson-end hook)");
            if (ipc != None)
            {
                ipc.SendCheckSpell(SpellNames[i]);
            }
        }
    }

    // Ch7Gryffindor's TriggerTurnOnAllSpells sets harry.bNoSpellBookCheck=
    // True, which makes IsInSpellBook return True for EVERY spell
    // (harry.uc:568) — the revert loop below could then never clear a spell
    // and the player keeps full casting. APGameInfo.InitGame destroys the
    // actor before it can fire on the normal entry path; clearing the flag
    // here every tick also covers a save reloaded inside the room (save-load
    // skips InitGame) or any other re-set. Guarded so it only acts/logs when
    // actually set. Open-castle-only; vanilla never enters this level.
    if (default.bOpenCastleMode == 1 && HarryRef.bNoSpellBookCheck
        && Caps(string(Level.Outer.Name)) == "CH7GRYFFINDOR")
    {
        HarryRef.bNoSpellBookCheck = False;
        Log("[Archipelago] APCardWatcher: cleared harry.bNoSpellBookCheck in CH7GRYFFINDOR (open castle)");
    }

    for (i = 0; i < NUM_SPELLS; i++)
    {
        // Forgetfulness Trap active: the spellbook is intentionally emptied
        // (or being restored this very tick by TrapTick). Skip the per-tick
        // vanilla-spell reconciliation entirely so the trap and the revert
        // don't fight; TrapTick owns restore (timer or level change). break
        // (not continue) — when active, none of the 7 are reconciled.
        if (default.bSpellTrapActive == 1)
        {
            break;
        }
        if (APGrantedSpell[i] == 1)
        {
            continue;
        }
        if (HarryRef.IsInSpellBook(SpellClasses[i].default.SpellType))
        {
            if (WasSpellOwned[i] == 0)
            {
                WasSpellOwned[i] = 1;
                default.LessonCheckFired[i] = 1;
                Log("[Archipelago] APCardWatcher: new vanilla spell learned: " $ SpellNames[i]);
                if (ipc != None)
                {
                    ipc.SendCheckSpell(SpellNames[i]);
                }
            }
            // Gate the wipe on the durable resync. Until the client has had a
            // chance to re-assert this slot's AP-granted spells (RESYNC_SPELLS,
            // sent on every Connected), assume an in-spellbook spell is one we
            // can't yet classify — a late client connect / save-load that
            // dropped APGrantedSpell would otherwise wipe legitimate AP grants
            // and never recover (the client's consumed_indices ledger blocks
            // re-forwarding). Once resync arrives, APGrantedSpell is the source
            // of truth and the wipe runs as before.
            if (default.bResyncReceived == 1)
            {
                HarryRef.SpellBook[SpellClasses[i].default.SpellType] = None;
                Log("[Archipelago] APCardWatcher: reverted vanilla " $ SpellNames[i]);
            }
        }
    }

    for (i = 0; i < NUM_KEY_ITEMS; i++)
    {
        if (WasKeyItemOwned[i] == 0 && HasKeyItem(i))
        {
            WasKeyItemOwned[i] = 1;
            Log("[Archipelago] APCardWatcher: new key item: " $ KeyItemNames[i]);
            if (ipc != None)
            {
                ipc.SendCheckKeyItem(KeyItemNames[i]);
            }
        }
    }

    // Spell-cast chat flavor. baseWand.LastCastedSpell is set on
    // every successful cast (baseWand.uc:391/463) and survives spell death
    // (SubtractFromCastedSpellList never clears it), so its reference
    // identity changing since the last 0.25s tick is a reliable "≥1 new
    // cast happened" signal — NumCastedSpells is non-monotonic and unread.
    // Store-then-compare prevents a double-fire; re-arm to None when the
    // casted list drains so the next cast of the same spell still triggers.
    // The wand is None during cutscene/menu (guarded). Duel/boss/sword
    // casts also reach here but SpellIndexForClass returns -1 for them.
    wand = baseWand(HarryRef.Weapon);
    if (wand != None)
    {
        cur = wand.LastCastedSpell;
        if (cur != None && cur != LastSeenCastedSpell)
        {
            LastSeenCastedSpell = cur;
            idx = SpellIndexForClass(cur.Class);
            if (idx >= 0) MaybeSaySpellCast(idx);
        }
        else if (cur == None)
        {
            LastSeenCastedSpell = None;
        }
    }

    // Clause-3 Mechanism A: getting the Boomslang / Bicorn / BitOGoyle key
    // item IS finishing that level (KeyItemStatus index i == objective idx
    // i: 0 Boomslang, 1 Bicorn, 2 Goyle). Outside the WasKeyItemOwned
    // transition guard above so it also catches the already-owned-at-snapshot
    // case; NotifyLevelObjective dedupes on the sticky GoalLevelDone bit.
    for (i = 0; i < NUM_KEY_ITEMS; i++)
    {
        if (HasKeyItem(i))
        {
            class'APCardWatcher'.static.NotifyLevelObjective(i);
        }
    }

    // Open castle Great Hall key: the first tick every enabled clause passes, open
    // the bookcase and arm the goal. WasGoalUnlocked is sticky class-default
    // so it survives level transitions / save-load and never re-locks; the
    // spawn helper early-returns on it so the bookcase never respawns.
    if (default.bOpenCastleMode == 1 && default.bGoalConfigured == 1
        && default.WasGoalUnlocked == 0 && GoalSatisfied())
    {
        default.WasGoalUnlocked = 1;
        Log("[Archipelago] APCardWatcher: open castle goal clauses satisfied - opening Great Hall");
        gi = APGameInfo(Level.Game);
        if (gi != None) gi.RemoveOpenCastleGreatHallBlocker();
    }

    // M7 goal detection: poll FEBook.bInEndGame, set True by ShowCredits()
    // (FEBook.uc:1392) when the post-Basilisk credits cutscene runs. Access
    // pattern mirrors harry.uc:5582 / harry.uc:339 — go through the live
    // gameplay UWorld's HPConsole to reach the active menuBook (HarryRef's
    // own .menuBook field can be stale; the explicit lookup is known-good).
    // One-shot: WasInEndGame guards re-fire. Null-check Player/Console/menuBook
    // because they can briefly be None during level loads. In open castle the fire
    // is gated on WasGoalUnlocked so the open-castle Great Hall can't complete
    // the seed before the 5-clause goal is met (vanilla: unchanged).
    if (WasInEndGame == 0 && HarryRef.Player != None
        && (default.bOpenCastleMode == 0 || default.WasGoalUnlocked == 1))
    {
        console = HPConsole(HarryRef.Player.Console);
        if (console != None)
        {
            book = console.menuBook;
            if (book != None && book.bInEndGame)
            {
                WasInEndGame = 1;
                Log("[Archipelago] APCardWatcher: bInEndGame transitioned True - firing GOAL_COMPLETE");
                if (ipc != None)
                {
                    ipc.SendGoalComplete();
                }
            }
        }
    }

    // Story-progression watcher. harry.iGameState is the canonical numeric
    // story state (set via SetGameState from cutscene `ChangeGameState <n>`
    // commands; mirrors the trailing digits of HarryRef.CurrentGameState).
    // Drives the Spongify blocker spawn (gated by APGameInfo.SpongifyGameStateGate),
    // and the log line is also general-purpose telemetry for any future
    // story-state-gated mod logic. One line per transition — quiet otherwise.
    if (HarryRef.iGameState != LastGameState)
    {
        Log("[Archipelago] APCardWatcher: iGameState " $ LastGameState $ " -> " $ HarryRef.iGameState $ " (CurrentGameState='" $ HarryRef.CurrentGameState $ "')");
        LastGameState = HarryRef.iGameState;
        // The Spongify blocker is gated on iGameState; re-attempt the spawn
        // pass on every transition so it appears the moment Harry crosses
        // SpongifyGameStateGate without waiting for a level reload.
        // Other blockers are idempotent (tag-scan no-op) so the redundant
        // calls are harmless.
        TrySpawnClassroomBlockers();
        // Several cards have strVendorOwnedAfterGState gates (e.g. GSTATE150
        // for WCFancourt). Re-run the assignment pass so cards become
        // vendor-available the moment their gate opens, without waiting for
        // a level reload.
        AssignMarkersToVendors();
    }

    // A genuine new game climbs gstate 0 -> ... -> 180 through the intro, so
    // the persistent singleton observes a sub-Great-Hall value before 180.
    // Loading a save already at/after 180 never does — and a loaded game
    // inherently has a save, so the safety net is moot there. Recording this
    // on the singleton is what scopes the save to new games only.
    if (ipc != None && HarryRef.iGameState < STARTUP_SAFETY_SAVE_GAMESTATE)
    {
        ipc.bSawStateBelowGreatHall = True;
    }

    // Durable-ledger new-game signal. Both vanilla and open castle start a genuine
    // new game at iGameState 0 and climb; a loaded save resumes at its saved
    // gstate and never re-observes 0. So iGameState==0 ⇒ genuine new game →
    // tell the client to wipe its AP-Data-Storage consumed-index ledger so the
    // fresh playthrough re-receives every item. One-shot via the singleton
    // latch; re-armed once gstate climbs > 0 so a later new game in the same
    // process signals again. NOT pinned to the open-castle-only 180 threshold.
    if (ipc != None && HarryRef.iGameState == 0)
    {
        if (!ipc.bNewGameSignalled)
        {
            ipc.SendNewGame();
            ipc.bNewGameSignalled = True;
        }
    }
    else if (ipc != None && HarryRef.iGameState > 0)
    {
        ipc.bNewGameSignalled = False;
    }

    // One-time startup safety save. Vanilla guarantees a recoverable save
    // around the opening (a SmartStart bDoLevelSave on the first level
    // transition), so quitting right after gaining control still leaves a
    // save; the AP open-castle flow can bypass that transition. Mirror the
    // intent: the first time the player actually holds control at or after
    // the Great Hall arrival state (reached in both modes), write the
    // autosave once. Both flags live on the persistent singleton so it fires
    // once per process, not once per level — this watcher re-spawns each
    // level. bSawStateBelowGreatHall scopes it to new games (a load into a
    // >=180 save already has a save, and re-saving there is a needless hitch
    // every load). gstate crosses STARTUP_SAFETY_SAVE_GAMESTATE during the
    // arrival cutscene, before control returns, so this is a per-tick retry
    // (not gated on the transition above) until a safe tick: alive,
    // PlayerWalking, no cutscene/menu — exactly IsPlayerInPlayableState.
    if (ipc != None && !ipc.bStartupSafetySaveDone && ipc.bSawStateBelowGreatHall
        && HarryRef.iGameState >= STARTUP_SAFETY_SAVE_GAMESTATE)
    {
        saveHarry = harry(Level.PlayerHarryActor);
        if (saveHarry != None && saveHarry.GetHealthCount() > 0
            && class'APGameInfo'.static.IsPlayerInPlayableState(saveHarry, deferReason))
        {
            ipc.bStartupSafetySaveDone = True;
            Log("[Archipelago] APCardWatcher: startup safety save (iGameState=" $ HarryRef.iGameState $ ")");
            saveHarry.SaveGame();
        }
    }

    // Guarantee a rendering toast actor before any toast consumer
    // (connection / received / sent) resolves one via GetInstance(): on a
    // save-load the toast is a stale cross-package actor that never renders.
    EnsureFreshToast();

    // "Connected to host:port" startup toast, delayed ~1s after the first
    // playable tick the AP address is known (delivered over the sticky
    // CONNECTED IPC line) so it doesn't pop the instant control returns.
    // bConnToastShown is compiled-default 0 every launch, so a fresh launch
    // shows it once; an area/level transition can't (the latch survives as a
    // class-default); a save-load re-arms it in EnsureFreshToast when it
    // replaces the deserialized toast. Mode-agnostic and NOT gated on the
    // safety-save's STARTUP_SAFETY_SAVE_GAMESTATE — first IsPlayerInPlayableState is
    // Whomping Willow (vanilla) / Entry Hall (open castle). If the client isn't
    // AP-connected yet ConnectedAddress is "" and this stays a no-op until it
    // arrives. Same alive/playable guard shape as the safety save above gates
    // only the SCHEDULE; the countdown then fires regardless of state (the
    // toast renders during cutscenes anyway) so a cutscene that triggers
    // inside the 1s window can't strand it.
    if (default.bConnToastShown == 0 && default.ConnectedAddress != "")
    {
        if (default.bConnToastScheduled == 0)
        {
            saveHarry = harry(Level.PlayerHarryActor);
            if (saveHarry != None && saveHarry.GetHealthCount() > 0
                && class'APGameInfo'.static.IsPlayerInPlayableState(saveHarry, deferReason))
            {
                default.bConnToastScheduled = 1;
                default.ConnToastTicksLeft = CONN_TOAST_DELAY_TICKS;
            }
        }
        else
        {
            default.ConnToastTicksLeft -= 1;
            if (default.ConnToastTicksLeft <= 0)
            {
                connToast = class'APHUDToast'.static.GetInstance();
                if (connToast != None)
                {
                    connToast.EnqueueToast("Connected to " $ default.ConnectedAddress);
                    default.bConnToastShown = 1;
                    default.bConnToastScheduled = 0;
                    Log("[Archipelago] APCardWatcher: connection toast shown ('"
                        $ default.ConnectedAddress $ "')");
                }
            }
        }
    }

    // Seed/install mismatch warning. Fires when the seed's declared mode
    // (SeedDeclaredMode, from the client's MODE line) disagrees with what the
    // install physically is (bInstallIsOpenCastle, from the MGBingo probe).
    // Both are sticky class-defaults so they survive the per-level respawn;
    // bModeMismatchToastShown is a plain INSTANCE var (compiled-0 on each fresh
    // per-level watcher), so the warning re-shows once per level until the
    // player runs the matching install. Same delayed/playable guard shape as
    // the connection toast so it doesn't pop mid-cutscene or before control
    // returns. A mismatched seed is at best un-completable (see the analysis in
    // the design notes), hence the loud, repeating warning rather than a silent
    // failure.
    if (default.bInstallProbed == 1 && default.SeedDeclaredMode != 0
        && bModeMismatchToastShown == 0)
    {
        seedIsOpenCastle = (default.SeedDeclaredMode == 2);
        if (seedIsOpenCastle != (default.bInstallIsOpenCastle == 1))
        {
            saveHarry = harry(Level.PlayerHarryActor);
            if (saveHarry != None && saveHarry.GetHealthCount() > 0
                && class'APGameInfo'.static.IsPlayerInPlayableState(saveHarry, deferReason))
            {
                connToast = class'APHUDToast'.static.GetInstance();
                if (connToast != None)
                {
                    if (seedIsOpenCastle)
                    {
                        connToast.EnqueueToast("AP: WRONG INSTALL - open castle seed on vanilla maps!");
                    }
                    else
                    {
                        connToast.EnqueueToast("AP: WRONG INSTALL - vanilla seed on open castle maps!");
                    }
                    bModeMismatchToastShown = 1;
                    Log("[Archipelago] APCardWatcher: mode mismatch toast shown (seed="
                        $ default.SeedDeclaredMode $ " installOpenCastle="
                        $ default.bInstallIsOpenCastle $ ")");
                }
            }
        }
    }

    if (siBronze.nCount != LastBronzeCount || siSilver.nCount != LastSilverCount || siGold.nCount != LastGoldCount)
    {
        Log("[Archipelago] APCardWatcher: nCount CHANGE - Bronze=" $ siBronze.nCount $ " Silver=" $ siSilver.nCount $ " Gold=" $ siGold.nCount $ " (was " $ LastBronzeCount $ "/" $ LastSilverCount $ "/" $ LastGoldCount $ ")");
        LastBronzeCount = siBronze.nCount;
        LastSilverCount = siSilver.nCount;
        LastGoldCount   = siGold.nCount;
    }
    // #3: one convergence sweep per level once the table is present. Covers
    // the case where the table was already sticky at level start but markers
    // (e.g. lazily-spawned vendor markers) registered after Snapshot's sweep.
    // Async mid-level arrival is handled separately by the APPEARANCE-IPC
    // sweep in APIPCActor; per-marker immediate morphs by their self-apply.
    if (default.bAppearanceReceived == 1 && bAppearanceRestampedThisLevel == 0)
    {
        RestampMarkerAppearance();
        bAppearanceRestampedThisLevel = 1;
    }

    HeartbeatCounter++;
    if (HeartbeatCounter >= 40)
    {
        HeartbeatCounter = 0;
        Log("[Archipelago] APCardWatcher: nCount heartbeat - Bronze=" $ siBronze.nCount $ " Silver=" $ siSilver.nCount $ " Gold=" $ siGold.nCount);
    }
}

// Phase C of vendor support: mirror vanilla `AssignVendorCards` for our
// markers. Vanilla iterates chest `EjectedObjects[]` / loose `WizardCardIcon`
// actors and reads `slotClass.Default.Id` + `slotClass.Default.bVendorsCanSell`
// to decide whether to assign the card to a vendor. Our markers have
// `Default.Id=200` (sentinel for vanilla bean-swap immunity, can't change),
// so vanilla's lookup writes vendor ownership for nonexistent id 200 — no-op.
// We re-do the pass with the marker's real `CardLocationId` and the per-card
// `bVendorsCanSell` / `strVendorOwnedAfterGState` defaults that the codegen
// copies from each WCXxx vanilla class. Result: cards left behind in any
// level (replayable or not) become available at vendors once their game-state
// gate has passed, mirroring vanilla's recovery path. Skips locations already
// AP-checked (handled by ClearVendorOwnershipForLocation in Phase A).
function AssignMarkersToVendors()
{
    local chestbronze chest;
    local bronzecauldron cauldron;
    local APCardMarker marker;
    local int i;
    local int assigned;

    // Phase C is vanilla-only missed-card recovery. In open castle every level is
    // infinitely replayable, so a card left behind is never lost — assigning
    // it to a vendor instead lets the player buy cards for levels they have
    // not even reached. Flip the pass into a cleanup so vendors never stock
    // cards in open castle. Covers every caller (iGameState transition + snapshot).
    if (default.bOpenCastleMode == 1)
    {
        ClearAllVendorOwnership();
        return;
    }

    assigned = 0;

    foreach AllActors(class'chestbronze', chest)
    {
        for (i = 0; i < ArrayCount(chest.EjectedObjects); i++)
        {
            if (chest.EjectedObjects[i] != None
                && ClassIsChildOf(chest.EjectedObjects[i], class'APCardMarker'))
            {
                if (TryAssignMarkerClassToVendor(class<APCardMarker>(chest.EjectedObjects[i])))
                {
                    assigned++;
                }
            }
        }
    }

    foreach AllActors(class'bronzecauldron', cauldron)
    {
        for (i = 0; i < ArrayCount(cauldron.EjectedObjects); i++)
        {
            if (cauldron.EjectedObjects[i] != None
                && ClassIsChildOf(cauldron.EjectedObjects[i], class'APCardMarker'))
            {
                if (TryAssignMarkerClassToVendor(class<APCardMarker>(cauldron.EjectedObjects[i])))
                {
                    assigned++;
                }
            }
        }
    }

    foreach AllActors(class'APCardMarker', marker)
    {
        if (TryAssignMarkerClassToVendor(marker.Class))
        {
            assigned++;
        }
    }

    // Level-independent backstop: the actor passes above only see markers in
    // the current level, so a card missed in a one-time area (Dumbledore's
    // Study, Slytherin Common Room) never enters the vendor pool because its
    // marker actor is never loaded again. Walk every card id directly so the
    // gstate gate stamps the missed card the moment iGameState crosses it,
    // regardless of which level Harry is in.
    assigned += StampUnownedCardsToVendorByIdWalk();

    if (assigned > 0)
    {
        Log("[Archipelago] APCardWatcher.AssignMarkersToVendors: assigned " $ assigned $ " marker location(s) to vendor stock");
    }
}

// Walk card ids 1..MAX_CARD_ID and call TryAssignMarkerClassToVendor for each,
// resolving the marker class via DynamicLoadObject on the vanilla card class
// name (the APCardMarker_<WCClass> naming contract codegen guarantees).
// Returns the number of cards that transitioned to vendor ownership.
function int StampUnownedCardsToVendorByIdWalk()
{
    local class<APCardMarker> markerCls;
    local class<Actor> wcClass;
    local int id, assigned;

    if (siBronze == None) return 0;

    assigned = 0;
    for (id = 1; id <= MAX_CARD_ID; id++)
    {
        wcClass = siBronze.GetCardClassFromId(id);
        if (wcClass == None) continue;
        markerCls = class<APCardMarker>(DynamicLoadObject(
            "HPArchipelago.APCardMarker_" $ string(wcClass.Name), class'Class'));
        if (markerCls == None) continue;
        if (TryAssignMarkerClassToVendor(markerCls)) assigned++;
    }
    return assigned;
}

// Helper for AssignMarkersToVendors. Returns True if it just transitioned the
// card into vendor ownership (for log accounting). Skips:
//   - markers whose Default.bVendorsCanSell is False (vanilla per-card opt-in)
//   - markers whose location is already AP-checked
//   - markers whose strVendorOwnedAfterGState gate hasn't passed yet
//   - markers whose card is already CardOwner_Harry or CardOwner_Vendor
function bool TryAssignMarkerClassToVendor(class<APCardMarker> markerCls)
{
    local int id;
    local string strState;
    local int gateState;

    if (markerCls == None) return False;
    id = markerCls.default.CardLocationId;
    if (id <= 0 || id > MAX_CARD_ID) return False;
    if (default.LocationChecked[id] == 1) return False;
    if (!markerCls.default.bVendorsCanSell) return False;

    strState = markerCls.default.strVendorOwnedAfterGState;
    if (strState != "")
    {
        gateState = int(Right(strState, 3));
        if (HarryRef == None || HarryRef.iGameState < gateState) return False;
    }

    if (markerCls.default.MarkerTier == "Bronze")
    {
        if (siBronze != None
            && siBronze.GetCardOwner(id) != siBronze.ECardOwner.CardOwner_Harry
            && siBronze.GetCardOwner(id) != siBronze.ECardOwner.CardOwner_Vendor)
        {
            siBronze.SetCardOwner(id, siBronze.ECardOwner.CardOwner_Vendor);
            Log("[Archipelago] AssignMarker: Bronze[" $ id $ "] -> Vendor (class=" $ string(markerCls.Name) $ ")");
            return True;
        }
    }
    else if (markerCls.default.MarkerTier == "Silver")
    {
        if (siSilver != None
            && siSilver.GetCardOwner(id) != siSilver.ECardOwner.CardOwner_Harry
            && siSilver.GetCardOwner(id) != siSilver.ECardOwner.CardOwner_Vendor)
        {
            siSilver.SetCardOwner(id, siSilver.ECardOwner.CardOwner_Vendor);
            Log("[Archipelago] AssignMarker: Silver[" $ id $ "] -> Vendor (class=" $ string(markerCls.Name) $ ")");
            return True;
        }
    }
    // Gold tier intentionally not handled — gold cards are non-sellable in
    // vanilla (all 11 have bVendorsCanSell=False and are filtered out above).
    return False;
}

// Phase B of vendor support: when a vendor's `MakePurchase` spawns a vanilla
// `WCXxx` actor (`Characters.uc:646`), replace it with the corresponding
// APCardMarker_<class> on the next watcher tick. The marker's clean Touch
// path then fires CHECK + Destroy without going through vanilla's
// SetCardOwner(Harry) (which would briefly show the card in the album before
// our revert logic clears it).
//
// Race window: 0-0.25s between vendor spawn and our replacement. Vendor cards
// arc-bounce for ~1-2s before they're pickup-able, so the player almost
// never beats the swap. If they do, the watcher's existing IsHarryOwned
// polling path catches it as a fallback (CHECK still fires, just with the
// album flicker).
//
// Skips actors that are already APCardMarker subclasses (idempotent), have
// id 0 / out-of-range, or have an unknown class (no marker subclass for
// this card type — leave alone, fallback path will still work). For
// already-checked locations, destroys the vanilla wci with no replacement
// (mirrors the chest-loose-icon path in ReplaceCardChests).
function ReplaceVendorSpawnedCards()
{
    local WizardCardIcon wci;
    local class<Actor> markerClass;
    local Vector spawnLoc;
    local Rotator spawnRot;
    local Actor spawned;
    local int id;
    local int replacedCount;

    replacedCount = 0;
    foreach AllActors(class'WizardCardIcon', wci)
    {
        if (ClassIsChildOf(wci.Class, class'APCardMarker'))
        {
            continue;
        }
        // A Tradersanity marker is a WizardCardIcon child but not a card
        // check; Id=200 already makes the range guard below skip it, this is
        // the explicit belt so intent is local to this loop.
        if (ClassIsChildOf(wci.Class, class'APVendorMarker_Trader'))
        {
            continue;
        }
        id = wci.Id;
        if (id <= 0 || id > MAX_CARD_ID)
        {
            continue;
        }
        if (default.LocationChecked[id] == 1)
        {
            Log("[Archipelago] APCardWatcher.ReplaceVendorSpawnedCards: vendor card id=" $ id $ " is already AP-checked - destroying vanilla wci with no replacement");
            wci.Destroy();
            replacedCount++;
            continue;
        }
        markerClass = class<Actor>(DynamicLoadObject("HPArchipelago.APCardMarker_" $ string(wci.Class.Name), class'Class'));
        if (markerClass == None)
        {
            continue;
        }
        spawnLoc = wci.Location;
        spawnRot = wci.Rotation;
        Log("[Archipelago] APCardWatcher.ReplaceVendorSpawnedCards: replacing vanilla " $ string(wci.Class.Name) $ " (id=" $ id $ ") at " $ string(spawnLoc) $ " with " $ string(markerClass));
        wci.Destroy();
        spawned = Spawn(markerClass, , , spawnLoc, spawnRot);
        if (spawned == None)
        {
            Log("[Archipelago] APCardWatcher.ReplaceVendorSpawnedCards: Spawn returned None for " $ string(markerClass) $ " at " $ string(spawnLoc));
            continue;
        }
        // Vendor-spawned markers are ephemeral, not design-time placements,
        // so do NOT call MarkAsLoose (which would keep bPersistent=True and
        // make the marker survive level exit, leading to ghost-stacking when
        // the player buys the same card twice). Set bPersistent=False
        // immediately to close the 0.05s race window before the marker's own
        // Timer event runs.
        spawned.bPersistent = False;
        replacedCount++;
    }
    if (replacedCount > 0)
    {
        Log("[Archipelago] APCardWatcher.ReplaceVendorSpawnedCards: replaced/destroyed " $ replacedCount $ " loose vanilla card(s) (vendor-spawned)");
    }
}

// Maps a SpellLessonTrigger.LessonShape enum value to our SpellNames[] index.
// Returns -1 for unrecognized shapes. Compared via the enum's ELessonShape
// member rather than int casts so the mapping survives any future enum
// reordering. Index mapping mirrors APCardWatcher.PreBeginPlay's SpellNames[].
function int LessonShapeToSpellIndex(SpellLessonTrigger lesson)
{
    if (lesson == None) return -1;
    if (lesson.LessonShape == lesson.ELessonShape.LessonShape_Rictusempra) return 4;
    if (lesson.LessonShape == lesson.ELessonShape.LessonShape_Skurge)      return 5;
    if (lesson.LessonShape == lesson.ELessonShape.LessonShape_Diffindo)    return 1;
    if (lesson.LessonShape == lesson.ELessonShape.LessonShape_Spongify)    return 6;
    return -1;
}

// Reverse of the SpellClasses[]/SpellNames[] table — maps a live
// baseSpell's class back to its 0..NUM_SPELLS-1 index, or -1 for any non-AP
// spell (duel / boss / sword-fire casts also flow through CastSpell ->
// AddToCastedSpellList but must not post chat). Same single-source table the
// learn-poll uses, so the 7-spell scope can never drift.
function int SpellIndexForClass(class<baseSpell> c)
{
    local int i;

    if (c == None) return -1;
    for (i = 0; i < NUM_SPELLS; i++)
    {
        if (SpellClasses[i] == c) return i;
    }
    return -1;
}

// A detected cast of one of the 7 AP spells gets a rate-limited
// ~1/100 roll; on success ship the bare ASCII spell name over SAY and let
// Python own all flavor text (unicode/emoticons). FRand() is the codebase
// RNG idiom (cf. baseWand.Finish). The 5s NextSpellSayEarliest floor caps a
// lucky streak independently of the 0.25s poll coalescing rapid casts.
function MaybeSaySpellCast(int idx)
{
    local APIPCActor ipc;

    if (idx < 0 || idx >= NUM_SPELLS) return;
    if (Level.TimeSeconds < NextSpellSayEarliest) return;
    if (FRand() >= SaySpellChance) return;
    NextSpellSayEarliest = Level.TimeSeconds + 5.0;
    ipc = class'APIPCActor'.static.GetInstance();
    if (ipc == None) return;
    ipc.SendSay(SpellNames[idx]);
    Log("[Archipelago] APCardWatcher: spell-cast flavor roll hit for " $ SpellNames[idx] $ " - sent SAY");
}

function bool Bind()
{
    local StatusGroupWizardCards sg;
    local harry candidate;

    candidate = class'APGameInfo'.static.FindActiveHarry(self);
    if (candidate == None)
    {
        return False;
    }
    if (HarryRef != candidate)
    {
        Log("[Archipelago] APCardWatcher: rebinding harry " $ string(HarryRef) $ " -> " $ string(candidate));
        HarryRef = candidate;
    }
    if (HarryRef.managerStatus == None)
    {
        return False;
    }

    sg = StatusGroupWizardCards(HarryRef.managerStatus.GetStatusGroup(class'StatusGroupWizardCards'));
    if (sg == None)
    {
        return False;
    }

    siBronze = StatusItemWizardCards(sg.GetStatusItem(class'StatusItemBronzeCards'));
    siSilver = StatusItemWizardCards(sg.GetStatusItem(class'StatusItemSilverCards'));
    siGold   = StatusItemWizardCards(sg.GetStatusItem(class'StatusItemGoldCards'));

    if (siBronze == None || siSilver == None || siGold == None)
    {
        return False;
    }

    KeyItemStatus[0] = HarryRef.managerStatus.GetStatusItem(class'StatusGroupPolyIngr', class'StatusItemBoomslang');
    KeyItemStatus[1] = HarryRef.managerStatus.GetStatusItem(class'StatusGroupPolyIngr', class'StatusItemBicorn');
    KeyItemStatus[2] = HarryRef.managerStatus.GetStatusItem(class'StatusGroupPolyIngr', class'StatusItemBitOGoyle');
    if (KeyItemStatus[2] == None)
    {
        KeyItemStatus[2] = HarryRef.managerStatus.GetStatusItem(class'StatusGroupPotionIngr', class'StatusItemBitOGoyle');
    }
    Log("[Archipelago] APCardWatcher: bound key items - Boomslang=" $ string(KeyItemStatus[0])
        $ " Bicorn=" $ string(KeyItemStatus[1]) $ " BitOGoyle=" $ string(KeyItemStatus[2]));

    // Suppress the vanilla first-trade narrator line ("Press on the Yes
    // button to accept the trade, or the No button to decline."):
    // VendorManager.WantInstructions() gates it on this travel flag, so
    // pre-setting it sends card/trader vendors straight to the transaction.
    // Duel vendors keep their own instruction (the IsDuelVendor clause).
    // Re-asserted every bind so a fresh save never shows it.
    HarryRef.bSaidVendorInstructions = True;

    Log("[Archipelago] APCardWatcher: bound to Harry's status items");
    return True;
}

function bool HasLivePlayerHarry()
{
    local harry h;

    if (HarryRef != None && HarryRef.Player != None && !HarryRef.bDeleteMe)
    {
        return True;
    }

    h = harry(Level.PlayerHarryActor);
    if (h != None && h.Player != None && !h.bDeleteMe)
    {
        return True;
    }

    return False;
}

// Guarantee a rendering APHUDToast in the live harry's level before any toast
// consumer (connection / received / sent) resolves one via GetInstance().
// Runs every snapshotted-LatestInstance Timer tick. A toast deserialized from
// a .usa is a private actor of the save's original package, so its Level is
// that stale LevelInfo, never the loaded level's — it never renders. M212
// does not honor `transient`, so the only reliable "stale" signal is the
// Level mismatch; replace on it. Idempotent: an InitGame-spawned toast is
// already in the live level (new game / area transition), so this returns
// immediately and never re-arms there. A replace only happens on a save-load
// (the sole source of a cross-package toast), which is where the connection
// toast re-arms so the loaded game re-shows "Connected to host:port".
function EnsureFreshToast()
{
    local APHUDToast existing;
    local harry h;

    h = harry(Level.PlayerHarryActor);
    if (h == None)
    {
        return;
    }

    existing = class'APHUDToast'.static.GetInstance();
    if (existing != None && existing.Level == h.Level)
    {
        return;
    }

    if (existing != None)
    {
        existing.Destroy();
    }
    if (h.Spawn(class'APHUDToast') == None)
    {
        Log("[Archipelago] APCardWatcher.EnsureFreshToast: Spawn(APHUDToast) FAILED");
        return;
    }
    Log("[Archipelago] APCardWatcher.EnsureFreshToast: replaced stale toast - fresh APHUDToast in " $ string(h.Level));

    default.bConnToastShown = 0;
    default.bConnToastScheduled = 0;
}

function TrySpawnClassroomBlockers()
{
    local APGameInfo gi;
    gi = APGameInfo(Level.Game);
    if (gi == None)
    {
        Log("[Archipelago] APCardWatcher: can't spawn classroom blockers - Level.Game is not APGameInfo");
        return;
    }
    gi.BlockRictaClassroomIfMissing();
    gi.BlockSkurgeClassroomIfMissing();
    gi.BlockDiffindoClassroomIfMissing();
    gi.BlockSpongifyClassroomIfMissing();
    gi.SpawnAllOpenCastleBlockers();
    // Re-apply per-level so save-load (which skips APGameInfo.InitGame)
    // still gets cutscene skip policy enforced for the freshly-loaded level.
    gi.ForceCutScenesSkippable();
    // APHUDToast is per-level; save-load needs it spawned here since
    // APGameInfo.InitGame doesn't run on that path.
    gi.SpawnAPHUDToastIfMissing();
}

function EnsureLatestRegistration()
{
    local APCardWatcher current;

    current = default.LatestInstance;
    if (current == self)
    {
        return;
    }

    if (current == None || current.bDeleteMe)
    {
        default.LatestInstance = self;
        // A watcher restored from a .usa save can come back with
        // bSnapshotted=True but stale/zeroed APGrantedSpell[] (e.g. when the
        // class layout differs between save creation and load). That makes the
        // next Timer skip Bind+Snapshot and run the revert path, wiping any
        // AP-granted spells the save preserved in HarryRef.SpellBook[]. Forcing
        // a re-snapshot here re-baselines APGrantedSpell from the live
        // spellbook before the revert path can fire.
        bSnapshotted = False;
        Log("[Archipelago] APCardWatcher: restored LatestInstance -> self (was empty/stale, re-snapshotting)");
        // ProcessServerTravel skips APGameInfo.InitGame, so the classroom
        // blockers won't have been spawned for this level entry. Spawn them
        // now — the Block* functions are idempotent via a tag-scan guard,
        // so calling them here in addition to InitGame can't double-spawn.
        TrySpawnClassroomBlockers();
        return;
    }

    if (HasLivePlayerHarry() && !current.HasLivePlayerHarry())
    {
        default.LatestInstance = self;
        // Force a fresh Bind+Snapshot onto the live Harry. A watcher restored
        // from a .usa comes back with bSnapshotted=True bound to a stale/None
        // HarryRef; without this reset it would skip Bind+Snapshot and never
        // re-add the resync spells to the now-possessed pawn until the next
        // level load (the spell-loss-on-reload bug). Mirrors the empty/stale
        // branch above.
        bSnapshotted = False;
        Log("[Archipelago] APCardWatcher: promoted self to LatestInstance (self has live Player, current does not) - re-snapshotting");
    }
}

// One-way-sticky open-castle-mode transition, shared by every entry path (durable
// DLO probe, in-level MGBingo actor scan, IPC `MODE open_castle`). Static so the
// pre-Harry / pre-IPC callers (APGameInfo.InitGame, APCardWatcher.
// PreBeginPlay, APIPCActor) can enter open castle mode without a live instance;
// only touches class-defaults (each watcher mirrors them from its
// PreBeginPlay). On the FIRST transition it wipes stale default.APGrantedSpell
// so the open castle revert loop can't keep a prior vanilla-seed's precollected
// Lumos/Flipendo/Alohomora — the AP client's durable resync re-sets the flag
// over IPC for spells THIS seed grants. Idempotent: a second call (already
// open castle) is a no-op, so reconnect / save-load that already has AP-granted
// spells does NOT re-wipe them. bOpenCastleMode is never cleared (one-way).
static function EnterOpenCastleMode(string reason)
{
    local int i;

    if (default.bOpenCastleMode == 1) return;
    default.bOpenCastleMode = 1;
    Log("[Archipelago] APCardWatcher: entering open castle mode (sticky) - " $ reason);
    for (i = 0; i < NUM_SPELLS; i++)
    {
        default.APGrantedSpell[i] = 0;
    }
    Log("[Archipelago] APCardWatcher: reset APGrantedSpell[] (AP grants this session will re-set as they arrive)");
}

// Durable, level-independent open castle probe. The HP2 Bingo install is the only one
// that ships the MGBingo package; a soft DynamicLoadObject of its class
// returns non-None there and None on the vanilla/Modded install (MayFail=true
// → no error, no hard reference that would block HPArchipelago.u loading on
// vanilla). Works pre-Harry / pre-IPC and on a cold load into a sentinel-less
// level (e.g. Ch7Gryffindor) where the in-level actor scan misses. Callable
// from APGameInfo.InitGame / APCardWatcher.PreBeginPlay / APIPCActor.
// Probe what the INSTALL physically is, independent of the seed. The HP2 Bingo
// open-castle install is the only one shipping the MGBingo package; a soft
// DynamicLoadObject (MayFail=true → no error, no hard ref) returns non-None
// there and None on the vanilla/Modded install. Self-latching: runs the DLO
// once, then records the result in class-defaults that survive every level.
// Distinct from EnterOpenCastleMode so the install signal stays separable from
// the seed's "MODE open_castle" IPC line (which also sets bOpenCastleMode).
static function ProbeInstall()
{
    if (default.bInstallProbed == 1) return;
    default.bInstallProbed = 1;
    if (DynamicLoadObject("MGBingo.MGBingoLearnAllSpells", class'Class', true) != None)
    {
        default.bInstallIsOpenCastle = 1;
        Log("[Archipelago] APCardWatcher.ProbeInstall: install is open castle (MGBingo present)");
    }
    else
    {
        Log("[Archipelago] APCardWatcher.ProbeInstall: install is vanilla (MGBingo absent)");
    }
}

// Record the seed's declared game_mode from the client's "MODE <mode>" line.
// Positive in both modes (1 vanilla / 2 open castle) so Timer can compare it
// against ProbeInstall's result. Does NOT touch bOpenCastleMode — the caller
// latches that separately for "open_castle" only.
static function SetSeedDeclaredMode(string mode)
{
    if (mode == "open_castle") default.SeedDeclaredMode = 2;
    else if (mode == "vanilla") default.SeedDeclaredMode = 1;
}

static function EnsureOpenCastleModeDetected()
{
    // Always probe the install first — even when bOpenCastleMode is already 1
    // (e.g. the seed's IPC line set it on a vanilla install), the mismatch
    // check still needs the separate install signal recorded.
    ProbeInstall();
    if (default.bOpenCastleMode == 1) return;
    if (default.bInstallIsOpenCastle == 1)
    {
        EnterOpenCastleMode("DLO MGBingo package present");
    }
}

// Per-level call from Snapshot. Durable probe first (covers cold-load into
// sentinel-less levels), then an in-level MGBingoLearnAllSpells actor scan
// as a secondary fallback. IPC `MODE open_castle` is the late authoritative
// belt (APIPCActor). Mirrors the class-default flag/wipe onto this instance.
function DetectOpenCastleMode()
{
    local Actor a;
    local int i;

    if (default.bOpenCastleMode == 1) return;

    class'APCardWatcher'.static.EnsureOpenCastleModeDetected();
    if (default.bOpenCastleMode == 1)
    {
        bOpenCastleMode = 1;
        for (i = 0; i < NUM_SPELLS; i++) APGrantedSpell[i] = 0;
        return;
    }

    foreach AllActors(class'Actor', a)
    {
        if (string(a.Class.Name) == "MGBingoLearnAllSpells")
        {
            class'APCardWatcher'.static.EnterOpenCastleMode("found MGBingoLearnAllSpells actor in level");
            bOpenCastleMode = 1;
            for (i = 0; i < NUM_SPELLS; i++) APGrantedSpell[i] = 0;
            return;
        }
    }
}

function Snapshot()
{
    local int id, i, ownedCardCount, ownedSpellCount;

    ownedCardCount = 0;
    for (id = 1; id <= MAX_CARD_ID; id++)
    {
        if (IsHarryOwned(id))
        {
            WasOwnedByHarry[id] = 1;
            ownedCardCount++;
        }
    }
    Log("[Archipelago] APCardWatcher: initial snapshot - Harry already owns " $ ownedCardCount $ " cards");

    DetectOpenCastleMode();

    // Re-pull AP-grant flags from the class default in case ApplyResyncSpells
    // (or an ApplyGrant) fired between this watcher's PreBeginPlay copy and
    // Snapshot — that one-shot copy would otherwise leave instance stale and
    // the revert loop would wipe a spell the durable resync already covered.
    for (i = 0; i < NUM_SPELLS; i++)
    {
        if (default.APGrantedSpell[i] == 1)
        {
            APGrantedSpell[i] = 1;
        }
    }

    // Restore AP-granted spells the .usa save dropped (M212's per-level package
    // does not always preserve travel class refs for spells the level's import
    // table didn't natively need — exactly the spell-loss reload bug). The
    // durable resync ledger is the source of truth; re-add anything it marked.
    // AddToSpellBook is idempotent (slot-empty guard, harry.uc:556).
    if (default.bResyncReceived == 1)
    {
        for (i = 0; i < NUM_SPELLS; i++)
        {
            if (default.APGrantedSpell[i] == 1
                && !HarryRef.IsInSpellBook(SpellClasses[i].default.SpellType))
            {
                HarryRef.AddToSpellBookByString(SpellNames[i]);
                Log("[Archipelago] APCardWatcher.Snapshot: re-added AP-granted "
                    $ SpellNames[i] $ " from durable resync (was missing from spellbook)");
            }
        }
    }

    ownedSpellCount = 0;
    for (i = 0; i < NUM_SPELLS; i++)
    {
        if (HarryRef.IsInSpellBook(SpellClasses[i].default.SpellType))
        {
            // harry.PreBeginPlay (harry.uc:335-337) unconditionally adds
            // Flipendo/Lumos/Alohomora to every fresh Harry actor, and
            // open castle's MGBingo grants all 7. Neither is a player action,
            // so set WasSpellOwned[i] to suppress the "new vanilla spell learned"
            // CHECK_SPELL transition in the revert loop. APGrantedSpell stays
            // 0 — only true AP grants (ApplyGrant via IPC) set it. Spells the
            // user marked in starting_spells flow back over the durable resync;
            // anything else gets reverted on the next tick.
            WasSpellOwned[i] = 1;
            ownedSpellCount++;
        }
    }
    Log("[Archipelago] APCardWatcher: initial snapshot - Harry knows " $ ownedSpellCount $ " spells (will revert non-AP spells next tick)");

    for (i = 0; i < NUM_KEY_ITEMS; i++)
    {
        if (HasKeyItem(i))
        {
            WasKeyItemOwned[i] = 1;
        }
    }

    LastBronzeCount = siBronze.nCount;
    LastSilverCount = siSilver.nCount;
    LastGoldCount   = siGold.nCount;
    Log("[Archipelago] APCardWatcher: initial nCount snapshot - Bronze=" $ LastBronzeCount $ " Silver=" $ LastSilverCount $ " Gold=" $ LastGoldCount);

    // Vanilla AssignVendorCards (run during the level transition that brought
    // us here) just re-stamped CardOwner_Vendor on every silver/eligible card
    // including ones the player has already AP-checked. Re-clear them so the
    // vendors don't offer them.
    SweepVendorAssignments();
    // Then run our own marker-aware vendor-assignment pass so cards left in
    // chest/loose markers in this level become vendor-available (vanilla's
    // pass can't see our markers because of the Default.Id=200 sentinel).
    AssignMarkersToVendors();
    // Open-castle-only: destroy Ch7Gryffindor's give-all-spells actor at the source
    // so Harry has only AP-granted spells inside the room (no-op elsewhere).
    // After DetectOpenCastleMode (bOpenCastleMode stuck) and the spell baseline above,
    // before the stars are replaced.
    NeutralizeGryffindorSpellGiver();
    // Subclass-replace each unchecked vanilla challenge star with an
    // APChallengeStarMarker so pickup fires CHECK_LOCID alongside vanilla
    // score. Already-checked stars stay vanilla, so replay still scores.
    ReplaceChallengeStars();
    // Spawn the visible Slytherin Common Room end star here (post-Bind, so the
    // HProp's PreBeginPlay resolves a valid PlayerHarry) - APGameInfo.InitGame
    // runs before Harry exists, so a star spawned there has PlayerHarry==None
    // and HProp.CanPickupNow can never fire. Save-load forces bSnapshotted=
    // False, so this single hook covers the ProcessServerTravel path too.
    if (APGameInfo(Level.Game) != None)
        APGameInfo(Level.Game).SpawnSlytherinEndStarIfMissing();
    else
        Log("[Archipelago] APCardWatcher.Snapshot: Level.Game not APGameInfo - cannot spawn Slytherin end star");
    // Clause-3: credit terminal objective levels (ingredient levels 0-2,
    // Willow 5, Slytherin 6) from the watcher's own per-level bind history
    // when we leave them. Challenges (7-11) are NOT exit-credited — see
    // ScanFinalStarCompletion (per-tick FinalStar pickup observer), since the
    // entrance door and pause-menu Return-to-Hub button both bypass the
    // "leaving == completion" premise.
    CheckExitedLevelObjective();
    // Drop the per-card curtain in Ch6WizardCard for every gold card Harry
    // currently owns. Vanilla's RemoveHarryOwnedCardsFromLevel destroys
    // owned wci silently with no TriggerEvent, so the per-card curtain
    // movers (Mover76..86 tagged WC1..WC11) would otherwise stay closed
    // on reload. See DropOwnedGoldCardCurtains for the WCn → card mapping.
    DropOwnedGoldCardCurtains();

    // Post-snapshot warmup. Without this, the very first drain happens the
    // moment Snapshot() returns — but level-load cutscenes haven't yet hit
    // their `Play()` call (CutScene.uc:411 sleeps 0.2s in Idle.begin), so
    // every cutscene-presence gate (bPlaying / bIsCaptured / IsCutSceneOrPopupInProgress)
    // returns False and the drain leaks an item during the intro. Pushing
    // the earliest-drain time forward gives the level's bLevelLoadStarts
    // cutscenes time to enter Running state so the existing gates take over.
    // A Snapshot fires after every save-load, so the first post-Snapshot
    // bean diff is the load's autosave revert — absorb it into the
    // baseline rather than broadcasting.
    if (class'APIPCActor'.static.GetInstance() != None)
    {
        class'APIPCActor'.static.GetInstance().PushDrainStability(3.0);
        class'APIPCActor'.static.GetInstance().bSuppressNextRingOutDiff = 1;
    }

    RecoverStuckCutsceneState();

    // #3: morph every marker that registered before/at snapshot (cards via
    // PostBeginPlay, stars via ReplaceChallengeStars above) to the real item
    // art. No-op until the appearance table has arrived; the Timer one-shot +
    // the APPEARANCE-IPC sweep converge anything registered later or async.
    RestampMarkerAppearance();
}

function bool IsHarryOwned(int id)
{
    return siBronze.IsOwnedByHarry(id) || siSilver.IsOwnedByHarry(id) || siGold.IsOwnedByHarry(id);
}

// Per-card curtain mapping for Ch6WizardCard.unr (the Gold Card Room): each
// gold-card display is fronted by a Mover (Mover76..86) tagged WC1..WC11.
// Vanilla `WizardCardIcon.Touch` fires `TriggerEvent(wci.Event)` per-pickup
// where the editor data wired each WCBott/WCDumbledore/etc. instance's
// `Event` field to the matching WCn. Our ReplaceCardChests destroys the
// vanilla wci on first visit, so on every later visit the curtain mover
// spawns at its initial closed keyframe and stays up — vanilla's
// RemoveHarryOwnedCardsFromLevel destroys owned wci silently without
// re-firing the event. DropOwnedGoldCardCurtains re-fires WCn at level
// entry for each gold card Harry owns, restoring the curtain-down state.
//
// WC1 = WCBott is confirmed via Dispatcher13 ('WC1Dispatcher', OutEvents
// include 'WC1') sitting right next to WCBott at ~(0, -455, 800). WC2..WC11
// are best-guess in physical walking order; swap entries if a curtain
// visibly drops in the wrong slot.
function int WCNumForGoldCardId(int id)
{
    // Card ids from gen_apworld.CARD_GAME_ID_TO_CLASS (Goldcards subset).
    switch (id)
    {
        case 69:  return 1;  // WCBott        (entrance, confirmed)
        case 101: return 2;  // WCDumbledore  (Y=-1264)
        case 41:  return 3;  // WCGriffindor  (Y=-3002)
        case 11:  return 4;  // WCHerpo       (Y=-4224)
        case 48:  return 5;  // WCSlytherin   (Y=-5529, right side)
        case 72:  return 6;  // WCHufflepuff  (Y=-5505, left side)
        case 74:  return 7;  // WCKnightley   (Y=-4733)
        case 15:  return 8;  // WCParacelsus  (Y=-4237, X=-4780)
        case 40:  return 9;  // WCPinkstone   (Y=-1824)
        case 82:  return 10; // WCRavenclaw   (Y=-515)
        case 100: return 11; // WCPotter      (Y=2879, far behind)
    }
    return 0;
}

// Fire the per-card curtain event for each gold card Harry currently owns.
// Iterates the APCardMarker actors in the current level (which carry
// CardLocationId from the original game-side card id), looks up the WC
// mover tag via WCNumForGoldCardId, fires TriggerEvent(WCn). The curtain
// movers (Mover76..86 in Ch6WizardCard) have bTriggerOnceOnly=True so each
// fire is a stable drop. No-op outside Ch6WizardCard since no WCn movers
// exist in other levels.
function DropOwnedGoldCardCurtains()
{
    local APCardMarker marker;
    local int wcN, firedCount;
    local name evtName;

    Log("[Archipelago] DropOwnedGoldCardCurtains: entry, siGold=" $ string(siGold));
    if (siGold == None) return;

    firedCount = 0;
    foreach AllActors(class'APCardMarker', marker)
    {
        if (marker.CardLocationId <= 0 || marker.CardLocationId > 101) continue;
        if (!siGold.IsOwnedByHarry(marker.CardLocationId)) continue;
        wcN = WCNumForGoldCardId(marker.CardLocationId);
        if (wcN <= 0)
        {
            Log("[Archipelago] DropOwnedGoldCardCurtains: id=" $ marker.CardLocationId $ " (" $ string(marker.Class.Name) $ ") owned but no WC mapping");
            continue;
        }
        // Curtain movers are TriggerToggle and HP2 preserves their state
        // across level exits in a session — firing twice toggles them back
        // to closed. Class-default WCnFiredThisSession[] ensures one fire
        // per WCn per session, so the mover stays open after first trigger.
        if (default.WCnFiredThisSession[wcN] == 1)
        {
            Log("[Archipelago] DropOwnedGoldCardCurtains: WC" $ wcN $ " (id " $ marker.CardLocationId $ ") already fired this session, skipping to preserve open state");
            continue;
        }
        evtName = name("WC" $ string(wcN));
        Log("[Archipelago] DropOwnedGoldCardCurtains: id=" $ marker.CardLocationId $ " (" $ string(marker.Class.Name) $ ") owned - firing TriggerEvent(" $ string(evtName) $ ")");
        TriggerEvent(evtName, self, None);
        default.WCnFiredThisSession[wcN] = 1;
        firedCount++;
    }
    Log("[Archipelago] DropOwnedGoldCardCurtains: done - " $ firedCount $ " WCn event(s) fired");
}

// Per-tick poll of SecretAreaMarker actors. When `bFound` is True and the
// marker maps to a registered AP location id (via the generated
// APLocationRegistry), fire CHECK_LOCID once. Class-default
// NonCardLocationChecked[] dedupes across level re-entries within a session;
// the vanilla `bPersistent=True` on SecretAreaMarker keeps `bFound` True on
// re-entry so we'd otherwise re-fire forever. Markers not in the registry
// (locId==0) are skipped — they live in levels we haven't catalogued.
function ScanSecretMarkers(APIPCActor ipc)
{
    local SecretAreaMarker marker;
    local string levelName;
    local int locId;
    local int slot;

    levelName = string(Level.Outer.Name);
    foreach AllActors(class'SecretAreaMarker', marker)
    {
        if (!marker.bFound) continue;
        locId = class'APLocationRegistry'.static.GetSecretLocationId(levelName, string(marker.Name));
        if (locId == 0) continue;
        slot = locId - LOC_BASE;
        if (slot < 0 || slot >= NONCARD_LOC_WINDOW) continue;
        if (default.NonCardLocationChecked[slot] == 1) continue;
        default.NonCardLocationChecked[slot] = 1;
        Log("[Archipelago] APCardWatcher: secret bFound in " $ levelName
            $ " marker=" $ string(marker.Name) $ " - firing CHECK_LOCID " $ locId);
        if (ipc != None) ipc.SendCheckLocationId(locId);
    }
}

// Per-tick poll of harry.DuelRankHarry. Vanilla `UpdateDuelingRanks(True)`
// increments DuelRankHarry by 1 on each duel win when Harry equals the
// opponent's rank (harry.uc:6197-6210). So at any moment, ranks Harry has
// won are exactly {1..DuelRankHarry-1}. Fire CHECK_LOCID once per rank not
// yet checked. Idempotent: resync after save-load just re-fires already-
// banked AP CHECKs (the AP server and client both dedupe).
// AP location id = 5760600 + (rank - 1), per data/locations.yaml `duels`.
function ScanDuelWins(APIPCActor ipc)
{
    local int rank, locId, slot;

    if (HarryRef == None) return;

    for (rank = 1; rank < HarryRef.DuelRankHarry && rank <= 10; rank++)
    {
        locId = 5760600 + (rank - 1);
        slot = locId - LOC_BASE;
        if (slot < 0 || slot >= NONCARD_LOC_WINDOW) continue;
        if (default.NonCardLocationChecked[slot] == 1) continue;
        default.NonCardLocationChecked[slot] = 1;
        Log("[Archipelago] APCardWatcher: duel rank " $ rank
            $ " won (DuelRankHarry=" $ HarryRef.DuelRankHarry
            $ ") - firing CHECK_LOCID " $ locId);
        if (ipc != None) ipc.SendCheckLocationId(locId);
    }
}

// Per-tick poll of harry.quidGameResults[0..5].bWon. Vanilla sets bWon=True
// when Harry wins a Quidditch match (also persists via travel-class). Match
// index 5 is the final match — same poll handles both regular and final.
// AP location id = 5760620 + match_index, per data/locations.yaml
// `quidditch_matches`. Idempotent for the same reason as ScanDuelWins.
function ScanMatchWins(APIPCActor ipc)
{
    local int i, locId, slot;

    if (HarryRef == None) return;

    for (i = 0; i < 6; i++)
    {
        if (!HarryRef.quidGameResults[i].bWon) continue;
        locId = 5760620 + i;
        slot = locId - LOC_BASE;
        if (slot < 0 || slot >= NONCARD_LOC_WINDOW) continue;
        if (default.NonCardLocationChecked[slot] == 1) continue;
        default.NonCardLocationChecked[slot] = 1;
        Log("[Archipelago] APCardWatcher: quidditch match " $ (i + 1)
            $ " won (vs " $ HarryRef.quidGameResults[i].Opponent
            $ ") - firing CHECK_LOCID " $ locId);
        if (ipc != None) ipc.SendCheckLocationId(locId);
    }
}

// Per-tick poll of harry.ChallengeScores[0..3]. A spell challenge is Mastered
// once nHighScore >= nMaxScore (the par), the same predicate vanilla
// ChallengeScoreManager.EndState() uses to set bMastered. The `nMaxScore > 0`
// guard rejects a never-played challenge (0/0) so it cannot false-fire.
// ChallengeScores is var travel, so a Mastered challenge persists across
// save-load exactly like quidGameResults. AP location id = 5760630 + i, per
// data/locations.yaml `spell_challenge_times`, indexed 0=Rictusempra,
// 1=Skurge, 2=Diffindo, 3=Spongify. Idempotent for the same reason as
// ScanMatchWins.
function ScanChallengeMastery(APIPCActor ipc)
{
    local int i, locId, slot;

    if (HarryRef == None) return;

    for (i = 0; i < 4; i++)
    {
        if (HarryRef.ChallengeScores[i].nMaxScore <= 0) continue;
        if (HarryRef.ChallengeScores[i].nHighScore < HarryRef.ChallengeScores[i].nMaxScore) continue;
        locId = 5760630 + i;
        slot = locId - LOC_BASE;
        if (slot < 0 || slot >= NONCARD_LOC_WINDOW) continue;
        if (default.NonCardLocationChecked[slot] == 1) continue;
        default.NonCardLocationChecked[slot] = 1;
        Log("[Archipelago] APCardWatcher: spell challenge " $ i $ " mastered (high="
            $ HarryRef.ChallengeScores[i].nHighScore $ " par="
            $ HarryRef.ChallengeScores[i].nMaxScore $ ") - firing CHECK_LOCID " $ locId);
        if (ipc != None) ipc.SendCheckLocationId(locId);
    }
}

// Mechanism D (challenges 7-11): credit the LevelCompletion check on an
// observed FinalStar pickup in-level, not on exit. Players can leave a
// challenge without completing it — the entrance door of every challenge
// returns to the hub, and the pause-menu Return-to-Hub button bails out the
// same way — so the prior exit-credit path miscredited the location. Vanilla
// FinalStar.PickupProp.EndState is the only path that Destroy()'s the actor
// (HProp.uc:293), so observing AllActors transition from present → absent
// in-level is an unambiguous pickup signal. Idempotent:
// bAwardedFinalStarThisLevel prevents a re-fire within this watcher;
// NotifyLevelObjective is sticky across watchers via NonCardLocationChecked.
function ScanFinalStarCompletion()
{
    local FinalStar fs;
    local int idx;
    local bool found;

    if (bAwardedFinalStarThisLevel == 1) return;
    idx = class'APCardWatcher'.static.LevelObjectiveIndexFor(Caps(string(Level.Outer.Name)));
    if (idx < 7 || idx > 11) return;

    foreach AllActors(class'FinalStar', fs)
    {
        if (fs == None || fs.bDeleteMe) continue;
        found = True;
        break;
    }

    if (found)
    {
        if (bSawFinalStarThisLevel == 0)
        {
            bSawFinalStarThisLevel = 1;
            Log("[Archipelago] APCardWatcher.ScanFinalStarCompletion: FinalStar observed in "
                $ string(Level.Outer.Name) $ " (idx=" $ idx $ ")");
        }
    }
    else if (bSawFinalStarThisLevel == 1)
    {
        bAwardedFinalStarThisLevel = 1;
        Log("[Archipelago] APCardWatcher.ScanFinalStarCompletion: FinalStar consumed in "
            $ string(Level.Outer.Name) $ " (idx=" $ idx $ ") - crediting completion");
        class'APCardWatcher'.static.NotifyLevelObjective(idx);
    }
}

// DeathLink. Outgoing rising-edge detection on the single terminal state
// every death cause funnels through (stateDead → LoadGame 0), plus inbound
// application via a dedicated terminal path that never routes through
// Died/KillHarry — KillHarry's boss-victory branch (harry.uc:1576) would send
// SendVictoriousTrigger instead of dying when Harry has a boss target with
// TrigEventWhenVictor, gifting a open castle player an Aragog/Basilisk goal.
// StopBossEncounter clears that target; bClubDeath bypasses the Wiggenweld
// auto-quaff; GotoState('stateDead') is the same engine terminal state a
// natural death uses (→ LoadGame 0, which discards boss state anyway).
function ScanDeathLink(APIPCActor ipc)
{
    local string reason;
    local bool bDead;

    if (HarryRef == None) return;

    bDead = (HarryRef.GetStateName() == 'stateDead');

    // Outgoing: rising edge into stateDead.
    if (bDead && default.bWasDead == 0)
    {
        default.bWasDead = 1;
        // Death (organic OR induced) → LoadGame 0 reloads the autosave, which
        // travels out of this level. Mark it so CheckExitedLevelObjective does
        // not miscredit the death-reload as completing an exit-credited level.
        default.DeathExitFromLevelCaps = Caps(string(Level.Outer.Name));
        if (default.bSuppressNextDeathBroadcast == 1)
        {
            // This stateDead is our own induced (incoming) kill — consume the
            // latch and do NOT rebroadcast (deterministic loop prevention).
            default.bSuppressNextDeathBroadcast = 0;
            default.DeathSuppressTicksLeft = 0;
            Log("[Archipelago] APCardWatcher: stateDead from induced DeathLink kill - rebroadcast suppressed");
        }
        else
        {
            Log("[Archipelago] APCardWatcher: Harry died (stateDead) - firing DEATH");
            if (ipc != None) ipc.SendDeath("Harry was defeated");
        }
    }
    else if (!bDead && default.bWasDead == 1)
    {
        // Alive again (post-reload PlayerWalking) — re-arm the edge.
        default.bWasDead = 0;
    }

    // Latch timeout: if the induced GotoState was somehow missed, don't let a
    // stale suppress flag eat a later natural death.
    if (default.bSuppressNextDeathBroadcast == 1 && !bDead
        && default.DeathSuppressTicksLeft > 0)
    {
        default.DeathSuppressTicksLeft -= 1;
        if (default.DeathSuppressTicksLeft <= 0)
        {
            default.bSuppressNextDeathBroadcast = 0;
            Log("[Archipelago] APCardWatcher: DeathLink suppress latch timed out (no stateDead) - cleared");
        }
    }

    // Incoming: apply a pending linked death.
    if (default.bPendingDeathLink == 1)
    {
        if (bDead)
        {
            // Already dying (our own death raced the inbound) — the reload is
            // happening regardless, so just drop the pending kill.
            default.bPendingDeathLink = 0;
        }
        else if (class'APGameInfo'.static.IsPlayerInPlayableState(HarryRef, reason))
        {
            default.bPendingDeathLink = 0;
            default.bSuppressNextDeathBroadcast = 1;
            default.DeathSuppressTicksLeft = DEATH_SUPPRESS_TIMEOUT_TICKS;
            // The imminent LoadGame 0 will revert beans to the autosave
            // value; mark the diff as a reload so RingLink absorbs it.
            if (ipc != None) ipc.bSuppressNextRingOutDiff = 1;
            Log("[Archipelago] APCardWatcher: applying inbound DeathLink kill (dedicated terminal path)");
            if (baseBoss(HarryRef.BossTarget) != None) HarryRef.StopBossEncounter();
            HarryRef.bClubDeath       = True;
            HarryRef.bHarryKilled     = True;
            HarryRef.bAllowHarryToDie = True;
            HarryRef.GotoState('stateDead');
            // Clear input axes and motion so a surface effect (ectoplasm
            // push, ladder/grab residual) cannot survive the reload and
            // stick post-respawn.
            HarryRef.aForward     = 0;
            HarryRef.aStrafe      = 0;
            HarryRef.aTurn        = 0;
            HarryRef.aLookUp      = 0;
            HarryRef.Velocity     = vect(0, 0, 0);
            HarryRef.Acceleration = vect(0, 0, 0);
        }
        // else not playable (cutscene/menu/load): keep pending, retry next tick.
    }
}

// Clause-3 Mechanism B: poll the boss in its level.
// Aragog: Health<=0 routes to GotoState('stateBeatAragog') (Aragog.uc:176-181),
// the unambiguous "defeated" state (the level has 2 Aragog actors; only the
// beaten boss enters it). Basilisk has TWO phases: BeatBoss() runs at BOTH the
// phase-1 (Tom-revealed, 17170VoldRevealedV2) and final kill, so Health<=0 is
// NOT a final-defeat signal (it also fires idx=4 on phase 1). Use
// bBasilFinishedForGood — set True only in BeatBoss()'s
// bDidFirstBattle branch that also destroys the collision + goes stateInactive
// (Basilisk.uc:2215-2220). Level-gated so it never scans unrelated maps or
// matches a stray actor. Idempotent via NotifyLevelObjective's dedupe.
function ScanBossKills(APIPCActor ipc)
{
    local string lvl;
    local Aragog ag;
    local Basilisk bs;

    if (HarryRef == None) return;
    lvl = Caps(string(Level.Outer.Name));

    if (lvl == "ADV9ARAGOG")
    {
        foreach AllActors(class'Aragog', ag)
        {
            if (ag.IsInState('stateBeatAragog'))
            {
                class'APCardWatcher'.static.NotifyLevelObjective(3);
                break;
            }
        }
    }
    else if (lvl == "ADV12CHAMBER")
    {
        foreach AllActors(class'Basilisk', bs)
        {
            if (bs.bBasilFinishedForGood)
            {
                class'APCardWatcher'.static.NotifyLevelObjective(4);
                break;
            }
        }
    }
}

// Per-tick scan for VendorNimbusBroom / QArmor actors freshly spawned by
// Characters.MakePurchase (line 631-636 in vanilla Characters.uc). Each one
// is destroyed and replaced with our AP-aware subclass at the same
// Location/Rotation, with CheckLocationId baked in. The replacement's Touch
// fires CHECK_LOCID instead of granting the inventory item, so AP retains
// control over what the player actually receives from buying.
//
// Skips actors that are already our subclass so re-running is idempotent.
// If the location is already AP-checked (e.g. the player bought once already
// in this session and AP banked it), destroy the freshly-spawned vanilla
// item with no replacement — buying twice shouldn't double-fire.
//
// Mirrors ReplaceVendorSpawnedCards's structure for the cards path.
function ReplaceVendorEquipment()
{
    local VendorNimbusBroom broom;
    local QArmor armor;
    local APVendorMarker_Nimbus apNimbus;
    local APVendorMarker_QArmor apArmor;
    local Vector loc;
    local Rotator rot;
    local int slot;

    foreach AllActors(class'VendorNimbusBroom', broom)
    {
        if (ClassIsChildOf(broom.Class, class'APVendorMarker_Nimbus')) continue;
        slot = 5760005 - LOC_BASE;  // "Castle Exterior - Nimbus 2001" id_offset 5
        if (default.NonCardLocationChecked[slot] == 1)
        {
            Log("[Archipelago] APCardWatcher.ReplaceVendorEquipment: Nimbus location already AP-checked - destroying vanilla broom with no replacement");
            broom.Destroy();
            continue;
        }
        loc = broom.Location;
        rot = broom.Rotation;
        Log("[Archipelago] APCardWatcher.ReplaceVendorEquipment: swapping VendorNimbusBroom -> APVendorMarker_Nimbus at " $ string(loc));
        broom.Destroy();
        apNimbus = Spawn(class'APVendorMarker_Nimbus', , , loc, rot);
        if (apNimbus == None)
        {
            Log("[Archipelago] APCardWatcher.ReplaceVendorEquipment: Spawn(APVendorMarker_Nimbus) returned None");
            continue;
        }
        apNimbus.CheckLocationId = 5760005;
        RegisterMorphMarker(apNimbus, 5760005);
        apNimbus.ApplyAPAppearance();
    }

    foreach AllActors(class'QArmor', armor)
    {
        if (ClassIsChildOf(armor.Class, class'APVendorMarker_QArmor')) continue;
        slot = 5760006 - LOC_BASE;  // "Castle Exterior - Quidditch Armour" id_offset 6
        if (default.NonCardLocationChecked[slot] == 1)
        {
            Log("[Archipelago] APCardWatcher.ReplaceVendorEquipment: QArmor location already AP-checked - destroying vanilla armor with no replacement");
            armor.Destroy();
            continue;
        }
        loc = armor.Location;
        rot = armor.Rotation;
        Log("[Archipelago] APCardWatcher.ReplaceVendorEquipment: swapping QArmor -> APVendorMarker_QArmor at " $ string(loc));
        armor.Destroy();
        apArmor = Spawn(class'APVendorMarker_QArmor', , , loc, rot);
        if (apArmor == None)
        {
            Log("[Archipelago] APCardWatcher.ReplaceVendorEquipment: Spawn(APVendorMarker_QArmor) returned None");
            continue;
        }
        apArmor.CheckLocationId = 5760006;
        RegisterMorphMarker(apArmor, 5760006);
        apArmor.ApplyAPAppearance();
    }

    // Tradersanity vendors.
    TradersanityPass();
    TradersanityHintOnOpenPass();
}

// Edge-detect the player engaging a Tradersanity vendor's dialogue: on the
// transition from "no engagement / different vendor" to "this vendor", fire
// VENDOR_OPENED <locId> so the client publishes a broadcast hint for the AP
// item that vendor is holding. Gated on Tradersanity being on (off-mode
// vendors have no AP check to hint) and on the location still being
// unchecked (a checked vendor's item is already known to the room).
function TradersanityHintOnOpenPass()
{
    local VendorManager vm;
    local Characters engagedVendor;
    local APIPCActor ipc;
    local int locId, slot;
    local string lvl;

    if (default.TradersanityMode == TRADER_OFF) return;
    if (HarryRef == None) return;

    vm = HarryRef.CurrVendorManager;
    if (vm == None || vm.Vendor == None)
    {
        default.TraderHintLastEngagedLocId = 0;
        return;
    }

    engagedVendor = vm.Vendor;

    lvl = string(Level.Outer.Name);
    locId = class'APLocationRegistry'.static.GetVendorLocationId(lvl, string(engagedVendor.Name));
    if (locId == 0) return;
    if (locId == default.TraderHintLastEngagedLocId) return;

    default.TraderHintLastEngagedLocId = locId;

    slot = locId - LOC_BASE;
    if (slot < 0 || slot >= NONCARD_LOC_WINDOW) return;
    if (default.NonCardLocationChecked[slot] == 1) return;

    ipc = class'APIPCActor'.static.GetInstance();
    if (ipc != None) ipc.SendVendorOpened(locId);
    Log("[Archipelago] APCardWatcher.TradersanityHintOnOpenPass: fired VENDOR_OPENED "
        $ locId $ " for engaged vendor " $ string(engagedVendor.Name));
}

// True for the four Tradersanity-eligible sell types. Fred/George
// (Sells_Nimbus2001 / Sells_QArmor) and Sells_Duel / Sells_Nothing are
// excluded by omission. Enum reference form per VendorManager.uc.
function bool IsTradersanitySellType(Characters c)
{
    return c.CharacterSells == c.ESells.Sells_WBark
        || c.CharacterSells == c.ESells.Sells_FMucus
        || c.CharacterSells == c.ESells.Sells_BronzeCards
        || c.CharacterSells == c.ESells.Sells_SilverCards;
}

// Find-or-add a vendor in the per-level registry. The original sell type
// comes from the GENERATED registry (data/locations.yaml), NOT the live
// actor, so a card vendor we converted to Sells_WBark is still known to be a
// card vendor after a save/load. The price range is snapshotted from the
// actor's original fields (best-effort; a save/load mid-pending can capture
// an already-modified ingredient price — a minor price-only edge).
function int TraderRegIndex(Characters c, string lvl)
{
    local int i, free, s;

    free = -1;
    for (i = 0; i < TRADER_REG_SIZE; i++)
    {
        if (TraderVendor[i] == c) return i;
        if (free < 0 && (TraderVendor[i] == None || TraderVendor[i].bDeleteMe))
        {
            free = i;
        }
    }
    if (free < 0) return -1;

    s = class'APLocationRegistry'.static.GetVendorSells(lvl, string(c.Name));
    TraderVendor[free]    = c;
    TraderOrigSells[free] = s;
    TraderApplied[free]   = 0;
    TraderRestored[free]  = 0;
    TraderDispensed[free] = 0;
    TraderToken[free]     = None;
    TraderWait[free]      = 0;
    TraderSavedIngr[free] = c.nCurrIngrCount;
    if (s == SELLS_BRONZE)
    {
        TraderSavedLo[free] = c.nPriceBronzeCardsMin;
        TraderSavedHi[free] = c.nPriceBronzeCardsMax;
    }
    else if (s == SELLS_SILVER)
    {
        TraderSavedLo[free] = c.nPriceSilverCardsMin;
        TraderSavedHi[free] = c.nPriceSilverCardsMax;
    }
    else if (s == SELLS_FMUCUS)
    {
        TraderSavedLo[free] = c.nPriceFMucus;
        TraderSavedHi[free] = c.nPriceFMucus;
    }
    else
    {
        TraderSavedLo[free] = c.nPriceWBark;
        TraderSavedHi[free] = c.nPriceWBark;
    }
    return free;
}

// Original sell type was a card tier — this vendor is converted to an
// ingredient vendor while its check is pending and restored on collection.
function bool IsTraderCardVendor(int idx)
{
    return TraderOrigSells[idx] == SELLS_BRONZE
        || TraderOrigSells[idx] == SELLS_SILVER;
}

// Every pending Tradersanity vendor sells via the ingredient path (genuine
// ones unchanged; card vendors set to Sells_WBark), so the active price is
// always the single ingredient field that GetSellingPrice reads.
function SetVendorActivePrice(Characters c, int p)
{
    if (c.CharacterSells == c.ESells.Sells_FMucus)
    {
        c.nPriceFMucus = p;
    }
    else
    {
        c.nPriceWBark = p;
    }
}

// Apply the slot_data price mode to the vendor's active (ingredient) price,
// once per visit. price_low: flat. price_random: blend the per-vendor
// pre-rolled factor across [LO,HI]. price_vanilla: a genuine ingredient
// vendor keeps its true price; a converted card vendor blends the SAME
// factor across its original card [min,max] so the AP sale costs a card-like
// price. The factor is rolled in the apworld from the seed and shipped via
// TRADERPRICES, so a vendor's AP-check price is fixed for the seed across
// level transitions AND save/exit instead of re-rolling on every re-entry.
function ApplyVendorPrice(Characters c, int idx, int slot)
{
    local int factor, lo, hi;

    if (default.TradersanityMode == TRADER_PRICE_LOW)
    {
        SetVendorActivePrice(c, TRADER_PRICE_LOW_BEANS);
        return;
    }
    factor = default.TraderRolledFactor[slot];
    if (default.TradersanityMode == TRADER_PRICE_RANDOM)
    {
        lo = TRADER_PRICE_RAND_LO;
        hi = TRADER_PRICE_RAND_HI;
        SetVendorActivePrice(c, lo + ((hi - lo) * factor) / 255);
        return;
    }
    // price_vanilla
    if (IsTraderCardVendor(idx))
    {
        lo = TraderSavedLo[idx];
        hi = TraderSavedHi[idx];
        SetVendorActivePrice(c, lo + ((hi - lo) * factor) / 255);
    }
    else
    {
        SetVendorActivePrice(c, TraderSavedLo[idx]);
    }
}

// Put a sold Tradersanity vendor fully back to vanilla, exactly once. Called
// the instant the sale resolves (the AP token is claimed) — NOT deferred to
// the token pickup — so the vendor is sellable again in the same trade
// session. A converted card vendor returns to its card tier. The original
// ingredient sale price is restored unconditionally: the AP price is written
// into nPriceWBark/nPriceFMucus and the conformal save persists it, so on a
// later level load (fresh per-level registry, TraderApplied==0) a guarded
// restore would be skipped and the vendor would stay stuck at the AP price.
// For a reverted card vendor SetVendorActivePrice writes an unread field (it
// prices off its card min/max), so the restore is a harmless no-op there.
// nCurrIngrCount is restored to the vanilla count snapshotted at registration
// (card vendors sell from card stock so their ~0 snapshot is harmless;
// genuine ingredient vendors get at least 1) so vanilla resumes managing
// stock immediately instead of sitting at the pinned zero.
function RevertTraderVendorOnce(Characters c, int idx, bool cardV, int locId)
{
    if (TraderRestored[idx] == 1) return;
    if (cardV)
    {
        if (TraderOrigSells[idx] == SELLS_BRONZE)
            c.CharacterSells = c.ESells.Sells_BronzeCards;
        else
            c.CharacterSells = c.ESells.Sells_SilverCards;
    }
    SetVendorActivePrice(c, TraderSavedLo[idx]);
    c.nCurrIngrCount = TraderSavedIngr[idx];
    if (!cardV && c.nCurrIngrCount <= 0)
    {
        c.nCurrIngrCount = 1;
    }
    // VendorManager caches Vendor.GetSellingPrice() into nCurrPrice ONCE at
    // engage and reuses it for the whole dialogue (both the displayed price
    // and the amount charged); it never recomputes per item. So an open menu
    // keeps showing/charging the AP price after we revert the price fields
    // until the player disengages and re-talks. Push the reverted price into
    // the live menu instance so it updates in the same trade session.
    if (c.managerVendor != None)
    {
        c.managerVendor.nCurrPrice = c.GetSellingPrice();
    }
    TraderRestored[idx] = 1;
    Log("[Archipelago] APCardWatcher.TradersanityPass: reverted vendor "
        $ string(c.Name) $ " (loc id " $ locId $ " price " $ TraderSavedLo[idx] $ ")");
}

// Tradersanity per-tick pass. No actor is ever Spawn()ed: a WizardCardIcon
// subclass returns None from Spawn() at essentially every occupied point in
// this engine (bCollideWhenPlacing=False is not honored), which is why the
// marker-spawn approach could never place reliably. Instead we re-skin the
// prop the vendor itself spawned.
//
// While a vendor's check is pending it is made to sell exactly ONE item:
//   - card vendor  → CharacterSells coerced to Sells_WBark (plain prop, no
//     real card, so cardsanity stays fully independent),
//   - either kind  → nCurrIngrCount pinned to 1 and AP-priced.
// Vanilla MakePurchase deducts the beans, does `--nCurrIngrCount`, and drops
// a pickup prop. The single unit going 1 -> 0 between ticks is an
// unambiguous "paid purchase happened" signal (MakePurchase early-returns
// without decrementing if the player can't afford it). The PotionIngredients
// sweep below the vendor loop then morphs that dropped prop to the AP item's
// vanilla appearance and claims it as the vendor's pickup token; the check
// fires when the player PICKS IT UP (the pickup destroys the actor). The
// checkedLoc branch then permanently reverts the vendor to full vanilla
// (card vendor back to its card tier; ingredient vendor back to its real
// stock at its real price). Inert when the mode is off.
function TradersanityPass()
{
    local Characters c, v;
    local APIPCActor ipc;
    local PotionIngredients pi;
    local string lvl;
    local int locId, slot, idx, i, bestIdx, bLoc;
    local float bestD, dd;
    local bool checkedLoc, cardV;

    if (default.TradersanityMode == TRADER_OFF) return;

    lvl = string(Level.Outer.Name);

    foreach AllActors(class'Characters', c)
    {
        if (!IsTradersanitySellType(c)) continue;
        locId = class'APLocationRegistry'.static.GetVendorLocationId(lvl, string(c.Name));
        if (locId == 0) continue;
        slot = locId - LOC_BASE;
        if (slot < 0 || slot >= NONCARD_LOC_WINDOW) continue;

        idx = TraderRegIndex(c, lvl);
        if (idx < 0) continue;

        checkedLoc = (default.NonCardLocationChecked[slot] == 1);
        cardV      = IsTraderCardVendor(idx);

        if (checkedLoc)
        {
            // Already collected — ensure the vendor is back to vanilla
            // (idempotent; normally already reverted at sale time) and leave
            // it alone so vanilla owns its stock.
            RevertTraderVendorOnce(c, idx, cardV, locId);
            continue;
        }

        if (TraderDispensed[idx] == 1)
        {
            // Sold. The vendor was put fully back to vanilla the instant the
            // sale resolved (RevertTraderVendorOnce, in the morph sweep), so
            // it is sellable again in the same trade session — we do not
            // touch its stock here. The morphed prop is the AP token; the
            // check fires when the player PICKS IT UP (the pickup destroys
            // the actor, so the ref goes None/bDeleteMe).
            RevertTraderVendorOnce(c, idx, cardV, locId);
            if (TraderToken[idx] == None || TraderToken[idx].bDeleteMe)
            {
                ipc = class'APIPCActor'.static.GetInstance();
                if (ipc != None) ipc.SendCheckLocationId(locId);
                default.NonCardLocationChecked[slot] = 1;
                Log("[Archipelago] APCardWatcher.TradersanityPass: vendor "
                    $ string(c.Name) $ " AP token picked up (loc id " $ locId
                    $ ") - fired CHECK_LOCID");
            }
            continue;
        }

        // Pending and unsold. Coerce a card vendor onto the ingredient sale
        // path so the sold prop is a plain WiggentreeBark, never a real card
        // (only while undispensed — once sold the revert above owns it).
        if (cardV)
        {
            c.CharacterSells = c.ESells.Sells_WBark;
        }

        if (TraderApplied[idx] == 0)
        {
            // Arm: AP price + a single purchasable unit, together (same tick,
            // so it can't be misread as a sale).
            ApplyVendorPrice(c, idx, slot);
            c.nCurrIngrCount = 1;
            TraderApplied[idx] = 1;
            TraderWait[idx] = 0;
        }
        else if (c.nCurrIngrCount == 0)
        {
            // Bought (beans paid, MakePurchase decremented it). The morph
            // sweep below claims the dropped prop as the token AND reverts
            // the vendor this same tick; hold at zero stock until it does.
            // Safety net: if no token ever resolves (prop grabbed before the
            // sweep saw it, or never appeared) fire the check directly and
            // revert so the vendor can't stick pending forever.
            c.nCurrIngrCount = 0;
            TraderWait[idx] = TraderWait[idx] + 1;
            if (TraderWait[idx] >= TRADER_PICKUP_WAIT_TICKS)
            {
                ipc = class'APIPCActor'.static.GetInstance();
                if (ipc != None) ipc.SendCheckLocationId(locId);
                default.NonCardLocationChecked[slot] = 1;
                TraderDispensed[idx] = 1;
                RevertTraderVendorOnce(c, idx, cardV, locId);
                Log("[Archipelago] APCardWatcher.TradersanityPass: vendor "
                    $ string(c.Name) $ " sold (loc id " $ locId
                    $ ") but no pickup token resolved - fired CHECK_LOCID directly");
            }
        }
        else
        {
            // Armed, unsold: re-pin the single unit against vanilla's
            // per-state-change RandRange reroll.
            c.nCurrIngrCount = 1;
        }
    }

    // Morph + claim the freshly-dropped sale prop for any vendor that just
    // sold but has no token yet. Sequential top-level iterator (never nested
    // in the Characters sweep) and mutate-only — no Spawn. The prop is
    // re-skinned to the AP item's vanilla appearance for its location and
    // becomes the vendor's pickup token; picking it up fires the check.
    foreach AllActors(class'PotionIngredients', pi)
    {
        if (pi.bDeleteMe) continue;
        bestIdx = -1;
        bestD = TRADER_MATCH_RADIUS;
        for (i = 0; i < TRADER_REG_SIZE; i++)
        {
            v = TraderVendor[i];
            if (v == None || v.bDeleteMe) continue;
            if (TraderApplied[i] != 1 || TraderDispensed[i] != 0) continue;
            if (TraderToken[i] != None) continue;
            if (v.nCurrIngrCount != 0) continue;
            dd = VSize(v.Location - pi.Location);
            if (dd < bestD)
            {
                bestD = dd;
                bestIdx = i;
            }
        }
        if (bestIdx < 0) continue;

        bLoc = class'APLocationRegistry'.static.GetVendorLocationId(
            lvl, string(TraderVendor[bestIdx].Name));
        if (bLoc == 0) continue;

        ApplyAppearanceTo(pi, AppearanceForApId(bLoc));
        // The dropped prop is a real WiggentreeBark/FlobberwormMucus; its
        // ingredient grant is the stock HProp pickup pipeline reading these
        // two class fields (the exact pair APVendorMarker_Trader nulls so it
        // grants nothing). Null them on this instance so picking the morphed
        // AP token up does not add the ingredient to inventory, while the
        // pickup itself still destroys the actor so the check still fires.
        pi.classStatusGroup = None;
        pi.classStatusItem  = None;
        RegisterMorphMarker(pi, bLoc);
        TraderToken[bestIdx]     = pi;
        TraderDispensed[bestIdx] = 1;
        TraderWait[bestIdx]      = 0;
        // Put the vendor back to vanilla in this same tick the sale resolves
        // so it sells its normal stock again immediately (not deferred to the
        // token pickup). The check still fires when the token is picked up.
        RevertTraderVendorOnce(TraderVendor[bestIdx], bestIdx,
            IsTraderCardVendor(bestIdx), bLoc);
        Log("[Archipelago] APCardWatcher.TradersanityPass: vendor "
            $ string(TraderVendor[bestIdx].Name) $ " sold - morphed dropped "
            $ string(pi.Class.Name) $ " to AP appearance (loc id " $ bLoc
            $ "), vendor reverted, check fires on pickup");
    }
}

// Snapshot-time: subclass-replace each unchecked vanilla ChallengeStar with
// an APChallengeStarMarker carrying the AP location id baked in. The marker
// inherits the entire ChallengeStar pickup pipeline (mesh, sound, fly-to-HUD,
// PickedUpStar score increment via PickupProp.EndState's Super call); it only
// adds the CHECK_LOCID fire. Already-checked locations are left as vanilla
// stars so level replay still grants vanilla score but never re-fires AP.
// Skips actors already of our subclass so re-running is idempotent.
// Open-castle-only Snapshot-path safety net for the Gryffindor spell giver. The
// PRIMARY kill is APGameInfo.DestroyGryffindorSpellGiver (InitGame, pre-Harry)
// — by Snapshot the level-start dispatcher has usually already fired the
// TriggerTurnOnAllSpells and set harry.bNoSpellBookCheck=True. This still
// destroys any surviving giver (covers the save-load path, where
// ProcessServerTravel skips InitGame and the level package re-instantiates
// the actor) AND clears bNoSpellBookCheck so IsInSpellBook stops reporting
// every spell as owned (harry.uc:568). The per-tick clear in the reconcile
// loop is the continuous guarantee. Class match is by class-name string (no
// hard ref). Vanilla never enters this level so the giver is left intact.
function NeutralizeGryffindorSpellGiver()
{
    local Actor a;
    local int n;

    if (Caps(string(Level.Outer.Name)) != "CH7GRYFFINDOR") return;
    if (default.bOpenCastleMode != 1) return;

    foreach AllActors(class'Actor', a)
    {
        if (!a.bDeleteMe && string(a.Class.Name) == "TriggerTurnOnAllSpells")
        {
            a.Destroy();
            n++;
        }
    }
    if (HarryRef != None)
    {
        HarryRef.bNoSpellBookCheck = False;
    }
    Log("[Archipelago] NeutralizeGryffindorSpellGiver: destroyed " $ n
        $ " TriggerTurnOnAllSpells actor(s) + cleared bNoSpellBookCheck (CH7GRYFFINDOR open castle)");
}

function ReplaceChallengeStars()
{
    local ChallengeStar star;
    local APChallengeStarMarker apStar;
    local Vector loc;
    local Rotator rot;
    local Actor vanillaBase;
    local Name vanillaTag;
    local string levelName, markerName;
    local int locId, slot, replaced;

    levelName = string(Level.Outer.Name);
    replaced = 0;
    foreach AllActors(class'ChallengeStar', star)
    {
        if (ClassIsChildOf(star.Class, class'APChallengeStarMarker')) continue;

        markerName = string(star.Name);
        locId = class'APLocationRegistry'.static.GetStarLocationId(levelName, markerName);
        if (locId == 0) continue;
        slot = locId - LOC_BASE;
        if (slot < 0 || slot >= NONCARD_LOC_WINDOW) continue;
        if (default.NonCardLocationChecked[slot] == 1) continue;

        // Capture mover-attachment state before destroying the vanilla star.
        // Many challenge-level stars ride moving platforms — the mover wires
        // each star's Base at level load by matching its AttachTag against
        // the star's Tag. A naive Destroy + Spawn at the same Location/
        // Rotation drops the Base linkage, leaving the new actor sitting
        // stationary while its platform travels off. Copying Tag (defensive,
        // for any system that later inspects it) and re-running SetBase on
        // the replacement restores the linkage so the engine carries the
        // replacement along with the platform every tick like vanilla.
        loc = star.Location;
        rot = star.Rotation;
        vanillaBase = star.Base;
        vanillaTag = star.Tag;
        star.Destroy();
        apStar = Spawn(class'APChallengeStarMarker', , , loc, rot);
        if (apStar == None)
        {
            Log("[Archipelago] APCardWatcher.ReplaceChallengeStars: Spawn returned None at "
                $ string(loc) $ " for AP id " $ locId);
            continue;
        }
        apStar.CheckLocationId = locId;
        // #3: id is now known — opt this marker into the appearance sweep and
        // best-effort morph it (no-op until the table arrives).
        RegisterMorphMarker(apStar, locId);
        apStar.ApplyAPAppearance();
        if (vanillaTag != 'None')
        {
            apStar.Tag = vanillaTag;
        }
        if (vanillaBase != None)
        {
            apStar.SetBase(vanillaBase);
        }
        replaced++;
    }
    if (replaced > 0)
    {
        Log("[Archipelago] APCardWatcher.ReplaceChallengeStars: replaced " $ replaced
            $ " vanilla star(s) with AP markers in " $ levelName);
    }
}

// Clause-3 exit-credit for the levels whose ONLY forward progress is
// completing their single objective: 0 Boomslang (Adv4Greenhouse), 1 Bicorn
// (Adv3DungeonQuest), 2 BitOGoyle (Adv6Goyle), 5 Whomping Willow, and 6
// Slytherin Common Room. We do NOT poll per-item state: the ingredient
// StatusItem path is broken in this build (orphaned StatusItemBitOGoyle; the
// Bicorn prop has null class refs so StatusManager.PickupItem early-returns
// and nCount never rises - §12 #16/#17), and harry.PreviousLevelName is
// blanked by the return auto-save before Snapshot runs (§12 #15). Instead we
// track OUR own per-level bind history: the watcher Snapshots in every level,
// so when this bind's level differs from the last bind's and the last one was
// an exit-credited level, it is complete. Catches scripted-cutscene exits a
// Touch probe never saw. Boss levels (3/4) keep their own poll detector and
// are NOT exit-credited (they can be traversed/left without the kill). The
// mod's Return-to-Hub menu also leaves without completing; APFEInGamePage
// stamps MenuReturnFromLevelCaps so that bail is not miscredited. For 0-2,
// leaving the level also means the polyjuice ingredient was obtained, so its
// key-item AP location is checked too. NotifyLevelObjective dedupes via the
// sticky GoalLevelDone bit.
//
// Challenges (idx 7-11) are NOT exit-credited: the entrance door of every
// challenge level returns to the hub without completing the challenge, and
// the pause-menu Return-to-Hub button does the same. Both bypasses miscredit
// the LevelCompletion location. ScanFinalStarCompletion owns the credit for
// challenges via direct FinalStar-pickup observation instead.
function CheckExitedLevelObjective()
{
    local string curCaps, prevCaps;
    local int idx;
    local APIPCActor ipc;

    curCaps = Caps(string(Level.Outer.Name));
    // Physically back inside an exit-credited level => a fresh attempt; any
    // earlier menu-bail or death-reload record is moot and must not suppress
    // this run's exit (covers the case where the autosave was in-level, so a
    // death reloaded the same level and the marker would otherwise go stale).
    if (curCaps == "ADV1WILLOW" || curCaps == "ADV7SLYTHCOMROOM"
        || curCaps == "ADV4GREENHOUSE" || curCaps == "ADV3DUNGEONQUEST"
        || curCaps == "ADV6GOYLE")
    {
        default.MenuReturnFromLevelCaps = "";
        default.DeathExitFromLevelCaps = "";
    }

    prevCaps = default.LastBoundLevelCaps;
    // Record this bind's level for the NEXT bind's comparison before any
    // early-out, so a single Snapshot per level keeps the history exact and
    // repeated binds in one level are a no-op (prevCaps == curCaps).
    default.LastBoundLevelCaps = curCaps;

    if (prevCaps == "" || prevCaps == curCaps) return;
    idx = class'APCardWatcher'.static.LevelObjectiveIndexFor(prevCaps);
    // 0-2 ingredient levels, 5 Willow, 6 Slytherin. NOT 3/4 (boss levels keep
    // their poll detector - leavable without the kill) and NOT 7-11
    // (challenges have an entrance-door / Return-to-Hub bypass that exit-credit
    // miscredits - ScanFinalStarCompletion owns those via in-level pickup poll).
    if (idx < 0 || idx == 3 || idx == 4 || (idx >= 7 && idx <= 11))
        return;
    if (default.GoalLevelDone[idx] == 1) return; // already credited

    if (prevCaps == default.MenuReturnFromLevelCaps)
    {
        Log("[Archipelago] APCardWatcher.CheckExitedLevelObjective: idx=" $ idx
            $ " skipped - left " $ prevCaps $ " via Return-to-Hub menu");
        return;
    }
    // Death (organic or DeathLink-induced) reloads the autosave (LoadGame 0),
    // which travels out of the level WITHOUT completing it. Not a completion.
    // Clear on consume so a later genuine completion of the same level credits.
    if (prevCaps == default.DeathExitFromLevelCaps)
    {
        default.DeathExitFromLevelCaps = "";
        Log("[Archipelago] APCardWatcher.CheckExitedLevelObjective: idx=" $ idx
            $ " skipped - left " $ prevCaps $ " via death-reload (LoadGame 0)");
        return;
    }
    // idx 0-2: leaving the terminal ingredient level == obtained the
    // ingredient, so the polyjuice key-item AP location is checked too (its
    // StatusItem nCount path is unrecoverable in this build, §12 #16/#17).
    if (idx <= 2)
    {
        WasKeyItemOwned[idx] = 1;
        ipc = class'APIPCActor'.static.GetInstance();
        if (ipc != None) ipc.SendCheckKeyItem(KeyItemNames[idx]);
    }
    Log("[Archipelago] APCardWatcher.CheckExitedLevelObjective: exited "
        $ prevCaps $ " (idx=" $ idx $ ") - crediting objective");
    class'APCardWatcher'.static.NotifyLevelObjective(idx);
}

// One-shot menu patch: replace menuBook.InGamePage with an APFEInGamePage
// instance so the pause menu gets the Return-to-Hub button. Self-healing -
// detects the stock subclass via class-cast, so if a fresh menuBook ever
// appears in this process we re-inject. The previous (stock) InGamePage is
// left as a hidden orphan child of menuBook; this is a one-instance leak per
// inject, acceptable because the inject runs at most a handful of times per
// process lifetime (usually exactly once).
function EnsureHomeMenuInjected()
{
    local HPConsole console;
    local FEBook book;
    local APFEInGamePage newPage;

    if (HarryRef == None || HarryRef.Player == None)
    {
        return;
    }
    console = HPConsole(HarryRef.Player.Console);
    if (console == None || console.menuBook == None)
    {
        return;
    }
    book = console.menuBook;
    if (book.InGamePage == None)
    {
        return;
    }
    if (APFEInGamePage(book.InGamePage) != None)
    {
        return;
    }
    newPage = APFEInGamePage(book.CreateWindow(Class'APFEInGamePage', 0.0, 0.0, book.WinWidth, book.WinHeight));
    if (newPage == None)
    {
        Log("[Archipelago] APCardWatcher.EnsureHomeMenuInjected: CreateWindow returned None; aborting");
        return;
    }
    newPage.book = book;
    newPage.HideWindow();
    book.InGamePage = newPage;
    Log("[Archipelago] APCardWatcher.EnsureHomeMenuInjected: replaced menuBook.InGamePage with APFEInGamePage");
}

// Post-snapshot recovery for two related save/delta-cache corruptions that
// leave the player softlocked (forced black screen, frozen input, hidden HUD)
// on a level the engine restores from a persistent cache:
//
// 1) CutScene actor stuck in (bPlaying=False, bFastForwarding=True) in
//    UnrealScript state 'FastForwarding'. This pair is unreachable via the
//    normal CutScene state machine (FastForwarding clears bFastForwarding
//    before GotoState('Finished'), which sets bPlaying=False). It is baked
//    into Save0.usa when a victory cutscene's own `ChangeLevel` fires from
//    inside its fast-forward tick (Aragog/Basilisk wrap-up) and the
//    FastForwarding->Finished latent transition does not survive the save
//    round-trip; it re-appears on every load of that save.
//
// 2) CutSceneManager.bPopupBorderActive (or bBothBordersActive) stuck True
//    with no CutScene bPlaying. The manager flag is set by SlideIn's
//    BeginState (CutSceneManager.uc:177-188) on every StartCutScene call;
//    it's cleared only when SlideOut completes inside RenderHudItemManager
//    (line 213-216), which requires an EndCutScene to trigger SlideOut. If
//    the player exits the level mid-Hold (level-entry cutscene running, no
//    text-clear or EnablePlayerInput fired yet), the delta-cache write saves
//    Hold-state and on re-entry no fresh cutscene slides it out.
//
// The actual unfreeze (clear bForceBlackScreen, re-enable input, end the
// manager cutscene, unmute) is performed by HPConsole.HandleFastForward
// (HPConsole.uc:694-726), gated on HPConsole.bFastForwarding. harry only
// re-arms that console flag post-load when the restored save had
// managerCutScene.bShowFF==True (harry.uc:1025-1028) - true on a boss-kill
// direct travel, false on a player save+quit from the still-broken hub. So
// clearing the FF flag alone unlocks only on the direct-travel path; on the
// save+quit path HandleFastForward never runs and the flag clear heals
// nothing. On a detected corruption signature this asserts the unlocked
// end-state directly (ForceCutsceneUnlock), independent of that chain. Gated
// on actually-detected corruption so normal level-intro captures (which are
// briefly bPlaying=False at the early Snapshot tick) are never disturbed.
function RecoverStuckCutsceneState()
{
    local CutScene cs;
    local int playingCount, ffCorruptCount;
    local HPHud hud;

    if (HarryRef == None)
    {
        return;
    }

    foreach HarryRef.AllActors(class'CutScene', cs)
    {
        if (cs.bPlaying)
        {
            playingCount++;
            continue;
        }
        if (cs.bFastForwarding)
        {
            Log("[Archipelago] RecoverStuckCutsceneState: clearing invalid bFastForwarding=True on "
                $ string(cs.Name) $ " (FN='" $ cs.FileName $ "', bPlaying=False) - forcing GotoState('Finished')");
            cs.bFastForwarding = False;
            // Push the actor out of the dead 'FastForwarding' state so a clean
            // save no longer round-trips it. Finished's Begin sets
            // bPlaying=False, deletes threads and idles; bPlayOnce story
            // cutscenes stay Finished, so the already-played wrap-up never
            // replays. The numScriptsPlaying-- in Finished's Begin is inert:
            // the engine only ever writes that class default, never reads it.
            cs.GotoState('Finished');
            ffCorruptCount++;
        }
    }

    if (playingCount > 0)
    {
        if (ffCorruptCount > 0)
        {
            Log("[Archipelago] RecoverStuckCutsceneState: cleared " $ ffCorruptCount
                $ " stale FF flag(s); active CutScene(s) present (count=" $ playingCount
                $ "), leaving player capture + CutSceneManager alone");
        }
        return;
    }

    if (ffCorruptCount > 0)
    {
        ForceCutsceneUnlock("stuck FastForwarding CutScene (count=" $ ffCorruptCount $ ")");
        return;
    }

    hud = HPHud(HarryRef.myHUD);
    if (hud == None || hud.managerCutScene == None)
    {
        return;
    }
    if (!hud.managerCutScene.bPopupBorderActive && !hud.managerCutScene.bBothBordersActive)
    {
        return;
    }

    ForceCutsceneUnlock("CutSceneManager borders up with no CutScene bPlaying"
        $ " (bPopupBorderActive=" $ hud.managerCutScene.bPopupBorderActive
        $ " bBothBordersActive=" $ hud.managerCutScene.bBothBordersActive $ ")");
}

// Assert the post-cutscene unlocked state directly. Does NOT depend on
// HPConsole.HandleFastForward (gated on HPConsole.bFastForwarding, which the
// player save+quit path never re-arms). harry.EnablePlayerInput clears
// bIsCaptured/bKeepStationary, calls HPHud.EndCutScene (manager SlideOut +
// bCutSceneMode/bCutPopupMode clear) and releases captured pawns;
// bForceBlackScreen and the sound mute are the two HandleFastForward-only
// effects, restored here explicitly. myHUD is guarded because
// EnablePlayerInput dereferences it (always set on a possessed gameplay
// harry; the guard only matters in degenerate teardown).
function ForceCutsceneUnlock(string reason)
{
    Log("[Archipelago] RecoverStuckCutsceneState: " $ reason
        $ " - asserting unlock (clear bForceBlackScreen + EnablePlayerInput + unmute)");
    HarryRef.bForceBlackScreen = False;
    if (HarryRef.myHUD != None)
    {
        HarryRef.EnablePlayerInput();
    }
    HarryRef.ConsoleCommand("UNMUTESOUNDS");
}

event Destroyed()
{
    if (default.LatestInstance == self)
    {
        default.LatestInstance = None;
    }
    Super.Destroyed();
}

defaultproperties
{
    bHidden=True
    SaySpellChance=0.010000
}

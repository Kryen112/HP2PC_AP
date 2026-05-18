class APCardWatcher extends Actor;

const MAX_CARD_ID = 101;
const NUM_SPELLS = 7;
const NUM_KEY_ITEMS = 3;
const NUM_BINGO_KEYS = 13;

// AP location base id (locations.yaml `base_id`). Used to index
// NonCardLocationChecked[] by `apId - LOC_BASE` for secrets/stars/etc.
// Mirrors `BASE_ID` in apworld/locations.py.
const LOC_BASE = 5760000;
// Window size for the non-card-location dedupe array and every `slot` guard
// below. Mirrors `NONCARD_LOC_WINDOW` in gen_apworld.py — the two MUST hold
// the same value; gen_apworld.py fails generation if any non-card location
// id_offset >= this. Sized generously to cover every band in
// plans/ID_BAND_LEDGER.md with headroom.
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
// HP2 spell; 2001..2008 = HP2 filler; 3001..3002 = HP2 equipment (Nimbus /
// Quidditch Armour); 3003 = HP2 bingo level/challenge key (the vanilla
// silver-key FX sprite); 9000 = foreign filler/useful (AP-logo plain); 9001 =
// foreign progression/trap (AP-logo arrow). Dimension literal
// MUST equal NONCARD_LOC_WINDOW (M212 array dims take an integer literal, not
// a const — see NonCardLocationChecked[] above).
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
// slots. As instance state it lives and dies with the per-level watcher, which
// the engine cleans up the normal same-level way; markers simply re-register
// into each level's fresh watcher (and PostBeginPlay self-apply is the
// independent safety net since AppearanceCode[] IS class-default). The value
// array AppearanceCode[] above stays class-default — only Object refs are
// unsafe there. MORPH_REGISTRY_SIZE is generous: a level holds at most a
// handful of card chests + the chest FancySpawn burst + ≤6 stars + 2 vendors.
const MORPH_REGISTRY_SIZE = 256;
var Actor MorphActor[256];
var int   MorphApId[256];

// --- Tradersanity (plans/06-tradersanity.md) --------------------------------
// Price mode from the apworld slot_data, pushed via the TRADECFG IPC line
// (mirrors GOALCFG / bBingoMode). Class-default so it survives level
// transitions in a session; resent every HELLO so it is sticky. Values mirror
// the apworld Tradersanity Choice.
const TRADER_OFF           = 0;
const TRADER_PRICE_VANILLA = 1;
const TRADER_PRICE_RANDOM  = 2;
const TRADER_PRICE_LOW     = 3;
var int TradersanityMode;
// Price constants for the non-vanilla modes (retune freely). price_vanilla
// never touches the vendor's price fields; price_low clamps to a flat value;
// price_random rolls within [LO, HI] (LO == HI floor is intentional).
const TRADER_PRICE_LOW_BEANS  = 10;
const TRADER_PRICE_RAND_LO    = 10;
const TRADER_PRICE_RAND_HI    = 250;
// A freshly-sold item spawns within ~CollisionRadius+10 of its vendor and is
// caught within ≤0.25s, so it is always far nearer its own vendor than the
// closest neighbouring vendor (census min separation ≈ 210uu). Match the
// NEAREST eligible unchecked Tradersanity vendor within this cap.
const TRADER_MATCH_RADIUS = 256.0;
// Per-level price-restore registry. INSTANCE, not class-default: it holds
// Characters refs and the per-level watcher is torn down the safe same-level
// way (see the MorphActor[] rationale above). A level holds ≤6 eligible
// vendors; 16 is generous. SavedLo/Hi are the vendor's pre-override price
// fields (card vendors: min/max; ingredient vendors: the single price in
// both) snapshotted once so the revert restores the true vanilla price even
// if the .unr tuned it per-instance.
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

var StatusItem KeyItemStatus[3];
var string KeyItemNames[3];
var byte WasKeyItemOwned[3];
var byte APGrantedKeyItem[3];

// Bingo-only level-entry keys. 13 new progression items the apworld puts in
// the pool when game_mode==bingo, each gating one or more bookcases spawned
// in the hub levels (Entryhall_hub / Grandstaircase_hub / Grounds_hub +
// Grounds_Night). APGrantedBingoKey[i]==1 means the matching key has been
// delivered by AP this session — the BlockBingo<X>EntryIfMissing helpers
// early-return when their flag is set, and RemoveBingo<X>Blocker tag-scans
// the level to destroy any still-present bookcase. Class-default writes via
// MarkBingoKeyAsGrantedDefault keep the flag sticky across save/load and
// across the per-level watcher instance lifecycle. Index → name mapping in
// BingoKeyNames[] below; new entries here must mirror items.yaml bingo_keys.
var string BingoKeyNames[13];
var byte APGrantedBingoKey[13];

// M7 goal detection: tracks whether we've already fired GOAL_COMPLETE this
// session. Class-default so it survives level transitions (the credits flow
// stays in the same level instance, but defensive-default just in case).
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
// here keeps each curtain stably open after the first fire. Cross-session
// note: on a fresh game launch this resets to all zeros, so if the save
// preserved the mover position as open from a prior session, the first
// re-entry will toggle it back to closed once before stabilising —
// acceptable as a known edge case.
var byte WCnFiredThisSession[12];

// Sticky bingo-mode flag. Set once Snapshot finds an MGBingoLearnAllSpells
// actor in any level; persists for the rest of the session via class-default
// write. In bingo mode, Snapshot skips the APGrantedSpell baseline so the
// revert loop wipes MGBingo's R/Sk/D/Sp grants (and any other spell Harry
// owns at snapshot time) — AP must deliver every spell. Vanilla mode is
// unchanged: cutscene starters get baselined and survive.
var byte bBingoMode;

// Bingo Great Hall key config. Delivered once per process by the client as
// "GOALCFG c,s,l,d,q,mask" (from apworld slot_data) → SetGoalConfigCSV writes
// these class-defaults; sticky across level transitions / save-load like
// bBingoMode and APGrantedBingoKey. GoalSatisfied() (Phase 2) reads them; the
// Great Hall bookcase (Phase 3) clears when every enabled clause passes. A
// clause of 0 / off drops out of the AND (apworld already applied the
// all-off → all-spells fallback, so this is never a no-gate config in bingo).
var byte bGoalConfigured;
var int  GoalCards;
var int  GoalSpells;
var int  GoalLevels;
// Int (not byte) so the int return of NextCsvInt assigns without a coercion
// question; only ever 0/1.
var int  GoalDuels;
var int  GoalQuidditch;
var int  GoalLevelMask;
// Clause-3 objective bitset (goal_plan.md §6.4: 11 objectives), set by the
// Phase-4 detectors. Class-default sticky.
var byte GoalLevelDone[16];
// One-shot: set when the clauses are first all satisfied. Gates the Great
// Hall bookcase removal AND the bInEndGame GOAL_COMPLETE fire in bingo.
var byte WasGoalUnlocked;
// Caps'd name of the adventure level abandoned via the Return-to-Hub menu
// (stamped by APFEInGamePage.TeleportToHub). CheckExitedLevelObjective uses
// it to tell a menu-bail apart from a real Mechanism-C completion; cleared on
// any bind back inside a Mechanism-C level (a fresh attempt supersedes a bail).
var string MenuReturnFromLevelCaps;
// Caps'd name of the level the watcher was last bound in. Mechanism-C credits
// off OUR own per-level bind history, NOT harry.PreviousLevelName: the return
// SmartStart auto-saves, and harry.PreSaveGame wipes PreviousLevelName before
// Snapshot ever runs (goal_plan.md §12 #15). Class-default sticky.
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

// --- Archipelago trap lifetime state (05-trap-items.md §8) ---------------
// All class-default + sticky like bBingoMode / APGrantedSpell: the backup
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
// (not watcher instance) is the discriminator so bingo's streamed-sublevel
// watcher churn never false-triggers.
var name TrapLastLevelName;

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

// Bingo only: every wizard card is an AP location reachable by replaying its
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
        Log("[Archipelago] APCardWatcher.ClearAllVendorOwnership: cleared " $ cleared $ " card(s) from vendor stock (bingo: every card is a replayable AP location)");
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

    // Bingo-only level-entry keys. Order matters — APGrantedBingoKey[] is
    // indexed by this. Keep in sync with items.yaml bingo_keys section and
    // with TryApplyBingoKey / RemoveBingo<X>Blocker dispatch in APGameInfo.
    BingoKeyNames[0]  = "Chamber of Secrets Key";
    BingoKeyNames[1]  = "Spongify Challenge Key";
    BingoKeyNames[2]  = "Skurge Challenge Key";
    BingoKeyNames[3]  = "Rictusempra Challenge Key";
    BingoKeyNames[4]  = "Diffindo Challenge Key";
    BingoKeyNames[5]  = "Boomslang Level Key";
    BingoKeyNames[6]  = "Whomping Willow Key";
    BingoKeyNames[7]  = "Forbidden Forest Key";
    BingoKeyNames[8]  = "Slytherin Common Room Key";
    BingoKeyNames[9]  = "Goyle Level Key";
    BingoKeyNames[10] = "Bicorn Level Key";
    BingoKeyNames[11] = "Duelling Key";
    BingoKeyNames[12] = "Quidditch Key";

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
    for (i = 0; i < NUM_BINGO_KEYS; i++)
    {
        if (default.APGrantedBingoKey[i] == 1)
        {
            APGrantedBingoKey[i] = 1;
        }
    }
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

// Bingo key dispatch. Returns the BingoKeyNames[] index, or -1 if the string
// doesn't match a known bingo key. APGameInfo.TryApplyBingoKey uses this both
// to stamp the class-default flag and to dispatch to the right
// RemoveBingo<X>Blocker helper.
static function int BingoKeyIndexFromName(string KeyName)
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
    return -1;
}

static function MarkBingoKeyAsAPGrantedDefault(string KeyName)
{
    local int idx;
    idx = BingoKeyIndexFromName(KeyName);
    if (idx < 0)
    {
        return;
    }
    default.APGrantedBingoKey[idx] = 1;
    Log("[Archipelago] APCardWatcher.MarkBingoKeyAsAPGrantedDefault: " $ KeyName $ " (idx=" $ idx $ " class default set)");
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
// level). Level NAME is the change discriminator — robust against bingo's
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
// slot_data, sent every HELLO). Class-default + sticky like bBingoMode /
// APGrantedBingoKey; idempotent (re-parsing the same csv re-asserts the same
// values). The apworld already applied the all-off → all-spells fallback, so
// a bingo seed never delivers an all-zero (no-gate) config.
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

// Spell-ball skin per spell index (0 Alohomora,1 Diffindo,2 Flipendo,3 Lumos,
// 4 Rictusempra,5 Skurge,6 Spongify — same order as SpellNames[]). Alohomora,
// Flipendo and Lumos have no baked icon imported anywhere → defaultSpellIcon.
static function Texture SpellIconForIndex(int idx)
{
    if (idx == 1) return Texture(DynamicLoadObject("HGame.Icons.DiffindoTexture", class'Texture'));
    if (idx == 4) return Texture(DynamicLoadObject("HGame.Icons.RictusempraTexture", class'Texture'));
    if (idx == 5) return Texture(DynamicLoadObject("HGame.Icons.SkurgeTexture", class'Texture'));
    if (idx == 6) return Texture(DynamicLoadObject("HGame.Icons.tSpongifyTexture", class'Texture'));
    return Texture(DynamicLoadObject("HGame.Icons.defaultSpellIcon", class'Texture'));
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
        // No vanilla world-pickup prop for spells (they are learned, not
        // dropped); skSpellBall's HPMeshActor default DrawScale is 1.0.
        // Constant, tunable — there is no vanilla pickup to anchor on.
        m = Mesh(DynamicLoadObject("HProps.skSpellBallMesh", class'Mesh'));
        tex = SpellIconForIndex(code - 1000);
        ApplyMeshSkin(a, m, tex, True, 1.0, False);
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
        // Bingo level/challenge bookcase key — the vanilla "silver key" FX
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

// Clause-3 objective index for a Caps'd map name (goal_plan.md §6.4). The 3
// key-item ingredient levels (idx 0-2) are listed too: their StatusItem nCount
// path is unreliable in this build (orphaned StatusItemBitOGoyle; the
// Adv3DungeonQuest Bicorn prop has null class refs so PickupItem early-returns
// - §12 #16/#17), so they are credited the robust Willow/Slytherin way: by
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
    return -1;
}

// Mark a clause-3 level objective complete. Dedupe is UNIFORM with
// stars/duels/quidditch via NonCardLocationChecked[apId-LOC_BASE] AND we still
// set the sticky
// GoalLevelDone[idx] bit, which is the clause-3 gate state GoalSatisfied()
// reads. Fires the Heretic-style "X Level Complete" CHECK_LOCID 5760700+idx.
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

// True when every ENABLED bingo Great Hall key clause passes. A clause with a
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
    local APGameInfo gi;

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
    // skips APGameInfo.InitGame, leaving the post-save GameInfo with IPCActor=None
    // even though the persistent singleton is still alive. Pre-fix this dropped
    // every game→client CHECK after a save-load.
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
    ScanBossKills(ipc);

    // Lesson-end hook for the four spell-tutorial location checks.
    // Fires CHECK_SPELL the tick after harry.CurrSpellLesson transitions from
    // a valid lesson to None — which vanilla `harry.EndSpellLearning()` does
    // inside `SpellLessonTrigger.EndLesson()` (uc:842-879), right after
    // `AddToSpellBook(...)` and before the teleport-to-challenge-level event.
    // The transition is what the player perceives as "minigame finished".
    //
    // Workaround case (Bug the earlier lesson-start hook fixed): when AP has
    // already granted the spell (e.g. start_inventory_from_pool), the
    // IsInSpellBook poll below cannot fire on the lesson because there's no
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
            HarryRef.SpellBook[SpellClasses[i].default.SpellType] = None;
            Log("[Archipelago] APCardWatcher: reverted vanilla " $ SpellNames[i]);
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

    // Bingo Great Hall key: the first tick every enabled clause passes, open
    // the bookcase and arm the goal. WasGoalUnlocked is sticky class-default
    // so it survives level transitions / save-load and never re-locks; the
    // spawn helper early-returns on it so the bookcase never respawns.
    if (default.bBingoMode == 1 && default.bGoalConfigured == 1
        && default.WasGoalUnlocked == 0 && GoalSatisfied())
    {
        default.WasGoalUnlocked = 1;
        Log("[Archipelago] APCardWatcher: bingo goal clauses satisfied - opening Great Hall");
        gi = APGameInfo(Level.Game);
        if (gi != None) gi.RemoveBingoGreatHallBlocker();
    }

    // M7 goal detection: poll FEBook.bInEndGame, set True by ShowCredits()
    // (FEBook.uc:1392) when the post-Basilisk credits cutscene runs. Access
    // pattern mirrors harry.uc:5582 / harry.uc:339 — go through the live
    // gameplay UWorld's HPConsole to reach the active menuBook (HarryRef's
    // own .menuBook field can be stale; the explicit lookup is known-good).
    // One-shot: WasInEndGame guards re-fire. Null-check Player/Console/menuBook
    // because they can briefly be None during level loads. In bingo the fire
    // is gated on WasGoalUnlocked so the open-castle Great Hall can't complete
    // the seed before the 5-clause goal is met (vanilla: unchanged).
    if (WasInEndGame == 0 && HarryRef.Player != None
        && (default.bBingoMode == 0 || default.WasGoalUnlocked == 1))
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

    // Phase C is vanilla-only missed-card recovery. In bingo every level is
    // infinitely replayable, so a card left behind is never lost — assigning
    // it to a vendor instead lets the player buy cards for levels they have
    // not even reached. Flip the pass into a cleanup so vendors never stock
    // cards in bingo. Covers every caller (iGameState transition + snapshot).
    if (default.bBingoMode == 1)
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

    if (assigned > 0)
    {
        Log("[Archipelago] APCardWatcher.AssignMarkersToVendors: assigned " $ assigned $ " marker location(s) to vendor stock");
    }
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
    gi.SpawnAllBingoBlockers();
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
        // Save-load fix: a watcher restored from a .usa save can come back with
        // bSnapshotted=True but stale/zeroed APGrantedSpell[] (e.g. when the
        // class layout changed between save creation and load). That makes the
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
        Log("[Archipelago] APCardWatcher: promoted self to LatestInstance (self has live Player, current does not)");
    }
}

// Detect bingo-distribution maps by looking for an MGBingoLearnAllSpells
// actor placed in the level (the package MGBingo.u ships only with the
// bingo install, so we identify by class-name string to avoid a hard
// reference that would prevent HPArchipelago.u from loading on the
// vanilla/Modded install). Once detected, the flag persists for the rest
// of the session via class-default write; sub-levels without the actor
// still get treated as bingo mode.
function DetectBingoMode()
{
    local Actor a;
    local int i;

    if (default.bBingoMode == 1)
    {
        return;
    }
    foreach AllActors(class'Actor', a)
    {
        if (string(a.Class.Name) == "MGBingoLearnAllSpells")
        {
            default.bBingoMode = 1;
            bBingoMode = 1;
            Log("[Archipelago] APCardWatcher: DetectBingoMode - found " $ string(a.Class.Name) $ " - entering bingo mode (sticky)");
            // Wipe stale AP-grant flags carried over from previous vanilla-seed
            // sessions. MarkSpellAsAPGrantedDefault sticks default.APGrantedSpell
            // across save/load, so a prior vanilla seed that precollected
            // Lumos/Flipendo/Alohomora as starters would leave those flags set
            // forever — the bingo revert loop would then skip them and the
            // player keeps L/F/A despite bingo wanting them in the AP pool.
            // Resetting both default and instance flags forces the revert loop
            // to wipe every spell Harry currently has; the AP client's durable
            // resync re-sets the flag for spells legitimately granted by THIS
            // seed as they arrive over IPC via ApplyGrant.
            for (i = 0; i < NUM_SPELLS; i++)
            {
                default.APGrantedSpell[i] = 0;
                APGrantedSpell[i] = 0;
            }
            Log("[Archipelago] APCardWatcher: DetectBingoMode - reset APGrantedSpell[] (AP grants this session will re-set as they arrive)");
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

    DetectBingoMode();

    ownedSpellCount = 0;
    for (i = 0; i < NUM_SPELLS; i++)
    {
        if (HarryRef.IsInSpellBook(SpellClasses[i].default.SpellType))
        {
            // WasSpellOwned suppresses the "new vanilla spell learned"
            // CHECK_SPELL transition in the revert loop. In bingo mode we
            // still want that suppression (MGBingo's PostBeginPlay grants
            // are not a player action) — we just skip APGrantedSpell so the
            // revert loop wipes the spell on its next pass. In vanilla mode
            // both flags get set, which preserves the spell as if AP granted it.
            WasSpellOwned[i] = 1;
            if (default.bBingoMode == 0)
            {
                APGrantedSpell[i] = 1;
                default.APGrantedSpell[i] = 1;
            }
            ownedSpellCount++;
        }
    }
    if (default.bBingoMode == 1)
    {
        Log("[Archipelago] APCardWatcher: initial snapshot - Harry knows " $ ownedSpellCount $ " spells (bingo mode: will revert non-AP spells next tick)");
    }
    else
    {
        Log("[Archipelago] APCardWatcher: initial snapshot - Harry already knows " $ ownedSpellCount $ " spells (baselined as AP-granted, no revert)");
    }

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
    // Subclass-replace each unchecked vanilla challenge star with an
    // APChallengeStarMarker so pickup fires CHECK_LOCID alongside vanilla
    // score. Already-checked stars stay vanilla, so replay still scores.
    ReplaceChallengeStars();
    // Clause-3: credit terminal objective levels (ingredient levels 0-2,
    // Willow 5, Slytherin 6, and the 4 challenges 7-10) from the watcher's
    // own per-level bind history when we leave them. The challenge FinalStar
    // is NOT subclass-replaced: destroy+respawn dropped its Event/CutName so
    // the vanilla win cutscene/travel never fired (level stuck, §12 #18) -
    // a failed challenge restarts in place, so only true completion travels
    // out, exactly like the other terminal levels.
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
    if (class'APIPCActor'.static.GetInstance() != None)
    {
        // 3.0s mirrors APIPCActor.POST_SNAPSHOT_WARMUP_SECS.
        class'APIPCActor'.static.GetInstance().PushDrainStability(3.0);
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

// Clause-3 Mechanism B (goal_plan.md §6.2): poll the boss in its level.
// Aragog: Health<=0 routes to GotoState('stateBeatAragog') (Aragog.uc:176-181),
// the unambiguous "defeated" state (the level has 2 Aragog actors; only the
// beaten boss enters it). Basilisk has TWO phases: BeatBoss() runs at BOTH the
// phase-1 (Tom-revealed, 17170VoldRevealedV2) and final kill, so Health<=0 is
// NOT a final-defeat signal (it fired idx=4 on phase 1 in Stefan's 2026-05-15
// run). Use bBasilFinishedForGood — set True only in BeatBoss()'s
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

    // Tradersanity vendors (plans/06-tradersanity.md).
    TradersanityPass();
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
// once per visit. price_low: flat. price_random: one roll in [LO,HI] (the
// ingredient field has no built-in RandRange, so re-rolling per tick would
// flicker — applied once). price_vanilla: a genuine ingredient vendor keeps
// its true price; a converted card vendor rolls within its original card
// [min,max] so the AP sale still costs a card-like price.
function ApplyVendorPrice(Characters c, int idx)
{
    if (default.TradersanityMode == TRADER_PRICE_LOW)
    {
        SetVendorActivePrice(c, TRADER_PRICE_LOW_BEANS);
        return;
    }
    if (default.TradersanityMode == TRADER_PRICE_RANDOM)
    {
        SetVendorActivePrice(c,
            int(RandRange(TRADER_PRICE_RAND_LO, TRADER_PRICE_RAND_HI)));
        return;
    }
    // price_vanilla
    if (IsTraderCardVendor(idx))
    {
        SetVendorActivePrice(c,
            int(RandRange(TraderSavedLo[idx], TraderSavedHi[idx])));
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
            ApplyVendorPrice(c, idx);
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
        // grants nothing). Null them on this instance: picking the morphed
        // AP token up no longer adds the ingredient to inventory, while the
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

// Clause-3 Mechanism D (challenges 7-10) is NOT a FinalStar subclass-replace.
// Vanilla FinalStar.PickupProp.EndState does PickedUpFinalStar() (EndChallenge)
// AND TriggerEvent(Event,None,None) - that Event (plus the win cutscene's
// FlyTo-by-CutName) is what tallies the challenge and travels back to the hub.
// A destroy+respawn drops Event and CutName, so the level never ends (stuck,
// §12 #18). Challenges are terminal like the other objective levels: a failed
// run restarts in place (EventTimeUpRestart, ChallengeScoreManager.uc), so the
// only way a challenge level travels out is true completion. Credited by
// CheckExitedLevelObjective on exit, same as 0-2/5/6.

// Clause-3 exit-credit for the levels whose ONLY forward progress is
// completing their single objective: 0 Boomslang (Adv4Greenhouse), 1 Bicorn
// (Adv3DungeonQuest), 2 BitOGoyle (Adv6Goyle), 5 Whomping Willow, 6 Slytherin
// Common Room, and 7-10 the four challenges (Ch1Rictusempra/Ch2Skurge/
// Ch3Diffindo/Ch4Spongify). "We left that level" == "we completed it": each is
// terminal and a failed/abandoned attempt restarts in place rather than
// travelling out (challenges: EventTimeUpRestart). We do NOT poll per-item
// state: the ingredient StatusItem path is broken in this build (orphaned
// StatusItemBitOGoyle; the Bicorn prop has null class refs so
// StatusManager.PickupItem early-returns and nCount never rises - §12 #16/#17),
// the FinalStar can't be subclass-replaced without losing its Event/CutName
// and breaking the win cutscene (§12 #18), and harry.PreviousLevelName is
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
function CheckExitedLevelObjective()
{
    local string curCaps, prevCaps;
    local int idx;
    local APIPCActor ipc;

    curCaps = Caps(string(Level.Outer.Name));
    // Physically back inside an exit-credited level => a fresh attempt; any
    // earlier menu-bail record is moot and must not suppress this run's exit.
    if (curCaps == "ADV1WILLOW" || curCaps == "ADV7SLYTHCOMROOM"
        || curCaps == "ADV4GREENHOUSE" || curCaps == "ADV3DUNGEONQUEST"
        || curCaps == "ADV6GOYLE" || curCaps == "CH1RICTUSEMPRA"
        || curCaps == "CH2SKURGE" || curCaps == "CH3DIFFINDO"
        || curCaps == "CH4SPONGIFY")
        default.MenuReturnFromLevelCaps = "";

    prevCaps = default.LastBoundLevelCaps;
    // Record this bind's level for the NEXT bind's comparison before any
    // early-out, so a single Snapshot per level keeps the history exact and
    // repeated binds in one level are a no-op (prevCaps == curCaps).
    default.LastBoundLevelCaps = curCaps;

    if (prevCaps == "" || prevCaps == curCaps) return;
    idx = class'APCardWatcher'.static.LevelObjectiveIndexFor(prevCaps);
    // 0-2 ingredient levels, 5 Willow, 6 Slytherin, 7-10 challenges. NOT 3/4
    // (boss levels keep their poll detector - leavable without the kill).
    if (idx < 0 || idx == 3 || idx == 4)
        return;                                  // only the exit-driven levels
    if (default.GoalLevelDone[idx] == 1) return; // already credited

    if (prevCaps == default.MenuReturnFromLevelCaps)
    {
        Log("[Archipelago] APCardWatcher.CheckExitedLevelObjective: idx=" $ idx
            $ " skipped - left " $ prevCaps $ " via Return-to-Hub menu");
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
}

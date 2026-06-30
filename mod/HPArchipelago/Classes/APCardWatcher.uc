class APCardWatcher extends Actor;

const MAX_CARD_ID = 101;
const NUM_SPELLS = 7;
const NUM_KEY_ITEMS = 3;
const NUM_BLOCKER_KEYS = 14;

// AP location base id (locations.yaml `base_id`). Used to index
// NonCardLocationChecked[] by `apId - LOC_BASE` for secrets/stars/etc.
// Mirrors `BASE_ID` in apworld/locations.py.
const LOC_BASE = 5760000;
// Window size for the non-card-location dedupe array and every `slot` guard
// below. APContainerMarker.uc and APVendorMarker_Trader.uc carry the same
// const and all MUST hold the same value. A non-card location id_offset >=
// this falls outside the array, so its dedupe is skipped. Sized to cover
// every band with headroom.
const NONCARD_LOC_WINDOW = 2048;
// Max characters per CHECKEDOUT chunk line. The full checked-id list outgrows
// the engine's per-line TcpLink transmit limit (one over-length SendText
// truncates mid-id, null-pads, and the next IPC line bleeds into the tail), so
// NextCheckedOutChunk caps each line well under it. Generous margin: each line
// also carries "CHECKEDOUT " and a trailing newline on top of this.
const CHECKEDOUT_CHUNK_CHARS = 600;
// Class-default dedup for non-card AP locations (secrets, stars, vendors,
// duels, matches, level completions). Indexed by `apId - LOC_BASE`.
// Class-default so it persists across level transitions in a session, like
// LocationChecked[]. The dimension literal MUST equal NONCARD_LOC_WINDOW:
// M212 UnrealScript array dimensions take an integer literal, not a const
// (no vanilla array in the decompiled retail source uses a const/enum dim),
// so the constant cannot be referenced here directly.
var byte NonCardLocationChecked[2048];

var harry HarryRef;
var StatusItemWizardCards siBronze;
var StatusItemWizardCards siSilver;
var StatusItemWizardCards siGold;
var byte WasOwnedByHarry[102];
var bool bSnapshotted;

// HarryRef.bIsCaptured from the previous Timer tick. Its falling edge (a
// cutscene / player-capture just ended) is when harry.PlayerCutRelease re-arms
// every pixie's 3s fly-in window. Instance state: resets with each per-level
// watcher, which is correct since capture is level-local.
var byte bWasCapturedPrev;

// Folio emptiness sampled at Snapshot entry, BEFORE ReassertAPGrantedCards
// re-asserts this slot's AP cards. A genuine new game binds with an empty
// folio; a loaded save binds with its .usa folio already restored. The live
// nCount sum can't tell them apart any more because RESYNC fills the folio on
// connect, so the NEWGAME signal and the startup-safety-save scope read this
// pre-RESYNC sample instead. Per-instance: each level's watcher re-samples.
var bool bFolioEmptyAtSnapshot;

// Durable AP-granted-card ledger. Class-default (process-lifetime, survives the
// per-level watcher respawn and save-load) so a wizard card the slot received
// from AP is never mistaken for a fresh vanilla pickup by the Timer revert loop,
// and so a folio that dropped one (save-load / death-reload race, or a cold load
// with no .usa-backed mod state) can be re-asserted. Indexed by card Id (1..101);
// the value is the card's tier (CARD_TIER_*) so ReassertAPGrantedCards knows
// which StatusItem to set ownership on without re-resolving the class. Mirrors
// default.APGrantedSpell[] / default.APGrantedBlockerKey[]; written by every card
// grant (APGameInfo.TryApplyCard) and by the RESYNC_CARDS client ledger
// (ApplyResyncCards). Dimension literal MUST be 102 (M212 array dims take an
// integer literal, not a const). Matches WasOwnedByHarry[] / LocationChecked[].
const CARD_TIER_BRONZE = 1;
const CARD_TIER_SILVER = 2;
const CARD_TIER_GOLD   = 3;
var byte APGrantedCard[102];

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
// var (NOT class-default/travel), re-spawned each level like the
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

// Bookcase-blocker keys. 14 progression items, each gating one or more
// bookcases the mod spawns in the hub levels (Entryhall_hub / Grandstaircase_hub
// / Grounds_hub + Grounds_Night). Used in BOTH game modes: open castle puts all
// 14 in the AP pool, vanilla puts the 7 in VANILLA_BLOCKED_KEY_NAMES in the
// pool (cumulative chain + Duelling/Quidditch standalone) and precollects the
// rest. APGrantedBlockerKey[i]==1 means the matching key has been delivered by
// AP. The BlockOpenCastle<X>EntryIfMissing helpers early-return when their
// flag is set, and RemoveOpenCastle<X>Blocker tag-scans the level to destroy
// any still-present bookcase. Class-default writes via MarkBlockerKeyAsAPGranted-
// Default keep the flag sticky across save/load and across the per-level watcher
// instance lifecycle. Index → name mapping in BlockerKeyNames[] below; new
// entries here must mirror items.yaml blocker_keys.
// Dimension literal MUST be the integer 14, not NUM_BLOCKER_KEYS (M212 array
// dims take an integer literal, not a const). Keep in sync with the const.
var string BlockerKeyNames[14];
var byte APGrantedBlockerKey[14];

// M7 goal detection: 1 once GOAL_COMPLETE has fired in this watcher. Plain
// per-level instance var, so it resets when the watcher respawns; re-firing
// GOAL_COMPLETE after a level change is harmless because the server dedupes goal
// completion. The durable cross-connect anchor is ipc.bGoalReached on the
// persistent singleton (see the fire site), not this flag.
var byte WasInEndGame;

// Singleton pointer lives ONLY on the class default (`default.LatestInstance`).
// Each per-level watcher's instance copy of this field must always be None,
// otherwise the save graph trips on a cross-package ref (Entryhall_hub.APCard-
// Watcher.LatestInstance → Entry.APCardWatcher0 from app launch) and aborts
// SaveGame with "Graph is linked to external private object". PreBeginPlay
// clears it for fresh spawns; Timer clears it defensively every tick for
// deserialized watchers. Mirrors the same fix in APHUDToast.uc.
var APCardWatcher LatestInstance;

// Class-default array. Survives level transitions in a session (default vars are
// process-wide). APCardMarker.Touch sets LocationChecked[id]=1 after firing its
// CHECK; APCardMarker.PostBeginPlay self-destroys if its id is already checked.
var byte LocationChecked[102];

// Durable resync handshake. Set by ApplyResyncSpells the first time the client
// delivers the AP-Data-Storage spell ledger ("RESYNC_SPELLS <csv>"), at which
// point default.APGrantedSpell[] reflects every spell this slot has ever
// received from AP. The revert loop gates its wipe branch on this flag so a
// fresh process / save-load can never wipe AP-granted spells before the client
// has had a chance to re-assert them. Sticky for the lifetime of the process
// (never cleared); a reconnect / late client launch re-arms it on arrival.
var byte bResyncReceived;

// Open castle Great Hall key config + clause-3 progress now live in
// APGoalTracker (goal definition, GoalSatisfied, the progress readers). The
// watcher keeps only WasGoalUnlocked, the Timer's "goal has fired" latch.
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
// LoadGame 0, which reloads the autosave and so travels OUT of the level.
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
// TriggerEvent likely fires the teleport on the same frame. The new
// watcher in the challenge level still observes the cleared flag and the
// stamped InLessonForSpell entry, and fires the check there).
var byte InLessonForSpell[7];

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
// Earliest Level.TimeSeconds at which a pending inbound kill may apply.
// Deliberately an INSTANCE var (the DeathLink flags above are class-default):
// it is a Level.TimeSeconds-relative cooldown and that clock resets to ~0 on
// level travel, so a sticky value would read as a stale far-future gate in the
// next level. The per-level watcher respawn hands each level a fresh clock, and
// the kill must not outlive the reload anyway. ScanDeathLink holds the kill
// until Harry has been continuously playable past this time, so a one-tick
// PlayerWalking flicker between cutscene segments cannot trigger it. Mirrors the
// grant drain's NextGrantDrainEarliest (APIPCActor.uc).
var float DeathLinkSettleEarliest;
const DEATHLINK_SETTLE_SECS = 1.0;
const DEATHLINK_WARMUP_SECS = 3.0;

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
            // Mirror to class default so the flag survives level transitions.
            // Each level spawns a fresh watcher with zeroed instance arrays,
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
// build (broken Adv3DungeonQuest Bicorn prop / orphaned StatusItemBitOGoyle).
// They are credited by leaving their terminal level instead
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
// Vendors then offer them for sale, wasting beans for a duplicate CHECK that
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

// Re-assert Harry ownership for every card this slot has received from AP
// (default.APGrantedCard[id] != 0) that the live folio is currently missing, and
// protect all of them from the Timer revert loop (WasOwnedByHarry). Quiet: no
// pickup FX, idempotent (SetCardOwner on an already-owned id only reorders, never
// double-counts). Heals the save-load / death-reload drop that the client's
// consumed-indices ledger would otherwise make permanent (no GRANT replay).
// Called from Snapshot (per level) and from ApplyResyncCards when a bound watcher
// is already live. The tier value selects the matching StatusItem: card ownership
// is per-tier, so a silver id set on siBronze would wrongly raise siBronze.nCount.
function ReassertAPGrantedCards()
{
    local int id, restored;

    if (siBronze == None || siSilver == None || siGold == None)
    {
        return;
    }
    restored = 0;
    for (id = 1; id <= MAX_CARD_ID; id++)
    {
        if (default.APGrantedCard[id] == 0)
        {
            continue;
        }
        // Suppress the revert loop for this id even if ownership is restored
        // after Snapshot baselined it (the exact reload race this fixes).
        WasOwnedByHarry[id] = 1;
        if (IsHarryOwned(id))
        {
            continue;
        }
        if (default.APGrantedCard[id] == CARD_TIER_BRONZE)
        {
            siBronze.SetCardOwner(id, siBronze.ECardOwner.CardOwner_Harry);
        }
        else if (default.APGrantedCard[id] == CARD_TIER_SILVER)
        {
            siSilver.SetCardOwner(id, siSilver.ECardOwner.CardOwner_Harry);
        }
        else if (default.APGrantedCard[id] == CARD_TIER_GOLD)
        {
            siGold.SetCardOwner(id, siGold.ECardOwner.CardOwner_Harry);
        }
        restored++;
    }
    if (restored > 0)
    {
        Log("[Archipelago] APCardWatcher.ReassertAPGrantedCards: restored " $ restored $ " AP-granted card(s) missing from folio");
    }
}

// Re-derive the card-set milestone rewards from the restored card counts. The
// extra health bar (vanilla harry.DoCelebrateCardSet -> health potential) and
// the silver Gold-Card-Room keys (StatusItemSilverCards.UpdateCount -> Lock1..4)
// are one-shot side effects of the live card pickup. The RESYNC restore path
// sets card ownership directly via SetCardOwner and never replays them, so a
// card that arrives by resync (a new game / reconnect with already-received
// cards) leaves its milestone ungranted. Both rewards are pure functions of the
// count, so reconcile the derived stats: one health icon per 10 bronze (plus the
// base icon), one lock per 10 silver. Idempotent (tops up only the shortfall, and
// never lowers), so it is a no-op on a load whose folio is already correct.
function ReconcileCardMilestones()
{
    local StatusManager ms;
    local StatusItemHealth siHealth;
    local int nBronze, desiredPotential, healthShortfall;

    if (HarryRef == None || HarryRef.managerStatus == None) return;
    if (siBronze == None || siSilver == None) return;
    ms = HarryRef.managerStatus;
    nBronze = siBronze.nCount;

    // Extra health bars. Vanilla seeds one icon and adds one per 10 bronze,
    // capped at the item's nMaxCount. A positive AddHealthPotential also tops
    // current HP to the new max, matching the vanilla celebration heal.
    siHealth = StatusItemHealth(ms.GetStatusItem(class'StatusGroupHealth', class'StatusItemHealth'));
    if (siHealth != None && siHealth.nUnitsPerIcon > 0)
    {
        desiredPotential = (1 + (nBronze / 10)) * siHealth.nUnitsPerIcon;
        if (siHealth.nMaxCount > 0 && desiredPotential > siHealth.nMaxCount)
        {
            desiredPotential = siHealth.nMaxCount;
        }
        healthShortfall = desiredPotential - siHealth.nCurrCountPotential;
        if (healthShortfall > 0)
        {
            ms.AddHealthPotential(healthShortfall);
            Log("[Archipelago] APCardWatcher.ReconcileCardMilestones: +" $ healthShortfall
                $ " health potential for " $ nBronze $ " bronze cards (target " $ desiredPotential $ ")");
        }
    }

    // Silver Gold-Card-Room keys: one lock per completed set of 10 silver cards.
    ReconcileSilverLock(ms, class'StatusItemLock1', siSilver.nCount >= 10);
    ReconcileSilverLock(ms, class'StatusItemLock2', siSilver.nCount >= 20);
    ReconcileSilverLock(ms, class'StatusItemLock3', siSilver.nCount >= 30);
    ReconcileSilverLock(ms, class'StatusItemLock4', siSilver.nCount >= 40);
}

// Set one Gold-Card-Room lock to owned when its silver threshold is met.
// Idempotent: only raises a missing lock to 1, never lowers one.
function ReconcileSilverLock(StatusManager ms, class<StatusItem> lockClass, bool bWanted)
{
    local StatusItem siLock;

    if (!bWanted || ms == None) return;
    siLock = ms.GetStatusItem(class'StatusGroupLocks', lockClass);
    if (siLock != None && siLock.nCount < 1)
    {
        ms.IncrementCount(class'StatusGroupLocks', lockClass, 1);
        Log("[Archipelago] APCardWatcher.ReconcileSilverLock: granted " $ string(lockClass) $ " (silver milestone)");
    }
}

event PreBeginPlay()
{
    local int i;
    Super.PreBeginPlay();
    Log("[Archipelago] APCardWatcher.PreBeginPlay - starting timer (Level=" $ string(Level)
        $ " Level.Outer.Name=" $ string(Level.Outer.Name) $ ")");

    // Critical save-graph hygiene. See the comment above the LatestInstance
    // declaration. Spawn() seeds the instance copy from the class default,
    // which may point at the prior level's (or Entry's) watcher.
    LatestInstance = None;

    default.LatestInstance = self;
    SetTimer(0.25, true);

    // Durable open castle detection BEFORE the default->instance copy loops below,
    // so on the HP2 Bingo install they see the wiped default.APGrantedSpell[].
    // Works on the save-load path (ProcessServerTravel skips InitGame) since
    // it needs no instance/level/IPC.
    class'APModeDetector'.static.EnsureOpenCastleModeDetected();

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

    // Bookcase-blocker keys (shared by open castle and vanilla). Order matters.
    // APGrantedBlockerKey[] is indexed by this. Keep in sync with items.yaml
    // blocker_keys section and with TryApplyBlockerKey / RemoveOpenCastle<X>Blocker
    // dispatch in APGameInfo.
    for (i = 0; i < NUM_BLOCKER_KEYS; i++)
        BlockerKeyNames[i] = BlockerKeyName(i);

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
    class'APLevelSetup'.static.NeutralizeGryffindorSpellGiver(self, HarryRef);
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

// Class-default-only marker so a card grant (APGameInfo.TryApplyCard) and the
// RESYNC_CARDS ledger (ApplyResyncCards) record the card's tier durably even when
// no watcher instance is alive. The Timer revert loop reads this to never revert
// an AP-granted card as a vanilla pickup; ReassertAPGrantedCards reads the tier to
// restore a dropped card to the right StatusItem. Mirrors
// MarkSpellAsAPGrantedDefault. tier is CARD_TIER_BRONZE / _SILVER / _GOLD.
static function MarkCardAsAPGrantedDefault(int id, int tier)
{
    if (id < 1 || id > MAX_CARD_ID)
    {
        return;
    }
    default.APGrantedCard[id] = byte(tier);
    Log("[Archipelago] APCardWatcher.MarkCardAsAPGrantedDefault: id=" $ id $ " tier=" $ string(tier) $ " (class default set)");
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
        name = class'APCsvCodec'.static.NextCsvToken(rest);
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
// current level is destroyed. The consumed-indices ledger blocks GRANT replay,
// so without this a cold load with wiped class-defaults strands the slot.
// Falls back to the class-default-only marker when no GameInfo is reachable
// (resync arrived before any level Game exists).
static function ApplyResyncBlockerKeys(string CsvNames)
{
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
        name = class'APCsvCodec'.static.NextCsvToken(rest);
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
        name = class'APCsvCodec'.static.NextCsvToken(rest);
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

// Durable card-grant resync entry point. The client's RESYNC_CARDS line carries
// the wizard-card UScript class names (GRANT-payload form) of every card this
// slot has ever received from AP, sent on every Connected and game HELLO. Records
// each card's tier in default.APGrantedCard[] (so the revert loop never wipes it
// and a dropped card can be restored to the right StatusItem), then re-asserts
// ownership on the live folio if a bound watcher exists. Otherwise the next
// Snapshot picks the flags up from the class-defaults. Mirrors ApplyResyncSpells /
// ApplyResyncBlockerKeys: cards have no .usa-backed store and the consumed-indices
// ledger blocks GRANT replay, so without this a save-load / death-reload that
// dropped a card from the folio is unrecoverable. Idempotent.
static function ApplyResyncCards(string CsvNames)
{
    local int id, tier;
    local string rest, name;
    local APCardWatcher w;
    local class<WizardCardIcon> cardClass;

    Log("[Archipelago] APCardWatcher.ApplyResyncCards: csv='" $ CsvNames $ "'");

    rest = CsvNames;
    while (rest != "")
    {
        name = class'APCsvCodec'.static.NextCsvToken(rest);
        if (name == "") continue;

        cardClass = class<WizardCardIcon>(DynamicLoadObject("HGame." $ name, class'Class'));
        if (cardClass == None) continue;
        id = cardClass.default.Id;
        if (id < 1 || id > MAX_CARD_ID) continue;

        if (ClassIsChildOf(cardClass, class'BronzeCards'))
        {
            tier = CARD_TIER_BRONZE;
        }
        else if (ClassIsChildOf(cardClass, class'SilverCards'))
        {
            tier = CARD_TIER_SILVER;
        }
        else if (ClassIsChildOf(cardClass, class'Goldcards'))
        {
            tier = CARD_TIER_GOLD;
        }
        else
        {
            continue;
        }
        MarkCardAsAPGrantedDefault(id, tier);
    }

    // Re-assert ownership immediately when a bound watcher is live; a pre-bind
    // resync (cold load) is picked up by the first post-Bind Snapshot instead.
    // Skip on a new game (empty folio at the last Snapshot): the NEWGAME GRANT
    // replay delivers those cards fresh with their pickup celebration, so only
    // the resync branch (loaded save / reconnect) needs the silent restore.
    w = class'APCardWatcher'.static.GetLatest();
    if (w != None && w.bSnapshotted && !w.bFolioEmptyAtSnapshot)
    {
        w.ReassertAPGrantedCards();
        w.ReconcileCardMilestones();
    }
}

// Bookcase-blocker-key dispatch. Returns the BlockerKeyNames[] index, or -1 if
// the string doesn't match a known key. APGameInfo.TryApplyBlockerKey uses this
// both to stamp the class-default flag and to dispatch to the right
// RemoveOpenCastle<X>Blocker helper.
// Single source of truth for the 14 bookcase-blocker key names, index 0-13.
// The instance BlockerKeyNames[] (filled in PreBeginPlay) and the name->index
// lookup below both derive from this, and the open-castle blocker dispatch in
// APGameInfo keys off the same indices.
static function string BlockerKeyName(int i)
{
    switch (i)
    {
        case 0:  return "Chamber of Secrets Key";
        case 1:  return "Spongify Challenge Key";
        case 2:  return "Skurge Challenge Key";
        case 3:  return "Rictusempra Challenge Key";
        case 4:  return "Diffindo Challenge Key";
        case 5:  return "Boomslang Level Key";
        case 6:  return "Whomping Willow Key";
        case 7:  return "Forbidden Forest Key";
        case 8:  return "Slytherin Common Room Key";
        case 9:  return "Goyle Level Key";
        case 10: return "Bicorn Level Key";
        case 11: return "Duelling Key";
        case 12: return "Quidditch Key";
        case 13: return "Gryffindor Challenge Key";
    }
    return "";
}

static function int BlockerKeyIndexFromName(string KeyName)
{
    local int i;
    for (i = 0; i < NUM_BLOCKER_KEYS; i++)
        if (BlockerKeyName(i) == KeyName) return i;
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

// Collapse the post-cutscene pixie dead-zone. When a cutscene or player-capture
// ends, harry.PlayerCutRelease throws every CornishPixie back into
// stateLoopSplinePath, which re-arms a 3s StayOnSpline fly-in: eVulnerableToSpell
// is SPELL_None for the duration and SpellCursor refuses the pixie as a lock-on
// target, so Rictusempra appears unresponsive. On the capture-release edge,
// zero that timer on any pixie still flying in so it is castable at once. Only
// StayOnSpline is touched: the pixie's own Tick flips eVulnerableToSpell back
// once StayOnSpline reads negative, leaving stunned / hit / run-away states and
// the normal between-hits recovery window alone.
function PixieCutsceneTick()
{
    local CornishPixie p;
    local bool capturedNow;

    if (HarryRef == None)
    {
        return;
    }
    capturedNow = HarryRef.bIsCaptured;
    if (bWasCapturedPrev == 1 && !capturedNow)
    {
        foreach HarryRef.AllActors(class'CornishPixie', p)
        {
            if (p.IsInState('stateLoopSplinePath') && p.StayOnSpline > 0.0)
            {
                p.StayOnSpline = -1.0;
            }
        }
    }
    if (capturedNow)
    {
        bWasCapturedPrev = 1;
    }
    else
    {
        bWasCapturedPrev = 0;
    }
}

// Inbound DeathLink arm (DEATHLINK IPC line). Class-default + sticky like the
// other setters; ScanDeathLink applies it on the next playable tick. Setting
// 1 over an already-pending 1 is idempotent (a death you can't act on yet
// collapses to a single kill on return, correct, you only die once).
static function SetPendingDeathLink()
{
    default.bPendingDeathLink = 1;
    Log("[Archipelago] APCardWatcher.SetPendingDeathLink: inbound DeathLink armed");
}

// Ingest the client's CHECKED resync (comma-separated AP location ids the
// server already has as checked for this slot). Stamps card apIds into
// default.LocationChecked[cardId] and everything else into
// default.NonCardLocationChecked[apId - LOC_BASE], so the mod's
// process-lifetime dedupe arrays match the AP server's source of truth across
// game close+reload (class-defaults are compiled, never read from the .usa).
// Level-completion apIds (5760700..5760711 → slot 700..711) additionally
// re-stamp APGoalTracker's GoalLevelDone[idx], so a cold load can't leave the
// open-castle goal evaluator stranded. The bookcase / hub Timer re-evaluates
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
        apId = class'APCsvCodec'.static.NextCsvInt(rest);
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
                class'APGoalTracker'.default.GoalLevelDone[slot - 700] = 1;
                nGoalLevel++;
            }
        }
    }
    Log("[Archipelago] APCardWatcher.SetCheckedLocationsCSV: stamped "
        $ nCard $ " card check(s) + " $ nNonCard $ " non-card check(s) ("
        $ nGoalLevel $ " level completion(s) → GoalLevelDone[])");
}

// Inverse of SetCheckedLocationsCSV: serialize the process-lifetime checked
// arrays back to comma-separated AP location ids, emitted as one or more
// length-bounded chunks. SendCheckedOut ships each chunk as its own CHECKEDOUT
// line on every bridge (re)connect, so a check fired while the client wasn't
// bridged (client launched after the pickup, or client restarted mid-session)
// is replayed to AP. The client dedupes each line against the server's
// checked_locations, so chunk boundaries and already-known ids are both no-ops.
//
// Chunking exists because the full id list outgrows the engine's per-line
// TcpLink transmit limit; one over-length SendText truncates mid-id and
// corrupts the rest of the IPC stream. Each chunk stays under
// CHECKEDOUT_CHUNK_CHARS.
//
// `cursor` spans both arrays: 1..MAX_CARD_ID walks cards (resolved via
// CardIdToApId, since the band mapping is scrambled), then
// MAX_CARD_ID+1..MAX_CARD_ID+NONCARD_LOC_WINDOW walks non-card slots
// (slot = cursor - MAX_CARD_ID - 1, id = slot + LOC_BASE). Start at 1, call
// until it returns False. Advances `cursor` past everything it emitted and
// returns True while a non-empty chunk remains.
static function bool NextCheckedOutChunk(out int cursor, out string chunk)
{
    local int id, slot;

    chunk = "";
    while (cursor >= 1 && cursor <= MAX_CARD_ID)
    {
        id = cursor;
        cursor++;
        if (default.LocationChecked[id] == 1)
        {
            if (chunk != "") chunk = chunk $ ",";
            chunk = chunk $ string(class'APCardAppearance'.static.CardIdToApId(id));
            if (Len(chunk) >= CHECKEDOUT_CHUNK_CHARS) return True;
        }
    }
    while (cursor > MAX_CARD_ID && cursor <= MAX_CARD_ID + NONCARD_LOC_WINDOW)
    {
        slot = cursor - MAX_CARD_ID - 1;
        cursor++;
        if (default.NonCardLocationChecked[slot] == 1)
        {
            if (chunk != "") chunk = chunk $ ",";
            chunk = chunk $ string(slot + LOC_BASE);
            if (Len(chunk) >= CHECKEDOUT_CHUNK_CHARS) return True;
        }
    }
    return chunk != "";
}

// Convergence sweep after a CHECKED resync. Walks the current level's
// chest / cauldron slots and live APCardMarker actors and bean-swaps /
// destroys the ones whose location is now (post-stamp) in
// default.LocationChecked[].
//
// Why this exists: ReplaceCardChests only runs in InitGame, but the CHECKED
// IPC line arrives asynchronously some hundreds of ms after the game's HELLO.
// By then InitGame has long finished. Without this sweep the chests stay
// in their save-restored "APCardMarker in slot" state until the next level
// transition. Idempotent: a slot already Jellybean (or one whose location
// is still unchecked) is left alone. Mirrors the
// APPEARANCE → RestampMarkerAppearance pattern.
//
// Scope: cards only. chest.bOpened is deliberately NOT restored to True
// here: same-session ReplaceCardChests' bean-swap path doesn't touch
// bOpened either (it only resets when hasUnchecked is true), so leaving it
// matches that behaviour. A chest re-Alohomora'd post-sweep dispenses a
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

// Per-frame shift-to-run upkeep. The speed caps must be re-pinned within a frame
// of the game resetting them (StopAiming, Landed) and raised before a jump's
// takeoff clamp, so this runs off Tick rather than the 0.25s Timer that drives
// the rest of the watcher. Only the active singleton watcher with a bound Harry
// acts; the bean drain stays on Timer via SprintTick. SlowdownClamp runs after,
// re-pinning any active slow (sleepy / ectoplasm / web) so shift can't outrun it.
event Tick(float DeltaTime)
{
    local APSprintController sc;

    if (default.LatestInstance != self || !bSnapshotted)
    {
        return;
    }
    sc = class'APSprintController'.static.GetInstance(self);
    if (sc != None)
    {
        sc.SprintApply(HarryRef);
        sc.SlowdownClamp(HarryRef);
    }
    class'APTrapController'.static.LevicorpusHold(HarryRef);
    class'APTrapController'.static.JellyLegsHold(HarryRef);
    class'APTrapController'.static.ConfundusTint(HarryRef);
}

event Timer()
{
    local harry viewportHarry;
    local APLocationScanner ls;

    // Save-graph hygiene. The instance copy of LatestInstance must always be
    // None (only `default.LatestInstance` is the singleton pointer). A non-None
    // instance copy is a cross-package ref that aborts SaveGame.
    if (LatestInstance != None)
    {
        LatestInstance = None;
    }

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
        // Heal a strafe swap orphaned by a prior save/quit while flipped: the
        // bindings persist but the runtime trap flag reset on reboot.
        class'APTrapController'.static.HealOrphanedStrafe(HarryRef);
        // Same for a Jelly-Legs jump-suppression gate orphaned by a save/quit
        // while the trap was active: the gate may be restored from the save but
        // the runtime trap flag reset on reboot, so clear it when no trap is live.
        class'APTrapController'.static.HealOrphanedJellyLegs(HarryRef);
        // Run the trap lifetime check on this first post-Bind tick too, so a
        // level transition restores the Obliviate spellbook immediately
        // (HarryRef is valid here) instead of one tick later, and before the
        // spell-revert loop, which we return short of, can run. Idempotent
        // with the TrapTick() below; only acts when a trap is active.
        class'APTrapController'.static.TrapTick(HarryRef);
        // Same reasoning for the stuck-ectoplasm release: a save reloaded
        // (death respawn, level return) restores the slime's serialised claim
        // on Harry, so clear it on this first bind tick instead of one tick
        // later. Idempotent; only acts when a slime wrongly claims a Harry.
        ls = class'APLocationScanner'.static.GetInstance(self);
        if (ls != None) ls.ScanStuckEctoplasm();
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

    // Steady-state per-tick orchestration lives in the tick driver.
    class'APTickDriver'.static.DriveTick(self);
}

// Per-tick vanilla wizard-card pickup detection: a card owned since last tick
// that AP did not grant is a fresh pickup - fire the CHECK, revert, stamp checked.
function ReconcileVanillaCardPickups(APIPCActor ipc)
{
    local int id;

    for (id = 1; id <= MAX_CARD_ID; id++)
    {
        if (WasOwnedByHarry[id] == 0 && IsHarryOwned(id))
        {
            // AP-granted cards are expected to be Harry-owned. Never treat one as
            // a fresh vanilla pickup: that revert + spurious CHECK, with the
            // consumed-indices ledger blocking any GRANT replay, is exactly the
            // missing-cards bug. Just baseline it so we stop re-checking. This is
            // the primary fix for the reload race. Ownership can be restored
            // after Snapshot baselined, leaving WasOwnedByHarry 0 here.
            if (default.APGrantedCard[id] != 0)
            {
                WasOwnedByHarry[id] = 1;
                continue;
            }
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
}

// Lesson-end hook for the four spell-tutorial location checks.
// Fires CHECK_SPELL the tick after harry.CurrSpellLesson transitions from
// a valid lesson to None, which vanilla `harry.EndSpellLearning()` does
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
// classroom level and the challenge level. The new watcher inherits
// InLessonForSpell[i] = 1 and fires there if it missed the transition
// before the level change.
function SpellLessonEndHook(APIPCActor ipc)
{
    local int i;

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
}

// Ch7Gryffindor's TriggerTurnOnAllSpells sets harry.bNoSpellBookCheck=
// True, which makes IsInSpellBook return True for EVERY spell
// (harry.uc:568). The revert loop below could then never clear a spell
// and the player keeps full casting. APGameInfo.InitGame destroys the
// actor before it can fire on the normal entry path; clearing the flag
// here every tick also covers a save reloaded inside the room (save-load
// skips InitGame) or any other re-set. Guarded so it only acts/logs when
// actually set. Open-castle-only; vanilla never enters this level.
function ClearGryffindorSpellBookFlag()
{
    if (class'APModeDetector'.default.bOpenCastleMode == 1 && HarryRef.bNoSpellBookCheck
        && Caps(string(Level.Outer.Name)) == "CH7GRYFFINDOR")
    {
        HarryRef.bNoSpellBookCheck = False;
        Log("[Archipelago] APCardWatcher: cleared harry.bNoSpellBookCheck in CH7GRYFFINDOR (open castle)");
    }
}

// Per-tick vanilla spell-learn reconcile: fire CHECK_SPELL on a newly-learned
// vanilla spell, then revert it (gated on the durable resync). The whole loop is
// skipped while the Obliviate trap owns the spellbook.
function ReconcileVanillaSpells(APIPCActor ipc)
{
    local int i;

    for (i = 0; i < NUM_SPELLS; i++)
    {
        // Obliviate Trap active: the spellbook is intentionally emptied
        // (or being restored this very tick by TrapTick). Skip the per-tick
        // vanilla-spell reconciliation entirely so the trap and the revert
        // don't fight; TrapTick owns restore (timer or level change). break
        // (not continue). When active, none of the 7 are reconciled.
        if (class'APTrapController'.default.bSpellTrapActive == 1)
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
            // can't yet classify. A late client connect / save-load that
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
}

// Per-tick key-item pickup detection: fire CHECK on a newly-owned key item.
function ReconcileKeyItems(APIPCActor ipc)
{
    local int i;

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
}

// Spell-cast chat flavor. baseWand.LastCastedSpell is set on
// every successful cast (baseWand.uc:391/463) and survives spell death
// (SubtractFromCastedSpellList never clears it), so its reference
// identity changing since the last 0.25s tick is a reliable "≥1 new
// cast happened" signal. NumCastedSpells is non-monotonic and unread.
// Store-then-compare prevents a double-fire; re-arm to None when the
// casted list drains so the next cast of the same spell still triggers.
// The wand is None during cutscene/menu (guarded). Duel/boss/sword
// casts also reach here but SpellIndexForClass returns -1 for them.
function SaySpellCastFlavor()
{
    local baseWand wand;
    local baseSpell cur;
    local int idx;

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
}

// Clause-3 Mechanism A: getting the Boomslang / Bicorn / BitOGoyle key
// item IS finishing that level (KeyItemStatus index i == objective idx
// i: 0 Boomslang, 1 Bicorn, 2 Goyle). Outside the WasKeyItemOwned
// transition guard above so it also catches the already-owned-at-snapshot
// case; NotifyLevelObjective dedupes on the sticky GoalLevelDone bit.
function CheckKeyItemObjectives()
{
    local int i;

    for (i = 0; i < NUM_KEY_ITEMS; i++)
    {
        if (HasKeyItem(i))
        {
            class'APGoalTracker'.static.NotifyLevelObjective(i);
        }
    }
}

// Open castle Great Hall key: the first tick every enabled clause passes, open
// the bookcase and arm the goal. WasGoalUnlocked is sticky class-default
// so it survives level transitions / save-load and never re-locks; the
// spawn helper early-returns on it so the bookcase never respawns.
function DetectGoalUnlock()
{
    local APGameInfo gi;

    if (class'APModeDetector'.default.bOpenCastleMode == 1 && class'APGoalTracker'.default.bGoalConfigured == 1
        && default.WasGoalUnlocked == 0 && class'APGoalTracker'.static.GoalSatisfied())
    {
        default.WasGoalUnlocked = 1;
        Log("[Archipelago] APCardWatcher: open castle goal clauses satisfied - opening Great Hall");
        gi = APGameInfo(Level.Game);
        if (gi != None) gi.RemoveOpenCastleGreatHallBlocker();
    }
}

// M7 goal detection: poll FEBook.bInEndGame, set True by ShowCredits()
// (FEBook.uc:1392) when the post-Basilisk credits cutscene runs. Access
// pattern mirrors harry.uc:5582 / harry.uc:339. Go through the live
// gameplay UWorld's HPConsole to reach the active menuBook (HarryRef's
// own .menuBook field can be stale; the explicit lookup is known-good).
// One-shot: WasInEndGame guards re-fire. Null-check Player/Console/menuBook
// because they can briefly be None during level loads. In open castle the fire
// is gated on WasGoalUnlocked so the open-castle Great Hall can't complete
// the seed before the 5-clause goal is met (vanilla: unchanged).
function DetectGoalCompletion(APIPCActor ipc)
{
    local HPConsole console;
    local FEBook book;

    if (WasInEndGame == 0 && HarryRef.Player != None
        && (class'APModeDetector'.default.bOpenCastleMode == 0 || default.WasGoalUnlocked == 1))
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
                    // Latch on the persistent singleton so Opened() can replay
                    // GOAL_COMPLETE on a later connect if this send hits a down
                    // bridge (WasInEndGame is per-level instance, can't anchor it).
                    ipc.bGoalReached = True;
                    ipc.SendGoalComplete();
                }
            }
        }
    }
}

// Story-progression watcher. harry.iGameState is the canonical numeric
// story state (set via SetGameState from cutscene `ChangeGameState <n>`
// commands; mirrors the trailing digits of HarryRef.CurrentGameState).
// Drives the Spongify blocker spawn (gated by APGameInfo.SpongifyGameStateGate),
// and the log line is also general-purpose telemetry for any future
// story-state-gated mod logic. One line per transition, quiet otherwise.
function DriveStoryProgression()
{
    if (HarryRef.iGameState != LastGameState)
    {
        Log("[Archipelago] APCardWatcher: iGameState " $ LastGameState $ " -> " $ HarryRef.iGameState $ " (CurrentGameState='" $ HarryRef.CurrentGameState $ "')");
        LastGameState = HarryRef.iGameState;
        // The Spongify blocker is gated on iGameState; re-attempt the spawn
        // pass on every transition so it appears the moment Harry crosses
        // SpongifyGameStateGate without waiting for a level reload.
        // Other blockers are idempotent (tag-scan no-op) so the redundant
        // calls are harmless.
        class'APLevelSetup'.static.TrySpawnClassroomBlockers(self);
        // Several cards have strVendorOwnedAfterGState gates (e.g. GSTATE150
        // for WCFancourt). Re-run the assignment pass so cards become
        // vendor-available the moment their gate opens, without waiting for
        // a level reload.
        AssignMarkersToVendors();
    }
}

// Log a wizard-card nCount change (bronze/silver/gold) when it moves.
function LogCardCountChange()
{
    if (siBronze.nCount != LastBronzeCount || siSilver.nCount != LastSilverCount || siGold.nCount != LastGoldCount)
    {
        Log("[Archipelago] APCardWatcher: nCount CHANGE - Bronze=" $ siBronze.nCount $ " Silver=" $ siSilver.nCount $ " Gold=" $ siGold.nCount $ " (was " $ LastBronzeCount $ "/" $ LastSilverCount $ "/" $ LastGoldCount $ ")");
        LastBronzeCount = siBronze.nCount;
        LastSilverCount = siSilver.nCount;
        LastGoldCount   = siGold.nCount;
    }
}

// Periodic nCount heartbeat log (every 40 ticks).
function TickHeartbeat()
{
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
// so vanilla's lookup writes vendor ownership for nonexistent id 200 (no-op).
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
    // infinitely replayable, so a card left behind is never lost. Assigning
    // it to a vendor instead lets the player buy cards for levels they have
    // not even reached. Flip the pass into a cleanup so vendors never stock
    // cards in open castle. Covers every caller (iGameState transition + snapshot).
    if (class'APModeDetector'.default.bOpenCastleMode == 1)
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
    // Gold tier intentionally not handled. Gold cards are non-sellable in
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
// this card type, leave alone, fallback path will still work). For
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

// Reverse of the SpellClasses[]/SpellNames[] table, maps a live
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
        // now. The Block* functions are idempotent via a tag-scan guard,
        // so calling them here in addition to InitGame can't double-spawn.
        class'APLevelSetup'.static.TrySpawnClassroomBlockers(self);
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

// Per-level call from Snapshot. Durable probe first (covers cold-load into
// sentinel-less levels), then an in-level MGBingoLearnAllSpells actor scan
// as a secondary fallback. IPC `MODE open_castle` is the late authoritative
// belt (APIPCActor). Mirrors the class-default flag/wipe onto this instance.
function DetectOpenCastleMode()
{
    local Actor a;
    local int i;

    if (class'APModeDetector'.default.bOpenCastleMode == 1) return;

    class'APModeDetector'.static.EnsureOpenCastleModeDetected();
    if (class'APModeDetector'.default.bOpenCastleMode == 1)
    {
        for (i = 0; i < NUM_SPELLS; i++) APGrantedSpell[i] = 0;
        return;
    }

    foreach AllActors(class'Actor', a)
    {
        if (string(a.Class.Name) == "MGBingoLearnAllSpells")
        {
            class'APModeDetector'.static.EnterOpenCastleMode("found MGBingoLearnAllSpells actor in level");
            for (i = 0; i < NUM_SPELLS; i++) APGrantedSpell[i] = 0;
            return;
        }
    }
}

function Snapshot()
{
    local int id, i, ownedCardCount, ownedSpellCount;
    local APBeanRoom br;
    local APMorphRegistry mr;
    local APLocationScanner ls;
    local APVendorController vc;

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

    // New-game discriminator for the NEWGAME signal: an empty folio here (before
    // ReassertAPGrantedCards re-asserts this slot's AP cards) means this bind is
    // a genuine new game, not a loaded save. Sampled now because RESYNC fills the
    // folio moments later and would otherwise mask the difference.
    bFolioEmptyAtSnapshot = (ownedCardCount == 0);

    // On a genuine new game (empty folio at entry) the NEWGAME signal fires a
    // full GRANT replay that re-delivers every card fresh, so the vanilla pickup
    // celebration grants the extra health bar / silver key with its toast. Skip
    // the silent reassert + reconcile here so those milestones arrive through that
    // flow, not instantly. A loaded save / reconnect (folio not empty here) has no
    // replay coming, so it still needs the silent restore + milestone reconcile.
    if (!bFolioEmptyAtSnapshot)
    {
        // Restore any AP-granted card the .usa save dropped or a prior revert
        // nuked, and protect every AP-granted id from the revert loop. The durable
        // RESYNC_CARDS ledger (default.APGrantedCard[]) is the source of truth.
        // Runs before the nCount baseline so restored cards are reflected in
        // LastSilverCount and don't log a spurious nCount CHANGE.
        ReassertAPGrantedCards();
        // Re-derive the card-set milestone rewards (extra health bars, silver
        // Gold-Card-Room keys) from the restored counts. The silent restore sets
        // card ownership directly and never replays the vanilla pickup that grants
        // them, so reconcile the derived stats here.
        ReconcileCardMilestones();
    }

    DetectOpenCastleMode();

    // Re-pull AP-grant flags from the class default in case ApplyResyncSpells
    // (or an ApplyGrant) fired between this watcher's PreBeginPlay copy and
    // Snapshot. That one-shot copy would otherwise leave instance stale and
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
    // table didn't natively need, exactly the spell-loss reload bug). The
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
            // 0. Only true AP grants (ApplyGrant via IPC) set it. Spells the
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
    class'APLevelSetup'.static.NeutralizeGryffindorSpellGiver(self, HarryRef);
    // Subclass-replace each unchecked vanilla challenge star with an
    // APChallengeStarMarker so pickup fires CHECK_LOCID alongside vanilla
    // score. Already-checked stars stay vanilla, so replay still scores.
    class'APLevelSetup'.static.ReplaceChallengeStars(self);
    // Subclass-replace each unfound, unchecked vanilla SecretAreaMarker with an
    // APSecretMarker so entry fires CHECK_LOCID the same frame, not up to a poll
    // tick later. ScanSecretMarkers stays as the safety net.
    class'APLevelSetup'.static.ReplaceSecretMarkers(self);
    // Swap Ch7Gryffindor's placed FinalStar for an AP-aware end star that
    // credits the completion in EndState, then travels. Ch7Gryffindor has no
    // ChallengeScoreManager, so the vanilla star travels the same frame it is
    // destroyed and ScanFinalStarCompletion's poll can never see it. No-op
    // outside CH7GRYFFINDOR.
    class'APLevelSetup'.static.ReplaceGryffindorEndStar(self);
    // Swap Ch6WizardCard's far-end TriggerChangeLevel (tag changelevel1) for an
    // AP-aware trigger that credits clause-3 objective idx 12 before the stock
    // reload. No-op outside CH6WIZARDCARD.
    class'APLevelSetup'.static.ReplaceGoldRoomEndTrigger(self);
    // Spawn the visible Slytherin Common Room end star here (post-Bind, so the
    // HProp's PreBeginPlay resolves a valid PlayerHarry) - APGameInfo.InitGame
    // runs before Harry exists, so a star spawned there has PlayerHarry==None
    // and HProp.CanPickupNow can never fire. Save-load forces bSnapshotted=
    // False, so this single hook covers the ProcessServerTravel path too.
    if (APGameInfo(Level.Game) != None)
    {
        APGameInfo(Level.Game).SpawnSlytherinEndStarIfMissing();
        // Bean room exit star (open castle): same post-Bind reasoning as the
        // Slytherin star. Level-gated to BeanRewardRoom internally.
        APGameInfo(Level.Game).SpawnBeanRoomExitStarIfMissing();
    }
    else
        Log("[Archipelago] APCardWatcher.Snapshot: Level.Game not APGameInfo - cannot spawn Slytherin / bean room end star");
    // Prune already-collected beans + restore chest/gargoyle drops immediately on
    // a bean-room bind so they do not flash before the per-tick sweep in Timer.
    br = class'APBeanRoom'.static.GetInstance(self);
    if (br != None)
    {
        br.ScanBeanRoom();
        br.ManageBeanDrops();
    }
    // Clause-3: credit terminal objective levels (ingredient levels 0-2,
    // Willow 5, Slytherin 6) from the watcher's own per-level bind history
    // when we leave them. Challenges (7-11) are NOT exit-credited. See
    // ScanFinalStarCompletion (per-tick FinalStar pickup observer), since the
    // entrance door and pause-menu Return-to-Hub button both bypass the
    // "leaving == completion" premise.
    CheckExitedLevelObjective();
    // Drop the per-card curtain in Ch6WizardCard for every gold card Harry
    // currently owns. Vanilla's RemoveHarryOwnedCardsFromLevel destroys
    // owned wci silently with no TriggerEvent, so the per-card curtain
    // movers (Mover76..86 tagged WC1..WC11) would otherwise stay closed
    // on reload. See DropOwnedGoldCardCurtains for the WCn → card mapping.
    ls = class'APLocationScanner'.static.GetInstance(self);
    if (ls != None) ls.DropOwnedGoldCardCurtains();

    // Post-snapshot warmup. Without this, the very first drain happens the
    // moment Snapshot() returns, but level-load cutscenes haven't yet hit
    // their `Play()` call (CutScene.uc:411 sleeps 0.2s in Idle.begin), so
    // every cutscene-presence gate (bPlaying / bIsCaptured / the full-cut HUD flags)
    // returns False and the drain leaks an item during the intro. Pushing
    // the earliest-drain time forward gives the level's bLevelLoadStarts
    // cutscenes time to enter Running state so the existing gates take over.
    // A Snapshot fires after every save-load, so the first post-Snapshot
    // bean diff is the load's autosave revert. Absorb it into the
    // baseline rather than broadcasting.
    if (class'APIPCActor'.static.GetInstance() != None)
    {
        class'APIPCActor'.static.GetInstance().PushDrainStability(3.0);
        class'APIPCActor'.static.GetInstance().bSuppressNextRingOutDiff = 1;
    }

    // Same warmup for the inbound DeathLink kill: hold a death pending across
    // the load while the level's bLevelLoadStarts cutscenes spin up to Running,
    // so it cannot fire in the brief pre-cutscene PlayerWalking window.
    PushDeathLinkSettle(DEATHLINK_WARMUP_SECS);

    class'APMenuCutsceneAid'.static.RecoverStuckCutsceneState(HarryRef);

    // #3: morph every marker that registered before/at snapshot (cards via
    // PostBeginPlay, stars via ReplaceChallengeStars above) to the real item
    // art. No-op until the appearance table has arrived; the Timer one-shot +
    // the APPEARANCE-IPC sweep converge anything registered later or async.
    mr = class'APMorphRegistry'.static.GetInstance(self);
    if (mr != None) mr.RestampMarkerAppearance();

    // Skip-vendor-voices sweep. Vendors come up with their compiled
    // VendorDialog defaults each level load; if the option is on, blank the
    // in-trade string ids now so the first trade in this level is already
    // silent. No-op when off.
    vc = class'APVendorController'.static.GetInstance(self);
    if (vc != None) vc.ApplySkipVendorVoicesPass();
}

function bool IsHarryOwned(int id)
{
    return siBronze.IsOwnedByHarry(id) || siSilver.IsOwnedByHarry(id) || siGold.IsOwnedByHarry(id);
}

// Push the inbound-kill settle window forward by `seconds` from now, bumping
// only when the candidate is later so the level-entry warmup and the per-tick
// not-playable defers never shorten each other. Mirrors
// APIPCActor.PushDrainStability for the grant drain.
function PushDeathLinkSettle(float seconds)
{
    local float candidate;
    candidate = Level.TimeSeconds + seconds;
    if (candidate > DeathLinkSettleEarliest)
    {
        DeathLinkSettleEarliest = candidate;
    }
}

// DeathLink. Outgoing rising-edge detection on the single terminal state
// every death cause funnels through (stateDead → LoadGame 0), plus inbound
// application via a dedicated terminal path that never routes through
// Died/KillHarry. KillHarry's boss-victory branch (harry.uc:1576) would send
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
        // Drop any APPLIED acks that haven't been flushed: their saves never
        // landed, so the items they refer to are about to be discarded by
        // LoadGame 0. The post-reload falling edge below sends DRAIN_ROLLBACK
        // so the client clears them from sent_this_session and re-forwards.
        // Reset the drain-pass counters too so the post-revive resumed drain
        // starts a fresh pass (the pre-death items it counted are reverted).
        if (ipc != None && ipc.PendingApplyAcks.Length > 0)
        {
            Log("[Archipelago] APCardWatcher: discarding " $ string(ipc.PendingApplyAcks.Length)
                $ " unflushed APPLIED ack(s) on death rising-edge");
            ipc.PendingApplyAcks.Remove(0, ipc.PendingApplyAcks.Length);
        }
        if (ipc != None)
        {
            ipc.DrainPassItemCount = 0;
            ipc.bDrainPassHadHighStakes = 0;
        }
        if (default.bSuppressNextDeathBroadcast == 1)
        {
            // This stateDead is our own induced (incoming) kill. Consume the
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
        // LoadGame 0 finished and Harry is playable again. If it returned us to
        // the same level we died in (the in-level autosave case), the death did
        // NOT travel out of the level, so the death-exit marker must not linger
        // and suppress a genuine same-visit completion. The in-level reload
        // restores the level without a fresh PreBeginPlay, so Snapshot() /
        // CheckExitedLevelObjective never re-run - this falling edge is the only
        // place that observes the post-reload level. The marker is kept when the
        // reload landed in a different level (hub autosave) - the case the
        // CheckExitedLevelObjective death-reload skip actually guards.
        if (default.DeathExitFromLevelCaps == Caps(string(Level.Outer.Name)))
            default.DeathExitFromLevelCaps = "";

        // Alive again (post-reload PlayerWalking). Tell the client to clear
        // sent_this_session for any indices not yet durably consumed, then
        // re-forward them. The reload is finished, so the freshly queued
        // grants are safe from a wipe. Earlier (rising edge) would race the
        // LoadGame. Clearing bWasDead is gated on the send going through;
        // otherwise a next-tick retry can re-attempt once the IPC settles.
        if (ipc != None)
        {
            ipc.SendText("DRAIN_ROLLBACK" $ Chr(10));
            Log("[Archipelago] APCardWatcher: post-death recovery - sent DRAIN_ROLLBACK");
            default.bWasDead = 0;
        }
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
            // Already dying (our own death raced the inbound). The reload is
            // happening regardless, so just drop the pending kill.
            default.bPendingDeathLink = 0;
        }
        else if (!class'APGameInfo'.static.IsPlayerInPlayableState(HarryRef, reason))
        {
            // Not playable (cutscene / menu / load): hold the kill and push the
            // settle window, so once control returns the kill still waits out a
            // full DEATHLINK_SETTLE_SECS of continuous playability before firing.
            // That is what stops it landing on the one-tick PlayerWalking flicker
            // between chained cutscene segments. Retry next tick.
            PushDeathLinkSettle(DEATHLINK_SETTLE_SECS);
        }
        else if (Level.TimeSeconds >= DeathLinkSettleEarliest)
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
        // else: playable but still inside the settle window - keep pending and
        // retry next tick once continuous playability clears the window.
    }
}

// Clause-3 exit-credit for the levels whose ONLY forward progress is
// completing their single objective: 0 Boomslang (Adv4Greenhouse), 1 Bicorn
// (Adv3DungeonQuest), 2 BitOGoyle (Adv6Goyle), 5 Whomping Willow, and 6
// Slytherin Common Room. We do NOT poll per-item state: the ingredient
// StatusItem path is broken in this build (orphaned StatusItemBitOGoyle; the
// Bicorn prop has null class refs so StatusManager.PickupItem early-returns
// and nCount never rises), and harry.PreviousLevelName is
// blanked by the return auto-save before Snapshot runs. Instead we
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

    // Open castle: on leaving the bean room, persist its ledger via the client
    // (AP data storage) so it survives a game restart. Sent here, before the
    // objective early-returns, because BeanRewardRoom is not an objective level.
    if (class'APModeDetector'.default.bOpenCastleMode == 1
        && prevCaps == "BEANREWARDROOM" && curCaps != "BEANREWARDROOM")
    {
        class'APBeanRoom'.static.SendBeanRoomStateToClient();
    }

    if (prevCaps == "" || prevCaps == curCaps) return;
    idx = class'APGoalTracker'.static.LevelObjectiveIndexFor(prevCaps);
    // 0-2 ingredient levels, 5 Willow, 6 Slytherin. NOT 3/4 (boss levels keep
    // their poll detector - leavable without the kill) and NOT 7-11
    // (challenges have an entrance-door / Return-to-Hub bypass that exit-credit
    // miscredits - ScanFinalStarCompletion owns those via in-level pickup poll).
    if (idx < 0 || idx == 3 || idx == 4 || (idx >= 7 && idx <= 11))
        return;
    if (class'APGoalTracker'.default.GoalLevelDone[idx] == 1) return; // already credited

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
    // StatusItem nCount path is unrecoverable in this build).
    if (idx <= 2)
    {
        WasKeyItemOwned[idx] = 1;
        ipc = class'APIPCActor'.static.GetInstance();
        if (ipc != None) ipc.SendCheckKeyItem(KeyItemNames[idx]);
    }
    Log("[Archipelago] APCardWatcher.CheckExitedLevelObjective: exited "
        $ prevCaps $ " (idx=" $ idx $ ") - crediting objective");
    class'APGoalTracker'.static.NotifyLevelObjective(idx);
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

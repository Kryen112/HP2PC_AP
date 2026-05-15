class APCardWatcher extends Actor;

const MAX_CARD_ID = 101;
const NUM_SPELLS = 7;
const NUM_KEY_ITEMS = 3;
const NUM_BINGO_KEYS = 13;

// AP location base id (locations.yaml `base_id`). Used to index
// NonCardLocationChecked[] by `apId - LOC_BASE` for secrets/stars/etc.
// Mirrors `BASE_ID` in apworld/locations.py.
const LOC_BASE = 5760000;
// Class-default dedup for non-card AP locations (secrets, stars, vendors, duels,
// matches). Indexed by `apId - LOC_BASE`. Sized to fit the current id-space
// upper bound (~625 for Quidditch match 6) with headroom. Class-default so it
// persists across level transitions in a session, like LocationChecked[].
var byte NonCardLocationChecked[700];

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

event Timer()
{
    local int id, i;
    local APIPCActor ipc;
    local HPConsole console;
    local FEBook book;
    local harry viewportHarry;

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

    ReplaceVendorSpawnedCards();
    ReplaceVendorEquipment();
    ScanSecretMarkers(ipc);
    ScanDuelWins(ipc);
    ScanMatchWins(ipc);

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
        if (KeyItemStatus[i] != None && WasKeyItemOwned[i] == 0 && KeyItemStatus[i].nCount > 0)
        {
            WasKeyItemOwned[i] = 1;
            Log("[Archipelago] APCardWatcher: new key item: " $ KeyItemNames[i]);
            if (ipc != None)
            {
                ipc.SendCheckKeyItem(KeyItemNames[i]);
            }
        }
    }

    // M7 goal detection: poll FEBook.bInEndGame, set True by ShowCredits()
    // (FEBook.uc:1392) when the post-Basilisk credits cutscene runs. Access
    // pattern mirrors harry.uc:5582 / harry.uc:339 — go through the live
    // gameplay UWorld's HPConsole to reach the active menuBook (HarryRef's
    // own .menuBook field can be stale; the explicit lookup is known-good).
    // One-shot: WasInEndGame guards re-fire. Null-check Player/Console/menuBook
    // because they can briefly be None during level loads.
    if (WasInEndGame == 0 && HarryRef.Player != None)
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
        if (KeyItemStatus[i] != None && KeyItemStatus[i].nCount > 0)
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
        if (slot < 0 || slot >= 700) continue;
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
        if (slot < 0 || slot >= 700) continue;
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
        if (slot < 0 || slot >= 700) continue;
        if (default.NonCardLocationChecked[slot] == 1) continue;
        default.NonCardLocationChecked[slot] = 1;
        Log("[Archipelago] APCardWatcher: quidditch match " $ (i + 1)
            $ " won (vs " $ HarryRef.quidGameResults[i].Opponent
            $ ") - firing CHECK_LOCID " $ locId);
        if (ipc != None) ipc.SendCheckLocationId(locId);
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
        if (slot < 0 || slot >= 700) continue;
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

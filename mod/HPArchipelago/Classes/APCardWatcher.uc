class APCardWatcher extends Actor;

const MAX_CARD_ID = 101;
const NUM_SPELLS = 7;
const NUM_KEY_ITEMS = 3;

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

// M7 goal detection: tracks whether we've already fired GOAL_COMPLETE this
// session. Class-default so it survives level transitions (the credits flow
// stays in the same level instance, but defensive-default just in case).
var byte WasInEndGame;

var APCardWatcher LatestInstance;

// Class-default array. Survives level transitions in a session (default vars are
// process-wide). APCardMarker.Touch sets LocationChecked[id]=1 after firing its
// CHECK; APCardMarker.PostBeginPlay self-destroys if its id is already checked.
var byte LocationChecked[102];

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
    Log("[Archipelago] APCardWatcher.PreBeginPlay - starting timer (Level=" $ string(Level) $ ")");
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
    // every game→sidecar CHECK after a save-load.
    ipc = class'APIPCActor'.static.GetInstance();

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

    // Lesson-start hook for the four spell-tutorial location checks.
    // Bug it fixes: the IsInSpellBook poll below only fires CHECK_SPELL on a
    // not-having → having transition. If AP grants the spell BEFORE Harry
    // visits the classroom (any plando placement that doesn't put the spell
    // at its own classroom), the lesson plays but Harry already has the spell —
    // no transition, no CHECK_SPELL, location lost. Polling harry.CurrSpellLesson
    // fires at the moment SpellLessonTrigger.Activate sets it (regardless of
    // spell ownership). Shares WasSpellOwned[] with the IsInSpellBook fallback
    // so the two paths dedupe against each other.
    if (HarryRef.CurrSpellLesson != None)
    {
        i = LessonShapeToSpellIndex(HarryRef.CurrSpellLesson);
        if (i >= 0 && default.LessonCheckFired[i] == 0)
        {
            default.LessonCheckFired[i] = 1;
            Log("[Archipelago] APCardWatcher: SpellLessonTrigger active for " $ SpellNames[i] $ " - firing CHECK_SPELL (lesson-start hook)");
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
// `bVendorsCanSell` / `strVendorOwnedAfterGState` defaults that gen_apworld
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

    ownedSpellCount = 0;
    for (i = 0; i < NUM_SPELLS; i++)
    {
        if (HarryRef.IsInSpellBook(SpellClasses[i].default.SpellType))
        {
            WasSpellOwned[i] = 1;
            APGrantedSpell[i] = 1;
            default.APGrantedSpell[i] = 1;
            ownedSpellCount++;
        }
    }
    Log("[Archipelago] APCardWatcher: initial snapshot - Harry already knows " $ ownedSpellCount $ " spells (baselined as AP-granted, no revert)");

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

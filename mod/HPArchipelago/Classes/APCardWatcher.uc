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

var class<baseSpell> SpellClasses[7];
var string SpellNames[7];
var byte WasSpellOwned[7];
var byte APGrantedSpell[7];

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

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

var class<baseSpell> SpellClasses[7];
var string SpellNames[7];
var byte WasSpellOwned[7];

var StatusItem KeyItemStatus[3];
var string KeyItemNames[3];
var byte WasKeyItemOwned[3];

event PreBeginPlay()
{
    Super.PreBeginPlay();
    Log("[Archipelago] APCardWatcher.PreBeginPlay - starting timer");
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
}

event Timer()
{
    local int id, i;
    local APGameInfo gi;

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

    gi = APGameInfo(Level.Game);

    for (id = 1; id <= MAX_CARD_ID; id++)
    {
        if (WasOwnedByHarry[id] == 0 && IsHarryOwned(id))
        {
            WasOwnedByHarry[id] = 1;
            Log("[Archipelago] APCardWatcher: new card owned by Harry, id=" $ id);
            if (gi != None && gi.IPCActor != None)
            {
                gi.IPCActor.SendCheck(id);
            }
        }
    }

    for (i = 0; i < NUM_SPELLS; i++)
    {
        if (WasSpellOwned[i] == 0 && HarryRef.IsInSpellBook(SpellClasses[i].default.SpellType))
        {
            WasSpellOwned[i] = 1;
            Log("[Archipelago] APCardWatcher: new spell learned: " $ SpellNames[i]);
            if (gi != None && gi.IPCActor != None)
            {
                gi.IPCActor.SendCheckSpell(SpellNames[i]);
            }
        }
    }

    for (i = 0; i < NUM_KEY_ITEMS; i++)
    {
        if (KeyItemStatus[i] != None && WasKeyItemOwned[i] == 0 && KeyItemStatus[i].nCount > 0)
        {
            WasKeyItemOwned[i] = 1;
            Log("[Archipelago] APCardWatcher: new key item: " $ KeyItemNames[i]);
            if (gi != None && gi.IPCActor != None)
            {
                gi.IPCActor.SendCheckKeyItem(KeyItemNames[i]);
            }
        }
    }
}

function bool Bind()
{
    local StatusGroupWizardCards sg;

    if (HarryRef == None)
    {
        foreach AllActors(class'harry', HarryRef)
        {
            break;
        }
    }
    if (HarryRef == None || HarryRef.managerStatus == None)
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
            ownedSpellCount++;
        }
    }
    Log("[Archipelago] APCardWatcher: initial snapshot - Harry already knows " $ ownedSpellCount $ " spells");

    for (i = 0; i < NUM_KEY_ITEMS; i++)
    {
        if (KeyItemStatus[i] != None && KeyItemStatus[i].nCount > 0)
        {
            WasKeyItemOwned[i] = 1;
        }
    }
}

function bool IsHarryOwned(int id)
{
    return siBronze.IsOwnedByHarry(id) || siSilver.IsOwnedByHarry(id) || siGold.IsOwnedByHarry(id);
}

defaultproperties
{
    bHidden=True
}

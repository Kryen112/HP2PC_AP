// Tradersanity: the ingredient / equipment trader shop surfaced as AP checks,
// plus Fred (Nimbus 2001) / George (Quidditch Armour). Per-level singleton
// (GetInstance). The 16-slot vendor registry and the Weasley token slots hold
// Characters / Actor refs, so they MUST be instance state (a class-default
// actor-ref array crashes level cleanup); they are rebuilt each level. The seed
// config (price mode, skip-voices, quidditch-upgrades) and the sticky
// cross-level tables (purchase ledger, hint names, rolled price factors) are
// class-default and persist for the process. The shared location-checked ledger
// (NonCardLocationChecked) lives on APCardWatcher and is read cross-class.
// HarryRef (for the live VendorManager) is captured each Snapshot by
// ReplaceVendorEquipment. Cleanly independent of the wizard-card core: it never
// touches siBronze/siSilver/siGold or the card ownership ledger.
class APVendorController extends Info;

// id-window math for the shared ledger and the parallel class-default arrays.
const LOC_BASE = 5760000;
const NONCARD_LOC_WINDOW = 2048;

// Process-wide singleton pointer (class-default). Instance copy kept None for
// save-graph hygiene.
var APVendorController LatestInstance;

// Live Harry for the engaged VendorManager. Set each Snapshot by
// ReplaceVendorEquipment; the hint / icon / purchased / out-of-stock passes
// read it. Instance, refreshed per level.
var harry HarryRef;

// --- config (class-default, sticky; set via the static IPC setters) ----------
// Price mode from the apworld slot_data, pushed via the TRADECFG IPC line.
// Class-default so it survives level transitions in a session; resent every
// HELLO so it is sticky.
const TRADER_OFF           = 0;
const TRADER_PRICE_VANILLA = 1;
const TRADER_PRICE_RANDOM  = 2;
const TRADER_PRICE_LOW     = 3;
var int TradersanityMode;
// Skip-vendor-voices flag (SKIP_VENDOR_VOICES IPC). When 1, SilenceVendorDialog
// zeroes each vendor's VendorDialog string ids so VendorManager.DoCutTalk's
// empty-dialog branch fires the cue immediately without audio. Sticky byte; the
// Snapshot pass re-applies the silence on every level load.
var byte bSkipVendorVoices;
// Quidditch-upgrades flag (QUIDDITCH_UPGRADES IPC). When 1, Fred / George are
// AP-tracked (5760005 / 5760006) and the AP-UX passes treat them as Tradersanity
// vendors. When 0, the two locations do not exist in the seed and the brothers
// fall back to their vanilla trade UX.
var byte bQuidditchUpgrades;
// Per-location flag set on the first observation of the engaged VendorManager
// entering MakePurchase (the player clicked Yes). Lets the label and icon-swap
// drop the "this is an AP check" affordance immediately on Yes-click without
// firing CHECK_LOCID early. Indexed by locId - LOC_BASE. Dimension MUST equal
// NONCARD_LOC_WINDOW.
var byte TraderPurchased[2048];
// Per-location cached item name from the apworld's scout response (HINT IPC).
// Empty if hint-on-open is off for this seed; the label falls back to the
// generic "Archipelago Item" text.
var string TraderHintItemName[2048];
// Price constants for the non-vanilla modes. price_low clamps to a flat value;
// price_random blends a per-vendor factor across [LO, HI]; price_vanilla on a
// card vendor blends the SAME factor across the vendor's own [min,max].
const TRADER_PRICE_LOW_BEANS  = 10;
const TRADER_PRICE_RAND_LO    = 10;
const TRADER_PRICE_RAND_HI    = 250;
// Per-location price factor (byte 0..255) pre-rolled in the apworld from the
// seeded RNG and shipped via the TRADERPRICES IPC line. Class-default and sticky
// for the seed: survives level transitions (class-default carries cross-level in
// a session) and save/exit (re-armed from slot_data on the next HELLO).
// Dimension MUST be the integer literal 2048; M212 array dims take an integer
// literal, not a const.
var byte TraderRolledFactor[2048];

// --- per-level registry (instance: holds actor refs) -------------------------
// A freshly-sold item spawns within ~CollisionRadius+10 of its vendor and is
// caught within ~0.25s, so it is always far nearer its own vendor than the
// closest neighbour (census min separation ~210uu). Match the NEAREST eligible
// unchecked Tradersanity vendor within this cap.
const TRADER_MATCH_RADIUS = 256.0;
// INSTANCE, not class-default: holds Characters refs and the per-level singleton
// is torn down the safe same-level way. A level holds at most ~6 eligible
// vendors; 16 is generous.
//
// Card vendors are turned INTO ingredient vendors while their check is pending:
// HP2 card-vendor stock is tier-global and MakePurchase spawns a real card
// (cardsanity cross-fire), but ingredient stock (nCurrIngrCount) is PER-VENDOR
// and MakePurchase spawns a plain prop. So a Tradersanity card vendor gets
// CharacterSells := Sells_WBark while pending; on collection it is restored.
//   TraderOrigSells   SELLS_* from the GENERATED registry (not the mutated
//                     actor) so card-vendor restore survives save/load.
//   TraderSavedLo/Hi  original sale-price range (card: min/max; ingredient: the
//                     single price twice) for price_vanilla / revert.
//   TraderApplied     price mode applied this visit (once).
//   TraderRestored    post-collect cleanup (price + CharacterSells) done.
//   TraderDispensed   the sold prop has been morphed + claimed as this vendor's
//                     AP pickup token; resets with the per-level singleton so an
//                     uncollected check re-arms on re-entry.
//   TraderToken       the morphed PotionIngredients prop acting as the AP
//                     pickup; when it goes None/bDeleteMe the check fires.
//                     Instance only; actor refs in class-default crash cleanup.
//   TraderWait        ticks spent sold-but-untokenised; a safety counter.
//   TraderSavedIngr   the vendor's vanilla nCurrIngrCount at registration,
//                     restored on revert so a genuine ingredient vendor restocks
//                     immediately instead of sitting at the pinned zero.
const TRADER_REG_SIZE = 16;
// Sold-but-no-token ticks before the check fires anyway (the prop was picked up
// before the morph pass saw it, or never appeared).
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
// AP location id of the Tradersanity vendor whose dialogue was engaged at the
// last poll. 0 = no engagement. Rising-edge discriminator for the VENDOR_OPENED
// IPC so a held-open dialogue fires the hint exactly once per engagement.
var int TraderHintLastEngagedLocId;
// Characters.ESells ordinal values (stable in the decompiled retail enum). Used
// only to record/branch a vendor's ORIGINAL sell type from the registry; live
// vendor comparisons still use the c.ESells.Sells_* idiom.
const SELLS_WBARK  = 2;
const SELLS_FMUCUS = 3;
const SELLS_BRONZE = 4;
const SELLS_SILVER = 5;

// --- Fred / George (Nimbus 2001 / Quidditch Armour) in-place tokens ----------
// The thrown VendorNimbusBroom / QArmor is morphed in place (never destroyed +
// respawned) so it keeps the Velocity / PHYS_Falling / arc vanilla MakePurchase
// gave it. WeasleyToken holds the morphed prop; the check fires when it is
// picked up (ref None / bDeleteMe). WeasleyDispensed marks that a prop has been
// bound this session. Index 0 = Nimbus 2001 (5760005), 1 = Quidditch Armour
// (5760006). INSTANCE state: actor refs in a class-default array crash level
// cleanup; re-acquired each level from the bPersistent prop.
var Actor WeasleyToken[2];
var byte  WeasleyDispensed[2];

// Found-or-spawned singleton accessor. Lazily spawns one via the caller's
// context on first use of a level. Logic-only (no mesh) so runtime spawn is safe.
static function APVendorController GetInstance(Actor ctx)
{
    if (default.LatestInstance != None && !default.LatestInstance.bDeleteMe)
        return default.LatestInstance;
    if (ctx == None) return None;
    return ctx.Spawn(class'APVendorController');
}

event PreBeginPlay()
{
    Super.PreBeginPlay();
    // Only default.LatestInstance is the singleton pointer; Spawn seeds the
    // instance copy from the class default, so clear it.
    LatestInstance = None;
    default.LatestInstance = self;
}

// Price mode from the apworld slot_data (TRADECFG IPC). Class-default + sticky.
static function SetTradersanityMode(int m)
{
    default.TradersanityMode = m;
    Log("[Archipelago] APVendorController.SetTradersanityMode: mode=" $ default.TradersanityMode);
}

// Skip-vendor-voices flag (SKIP_VENDOR_VOICES IPC). Class-default + sticky. The
// Snapshot path calls ApplySkipVendorVoicesPass each level load to re-apply the
// silence on freshly-spawned vendors; a same-session re-arm by a live singleton
// also picks up the right state immediately.
static function SetSkipVendorVoices(byte v)
{
    local APVendorController vc;

    default.bSkipVendorVoices = v;
    Log("[Archipelago] APVendorController.SetSkipVendorVoices: skip=" $ string(default.bSkipVendorVoices));
    vc = default.LatestInstance;
    if (vc != None && !vc.bDeleteMe) vc.ApplySkipVendorVoicesPass();
}

// Quidditch-upgrades flag (QUIDDITCH_UPGRADES IPC). Class-default + sticky.
// GetActiveAPVendorLocationId checks this before returning a Weasley fallback id,
// so a 0 here leaves Fred/George with their vanilla trade UX.
static function SetQuidditchUpgrades(byte v)
{
    default.bQuidditchUpgrades = v;
    Log("[Archipelago] APVendorController.SetQuidditchUpgrades: enabled=" $ string(default.bQuidditchUpgrades));
}

// Resolve the AP location id for a vendor Characters actor IF that vendor is an
// AP check in the current seed. Generic Tradersanity vendors only count when
// TradersanityMode != TRADER_OFF; Fred -> 5760005, George -> 5760006 only count
// when bQuidditchUpgrades is on. Returns 0 when no AP check exists, so the AP-UX
// passes (icon swap, banner, hint-on-open, mark-purchased) can use a single gate.
static function int GetActiveAPVendorLocationId(Characters c, string lvl)
{
    local int loc;

    if (c == None) return 0;
    loc = class'APLocationRegistry'.static.GetVendorLocationId(lvl, string(c.Name));
    if (loc > 0)
    {
        if (default.TradersanityMode == TRADER_OFF) return 0;
        return loc;
    }
    if (default.bQuidditchUpgrades == 0) return 0;
    if (c.VendorDialogSet == c.EVendorDialog.VDialog_FredWeasley)   return 5760005;
    if (c.VendorDialogSet == c.EVendorDialog.VDialog_GeorgeWeasley) return 5760006;
    return 0;
}

// Zero out every in-trade VendorDialog string id so VendorManager.DoCutTalk's
// empty-dialog fast path fires the cue immediately, no audio. Intentionally
// LEFT ALONE: strLureId (proximity-only), strOutOfStockId (muted engagement-side
// by TradersanityKillPostTradeOutOfStockPass), and the not-enough/ran-out-of
// beans lines (situational feedback, stay vocal). Idempotent.
function SilenceVendorDialog(Characters c)
{
    if (c == None) return;
    c.VendorDialog.strSellNimbusId       = "";
    c.VendorDialog.strSellQArmorId       = "";
    c.VendorDialog.strSellWBarkId        = "";
    c.VendorDialog.strSellFMucusId       = "";
    c.VendorDialog.strSellBronzeCardsId  = "";
    c.VendorDialog.strSellSilverCardsId  = "";
    c.VendorDialog.strDeclineId          = "";
    c.VendorDialog.strTransactionDoneId  = "";
    c.VendorDialog.strSellDuelId         = "";
    c.VendorDialog.strNarratorInstrId    = "";
    c.VendorDialog.strHarryWhatYouGotId  = "";
}

// Sweep every Characters actor in the level and silence its in-trade dialog if
// the option is on. No-op when off. Idempotent.
function ApplySkipVendorVoicesPass()
{
    local Characters c;
    local int silenced;

    if (default.bSkipVendorVoices == 0) return;
    silenced = 0;
    foreach AllActors(class'Characters', c)
    {
        SilenceVendorDialog(c);
        silenced++;
    }
    Log("[Archipelago] APVendorController.ApplySkipVendorVoicesPass: silenced " $ string(silenced) $ " vendor(s)");
}

// Per-vendor Tradersanity price factors (TRADERPRICES IPC), as
// `locId:factor,locId:factor,...` (factor = byte 0..255). Pre-rolled in the
// apworld so the same AP seed always yields the same per-vendor prices; the mod
// blends each factor in ApplyVendorPrice. Class-default + sticky; idempotent.
// Wipes the table first so a later seed without Tradersanity can't leak stale
// factors from a prior session.
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
        apId   = class'APCsvCodec'.static.NextCsvIntUpTo(rest, ":");
        factor = class'APCsvCodec'.static.NextCsvIntUpTo(rest, ",");
        slot = apId - LOC_BASE;
        if (slot >= 0 && slot < NONCARD_LOC_WINDOW)
        {
            if (factor < 0)   factor = 0;
            if (factor > 255) factor = 255;
            default.TraderRolledFactor[slot] = byte(factor);
            n++;
        }
    }
    Log("[Archipelago] APVendorController.SetTraderRolledFactors: ingested " $ n $ " factor entry(ies)");
}

// Cache the hint item name for a Tradersanity vendor location (HINT IPC), after
// the apworld scout response resolves the item. The label swaps "Archipelago
// Item" for the actual name when hint-on-open is enabled.
static function SetVendorHintItemName(int locId, string itemName)
{
    local int slot;

    slot = locId - LOC_BASE;
    if (slot < 0 || slot >= NONCARD_LOC_WINDOW) return;
    default.TraderHintItemName[slot] = itemName;
    Log("[Archipelago] APVendorController.SetVendorHintItemName: locId=" $ string(locId)
        $ " name='" $ itemName $ "'");
}

// Snapshot entry point. Captures the live Harry for the engaged-vendor passes,
// morphs Fred/George thrown equipment into AP tokens, then runs the Tradersanity
// vendor pass and the four AP-UX passes.
function ReplaceVendorEquipment(harry h)
{
    local VendorNimbusBroom broom;
    local QArmor armor;

    HarryRef = h;

    if (default.bQuidditchUpgrades == 1)
    {
        foreach AllActors(class'VendorNimbusBroom', broom)
        {
            MorphWeasleyPropInPlace(broom, 0, 5760005);  // Castle Exterior - Nimbus 2001
        }
        foreach AllActors(class'QArmor', armor)
        {
            MorphWeasleyPropInPlace(armor, 1, 5760006);  // Castle Exterior - Quidditch Armour
        }
        FireWeasleyCheck(0, 5760005, HarryRef != None && HarryRef.bHaveNimbus2001);
        FireWeasleyCheck(1, 5760006, HarryRef != None && HarryRef.bHaveQArmor);
    }

    // Tradersanity vendors.
    TradersanityPass();
    TradersanityHintOnOpenPass();
    // Two complementary passes that drive the trade UI's "this is an AP item"
    // affordance: IconSwapPass swaps textureItemToSell to the AP logo before
    // purchase and restores the vanilla icon once the location is checked or
    // purchased; MarkPurchasedPass flips TraderPurchased[slot] at MakePurchase
    // entry so the label + icon revert the moment the player clicks Yes
    // (CHECK_LOCID + stars + sound + drop are untouched, fire on Touch).
    TradersanityIconSwapPass();
    TradersanityMarkPurchasedPass();
    // Engagement-gated strOutOfStockId mute. Blanks the out-of-stock dialog id
    // WHILE engaged so the post-trade CutCue chain takes DoCutTalk's empty-string
    // fast path and disengages silently. Restored when not engaged so a later
    // proximity bump on an empty vendor still plays the vanilla "sorry, I'm out".
    TradersanityKillPostTradeOutOfStockPass();
}

// Morph a freshly-thrown VendorNimbusBroom / QArmor into this location's AP
// pickup token without destroying it, so it keeps its vanilla throw arc. Null
// the grant fields (StatusManager.PickupItem / GetHudLocation both early-return
// on a null classStatusItem, so pickup adds no inventory) and set PickupFlyTo to
// FT_None so the pickup skips the HUD fly. FireWeasleyCheck fires the check when
// the token is picked up. Idempotent: an already-morphed prop is just re-bound.
function MorphWeasleyPropInPlace(HProp prop, int wi, int locId)
{
    local int slot;
    local APMorphRegistry mr;

    if (prop == None || prop.bDeleteMe) return;
    slot = locId - LOC_BASE;
    if (slot < 0 || slot >= NONCARD_LOC_WINDOW) return;

    if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1)
    {
        // Already collected; a leftover (e.g. save-load-restored) prop must not
        // re-arm. The purchase set bHave* so no fresh one spawns.
        prop.Destroy();
        return;
    }

    if (prop.classStatusItem == None)
    {
        // Already our token; re-bind quietly on a fresh per-level singleton.
        WeasleyToken[wi]     = prop;
        WeasleyDispensed[wi] = 1;
        return;
    }

    prop.classStatusGroup = None;
    prop.classStatusItem  = None;
    prop.PickupFlyTo      = prop.EPickupFlyTo.FT_None;
    class'APAppearanceMath'.static.ApplyAppearanceTo(prop, class'APMorphRegistry'.static.AppearanceForApId(locId));
    mr = class'APMorphRegistry'.static.GetInstance(self);
    if (mr != None) mr.RegisterMorphMarker(prop, locId);
    WeasleyToken[wi]     = prop;
    WeasleyDispensed[wi] = 1;
    Log("[Archipelago] APVendorController.MorphWeasleyPropInPlace: morphed "
        $ string(prop.Class.Name) $ " in place to AP token (loc id " $ locId
        $ ") - keeps vanilla throw arc, check fires on pickup");
}

// Fire the Weasley AP check once. Primary trigger: the morphed token was picked
// up, so its ref is None / bDeleteMe. Safety net: the player paid (bHave* set)
// but no token is live and none was bound this session (the thrown prop was
// grabbed in the sub-tick race before the morph, or an old-format marker was
// dropped on a cross-version save load) - fire directly so the paid check can't
// strand.
function FireWeasleyCheck(int wi, int locId, bool bPaid)
{
    local APIPCActor ipc;
    local int slot;
    local bool bPickedUp, bPaidNoToken;

    slot = locId - LOC_BASE;
    if (slot < 0 || slot >= NONCARD_LOC_WINDOW) return;
    if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) return;

    bPickedUp = (WeasleyDispensed[wi] == 1
                 && (WeasleyToken[wi] == None || WeasleyToken[wi].bDeleteMe));
    bPaidNoToken = (bPaid && WeasleyDispensed[wi] == 0 && WeasleyToken[wi] == None);
    if (!bPickedUp && !bPaidNoToken) return;

    ipc = class'APIPCActor'.static.GetInstance();
    if (ipc != None) ipc.SendCheckLocationId(locId);
    class'APCardWatcher'.default.NonCardLocationChecked[slot] = 1;
    WeasleyToken[wi] = None;
    if (bPickedUp)
    {
        Log("[Archipelago] APVendorController.FireWeasleyCheck: AP token picked up (loc id " $ locId $ ") - fired CHECK_LOCID");
    }
    else
    {
        Log("[Archipelago] APVendorController.FireWeasleyCheck: paid but no token resolved (loc id " $ locId $ ") - fired CHECK_LOCID directly");
    }
}

// Edge-detect the player engaging a Tradersanity vendor's dialogue: on the
// transition to "this vendor", fire VENDOR_OPENED <locId> so the client
// publishes a broadcast hint for the AP item that vendor is holding. Gated on
// Tradersanity being on and the location still being unchecked.
function TradersanityHintOnOpenPass()
{
    local VendorManager vm;
    local Characters engagedVendor;
    local APIPCActor ipc;
    local int locId, slot;
    local string lvl;

    // Helper gates Tradersanity / Weasley separately, so no early return here.
    if (HarryRef == None) return;

    vm = HarryRef.CurrVendorManager;
    if (vm == None || vm.Vendor == None)
    {
        TraderHintLastEngagedLocId = 0;
        return;
    }

    engagedVendor = vm.Vendor;

    lvl = string(Level.Outer.Name);
    locId = class'APVendorController'.static.GetActiveAPVendorLocationId(engagedVendor, lvl);
    if (locId == 0) return;
    if (locId == TraderHintLastEngagedLocId) return;

    TraderHintLastEngagedLocId = locId;

    slot = locId - LOC_BASE;
    if (slot < 0 || slot >= NONCARD_LOC_WINDOW) return;
    if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) return;

    ipc = class'APIPCActor'.static.GetInstance();
    if (ipc != None) ipc.SendVendorOpened(locId);
    Log("[Archipelago] APVendorController.TradersanityHintOnOpenPass: fired VENDOR_OPENED "
        $ locId $ " for engaged vendor " $ string(engagedVendor.Name));
}

// Re-derive the vanilla in-trade icon for a vendor from its CharacterSells enum
// (the same switch VendorManager.DoEngageVendor uses). Used to restore the
// original texture on a re-engagement once the AP check is done (the vanilla
// bar-texture-None gate prevents DoEngageVendor from reloading textureItemToSell
// on subsequent engagements, so we do it ourselves).
function Texture GetVanillaTradeIconForVendor(Characters c)
{
    if (c == None) return None;
    if (c.CharacterSells == c.ESells.Sells_WBark)
        return Texture(DynamicLoadObject("HP2_Menu.Icons.HP2VendorWBark", class'Texture'));
    if (c.CharacterSells == c.ESells.Sells_FMucus)
        return Texture(DynamicLoadObject("HP2_Menu.Icons.HP2VendorFMucus", class'Texture'));
    if (c.CharacterSells == c.ESells.Sells_BronzeCards)
        return Texture(DynamicLoadObject("HP2_Menu.Icons.HP2VendorBronzeCard", class'Texture'));
    if (c.CharacterSells == c.ESells.Sells_SilverCards)
        return Texture(DynamicLoadObject("HP2_Menu.Icons.HP2VendorSilverCard", class'Texture'));
    // Vanilla DoEngageVendor texture paths for the Weasley brothers, so the
    // post-check restore can return them to their native broom / armour icon
    // once the AP check at Fred / George has fired.
    if (c.CharacterSells == c.ESells.Sells_Nimbus2001)
        return Texture(DynamicLoadObject("HP2_Menu.Icons.HP2Nimbus2001", class'Texture'));
    if (c.CharacterSells == c.ESells.Sells_QArmor)
        return Texture(DynamicLoadObject("HP2_Menu.Icons.HP2QuidditchArmor", class'Texture'));
    return None;
}

// Swap the trade UI's item icon to the AP logo while the engaged Tradersanity
// vendor's AP location is still unchecked, and back to the vanilla ingredient /
// card icon once it's checked. Polled per Timer tick so a re-engagement after
// the check picks up the right state (DoEngageVendor only loads textureItemToSell
// on the first engagement, so the restore is ours to do).
function TradersanityIconSwapPass()
{
    local VendorManager vm;
    local Characters engagedVendor;
    local int locId, slot;
    local string lvl;
    local Texture desired;

    // No TradersanityMode early return: Fred/George ride on bQuidditchUpgrades
    // alone, so the gate lives inside GetActiveAPVendorLocationId.
    if (HarryRef == None) return;

    vm = HarryRef.CurrVendorManager;
    if (vm == None || vm.Vendor == None) return;
    if (vm.textureItemToSell == None) return;

    engagedVendor = vm.Vendor;
    lvl = string(Level.Outer.Name);
    locId = class'APVendorController'.static.GetActiveAPVendorLocationId(engagedVendor, lvl);
    if (locId == 0) return;

    slot = locId - LOC_BASE;
    if (slot < 0 || slot >= NONCARD_LOC_WINDOW) return;

    // AP icon ONLY while the location is unchecked AND the player hasn't already
    // clicked Yes for this vendor (TraderPurchased). The OR means a
    // mid-MakePurchase or post-pickup re-engagement both show the vanilla icon.
    if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 0 && default.TraderPurchased[slot] == 0)
    {
        desired = class'APAppearanceMath'.static.GetAPItemTextureStatic();
    }
    else
    {
        desired = GetVanillaTradeIconForVendor(engagedVendor);
    }

    if (desired != None && vm.textureItemToSell != desired)
    {
        vm.textureItemToSell = desired;
    }
}

// Edge-mark TraderPurchased[slot] = 1 when the engaged Tradersanity vendor's
// VendorManager enters MakePurchase (player clicked Yes). The label and
// icon-swap read this to flip to "post-purchase" UX, while CHECK_LOCID / drop
// sound / rainbow stars still fire on the marker's Touch as vanilla.
function TradersanityMarkPurchasedPass()
{
    local VendorManager vm;
    local Characters engagedVendor;
    local int locId, slot;
    local string lvl;

    // Helper gates Tradersanity / Weasley separately, so no early return here.
    if (HarryRef == None) return;

    vm = HarryRef.CurrVendorManager;
    if (vm == None || vm.Vendor == None) return;
    if (vm.GetStateName() != 'MakePurchase') return;

    engagedVendor = vm.Vendor;
    lvl = string(Level.Outer.Name);
    locId = class'APVendorController'.static.GetActiveAPVendorLocationId(engagedVendor, lvl);
    if (locId == 0) return;

    slot = locId - LOC_BASE;
    if (slot < 0 || slot >= NONCARD_LOC_WINDOW) return;
    if (default.TraderPurchased[slot] == 1) return;

    default.TraderPurchased[slot] = 1;
    Log("[Archipelago] APVendorController.TradersanityMarkPurchasedPass: TraderPurchased["
        $ string(slot) $ "] = 1 at MakePurchase for vendor " $ string(engagedVendor.Name));
}

// Mirror of the strOutOfStockId values vanilla VendorInit assigns per
// VendorDialogSet enum. Used to RESTORE strOutOfStockId after the engagement-
// gated mute. Duel vendors and unmapped sets get "" (vanilla also leaves them
// empty). M212 const-cross-class limits mean we can't reuse the vanilla
// literals; they're spelled out here.
function string VanillaOutOfStockIdForVendor(Characters c)
{
    if (c == None) return "";
    if (c.VendorDialogSet == c.EVendorDialog.VDialog_FredWeasley)    return "PC_Frd_Vendor_85";
    if (c.VendorDialogSet == c.EVendorDialog.VDialog_GeorgeWeasley)  return "PC_Grg_Vendor_86";
    if (c.VendorDialogSet == c.EVendorDialog.VDialog_GenericMale1)   return "PC_Gv1_Vendor_80";
    if (c.VendorDialogSet == c.EVendorDialog.VDialog_GenericMale2)   return "PC_Gv2_Vendor_81";
    if (c.VendorDialogSet == c.EVendorDialog.VDialog_GenericFemale1) return "PC_Gv3_Vendor_82";
    if (c.VendorDialogSet == c.EVendorDialog.VDialog_GenericFemale2) return "PC_Gv4_Vendor_83";
    return "";
}

// Engagement-gated mute of strOutOfStockId on every AP-eligible vendor. While
// the player is engaged with such a vendor, the engaged vendor's strOutOfStockId
// is "" so the post-trade CutCue chain takes DoCutTalk's empty-string fast path
// and the "sorry, I'm out" voice never plays. Every other tick the id is
// restored to its vanilla value, so the proximity-bump path (SayPopupLine, which
// has NO empty-string fast path) still plays the proper line + subtitle.
// Idempotent.
function TradersanityKillPostTradeOutOfStockPass()
{
    local VendorManager vm;
    local Characters c, engagedVendor;
    local string desired, lvl;
    local int locId;

    if (default.TradersanityMode == TRADER_OFF) return;

    engagedVendor = None;
    if (HarryRef != None)
    {
        vm = HarryRef.CurrVendorManager;
        if (vm != None) engagedVendor = vm.Vendor;
    }

    lvl = string(Level.Outer.Name);
    foreach AllActors(class'Characters', c)
    {
        locId = class'APLocationRegistry'.static.GetVendorLocationId(lvl, string(c.Name));
        if (locId == 0) continue;
        if (c == engagedVendor)
        {
            desired = "";
        }
        else
        {
            desired = VanillaOutOfStockIdForVendor(c);
        }
        if (c.VendorDialog.strOutOfStockId != desired)
        {
            c.VendorDialog.strOutOfStockId = desired;
        }
    }
}

// True for the four Tradersanity-eligible sell types. Fred/George
// (Sells_Nimbus2001 / Sells_QArmor) and Sells_Duel / Sells_Nothing are excluded
// by omission. Enum reference form per VendorManager.uc.
function bool IsTradersanitySellType(Characters c)
{
    return c.CharacterSells == c.ESells.Sells_WBark
        || c.CharacterSells == c.ESells.Sells_FMucus
        || c.CharacterSells == c.ESells.Sells_BronzeCards
        || c.CharacterSells == c.ESells.Sells_SilverCards;
}

// Find-or-add a vendor in the per-level registry. The original sell type comes
// from the GENERATED registry, NOT the live actor, so a card vendor converted to
// Sells_WBark is still known to be a card vendor after a save/load. The price
// range is snapshotted from the actor's original fields (best-effort).
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

// Original sell type was a card tier - this vendor is converted to an ingredient
// vendor while its check is pending and restored on collection.
function bool IsTraderCardVendor(int idx)
{
    return TraderOrigSells[idx] == SELLS_BRONZE
        || TraderOrigSells[idx] == SELLS_SILVER;
}

// Every pending Tradersanity vendor sells via the ingredient path, so the active
// price is always the single ingredient field that GetSellingPrice reads.
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

// Apply the slot_data price mode to the vendor's active (ingredient) price, once
// per visit. price_low: flat. price_random: blend the per-vendor pre-rolled
// factor across [LO,HI]. price_vanilla: a genuine ingredient vendor keeps its
// true price; a converted card vendor blends the SAME factor across its original
// card [min,max]. The factor is rolled in the apworld from the seed and shipped
// via TRADERPRICES, so a vendor's AP-check price is fixed for the seed.
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

// Put a sold Tradersanity vendor fully back to vanilla, exactly once. Called the
// instant the sale resolves (the AP token is claimed), NOT deferred to the token
// pickup, so the vendor is sellable again in the same trade session. A converted
// card vendor returns to its card tier. The original ingredient sale price is
// restored unconditionally so a later level load can't leave it stuck at the AP
// price. nCurrIngrCount is restored to the vanilla count snapshotted at
// registration so vanilla resumes managing stock immediately.
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
    // engage and reuses it for the whole dialogue; it never recomputes per item.
    // So an open menu keeps showing/charging the AP price after we revert until
    // the player disengages and re-talks. Push the reverted price into the live
    // menu instance so it updates in the same trade session.
    if (c.managerVendor != None)
    {
        c.managerVendor.nCurrPrice = c.GetSellingPrice();
    }
    TraderRestored[idx] = 1;
    Log("[Archipelago] APVendorController.TradersanityPass: reverted vendor "
        $ string(c.Name) $ " (loc id " $ locId $ " price " $ TraderSavedLo[idx] $ ")");
}

// Tradersanity per-tick pass. No actor is ever Spawn()ed: a WizardCardIcon
// subclass returns None from Spawn() at essentially every occupied point in this
// engine (bCollideWhenPlacing=False is not honored). Instead we re-skin the prop
// the vendor itself spawned.
//
// While a vendor's check is pending it is made to sell exactly ONE item: a card
// vendor -> CharacterSells coerced to Sells_WBark (plain prop, no real card, so
// cardsanity stays independent); either kind -> nCurrIngrCount pinned to 1 and
// AP-priced. Vanilla MakePurchase deducts the beans, does --nCurrIngrCount, and
// drops a pickup prop. The single unit going 1 -> 0 between ticks is an
// unambiguous "paid purchase happened" signal. The PotionIngredients sweep below
// the vendor loop then morphs that dropped prop to the AP item's vanilla
// appearance and claims it as the vendor's pickup token; the check fires when
// the player PICKS IT UP. The checkedLoc branch then permanently reverts the
// vendor to full vanilla. Inert when the mode is off.
function TradersanityPass()
{
    local Characters c, v;
    local APIPCActor ipc;
    local PotionIngredients pi;
    local string lvl;
    local int locId, slot, idx, i, bestIdx, bLoc;
    local float bestD, dd;
    local bool checkedLoc, cardV;
    local APMorphRegistry mr;

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

        checkedLoc = (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1);
        cardV      = IsTraderCardVendor(idx);

        if (checkedLoc)
        {
            // Already collected - ensure the vendor is back to vanilla
            // (idempotent) and leave it alone so vanilla owns its stock.
            RevertTraderVendorOnce(c, idx, cardV, locId);
            continue;
        }

        if (TraderDispensed[idx] == 1)
        {
            // Sold. The vendor was put fully back to vanilla the instant the sale
            // resolved, so it is sellable again in the same trade session. The
            // morphed prop is the AP token; the check fires when the player PICKS
            // IT UP (the pickup destroys the actor).
            RevertTraderVendorOnce(c, idx, cardV, locId);
            if (TraderToken[idx] == None || TraderToken[idx].bDeleteMe)
            {
                ipc = class'APIPCActor'.static.GetInstance();
                if (ipc != None) ipc.SendCheckLocationId(locId);
                class'APCardWatcher'.default.NonCardLocationChecked[slot] = 1;
                Log("[Archipelago] APVendorController.TradersanityPass: vendor "
                    $ string(c.Name) $ " AP token picked up (loc id " $ locId
                    $ ") - fired CHECK_LOCID");
            }
            continue;
        }

        // Pending and unsold. Coerce a card vendor onto the ingredient sale path
        // so the sold prop is a plain WiggentreeBark, never a real card (only
        // while undispensed - once sold the revert above owns it).
        if (cardV)
        {
            c.CharacterSells = c.ESells.Sells_WBark;
        }

        if (TraderApplied[idx] == 0)
        {
            // Arm: AP price + a single purchasable unit, together (same tick, so
            // it can't be misread as a sale).
            ApplyVendorPrice(c, idx, slot);
            c.nCurrIngrCount = 1;
            TraderApplied[idx] = 1;
            TraderWait[idx] = 0;
        }
        else if (c.nCurrIngrCount == 0)
        {
            // Bought (beans paid, MakePurchase decremented it). The morph sweep
            // below claims the dropped prop as the token AND reverts the vendor
            // this same tick; hold at zero stock until it does. Safety net: if no
            // token ever resolves fire the check directly and revert so the
            // vendor can't stick pending forever.
            c.nCurrIngrCount = 0;
            TraderWait[idx] = TraderWait[idx] + 1;
            if (TraderWait[idx] >= TRADER_PICKUP_WAIT_TICKS)
            {
                ipc = class'APIPCActor'.static.GetInstance();
                if (ipc != None) ipc.SendCheckLocationId(locId);
                class'APCardWatcher'.default.NonCardLocationChecked[slot] = 1;
                TraderDispensed[idx] = 1;
                RevertTraderVendorOnce(c, idx, cardV, locId);
                Log("[Archipelago] APVendorController.TradersanityPass: vendor "
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

    // Morph + claim the freshly-dropped sale prop for any vendor that just sold
    // but has no token yet. Sequential top-level iterator (never nested in the
    // Characters sweep) and mutate-only - no Spawn. The prop is re-skinned to the
    // AP item's vanilla appearance for its location and becomes the vendor's
    // pickup token; picking it up fires the check.
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

        class'APAppearanceMath'.static.ApplyAppearanceTo(pi, class'APMorphRegistry'.static.AppearanceForApId(bLoc));
        // The dropped prop is a real WiggentreeBark/FlobberwormMucus; its
        // ingredient grant is the stock HProp pickup pipeline reading these two
        // class fields. Null them on this instance so picking the morphed AP
        // token up does not add the ingredient to inventory, while the pickup
        // itself still destroys the actor so the check still fires.
        pi.classStatusGroup = None;
        pi.classStatusItem  = None;
        mr = class'APMorphRegistry'.static.GetInstance(self);
        if (mr != None) mr.RegisterMorphMarker(pi, bLoc);
        TraderToken[bestIdx]     = pi;
        TraderDispensed[bestIdx] = 1;
        TraderWait[bestIdx]      = 0;
        // Put the vendor back to vanilla in this same tick the sale resolves so
        // it sells its normal stock again immediately (not deferred to the token
        // pickup). The check still fires when the token is picked up.
        RevertTraderVendorOnce(TraderVendor[bestIdx], bestIdx,
            IsTraderCardVendor(bestIdx), bLoc);
        Log("[Archipelago] APVendorController.TradersanityPass: vendor "
            $ string(TraderVendor[bestIdx].Name) $ " sold - morphed dropped "
            $ string(pi.Class.Name) $ " to AP appearance (loc id " $ bLoc
            $ "), vendor reverted, check fires on pickup");
    }
}

defaultproperties
{
    bHidden=True
    bGameRelevant=False
    bCollideActors=False
    bBlockActors=False
}

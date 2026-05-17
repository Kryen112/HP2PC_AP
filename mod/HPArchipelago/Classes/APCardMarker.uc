// Base class for the AP-replacement card icons placed in chests/cauldrons/levels.
// One concrete subclass per card class (APCardMarker_WCStarkey etc.) is
// auto-generated from data/items.yaml; each subclass sets CardLocationId
// to the real card id.
//
// Why we extend WizardCardIcon: we want the vanilla visual experience (mesh,
// bouncing physics, fall-from-chest, fly-to-HUD spin). Extending WizardCardIcon
// inherits all that for free.
//
// Why Id=200 in defaults: vanilla harry.uc:977 / RemoveHarryOwnedCardsFromLevel
// iterates chests and bean-swaps EjectedObjects[i] whose class is a WizardCardIcon
// child IF IsOwnedByHarry(class.Default.Id) returns true. Setting Id=200 (a
// sentinel never present in WizardCards[]) makes that check always-false, so our
// markers are immune to the level-entry bean-swap.
//
// CardLocationId holds the actual game-side card id (1..101) we fire CHECK for.
class APCardMarker extends WizardCardIcon;

var int CardLocationId;
// True if this marker was spawned by APGameInfo.ReplaceCardChests for a
// design-time loose-icon placement (Sweeting, Sykes, Oglethorpe, etc.) as
// opposed to chest-spawned by chestbronze.generateobject. Loose-spawned
// markers keep bPersistent=True so they survive level transitions (matching
// the vanilla wci behaviour they replace, since the cache delta records the
// vanilla wci as destroyed — without a persistent replacement the spot ends
// up empty on re-entry). Chest-spawned markers get bPersistent=False via
// the Timer to avoid the 18-marker-stacking bug.
var bool bIsLooseSpawn;

// "Bronze" / "Silver" / "Gold" — set per generated subclass
// (mirrors the parent vanilla class's tier). Used by
// APCardWatcher.AssignMarkersToVendors to pick the right si (siBronze /
// siSilver / siGold) when assigning vendor ownership for missed cards.
// `bVendorsCanSell` and `strVendorOwnedAfterGState` are inherited from
// `WizardCardIcon` — generated subclasses override them via defaultproperties
// with the per-card vanilla values so vendors see our markers as sellable.
var string MarkerTier;

// AP item display name (e.g. "Silver Card - Duke"), set per generated subclass
// from items.yaml's `name` field. APGameInfo.FormatGrantText reads this so the
// HUD toast shows the real AP name instead of synthesising "Received silver
// card Duke" from class + MarkerTier.
var string DisplayName;

// Set True for cards the level designer placed mid-air
// (e.g., `WCToothill` floating above the Grand Staircase, vanilla intent: reach
// it via Spongify-jump). Vanilla level-loaded `WizardCardIcon` defaults to
// `Physics=PHYS_None` (no Physics line in `WizardCardIcon.defaultproperties`)
// so it stays pinned. Our `Spawned()` normally overrides to `PHYS_Falling` so
// chest-ejected cards fall and mover-carried cards (Chamber-II descending
// platform → `WCElphick`) get pushed by mover collision — but that breaks the
// floating placements. With this flag set, `Spawned()` keeps `PHYS_None` to
// preserve the design-time Z. Set per-card via the FLOATING_CARDS list
// in the codegen tooling.
var bool bIsFloatingCard;

function PostBeginPlay()
{
    local APCardWatcher w;

    Super.PostBeginPlay();

    Log("[Archipelago] APCardMarker.PostBeginPlay: " $ string(self) $ " CardLocationId=" $ CardLocationId
        $ " at " $ string(Location) $ " bHidden=" $ bHidden $ " Mesh=" $ string(Mesh));

    if (CardLocationId > 0 && CardLocationId <= 101
        && class'APCardWatcher'.default.LocationChecked[CardLocationId] == 1)
    {
        Log("[Archipelago] APCardMarker.PostBeginPlay: location " $ CardLocationId
            $ " already checked - destroying immediately");
        Destroy();
        return;
    }

    // #3 capability contract: opt this marker into the appearance sweep and
    // best-effort morph it now. Runs AFTER the self-destroy guard so a
    // checked location never registers/morphs a stale ghost. Register on the
    // live per-level watcher (instance registry — class-default actor refs
    // crash level cleanup); the watcher exists by now (spawned in InitGame
    // before ReplaceCardChests). Self-apply is independent of registration
    // and a no-op until the table arrives (async-safe); the sweep is the
    // authoritative re-stamp.
    if (CardLocationId > 0 && CardLocationId <= 101)
    {
        w = class'APCardWatcher'.static.GetLatest();
        if (w != None)
        {
            w.RegisterMorphMarker(self,
                class'APCardAppearance'.static.CardIdToApId(CardLocationId));
        }
        ApplyAPAppearance();
    }

    // Defer bPersistent=False to next tick. chestbronze.generateobject (uc:163)
    // stamps newSpawn.bPersistent = bMakeSpawnPersistent AFTER PostBeginPlay
    // returns, so setting bPersistent here would be overridden. The Timer
    // fires next tick — by then the chest's generateobject has finished and
    // our False sticks. Effect: an opened-but-not-picked-up card is gone on
    // level re-entry instead of stacking into a pile of intangible markers.
    // (For loose-spawn markers there's no chest stamp, but the timer still
    // runs harmlessly.)
    SetTimer(0.05, false);
}

event Timer()
{
    if (!bIsLooseSpawn)
    {
        bPersistent = False;
    }
    SetTimer(0.0, false);
}

// Override the parent's bouncing-fall behavior. Vanilla WizardCardIcon.Spawned()
// sets PHYS_Falling and goes to state 'bouncing' so the icon flies out of the
// chest with a dramatic arc. The bouncing state moves the icon around, which
// makes loose-icon replacements (placed at design time) end up far from where
// the player expects them. We keep gravity (PHYS_Falling so chest-spawned
// markers fall to the floor instead of floating) but skip the bouncing state —
// the marker drops straight down to land at its spawn x/y, then sits in Wait.
function Spawned()
{
    if (bIsFloatingCard)
    {
        // Pin at design-time location. Mirrors vanilla level-loaded
        // WizardCardIcon's default PHYS_None.
        SetPhysics(PHYS_None);
    }
    else
    {
        SetPhysics(PHYS_Falling);
    }
    bBouncingState = False;
    GotoState('Wait');
}

// Called by APGameInfo.ReplaceCardChests right after spawning a loose-icon
// replacement at a design-time placement. v1 had this switch to PHYS_None to
// pin the marker, but that broke mover-carried cards (Chamber-II descending
// platform) because PHYS_None actors don't get pushed by mover collision.
//
// v2: no-op. We leave PHYS_Falling from Spawned() in place. The Wait state's
// HitWall override below zeroes velocity on contact so the card settles on
// its initial surface without drifting, and a mover sliding through it still
// carries it via collision.
//
// Sets bIsLooseSpawn so the deferred Timer leaves bPersistent at the default
// True. Without this flag, our Timer-driven bPersistent=False (intended for
// chest-spawned markers) would also nuke loose-spawned markers, and since the
// cache delta records the vanilla wci as destroyed, the spot would be empty
// on every re-entry.
function MarkAsLoose()
{
    bIsLooseSpawn = True;
}

// Override vanilla's empty Wait.HitWall so the card actually settles on its
// landing surface instead of jittering forever under gravity. Velocity zeroed
// on every contact; PHYS_Falling stays active so movers can collision-carry
// the card. Tick keeps vanilla's spinning-yaw animation. The begin: loop
// mirrors vanilla — UE1 needs a state entry point.
auto state Wait
{
    function HitWall(Vector HitNormal, Actor Wall)
    {
        Velocity = vect(0, 0, 0);
    }

    function Tick(float Delta)
    {
        local Rotator newRot;

        newRot = Rotation;
        newRot.Yaw = newRot.Yaw + (50000 * Delta);
        SetRotation(newRot);
    }

begin:
    Sleep(1.0);
    goto ('Begin');
}

function Touch(Actor Other)
{
    local APIPCActor ipc;
    local APCardWatcher w;
    local harry h;
    local Rotator rotPickupFX;

    h = harry(Other);
    if (h == None) return;
    if (CardLocationId <= 0 || CardLocationId > 101) return;
    // Already AP-checked: this is a stale duplicate (e.g. vendor spawned a
    // second copy of the same card before the player picked up the first).
    // Destroy self instead of returning silently — leaving the actor in the
    // world makes it an intangible ghost the player walks through forever.
    if (class'APCardWatcher'.default.LocationChecked[CardLocationId] == 1)
    {
        Log("[Archipelago] APCardMarker.Touch: location " $ CardLocationId $ " already checked - destroying stale duplicate marker");
        Destroy();
        return;
    }

    Log("[Archipelago] APCardMarker.Touch: firing CHECK " $ CardLocationId);

    // Use the persistent singleton directly. Save-load skips APGameInfo.InitGame,
    // so the post-save-load APGameInfo's IPCActor field stays None and going
    // through gi.IPCActor silently drops the CHECK. The singleton survives the
    // level transition via bGameRelevant and is always reachable via GetInstance.
    ipc = class'APIPCActor'.static.GetInstance();
    if (ipc != None)
    {
        ipc.SendCheck(CardLocationId);
    }
    else
    {
        Log("[Archipelago] APCardMarker.Touch: APIPCActor singleton is None - CHECK " $ CardLocationId $ " dropped");
    }

    class'APCardWatcher'.default.LocationChecked[CardLocationId] = 1;

    // Phase A vendor support: clear any vendor ownership of this card so the
    // next AssignVendorCards pass (every save / level transition) doesn't
    // re-offer it. The watcher holds the bound siBronze/siSilver/siGold refs
    // we need for the lookup.
    w = class'APCardWatcher'.static.GetLatest();
    if (w != None)
    {
        w.ClearVendorOwnershipForLocation(CardLocationId);
    }

    // AP-themed pickup feedback: spawn the 6 Archipelago-logo-coloured star
    // bursts, then play the per-tier pickup sound (set in each
    // generated APCardMarker_<X> subclass: pickup_WC_bronze/silver/gold).
    // The Pitch=16464 rotation matches vanilla WizardCardIcon.Touch's rotPickupFX
    // so the stars emit upward instead of into the floor.
    rotPickupFX.Pitch = 16464;
    rotPickupFX.Yaw = 0;
    rotPickupFX.Roll = 0;
    Spawn(class'APStarsRed',    , , Location, rotPickupFX);
    Spawn(class'APStarsOrange', , , Location, rotPickupFX);
    Spawn(class'APStarsYellow', , , Location, rotPickupFX);
    Spawn(class'APStarsGreen',  , , Location, rotPickupFX);
    Spawn(class'APStarsBlue',   , , Location, rotPickupFX);
    Spawn(class'APStarsPurple', , , Location, rotPickupFX);

    if (soundPickup != None)
    {
        PlaySound(soundPickup);
    }

    Destroy();
}

// #3 capability contract. Resolve this card location's appearance code and
// stamp it onto self. The card branch of the resolver reads the exact card
// face from <cardClass>.default.Skin. Called best-effort from PostBeginPlay
// and authoritatively by APCardWatcher.RestampMarkerAppearance.
function ApplyAPAppearance()
{
    if (CardLocationId <= 0 || CardLocationId > 101) return;
    class'APCardWatcher'.static.ApplyAppearanceTo(self,
        class'APCardWatcher'.static.AppearanceForApId(
            class'APCardAppearance'.static.CardIdToApId(CardLocationId)));
}

defaultproperties
{
    Id=200
    bPickupOnTouch=True
    PickupFlyTo=FT_HudPosition
}

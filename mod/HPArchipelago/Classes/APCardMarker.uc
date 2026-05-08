// Base class for the AP-replacement card icons placed in chests/cauldrons/levels.
// One concrete subclass per card class (APCardMarker_WCStarkey etc.) is generated
// by scripts/gen_apworld.py from data/items.yaml; each subclass sets CardLocationId
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

function PostBeginPlay()
{
    Super.PostBeginPlay();

    Log("[Archipelago] APCardMarker.PostBeginPlay: " $ string(self) $ " CardLocationId=" $ CardLocationId
        $ " at " $ string(Location) $ " bHidden=" $ bHidden $ " Mesh=" $ string(Mesh));

    if (CardLocationId > 0 && CardLocationId <= 101
        && class'APCardWatcher'.default.LocationChecked[CardLocationId] == 1)
    {
        Log("[Archipelago] APCardMarker.PostBeginPlay: location " $ CardLocationId
            $ " already checked - destroying immediately");
        Destroy();
    }
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
    SetPhysics(PHYS_Falling);
    bBouncingState = False;
    GotoState('Wait');
}

function Touch(Actor Other)
{
    local APGameInfo gi;
    local harry h;

    h = harry(Other);
    if (h == None) return;
    if (CardLocationId <= 0 || CardLocationId > 101) return;
    if (class'APCardWatcher'.default.LocationChecked[CardLocationId] == 1) return;

    Log("[Archipelago] APCardMarker.Touch: firing CHECK " $ CardLocationId);

    gi = APGameInfo(Level.Game);
    if (gi != None && gi.IPCActor != None)
    {
        gi.IPCActor.SendCheck(CardLocationId);
    }

    class'APCardWatcher'.default.LocationChecked[CardLocationId] = 1;

    if (soundPickup != None)
    {
        PlaySound(soundPickup);
    }

    Destroy();
}

defaultproperties
{
    Id=200
    bPickupOnTouch=True
    PickupFlyTo=FT_HudPosition
}

// Shared base for the runtime-spawned exit stars that travel the player back to
// Entryhall_Hub on touch. Subclasses override CreditObjective to fire their AP
// level-objective credit (the bean room exit credits nothing).
//
// Inherits the gold FinalStar appearance verbatim (mesh, particle, AmbientGlow,
// PHYS_Rotating, bPickupOnTouch) via FinalStar's defaultproperties.
//
// Not a Super.EndState() call: vanilla FinalStar.EndState drives a
// ChallengeScoreManager (challenge levels only) and an editor-wired Event/CutName,
// none of which exist for a runtime-spawned star in these levels, so calling it
// would null-access.
class APEndStarBase extends FinalStar;

// HPawn.OnResolveGameState hides + de-collides any actor not in the level's
// current game state. A runtime-spawned star has no game-state membership, so
// override the resolver to keep this permanent exit star visible and touchable.
event OnResolveGameState() {}

// Force visible + overlap-collidable right after spawn (bCollideActors=True so
// HProp.Touch fires; bBlock* False so the player passes through like a vanilla
// star) in case a base Pre/PostBeginPlay path disabled collision.
function PostBeginPlay()
{
    Super.PostBeginPlay();
    bHidden = False;
    SetCollision(True, False, False);
}

// AP credit on touch. Default does nothing (the bean room exit is not an AP
// location). Subclasses override to fire their dedupe-safe NotifyLevelObjective.
function CreditObjective() {}

state PickupProp
{
    function EndState()
    {
        local Pawn p;
        local PlayerPawn localPlayerPawn;
        local HPConsole console;
        local harry h;

        // Credit first: synchronous, idempotent, sticky. Doing it before the
        // travel guarantees the credit even if the console lookup or travel fails.
        CreditObjective();

        // Reach the local player's console without depending on the watcher's
        // HarryRef (it may not be bound at the instant of touch).
        foreach AllActors(class'Pawn', p)
        {
            localPlayerPawn = PlayerPawn(p);
            if (localPlayerPawn != None && localPlayerPawn.Player != None)
                break;
            localPlayerPawn = None;
        }
        if (localPlayerPawn != None && localPlayerPawn.Player != None)
            console = HPConsole(localPlayerPawn.Player.Console);
        h = harry(localPlayerPawn);

        // Prefer harry.LoadLevel (the path TriggerChangeLevel volumes use) so the
        // room commits its persistent-actor state via SavePActors before travel; a
        // raw ChangeLevel would discard found secrets, picked-up beans and dropped
        // loot. Fall back to ChangeLevel if the harry cast fails.
        if (h != None)
        {
            Log("[Archipelago] " $ string(Class.Name) $ ": harry.LoadLevel('Entryhall_Hub')");
            h.LoadLevel("Entryhall_Hub");
        }
        else if (console != None)
        {
            Log("[Archipelago] " $ string(Class.Name) $ ": no harry; ChangeLevel('Entryhall_Hub', True)");
            console.ChangeLevel("Entryhall_Hub", True);
        }
        else
        {
            // AP credit (if any) already fired above; the player can still use the
            // original level exit or the pause-menu Return to Entry Hall.
            Log("[Archipelago] " $ string(Class.Name) $ ": no harry/HPConsole found - using fallback exit");
        }
    }
}

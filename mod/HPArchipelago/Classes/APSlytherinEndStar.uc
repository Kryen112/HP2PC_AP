// Visible "end star" for the Slytherin Common Room (Adv7SlythComRoom).
//
// Inherits the gold FinalStar appearance verbatim (skChallengeStarFinalMesh,
// GoldstarFinal particle, AmbientGlow, PHYS_Rotating, bPickupOnTouch). The
// only behavioural change is a full override of PickupProp.EndState:
//   - credits the clause-3 Slytherin objective (CHECK_LOCID 5760706) via the
//     dedupe-safe APCardWatcher.NotifyLevelObjective, then
//   - travels the player back to Entryhall_Hub through HPConsole.ChangeLevel,
//     the same inventory/quest-preserving path APFEInGamePage.TeleportToHub
//     uses.
//
// It is NOT a Super.EndState() call: vanilla FinalStar.EndState drives a
// ChallengeScoreManager (challenge-levels only) and TriggerEvent on its
// editor-wired Event/CutName - none of which exist for a runtime-spawned
// actor in this adventure level, so calling it would null-access.
//
// Lifecycle: APGameInfo.SpawnSlytherinEndStarIfMissing spawns one near the
// level start while the objective is uncredited; the original puzzle exit
// stays as a harmless deduped fallback (NotifyLevelObjective is idempotent).
class APSlytherinEndStar extends FinalStar;

// Adv7SlythComRoom clause-3 objective index
// (APCardWatcher.LevelObjectiveIndexFor("ADV7SLYTHCOMROOM") == 6).
const SLYTHERIN_OBJECTIVE_INDEX = 6;

// HPawn.OnResolveGameState (HPawn.uc:139-146) does
// `bHidden=True; SetCollision(False,False,False)` for any actor not in the
// level's CURRENT game state. A runtime-Spawned actor has no editor-assigned
// game-state membership, so the moment Adv7SlythComRoom resolves a game state
// (log: iGameState 0 -> 180) the vanilla resolver would make this star
// invisible AND non-touchable. This is a permanent level-exit star, so we
// never want it culled - override the resolver to do nothing.
event OnResolveGameState() {}

// Belt-and-suspenders: assert the star is visible and overlap-collidable
// (bCollideActors=True so HProp.Touch fires; bBlock* False so the player
// passes through like a vanilla star) right after spawn, in case any base
// PreBeginPlay/PostBeginPlay path disabled collision before OnResolveGameState
// is overridden out.
function PostBeginPlay()
{
    Super.PostBeginPlay();
    bHidden = False;
    SetCollision(True, False, False);
}

state PickupProp
{
    function EndState()
    {
        local Pawn p;
        local PlayerPawn localPlayerPawn;
        local HPConsole console;

        // Credit first: synchronous, idempotent, sticky (sets
        // NonCardLocationChecked + GoalLevelDone[6], fires CHECK_LOCID
        // 5760706). Doing it before the travel guarantees the credit even if
        // the console lookup or ChangeLevel below fails.
        class'APCardWatcher'.static.NotifyLevelObjective(SLYTHERIN_OBJECTIVE_INDEX);

        // Reach the local player's console without depending on
        // APCardWatcher.HarryRef (the watcher may not be bound at the instant
        // of touch). Same cast HPConsole(... .Player.Console) used elsewhere.
        foreach AllActors(class'Pawn', p)
        {
            localPlayerPawn = PlayerPawn(p);
            if (localPlayerPawn != None && localPlayerPawn.Player != None)
                break;
            localPlayerPawn = None;
        }
        if (localPlayerPawn != None && localPlayerPawn.Player != None)
            console = HPConsole(localPlayerPawn.Player.Console);

        if (console != None)
        {
            Log("[Archipelago] APSlytherinEndStar: ChangeLevel('Entryhall_Hub', True)");
            console.ChangeLevel("Entryhall_Hub", True);
        }
        else
        {
            // AP check already fired above; the original level exit still
            // credits via CheckExitedLevelObjective. Do not crash.
            Log("[Archipelago] APSlytherinEndStar: no HPConsole found - AP check fired, player can still use the original exit");
        }
    }
}

// Visible "end star" for the Gryffindor Challenge (Ch7Gryffindor).
//
// Unlike the four spell challenges, Ch7Gryffindor ships NO ChallengeScoreManager,
// so vanilla FinalStar.PickupProp.EndState runs managerChallenge.PickedUpFinalStar()
// on a None reference (no score tally) and TriggerEvent(Event) travels to the hub
// on the same frame the star is destroyed. APCardWatcher.ScanFinalStarCompletion
// credits challenges 7-11 by observing a FinalStar go present -> absent while the
// per-level watcher is still bound, but that window never exists here: the level
// (and the watcher) tear down before any poll tick sees the star gone, so the
// completion check would never fire.
//
// This AP-aware replacement (swapped in for the placed FinalStar by
// APCardWatcher.ReplaceGryffindorEndStar) credits the objective synchronously in
// EndState, then travels to Entryhall_Hub itself, the same shape as
// APSlytherinEndStar. The credit is guaranteed regardless of the immediate travel.
class APGryffindorEndStar extends FinalStar;

// Ch7Gryffindor clause-3 objective index
// (APCardWatcher.LevelObjectiveIndexFor("CH7GRYFFINDOR") == 11). Fires CHECK_LOCID
// 5760711 via NotifyLevelObjective.
const GRYFFINDOR_OBJECTIVE_INDEX = 11;

// Runtime-spawned (the watcher destroys the placed FinalStar and Spawns this at
// its Location), so it has no editor-assigned game-state membership. The vanilla
// resolver would do bHidden=True; SetCollision(False,...) for any actor not in
// the level's current game state. This is a permanent level-exit star, so
// override the resolver to do nothing.
event OnResolveGameState() {}

// Force visible + overlap-collidable right after spawn (bCollideActors=True so
// HProp.Touch fires; bBlock* False so the player passes through like a vanilla
// star) in case any base Pre/PostBeginPlay path disabled collision.
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
        local harry h;

        // Credit first: synchronous, idempotent, sticky (sets
        // NonCardLocationChecked + GoalLevelDone[11], fires CHECK_LOCID 5760711).
        // Doing it before the travel guarantees the credit even if the console
        // lookup or ChangeLevel below fails.
        class'APCardWatcher'.static.NotifyLevelObjective(GRYFFINDOR_OBJECTIVE_INDEX);

        // Reach the local player's console without depending on
        // APCardWatcher.HarryRef (the watcher may not be bound at the instant
        // of touch).
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
        // room commits its persistent-actor state via SavePActors before travel;
        // a raw ChangeLevel would discard found secrets, picked-up beans and
        // dropped loot. Fall back to ChangeLevel if the harry cast ever fails.
        if (h != None)
        {
            Log("[Archipelago] APGryffindorEndStar: harry.LoadLevel('Entryhall_Hub')");
            h.LoadLevel("Entryhall_Hub");
        }
        else if (console != None)
        {
            Log("[Archipelago] APGryffindorEndStar: no harry; ChangeLevel('Entryhall_Hub', True)");
            console.ChangeLevel("Entryhall_Hub", True);
        }
        else
        {
            // AP check already fired above; the original level exit still
            // travels via the level's own TriggerChangeLevel. Do not crash.
            Log("[Archipelago] APGryffindorEndStar: no harry/HPConsole found - AP check fired, player can still use the original exit");
        }
    }
}

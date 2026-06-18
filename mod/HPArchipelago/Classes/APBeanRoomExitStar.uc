// Visible exit star for the open-castle bean bonus room (BeanRewardRoom).
//
// Open castle reaches the bean room via a spawned TriggerChangeLevel in
// Entryhall_hub and suppresses the native timer (so the room's timer-expiry
// return never fires), leaving this star as the in-world way back to the hub.
// The pause-menu "Return to Entry Hall" button is the fallback.
//
// Clone of APSlytherinEndStar minus the AP credit: the bean room is not an AP
// location, so EndState only travels. Not a Super.EndState() call, for the
// same reason APSlytherinEndStar avoids it (vanilla FinalStar.EndState drives a
// ChallengeScoreManager and an editor-wired Event a runtime-spawned star lacks).
class APBeanRoomExitStar extends FinalStar;

// A runtime-spawned star has no game-state membership, so the vanilla resolver
// would hide and de-collide it. Override to keep this permanent exit visible.
event OnResolveGameState() {}

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

        // Prefer harry.LoadLevel (the TriggerChangeLevel path) so the room
        // commits its persistent-actor state via SavePActors first, keeping
        // picked-up beans picked up. Fall back to ChangeLevel if the cast fails.
        if (h != None)
        {
            Log("[Archipelago] APBeanRoomExitStar: harry.LoadLevel('Entryhall_Hub')");
            h.LoadLevel("Entryhall_Hub");
        }
        else if (console != None)
        {
            Log("[Archipelago] APBeanRoomExitStar: no harry; ChangeLevel('Entryhall_Hub', True)");
            console.ChangeLevel("Entryhall_Hub", True);
        }
        else
        {
            Log("[Archipelago] APBeanRoomExitStar: no harry/HPConsole - player can still use the pause-menu Return to Entry Hall");
        }
    }
}

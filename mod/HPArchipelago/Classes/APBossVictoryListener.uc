// Invisible listener tagged with a boss's final-defeat event. The boss's own
// TriggerEvent calls Trigger synchronously inside the kill, so the level objective
// is credited before a skipped victory cutscene can carry the level out.
// APLocationScanner.EnsureBossVictoryListener spawns one per boss level.
class APBossVictoryListener extends Actor;

var int ObjectiveIndex;

event Trigger(Actor Other, Pawn EventInstigator)
{
    Log("[Archipelago] APBossVictoryListener: " $ string(Tag) $ " fired - crediting objective idx=" $ ObjectiveIndex);
    class'APGoalTracker'.static.NotifyLevelObjective(ObjectiveIndex);
}

defaultproperties
{
    bHidden=True
    bCollideActors=False
    bBlockActors=False
    bBlockPlayers=False
}

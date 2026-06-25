// AP-aware Gold Card Room end trigger (open castle's 13th level objective).
//
// Ch6WizardCard's far-end TriggerChangeLevel (tag changelevel1) reloads the
// room on touch. APLevelSetup.ReplaceGoldRoomEndTrigger swaps the placed
// instance for this subclass so reaching the end credits clause-3 objective
// idx 12 (CHECK_LOCID 5760712) synchronously, before the stock reload travels.
//
// Crediting here (not on level exit) is required: the trigger reloads the SAME
// level, so the exit-credit path never sees a level change, and the room's
// entrance TriggerChangeLevel bails to the hub without completing. ProcessTrigger
// is virtual and is the single sink both the Touch and Trigger-event paths call,
// so overriding it covers every way the volume fires.
class APTriggerChangeLevel extends TriggerChangeLevel;

// APGoalTracker.LevelObjectiveIndexFor("CH6WIZARDCARD") == 12.
const GOLDROOM_OBJECTIVE_INDEX = 12;

function ProcessTrigger()
{
    // Idempotent + sticky (NonCardLocationChecked + GoalLevelDone[12]). Fired
    // before Super travels so the credit survives the immediate reload.
    class'APGoalTracker'.static.NotifyLevelObjective(GOLDROOM_OBJECTIVE_INDEX);
    Super.ProcessTrigger();
}

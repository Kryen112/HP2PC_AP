// Visible "end star" for the Gryffindor Challenge (Ch7Gryffindor).
//
// Ch7Gryffindor ships no ChallengeScoreManager, and the level (and its watcher)
// tear down before any poll tick sees the placed FinalStar go absent, so the
// usual ScanFinalStarCompletion path never fires. APLevelSetup.ReplaceGryffindorEndStar
// swaps this AP-aware star in for the placed FinalStar; it credits the objective
// synchronously in CreditObjective, then APEndStarBase travels to the hub.
class APGryffindorEndStar extends APEndStarBase;

// Ch7Gryffindor clause-3 objective index
// (APGoalTracker.LevelObjectiveIndexFor("CH7GRYFFINDOR") == 11). Fires
// CHECK_LOCID 5760711 via NotifyLevelObjective.
const GRYFFINDOR_OBJECTIVE_INDEX = 11;

function CreditObjective()
{
    class'APGoalTracker'.static.NotifyLevelObjective(GRYFFINDOR_OBJECTIVE_INDEX);
}

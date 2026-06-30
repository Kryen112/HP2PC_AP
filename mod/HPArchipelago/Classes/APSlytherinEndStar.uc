// Visible "end star" for the Slytherin Common Room (Adv7SlythComRoom).
//
// APGameInfo.SpawnSlytherinEndStarIfMissing spawns one near the level start while
// the clause-3 objective is uncredited. The original puzzle exit stays as a
// harmless deduped fallback (NotifyLevelObjective is idempotent). All shared
// behavior (visible/collidable setup, travel-to-hub on touch) lives in
// APEndStarBase; this only adds the AP credit.
class APSlytherinEndStar extends APEndStarBase;

// Adv7SlythComRoom clause-3 objective index
// (APGoalTracker.LevelObjectiveIndexFor("ADV7SLYTHCOMROOM") == 6). Fires
// CHECK_LOCID 5760706 via NotifyLevelObjective.
const SLYTHERIN_OBJECTIVE_INDEX = 6;

function CreditObjective()
{
    class'APGoalTracker'.static.NotifyLevelObjective(SLYTHERIN_OBJECTIVE_INDEX);
}

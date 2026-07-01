// AP-aware final star for the four spell challenges (Ch1Rictusempra, Ch2Skurge,
// Ch3Diffindo, Ch4Spongify; APGoalTracker level-objective idx 7..10). Picking up
// the vanilla FinalStar ends the challenge and the completion cutscene returns to
// the hub; APLocationScanner.ScanFinalStarCompletion's present->absent poll does not
// reliably observe the destroy in time, so the "... Challenge - Complete" check and
// the par-honest end-score capture do not fire (the same race the Gryffindor end
// star hit; see APGryffindorEndStar).
//
// APLevelSetup.ReplaceSpellChallengeFinalStar swaps this in. On pickup it fires the
// completion CHECK and captures the pre-tally end score, then hands off to the
// vanilla completion via Super.EndState(). Unlike APEndStarBase (Gryffindor / bean
// room, which own no ChallengeScoreManager and travel themselves) this preserves the
// vanilla FinalStar behaviour: the spell challenges own a ChallengeScoreManager, a
// tally, and the return-to-hub cutscene.
class APSpellChallengeFinalStar extends FinalStar;

state PickupProp
{
    function EndState()
    {
        local int idx;
        local APLocationScanner ls;

        idx = class'APGoalTracker'.static.LevelObjectiveIndexFor(Caps(string(Level.Outer.Name)));

        // Credit before the vanilla completion runs. CaptureSpellChallengeScore
        // reads the manager's live nCurrScore while the challenge is still in
        // progress (the honest end score, before the tally leaves nHighScore pinned
        // at par), and NotifyLevelObjective is guaranteed even if Super travels this
        // frame. Both are idempotent: genuine-best max fold, NonCardLocationChecked
        // dedupe.
        if (idx >= 7 && idx <= 10)
        {
            ls = class'APLocationScanner'.static.GetInstance(self);
            if (ls != None) ls.CaptureSpellChallengeScore(idx - 7);
            class'APGoalTracker'.static.NotifyLevelObjective(idx);
        }

        // Vanilla FinalStar completion: PickedUpFinalStar -> EndChallenge, then the
        // editor-wired Event drives the tally cutscene and the return-to-hub travel.
        Super.EndState();
    }
}

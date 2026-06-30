// Visible exit star for the open-castle bean bonus room (BeanRewardRoom).
//
// Open castle reaches the bean room via a spawned TriggerChangeLevel in
// Entryhall_hub and suppresses the native timer, leaving this star as the
// in-world way back to the hub (the pause-menu "Return to Entry Hall" is the
// fallback). The bean room is not an AP location, so it inherits APEndStarBase's
// travel-only behavior: CreditObjective stays the base no-op.
class APBeanRoomExitStar extends APEndStarBase;

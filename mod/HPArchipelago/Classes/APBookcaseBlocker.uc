//=============================================================================
// APBookcaseBlocker - level/challenge/ending chokepoint bookcase that tells the
// player which key it is waiting on. Collision and mesh are inherited unchanged
// from BookcaseGlassDoors; the only addition is a Bump handler that prints
// BlockMessage as a HUD subtitle, the same channel the stock Wiggenweld
// cauldron uses to say it is not ready yet.
//
// SpawnOpenCastleBookcase spawns this class by default and stamps BlockMessage
// per Tag, so every level/challenge/ending blocker gets the right line. An
// empty BlockMessage keeps the blocker silent but still solid. APFordAngliaBlocker
// (the Whomping Willow wreck) extends this so it speaks too.
//=============================================================================

class APBookcaseBlocker extends BookcaseGlassDoors;

// Subtitle shown when Harry bumps the blocker. Set per spawn; empty stays silent.
var string BlockMessage;

// Bump fires every frame Harry leans on the bookcase, so hold the next subtitle
// until Level.TimeSeconds passes this. Re-arms a few seconds after each show.
var float NextMessageTime;

event Bump(Actor Other)
{
    local harry h;
    local HPHud hud;

    Super.Bump(Other);

    if (BlockMessage == "") return;
    h = harry(Level.PlayerHarryActor);
    if (h == None || Other != h) return;
    if (Level.TimeSeconds < NextMessageTime) return;

    hud = HPHud(h.myHUD);
    if (hud == None) return;

    hud.SetSubtitleText(BlockMessage, (Len(BlockMessage) * 0.01) + 3.0);
    NextMessageTime = Level.TimeSeconds + 4.0;
}

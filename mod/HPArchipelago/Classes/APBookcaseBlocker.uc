//=============================================================================
// APBookcaseBlocker - level/challenge/ending/spell chokepoint bookcase that
// tells the player which key or spell it is waiting on. Collision and mesh are
// inherited unchanged from BookcaseGlassDoors; the additions are a proximity
// announcer that speaks while the player is still walking up and a Bump handler
// for the moment of contact. Both print BlockMessage as a HUD subtitle, the same
// channel the stock Wiggenweld cauldron uses to say it is not ready yet.
//
// Contact alone is not how a blocker reads: the player sees the bookcase,
// recognises it as closed and turns around without ever touching it, so the
// bumped line never plays and the requirement stays unknown. The proximity path
// puts the line on screen inside ProximityRadius, gated on clear line of sight
// so it never fires through a wall or a floor.
//
// APGameInfo.StampBlockerMessage stamps BlockMessage per Tag on every blocker
// spawn, so each site gets the right line. An empty BlockMessage keeps the
// blocker silent but still solid. APFordAngliaBlocker (the Whomping Willow
// wreck) extends this so it speaks too.
//=============================================================================

class APBookcaseBlocker extends BookcaseGlassDoors;

// Subtitle shown when Harry nears or bumps the blocker. Set per spawn; empty
// stays silent.
var string BlockMessage;

// Distance (uu) at which the approach line fires, read through `default.` so the
// APConsole BlockerHintRadius exec retunes live instances mid-playtest and so
// APFordAngliaBlocker's wider footprint can carry its own value. Harry runs at
// 210uu/s, so 500 lands the line about two and a half seconds out, before he has
// decided to turn around. Sites overlap at this range (Rictusempra, Duelling Club
// and the Great Hall gate sit 425uu to 900uu apart in Entryhall_hub) and there is
// no nearest-wins between them, which is accepted: they are on different floors,
// so line of sight separates them, and a pair it does not separate takes turns a
// cooldown apart instead of fighting over the subtitle.
var float ProximityRadius;

// Leaving costs 25% more distance than entering, so idling on the boundary does
// not re-arm the line every check.
const PROXIMITY_EXIT_SCALE = 1.25;

// Check cadence. A quarter second is well inside one of Harry's strides, and
// Tick only banks time until then.
const PROXIMITY_CHECK_INTERVAL = 0.25;

// How long one line holds the subtitle before any blocker may write another.
const ANNOUNCE_COOLDOWN = 4.0;

var float ProximityAccumulator;   // Tick time banked toward the next check
var bool bPlayerNear;             // inside the radius as of the last check
var bool bAnnouncePending;        // approach seen, line still owed

// The subtitle is one shared slot, so these are read and written through
// class'APBookcaseBlocker'.default: every blocker in the level, of either
// subclass, coordinates through the same pair. A site built from two to five
// identical bookcases speaks once, and two blockers with different lines at one
// doorway (Rictusempra and Spongify share a chokepoint in vanilla) take turns a
// cooldown apart instead of overwriting each other in the same frame. Floats and
// a string only, since an Actor reference in a class default faults on level
// teardown.
var float LastAnnounceTime;
var string LastAnnounceMessage;

function Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);

    ProximityAccumulator += DeltaTime;
    if (ProximityAccumulator < PROXIMITY_CHECK_INTERVAL) return;
    ProximityAccumulator = 0.0;
    CheckProximity();
}

// Latches the approach on the way in and clears it on the way out, so each
// approach is owed exactly one line. FastTrace walks world geometry only, so the
// gate is "Harry can see this blocker" rather than raw distance: a blocker one
// floor down or behind a wall stays quiet, and sibling blockers at the same site
// cannot occlude each other (actors are not traced).
function CheckProximity()
{
    local harry h;
    local float rangeToHarry;
    local bool bInRange;

    if (BlockMessage == "") return;
    h = harry(Level.PlayerHarryActor);
    if (h == None || h.bDeleteMe) return;

    rangeToHarry = VSize(h.Location - Location);
    if (bPlayerNear)
    {
        bInRange = rangeToHarry <= default.ProximityRadius * PROXIMITY_EXIT_SCALE;
    }
    else
    {
        bInRange = rangeToHarry <= default.ProximityRadius && FastTrace(h.Location);
    }

    if (!bInRange)
    {
        bPlayerNear = False;
        bAnnouncePending = False;
        return;
    }
    if (!bPlayerNear)
    {
        bPlayerNear = True;
        bAnnouncePending = True;
    }
    if (!bAnnouncePending) return;

    // A sibling bookcase at this site already put the identical line up, so drop
    // the turn rather than repeat it. Otherwise speak, and keep owing the line
    // while a cutscene or another blocker's line holds the subtitle.
    if (LineAlreadyShowing() || Announce(h))
    {
        bAnnouncePending = False;
    }
}

// True while an identical line is the one currently holding the subtitle slot.
function bool LineAlreadyShowing()
{
    return BlockMessage == class'APBookcaseBlocker'.default.LastAnnounceMessage
        && Level.TimeSeconds >= class'APBookcaseBlocker'.default.LastAnnounceTime
        && Level.TimeSeconds < class'APBookcaseBlocker'.default.LastAnnounceTime
            + ANNOUNCE_COOLDOWN;
}

// Prints BlockMessage on the subtitle line. Returns True only once it has
// actually shown, so a caller can tell "shown" from "held".
function bool Announce(harry h)
{
    local HPHud hud;
    local string deferReason;

    if (BlockMessage == "") return False;

    // The cooldown is stamped in Level.TimeSeconds, which restarts at 0 on
    // travel and on load. Time running backwards means a new level, so the
    // stale stamp goes.
    if (Level.TimeSeconds < class'APBookcaseBlocker'.default.LastAnnounceTime)
    {
        class'APBookcaseBlocker'.default.LastAnnounceTime = 0.0;
        class'APBookcaseBlocker'.default.LastAnnounceMessage = "";
    }
    // Any line, not just this one: a blocker that just spoke keeps the slot for
    // the cooldown so its line is readable before the next one lands.
    if (Level.TimeSeconds < class'APBookcaseBlocker'.default.LastAnnounceTime
            + ANNOUNCE_COOLDOWN)
    {
        return False;
    }

    // Same gate the grant queue uses: a full cutscene, the pause menu, vendor
    // dialogue and mid-air all hold the line, an ambient subtitle popup does not.
    if (!class'APGameInfo'.static.IsPlayerInPlayableState(h, deferReason))
    {
        return False;
    }

    hud = HPHud(h.myHUD);
    if (hud == None) return False;

    hud.SetSubtitleText(BlockMessage, (Len(BlockMessage) * 0.01) + 3.0);
    class'APBookcaseBlocker'.default.LastAnnounceTime = Level.TimeSeconds;
    class'APBookcaseBlocker'.default.LastAnnounceMessage = BlockMessage;
    return True;
}

event Bump(Actor Other)
{
    local harry h;

    Super.Bump(Other);

    h = harry(Level.PlayerHarryActor);
    if (h == None || Other != h) return;
    // Bump fires every frame Harry leans on the blocker; the cooldown inside
    // Announce is what holds that to one line.
    Announce(h);
}

defaultproperties
{
    ProximityRadius=500.00
}

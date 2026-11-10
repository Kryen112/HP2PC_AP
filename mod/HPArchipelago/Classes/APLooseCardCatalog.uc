// Where every freestanding wizard card sits in the stock maps. A level's saved
// state can drop a card marker, so each visit respawns any unchecked card whose
// marker and stock card are both gone. Level names are upper case.
class APLooseCardCatalog extends Object;

// The Index-th freestanding card of a level. False past the last one.
static function bool LooseCardAt(string LevelName, int Index, out int CardId, out Vector Loc, out Rotator Rot)
{
    if (LevelName == "ADV11BSECRETS")
    {
        if (Index == 0) { CardId = 91; Loc = vect(-3551.08, -1217.20, -2535.02); Rot = rot(0, 0, 0); return True; }
    }
    else if (LevelName == "ADV1WILLOW")
    {
        if (Index == 0) { CardId = 7; Loc = vect(769.08, -2817.93, -232.40); Rot = rot(0, 0, 0); return True; }
    }
    else if (LevelName == "ADV8FOREST")
    {
        if (Index == 0) { CardId = 57; Loc = vect(-3660.00, -5264.00, -652.00); Rot = rot(0, 0, 0); return True; }
    }
    else if (LevelName == "CH2SKURGE")
    {
        if (Index == 0) { CardId = 59; Loc = vect(-192.00, 2336.00, -1192.40); Rot = rot(0, 0, 0); return True; }
    }
    else if (LevelName == "CH6WIZARDCARD")
    {
        if (Index == 0) { CardId = 11; Loc = vect(541.09, -4224.91, 2133.60); Rot = rot(0, 16400, 0); return True; }
        if (Index == 1) { CardId = 15; Loc = vect(-4780.36, -4237.31, 2420.09); Rot = rot(0, -16080, 0); return True; }
        if (Index == 2) { CardId = 40; Loc = vect(-5256.00, -1824.00, 2136.00); Rot = rot(0, 0, 0); return True; }
        if (Index == 3) { CardId = 41; Loc = vect(635.60, -3002.76, 1707.60); Rot = rot(0, 0, 0); return True; }
        if (Index == 4) { CardId = 48; Loc = vect(-125.96, -5529.93, 2242.87); Rot = rot(0, 32176, 0); return True; }
        if (Index == 5) { CardId = 69; Loc = vect(2.12, -455.59, 813.60); Rot = rot(0, 0, 0); return True; }
        if (Index == 6) { CardId = 72; Loc = vect(-2934.92, -5505.27, 2223.99); Rot = rot(0, -16512, 0); return True; }
        if (Index == 7) { CardId = 74; Loc = vect(-2538.26, -4733.95, 2146.07); Rot = rot(0, -16032, 0); return True; }
        if (Index == 8) { CardId = 82; Loc = vect(-6263.57, -515.72, 2520.00); Rot = rot(0, 0, 0); return True; }
        if (Index == 9) { CardId = 100; Loc = vect(-6702.14, 2879.58, 3800.00); Rot = rot(0, 0, 0); return True; }
        if (Index == 10) { CardId = 101; Loc = vect(0.00, -1264.00, 1831.60); Rot = rot(0, 0, 0); return True; }
    }
    else if (LevelName == "GRANDSTAIRCASE_HUB")
    {
        if (Index == 0) { CardId = 79; Loc = vect(-3808.70, -6304.30, 2485.60); Rot = rot(0, 0, 0); return True; }
        if (Index == 1) { CardId = 89; Loc = vect(-773.46, -5451.96, 2172.00); Rot = rot(0, 0, 0); return True; }
    }
    else if (LevelName == "GROUNDS_HUB")
    {
        if (Index == 0) { CardId = 45; Loc = vect(640.70, -2640.46, 563.60); Rot = rot(0, 0, 0); return True; }
        if (Index == 1) { CardId = 61; Loc = vect(1823.93, 3695.70, -37.72); Rot = rot(0, 0, 0); return True; }
        if (Index == 2) { CardId = 64; Loc = vect(-848.87, -2240.50, 297.60); Rot = rot(0, 0, 0); return True; }
    }
    else if (LevelName == "GROUNDS_NIGHT")
    {
        if (Index == 0) { CardId = 45; Loc = vect(640.70, -2640.46, 563.60); Rot = rot(0, 0, 0); return True; }
        if (Index == 1) { CardId = 61; Loc = vect(1823.93, 3695.70, -37.72); Rot = rot(0, 0, 0); return True; }
        if (Index == 2) { CardId = 64; Loc = vect(-848.87, -2240.50, 297.60); Rot = rot(0, 0, 0); return True; }
    }
    return False;
}

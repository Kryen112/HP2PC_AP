class APContainerSpawner_BarkSpawn extends BarkSpawn;

const LOC_BASE = 5760000;
var int CheckLocationId;
var bool bAPTokenEjected;

// SpawnObject runs once per ejected goodie. With no Limits bump the
// native eject count is unchanged, so the first (and for a 1-goodie jar,
// only) call ejects the AP token THROUGH the parent goodie spawn --
// briefly pointing this slot at the baked marker class so it gets a
// goodie's arc/velocity/bounce/persist -- then returns. Every later call
// is suppressed, so the native goodie never spawns: the token replaces it.
function SpawnObject(int Index)
{
    local class<Actor> markerCls, saved;
    local int useIdx;

    if (!bAPTokenEjected)
    {
        bAPTokenEjected = True;
        if (CheckLocationId > 0)
        {
            markerCls = class<Actor>(DynamicLoadObject(
                "HPArchipelago.APContainerMarker_" $ string(CheckLocationId - LOC_BASE), class'Class'));
            if (markerCls != None)
            {
                useIdx = Index;
                if (useIdx < 0) { useIdx = 0; }
                saved = GoodieToSpawn[useIdx];
                GoodieToSpawn[useIdx] = markerCls;
                Super.SpawnObject(useIdx);
                GoodieToSpawn[useIdx] = saved;
                Log("[Archipelago] APContainerSpawner: ejected AP token (replace) for loc " $ string(CheckLocationId));
                return;
            }
        }
        // Token unavailable: drop the native goodie so the jar is never empty.
        Super.SpawnObject(Index);
        return;
    }
    // Replace mode: native goodie suppressed; only the AP token drops.
}

defaultproperties
{
    // Spawn at the exact saved transform on swap (no FindSpot nudge that
    // would float a tall box); runtime collision is unaffected.
    bCollideWhenPlacing=False
}

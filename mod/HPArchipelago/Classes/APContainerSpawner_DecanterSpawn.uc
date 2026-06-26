class APContainerSpawner_DecanterSpawn extends DecanterSpawn;

const LOC_BASE = 5760000;
var int CheckLocationId;
var bool bAPTokenEjected;

// SpawnObject runs once per ejected goodie. On the first call (the extra
// iteration the +1 Limits bump bought) eject the token THROUGH the parent
// goodie spawn -- temporarily point this slot at the baked marker class so
// Super.SpawnObject gives it the same arc/velocity/bounce/persist a bean
// gets -- then return (this slot was the token). Undo the Limits bump so a
// multi-life box's later hits eject the vanilla goodie count.
function SpawnObject(int Index)
{
    local class<Actor> markerCls, saved;
    local int useIdx;

    if (!bAPTokenEjected)
    {
        bAPTokenEjected = True;
        Limits.Min -= 1;
        Limits.Max -= 1;
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
                Log("[Archipelago] APContainerSpawner: ejected AP token for loc " $ string(CheckLocationId));
                return;
            }
        }
    }
    Super.SpawnObject(Index);
}

defaultproperties
{
    // Spawn at the exact saved transform on swap (no FindSpot nudge that
    // would float a tall box); runtime collision is unaffected.
    bCollideWhenPlacing=False
}

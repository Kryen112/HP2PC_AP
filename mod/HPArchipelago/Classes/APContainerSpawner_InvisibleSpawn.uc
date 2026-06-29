// Containersanity leaf for the invisible Flipendo spawners that sit inside the bean
// statues (Entry Hall / Skurge witch, Grand Staircase Gregory, Castle Exterior dragon)
// and the spider-spawning Dragon Skeleton. Same append-token logic as the other
// spawner leaves: the first SpawnObject ejects the AP marker through the parent goodie
// spawn (so it arcs out with bean velocity), then later hits eject the vanilla goodie
// (a bean, or a spider for the skeleton).
class APContainerSpawner_InvisibleSpawn extends InvisibleSpawn;

const LOC_BASE = 5760000;
var int CheckLocationId;
var bool bAPTokenEjected;

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
    bCollideWhenPlacing=False
    // These invisible spawners sit INSIDE their decoration statue's collision cylinder
    // (the statue is an HPawn with bBlockActors=True). A blocking actor spawned inside
    // another blocking actor fails the engine encroachment check -- Spawn returns None
    // even with bCollideWhenPlacing=False -- so the swap silently loses the spawner and
    // the statue ends up with no Flipendo target. bBlockActors=False (the same fix
    // Jellybean / APContainerMarker use) lets the swapped spawner spawn inside the
    // statue. The spell cursor traces against bCollideActors, which stays True, so it
    // remains Flipendo-targetable; bBlockPlayers was already False on InvisibleSpawn.
    bBlockActors=False
    bBlockPlayers=False
    bBlockCamera=False
}

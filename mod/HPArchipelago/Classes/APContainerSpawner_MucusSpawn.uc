// Auto-generated. Do not edit by hand; regenerate from
// data/locations.yaml (containers) via gen_apworld.py.
// Bring-up swap target for MucusSpawn containers: ejects the stamped AP
// token once from inside the goodie loop (so it pops with the beans),
// then behaves exactly like its parent.
class APContainerSpawner_MucusSpawn extends MucusSpawn;

var int CheckLocationId;
var bool bAPTokenEjected;

// Hook the goodie spawn, not HandleSpell*: SpawnObject runs after the
// open animation, once per ejected goodie, so the token appears with the
// beans (right timing + position) and on the FIRST hit no matter how many
// lives the box has.
function SpawnObject(int Index)
{
    Super.SpawnObject(Index);
    if (bAPTokenEjected) return;
    bAPTokenEjected = True;
    Log("[Archipelago] APContainerSpawner.SpawnObject: first goodie, CheckLocationId=" $ string(CheckLocationId));
    if (CheckLocationId > 0)
    {
        EjectAPToken();
    }
}

function EjectAPToken()
{
    local APContainerMarker m;
    local Vector dir, vel;
    local float angle;

    dir = StartPos >> Rotation;
    dir = dir + Location;
    m = Spawn(class'APContainerMarker', , , dir);
    if (m == None)
    {
        dir = Location;
        dir.Z += 24.0;
        m = Spawn(class'APContainerMarker', , , dir);
    }
    if (m == None)
    {
        Log("[Archipelago] APContainerSpawner.EjectAPToken: Spawn FAILED for loc " $ string(CheckLocationId));
        return;
    }
    m.CheckLocationId = CheckLocationId;
    angle = FRand() * 6.2831853;
    vel.X = 70.0 * Cos(angle);
    vel.Y = 70.0 * Sin(angle);
    vel.Z = 100.0 + FRand() * 80.0;
    m.Velocity = vel;
    m.SetPhysics(PHYS_Falling);
    m.ApplyAPAppearance();
    Log("[Archipelago] APContainerSpawner: ejected AP token for loc " $ string(CheckLocationId));
}

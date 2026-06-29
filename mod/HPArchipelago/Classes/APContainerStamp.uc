class APContainerStamp extends Object;

// Set CheckLocationId on a freshly-swapped container spawner. Returns
// False if the actor is not a known APContainerSpawner_<Leaf>.
static function bool Stamp(Actor a, int apId)
{
    if (APContainerSpawner_BarkSpawn(a) != None) { APContainerSpawner_BarkSpawn(a).CheckLocationId = apId; return True; }
    if (APContainerSpawner_CigarBoxSpawn(a) != None) { APContainerSpawner_CigarBoxSpawn(a).CheckLocationId = apId; return True; }
    if (APContainerSpawner_DecanterSpawn(a) != None) { APContainerSpawner_DecanterSpawn(a).CheckLocationId = apId; return True; }
    if (APContainerSpawner_GenericSpawner(a) != None) { APContainerSpawner_GenericSpawner(a).CheckLocationId = apId; return True; }
    if (APContainerSpawner_InvisibleSpawn(a) != None) { APContainerSpawner_InvisibleSpawn(a).CheckLocationId = apId; return True; }
    if (APContainerSpawner_JewelBoxSpawn(a) != None) { APContainerSpawner_JewelBoxSpawn(a).CheckLocationId = apId; return True; }
    if (APContainerSpawner_Knightspawn(a) != None) { APContainerSpawner_Knightspawn(a).CheckLocationId = apId; return True; }
    if (APContainerSpawner_MucusSpawn(a) != None) { APContainerSpawner_MucusSpawn(a).CheckLocationId = apId; return True; }
    if (APContainerSpawner_MusicBoxSpawn(a) != None) { APContainerSpawner_MusicBoxSpawn(a).CheckLocationId = apId; return True; }
    if (APContainerSpawner_OilCanSpawn(a) != None) { APContainerSpawner_OilCanSpawn(a).CheckLocationId = apId; return True; }
    if (APContainerSpawner_PlantPotSpawn(a) != None) { APContainerSpawner_PlantPotSpawn(a).CheckLocationId = apId; return True; }
    return False;
}

// True if the spawner's native goodie is REPLACED by the AP token
// (single-content jars: the token drops instead of the bark/mucus).
static function bool IsReplaceLeaf(Actor a)
{
    if (APContainerSpawner_BarkSpawn(a) != None) return True;
    if (APContainerSpawner_MucusSpawn(a) != None) return True;
    return False;
}

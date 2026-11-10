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

// The AP location id stamped on a swapped container spawner, or 0.
static function int ApIdOf(Actor a)
{
    if (APContainerSpawner_BarkSpawn(a) != None) return APContainerSpawner_BarkSpawn(a).CheckLocationId;
    if (APContainerSpawner_CigarBoxSpawn(a) != None) return APContainerSpawner_CigarBoxSpawn(a).CheckLocationId;
    if (APContainerSpawner_DecanterSpawn(a) != None) return APContainerSpawner_DecanterSpawn(a).CheckLocationId;
    if (APContainerSpawner_GenericSpawner(a) != None) return APContainerSpawner_GenericSpawner(a).CheckLocationId;
    if (APContainerSpawner_InvisibleSpawn(a) != None) return APContainerSpawner_InvisibleSpawn(a).CheckLocationId;
    if (APContainerSpawner_JewelBoxSpawn(a) != None) return APContainerSpawner_JewelBoxSpawn(a).CheckLocationId;
    if (APContainerSpawner_Knightspawn(a) != None) return APContainerSpawner_Knightspawn(a).CheckLocationId;
    if (APContainerSpawner_MucusSpawn(a) != None) return APContainerSpawner_MucusSpawn(a).CheckLocationId;
    if (APContainerSpawner_MusicBoxSpawn(a) != None) return APContainerSpawner_MusicBoxSpawn(a).CheckLocationId;
    if (APContainerSpawner_OilCanSpawn(a) != None) return APContainerSpawner_OilCanSpawn(a).CheckLocationId;
    if (APContainerSpawner_PlantPotSpawn(a) != None) return APContainerSpawner_PlantPotSpawn(a).CheckLocationId;
    return 0;
}

// True once the swapped spawner has ejected its AP token.
static function bool TokenEjected(Actor a)
{
    if (APContainerSpawner_BarkSpawn(a) != None) return APContainerSpawner_BarkSpawn(a).bAPTokenEjected;
    if (APContainerSpawner_CigarBoxSpawn(a) != None) return APContainerSpawner_CigarBoxSpawn(a).bAPTokenEjected;
    if (APContainerSpawner_DecanterSpawn(a) != None) return APContainerSpawner_DecanterSpawn(a).bAPTokenEjected;
    if (APContainerSpawner_GenericSpawner(a) != None) return APContainerSpawner_GenericSpawner(a).bAPTokenEjected;
    if (APContainerSpawner_InvisibleSpawn(a) != None) return APContainerSpawner_InvisibleSpawn(a).bAPTokenEjected;
    if (APContainerSpawner_JewelBoxSpawn(a) != None) return APContainerSpawner_JewelBoxSpawn(a).bAPTokenEjected;
    if (APContainerSpawner_Knightspawn(a) != None) return APContainerSpawner_Knightspawn(a).bAPTokenEjected;
    if (APContainerSpawner_MucusSpawn(a) != None) return APContainerSpawner_MucusSpawn(a).bAPTokenEjected;
    if (APContainerSpawner_MusicBoxSpawn(a) != None) return APContainerSpawner_MusicBoxSpawn(a).bAPTokenEjected;
    if (APContainerSpawner_OilCanSpawn(a) != None) return APContainerSpawner_OilCanSpawn(a).bAPTokenEjected;
    if (APContainerSpawner_PlantPotSpawn(a) != None) return APContainerSpawner_PlantPotSpawn(a).bAPTokenEjected;
    return False;
}

// Mark whether the swapped spawner has ejected its AP token.
static function SetTokenEjected(Actor a, bool b)
{
    if (APContainerSpawner_BarkSpawn(a) != None) { APContainerSpawner_BarkSpawn(a).bAPTokenEjected = b; return; }
    if (APContainerSpawner_CigarBoxSpawn(a) != None) { APContainerSpawner_CigarBoxSpawn(a).bAPTokenEjected = b; return; }
    if (APContainerSpawner_DecanterSpawn(a) != None) { APContainerSpawner_DecanterSpawn(a).bAPTokenEjected = b; return; }
    if (APContainerSpawner_GenericSpawner(a) != None) { APContainerSpawner_GenericSpawner(a).bAPTokenEjected = b; return; }
    if (APContainerSpawner_InvisibleSpawn(a) != None) { APContainerSpawner_InvisibleSpawn(a).bAPTokenEjected = b; return; }
    if (APContainerSpawner_JewelBoxSpawn(a) != None) { APContainerSpawner_JewelBoxSpawn(a).bAPTokenEjected = b; return; }
    if (APContainerSpawner_Knightspawn(a) != None) { APContainerSpawner_Knightspawn(a).bAPTokenEjected = b; return; }
    if (APContainerSpawner_MucusSpawn(a) != None) { APContainerSpawner_MucusSpawn(a).bAPTokenEjected = b; return; }
    if (APContainerSpawner_MusicBoxSpawn(a) != None) { APContainerSpawner_MusicBoxSpawn(a).bAPTokenEjected = b; return; }
    if (APContainerSpawner_OilCanSpawn(a) != None) { APContainerSpawner_OilCanSpawn(a).bAPTokenEjected = b; return; }
    if (APContainerSpawner_PlantPotSpawn(a) != None) { APContainerSpawner_PlantPotSpawn(a).bAPTokenEjected = b; return; }
}

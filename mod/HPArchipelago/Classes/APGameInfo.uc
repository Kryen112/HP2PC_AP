class APGameInfo extends GameInfo;

event InitGame(string Options, out string Error)
{
    local class<Mutator> mutClass;

    Super.InitGame(Options, Error);
    Log("[Archipelago] APGameInfo.InitGame - subclass active");

    mutClass = class<Mutator>(DynamicLoadObject("HPArchipelago.HelloMutator", class'Class'));
    if (mutClass != None)
    {
        Log("[Archipelago] APGameInfo: HelloMutator class loaded, spawning");
        Spawn(mutClass);
    }
    else
    {
        Log("[Archipelago] APGameInfo: HelloMutator class load FAILED");
    }
}

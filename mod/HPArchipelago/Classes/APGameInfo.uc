class APGameInfo extends GameInfo;

event InitGame(string Options, out string Error)
{
    local class<Actor> ipcClass;

    Super.InitGame(Options, Error);
    Log("[Archipelago] APGameInfo.InitGame - subclass active");

    ipcClass = class<Actor>(DynamicLoadObject("HPArchipelago.APIPCActor", class'Class'));
    if (ipcClass != None)
    {
        Log("[Archipelago] APGameInfo: APIPCActor class loaded, spawning");
        Spawn(ipcClass);
    }
    else
    {
        Log("[Archipelago] APGameInfo: APIPCActor class load FAILED");
    }
}

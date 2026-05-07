class APIPCActor extends IpDrv.TcpLink;

event PreBeginPlay()
{
    local IpAddr Addr;

    Super.PreBeginPlay();
    Log("[Archipelago] APIPCActor.PreBeginPlay - connecting to 127.0.0.1:38281");
    BindPort();

    if (!StringToIpAddr("127.0.0.1", Addr))
    {
        Log("[Archipelago] APIPCActor: StringToIpAddr failed");
        return;
    }
    Addr.Port = 38281;
    if (!Open(Addr))
    {
        Log("[Archipelago] APIPCActor: Open() returned false");
    }
}

event Opened()
{
    Log("[Archipelago] APIPCActor: Opened - sending hello");
    SendText("{\"type\":\"hello\"}" $ Chr(10));
}

event ReceivedText(string Text)
{
    Log("[Archipelago] APIPCActor: ReceivedText: " $ Text);
}

event Closed()
{
    Log("[Archipelago] APIPCActor: Closed");
}

defaultproperties
{
    LinkMode=MODE_Text
    ReceiveMode=RMODE_Event
}

// Stateless trap helpers: the pure input/wand utilities the trap subsystem uses,
// kept apart from the stateful trap ledger (the bXxxTrapActive flags, expiry
// timers and TrapLastLevelName, which live with the activators and TrapTick).
// Each function acts only on the pawn or wand it is handed; the strafe pair's
// only persistence is the self-identifying raw-axis key binding in User.ini.
class APTrapKit extends Object;

// Swap the held wand's retail LumosLight for an APLumosLight, which re-places the
// Lumos light (and the spell-charge glow) at the giant wand's tip via its
// UpdateLocation override. Idempotent: a re-activation that already swapped is a
// no-op. The old light is left orphaned and inert (turned off first if it was lit)
// rather than destroyed, since retail LumosLight.Destroyed emits player-visible
// debug text; the orphan dies at level unload. APLumosLight gates its rescale on
// bWandSizeTrapActive, so the trap's level-change revert needs no swap-back.
static function SwapInWandTipLumosLight(baseWand wand)
{
    local APLumosLight apLight;
    local LumosLight old;
    local bool wasOn, wasInfinite;

    if (wand == None)
    {
        return;
    }
    old = wand.TheLumosLight;
    if (old != None && old.IsA('APLumosLight'))
    {
        return;
    }
    if (old != None)
    {
        wasOn       = old.bLumosOn;
        wasInfinite = old.bInfiniteLumos;
        old.bUseDebugMode = False;
        if (wasOn)
        {
            // Stop the orphan's dynamic light + particles before it goes inert.
            old.TurnOff();
        }
    }
    apLight = wand.Spawn(class'APLumosLight', wand, , wand.Location);
    if (apLight == None)
    {
        // Spawn failed: keep the retail light, restoring its lit state if any.
        if (old != None && wasOn)
        {
            old.bInfiniteLumos = wasInfinite;
            old.TurnOn();
        }
        Log("[Archipelago] APTrapKit.SwapInWandTipLumosLight: APLumosLight spawn failed - kept retail light");
        return;
    }
    wand.TheLumosLight = apLight;
    if (wasOn)
    {
        apLight.bInfiniteLumos = wasInfinite;
        apLight.TurnOn();
    }
}

// Invert strafe by rebinding the strafe keys. The Levicorpus 180 roll flips the
// pawn's right-axis, and the native harry.PlayerMove strafes along
// GetAxes(Rotation).Y, so strafe drives the wrong way while flipped. The watcher
// Tick runs after PlayerMove each frame, too late to flip aStrafe before it is
// read, so the correction lives one layer earlier in the input bindings. Strafe
// here is keyboard-only (no analog/gamepad binding feeds aStrafe).
//
// Each key bound to the StrafeLeft alias is rebound to the raw StrafeRight axis
// command and vice versa, so the net motion matches the upright direction. The
// raw `Axis aStrafe` command (the same form the default config uses for MouseX
// etc.) is a self-identifying marker: the player config only binds strafe to the
// alias names, so a key carrying a raw aStrafe command can only be this swap.
// RestoreStrafeKeys keys off that to revert it - including across a reboot, since
// the binding persists in User.ini and reverting needs no separate state. Only
// acts on alias-bound keys, so it is a no-op once the keys are already swapped.
static function SwapStrafeKeys(harry h)
{
    local int i;
    local string keyName, binding;

    if (h == None)
    {
        return;
    }
    for (i = 0; i < 255; i++)
    {
        keyName = h.ConsoleCommand("KEYNAME " $ string(i));
        if (keyName == "")
        {
            continue;
        }
        binding = h.ConsoleCommand("KEYBINDING " $ keyName);
        if (Caps(binding) == "STRAFELEFT")
        {
            h.ConsoleCommand("SET Input " $ keyName $ " Axis aStrafe Speed=+300.0");
        }
        else if (Caps(binding) == "STRAFERIGHT")
        {
            h.ConsoleCommand("SET Input " $ keyName $ " Axis aStrafe Speed=-300.0");
        }
    }
    h.SaveConfig();
    Log("[Archipelago] APTrapKit.SwapStrafeKeys: strafe keys rebound to inverted raw axis commands");
}

// Revert the strafe keys SwapStrafeKeys rebound. A swapped key carries a raw
// `Axis aStrafe` command (which the normal config never uses), so it is
// self-identifying: the negative one was the original StrafeRight, the positive
// the original StrafeLeft. Keys off the `-` sign, which the negative axis command
// always carries and the positive one never does, so it is robust to the engine
// trimming a leading `+`. No-op when no key carries a raw aStrafe command, so it
// is safe to call unconditionally (level change, first-bind heal).
static function RestoreStrafeKeys(harry h)
{
    local int i;
    local string keyName, binding;
    local bool bAny;

    if (h == None)
    {
        return;
    }
    for (i = 0; i < 255; i++)
    {
        keyName = h.ConsoleCommand("KEYNAME " $ string(i));
        if (keyName == "")
        {
            continue;
        }
        binding = h.ConsoleCommand("KEYBINDING " $ keyName);
        if (InStr(Caps(binding), "ASTRAFE") == -1)
        {
            continue;
        }
        bAny = True;
        if (InStr(binding, "-") != -1)
        {
            h.ConsoleCommand("SET Input " $ keyName $ " StrafeRight");
        }
        else
        {
            h.ConsoleCommand("SET Input " $ keyName $ " StrafeLeft");
        }
    }
    if (bAny)
    {
        h.SaveConfig();
        Log("[Archipelago] APTrapKit.RestoreStrafeKeys: strafe keys reverted to the StrafeLeft/StrafeRight aliases");
    }
}

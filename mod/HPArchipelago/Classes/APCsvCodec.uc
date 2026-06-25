// Stateless CSV-field tokenisers shared by the IPC config parsers (GOALCFG,
// TRADECFG, APPEARANCE, bean-room resync). UE1 UScript has no string split and
// forbids fixed-size locals, so each parser pops one leading integer field at a
// time off an `out string rest` cursor until it is empty.
class APCsvCodec extends Object;

// Pop the leading comma-delimited integer off `rest` (consumes it, including
// the comma). Last field has no trailing comma, so take the whole remainder.
static function int NextCsvInt(out string rest)
{
    local int comma, val;
    comma = InStr(rest, ",");
    if (comma >= 0)
    {
        val = int(Left(rest, comma));
        rest = Mid(rest, comma + 1);
    }
    else
    {
        val = int(rest);
        rest = "";
    }
    return val;
}

// Like NextCsvInt but the field separator is a parameter, so the APPEARANCE
// payload's `apId:code,apId:code` form parses with one primitive (`:` then
// `,`). Last field has no trailing separator, so take the whole remainder.
static function int NextCsvIntUpTo(out string rest, string sep)
{
    local int p, val;
    p = InStr(rest, sep);
    if (p >= 0)
    {
        val = int(Left(rest, p));
        rest = Mid(rest, p + 1);
    }
    else
    {
        val = int(rest);
        rest = "";
    }
    return val;
}

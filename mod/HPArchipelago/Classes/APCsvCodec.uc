// Stateless field tokenisers shared by the IPC config parsers (GOALCFG,
// TRADECFG, APPEARANCE, bean-room resync) and the Chr(30)-joined toast segment
// records. UE1 UScript has no string split, so each parser pops one leading
// field at a time (as a string or an int) off an `out string rest` cursor until
// it is empty. All four helpers build on NextTokenUpTo.
class APCsvCodec extends Object;

// Pop the leading comma-delimited integer off `rest` (consumes it, including
// the comma): the same token NextCsvToken pops, read as an int.
static function int NextCsvInt(out string rest)
{
    return int(NextCsvToken(rest));
}

// Like NextCsvInt but the field separator is a parameter, so the APPEARANCE
// payload's `apId:code,apId:code` form parses with one primitive (`:` then `,`):
// the sep-delimited token, read as an int.
static function int NextCsvIntUpTo(out string rest, string sep)
{
    return int(NextTokenUpTo(rest, sep));
}

// Pop the leading field delimited by `sep` off `rest` (consumes it, including
// the separator). Last field has no trailing separator, so take the whole
// remainder. Returns "" for an empty field; callers skip those. Used for the
// comma-CSV resync lists and the Chr(30)-joined toast segment records.
static function string NextTokenUpTo(out string rest, string sep)
{
    local int p;
    local string val;
    p = InStr(rest, sep);
    if (p >= 0)
    {
        val = Left(rest, p);
        rest = Mid(rest, p + 1);
    }
    else
    {
        val = rest;
        rest = "";
    }
    return val;
}

// Pop the leading comma-delimited string field: NextTokenUpTo with a comma.
static function string NextCsvToken(out string rest)
{
    return NextTokenUpTo(rest, ",");
}

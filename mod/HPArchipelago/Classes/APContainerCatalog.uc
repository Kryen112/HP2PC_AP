// Where every swapped container (the GenericSpawner family) sits in the stock
// maps, keyed by its AP location id. A potion jar is used up once opened and is
// gone on the next visit, so an unchecked location whose box is gone gets its
// token here.
// Level names are upper case.
class APContainerCatalog extends Object;

// The Index-th swapped container of a level. False past the last one.
static function bool SpawnerAt(string LevelName, int Index, out int ApId, out Vector Loc, out Rotator Rot)
{
    if (LevelName == "ADV11ACORRIDOR")
    {
        if (Index == 0) { ApId = 5761024; Loc = vect(-184.00, -2404.00, -1836.00); Rot = rot(0, 0, 0); return True; }
        if (Index == 1) { ApId = 5761031; Loc = vect(-194.00, -2212.00, -1836.00); Rot = rot(0, 0, 0); return True; }
    }
    else if (LevelName == "ADV11BSECRETS")
    {
        if (Index == 0) { ApId = 5761039; Loc = vect(-2283.44, -1552.39, -1772.60); Rot = rot(0, -9472, 0); return True; }
        if (Index == 1) { ApId = 5761040; Loc = vect(528.00, -712.00, -6540.00); Rot = rot(0, -37808, 0); return True; }
        if (Index == 2) { ApId = 5761042; Loc = vect(-2071.23, -1552.00, -1772.60); Rot = rot(0, -17840, 0); return True; }
        if (Index == 3) { ApId = 5761043; Loc = vect(544.00, -688.00, -6540.00); Rot = rot(0, 21360, 0); return True; }
    }
    else if (LevelName == "ADV1WILLOW")
    {
        if (Index == 0) { ApId = 5761052; Loc = vect(544.39, -2687.26, -161.45); Rot = rot(0, 88, 0); return True; }
        if (Index == 1) { ApId = 5761053; Loc = vect(994.30, -2945.67, -162.21); Rot = rot(0, 32776, 0); return True; }
    }
    else if (LevelName == "ADV3DUNGEONQUEST")
    {
        if (Index == 0) { ApId = 5761054; Loc = vect(-704.06, -3013.04, -492.60); Rot = rot(0, 22284, 0); return True; }
        if (Index == 1) { ApId = 5761055; Loc = vect(-2822.65, -2213.92, -2028.60); Rot = rot(0, -16156, 0); return True; }
        if (Index == 2) { ApId = 5761065; Loc = vect(-6310.01, -3821.48, -1040.23); Rot = rot(0, -16196, 0); return True; }
        if (Index == 3) { ApId = 5761066; Loc = vect(-2539.58, -2885.10, -1959.44); Rot = rot(0, 16180, 0); return True; }
    }
    else if (LevelName == "ADV4GREENHOUSE")
    {
        if (Index == 0) { ApId = 5761074; Loc = vect(848.12, 144.17, -108.60); Rot = rot(0, 16384, 0); return True; }
        if (Index == 1) { ApId = 5761075; Loc = vect(766.49, 257.53, -105.33); Rot = rot(0, 6896, 0); return True; }
        if (Index == 2) { ApId = 5761076; Loc = vect(1105.08, 832.66, -106.50); Rot = rot(0, -10256, 0); return True; }
        if (Index == 3) { ApId = 5761077; Loc = vect(929.72, 257.49, -105.43); Rot = rot(0, 21216, 0); return True; }
        if (Index == 4) { ApId = 5761078; Loc = vect(704.79, 750.10, -70.70); Rot = rot(0, -14960, 0); return True; }
        if (Index == 5) { ApId = 5761079; Loc = vect(48.00, 640.00, -112.00); Rot = rot(0, -7616, 0); return True; }
        if (Index == 6) { ApId = 5761080; Loc = vect(1728.42, -62.58, 144.00); Rot = rot(0, 24880, 0); return True; }
        if (Index == 7) { ApId = 5761081; Loc = vect(1584.00, -2637.09, -368.00); Rot = rot(0, 8144, 0); return True; }
        if (Index == 8) { ApId = 5761082; Loc = vect(-80.00, 770.55, -112.00); Rot = rot(0, -29312, 0); return True; }
        if (Index == 9) { ApId = 5761083; Loc = vect(-80.74, 704.20, -112.00); Rot = rot(0, -28432, 0); return True; }
    }
    else if (LevelName == "ADV6GOYLE")
    {
        if (Index == 0) { ApId = 5761095; Loc = vect(2090.51, 610.71, 992.00); Rot = rot(0, 38064, 0); return True; }
    }
    else if (LevelName == "ADV7SLYTHCOMROOM")
    {
        if (Index == 0) { ApId = 5761100; Loc = vect(-1388.41, -11329.67, -384.60); Rot = rot(0, 27680, 0); return True; }
        if (Index == 1) { ApId = 5761104; Loc = vect(795.18, -2258.01, -32.00); Rot = rot(0, 16544, 0); return True; }
        if (Index == 2) { ApId = 5761105; Loc = vect(803.74, -1708.62, -32.00); Rot = rot(0, -16208, 0); return True; }
        if (Index == 3) { ApId = 5761106; Loc = vect(-114.95, -9280.00, -272.00); Rot = rot(0, 16496, 0); return True; }
        if (Index == 4) { ApId = 5761107; Loc = vect(-110.23, -8701.53, -272.00); Rot = rot(0, 49328, 0); return True; }
        if (Index == 5) { ApId = 5761108; Loc = vect(-1168.00, -6432.00, -576.00); Rot = rot(0, 0, 0); return True; }
        if (Index == 6) { ApId = 5761109; Loc = vect(1074.51, -5123.52, -128.00); Rot = rot(0, 32648, 0); return True; }
        if (Index == 7) { ApId = 5761110; Loc = vect(528.00, -5113.69, -128.00); Rot = rot(0, 0, 0); return True; }
        if (Index == 8) { ApId = 5761111; Loc = vect(-1142.07, -10904.75, -392.60); Rot = rot(0, 53232, 0); return True; }
    }
    else if (LevelName == "ADV8FOREST")
    {
        if (Index == 0) { ApId = 5761117; Loc = vect(1442.09, -5213.43, -1138.00); Rot = rot(0, -17896, 0); return True; }
        if (Index == 1) { ApId = 5761118; Loc = vect(1808.00, -3104.00, -2572.60); Rot = rot(0, -11760, 0); return True; }
        if (Index == 2) { ApId = 5761119; Loc = vect(1744.00, -3168.00, -2572.60); Rot = rot(0, -8784, 0); return True; }
    }
    else if (LevelName == "BEANREWARDROOM")
    {
        if (Index == 0) { ApId = 5761126; Loc = vect(-981.19, 769.15, -618.00); Rot = rot(0, 0, 0); return True; }
    }
    else if (LevelName == "CH2SKURGE")
    {
        if (Index == 0) { ApId = 5761138; Loc = vect(-576.00, -736.00, -124.60); Rot = rot(0, 16320, 0); return True; }
        if (Index == 1) { ApId = 5761143; Loc = vect(689.77, 2193.18, -940.60); Rot = rot(0, 32784, 0); return True; }
        if (Index == 2) { ApId = 5761144; Loc = vect(-860.72, -1730.69, 270.56); Rot = rot(0, -7808, 0); return True; }
        if (Index == 3) { ApId = 5761145; Loc = vect(-1064.06, 1082.96, -176.10); Rot = rot(0, 8544, 0); return True; }
        if (Index == 4) { ApId = 5761146; Loc = vect(1508.29, 2147.77, -504.15); Rot = rot(0, 32744, 0); return True; }
        if (Index == 5) { ApId = 5761147; Loc = vect(-233.86, 1160.53, 846.23); Rot = rot(0, 0, 0); return True; }
        if (Index == 6) { ApId = 5761148; Loc = vect(230.04, 1395.25, 846.23); Rot = rot(0, -32864, 0); return True; }
        if (Index == 7) { ApId = 5761149; Loc = vect(894.88, 1759.95, -236.60); Rot = rot(0, 32784, 0); return True; }
        if (Index == 8) { ApId = 5761150; Loc = vect(-1050.45, 1384.19, -186.89); Rot = rot(0, 0, 0); return True; }
        if (Index == 9) { ApId = 5761299; Loc = vect(-318.82, -1454.52, 304.00); Rot = rot(0, 16624, 0); return True; }
    }
    else if (LevelName == "CH3DIFFINDO")
    {
        if (Index == 0) { ApId = 5761170; Loc = vect(3098.36, -864.45, -120.11); Rot = rot(0, 32800, 0); return True; }
        if (Index == 1) { ApId = 5761171; Loc = vect(2369.50, -1726.76, -49.63); Rot = rot(0, 32736, 0); return True; }
        if (Index == 2) { ApId = 5761172; Loc = vect(832.53, -1727.45, -49.63); Rot = rot(0, 65560, 0); return True; }
        if (Index == 3) { ApId = 5761173; Loc = vect(2407.29, -823.54, -123.62); Rot = rot(0, 0, 0); return True; }
        if (Index == 4) { ApId = 5761174; Loc = vect(-3680.80, -1823.58, 19.40); Rot = rot(0, 16368, 0); return True; }
        if (Index == 5) { ApId = 5761175; Loc = vect(336.00, 1568.00, -108.60); Rot = rot(0, 36536, 0); return True; }
        if (Index == 6) { ApId = 5761176; Loc = vect(-2717.33, 1053.24, 332.39); Rot = rot(0, 0, 0); return True; }
        if (Index == 7) { ApId = 5761177; Loc = vect(1024.00, -1600.00, -106.50); Rot = rot(0, -16384, 0); return True; }
        if (Index == 8) { ApId = 5761178; Loc = vect(-2674.33, 861.83, 21.50); Rot = rot(0, -20496, 0); return True; }
        if (Index == 9) { ApId = 5761179; Loc = vect(-1843.02, 15.31, 149.50); Rot = rot(0, -25256, 0); return True; }
        if (Index == 10) { ApId = 5761180; Loc = vect(-288.00, -352.00, -378.50); Rot = rot(0, 11776, 0); return True; }
        if (Index == 11) { ApId = 5761181; Loc = vect(2276.68, -1521.02, -53.94); Rot = rot(0, 32776, 0); return True; }
        if (Index == 12) { ApId = 5761182; Loc = vect(-781.47, -1305.25, -54.38); Rot = rot(0, -16416, 0); return True; }
        if (Index == 13) { ApId = 5761183; Loc = vect(-2571.15, 1444.48, 330.78); Rot = rot(0, -16400, 0); return True; }
        if (Index == 14) { ApId = 5761184; Loc = vect(-2610.81, 846.51, 16.00); Rot = rot(0, -23216, 0); return True; }
        if (Index == 15) { ApId = 5761185; Loc = vect(-1275.67, -279.10, -21.99); Rot = rot(0, -7072, 0); return True; }
        if (Index == 16) { ApId = 5761186; Loc = vect(-768.00, -112.00, -80.00); Rot = rot(0, 9808, 0); return True; }
        if (Index == 17) { ApId = 5761187; Loc = vect(-304.79, 771.70, -21.46); Rot = rot(0, -21968, 0); return True; }
        if (Index == 18) { ApId = 5761188; Loc = vect(304.86, 770.75, -21.64); Rot = rot(0, -11520, 0); return True; }
        if (Index == 19) { ApId = 5761189; Loc = vect(-224.00, -352.00, -384.00); Rot = rot(0, 16368, 0); return True; }
        if (Index == 20) { ApId = 5761190; Loc = vect(636.39, 946.56, -309.61); Rot = rot(0, 23472, 0); return True; }
        if (Index == 21) { ApId = 5761191; Loc = vect(-3099.81, 1445.84, 330.38); Rot = rot(0, -16320, 0); return True; }
    }
    else if (LevelName == "CH4SPONGIFY")
    {
        if (Index == 0) { ApId = 5761199; Loc = vect(352.00, 1921.15, 1043.40); Rot = rot(0, -32760, 0); return True; }
        if (Index == 1) { ApId = 5761200; Loc = vect(-1600.00, -2464.00, 1043.40); Rot = rot(0, 16432, 0); return True; }
        if (Index == 2) { ApId = 5761201; Loc = vect(-735.32, 96.58, 1555.40); Rot = rot(0, -7584, 0); return True; }
        if (Index == 3) { ApId = 5761211; Loc = vect(-352.66, 1151.73, 323.86); Rot = rot(0, 0, 0); return True; }
        if (Index == 4) { ApId = 5761212; Loc = vect(1312.84, 1376.05, 1047.60); Rot = rot(0, 32808, 0); return True; }
        if (Index == 5) { ApId = 5761213; Loc = vect(1120.00, 1376.00, 1047.60); Rot = rot(0, 0, 0); return True; }
        if (Index == 6) { ApId = 5761214; Loc = vect(-2496.40, -1648.14, 915.40); Rot = rot(0, -16384, 0); return True; }
        if (Index == 7) { ApId = 5761215; Loc = vect(-352.00, 1921.15, 1043.40); Rot = rot(0, 0, 0); return True; }
        if (Index == 8) { ApId = 5761216; Loc = vect(-734.15, -99.00, 1555.40); Rot = rot(0, 8064, 0); return True; }
        if (Index == 9) { ApId = 5761217; Loc = vect(654.64, -497.65, 841.29); Rot = rot(0, -24736, 0); return True; }
    }
    else if (LevelName == "ENTRYHALL_HUB")
    {
        if (Index == 0) { ApId = 5761249; Loc = vect(-5083.51, 113.83, -441.90); Rot = rot(0, -13688, 0); return True; }
        if (Index == 1) { ApId = 5761257; Loc = vect(-4463.91, 157.86, -485.13); Rot = rot(0, -16400, 0); return True; }
        if (Index == 2) { ApId = 5761258; Loc = vect(-920.16, -1988.31, 30.89); Rot = rot(0, 16400, 0); return True; }
        if (Index == 3) { ApId = 5761259; Loc = vect(-494.77, -1987.84, 30.89); Rot = rot(0, 16400, 0); return True; }
        if (Index == 4) { ApId = 5761260; Loc = vect(-4031.87, -1862.85, -417.25); Rot = rot(0, 16400, 0); return True; }
        if (Index == 5) { ApId = 5761261; Loc = vect(-4031.99, -1333.29, -417.25); Rot = rot(0, 49248, 0); return True; }
        if (Index == 6) { ApId = 5761262; Loc = vect(-4961.80, 142.16, -441.90); Rot = rot(0, -52808, 0); return True; }
        if (Index == 7) { ApId = 5761300; Loc = vect(-1825.17, -2962.60, 154.10); Rot = rot(0, 16400, 0); return True; }
    }
    else if (LevelName == "GRANDSTAIRCASE_HUB")
    {
        if (Index == 0) { ApId = 5761271; Loc = vect(-4638.45, -6304.00, 2227.80); Rot = rot(0, 0, 0); return True; }
        if (Index == 1) { ApId = 5761272; Loc = vect(-156.08, -7620.86, 1224.33); Rot = rot(0, 32784, 0); return True; }
        if (Index == 2) { ApId = 5761273; Loc = vect(-358.52, -6321.80, 1219.46); Rot = rot(0, 32696, 0); return True; }
        if (Index == 3) { ApId = 5761274; Loc = vect(-2106.66, -8342.69, 1623.60); Rot = rot(0, 13664, 0); return True; }
        if (Index == 4) { ApId = 5761275; Loc = vect(-3414.18, -5876.93, 1943.60); Rot = rot(0, -16368, 0); return True; }
        if (Index == 5) { ApId = 5761276; Loc = vect(-1272.06, -8223.32, 1547.60); Rot = rot(0, 28160, 0); return True; }
        if (Index == 6) { ApId = 5761277; Loc = vect(-664.27, -6327.90, 1223.96); Rot = rot(0, 0, 0); return True; }
        if (Index == 7) { ApId = 5761278; Loc = vect(-1154.35, -7269.44, 1623.60); Rot = rot(0, 35248, 0); return True; }
        if (Index == 8) { ApId = 5761279; Loc = vect(-1997.77, -7424.00, 1536.00); Rot = rot(0, 0, 0); return True; }
        if (Index == 9) { ApId = 5761280; Loc = vect(1114.13, -7376.51, 1218.32); Rot = rot(0, 32752, 0); return True; }
        if (Index == 10) { ApId = 5761301; Loc = vect(781.25, -5312.00, 1749.75); Rot = rot(0, 32792, 0); return True; }
        if (Index == 11) { ApId = 5761302; Loc = vect(-1639.64, -7807.14, 1754.45); Rot = rot(-17840, 16368, 0); return True; }
        if (Index == 12) { ApId = 5761306; Loc = vect(451.38, -7959.22, 1196.00); Rot = rot(0, -16592, 0); return True; }
    }
    else if (LevelName == "GROUNDS_HUB")
    {
        if (Index == 0) { ApId = 5761303; Loc = vect(2.84, -131.57, 194.00); Rot = rot(0, -16336, 0); return True; }
    }
    else if (LevelName == "GROUNDS_NIGHT")
    {
        if (Index == 0) { ApId = 5761303; Loc = vect(-1.05, -96.24, 186.00); Rot = rot(0, -16336, 0); return True; }
    }
    return False;
}

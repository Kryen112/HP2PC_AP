// Stateless marker-appearance draw math: given an appearance code, morph any
// Actor to the vanilla art of the item its location holds (mesh, skin, scale,
// draw style). All asset objects resolve by name via DynamicLoadObject so there
// is no hard package link and a not-yet-loaded asset degrades to "native". The
// code-to-Actor stamp is pure; the appearance TABLE (which code each location
// carries) lives on APMorphRegistry via AppearanceForApId.
class APAppearanceMath extends Object;

// Lazy-loaded AP logo texture used by the Tradersanity icon-swap pass to replace
// the trade UI's wiggentree-bark / flobberworm-mucous / card icon on Tradersanity
// vendors with an "Archipelago Item" plate before purchase. Class default so the
// load survives level travel.
var Texture CachedAPItemTexture;

// Vanilla in-world DrawScale read from a pickup class default at runtime
// (each vanilla prop tunes its own; hardcoding one value mis-sized them).
// Same proven `.default` reflection as cardCls.default.Skin
// (APGameInfo.uc:1448). `fallback` if the class can't resolve (async-safe).
static function float VanillaDrawScale(string clsName, float fallback)
{
    local class<Actor> ac;
    ac = class<Actor>(DynamicLoadObject("HGame." $ clsName, class'Class'));
    if (ac == None) return fallback;
    return ac.default.DrawScale;
}

// AP defines four bean-pile sizes but vanilla has ONE jar mesh/class
// (JarBeans). Anchor on JarBeans' real DrawScale (`base`, read at runtime via
// VanillaDrawScale) and spread the four AP sizes around it so they stay
// proportional to the vanilla jar. Multipliers are the cosmetic dial-in the
// plan defers; "Large" == the vanilla jar size.
static function float BeanScale(int code, float base)
{
    if (code == 2001) return base * 0.60; // Small
    if (code == 2002) return base * 0.80; // Medium
    if (code == 2003) return base * 1.00; // Large  (== vanilla JarBeans)
    return base * 1.25;                    // 2004 Massive
}

// The per-spell wand-target gesture sprite (the shape SpellCursor draws on a
// locked target, SpellCursor.uc:84-108) by spell index (0 Alohomora,
// 1 Diffindo, 2 Flipendo, 3 Lumos, 4 Rictusempra, 5 Skurge, 6 Spongify, same
// order as SpellNames[]). WetTexture is-a Texture, so it loads cleanly as
// class'Texture'. None for an unknown index keeps the marker's native look.
static function Texture SpellGestureTextureForIndex(int idx)
{
    if (idx == 0) return Texture(DynamicLoadObject("SpellShapes.SpellFX.AlohomoraWet1", class'Texture'));
    if (idx == 1) return Texture(DynamicLoadObject("SpellShapes.SpellFX.DiffindoWet1", class'Texture'));
    if (idx == 2) return Texture(DynamicLoadObject("SpellShapes.SpellFX.FlipendoWet1", class'Texture'));
    if (idx == 3) return Texture(DynamicLoadObject("SpellShapes.SpellFX.LumosWet1", class'Texture'));
    if (idx == 4) return Texture(DynamicLoadObject("SpellShapes.SpellFX.RictusWet1", class'Texture'));
    if (idx == 5) return Texture(DynamicLoadObject("SpellShapes.SpellFX.SkurgeWet1", class'Texture'));
    if (idx == 6) return Texture(DynamicLoadObject("SpellShapes.SpellFX.SpongifyWet1", class'Texture'));
    return None;
}

// A random Bertie Bott's bean skin for the loose-bean fillers (1 / 5 Bean) so
// the pickup is a different colour each time it is stamped instead of one
// static texture. All 12 are vanilla HProps single-bean skins (the set
// Jellybean.uc's subclasses use). Re-rolled on every appearance re-stamp.
static function Texture RandomBeanTexture()
{
    local int i;
    i = Rand(12);
    if (i == 0)  return Texture(DynamicLoadObject("HProps.skJellybeanTex0",     class'Texture'));
    if (i == 1)  return Texture(DynamicLoadObject("HProps.skBeanRedTex0",       class'Texture'));
    if (i == 2)  return Texture(DynamicLoadObject("HProps.skBeanBlueSpotTex0",  class'Texture'));
    if (i == 3)  return Texture(DynamicLoadObject("HProps.skBeanBlackTex0",     class'Texture'));
    if (i == 4)  return Texture(DynamicLoadObject("HProps.skBeanPurpleTex0",    class'Texture'));
    if (i == 5)  return Texture(DynamicLoadObject("HProps.skBeanDarkGreenTex0", class'Texture'));
    if (i == 6)  return Texture(DynamicLoadObject("HProps.skBeanBogieTex0",     class'Texture'));
    if (i == 7)  return Texture(DynamicLoadObject("HProps.skBeanBrownTex0",     class'Texture'));
    if (i == 8)  return Texture(DynamicLoadObject("HProps.skBeanDkBlueTex0",    class'Texture'));
    if (i == 9)  return Texture(DynamicLoadObject("HProps.skBeanMauveTex0",     class'Texture'));
    if (i == 10) return Texture(DynamicLoadObject("HProps.skBeanOrngeTex0",     class'Texture'));
    return Texture(DynamicLoadObject("HProps.skBeanYellowyTex0", class'Texture'));
}

// Stamp mesh + (optionally) skin + draw fields onto any Actor (runtime Mesh/
// Skin/DrawType reassignment is engine-supported, Characters.uc:991-1034). If
// the mesh can't resolve, nothing is touched → marker keeps its native look
// (async-safe). 3-skin filler meshes pass bSetSkin=False (baked materials).
// bLogoStyle = the foreign AP-logo: STY_Masked for the magenta chroma-key
// transparency (see APLogoMesh.uc), unlit + full glow for constant brightness.
static function ApplyMeshSkin(Actor a, Mesh m, Material tex, bool bSetSkin, float scale, bool bLogoStyle)
{
    if (a == None || m == None) return;
    a.Mesh = m;
    a.DrawType = DT_Mesh;
    a.DrawScale = scale;
    if (bSetSkin && tex != None)
    {
        a.Skin = tex;
        a.MultiSkins[0] = tex;
    }
    if (bLogoStyle)
    {
        a.Style = STY_Masked;
        a.bUnlit = True;
        a.AmbientGlow = 255;
    }
    else
    {
        a.Style = STY_Normal;
        a.bUnlit = False;
    }
}

// The resolver. Morphs `a` to the vanilla art of whatever the location holds,
// per the appearance code. code 0 ⇒ leave the marker's own native look (do
// nothing). All asset objects are resolved by name via DynamicLoadObject so
// there is no hard package link and a not-yet-loaded asset degrades to
// "native" rather than failing. The per-card face is read from
// <cardClass>.default.Skin (proven pattern, APGameInfo.uc:1448) so the
// Griffindor/Gryffindor skin-name irregularity is auto-correct.
static function ApplyAppearanceTo(Actor a, int code)
{
    local Mesh m;
    // Actor.Skin / MultiSkins[] and WizardCardIcon.default.Skin are typed
    // Material in this engine (Texture extends Material), so the skin handle
    // must be Material; a Texture from DynamicLoadObject up-casts cleanly.
    local Material tex;
    local class<WizardCardIcon> cc;
    local string cn;
    local float sc;          // resolved per-prop vanilla DrawScale
    local Rotator r;         // 3003 key: 180° roll fix

    if (a == None || code == 0) return;

    if (code >= 1 && code <= 101)
    {
        m = Mesh(DynamicLoadObject("HProps.skWizardCardIconMesh", class'Mesh'));
        sc = 2.0; // WizardCardIcon.defaultproperties DrawScale (fallback)
        cn = class'APCardAppearance'.static.CardClassNameForId(code);
        if (cn != "")
        {
            cc = class<WizardCardIcon>(DynamicLoadObject("HGame." $ cn, class'Class'));
            if (cc != None)
            {
                tex = cc.default.Skin;
                sc  = cc.default.DrawScale; // per-card vanilla size (== 2.0)
            }
        }
        ApplyMeshSkin(a, m, tex, True, sc, False);
    }
    else if (code >= 1000 && code <= 1006)
    {
        // Spells are learned, not dropped: no vanilla world prop to anchor
        // on. Put the wand-target gesture art (the shape the player already
        // reads as "this spell") on the flat wizard-card mesh so a spell
        // pickup spins like a card pickup in the same chest (the card actor's
        // own Tick drives the Yaw spin). DrawScale 3.0 is deliberately above
        // the WizardCardIcon default of 2.0 so the gesture glyph reads at a
        // glance.
        m = Mesh(DynamicLoadObject("HProps.skWizardCardIconMesh", class'Mesh'));
        tex = SpellGestureTextureForIndex(code - 1000);
        ApplyMeshSkin(a, m, tex, True, 3.0, False);
    }
    else if (code >= 2001 && code <= 2004)
    {
        m = Mesh(DynamicLoadObject("HProps.skJarBeansMesh", class'Mesh'));
        tex = Texture(DynamicLoadObject("HProps.skJarBeansTex0", class'Texture'));
        ApplyMeshSkin(a, m, tex, True,
            BeanScale(code, VanillaDrawScale("JarBeans", 2.5)), False);
    }
    else if (code == 2005)
    {
        m = Mesh(DynamicLoadObject("HProps.skBottlePotionGreen1Mesh", class'Mesh'));
        tex = Texture(DynamicLoadObject("HProps.skBottlePotionGreen1Tex0", class'Texture'));
        ApplyMeshSkin(a, m, tex, True,
            VanillaDrawScale("BottlePotionGreen1", 1.0), False);
    }
    else if (code == 2006)
    {
        // 3-skin mesh, set Mesh only so the baked materials render.
        m = Mesh(DynamicLoadObject("HProps.skJarWiggentreeBarkMesh", class'Mesh'));
        ApplyMeshSkin(a, m, None, False,
            VanillaDrawScale("JarWiggentreeBark", 1.2), False);
    }
    else if (code == 2007)
    {
        // 3-skin mesh, set Mesh only.
        m = Mesh(DynamicLoadObject("HProps.skJarFlobberwormMucusMesh", class'Mesh'));
        ApplyMeshSkin(a, m, None, False,
            VanillaDrawScale("JarFlobberwormMucus", 1.2), False);
    }
    else if (code == 2008)
    {
        m = Mesh(DynamicLoadObject("HProps.skChocolateFrogMesh", class'Mesh'));
        tex = Texture(DynamicLoadObject("HProps.skChocolateFrogTex0", class'Texture'));
        ApplyMeshSkin(a, m, tex, True,
            VanillaDrawScale("ChocolateFrog", 0.5), False);
    }
    else if (code == 2009)
    {
        // 1 Bean, the vanilla jellybean prop, random colour per stamp.
        // Smallest of the bean ladder so a single bean reads as the lowest
        // reward.
        m = Mesh(DynamicLoadObject("HProps.skJellybeanMesh", class'Mesh'));
        tex = RandomBeanTexture();
        ApplyMeshSkin(a, m, tex, True, 1.5, False);
    }
    else if (code == 2010)
    {
        // 5 Beans, same bean mesh, random colour per stamp, larger than
        // 1 Bean so the two read apart by size.
        m = Mesh(DynamicLoadObject("HProps.skJellybeanMesh", class'Mesh'));
        tex = RandomBeanTexture();
        ApplyMeshSkin(a, m, tex, True, 2.0, False);
    }
    else if (code == 2011)
    {
        // 10 Beans, the bean jar, below the Small Pile (0.60) so the size
        // ladder reads loose bean -> small jar -> the Piles.
        m = Mesh(DynamicLoadObject("HProps.skJarBeansMesh", class'Mesh'));
        tex = Texture(DynamicLoadObject("HProps.skJarBeansTex0", class'Texture'));
        ApplyMeshSkin(a, m, tex, True,
            VanillaDrawScale("JarBeans", 2.5) * 0.45, False);
    }
    else if (code == 3001)
    {
        // Nimbus 2001, vanilla VendorNimbusBroom look (single baked skin,
        // set Mesh only).
        m = Mesh(DynamicLoadObject("HProps.skBroomQudditchMesh", class'Mesh'));
        ApplyMeshSkin(a, m, None, False,
            VanillaDrawScale("VendorNimbusBroom", 1.0), False);
    }
    else if (code == 3002)
    {
        // Quidditch Armour, vanilla QArmor look.
        m = Mesh(DynamicLoadObject("HProps.skQuidArmorMesh", class'Mesh'));
        ApplyMeshSkin(a, m, None, False,
            VanillaDrawScale("QArmor", 1.0), False);
    }
    else if (code == 3003)
    {
        // Open castle level/challenge bookcase key: the vanilla "silver key" FX
        // sprite (HPParticle.hp_fx.Particles.Key3, the texture SilverUnlock
        // spawns on every 10th silver card). It is a light-on-black additive
        // particle texture: the masked chroma-key (bLogoStyle) cannot key
        // black, so override to STY_Translucent. Black drops to transparent
        // and the key glows. Card-sized on the flat card quad (DrawScale 2.0).
        m   = Mesh(DynamicLoadObject("HProps.skWizardCardIconMesh", class'Mesh'));
        tex = Texture(DynamicLoadObject("HPParticle.hp_fx.Particles.Key3", class'Texture'));
        ApplyMeshSkin(a, m, tex, True, 2.0, True);
        a.Style = STY_Translucent;
        // Key3 maps onto the card quad upside down; roll 180° (32768 = 180°
        // in Rotator units). Absolute set, not an increment, so repeated
        // morph passes stay idempotent; the Wait-state spin animates Yaw
        // only, so this Roll persists.
        r = a.Rotation;
        r.Roll = 32768;
        a.SetRotation(r);
    }
    else if (code == 9000)
    {
        // Foreign plain (per-orb AP-logo coins). Textures live in the `Skins`
        // group so they MUST be loaded group-qualified (group-less DLO returns
        // None, which would drop 9001 back to the baked plain skin). DrawScale
        // 1.65 ≈ card-sized (tunable).
        m = Mesh(DynamicLoadObject("HPArchipelago.APLogoMesh", class'Mesh'));
        tex = Texture(DynamicLoadObject("HPArchipelago.Skins.APLogoTex0", class'Texture'));
        ApplyMeshSkin(a, m, tex, True, 1.65, True);
    }
    else if (code == 9001)
    {
        m = Mesh(DynamicLoadObject("HPArchipelago.APLogoMesh", class'Mesh'));
        tex = Texture(DynamicLoadObject("HPArchipelago.Skins.APLogoArrowTex0", class'Texture'));
        ApplyMeshSkin(a, m, tex, True, 1.65, True);
    }
}

// Lazy-load the in-trade "AP item" icon. APLogoTradeTex0 is a 64x64
// downscale of the world-pickup APLogoTex0 (generated by
// tools/gen_trade_icon.py), sized to fit the trade bar's icon slot.
// Canvas.DrawIcon draws at the texture's native USize/VSize so the original
// 256x256 mesh-skin variant overflows; this dedicated UI variant fits.
static function Texture GetAPItemTextureStatic()
{
    if (default.CachedAPItemTexture == None)
    {
        default.CachedAPItemTexture = Texture(DynamicLoadObject(
            "HPArchipelago.Skins.APLogoTradeTex0", class'Texture'));
    }
    return default.CachedAPItemTexture;
}

//================================================================================
// APGhostGlassesMesh.
//
// The ghost players' glasses: the project's own model, drawn by
// tools/gen_ghost_glasses.py (two round rims, a bridge and two temples, facing
// +X with the bridge at the origin), on a grey blue texture.
// APGhostGlasses draws it solid on the ghost's face, and the near-black APGhostNoGlasses
// hides the ghost's own faded glasses slot.
//
// UE1 re-import gotcha: UCC only re-runs the #exec lines when this .uc
// recompiles. Bump the asset-rev tag on any asset change for non-clean builds.
// asset-rev: 8
//
// Extends HPMesh: HPModels precedes HPArchipelago in Default.ini EditPackages.
//================================================================================

class APGhostGlassesMesh extends HPMesh
  Abstract;

#exec Anim Import Anim=APGhostGlassesAnims AnimFile=Models\APGhostGlassesAnims.psa Compress=1 MaxKeys=999999 ImportSeqs=1
#exec Texture Import File=Textures\APGhostGlasses.bmp Name=APGhostGlasses Mips=1 Flags=0 Group=Skins
#exec Texture Import File=Textures\APGhostNoGlasses.bmp Name=APGhostNoGlasses Mips=1 Flags=0 Group=Skins

#exec Mesh ModelImport Mesh=APGhostGlassesModel ModelFile=Models\APGhostGlasses.psk LODStyle=10
// Level of detail off: dropping vertices with distance breaks the thin frames.
#exec Mesh LODParams Mesh=APGhostGlassesModel Strength=0.0
#exec Mesh Origin Mesh=APGhostGlassesModel X=0 Y=0 Z=0 Yaw=0 Pitch=0 Roll=0
#exec MeshMap Scale MeshMap=APGhostGlassesModel X=1.0 Y=1.0 Z=1.0
#exec Mesh DefaultAnim Mesh=APGhostGlassesModel Anim=APGhostGlassesAnims
#exec MeshMap SetTexture MeshMap=APGhostGlassesModel Num=0 Texture=APGhostGlasses

#exec Anim Digest Anim=APGhostGlassesAnims VERBOSE

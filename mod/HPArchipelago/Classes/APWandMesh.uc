//================================================================================
// APWandMesh.
//
// The giant wand for the Overcompensation Trap: the project's own wand model,
// drawn by tools/gen_wand_mesh.py (an octagonal handle and tapering shaft, 20
// units down the negative Z axis like the game's wand, on a generated wood
// texture). The held wand is attached to Harry's WeaponRight bone,
// and the renderer ignores a bone-attached actor's own DrawScale
// (verified: setting baseWand.DrawScale changed nothing on screen), so the only
// way to enlarge the held wand is to swap baseWand.Mesh/ThirdPersonMesh to a
// variant whose scale is baked into its MeshMap. The trap applies APWandGiant;
// APCardWatcher restores HPModels.WandMesh on the next level change.
//
// The mesh is imported at a baked MeshMap scale (a MeshMap carries a single bake
// scale). Like the game's wand it has one bone and a one-frame 'All' sequence,
// so PlayAnim('All') behaves the same.
//
// UE1 re-import gotcha: editing the .psk/.psa/.bmp alone does not re-import; UCC
// only re-runs the #exec lines when this .uc recompiles. Bump the asset-rev tag
// on any asset change for non-clean builds.
// asset-rev: 3
//
// Extends HPMesh: HPModels precedes HPArchipelago in Default.ini EditPackages.
//================================================================================

class APWandMesh extends HPMesh
  Abstract;

//animation + skin
#exec Anim Import Anim=APWandAnims AnimFile=Models\APWandAnims.psa Compress=1 MaxKeys=999999 ImportSeqs=1
#exec Texture Import File=Textures\APWandTex.bmp Name=APWandTex0 Mips=1 Flags=0 Group=Skins

//giant (3.0)
#exec Mesh ModelImport Mesh=APWandGiant ModelFile=Models\APWandMesh.psk LODStyle=10
#exec Mesh Origin Mesh=APWandGiant X=0 Y=0 Z=0 Yaw=0 Pitch=0 Roll=0
#exec MeshMap Scale MeshMap=APWandGiant X=3.0 Y=3.0 Z=3.0
#exec Mesh DefaultAnim Mesh=APWandGiant Anim=APWandAnims
#exec MeshMap SetTexture MeshMap=APWandGiant Num=0 Texture=APWandTex0

#exec Anim Digest Anim=APWandAnims VERBOSE

//================================================================================
// APWandMesh.
//
// An enlarged copy of the vanilla wand (HPModels.WandMesh) for the
// Overcompensation Trap. The held wand is attached to Harry's WeaponRight bone,
// and this M212 renderer ignores a bone-attached actor's own DrawScale
// (verified: setting baseWand.DrawScale changed nothing on screen), so the only
// way to enlarge the held wand is to swap baseWand.Mesh/ThirdPersonMesh to a
// variant whose scale is baked into its MeshMap. The trap applies APWandGiant;
// APCardWatcher restores HPModels.WandMesh on the next level change.
//
// The variant is a re-import of the same WandMesh.psk at a baked MeshMap scale
// (a MeshMap carries a single bake scale). It shares the WandMesh skeleton, so
// the WandAnims import bound via DefaultAnim makes PlayAnim('All') behave
// exactly like the vanilla wand, on the original WandTex0 skin.
//
// UE1 re-import gotcha: editing the .psk/.psa/.png alone does not re-import; UCC
// only re-runs the #exec lines when this .uc recompiles. Bump the asset-rev tag
// on any asset change for non-clean builds.
// asset-rev: 2
//
// Extends HPMesh: HPModels precedes HPArchipelago in Default.ini EditPackages.
//================================================================================

class APWandMesh extends HPMesh
  Abstract;

//animation + skin (same WandMesh.psk skeleton as the vanilla wand)
#exec Anim Import Anim=APWandAnims AnimFile=Models\WandAnims.psa Compress=1 MaxKeys=999999 ImportSeqs=1
#exec Texture Import File=Textures\WandTex0.png Name=APWandTex0 COMPRESSION=0 UPSCALE=1 Mips=1 Flags=0 Group=Skins

//giant (3.0)
#exec Mesh ModelImport Mesh=APWandGiant ModelFile=Models\WandMesh.psk LODStyle=10
#exec Mesh Origin Mesh=APWandGiant X=0 Y=0 Z=0 Yaw=0 Pitch=0 Roll=0
#exec MeshMap Scale MeshMap=APWandGiant X=3.0 Y=3.0 Z=3.0
#exec Mesh DefaultAnim Mesh=APWandGiant Anim=APWandAnims
#exec MeshMap SetTexture MeshMap=APWandGiant Num=0 Texture=APWandTex0

#exec Anim Digest Anim=APWandAnims VERBOSE

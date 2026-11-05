// Mesh holder for APSlabMesh: a 128x128x48 box, the visible slab under the
// open castle Spongify pad on the Grounds (tools/gen_slab_mesh.py). The skin is
// the stock pad texture, set at runtime by APSpongifySlab.
class APSlabMesh extends HPMesh
  Abstract;

#exec Mesh ModelImport Mesh=APSlabMesh ModelFile=Models\APSlabMesh.psk LODStyle=10
#exec Mesh Origin Mesh=APSlabMesh X=0 Y=0 Z=0 Yaw=0 Pitch=0 Roll=0

#exec Anim Import Anim=APSlabAnims AnimFile=Models\APSlabAnims.psa Compress=1 MaxKeys=999999 ImportSeqs=1
#exec MeshMap Scale MeshMap=APSlabMesh X=1.0 Y=1.0 Z=1.0
#exec Mesh DefaultAnim Mesh=APSlabMesh Anim=APSlabAnims
#exec Anim Digest Anim=APSlabAnims VERBOSE

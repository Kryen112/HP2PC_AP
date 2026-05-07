class HelloMutator extends Mutator;

event PreBeginPlay()
{
    Super.PreBeginPlay();
    Log("[Archipelago] HelloMutator PreBeginPlay - mutator chain alive");
}

from test.bases import WorldTestBase

from .. import HP2World


class HP2TestBase(WorldTestBase):
    game = "Harry Potter 2 PC"
    world: HP2World

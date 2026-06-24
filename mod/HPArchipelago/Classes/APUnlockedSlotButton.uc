//=============================================================================
// APUnlockedSlotButton - icon cell for the pause-menu "Unlocked" panel.
//
// A plain HGameButton runs its design x through AlignButton in Resized, which
// applies the "Menu Centering" 4:3 horizontal correction. That makes the
// right-side Unlocked icons slide inward with the slider while the canvas-drawn
// goal-progress panel on the left stays put. This subclass drops only that
// horizontal correction by pinning WinLeft back to the raw design x, so the
// icons share the goal panel's pure-proportional placement and ignore the
// slider. Vertical position and size scaling are left untouched.
//=============================================================================

class APUnlockedSlotButton extends HGameButton;

function Resized()
{
    Super.Resized();
    WinLeft = WX + XOffset;
}

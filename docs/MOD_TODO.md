# MOD_TODO — UnrealScript implementation checklist

Running list of things the UScript mod must do. Build out across milestones M1–M8 (`docs/ROADMAP.md`). Tick off as you go.

## Hooks (intercept vanilla events to send AP `check_sent`)

- [ ] **Card pickup hook** — override `Touch()` in `BronzeCards`, `SilverCards`, `Goldcards` (parent classes). Fire `check_sent` with the card's `Id`. Then call `Super.Touch()` so vanilla pickup proceeds (count increments, FX play, album updates).
- [ ] **Spell-tutorial completion hook** — find the trigger that fires when a spell tutorial completes; fire `check_sent` with the tutorial location ID; **suppress the auto-transition into the matching challenge level**. Player remains in the classroom / hub.
- [ ] **Key-item pickup hook** — Boomslang, Bicorn, BitOGoyle. Same pattern as cards. Subclass the relevant `StatusItem*` or pickup actor, fire `check_sent`, then Super.
- [ ] **Level completion hook** — find the level-end trigger fired at the end of each level; fire `check_sent` with the level ID. Allow the level to end normally.
- [ ] **Basilisk death hook** — subclass `Basilisk` (`HGame/Classes/Bosses/Basilisk.uc`), override its death function, fire `goal_complete`, then call Super.

## Inbound (apply items granted by the AP server)

- [ ] **`APItemReceiver`** — handles `grant_item` messages. Maps item names to apply-functions. **All apply functions must be idempotent** (re-applying does nothing if Harry already has the item).
- [ ] **Apply spell** — add to spellbook (find vanilla "learn spell" path used by tutorials). Spawn 10-card-set celebration FX (`BronzeStamina` for normal, `SilverUnlock` for fancy) — see `WizardCardIcon.uc:104,117`.
- [ ] **Apply card** — call `siCard.SetCardOwner(Id, CardOwner_Harry)` on the relevant `StatusItemBronzeCards` / `StatusItemSilverCards` / `StatusItemGoldCards`. Spawn native pickup FX (`BronzePickup` / `SilverPickup` / `GoldPickup`).
- [ ] **Apply key item** — set the corresponding StatusItem flag. Silent + toast.
- [ ] **Apply filler (beans)** — add N beans to the player's bean count.

## Item delivery queue

- [ ] **`APItemQueue`** — FIFO queue. `grant_item` messages enqueue. A `Tick`-based drainer applies items only in **safe states**:
  - Harry exists, has player control (no `bIsInCutscene`, no menu open, no level load in progress, not Quidditch mid-match, not in dialog).
  - One item per ~1.5 seconds to prevent FX/sound flooding.
- [ ] **HUD toast** — for every applied item, also emit an on-screen "Received <item> from <player>" message. Stack vertically, fade after a few seconds.

## Vendor disable

- [ ] **Disable vendor card sales** — find the vendor inventory class; remove cards from the available SKUs. Beans / potion ingredients still sold normally.

## Level lockouts

- [ ] **Confirm levels are re-entrable** after completion. Vanilla HP2 might or might not lock you out of completed levels; investigate during playtest. If it does, patch the level-state flag check.

## IPC

- [ ] **`APIPCActor`** — wraps `class'IpDrv.TcpLink'`. Connects to `localhost:<port>`. Reads newline-delimited JSON. Writes newline-delimited JSON. Reconnect-on-disconnect with capped exponential backoff.
- [ ] **Boot sequence:** on level load, if not connected, attempt connect. On connect, request the items-received list from the sidecar (which got it from the AP server) and re-apply via `APItemReceiver` (idempotent).

## Config

- [ ] **`APConfig`** — port, possibly the slot name as a fallback. Editable via console (`set APConfig nPort 38281`) or .ini.

## Open questions for playtest

- Whether each of the 7 spells is taught in a classroom, picked up from a book, or earned in a challenge — needs cataloguing. (Determines the 4 sphere-0 location names.)
- Whether the post-tutorial level transition is fired by the cutscene, by a trigger, or by a state change — determines what to suppress.
- Whether HP2 has a "level cleared" persistent flag; if yes, whether re-entry is gated by it.
- What the Basilisk death function is actually called (`Died`, `Killed`, custom). Confirm in `Basilisk.uc` / `baseBasilisk.uc`.

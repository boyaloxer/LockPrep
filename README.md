# LockPrep

A warlock **arena prep helper** for WoW TBC Anniversary (2.5.x). It turns the
whole pre-gates routine (healthstones, spellstone, pet summons, buffs, Shadow
Ward, Tainted Blood, mount) into a single button you spam, plus a checklist that
counts down to the gate.

No `/castsequence`. Nothing gets automated that the game doesn't allow. You still
press the key for every action; the addon just always picks the *right next
action* for you.

## How it works

LockPrep has two parts:

1. **A state-aware "next step" button.** Bind one key to it. Each press performs
   the **first step that isn't done yet**, decided by reading your actual game
   state: bags, buffs, your pet, weapon/relic slot, and group size. If a step
   fails (out of range, interrupted, etc.) it simply stays "not done," so your
   next press just retries it. No sequence to desync.

2. **A bracket-aware checklist** with a gate countdown display (parsed from the
   "One minute / Thirty seconds / ..." messages). It shows what's done and what's
   next, and highlights the current step.

Most steps are gated by **state and order** — a failed cast just stays "not
done," so your next press retries it. The time-sensitive **finish** (Felhunter,
Sacrifice, Soul Link, Shadow Ward, Tainted Blood, mount) is additionally held
until **~12 seconds before the gates** so mashing early doesn't waste your
short-duration shields; it then unlocks on its own. If no gate countdown is
detected, the finish falls back to order-only so a missing timer never locks you
out.

The routine scales with the bracket via **presets** (2s, 3s/5s, BGs, Custom).

## Important: it reacts to what it can see

Because every press is a **state check**, the addon can only advance once the
result of your last action has actually registered in the game, i.e. once the
**healthstone is visibly in your bag**, the **pet is actually summoned**, the
**buff icon is up**, and so on.

There's a brief delay between casting something and the game reporting it. If you
mash the button *faster than the game updates*, LockPrep still sees the previous
step as "not done" and will **repeat that action**.

**Rule of thumb: give each step a beat.** Wait until you see the healthstone
appear, the pet pop, or the buff light up before driving the next step. When in
doubt, watch the checklist; it updates the instant the game does, so it's your
signal that it's safe to press again.

This is by design, and it's what makes the button robust (a failed cast just
retries instead of skipping ahead). It just means "spam smart," not "spam blind."

## Quick start

1. `/lp bind SHIFT-E` binds the one key you'll spam during prep.
2. (optional) Set your wand with `/lp wand <your wand name>`, then bind the
   spellstone dispel/swap to its own key with `/lp bindss SHIFT-R`.
3. **Left-click the minimap icon** for options/presets. **Right-click** it to
   toggle the checklist (same as `/lp test`).
4. In the arena, mash your bound key. It does each step in order, pausing where
   your state hasn't caught up yet (see the note above).

## Presets

Pick one from the **Preset** dropdown (or `/lp preset ...`). A preset just
checks/unchecks the right boxes:

| Preset | What it sets up |
| --- | --- |
| **2s** | Conjure healthstones one by one and trade them; no Ritual of Souls. Master Spellstone and Major Healthstone are left **off** by default (personal preference; tick them if you use them). |
| **3s / 5s** | Ritual of Souls (soulwell) instead of individual stones. |
| **BGs** | Ritual of Souls, Imp, buffs, Felhunter, Soul Link, mount. No Voidwalker, Sacrifice, or Shadow Ward (you're not engaging before the shield falls off). |
| **Custom** | Leaves your checkboxes exactly as they are so you can build your own. Hand-editing any box also flips you to Custom. |

## Healthstone trading (2s)

- When a stone is ready, LockPrep can shout a battle-cry in `/say` ("Open trade
  if you want to live." or "Soulwell's up...") so teammates know to open a trade.
  Toggle it in options; it only fires when a teammate actually needs a stone.
- When a teammate opens a trade with you (or you open one), your healthstones are
  auto-dropped into the trade window. You still accept it yourself with your
  normal button or the `/lp bindaccept` key; nothing is accepted without a real
  key press.
- Already-traded teammates are tracked for the match so you don't double-hand or
  re-announce.
- **Warlock partners are skipped** for stone trades (they conjure their own, so a
  trade would never get accepted). They still get your buffs, and in 3s/5s they
  grab from the soulwell like everyone else. If a warlock ever *does* want one,
  they can open the trade and your stone still auto-fills.

## Spellstone dispel/swap (optional)

Master Spellstone in TBC is a **relic in the wand/ranged slot** with an on-use
that dispels all harmful magic from you (off-GCD, 3-min cooldown). LockPrep's
prep equips it early so the equip cooldown is gone by the gates. Bind the swap
button (`/lp bindss <KEY>`) and set your wand name (`/lp wand <name>`); pressing
it dispels and swaps back to your wand, and pressing again re-arms the stone.

## Commands

```
/lp show | hide | test    show/hide the checklist (or right-click the minimap icon)
/lp minimap               show/hide the minimap icon
/lp options               choose which steps to include (or left-click the icon)
/lp preset 2s|3s5s|bg|custom   apply a preset (custom keeps your boxes)
/lp trade                 arm one trade to auto-fill your healthstones (auto in arena)
/lp announce              say the "open trade" battle-cry now
/lp mount <name>          set the gate-sprint mount (or pick it in /lp options)
/lp bind <KEY>            bind the next-step button (e.g. /lp bind 0)
/lp bindss <KEY>          bind the spellstone dispel/swap button
/lp bindaccept <KEY>      bind a key to accept a trade (when stones are in)
/lp wand <name>           set your wand's exact name (for the spellstone swap)
/lp unlock | lock         move / pin the checklist window
/lp spellstone            explain the spellstone dispel/swap button
/lp status                show your keybinds + what the next press will cast
```

The **mount dropdown** in options is populated from mount items in your bags.

## Notes

- Built for **TBC Anniversary (2.5.6)**, enUS. If a spell/item/pet name differs
  on your client or locale, edit the `CFG` table at the top of `LockPrep.lua`.
- The checklist window is **off by default**; use the minimap icon or `/lp test`.
- Settings and keybinds persist per-character in `LockPrepDB`.

## Changelog

### 0.15.2

- **New:** The gate mount works out of the box — if you haven't picked one,
  LockPrep auto-uses the first ground mount in your bags instead of a hardcoded
  name.
- **New:** Warlock class mounts (Summon Felsteed / Summon Dreadsteed) can be
  chosen as your gate mount; the step casts them instead of using an item.
- **Changed:** The mount picker now lists only ground mounts — flying mounts
  (unusable in the arena) are filtered out.

### 0.15.1

- **Changed:** The `/say` "open trade" announce is now **off by default** (opt in
  from options). LockPrep opens trades itself now, so the shout isn't needed.

### 0.15.0

- **New:** LockPrep now opens the trade for you (2s). Press your prep key and it
  opens a trade with the next partner who still needs a healthstone — previously
  the window had to be opened manually (by you or them). Your stones are still
  auto-filled and accepted on your next press, so you can keep mashing through
  prep.
- **New:** Auto-accepts a teammate's gift trade (e.g. a mage handing back
  food/water) on your key press.
- **New:** Warlock partners are no longer offered healthstone trades (they make
  their own); buffs and Ritual of Souls still cover them.
- **Changed:** The finish (Felhunter through mount) is now held until ~12s before
  the gates so mashing early doesn't waste short-duration shields, then unlocks
  automatically. Falls back to order-only if no countdown is detected.
- **Fixed:** No more double-cast when mashing the key during a pet summon or
  healthstone conjure.
- **Fixed:** Felhunter / Soul Link / Tainted Blood stay in the right order
  through the pet spawn gap.
- **Fixed:** Trade accept no longer flickers green/gray, respects Blizzard's
  anti-scam accept lockout, and no longer re-opens an empty window right after a
  completed trade.

### 0.14.0

- Initial CurseForge release.

## License

GPL-2.0. See the [LICENSE](LICENSE) file. Copyright (C) 2026 boyaloxer.

# LockPrep

A warlock **arena prep helper** for WoW TBC Anniversary (2.5.x). It turns the
whole pre-gates routine — healthstones, spellstone, pet summons, buffs, Shadow
Ward, Tainted Blood, mount — into a single button you spam, plus a checklist
that counts down to the gate.

No `/castsequence`. Nothing gets automated that the game doesn't allow. You still
press the key for every action; the addon just always picks the *right next
action* for you.

---

## How it works

LockPrep has two parts:

1. **A state-aware "next step" button.** Bind one key to it. Each press performs
   the **first step that isn't done yet**, decided by reading your actual game
   state — bags, buffs, your pet, weapon/relic slot, and group size. If a step
   fails (out of range, interrupted, etc.) it simply stays "not done," so your
   next press just retries it. No sequence to desync.

2. **A bracket-aware checklist** with a gate countdown display (parsed from the
   "One minute / Thirty seconds / ..." messages). It shows what's done and what's
   next, and highlights the current step.

Steps are gated by **state and order only**, not the clock — so nothing gets
blocked if the gate countdown mis-parses. You decide when to fire the final
Shadow Ward / Tainted Blood / mount, the same way you time everything else.

The routine scales automatically with the bracket via **presets** (2s / 3s-5s /
BGs / Custom).

---

## ⚠️ Important: it reacts to what it can SEE

Because every press is a **state check**, the addon can only advance once the
result of your last action has actually registered in the game — i.e. once the
**healthstone is visibly in your bag**, the **pet is actually summoned**, the
**buff icon is up**, etc.

There's a brief delay between casting something and the game reporting it. If you
mash the button *faster than the game updates*, LockPrep still sees the previous
step as "not done" and will **repeat that action**.

**Rule of thumb: give each step a beat.** Wait until you see the healthstone
appear, the pet pop, or the buff light up before driving the next step. When in
doubt, watch the checklist — it updates the instant the game does, so it's your
signal that it's safe to press again.

This is by design and it's what makes the button robust (a failed cast just
retries instead of skipping ahead) — it just means "spam smart," not "spam
blind."

---

## Quick start

1. `/lp bind SHIFT-E` — bind the one key you'll spam during prep.
2. (optional) `/lp wand <your wand name>` then `/lp bindss SHIFT-R` — spellstone
   dispel/swap on its own key.
3. **Left-click the minimap icon** for options/presets. **Right-click** it to
   toggle the checklist (also `/lp test`).
4. In the arena: mash your bound key — it does each step in order, pausing where
   your state hasn't caught up yet (see the note above).

---

## Presets

Pick one from the **Preset** dropdown (or `/lp preset ...`). A preset just
checks/unchecks the right boxes:

| Preset | What it sets up |
| --- | --- |
| **2s** | Conjure healthstones one-by-one and trade them; no Ritual of Souls. Master Spellstone and Major Healthstone are left **off** (personal preference — tick them if you use them). |
| **3s / 5s** | Ritual of Souls (soulwell) instead of individual stones. |
| **BGs** | Ritual of Souls + Imp + buffs + Felhunter + Soul Link + mount. No Voidwalker, Sacrifice, or Shadow Ward (you're not engaging before the shield falls off). |
| **Custom** | Leaves your checkboxes exactly as they are so you can build your own. Hand-editing any box also flips you to Custom. |

---

## Healthstone trading (2s)

- When a stone is ready, LockPrep can shout a battle-cry in `/say`
  ("Open trade if you want to live." / "Soulwell's up..."), so teammates know to
  open a trade. Toggle in options; it only fires when a teammate actually needs
  a stone.
- When a teammate opens a trade with you (or you open one), your healthstones are
  auto-dropped into the trade window. Accept it with your normal button/`/lp
  bindaccept` key — nothing is accepted without a real key press.
- Already-traded teammates are tracked for the match so you don't double-hand or
  re-announce.

---

## Spellstone dispel/swap (optional)

Master Spellstone in TBC is a **relic in the wand/ranged slot** with an on-use
that dispels all harmful magic from you (off-GCD, 3-min CD). LockPrep's prep
equips it early so the equip cooldown is gone by the gates. Bind the swap button
(`/lp bindss <KEY>`) and set your wand name (`/lp wand <name>`); pressing it
dispels + swaps back to your wand, and pressing again re-arms the stone.

---

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

---

## Notes

- Built for **TBC Anniversary (2.5.6)**, enUS. If a spell/item/pet name differs
  on your client or locale, edit the `CFG` table at the top of `LockPrep.lua`.
- The checklist window is **off by default**; use the minimap icon or `/lp test`.
- Settings and keybinds persist per-character in `LockPrepDB`.

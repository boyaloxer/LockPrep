local ADDON = ...

-- LockPrep - warlock arena prep helper.
-- Copyright (C) 2026 boyaloxer
--
-- This program is free software; you can redistribute it and/or modify it under the terms of
-- the GNU General Public License as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version. This program is distributed WITHOUT
-- ANY WARRANTY; see the GNU General Public License for more details. You should have received a
-- copy of the license with this program (see the LICENSE file); if not, see
-- <https://www.gnu.org/licenses/>.

-- =====================================================================
-- LockPrep -- warlock arena prep helper.
--
-- Two pieces working together:
--   1. A state-aware secure button (LockPrepButton). Bind one key to it;
--      each press does the FIRST setup step that isn't done yet, checking
--      your actual game state (bags, buffs, pet, weapon imbue). A failed
--      step just stays "not done", so the next press retries it -- no
--      castsequence desync.
--   2. A bracket-aware checklist overlay with a gate countdown display
--      (parsed from the "One minute / Thirty seconds / ..." messages). It
--      highlights the current step. Steps are gated by state and order only --
--      not the clock -- so nothing is blocked if the countdown mis-parses.
--
-- Everything castable is expressed as macro text so targeting (@player,
-- @party1, ...) and specific spell ranks are exact. Tweak CFG if any name
-- differs on your client/locale.
-- =====================================================================

local CFG = {
    -- macro text per action (edit names/ranks/locale here if needed)
    cast = {
        hsMajor      = "/cast Create Healthstone(Rank 5)",   -- 11730 -> Major Healthstone
        hsMaster     = "/cast Create Healthstone(Rank 6)",   -- 27230 -> Master Healthstone
        ritual       = "/cast Ritual of Souls",              -- 3s/5s: soulwell for the team
        spellstone      = "/cast Create Spellstone",          -- highest known = Master (Rank 4)
        equipSpellstone = "/equip Master Spellstone",         -- relic goes in the wand/ranged slot
        dispelSpellstone= "/use Master Spellstone",           -- IN-COMBAT: dispel all harmful magic (3 min CD)
        summonImp    = "/cast Summon Imp",
        summonVoid   = "/cast Summon Voidwalker",
        summonFel    = "/cast Summon Felhunter",
        felArmor     = "/cast Fel Armor",                    -- self-only armor buff
        fireShield   = "/cast [@%s] Fire Shield",            -- %s = unit
        unending     = "/cast [@%s] Unending Breath",
        detectInvis  = "/cast [@%s] Detect Invisibility",
        sacrifice    = "/cast Sacrifice",
        soulLink     = "/cast Soul Link",
        taintedBlood = "/cast Tainted Blood",
        shadowWard   = "/cast Shadow Ward",
        mount        = "/use Red Skeletal Warhorse",         -- ground mount for the gate sprint
    },

    -- item / buff / pet names used for state detection (enUS)
    item = { hsMajor = "Major Healthstone", hsMaster = "Master Healthstone", spellstone = "Master Spellstone" },
    buff = {
        felArmor = "Fel Armor",
        fireShield = "Fire Shield", unending = "Unending Breath", detectInvis = "Detect Invisibility",
        sacrifice = "Sacrifice", soulLink = "Soul Link", shadowWard = "Shadow Ward", taintedBlood = "Tainted Blood",
    },
}

-- =====================================================================
-- State helpers
-- =====================================================================
local function HasBuff(unit, name)
    if not UnitExists(unit) then return false end
    for i = 1, 40 do
        local n = UnitBuff(unit, i)
        if not n then return false end
        if n == name then return true end
    end
    return false
end

local PET_RANK = { Imp = 1, Voidwalker = 2, Felhunter = 3 }
local function PetFamily() return UnitExists("pet") and UnitCreatureFamily("pet") or nil end
local function PetRank() return PET_RANK[PetFamily() or ""] or 0 end
local function HasPet() return UnitExists("pet") end

local function Have(itemName) return (GetItemCount(itemName) or 0) > 0 end

-- Creation-delay guard (summons + healthstones only) ------------------
-- A summon/conjure can double-fire in two ways when you mash the key:
--   1. Spell-queue window: a spell with a cast time queues a SECOND identical
--      cast if you press again during its last ~0.4s. Nothing you check in
--      done() can undo an already-queued cast.
--   2. Spawn gap: for a beat AFTER the cast lands the pet isn't UnitExists yet
--      / the stone hasn't dropped into the bag yet, so done() reads false and
--      the next press recasts.
-- We close BOTH, scoped to just these steps:
--   * (1) while you're mid-cast on the step's own spell, Refresh blanks the
--         button so a mashed press can't queue a duplicate;
--   * (2) on cast SUCCESS we mark the step done until the real thing is
--         observed. Pets use a monotonic "highest rank summoned this match" so
--         summoning a higher pet (which dismisses the lower one) never re-opens
--         an earlier summon step. Healthstones use a per-tier pending flag that
--         clears the instant the stone lands; trade it away and the step
--         re-offers on its own (stone's gone, pending already cleared).
-- No timers involved: latches clear on the confirming event, not a stopwatch.
local CREATE_HS_NAME = GetSpellInfo(6201) or "Create Healthstone" -- shared by all HS ranks
local SUMMON_NAME = {
    [1] = GetSpellInfo(688) or "Summon Imp",
    [2] = GetSpellInfo(697) or "Summon Voidwalker",
    [3] = GetSpellInfo(691) or "Summon Felhunter",
}
local petSummonedMax = 0   -- highest pet rank summoned this match (monotonic)
local hsPending = {}       -- "hs_major"/"hs_master" -> true until the stone lands

-- A summon step is done if we've summoned that rank (or higher) THIS match
-- (petSummonedMax, monotonic, set on cast success) OR the live pet is EXACTLY
-- that rank. We deliberately use PetRank() == rank (not >=): a HIGHER-rank pet
-- carried in from before the match (e.g. zoning in with a Felhunter) must NOT
-- mark the lower Imp/Voidwalker summons done, or Fire Shield (needs Imp) and
-- Sacrifice (needs Voidwalker) get stranded. Summoning the Imp first replaces
-- the carried-in pet, so the chain self-corrects into normal order.
local function PetStepDone(rank) return petSummonedMax >= rank or PetRank() == rank end
local function HSStepDone(id, item) return Have(item) or hsPending[id] == true end

-- mount for the gate sprint (configurable so the addon is shareable)
local DEFAULT_MOUNT = "Red Skeletal Warhorse"
local OwnedMounts   -- forward decl; defined later (scans bags for mount items)
local function MountName()
    if LockPrepDB and LockPrepDB.mount then return LockPrepDB.mount end
    -- No explicit choice: auto-use the first ground mount found in the user's
    -- bags so the mount step works out of the box for anyone, not just the
    -- author. OwnedMounts() already filters out flying mounts (unusable in the
    -- arena). Falls back to a sensible name if the bag scan comes up empty.
    if OwnedMounts then
        local owned = OwnedMounts()
        if owned and owned[1] then return owned[1] end
    end
    return DEFAULT_MOUNT
end

-- Warlock class mounts are SPELLS you cast, not bag items you use, so they need
-- /cast instead of /use. Keyed by localized spell name.
local WARLOCK_MOUNT_IDS = { 5784, 23161 }   -- Summon Felsteed, Summon Dreadsteed
local WARLOCK_MOUNT_NAME = {
    [GetSpellInfo(5784) or "Summon Felsteed"]   = true,
    [GetSpellInfo(23161) or "Summon Dreadsteed"] = true,
}
-- The action line for the mount step: cast the warlock steed, or use an item mount.
local function MountMacro()
    local m = MountName()
    if WARLOCK_MOUNT_NAME[m] then return "/cast " .. m end
    return "/use " .. m
end

-- Whether we're in "ritual" mode: driven purely by the checkboxes (set via a
-- preset or by hand) - Ritual of Souls enabled and the manual pair disabled.
local function UseRitual()
    local d = LockPrepDB and LockPrepDB.disabled
    local ritualOn = not (d and d.ritual)
    local majorOn  = not (d and d.hsmajor)
    local masterOn = not (d and d.hsmaster)
    return ritualOn and not (majorOn or masterOn)
end
local ritualDone = false  -- set when Ritual of Souls is cast; reset each match
local RITUAL_NAME = GetSpellInfo(29893) or "Ritual of Souls"  -- 29893 = Ritual of Souls

-- generic "am I casting/channeling this spell right now" (by localized name)
local function IsCasting(spellName)
    return (UnitCastingInfo("player") == spellName) or (UnitChannelInfo("player") == spellName)
end

-- countdown ------------------------------------------------------------
-- gateAt is the GetTime() at which the gates open. Sources, either works:
--   * the "one minute / thirty seconds / fifteen seconds" arena emotes - this
--     is the timer that actually fires on this client and drove the original
--     (working) countdown. Once set, TimeLeft() counts down on its own via
--     GetTime(), so a single message is enough.
--   * START_TIMER - the game's own begin timer; used when it fires, but on the
--     Anniversary client it doesn't reliably show up, so we don't depend on it.
-- Whichever sets gateAt first wins; later messages just refine it.
local gateAt
local function TimeLeft()
    if not gateAt then return nil end
    local t = gateAt - GetTime()
    return (t < 0) and 0 or t
end

-- Soft time-gate for the time-sensitive finish (Felhunter + sac + Soul Link +
-- Shadow Ward + Tainted Blood + mount). Holds them until <= END_PREP_SECS left
-- so mashing early doesn't blow the fresh-shield/short-duration stuff. If no
-- countdown has been detected yet (gateAt nil) we allow it - never lock the user
-- out over a missing timer; order still applies via each step's own checks.
local END_PREP_SECS = 12
local function EndPrepReady()
    local t = TimeLeft()
    if t == nil then return true end
    return t <= END_PREP_SECS
end
local function InArena()
    local _, itype = IsInInstance()
    return itype == "arena"
end

local function Partners()
    local out = {}
    local total = GetNumGroupMembers() or 0
    -- party1..partyN (teammates); works for 2s/3s/5s
    for i = 1, math.max(0, total - 1) do out[i] = "party" .. i end
    return out
end

local function IsWarlock(unit)
    -- class comes from the group roster, so it's known even out of range /
    -- before the partner has zoned in
    local _, class = UnitClass(unit)
    return class == "WARLOCK"
end

-- Partners who actually need a healthstone FROM US. Warlocks conjure their own
-- (and never accept a traded one), so pestering them with the trade window just
-- jams the series. This is trade-only: buffs and Ritual of Souls still cover
-- warlock partners like everyone else.
local function StonePartners()
    local out = {}
    for _, u in ipairs(Partners()) do
        if not IsWarlock(u) then out[#out + 1] = u end
    end
    return out
end

-- per-match healthstone trade tracking (declared early; used by the UI)
-- We track by GUID (unique, realm-proof) so cross-realm skirmish partners are
-- matched correctly; tradedNames stays for the traded-count display.
local tradedNames = {}
local tradedGUIDs = {}
local tradeGUID                    -- GUID of the unit in the current trade window
local iAccepted = false            -- is OUR side of the trade accepted? (from TRADE_ACCEPT_UPDATE)
local partnerAccepted = false      -- the OTHER side's accept flag (TRADE_ACCEPT_UPDATE arg2)
local tradeCommitStones = 0        -- healthstones in OUR side seen while BOTH sides were accepted
local function TradedCount()
    local n = 0
    for _ in pairs(tradedNames) do n = n + 1 end
    return n
end
local function HasTraded(unit)
    local g = UnitGUID(unit)
    if g and tradedGUIDs[g] then return true end
    local name = UnitName(unit)
    return name ~= nil and tradedNames[name] == true
end
-- total healthstones currently in bags (used to detect a completed trade)
local function HSCount()
    return (GetItemCount(CFG.item.hsMajor) or 0) + (GetItemCount(CFG.item.hsMaster) or 0)
end

-- =====================================================================
-- Step groups (each can be toggled off in the options panel)
-- =====================================================================
local GROUPS = {
    { key = "hsmajor",      label = "Major Healthstone (2s)" },
    { key = "hsmaster",     label = "Master Healthstone (2s)" },
    { key = "ritual",       label = "Ritual of Souls (3s/5s)" },
    { key = "spellstone",   label = "Master Spellstone" },
    { key = "imp",          label = "Summon Imp" },
    { key = "felarmor",     label = "Fel Armor" },
    { key = "fireshield",   label = "Fire Shield" },
    { key = "unending",     label = "Unending Breath" },
    { key = "detectinvis",  label = "Detect Invisibility" },
    { key = "voidwalker",   label = "Summon Voidwalker" },
    { key = "felhunter",    label = "Summon Felhunter" },
    { key = "sacrifice",    label = "Sacrifice" },
    { key = "soullink",     label = "Soul Link" },
    { key = "shadowward",   label = "Shadow Ward" },
    { key = "taintedblood", label = "Tainted Blood" },
    { key = "mount",        label = "Mount" },
}

local function Enabled(group)
    if not group then return true end
    return not (LockPrepDB and LockPrepDB.disabled and LockPrepDB.disabled[group])
end

-- =====================================================================
-- Step model
-- =====================================================================
local steps = {}

local function BuildSteps()
    wipe(steps)
    local allies = Partners()
    local function add(t)
        if t.group and not Enabled(t.group) then return end
        steps[#steps + 1] = t
    end

    -- Healthstones. Which of these show is driven by the checkboxes (via presets):
    --  * 2s preset:   Major + Master on, Ritual off  -> conjure your pair, trade them
    --  * 3s/5s + BGs: Ritual on, pair off            -> one soulwell, team grabs stones
    -- (2s loop: once you trade a stone away it goes back to "not done" and the
    -- button re-offers it, so you make -> trade -> make ...).
    add({ id = "hs_major", group = "hsmajor", label = "Major Healthstone", macro = CFG.cast.hsMajor,
          castName = CREATE_HS_NAME,
          done = function() return HSStepDone("hs_major", CFG.item.hsMajor) end })
    add({ id = "hs_master", group = "hsmaster", label = "Master Healthstone", macro = CFG.cast.hsMaster,
          castName = CREATE_HS_NAME,
          done = function() return HSStepDone("hs_master", CFG.item.hsMaster) end })
    add({ id = "ritual", group = "ritual", label = "Ritual of Souls (soulwell for the team)", macro = CFG.cast.ritual,
          done = function() return ritualDone or Have(CFG.item.hsMaster) or Have(CFG.item.hsMajor) end })

    -- Spellstone: create it, then equip it in the wand/relic slot.
    -- (In TBC the spellstone is a wand-slot relic: passive +spell crit, plus an
    --  in-combat on-use that dispels all harmful magic. The dispel is a combat
    --  button, not a prep cast -- see /lp spellstone for a macro.)
    add({ id = "ss_make", group = "spellstone", label = "Create Master Spellstone", macro = CFG.cast.spellstone,
          done = function() return Have(CFG.item.spellstone) or IsEquippedItem(CFG.item.spellstone) end })
    add({ id = "ss_equip", group = "spellstone", label = "Equip Spellstone (wand slot)", macro = CFG.cast.equipSpellstone,
          done = function() return IsEquippedItem(CFG.item.spellstone) end,
          ready = function() return Have(CFG.item.spellstone) end })

    -- Imp (needed for Fire Shield)
    add({ id = "imp", group = "imp", label = "Summon Imp", macro = CFG.cast.summonImp,
          castName = SUMMON_NAME[1],
          done = function() return PetStepDone(1) end })

    -- Self buffs (Fel Armor first - it's your baseline armor buff)
    add({ id = "fa_self", group = "felarmor", label = "Fel Armor (you)", macro = CFG.cast.felArmor,
          done = function() return HasBuff("player", CFG.buff.felArmor) end })
    add({ id = "fs_self", group = "fireshield", label = "Fire Shield (you)", macro = CFG.cast.fireShield:format("player"),
          done = function() return HasBuff("player", CFG.buff.fireShield) end,
          ready = function() return PetFamily() == "Imp" end })
    add({ id = "ub_self", group = "unending", label = "Unending Breath (you)", macro = CFG.cast.unending:format("player"),
          done = function() return HasBuff("player", CFG.buff.unending) end })
    add({ id = "di_self", group = "detectinvis", label = "Detect Invisibility (you)", macro = CFG.cast.detectInvis:format("player"),
          done = function() return HasBuff("player", CFG.buff.detectInvis) end })

    -- Ally buffs (per partner, scales with 2s/3s/5s)
    for _, u in ipairs(allies) do
        add({ id = "fs_" .. u, group = "fireshield", label = "Fire Shield (" .. u .. ")", macro = CFG.cast.fireShield:format(u),
              done = function() return HasBuff(u, CFG.buff.fireShield) end,
              ready = function() return PetFamily() == "Imp" and UnitExists(u) end })
        add({ id = "ub_" .. u, group = "unending", label = "Unending Breath (" .. u .. ")", macro = CFG.cast.unending:format(u),
              done = function() return HasBuff(u, CFG.buff.unending) end,
              ready = function() return UnitExists(u) end })
        add({ id = "di_" .. u, group = "detectinvis", label = "Detect Invisibility (" .. u .. ")", macro = CFG.cast.detectInvis:format(u),
              done = function() return HasBuff(u, CFG.buff.detectInvis) end,
              ready = function() return UnitExists(u) end })
    end

    -- Voidwalker (for Sacrifice shield)
    add({ id = "vw", group = "voidwalker", label = "Summon Voidwalker", macro = CFG.cast.summonVoid,
          castName = SUMMON_NAME[2],
          done = function() return PetStepDone(2) end })

    -- Timed finish -----------------------------------------------------
    -- Felhunter + sac gate on STATE, not the clock: as soon as the voidwalker is
    -- out it's time to swap. Sac/Soul Link buffs persist, so no need to wait for
    -- the countdown. (If you trade your stones away, the healthstone step jumps
    -- back ahead of this in the order, so the button re-offers a stone first.)
    -- Ready once the voidwalker is out (arena sac flow); but if the voidwalker
    -- step is turned off (e.g. the BGs preset), go straight imp -> felhunter.
    -- We use petSummonedMax (not just the live PetRank) so the step stays ready
    -- through the no-pet gap: when you sacrifice the VW mid-summon the pet is
    -- gone for a beat, and a live-only check would drop Felhunter's readiness and
    -- skip ahead to Shadow Ward. Once you've had a VW this match, Felhunter is
    -- always reachable (and re-offered if the summon gets cut after the sac).
    -- No castName here: the Felhunter cast has its own handling in Refresh
    -- (felCastFrac) which offers the Voidwalker sac mid-cast.
    add({ id = "fh", group = "felhunter", label = "Summon Felhunter", macro = CFG.cast.summonFel,
          done = function() return PetStepDone(3) end,
          ready = function() return EndPrepReady()
                    and (PetRank() >= 2 or petSummonedMax >= 2 or not Enabled("voidwalker")) end })
    add({ id = "sac", group = "sacrifice", label = "Sacrifice VW (during Felhunter cast!)", macro = CFG.cast.sacrifice,
          done = function() return HasBuff("player", CFG.buff.sacrifice) or PetRank() >= 3 end,
          ready = function() return EndPrepReady() and PetFamily() == "Voidwalker" end })
    -- Ready check tolerates the felhunter spawn gap (petSummonedMax>=3): right
    -- after the summon lands the pet isn't UnitExists yet, and a live-only check
    -- would let Shadow Ward jump ahead of Soul Link. A press before the pet is
    -- up just no-ops (no demon = no GCD) and retries on the next mash.
    add({ id = "sl", group = "soullink", label = "Soul Link", macro = CFG.cast.soulLink,
          done = function() return HasBuff("player", CFG.buff.soulLink) end,
          ready = function() return EndPrepReady()
                    and (PetFamily() == "Felhunter" or petSummonedMax >= 3) end })
    -- These last steps are order-gated only (no countdown timing). The gate
    -- countdown on the Anniversary client is unreliable to parse, and mistiming
    -- these costs mana, so we just enforce order and let you press them when the
    -- gate is about to open -- same as the rest of the routine.
    add({ id = "sw", group = "shadowward", label = "Shadow Ward", macro = CFG.cast.shadowWard,
          done = function() return HasBuff("player", CFG.buff.shadowWard) end,
          ready = EndPrepReady })
    -- Tainted Blood MUST come before the mount: you can't use any ability
    -- (yours or the pet's) while mounted. Pet abilities don't share your GCD,
    -- so it's fine right alongside Shadow Ward.
    add({ id = "tb", group = "taintedblood", label = "Tainted Blood", macro = CFG.cast.taintedBlood,
          done = function() return HasBuff("pet", CFG.buff.taintedBlood) end,
          ready = function() return EndPrepReady()
                    and (PetFamily() == "Felhunter" or petSummonedMax >= 3) end })
    -- Mount is the very last thing (mounting locks out all abilities).
    add({ id = "mount", group = "mount", label = "Mount up (" .. MountName() .. ")", macro = MountMacro(),
          done = function() return IsMounted() end,
          ready = EndPrepReady })
end

local function FirstIncomplete()
    for _, s in ipairs(steps) do
        if not s.done() then
            if (not s.ready) or s.ready() then return s end
        end
    end
end

-- =====================================================================
-- Secure "next step" button
-- =====================================================================
-- Kept shown (tiny, transparent, mouse-off) -- hidden secure buttons can fail
-- to trigger from keybinds/click.
local button = CreateFrame("Button", "LockPrepButton", UIParent, "SecureActionButtonTemplate")
button:SetSize(1, 1)
button:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
button:SetAlpha(0)
button:EnableMouse(false)
button:RegisterForClicks("AnyDown") -- CLICK keybinds fire on key-down
button:SetAttribute("type", "macro")

-- Spellstone swap button. Smart toggle on one keybind:
--   * stone equipped  -> dispel (off-GCD) + swap wand in
--   * wand equipped   -> re-equip the stone (arms the 30s equip cooldown so the
--                        next press can dispel)
-- The stone is equipped during prep, so its equip CD is already gone by the
-- gates and the first press dispels immediately.
local ssButton = CreateFrame("Button", "LockPrepSpellstoneButton", UIParent, "SecureActionButtonTemplate")
ssButton:SetSize(1, 1)
ssButton:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
ssButton:SetAlpha(0)
ssButton:EnableMouse(false)
ssButton:RegisterForClicks("AnyDown") -- single fire so the toggle doesn't undo itself
ssButton:SetAttribute("type", "macro")

local function SpellstoneMacro()
    local wand = LockPrepDB and LockPrepDB.wand
    if wand and wand ~= "" then
        return "/use [noequipped:Wand] " .. CFG.item.spellstone ..
             "\n/equip [equipped:Wand] " .. CFG.item.spellstone ..
             "\n/equip [noequipped:Wand] " .. wand
    end
    -- no wand set yet: just dispel with the equipped stone
    return "/use " .. CFG.item.spellstone
end

local function UpdateSpellstoneButton()
    if InCombatLockdown() then return end
    ssButton:SetAttribute("macrotext", SpellstoneMacro())
end

local currentId
local function HaveAnyStone()
    return Have(CFG.item.hsMajor) or Have(CFG.item.hsMaster)
end

-- Felhunter-summon awareness: while you're casting Summon Felhunter we hand the
-- button the Voidwalker Sacrifice (the classic "sac during the felpup cast"),
-- and expose the cast progress so the checklist can show a % / "SAC NOW" cue.
local FEL_NAME = GetSpellInfo(691) or "Summon Felhunter"  -- 691 = Summon Felhunter
local felCastFrac = nil   -- 0..1 while summoning felhunter, else nil (read by UI)
local felAction = nil     -- action-line override while sac is offered
local function SacDone()
    return HasBuff("player", CFG.buff.sacrifice) or PetRank() >= 3
end
local function FelSummonProgress()
    local name, _, _, startMs, endMs = UnitCastingInfo("player")
    if not name or name ~= FEL_NAME then return nil end
    if not startMs or not endMs or endMs <= startMs then return 0 end
    local frac = (GetTime() * 1000 - startMs) / (endMs - startMs)
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    return frac
end

local function Refresh()
    if #steps == 0 then BuildSteps() end
    -- Drop a healthstone pending-latch the instant the real stone lands, so the
    -- 2s make -> trade -> make loop re-offers with no delay. (Pet ranks are
    -- monotonic for the match and reset on a new arena.)
    if hsPending.hs_major and Have(CFG.item.hsMajor) then hsPending.hs_major = nil end
    if hsPending.hs_master and Have(CFG.item.hsMaster) then hsPending.hs_master = nil end
    local step = FirstIncomplete()
    local macro = step and step.macro or ""
    felCastFrac = FelSummonProgress()
    felAction = nil
    if IsCasting(RITUAL_NAME) then
        -- Ritual of Souls in progress: cast nothing so a stray press can't
        -- interrupt the channel (teammates need the soulwell to finish).
        macro = ""
        currentId = "ritual"
    elseif felCastFrac then
        -- mid-felhunter-summon: offer the VW sac (if enabled, not yet done, and
        -- the voidwalker is still out), otherwise cast nothing so a stray press
        -- can't interrupt the summon.
        if Enabled("sacrifice") and not SacDone() and PetFamily() == "Voidwalker" then
            macro = CFG.cast.sacrifice
            currentId = "sac"
            felAction = "Sacrifice Voidwalker!"
        else
            macro = ""
            currentId = nil
        end
    elseif step and step.castName and IsCasting(step.castName) then
        -- Mid-cast on this step's OWN spell (summon / conjure): cast nothing so a
        -- mashed press can't queue a duplicate in the spell-queue window. Keep
        -- currentId pointed at the step so cast-SUCCESS latches the right tier.
        macro = ""
        currentId = step.id
    else
        currentId = step and step.id or nil
    end
    -- While a trade window is open and we still owe an accept, the button's only
    -- job is to accept (handled in PreClick), so blank the prep cast. But once
    -- WE'VE accepted (our stone is in, waiting on them), un-blank so you can keep
    -- prepping while they take their time -- casting doesn't cancel the trade, and
    -- if they never accept you're not jammed. (If they change the trade our accept
    -- resets, iAccepted flips false, and we blank again to re-accept.)
    if TradeFrame and TradeFrame:IsShown() and not iAccepted then
        macro = ""
    end
    if not InCombatLockdown() then
        button:SetAttribute("macrotext", macro)
    end
    if LockPrep_UpdateUI then LockPrep_UpdateUI() end
end

-- =====================================================================
-- UI: checklist overlay
-- =====================================================================
local ui = CreateFrame("Frame", "LockPrepFrame", UIParent, "BackdropTemplate")
ui:SetSize(300, 120)
ui:SetPoint("CENTER", UIParent, "CENTER", 350, 0)
ui:SetBackdrop({
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
})
ui:SetBackdropColor(0.05, 0.05, 0.07, 0.92)
ui:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
ui:SetMovable(true)
ui:EnableMouse(true)
ui:RegisterForDrag("LeftButton")
ui:SetClampedToScreen(true)
ui:SetScript("OnDragStart", function(self) if not self.locked then self:StartMoving() end end)
ui:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, r, x, y = self:GetPoint()
    LockPrepDB = LockPrepDB or {}
    LockPrepDB.pos = { p, r, x, y }
end)
ui:Hide()

local header = ui:CreateFontString(nil, "OVERLAY", "GameFontNormal")
header:SetPoint("TOPLEFT", 10, -8)
header:SetText("LockPrep  |cff888888(right-click: options)|r")

local countdownFS = ui:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
countdownFS:SetPoint("TOPRIGHT", -10, -6)
countdownFS:SetText("")

-- The big "what to press" line -- this is the whole point of the window.
local actionFS = ui:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
actionFS:SetPoint("TOPLEFT", 10, -26)
actionFS:SetPoint("RIGHT", ui, "RIGHT", -8, 0)
actionFS:SetJustifyH("LEFT")
actionFS:SetText("")

-- healthstone trade progress ("Stones traded: 1/2")
local tradeFS = ui:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
tradeFS:SetPoint("TOPLEFT", actionFS, "BOTTOMLEFT", 0, -3)
tradeFS:SetPoint("RIGHT", ui, "RIGHT", -8, 0)
tradeFS:SetJustifyH("LEFT")
tradeFS:SetText("")

-- felhunter summon progress ("Felhunter summon: 87%  SAC NOW")
local castFS = ui:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
castFS:SetPoint("TOPLEFT", tradeFS, "BOTTOMLEFT", 0, -2)
castFS:SetPoint("RIGHT", ui, "RIGHT", -8, 0)
castFS:SetJustifyH("LEFT")
castFS:SetText("")

local rows = {}
local function GetRow(i)
    local r = rows[i]
    if r then return r end
    r = ui:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r:SetJustifyH("LEFT")
    r:SetWordWrap(true)
    -- stack each row under the previous one's actual bottom, so a wrapped
    -- (two-line) label pushes everything below it down instead of overlapping
    if i == 1 then
        r:SetPoint("TOPLEFT", castFS, "BOTTOMLEFT", 0, -4)
    else
        r:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, -3)
    end
    r:SetPoint("RIGHT", ui, "RIGHT", -8, 0)
    rows[i] = r
    return r
end

local function BoundKey()
    return GetBindingKey("CLICK LockPrepButton:LeftButton")
end

function LockPrep_UpdateUI()
    if not ui:IsShown() then return end
    -- countdown
    local t = TimeLeft()
    if t then
        countdownFS:SetText(string.format("0:%02d", math.floor(t + 0.5)))
        countdownFS:SetTextColor(1, t <= 5 and 0.4 or 0.82, t <= 5 and 0.4 or 0)
    else
        countdownFS:SetText("")
    end

    local shown, curLabel, anyIncomplete = 0, nil, false
    for i, s in ipairs(steps) do
        local row = GetRow(i)
        local done = s.done()
        local ready = (not s.ready) or s.ready()
        if not done then anyIncomplete = true end
        if s.id == currentId then curLabel = s.label end
        local mark, r, g, b
        if done then
            mark, r, g, b = "|cff55ff55v|r ", 0.5, 0.5, 0.5
        elseif s.id == currentId then
            mark, r, g, b = "|cffffff00> |r", 1, 1, 0.3
        elseif not ready then
            mark, r, g, b = "|cff888888. |r", 0.55, 0.55, 0.6
        else
            mark, r, g, b = "|cffcccccc. |r", 0.8, 0.8, 0.8
        end
        row:SetText(mark .. s.label)
        row:SetTextColor(r, g, b)
        row:Show()
        shown = i
    end
    for i = shown + 1, #rows do rows[i]:Hide() end

    -- action line: tells a new user exactly what to do
    local key = BoundKey()
    if not key then
        actionFS:SetText("|cffff6666No key bound|r  -  type  |cffffffff/lp bind <KEY>|r")
    elseif felAction then
        actionFS:SetText("Press |cff00ff00" .. key .. "|r: |cffff5555" .. felAction .. "|r")
    elseif curLabel then
        actionFS:SetText("Press |cff00ff00" .. key .. "|r: " .. curLabel)
    elseif anyIncomplete then
        local t = TimeLeft()
        if t and t > END_PREP_SECS then
            actionFS:SetText(string.format("|cffaaaaaaHolding the finish until %ds left (%ds)|r",
                END_PREP_SECS, math.floor(t + 0.5)))
        else
            actionFS:SetText("|cffaaaaaaWaiting for the countdown...|r")
        end
    else
        actionFS:SetText("|cff55ff55All set - good luck!|r")
    end

    -- felhunter summon progress bar-as-text (turns green past 90%)
    if felCastFrac then
        local pct = math.floor(felCastFrac * 100 + 0.5)
        local col = (felCastFrac >= 0.90) and "|cff55ff55" or "|cffffcc44"
        local tag = (felCastFrac >= 0.90) and "  <SAC!>" or ""
        castFS:SetText(col .. "Felhunter summon: " .. pct .. "%" .. tag .. "|r")
    else
        castFS:SetText("")
    end

    -- trade progress (2s only; in 3s/5s people grab from the soulwell)
    -- count only warlock-free partners - a warlock partner never needs a stone
    local partners = #StonePartners()
    if UseRitual() then
        tradeFS:SetText(ritualDone and "|cff55ff55Soulwell up - team grabs their own|r" or "")
    elseif partners > 0 then
        local n = TradedCount()
        local col = (n >= partners) and "|cff55ff55" or "|cff88ccff"
        tradeFS:SetText(col .. "Healthstones traded: " .. n .. "/" .. partners .. "|r")
    else
        tradeFS:SetText("")
    end

    -- size the window to the real (possibly wrapped) content height
    local h = 8 + 16 + 4 + (actionFS:GetStringHeight() or 16) + 3 + (tradeFS:GetStringHeight() or 0)
        + 2 + (castFS:GetStringHeight() or 0) + 4
    for i = 1, shown do h = h + (rows[i]:GetStringHeight() or 12) + 3 end
    ui:SetHeight(h + 8)
end

-- =====================================================================
-- Show / hide
-- =====================================================================
local function ApplyPos()
    ui:ClearAllPoints()
    local p = LockPrepDB and LockPrepDB.pos
    if p then ui:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else ui:SetPoint("CENTER", UIParent, "CENTER", 350, 0) end
end

local function ShowUI()
    BuildSteps(); ApplyPos(); Refresh(); ui:Show()
end
local function HideUI() ui:Hide() end

-- =====================================================================
-- Trade auto-fill: drop your healthstones into the trade window.
-- Filling the trade window is NOT a protected action (this is how
-- TradeDispenser etc. work), so it runs from the TRADE_SHOW event. You
-- still click Accept yourself (AcceptTrade needs a real click).
-- =====================================================================
local tradeArmed = false      -- one-shot arm, for testing outside an arena
local tradeHadStones = false  -- did we put stones in the current trade?
local tradePartner = nil      -- who we're trading with (captured at TRADE_SHOW)
local tradeStartHS = 0        -- healthstone count when the trade opened
-- (iAccepted is declared earlier, near the trade-tracking state, so Refresh can read it)
local tradeFilledAt = 0       -- when we auto-filled; wait a beat before accepting
local TRADE_SETTLE = 0.4      -- so the item-placement confirms land before we accept
-- (tradedNames / TradedCount / HSCount are declared earlier, near Partners())

-- container API works via C_Container (modern) or legacy globals
local C = _G.C_Container
local GetNumSlots = (C and C.GetContainerNumSlots) or GetContainerNumSlots
local GetItemLink = (C and C.GetContainerItemLink) or GetContainerItemLink
local PickupItem  = (C and C.PickupContainerItem) or PickupContainerItem

local function AutoTradeOn()
    return not (LockPrepDB and LockPrepDB.autoTrade == false)
end

-- window is OFF by default now (toggle via the minimap icon). Opt in to have it
-- pop automatically when you zone into an arena.
local function AutoShowOn()
    return LockPrepDB and LockPrepDB.autoShow == true
end

local function FindBagItem(name)
    for bag = 0, 4 do
        local slots = GetNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetItemLink(bag, slot)
            if link and link:find(name, 1, true) then
                return bag, slot
            end
        end
    end
end

local function PlaceInTrade(name, tradeSlot)
    local bag, slot = FindBagItem(name)
    if not bag then return false end
    ClearCursor()
    PickupItem(bag, slot)
    ClickTradeButton(tradeSlot)
    ClearCursor()
    return true
end

local function FillTrade()
    tradeArmed = false
    local placed = 0
    if PlaceInTrade(CFG.item.hsMajor, 1) then placed = placed + 1 end
    if PlaceInTrade(CFG.item.hsMaster, 2) then placed = placed + 1 end
    tradeHadStones = placed > 0
    if placed > 0 then
        tradeFilledAt = GetTime()   -- let the placement confirms settle before we accept
        print("|cffcc66ffLockPrep|r: placed " .. placed .. " healthstone(s) - keep pressing your button to accept")
    else
        print("|cffcc66ffLockPrep|r: no healthstones in bags to trade (conjure a pair first)")
    end
end

-- How many of MY offered trade items are healthstones (so we only accept a
-- trade that actually has the stones in it).
local function StonesInTrade()
    local n = 0
    for i = 1, 7 do
        local link = GetTradePlayerItemLink and GetTradePlayerItemLink(i)
        if link and link:find("Healthstone", 1, true) then n = n + 1 end
    end
    return n
end

-- Is the person we're trading with actually one of our teammates? (Never
-- auto-accept a stranger's trade - only stones we placed or a teammate's gift.)
local function TradeFromTeammate()
    local g = UnitGUID("npc")
    if not g then return false end
    for _, u in ipairs(Partners()) do
        if UnitGUID(u) == g then return true end
    end
    return false
end

-- Has the other side actually put an item in yet? Stops us from accepting an
-- empty window the instant a teammate opens it (before they drop the food in).
local function TargetHasItems()
    for i = 1, 7 do
        if GetTradeTargetItemLink and GetTradeTargetItemLink(i) then return true end
    end
    return false
end

-- First partner (2s: party1) who still needs a stone. Skips anyone already
-- traded this match and anyone not currently present.
local function NextTradePartner()
    -- StonePartners() excludes warlocks (they make their own), so we never open
    -- a trade window with a partner who'll never accept it.
    for _, u in ipairs(StonePartners()) do
        if UnitExists(u) and not HasTraded(u) then
            return u, UnitName(u)
        end
    end
end

-- Fold trade handling into the SPAM key. PreClick runs on the same hardware
-- press (before the secure cast), so mashing your normal button:
--   * accepts an open stone-trade (AcceptTrade), and
--   * opens a trade with the next partner who needs a stone (InitiateTrade).
-- Both are legal from this hardware context; InitiateTrade(unit) does NOT change
-- your target, so you keep pressing through the rest of prep uninterrupted.
local lastInitiate = 0
local lastTradeClosed = 0        -- set on TRADE_CLOSED; blocks an instant empty re-open
local TRADE_REOPEN_CD = 1.5      -- > the 0.4s bag-drop confirm, with margin for bag lag
button:SetScript("PreClick", function()
    -- 1) a trade is already open -> accept it if our stones are in. AcceptTrade()
    -- TOGGLES, so calling it again while already accepted un-accepts you (green ->
    -- gray flicker). Only accept when our side isn't accepted yet; iAccepted is
    -- kept in sync from TRADE_ACCEPT_UPDATE. (The prep cast is blanked in Refresh
    -- while the window is up, so a mash here only accepts.)
    if TradeFrame and TradeFrame:IsShown() then
        -- Only accept when Blizzard's Accept button is actually enabled. If the
        -- other side adds/changes items (a mage handing back food/water), WoW
        -- un-accepts both sides and locks the button for a few seconds (anti-scam
        -- countdown); mashing AcceptTrade() through that is what caused the "-1" /
        -- stuck states. We just wait it out, then accept once when it clears.
        local acceptBtn = _G.TradeFrameTradeButton
        local canAccept = (not acceptBtn) or acceptBtn:IsEnabled()
        -- Accept when EITHER our stones are in (the give flow) OR a teammate has
        -- put something in for us (food/water back). Never a stranger, never an
        -- empty window.
        local shouldAccept = StonesInTrade() > 0
                             or (TradeFromTeammate() and TargetHasItems())
        if shouldAccept and not iAccepted and canAccept
           and (GetTime() - tradeFilledAt) > TRADE_SETTLE then
            iAccepted = true          -- optimistic; TRADE_ACCEPT_UPDATE corrects it
            AcceptTrade()
        end
        return
    end
    -- 2) 2s only: we hold a stone and a partner still needs one -> open the trade.
    -- The close cooldown covers the gap right after a trade completes: the stone
    -- has left the bags but HasTraded() isn't recorded until the bag-drop confirm
    -- lands (~0.4s later), so without it a mash would re-open an empty trade with
    -- the partner we just finished with.
    if AutoTradeOn() and InArena() and not UseRitual() and HaveAnyStone()
       and (GetTime() - lastInitiate) > 1.0
       and (GetTime() - lastTradeClosed) > TRADE_REOPEN_CD then
        local u = NextTradePartner()
        if u then
            lastInitiate = GetTime()
            InitiateTrade(u)
        end
    end
end)

-- Optional standalone accept key (same guard) for anyone who wants a dedicated bind.
local acceptBtn = CreateFrame("Button", "LockPrepAcceptButton", UIParent)
acceptBtn:RegisterForClicks("AnyDown")
acceptBtn:SetScript("OnClick", function()
    if not (TradeFrame and TradeFrame:IsShown()) then
        print("|cffcc66ffLockPrep|r: no trade window open")
        return
    end
    if StonesInTrade() > 0 then
        AcceptTrade()
    else
        print("|cffcc66ffLockPrep|r: no healthstone in the trade yet - not accepting")
    end
end)

-- =====================================================================
-- Options panel (checkboxes to include/exclude step groups)
-- =====================================================================
local opt = CreateFrame("Frame", "LockPrepOptions", UIParent, "BackdropTemplate")
opt:SetSize(300, 60 + #GROUPS * 22 + 248)
opt:SetPoint("CENTER")
opt:SetBackdrop({
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
})
opt:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
opt:SetBackdropBorderColor(0.4, 0.3, 0.5, 1)
opt:SetMovable(true); opt:EnableMouse(true); opt:RegisterForDrag("LeftButton")
opt:SetScript("OnDragStart", opt.StartMoving)
opt:SetScript("OnDragStop", opt.StopMovingOrSizing)
opt:SetFrameStrata("DIALOG")
opt:Hide()

local otitle = opt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
otitle:SetPoint("TOPLEFT", 12, -10)
otitle:SetText("LockPrep - steps to include")

local oclose = CreateFrame("Button", nil, opt, "UIPanelCloseButton")
oclose:SetPoint("TOPRIGHT", 2, 2)

local groupChecks = {}  -- key -> checkbox, so presets can refresh their state
for i, g in ipairs(GROUPS) do
    local cb = CreateFrame("CheckButton", nil, opt, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetPoint("TOPLEFT", 12, -34 - (i - 1) * 22)
    local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    lbl:SetText(g.label)
    cb:SetScript("OnShow", function(self) self:SetChecked(Enabled(g.key)) end)
    cb:SetScript("OnClick", function(self)
        LockPrepDB = LockPrepDB or {}
        LockPrepDB.disabled = LockPrepDB.disabled or {}
        LockPrepDB.disabled[g.key] = (not self:GetChecked()) or nil
        LockPrepDB.preset = "custom"  -- hand-edited => "Custom"
        if LockPrepPresetDropDown then UIDropDownMenu_SetText(LockPrepPresetDropDown, "Custom") end
        BuildSteps(); Refresh()
    end)
    groupChecks[g.key] = cb
end

-- Presets: one click sets a whole configuration of checkboxes.
-- Major Healthstone + Master Spellstone are left OFF in every preset (personal
-- preference); tick them yourself if you use them.
local PRESETS = {
    ["2s"]   = { label = "2s",     disabled = { hsmajor = true, spellstone = true, ritual = true } },
    ["3s5s"] = { label = "3s / 5s", disabled = { hsmajor = true, hsmaster = true, spellstone = true } },
    ["bg"]   = { label = "BGs",    disabled = { hsmajor = true, hsmaster = true, spellstone = true, taintedblood = true, voidwalker = true, sacrifice = true, shadowward = true } },
    -- "custom" has no preset table: it leaves your checkboxes exactly as they are
    -- so you can tick whatever you want. (Hand-editing any box also flips to this.)
    ["custom"] = { label = "Custom", custom = true },
}
local PRESET_ORDER = { "2s", "3s5s", "bg", "custom" }

local function RefreshGroupChecks()
    for key, cb in pairs(groupChecks) do cb:SetChecked(Enabled(key)) end
end

local function ApplyPreset(key)
    local p = PRESETS[key]; if not p then return end
    LockPrepDB = LockPrepDB or {}
    -- "custom" keeps the current checkbox states; other presets overwrite them.
    if not p.custom then
        LockPrepDB.disabled = {}
        for grp, v in pairs(p.disabled) do LockPrepDB.disabled[grp] = v end
    end
    LockPrepDB.preset = key
    RefreshGroupChecks()
    BuildSteps(); Refresh()
end

-- extras section: auto-trade toggle
local extraY = -34 - #GROUPS * 22 - 4
local sep = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
sep:SetPoint("TOPLEFT", 12, extraY)
sep:SetText("|cff888888Extras|r")
local atcb = CreateFrame("CheckButton", nil, opt, "UICheckButtonTemplate")
atcb:SetSize(22, 22)
atcb:SetPoint("TOPLEFT", 12, extraY - 16)
local atlbl = atcb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
atlbl:SetPoint("LEFT", atcb, "RIGHT", 2, 0)
atlbl:SetText("Auto-fill healthstones on trade (arena)")
atcb:SetScript("OnShow", function(self) self:SetChecked(AutoTradeOn()) end)
atcb:SetScript("OnClick", function(self)
    LockPrepDB = LockPrepDB or {}
    LockPrepDB.autoTrade = self:GetChecked() and true or false
end)

local ascb = CreateFrame("CheckButton", nil, opt, "UICheckButtonTemplate")
ascb:SetSize(22, 22)
ascb:SetPoint("TOPLEFT", 12, extraY - 38)
local aslbl = ascb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
aslbl:SetPoint("LEFT", ascb, "RIGHT", 2, 0)
aslbl:SetText("Auto-show window when entering an arena")
ascb:SetScript("OnShow", function(self) self:SetChecked(AutoShowOn()) end)
ascb:SetScript("OnClick", function(self)
    LockPrepDB = LockPrepDB or {}
    LockPrepDB.autoShow = self:GetChecked() and true or false
end)

-- Presets dropdown: pick 2s / 3s-5s / BGs and it checks/unchecks the right boxes
local function PresetText()
    local key = LockPrepDB and LockPrepDB.preset
    local p = key and PRESETS[key]
    return p and p.label or "Custom"
end

local pslbl = opt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
pslbl:SetPoint("TOPLEFT", 16, extraY - 68)
pslbl:SetText("Preset:")

-- dropdown sits below its label (labels get cut off if placed beside it)
local psdd = CreateFrame("Frame", "LockPrepPresetDropDown", opt, "UIDropDownMenuTemplate")
psdd:SetPoint("TOPLEFT", 0, extraY - 86)
UIDropDownMenu_SetWidth(psdd, 200)
UIDropDownMenu_Initialize(psdd, function(self, level)
    for _, key in ipairs(PRESET_ORDER) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = PRESETS[key].label
        info.checked = ((LockPrepDB and LockPrepDB.preset) == key)
        info.func = function()
            ApplyPreset(key)
            UIDropDownMenu_SetText(psdd, PresetText())
        end
        UIDropDownMenu_AddButton(info, level)
    end
end)
psdd:SetScript("OnShow", function() UIDropDownMenu_SetText(psdd, PresetText()) end)

-- mount selector: pick from your learned mounts (or /lp mount <name>)
local mlbl = opt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
mlbl:SetPoint("TOPLEFT", 16, extraY - 128)
mlbl:SetText("Gate mount:")

local mdd = CreateFrame("Frame", "LockPrepMountDropDown", opt, "UIDropDownMenuTemplate")
mdd:SetPoint("TOPLEFT", 0, extraY - 146)
UIDropDownMenu_SetWidth(mdd, 200)

local function SetMount(name)
    LockPrepDB = LockPrepDB or {}
    -- store exactly what was picked; auto-detect only applies when nothing is
    -- saved (use /lp mount reset to clear back to auto)
    LockPrepDB.mount = name
    UIDropDownMenu_SetText(mdd, MountName())
    BuildSteps(); Refresh()
end

-- Flying mounts can't be summoned in the arena, and bag items don't flag ground
-- vs flying. But TBC's mount naming is consistent: every flying mount is a
-- gryphon, wind rider, nether drake, nether ray, hippogryph, flying machine, or
-- Ashes of Al'ar - and no ground mount uses any of those words. So we exclude on
-- keywords (this also covers the arena Nether Drakes a PvP player will own).
-- If someone really wants a flying mount here, /lp mount <name> still sets it.
local FLYING_MOUNT_KEYWORDS = {
    "gryphon", "wind rider", "nether drake", "netherwing",
    "nether ray", "hippogryph", "flying machine", "al'ar",
}
local function IsFlyingMountName(name)
    local lc = name:lower()
    for _, kw in ipairs(FLYING_MOUNT_KEYWORDS) do
        if lc:find(kw, 1, true) then return true end
    end
    return false
end

-- collect owned mounts. In TBC (2.5.x) mounts are ITEMS in your bags, not
-- entries in the WotLK+ companion journal, so scan the bags. We also fold in
-- any learned companions in case this ever runs on a later client.
-- Flying mounts are filtered out (see IsFlyingMountName) since they can't be
-- used in the arena.
OwnedMounts = function()
    local names, seen = {}, {}
    local function addName(nm)
        if nm and nm ~= "" and not seen[nm] and not IsFlyingMountName(nm) then
            seen[nm] = true; names[#names + 1] = nm
        end
    end
    -- learned mounts (usually empty in TBC)
    local n = (GetNumCompanions and GetNumCompanions("MOUNT")) or 0
    for i = 1, n do
        local _, cname = GetCompanionInfo("MOUNT", i)
        addName(cname)
    end
    -- mount items in bags (classID 15 = Miscellaneous, subclassID 5 = Mount)
    for bag = 0, 4 do
        local slots = (GetNumSlots and GetNumSlots(bag)) or 0
        for slot = 1, slots do
            local link = GetItemLink and GetItemLink(bag, slot)
            if link then
                local isMount = false
                if GetItemInfoInstant then
                    local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(link)
                    isMount = (classID == 15 and subclassID == 5)
                end
                if not isMount then
                    local _, _, _, _, _, _, subclass = GetItemInfo(link)
                    isMount = (subclass == "Mount")
                end
                if isMount then
                    addName((GetItemInfo(link)) or link:match("%[(.-)%]"))
                end
            end
        end
    end
    -- warlock class mounts (spells, not bag items) if the player knows them
    for _, id in ipairs(WARLOCK_MOUNT_IDS) do
        if not IsSpellKnown or IsSpellKnown(id) then
            addName(GetSpellInfo(id))
        end
    end
    table.sort(names)
    return names
end

UIDropDownMenu_Initialize(mdd, function(self, level)
    local names = OwnedMounts()
    local current = MountName()   -- resolve once (may scan bags) instead of per entry
    for _, cname in ipairs(names) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = cname
        info.checked = (current == cname)
        info.func = function() SetMount(cname) end
        UIDropDownMenu_AddButton(info, level)
    end
    if #names == 0 then
        local info = UIDropDownMenu_CreateInfo()
        info.text = "no mounts found - use /lp mount <name>"
        info.disabled = true; info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)
    end
end)
mdd:SetScript("OnShow", function() UIDropDownMenu_SetText(mdd, MountName()) end)

-- keybind: laid out like the Preset / Gate mount controls (label, then a box)
local kblbl = opt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
kblbl:SetPoint("TOPLEFT", 16, extraY - 188)
kblbl:SetText("Keybind:")

local kbhint = opt:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
kbhint:SetPoint("LEFT", kblbl, "RIGHT", 6, 0)
kbhint:SetText("click button, press key you want to use")

local keyRows = {}

local IGNORE_KEYS = {
    LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
    LALT = true, RALT = true, UNKNOWN = true,
}
local function KeyChord(key)
    if not key or IGNORE_KEYS[key] then return nil end
    local m = ""
    if IsAltKeyDown()     then m = m .. "ALT-"   end
    if IsControlKeyDown() then m = m .. "CTRL-"  end
    if IsShiftKeyDown()   then m = m .. "SHIFT-" end
    return m .. key
end

local function RefreshKeyButtons()
    for _, row in ipairs(keyRows) do
        if not row.listening then
            local k = GetBindingKey(row.action)
            row.btn:SetText(k or "|cff888888Not bound|r")
        end
    end
end

local function StopListening(row)
    row.listening = false
    row.btn:EnableKeyboard(false)
    row.btn:EnableMouseWheel(false)
    row.btn:SetPropagateKeyboardInput(true)
    row.btn:SetButtonState("NORMAL")   -- release the stuck "pressed" look
    row.btn:UnlockHighlight()
    row.btn:SetScript("OnKeyDown", nil)
    row.btn:SetScript("OnMouseWheel", nil)
    row.btn:SetScript("OnMouseUp", nil)
    RefreshKeyButtons()
end

local function ApplyKey(row, keyStr)
    if not keyStr then return end
    local old1, old2 = GetBindingKey(row.action)   -- clear this action's old key(s)
    if old1 then SetBinding(old1) end
    if old2 then SetBinding(old2) end
    SetBindingClick(keyStr, row.button)
    SaveBindings(GetCurrentBindingSet())
    StopListening(row)
    print("|cffcc66ffLockPrep|r: bound |cffffffff" .. keyStr .. "|r to " .. row.label)
end

local function StartListening(row)
    for _, r in ipairs(keyRows) do
        if r ~= row and r.listening then StopListening(r) end
    end
    row.listening = true
    row.btn:SetText("|cffffff00Press a key...|r")
    row.btn:EnableKeyboard(true)
    row.btn:EnableMouseWheel(true)
    row.btn:SetScript("OnKeyDown", function(self, key)
        self:SetPropagateKeyboardInput(false)
        if key == "ESCAPE" then StopListening(row); return end
        local chord = KeyChord(key)
        if chord then ApplyKey(row, chord) end
    end)
    row.btn:SetScript("OnMouseWheel", function(_, delta)
        ApplyKey(row, (delta > 0) and "MOUSEWHEELUP" or "MOUSEWHEELDOWN")
    end)
    row.btn:SetScript("OnMouseUp", function(_, mbtn)
        if mbtn == "LeftButton" then return end   -- left starts listening
        local map = { RightButton = "BUTTON2", MiddleButton = "BUTTON3",
                      Button4 = "BUTTON4", Button5 = "BUTTON5" }
        local b = map[mbtn]
        if b then ApplyKey(row, KeyChord(b)) end
    end)
end

local function MakeKeyRow(labelText, buttonName, yoff)
    local btn = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate")
    btn:SetSize(200, 24)
    btn:SetPoint("TOPLEFT", 16, yoff)
    local nt = btn:GetNormalTexture()
    if nt then nt:SetVertexColor(0.85, 0.3, 0.3) end   -- red tint, keeps the button border/texture
    local row = {
        label  = labelText,
        button = buttonName,
        action = "CLICK " .. buttonName .. ":LeftButton",
        btn    = btn,
    }
    btn:SetScript("OnClick", function()
        if row.listening then StopListening(row) else StartListening(row) end
    end)
    keyRows[#keyRows + 1] = row
    return row
end

MakeKeyRow("the next-step button", "LockPrepButton", extraY - 206)

opt:HookScript("OnShow", RefreshKeyButtons)

local function ToggleOptions()
    if opt:IsShown() then opt:Hide() else opt:Show() end
end

-- right-click the checklist to open options
ui:SetScript("OnMouseUp", function(_, mb) if mb == "RightButton" then ToggleOptions() end end)

-- =====================================================================
-- Minimap button (LibDBIcon) - the round, bordered icon on the minimap
-- =====================================================================
local ToggleWindow  -- fwd (defined with the window show/hide flags below)
local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
local ldbObj
if LDB then
    ldbObj = LDB:NewDataObject("LockPrep", {
        type = "launcher",
        text = "LockPrep",
        icon = "Interface\\Icons\\INV_Stone_04", -- healthstone
        OnClick = function(_, mb)
            if mb == "RightButton" then
                ToggleWindow()
            else
                ToggleOptions()
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("LockPrep")
            tt:AddLine("|cffffffffLeft-click|r  options / presets", 1, 1, 1)
            tt:AddLine("|cffffffffRight-click|r  toggle the checklist", 1, 1, 1)
        end,
    })
end

-- Right-click the icon (and /lp show|hide|test) toggles the checklist window;
-- respects the manual show/hide flags so it behaves the same as /lp show|hide.
ToggleWindow = function()
    if ui:IsShown() then
        ui.userHidden = true; ui.preview = false; HideUI()
    else
        ui.userHidden = false; ui.preview = true; ShowUI()
    end
end

-- =====================================================================
-- Events
-- =====================================================================
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("UNIT_PET")
ev:RegisterEvent("UNIT_AURA")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("CHAT_MSG_BG_SYSTEM_NEUTRAL")
ev:RegisterEvent("CHAT_MSG_RAID_BOSS_EMOTE")
ev:RegisterEvent("START_TIMER")   -- reliable arena begin timer (Blizzard TimerTracker)
ev:RegisterEvent("TRADE_SHOW")
ev:RegisterEvent("TRADE_CLOSED")
ev:RegisterEvent("TRADE_ACCEPT_UPDATE")
-- Either side changing the trade contents un-accepts BOTH sides (and starts the
-- anti-scam accept lockout). WoW signals that via these item-change events, not
-- reliably via TRADE_ACCEPT_UPDATE, so we listen here to keep our accept mirror
-- honest -- otherwise iAccepted sticks true and PreClick refuses to re-accept.
ev:RegisterEvent("TRADE_PLAYER_ITEM_CHANGED")
ev:RegisterEvent("TRADE_TARGET_ITEM_CHANGED")
ev:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
-- Player-only cast start/stop so the button blanks the instant a summon/conjure
-- begins (kills the spell-queue duplicate) and re-offers if the cast is cut.
ev:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
-- Channels (Ritual of Souls) don't fire the *_START cast events, so register the
-- channel equivalents too. They fall through to the default Refresh() branch,
-- which blanks the button the instant the channel begins -- the same mid-cast
-- mash protection the timed casts already get.
ev:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE", "player")

-- Live updater: while Summon Felhunter is casting, refresh ~10x/sec so the
-- progress % and the swap-to-sacrifice button stay current, plus one final
-- refresh when the cast ends to return to the normal flow.
local felTicker = CreateFrame("Frame")
felTicker.t = 0
felTicker:SetScript("OnUpdate", function(self, dt)
    self.t = self.t + dt
    if self.t < 0.1 then return end
    self.t = 0
    local casting = FelSummonProgress() ~= nil
    if casting or self.was then
        self.was = casting
        Refresh()
    end
end)

local function OnCountdownMessage(msg)
    if not msg then return end
    msg = msg:lower()
    if msg:find("one minute") then gateAt = GetTime() + 60
    elseif msg:find("thirty second") then gateAt = GetTime() + 30
    elseif msg:find("fifteen second") then gateAt = GetTime() + 15
    elseif msg:find("has begun") or msg:find("gates are open") then gateAt = GetTime() end
end

ev:SetScript("OnEvent", function(self, event, arg1, arg2, arg3)
    if event == "PLAYER_LOGIN" then
        LockPrepDB = LockPrepDB or {}
        -- Re-resolve the spell names the mid-cast blanks/latches key on, now that
        -- the client's spell cache is warm. At file-load these can come back nil
        -- (cold cache) and fall back to English strings, which would silently break
        -- the guards on a non-enUS client. We only overwrite when a real name
        -- resolves, so this never nils anything and is a no-op where load-time
        -- values were already correct. BuildSteps re-runs per match, so step
        -- castNames pick these up before any arena.
        CREATE_HS_NAME = GetSpellInfo(6201)  or CREATE_HS_NAME
        SUMMON_NAME[1] = GetSpellInfo(688)   or SUMMON_NAME[1]
        SUMMON_NAME[2] = GetSpellInfo(697)   or SUMMON_NAME[2]
        SUMMON_NAME[3] = GetSpellInfo(691)   or SUMMON_NAME[3]
        RITUAL_NAME    = GetSpellInfo(29893) or RITUAL_NAME
        FEL_NAME       = GetSpellInfo(691)   or FEL_NAME
        if not LockPrepDB.disabled then
            LockPrepDB.disabled = { hsmajor = true, spellstone = true, ritual = true } -- 2s preset
            LockPrepDB.preset = "2s"
        end
        ApplyPos()
        ui.locked = LockPrepDB.locked or false
        UpdateSpellstoneButton()
        if DBIcon and ldbObj then
            LockPrepDB.minimap = LockPrepDB.minimap or {}
            if not DBIcon:IsRegistered("LockPrep") then
                DBIcon:Register("LockPrep", ldbObj, LockPrepDB.minimap)
            end
        end
        if not GetBindingKey("CLICK LockPrepButton:LeftButton") then
            print("|cffcc66ffLockPrep|r loaded. Quick start:")
            print("  1) Left-click the |cffffffffminimap icon|r for options/presets, then set your keys in the |cffffffffKeybinds|r section")
            print("     (or use |cffffffff/lp bind SHIFT-E|r for the next-step key)")
            print("  2) |cffffffff/lp wand <your wand name>|r for the spellstone dispel/swap")
            print("  3) Right-click the minimap icon (or |cffffffff/lp test|r) to peek at the checklist")
            print("  In the arena: just mash your bound key - it does each step in order.")
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        if InArena() then
            gateAt = nil
            wipe(tradedNames)     -- fresh trade tracking each match
            wipe(tradedGUIDs)
            tradeGUID = nil
            petSummonedMax = 0    -- fresh creation-delay latches each match
            wipe(hsPending)
            ritualDone = false
            BuildSteps()          -- fresh steps for this match
            if AutoShowOn() then
                ui.userHidden = false -- auto-show fresh each match
                ShowUI()
            else
                Refresh()         -- keep the button macro correct even if hidden
            end
        else
            if ui.preview then ShowUI() else HideUI() end
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg1 == "player" and arg3 then
            local name = GetSpellInfo(arg3)
            if name == RITUAL_NAME then
                ritualDone = true
                Refresh()
            elseif name == SUMMON_NAME[1] then
                if petSummonedMax < 1 then petSummonedMax = 1 end
                Refresh()
            elseif name == SUMMON_NAME[2] then
                if petSummonedMax < 2 then petSummonedMax = 2 end
                Refresh()
            elseif name == SUMMON_NAME[3] then
                if petSummonedMax < 3 then petSummonedMax = 3 end
                Refresh()
            elseif name == CREATE_HS_NAME then
                -- ranks share one name; latch whichever tier we're on right now
                if currentId == "hs_master" then hsPending.hs_master = true
                elseif currentId == "hs_major" then hsPending.hs_major = true end
                Refresh()
            end
        end
    elseif event == "START_TIMER" then
        -- arg1 = timerType, arg2 = seconds left. Extra source for the gate when it
        -- fires: type 1 is the arena begin timer on the Classic client (what
        -- DBM-PvP keys on); retail's Enum.StartTimerType.PvPBeginTimer is 0, so
        -- accept either. Type 2 is the /countdown pull timer - ignore it. On the
        -- Anniversary client this often doesn't fire, which is fine: the chat
        -- countdown carries the gate on its own.
        local pvpBegin = Enum and Enum.StartTimerType and Enum.StartTimerType.PvPBeginTimer
        if arg2 and (arg1 == 1 or (pvpBegin and arg1 == pvpBegin)) then
            gateAt = GetTime() + arg2
            Refresh()
        end
    elseif event == "CHAT_MSG_BG_SYSTEM_NEUTRAL" or event == "CHAT_MSG_RAID_BOSS_EMOTE" then
        OnCountdownMessage(arg1)
    elseif event == "TRADE_ACCEPT_UPDATE" then
        -- arg1 = our side accepted (0/1), arg2 = the partner's side. Keep iAccepted
        -- in sync so PreClick only calls AcceptTrade() once (a second call toggles
        -- it back off).
        iAccepted = (arg1 == 1)
        partnerAccepted = (arg2 == 1)
        -- When BOTH sides are green the trade is about to go through. Snapshot how
        -- many healthstones are in OUR side right now: if it's >0, this completion
        -- credits the partner regardless of bag-count timing (a conjure landing
        -- mid-trade or a bag-update lag can otherwise hide the count delta and make
        -- us re-trade someone who already got a stone).
        if iAccepted and partnerAccepted then
            local s = StonesInTrade()
            if s > tradeCommitStones then tradeCommitStones = s end
        end
        Refresh()   -- un-blank prep once accepted / re-blank if our accept reset
    elseif event == "TRADE_PLAYER_ITEM_CHANGED" or event == "TRADE_TARGET_ITEM_CHANGED" then
        -- Contents changed on either side -> WoW un-accepted both sides. Clear our
        -- mirror so PreClick will accept again once the anti-scam lockout clears,
        -- and drop the both-accepted stone snapshot so it re-captures at the real
        -- completion (a fresh accept is required now). Re-blank the prep cast via
        -- Refresh since we're back to "needs accept".
        iAccepted = false
        partnerAccepted = false
        tradeCommitStones = 0
        Refresh()
    elseif event == "TRADE_SHOW" then
        iAccepted = false
        partnerAccepted = false
        tradeCommitStones = 0
        tradeHadStones = false
        tradeStartHS = HSCount()
        tradeGUID = UnitGUID("npc")   -- the unit we're trading with (either direction)
        tradePartner = (TradeFrameRecipientNameText and TradeFrameRecipientNameText:GetText())
        if not tradePartner or tradePartner == "" then tradePartner = UnitName("npc") end
        if not tradePartner or tradePartner == "" then tradePartner = "partner" end
        -- Only auto-fill our stones if THIS partner still needs one. Otherwise a
        -- teammate re-opening a trade to hand US something (a mage giving food)
        -- would get another stone dumped in - and possibly accepted away.
        local giveStone = AutoTradeOn() and InArena() and not UseRitual()
                          and HaveAnyStone() and not HasTraded("npc")
        if tradeArmed or giveStone then FillTrade() end
        Refresh()                     -- blank the prep cast while the window is up
    elseif event == "TRADE_CLOSED" then
        lastTradeClosed = GetTime()   -- start the re-open cooldown (see PreClick)
        iAccepted = false
        partnerAccepted = false
        local partner, guid, before = tradePartner, tradeGUID, tradeStartHS
        local committed = tradeCommitStones   -- our stones in-window when both accepted
        tradeHadStones = false; tradePartner = nil; tradeGUID = nil; tradeCommitStones = 0
        Refresh()                     -- restore the prep cast now the window is gone
        -- Credit the partner with their stone. Store the GUID (realm-proof) plus a
        -- realm-stripped name so HasTraded()'s UnitName fallback can't miss on a
        -- cross-realm skirmish partner.
        local function record()
            if guid then tradedGUIDs[guid] = true end
            if partner then tradedNames[(partner:match("^[^-]+")) or partner] = true end
            Refresh()
        end
        if committed > 0 then
            -- Both sides accepted with our healthstone(s) in the window: it went
            -- through. Deterministic, immune to conjure timing / bag-update lag.
            record()
        else
            -- Fallback for clients that don't report the partner's accept flag:
            -- infer from our stones leaving the bags. Poll twice for bag lag.
            C_Timer.After(0.4, function() if HSCount() < before then record() end end)
            C_Timer.After(1.2, function() if HSCount() < before then record() end end)
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- roster affects partner buff steps; rebuild to keep them current
        BuildSteps()
        Refresh()
    elseif event == "PLAYER_REGEN_ENABLED" then
        UpdateSpellstoneButton()
        Refresh()
    else
        Refresh()
    end
end)

-- Throttled re-evaluation (handles the time-gated steps, which have no event to
-- fire when "12s left" arrives - they must be polled). This MUST live on an
-- always-running frame, NOT on `ui`: OnUpdate only fires while its frame is
-- shown, and the window is hidden during matches. Tying it to `ui` meant that
-- once the finish was gated the button's macro was blanked and never re-armed
-- when the clock crossed the gate, so the finish stayed locked all match.
local tickerFrame = CreateFrame("Frame")
local acc = 0
tickerFrame:SetScript("OnUpdate", function(self, elapsed)
    if not LockPrepDB then return end   -- wait for PLAYER_LOGIN / saved vars
    acc = acc + elapsed
    if acc < 0.2 then return end
    acc = 0
    Refresh()
end)

-- =====================================================================
-- Slash
-- =====================================================================
SLASH_LOCKPREP1 = "/lockprep"
SLASH_LOCKPREP2 = "/lp"
SLASH_LOCKPREP3 = "/va"
SlashCmdList["LOCKPREP"] = function(msg)
    local raw = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local lc = raw:lower()
    local cmd, arg = lc:match("^(%S*)%s*(.-)$")
    local _, rawArg = raw:match("^(%S*)%s*(.-)$") -- preserves case (item names)
    if cmd == "unlock" then
        ui.locked = false; ui.preview = true; ui.userHidden = false
        LockPrepDB = LockPrepDB or {}; LockPrepDB.locked = nil
        ShowUI()
        print("|cffcc66ffLockPrep|r: movable - drag it anywhere, then /lp lock when happy")
    elseif cmd == "lock" then
        ui.locked = true
        local p, _, r, x, y = ui:GetPoint()
        LockPrepDB = LockPrepDB or {}; LockPrepDB.pos = { p, r, x, y }; LockPrepDB.locked = true
        print("|cffcc66ffLockPrep|r: locked & position saved")
    elseif cmd == "test" or cmd == "toggle" or cmd == "show" or cmd == "hide" then
        local wantShow
        if cmd == "show" then wantShow = true
        elseif cmd == "hide" then wantShow = false
        else wantShow = not ui:IsShown() end
        if wantShow then
            if InArena() then ui.userHidden = false else ui.preview = true end
            ShowUI(); print("|cffcc66ffLockPrep|r: shown")
        else
            if InArena() then ui.userHidden = true else ui.preview = false end
            HideUI(); print("|cffcc66ffLockPrep|r: hidden (/lp show to bring back)")
        end
    elseif cmd == "status" then
        local key = GetBindingKey("CLICK LockPrepButton:LeftButton") or "|cffff6666none|r"
        local sskey = GetBindingKey("CLICK LockPrepSpellstoneButton:LeftButton") or "|cffff6666none|r"
        local ackey = GetBindingKey("CLICK LockPrepAcceptButton:LeftButton") or "|cffff6666none|r"
        print("|cffcc66ffLockPrep|r status:")
        print("  next-step key: |cffffffff" .. key .. "|r   spellstone key: |cffffffff" .. sskey .. "|r   accept key: |cffffffff" .. ackey .. "|r")
        print("  next-step macro: |cffffffff" .. (button:GetAttribute("macrotext") or "(empty)") .. "|r")
        print("  wand: |cffffffff" .. (LockPrepDB and LockPrepDB.wand or "(not set)") .. "|r  in arena: " .. tostring(InArena()))
        local sz = GetNumGroupMembers() or 0
        local preset = (LockPrepDB and LockPrepDB.preset and PRESETS[LockPrepDB.preset] and PRESETS[LockPrepDB.preset].label) or "Custom"
        print("  group size: |cffffffff" .. sz .. "|r  preset: |cffffffff" .. preset .. "|r  ->  stones: |cffffffff" .. (UseRitual() and "Ritual of Souls" or "conjure pair") .. "|r")
    elseif cmd == "bind" and arg ~= "" then
        local key = arg:upper()
        SetBindingClick(key, "LockPrepButton")
        SaveBindings(GetCurrentBindingSet())
        print("|cffcc66ffLockPrep|r: bound |cffffffff" .. key .. "|r to the next-step button")
    elseif cmd == "bindss" and arg ~= "" then
        local key = arg:upper()
        SetBindingClick(key, "LockPrepSpellstoneButton")
        SaveBindings(GetCurrentBindingSet())
        print("|cffcc66ffLockPrep|r: bound |cffffffff" .. key .. "|r to the spellstone dispel/swap button")
    elseif cmd == "bindaccept" and arg ~= "" then
        local key = arg:upper()
        SetBindingClick(key, "LockPrepAcceptButton")
        SaveBindings(GetCurrentBindingSet())
        print("|cffcc66ffLockPrep|r: bound |cffffffff" .. key .. "|r to accept a trade (only when stones are in)")
    elseif cmd == "unbind" and arg ~= "" then
        SetBinding(arg:upper())
        SaveBindings(GetCurrentBindingSet())
        print("|cffcc66ffLockPrep|r: unbound |cffffffff" .. arg:upper() .. "|r")
    elseif cmd == "wand" then
        LockPrepDB = LockPrepDB or {}
        if rawArg == "" then
            LockPrepDB.wand = nil
            UpdateSpellstoneButton()
            print("|cffcc66ffLockPrep|r: wand cleared (spellstone button will just dispel, no swap)")
        else
            LockPrepDB.wand = rawArg
            UpdateSpellstoneButton()
            print("|cffcc66ffLockPrep|r: wand set to |cffffffff" .. rawArg .. "|r")
        end
    elseif cmd == "mount" then
        LockPrepDB = LockPrepDB or {}
        if rawArg == "" then
            LockPrepDB.mount = nil
            BuildSteps(); Refresh()
            print("|cffcc66ffLockPrep|r: gate mount reset to default (|cffffffff" .. DEFAULT_MOUNT .. "|r)")
        else
            LockPrepDB.mount = rawArg
            BuildSteps(); Refresh()
            print("|cffcc66ffLockPrep|r: gate mount set to |cffffffff" .. rawArg .. "|r")
        end
    elseif cmd == "preset" then
        local key
        if arg == "2s" then key = "2s"
        elseif arg == "3s" or arg == "5s" or arg == "3s5s" or arg == "3s/5s" then key = "3s5s"
        elseif arg == "bg" or arg == "bgs" then key = "bg"
        elseif arg == "custom" then key = "custom"
        else print("|cffcc66ffLockPrep|r: usage /lp preset 2s|3s5s|bg|custom"); return end
        ApplyPreset(key)
        print("|cffcc66ffLockPrep|r: preset = |cffffffff" .. PRESETS[key].label .. "|r")
    elseif cmd == "minimap" or cmd == "icon" then
        LockPrepDB = LockPrepDB or {}
        LockPrepDB.minimap = LockPrepDB.minimap or {}
        LockPrepDB.minimap.hide = not LockPrepDB.minimap.hide
        if DBIcon then
            if LockPrepDB.minimap.hide then DBIcon:Hide("LockPrep") else DBIcon:Show("LockPrep") end
        end
        print("|cffcc66ffLockPrep|r: minimap icon " .. (LockPrepDB.minimap.hide and "hidden" or "shown"))
    elseif cmd == "options" or cmd == "config" or cmd == "opt" then
        ToggleOptions()
    elseif cmd == "trade" then
        tradeArmed = true
        print("|cffcc66ffLockPrep|r: armed - open a trade now and your healthstones drop in (once)")
    elseif cmd == "spellstone" or cmd == "ss" then
        print("|cffcc66ffLockPrep|r spellstone dispel/swap:")
        print("  Prep equips the stone (30s equip CD burns off before the gates).")
        print("  Then bind the swap button: |cffffffff/lp bindss <KEY>|r (or macro |cffffffff/click LockPrepSpellstoneButton|r)")
        print("  Set your wand name first: |cffffffff/lp wand <exact wand name>|r")
        print("  Press = dispel all harmful magic (off-GCD) + swap to wand. Press again later to re-arm the stone.")
    else
        print("|cffcc66ffLockPrep|r commands:")
        print("  /lp show | hide | test  - show/hide the checklist (or right-click the minimap icon)")
        print("  /lp minimap  - show/hide the minimap icon")
        print("  /lp options  - choose which steps to include (or left-click the icon)")
        print("  /lp trade  - arm one trade to auto-fill your healthstones (auto in arena)")
        print("  /lp unlock | lock  - move / pin the window")
        print("  /lp bind <KEY>  - bind the next-step button (e.g. /lp bind 0)")
        print("  /lp bindss <KEY>  - bind the spellstone dispel/swap button")
        print("  /lp bindaccept <KEY>  - bind a key to accept a trade (when stones are in)")
        print("  /lp wand <name>  - set your wand's exact name (for the spellstone swap)")
        print("  /lp mount <name>  - set the mount used for the gate sprint (or pick it in /lp options)")
        print("  /lp preset 2s|3s5s|bg|custom  - apply a preset (custom keeps your boxes)")
        print("  /lp spellstone  - how the spellstone dispel/swap button works")
        print("  /lp status  - show your keybinds + what the next press will cast")
    end
end

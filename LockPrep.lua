local ADDON = ...

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

-- mount for the gate sprint (configurable so the addon is shareable)
local DEFAULT_MOUNT = "Red Skeletal Warhorse"
local function MountName() return (LockPrepDB and LockPrepDB.mount) or DEFAULT_MOUNT end

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
local gateAt
local function TimeLeft()
    if not gateAt then return nil end
    local t = gateAt - GetTime()
    return (t < 0) and 0 or t
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

-- per-match healthstone trade tracking (declared early; used by the UI)
local tradedNames = {}
local function TradedCount()
    local n = 0
    for _ in pairs(tradedNames) do n = n + 1 end
    return n
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
          done = function() return Have(CFG.item.hsMajor) end })
    add({ id = "hs_master", group = "hsmaster", label = "Master Healthstone", macro = CFG.cast.hsMaster,
          done = function() return Have(CFG.item.hsMaster) end })
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
          done = function() return PetRank() >= 1 end })

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
          done = function() return PetRank() >= 2 end })

    -- Timed finish -----------------------------------------------------
    -- Felhunter + sac gate on STATE, not the clock: as soon as the voidwalker is
    -- out it's time to swap. Sac/Soul Link buffs persist, so no need to wait for
    -- the countdown. (If you trade your stones away, the healthstone step jumps
    -- back ahead of this in the order, so the button re-offers a stone first.)
    -- Ready once the voidwalker is out (arena sac flow); but if the voidwalker
    -- step is turned off (e.g. the BGs preset), go straight imp -> felhunter.
    add({ id = "fh", group = "felhunter", label = "Summon Felhunter", macro = CFG.cast.summonFel,
          done = function() return PetRank() >= 3 end,
          ready = function() return PetRank() >= 2 or not Enabled("voidwalker") end })
    add({ id = "sac", group = "sacrifice", label = "Sacrifice VW (during Felhunter cast!)", macro = CFG.cast.sacrifice,
          done = function() return HasBuff("player", CFG.buff.sacrifice) or PetRank() >= 3 end,
          ready = function() return PetFamily() == "Voidwalker" end })
    add({ id = "sl", group = "soullink", label = "Soul Link", macro = CFG.cast.soulLink,
          done = function() return HasBuff("player", CFG.buff.soulLink) end,
          ready = function() return PetFamily() == "Felhunter" end })
    -- These last steps are order-gated only (no countdown timing). The gate
    -- countdown on the Anniversary client is unreliable to parse, and mistiming
    -- these costs mana, so we just enforce order and let you press them when the
    -- gate is about to open -- same as the rest of the routine.
    add({ id = "sw", group = "shadowward", label = "Shadow Ward", macro = CFG.cast.shadowWard,
          done = function() return HasBuff("player", CFG.buff.shadowWard) end })
    -- Tainted Blood MUST come before the mount: you can't use any ability
    -- (yours or the pet's) while mounted. Pet abilities don't share your GCD,
    -- so it's fine right alongside Shadow Ward.
    add({ id = "tb", group = "taintedblood", label = "Tainted Blood", macro = CFG.cast.taintedBlood,
          done = function() return HasBuff("pet", CFG.buff.taintedBlood) end,
          ready = function() return PetFamily() == "Felhunter" end })
    -- Mount is the very last thing (mounting locks out all abilities).
    add({ id = "mount", group = "mount", label = "Mount up (" .. MountName() .. ")", macro = "/use " .. MountName(),
          done = function() return IsMounted() end })
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
-- Party-chat announce: tell teammates to open a trade once stones are ready.
-- One-shot per batch: fires when we go from "no stones" to "have a stone", and
-- re-arms after they're traded away (bags hit zero) so each new pair re-pings.
local announcedStones = false
local function AnnounceOn()
    return not (LockPrepDB and LockPrepDB.announce == false)
end
local function HaveAnyStone()
    return Have(CFG.item.hsMajor) or Have(CFG.item.hsMaster)
end
local function AnnounceStones()
    local partners = #Partners()
    local msg
    if UseRitual() then
        msg = "Soulwell's up - grab a healthstone if you want to live."
    else
        msg = "Open trade if you want to live."
        if partners > 0 then
            msg = msg .. " (" .. TradedCount() .. "/" .. partners .. " traded)"
        end
    end
    SendChatMessage(msg, "SAY")
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
    else
        currentId = step and step.id or nil
    end
    if not InCombatLockdown() then
        button:SetAttribute("macrotext", macro)
    end
    -- battle-cry: in 3s/5s once the soulwell is up; in 2s when a stone is ready
    -- (re-arms after they're traded away, and skips once everyone's stocked).
    if AnnounceOn() and InArena() then
        local ready = UseRitual() and ritualDone or (not UseRitual() and HaveAnyStone())
        -- Only shout when a teammate is actually there to grab a stone. Without
        -- this, a partner leaving mid-match drops the count to 0 and the old
        -- "solo" clause would fire the message into an empty arena.
        local needed
        if UseRitual() then
            needed = #Partners() > 0
        else
            needed = (#Partners() - TradedCount()) > 0
        end
        if ready then
            if not announcedStones and needed then
                announcedStones = true
                AnnounceStones()
            end
        else
            announcedStones = false
        end
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
        actionFS:SetText("|cffaaaaaaWaiting for the countdown...|r")
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
    local partners = #Partners()
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

-- Fold accept into the SPAM key: PreClick runs on the same hardware press
-- (before the secure cast), so while a stone-trade is open your normal button
-- mashing accepts it. AcceptTrade() is legal from this hardware context.
button:SetScript("PreClick", function()
    if TradeFrame and TradeFrame:IsShown() and StonesInTrade() > 0 then
        AcceptTrade()
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
opt:SetSize(300, 60 + #GROUPS * 22 + 210)
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

local ancb = CreateFrame("CheckButton", nil, opt, "UICheckButtonTemplate")
ancb:SetSize(22, 22)
ancb:SetPoint("TOPLEFT", 12, extraY - 38)
local anlbl = ancb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
anlbl:SetPoint("LEFT", ancb, "RIGHT", 2, 0)
anlbl:SetText("Announce 'open trade' in /say (arena)")
ancb:SetScript("OnShow", function(self) self:SetChecked(AnnounceOn()) end)
ancb:SetScript("OnClick", function(self)
    LockPrepDB = LockPrepDB or {}
    LockPrepDB.announce = self:GetChecked() and true or false
end)

local ascb = CreateFrame("CheckButton", nil, opt, "UICheckButtonTemplate")
ascb:SetSize(22, 22)
ascb:SetPoint("TOPLEFT", 12, extraY - 60)
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
pslbl:SetPoint("TOPLEFT", 16, extraY - 90)
pslbl:SetText("Preset:")

-- dropdown sits below its label (labels get cut off if placed beside it)
local psdd = CreateFrame("Frame", "LockPrepPresetDropDown", opt, "UIDropDownMenuTemplate")
psdd:SetPoint("TOPLEFT", 0, extraY - 108)
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
mlbl:SetPoint("TOPLEFT", 16, extraY - 150)
mlbl:SetText("Gate mount:")

local mdd = CreateFrame("Frame", "LockPrepMountDropDown", opt, "UIDropDownMenuTemplate")
mdd:SetPoint("TOPLEFT", 0, extraY - 168)
UIDropDownMenu_SetWidth(mdd, 200)

local function SetMount(name)
    LockPrepDB = LockPrepDB or {}
    LockPrepDB.mount = (name ~= DEFAULT_MOUNT) and name or nil
    UIDropDownMenu_SetText(mdd, MountName())
    BuildSteps(); Refresh()
end

-- collect owned mounts. In TBC (2.5.x) mounts are ITEMS in your bags, not
-- entries in the WotLK+ companion journal, so scan the bags. We also fold in
-- any learned companions in case this ever runs on a later client.
local function OwnedMounts()
    local names, seen = {}, {}
    local function addName(nm)
        if nm and nm ~= "" and not seen[nm] then seen[nm] = true; names[#names + 1] = nm end
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
    table.sort(names)
    return names
end

UIDropDownMenu_Initialize(mdd, function(self, level)
    local names = OwnedMounts()
    for _, cname in ipairs(names) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = cname
        info.checked = (MountName() == cname)
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
ev:RegisterEvent("TRADE_SHOW")
ev:RegisterEvent("TRADE_CLOSED")
ev:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")

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
            print("  1) |cffffffff/lp bind SHIFT-E|r - one key you'll spam during arena prep")
            print("  2) |cffffffff/lp wand <your wand name>|r then |cffffffff/lp bindss SHIFT-R|r - spellstone dispel/swap")
            print("  3) Left-click the |cffffffffminimap icon|r for options/presets (right-click = checklist)")
            print("  In the arena: just mash your bound key - it does each step in order.")
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        if InArena() then
            gateAt = nil
            wipe(tradedNames)     -- fresh trade tracking each match
            announcedStones = false
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
        if arg1 == "player" and arg3 and GetSpellInfo(arg3) == RITUAL_NAME then
            ritualDone = true
            Refresh()
        end
    elseif event == "CHAT_MSG_BG_SYSTEM_NEUTRAL" or event == "CHAT_MSG_RAID_BOSS_EMOTE" then
        OnCountdownMessage(arg1)
    elseif event == "TRADE_SHOW" then
        tradeHadStones = false
        tradeStartHS = HSCount()
        tradePartner = (TradeFrameRecipientNameText and TradeFrameRecipientNameText:GetText())
        if not tradePartner or tradePartner == "" then tradePartner = UnitName("npc") end
        if not tradePartner or tradePartner == "" then tradePartner = "partner" end
        if tradeArmed or (AutoTradeOn() and InArena()) then FillTrade() end
    elseif event == "TRADE_CLOSED" then
        -- success is detected by our stones actually leaving the bags. Check
        -- after a short delay so the bag update has landed.
        local partner, before = tradePartner, tradeStartHS
        tradeHadStones = false; tradePartner = nil
        C_Timer.After(0.4, function()
            if partner and HSCount() < before then
                tradedNames[partner] = true
                Refresh()
            end
        end)
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

-- throttled re-evaluation (handles the time-gated steps without events)
local acc = 0
ui:SetScript("OnUpdate", function(self, elapsed)
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
    elseif cmd == "announce" then
        AnnounceStones()
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
        print("  /lp announce  - say the 'open trade' battle-cry now")
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

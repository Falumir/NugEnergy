local lastTickTime = GetTime() -- Used for both energy tick timing and FSR 5-second countdown
local lastEnergyValue = 0
local heartbeatPlayed = false
local EPT = Enum.PowerType
local Enum_PowerType_Energy = EPT.Energy

local tickFiltering = true
local ClassicTickerFrame = CreateFrame("Frame")
NugEnergy.ticker = ClassicTickerFrame
local ClassicTickerOnUpdate = function(self)
    local _, PowerTypeIndex = NugEnergy:GetPowerFilter()
    local currentEnergy = UnitPower("player", PowerTypeIndex)
    local now = GetTime()
    local possibleTick = false
    if currentEnergy > lastEnergyValue then
        if PowerTypeIndex == Enum_PowerType_Energy and tickFiltering then
            local diff = currentEnergy - lastEnergyValue
            if  (diff > 18 and diff < 22) or -- normal tick
                (diff > 38 and diff < 42) or -- adr rush
                (diff < 42 and currentEnergy == UnitPowerMax("player", PowerTypeIndex)) -- including tick to cap, but excluding thistle tea
            then
                possibleTick = true
            end
        else
            -- Mana gains can come from spirit regen (2s cadence) or Mana Per 5
            -- items (5s cadence), with no way to tell them apart from the event.
            -- Time-gate to 1.8s so MP5 ticks mid-cycle don't reset the bar.
            -- Unlike energy, there is no fallback timer -- mana always fires a
            -- UNIT_POWER_UPDATE on tick so one is not needed.
            if now >= lastTickTime + 1.8 then
                possibleTick = true
            end
        end
    end
    if PowerTypeIndex == Enum_PowerType_Energy and now >= lastTickTime + 2 then
        possibleTick = true
    end
    if possibleTick then
        lastTickTime = now
        heartbeatPlayed = false
    end
    lastEnergyValue = currentEnergy
end

local fsrCallback
local ClassicTickerOnUpdateFSR = function(self)
    local now = GetTime()
    if now >= lastTickTime + 5 then
        self:Disable()
        fsrCallback(NugEnergy)
    end
end

function ClassicTickerFrame:GetLastTickTime()
    return lastTickTime
end
function ClassicTickerFrame:Reset()
    lastTickTime = GetTime()
end
function ClassicTickerFrame:Enable(mode, callback)
    if mode == "FSR" then
        self:SetScript("OnUpdate", ClassicTickerOnUpdateFSR)
        fsrCallback = callback
        self:Reset()
    else
        self:SetScript("OnUpdate", ClassicTickerOnUpdate)
        lastTickTime = 0  -- force sync on first observed tick
    end
    self.isEnabled = true
end
function ClassicTickerFrame:Disable()
    self:SetScript("OnUpdate", nil)
    self.isEnabled = false
end

function ClassicTickerFrame:GetTickProgress()
    return GetTime() - lastTickTime
end
function ClassicTickerFrame:SetHeartbeatPlayed(status)
    heartbeatPlayed = status
end
function ClassicTickerFrame:HasHeartbeatPlayed()
    return heartbeatPlayed
end

do

    local twEnabled
    local twEnabledCappedOnly
    local twStart
    local twLength
    local twCrossfade
    local twChangeColor
    local twPlaySound

    function ClassicTickerFrame:UpdateUpvalues()
        twEnabled = NugEnergy.db.profile.twEnabled
        twEnabledCappedOnly = NugEnergy.db.profile.twEnabledCappedOnly
        twStart = NugEnergy.db.profile.twStart
        twLength = NugEnergy.db.profile.twLength
        twCrossfade = NugEnergy.db.profile.twCrossfade
        twPlaySound = NugEnergy.db.profile.soundName ~= "none"
        twChangeColor = NugEnergy.db.profile.twChangeColor
    end

    local UnitReaction = UnitReaction
    local GetUnitSpeed = GetUnitSpeed
    local IsStealthed = IsStealthed

    local heartbeatEligible
    local heartbeatEligibleLastTime = 0
    local heartbeatEligibleTimeout = 8
    local function GetGradientColor(c1, c2, v)
        if v > 1 then v = 1 end
        local r = c1[1] + v*(c2[1]-c1[1])
        local g = c1[2] + v*(c2[2]-c1[2])
        local b = c1[3] + v*(c2[3]-c1[3])
        return r,g,b
    end
    local function ClassicTickerColorUpdate(self, tp, prevColor)
        local twSecondThreshold = twStart + twLength

        if tp > twSecondThreshold then
            local fp = twCrossfade > 0 and  ((twSecondThreshold + twCrossfade - tp) / twCrossfade) or 0
            if fp < 0 then fp = 0 end
            local cN = prevColor
            local cA = NugEnergy.db.profile.twColor
            self:SetColor(GetGradientColor(cN, cA, fp))
        elseif tp > twStart then
            local fp = twCrossfade > 0 and  ((twStart + twCrossfade - tp) / twCrossfade) or 0
            if fp < 0 then fp = 0 end
            local cN = prevColor
            local cA = NugEnergy.db.profile.twColor
            self:SetColor(GetGradientColor(cA, cN, fp))
        elseif tp >= 0 then
            local cN = prevColor
            self:SetColor(unpack(cN))
        end
    end

    function NugEnergy:ColorTickWindow(isCapped, prevColor)
        if twEnabled then
            local ticker = self.ticker
            if ticker.isEnabled and (not twEnabledCappedOnly or isCapped) and ticker:GetTickProgress() > twStart then
                if twPlaySound then
                    local now = GetTime()
                    local isEnemy = (UnitReaction("target", "player") or 4) <= 4
                    heartbeatEligible = IsStealthed() and UnitExists("target") and isEnemy and GetUnitSpeed("player") > 0
                    if heartbeatEligible then
                        heartbeatEligibleLastTime = now
                    end

                    if not ticker:HasHeartbeatPlayed() and now - heartbeatEligibleLastTime < heartbeatEligibleTimeout then
                        ticker:SetHeartbeatPlayed(true)
                        self:PlaySound()
                    end
                end

                if twChangeColor then
                    ClassicTickerColorUpdate(self, ticker:GetTickProgress(), prevColor)
                end
            end
        end
    end

    function NugEnergy:PlaySound()
        local sound
        if NugEnergy.db.profile.soundName == "Heartbeat" then
            sound = "Interface\\AddOns\\NugEnergy\\heartbeat.mp3"
        elseif NugEnergy.db.profile.soundName then
            sound = NugEnergy.db.profile.soundNameCustom
        end
        PlaySoundFile(sound, NugEnergy.db.profile.soundChannel)
    end
end

-- Make5SRWatcher
-- Monitors for mana expenditure and triggers the FSR (Five Second Rule) config
-- switch, which shows a 5-second countdown bar after mana is spent on a spell.
--
-- Two events are used together because neither is reliable on its own:
--   UNIT_SPELLCAST_SUCCEEDED fires when a spell completes, but NOT for instant
--   casts that fire before the config has switched to GeneralMana (e.g. casting
--   directly out of bear/cat form). In that case the event is already gone by
--   the time this watcher is listening.
--
--   UNIT_POWER_UPDATE catches the mana drop itself, covering instant casts that
--   UNIT_SPELLCAST_SUCCEEDED misses. Both events are checked so that whichever
--   fires second will see both timestamps set and trigger the callback.
--
-- Both events are registered permanently (Disable is intentionally a no-op).
-- This is necessary because when shifting out of a form, UNIT_SPELLCAST_SUCCEEDED
-- and UNIT_POWER_UPDATE can fire BEFORE UNIT_DISPLAYPOWER, which is what
-- actually triggers the config switch to GeneralMana. If we only listened while
-- GeneralMana was active, we would miss the events entirely.
-- Keeping the watcher always-on also prevents prevMana from going stale while
-- in bear/cat form, which would cause false mana drop detections on re-enable.
--
-- The callback is deferred by one frame with C_Timer.After(0) so that
-- UNIT_DISPLAYPOWER has time to fire and UpdateConfig has time to run before
-- we check whether PowerFilter is "MANA". Without this defer, an instant cast
-- from a form would pass the timestamp check but PowerFilter would still be
-- "RAGE" or "ENERGY" and the callback would be silently skipped.

function NugEnergy:Make5SRWatcher(default_callback)
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetScript("OnEvent", function(self, event, ...)
        return self[event](self, event, ...)
    end)

    local callback = default_callback
    local prevMana = UnitPower("player", 0)
    local lastManaDropTime = 0
    local lastSpellCastTime = 0
    local lastCallbackTime = 0

    local function tryCallback()
        local now = GetTime()
        if math.abs(lastSpellCastTime - lastManaDropTime) < 0.5
            and now - lastCallbackTime > 0.5 then
            -- Defer so UNIT_DISPLAYPOWER can fire first if this
            -- is an instant cast from a shapeshift form
            C_Timer.After(0, function()
                if NugEnergy:GetPowerFilter() == "MANA" then
                    lastCallbackTime = GetTime()
                    callback(NugEnergy)
                end
            end)
        end
    end

    f.UNIT_SPELLCAST_SUCCEEDED = function(self, event, unit)
        if unit == "player" then
            lastSpellCastTime = GetTime()
            tryCallback()
        end
    end

    f.UNIT_POWER_UPDATE = function(self, event, unit, ptype)
        if ptype == "MANA" then
            local mana = UnitPower("player", 0)
            if mana < prevMana then
                lastManaDropTime = GetTime()
                tryCallback()
            end
            prevMana = mana
        end
    end

    -- Both events stay registered permanently so we never miss an instant
    -- cast that fires before UNIT_DISPLAYPOWER switches the config.
    -- The deferred PowerFilter check keeps it safe during rage/energy configs.
    f.Enable = function(self, new_callback)
        prevMana = UnitPower("player", 0)
        self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        self:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
        if new_callback then callback = new_callback end
    end

    f.Disable = function(self) end

    f.GetLastManaSpentTime = function(self)
        return lastManaDropTime
    end

    f:Enable()
    return f
end
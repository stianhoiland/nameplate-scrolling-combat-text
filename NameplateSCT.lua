---------------
-- LIBRARIES --
---------------
local AceAddon = LibStub("AceAddon-3.0");
local LibEasing = LibStub("LibEasing-1.0");

NameplateSCT = AceAddon:NewAddon("NameplateSCT", "AceConsole-3.0", "AceEvent-3.0");
NameplateSCT.frame = CreateFrame("Frame", "NameplateSCT.frame", UIParent);


------------
-- LOCALS --
------------
local _;
local unitToGuid = {};
local guidToUnit = {};
local nameplateFontStrings = {};
local animating = {};
local playerGUID;

local damageTypeColors = {
    [SCHOOL_MASK_PHYSICAL] = "FFFF00",
    [SCHOOL_MASK_HOLY] = "FFE680",
    [SCHOOL_MASK_FIRE] = "FF8000",
    [SCHOOL_MASK_NATURE] = "4DFF4D",
    [SCHOOL_MASK_FROST] = "80FFFF",
    [SCHOOL_MASK_SHADOW] = "8080FF",
    [SCHOOL_MASK_ARCANE] = "FF80FF",
};


--------
-- DB --
--------
local defaults = {
    global = {
        enabled = true,
        damageColor = true,
        defaultColor = "FFFFFF",
        useOffTarget = true,
        truncate = true,
        truncateLetter = true,
        embiggenCrits = true,
        embiggenCritsScale = 1.5,
        font = [[Interface\Addons\SharedMedia\fonts\bazooka\Bazooka.ttf]],
        yOffset = 0,

        animations = {
            normal = "fountain",
            crit = "vertical",
        },

        formatting = {
            size = 15,
            icon = "right",
            alpha = 1,
        },

        offTargetFormatting = {
            size = 15,
            icon = "none",
            alpha = 0.75,
        },
    },
};


----------------------
-- FONTSTRING CACHE --
----------------------
local fontStringCache = {};
local function getFontString()
    local fontString;

    if (next(fontStringCache)) then
        fontString = table.remove(fontStringCache);
    else
        fontString = NameplateSCT.frame:CreateFontString();
    end

    fontString:SetFont(NameplateSCT.db.global.font, 15, "OUTLINE")
    fontString:SetAlpha(1);
    fontString:SetDrawLayer("OVERLAY", 7);
    fontString:SetText("");
    fontString:Show();

    return fontString;
end

local function recycleFontString(fontString)
    fontString:SetAlpha(0);
    fontString:Hide();

    nameplateFontStrings[fontString.unit][fontString] = nil;
    animating[fontString] = nil;

    fontString.distance = nil;
    fontString.arcTop = nil;
    fontString.arcBottom = nil;
    fontString.arcXDist = nil;
    fontString.deflection = nil;
    fontString.numShakes = nil;
    fontString.animation = nil;
    fontString.animatingDuration = nil;
    fontString.animatingStartTime = nil;
    fontString.anchorFrame = nil;

    table.insert(fontStringCache, fontString);
end


----------
-- CORE --
----------
function NameplateSCT:OnInitialize()
    -- setup db
    self.db = LibStub("AceDB-3.0"):New("NameplateSCTDB", defaults, true);

    -- setup chat commands
    self:RegisterChatCommand("nsct", "OpenMenu");

    -- setup menu
    self:RegisterMenu();

    -- if the addon is turned off in db, turn it off
    if (self.db.global.enabled == false) then
        self:Disable();
    end
end

function NameplateSCT:OnEnable()
    playerGUID = UnitGUID("player");

    self:RegisterEvent("NAME_PLATE_UNIT_ADDED");
    self:RegisterEvent("NAME_PLATE_UNIT_REMOVED");
    self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED");

    self.db.global.enabled = true;
end

function NameplateSCT:OnDisable()
    self:UnregisterAllEvents();

    for fontString, _ in pairs(animating) do
        recycleFontString(fontString);
    end

    self.db.global.enabled = false;
end


---------------
-- ANIMATION --
---------------
local function verticalLinearPath(progress, distance)
    return 0, progress * distance;
end

local function arcPath(progress, xDist, yStart, yTop, yBottom)
    local x, y;

    x = progress * xDist;

    -- progress 0 to 1
    -- at progress 0, y = yStart
    -- at progress 0.5 y = yTop
    -- at progress 1 y = yBottom

    -- -0.25a + .5b + yStart = yTop
    -- -a + b + yStart = yBottom

    -- -0.25a + .5b + yStart = yTop
    -- .5b + yStart - yTop = 0.25a
    -- 2b + 4yStart - 4yTop = a

    -- -(2b + 4yStart - 4yTop) + b + yStart = yBottom
    -- -2b - 4yStart + 4yTop + b + yStart = yBottom
    -- -b - 3yStart + 4yTop = yBottom

    -- -3yStart + 4yTop - yBottom = b

    -- 2(-3yStart + 4yTop - yBottom) + 4yStart - 4yTop = a
    -- -6yStart + 8yTop - 2yBottom + 4yStart - 4yTop = a
    -- -2yStart + 4yTop - 2yBottom = a

    -- -3yStart + 4yTop - yBottom = b
    -- -2yStart + 4yTop - 2yBottom = a

    local a = -2 * yStart + 4 * yTop - 2 * yBottom;
    local b = -3 * yStart + 4 * yTop - yBottom;

    y = -a * math.pow(progress, 2) + b * progress + yStart;

    return x, y;
end

local function AnimationOnUpdate()
    if (next(animating)) then
        for fontString, _ in pairs(animating) do
            if (GetTime() - fontString.animatingStartTime > fontString.animatingDuration or UnitIsDead(fontString.unit) or not fontString.anchorFrame or not fontString.anchorFrame:IsShown()) then
                -- the animation is over or the unit it was attached to is dead
                recycleFontString(fontString);
            else
                -- alpha
                local startAlpha = NameplateSCT.db.global.formatting.alpha;
                if (NameplateSCT.db.global.useOffTarget and not UnitIsUnit(fontString.unit, "target")) then
                    startAlpha = NameplateSCT.db.global.offTargetFormatting.alpha;
                end

                local alpha = LibEasing.InExpo(GetTime() - fontString.animatingStartTime, startAlpha, -startAlpha, fontString.animatingDuration);
                fontString:SetAlpha(alpha);

                -- position
                local xOffset, yOffset;
                if (fontString.animation == "vertical") then
                    local posProgress = LibEasing.InQuad(GetTime() - fontString.animatingStartTime, 0, 1, fontString.animatingDuration);
                    xOffset, yOffset = verticalLinearPath(posProgress, fontString.distance)
                elseif (fontString.animation == "fountain") then
                    local posProgress = LibEasing.Linear(GetTime() - fontString.animatingStartTime, 0, 1, fontString.animatingDuration);
                    xOffset, yOffset = arcPath(posProgress, fontString.arcXDist, 0, fontString.arcTop, fontString.arcBottom);
                elseif (fontString.animation == "shake") then
                    -- local progress = (GetTime() - fontString.animatingStartTime)/fontString.animatingDuration;
                    -- local shakeNum = math.floor(fontString.numShakes/progress);
                    -- local shakeProgress = progress - (shakeNum-1) * (fontString.animatingDuration/fontString.numShakes);
                    xOffset = 0;
                    yOffset = 0;
                end

                fontString:SetPoint("CENTER", fontString.anchorFrame, "CENTER", xOffset, NameplateSCT.db.global.yOffset + yOffset);
            end
        end
    else
        -- nothing in the animation list, so just kill the onupdate
        NameplateSCT.frame:SetScript("OnUpdate", nil);
    end
end

local arcDirection = 1;
function NameplateSCT:Animate(fontString, anchorFrame, duration, animation)
    animation = animation or "vertical";

    fontString.animation = animation;
    fontString.animatingDuration = duration;
    fontString.animatingStartTime = GetTime();
    fontString.anchorFrame = anchorFrame;

    if (animation == "vertical") then
        fontString.distance = 100;
    elseif (animation == "fountain") then
        fontString.arcTop = math.random(10, 75);
        fontString.arcBottom = -math.random(10, 150);
        fontString.arcXDist = arcDirection * math.random(50, 150);
        arcDirection = arcDirection * -1;
    elseif (animation == "shake") then
        fontString.deflection = 15;
        fontString.numShakes = 4;
    end

    animating[fontString] = true;

    if (NameplateSCT.frame:GetScript("OnUpdate") == nil) then
        NameplateSCT.frame:SetScript("OnUpdate", AnimationOnUpdate);
    end
end


------------
-- EVENTS --
------------
function NameplateSCT:NAME_PLATE_UNIT_ADDED(event, unitID)
    local guid = UnitGUID(unitID);

    unitToGuid[unitID] = guid;
    guidToUnit[guid] = unitID;
    nameplateFontStrings[unitID] = {};
end

function NameplateSCT:NAME_PLATE_UNIT_REMOVED(event, unitID)
    local guid = unitToGuid[unitID];

    unitToGuid[unitID] = nil;
    guidToUnit[guid] = nil;

    for fontString, _ in pairs(nameplateFontStrings[unitID]) do
        recycleFontString(fontString);
    end

    nameplateFontStrings[unitID] = nil;
end

function NameplateSCT:COMBAT_LOG_EVENT_UNFILTERED(event, time, cle, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags, ...)
    -- only use player events (or their pet/guardian)
    if ((playerGUID == sourceGUID)
        or (((bit.band(sourceFlags, COMBATLOG_OBJECT_TYPE_GUARDIAN) > 0) or (bit.band(sourceFlags, COMBATLOG_OBJECT_TYPE_PET) > 0)) and bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) > 0)) then
        local destUnit = guidToUnit[destGUID];

        if (destUnit) then
            if (string.find(cle, "_DAMAGE")) then
                local spellID, spellName, spellSchool, amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing, isOffHand;

                if (string.find(cle, "SWING")) then
                    spellName, amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing, isOffHand = "melee", ...;
                else
                    spellID, spellName, spellSchool, amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing, isOffHand = ...;
                end

                self:DamageEvent(destUnit, spellID, amount, school, critical)
            elseif(string.find(cle, "_HEAL")) then
                local spellID, spellName, spellSchool, amount, overhealing, absorbed, critical = ...;

                self:HealEvent(destUnit, spellID, amount, critical);
            elseif(string.find(cle, "_MISSED")) then
                local spellID, spellName, spellSchool, missType, isOffHand, amountMissed;

                if (string.find(cle, "SWING")) then
                    missType, isOffHand, amountMissed = "melee", ...;
                else
                    spellID, spellName, spellSchool, missType, isOffHand, amountMissed = ...;
                end

                self:MissEvent(destUnit, spellID, missType);
            end
        end
    end
end


-------------
-- DISPLAY --
-------------
function NameplateSCT:DamageEvent(unit, spellID, amount, school, crit)
    local text, animation, size, icon, alpha;

    if (self.db.global.useOffTarget and not UnitIsUnit(unit, "target")) then
        size = self.db.global.offTargetFormatting.size;
        icon = self.db.global.offTargetFormatting.icon;
        alpha = self.db.global.offTargetFormatting.alpha;
    else
        size = self.db.global.formatting.size;
        icon = self.db.global.formatting.icon;
        alpha = self.db.global.formatting.alpha;
    end

    -- select an animation
    if (crit) then
        animation = self.db.global.animations.crit;
    else
        animation = self.db.global.animations.normal;
    end

    -- truncate
    if (self.db.global.truncate and amount >= 1000000 and self.db.global.truncateLetter) then
        text = string.format("%.1fM", amount / 1000000);
    elseif (self.db.global.truncate and amount >= 1000) then
        text = string.format("%.0f", amount / 1000);

        if (self.db.global.truncateLetter) then
            text = text.."k";
        end
    else
        text = tostring(amount);
    end

    -- color text
    if (self.db.global.damageColor and school and damageTypeColors[school]) then
        text = "|Cff"..damageTypeColors[school]..text.."|r";
    else
        text = "|Cff"..self.db.global.defaultColor..text.."|r";
    end

    -- add icons
    if (icon ~= "none" and spellID) then
        local iconText = "|T"..GetSpellTexture(spellID)..":0|t";

        if (icon == "both") then
            text = iconText..text..iconText;
        elseif (icon == "left") then
            text = iconText..text;
        elseif (icon == "right") then
            text = text..iconText;
        end
    end

    -- embiggen crit's size
    if (self.db.global.embiggenCrits and crit) then
        size = size * self.db.global.embiggenCritsScale;
    end

    self:DisplayText(unit, text, size, animation)
end

function NameplateSCT:MissEvent(unit, spellID, missType)
    -- TODO
end

function NameplateSCT:HealEvent(unit, spellID, amount, crit)
    -- TODO
end

function NameplateSCT:DisplayText(unit, text, size, animation)
    local fontString = getFontString();
    local nameplate = C_NamePlate.GetNamePlateForUnit(unit);

    if (nameplate) then
        fontString.unit = unit;
        fontString:SetText(text);
        fontString:SetFont(self.db.global.font, size or 15, "OUTLINE");

        nameplateFontStrings[unit][fontString] = true;

        -- animate the new fontString
        self:Animate(fontString, nameplate, 1.5, animation);
    end
end


-------------
-- OPTIONS --
-------------
local iconValues = {
    ["none"] = "No Icons",
    ["left"] = "Left Side",
    ["right"] = "Right Side",
    ["both"] = "Both Sides",
};

local animationValues = {
    ["shake"] = "Shake",
    ["vertical"] = "Vertical",
    ["fountain"] = "Fountain",
};

local menu = {
    name = "NameplateSCT",
    handler = NameplateSCT,
    type = 'group',
    args = {
        enable = {
            type = 'toggle',
            name = "Enable",
            desc = "If the addon is enabled.",
            get = "IsEnabled",
            set = function(_, newValue) if (not newValue) then NameplateSCT:Disable(); else NameplateSCT:Enable(); end end,
            order = 1,
        },

        animations = {
            type = 'group',
            name = "Animations",
            order = 80,
            inline = true,
            args = {
                normal = {
                    type = 'select',
                    name = "Default",
                    desc = "",
                    get = function() return NameplateSCT.db.global.animations.normal; end,
                    set = function(_, newValue) NameplateSCT.db.global.animations.normal = newValue; end,
                    values = animationValues,
                    order = 1,
                },
                crit = {
                    type = 'select',
                    name = "Criticals",
                    desc = "",
                    get = function() return NameplateSCT.db.global.animations.crit; end,
                    set = function(_, newValue) NameplateSCT.db.global.animations.crit = newValue; end,
                    values = animationValues,
                    order = 2,
                },
            },
        },

        formatting = {
            type = 'group',
            name = "Text Appearence",
            order = 90,
            inline = true,
            args = {
                truncate = {
                    type = 'toggle',
                    name = "Truncate Number",
                    desc = "",
                    get = function() return NameplateSCT.db.global.truncate; end,
                    set = function(_, newValue) NameplateSCT.db.global.truncate = newValue; end,
                    order = 1,
                },
                truncateLetter = {
                    type = 'toggle',
                    name = "Show Truncated Letter",
                    desc = "",
                    disabled = function() return not NameplateSCT.db.global.truncate; end,
                    get = function() return NameplateSCT.db.global.truncateLetter; end,
                    set = function(_, newValue) NameplateSCT.db.global.truncateLetter = newValue; end,
                    order = 2,
                },
                damageColor = {
                    type = 'toggle',
                    name = "Use Damage Type Color",
                    desc = "",
                    get = function() return NameplateSCT.db.global.damageColor; end,
                    set = function(_, newValue) NameplateSCT.db.global.damageColor = newValue; end,
                    order = 20,
                },

                icon = {
                    type = 'select',
                    name = "Icon",
                    desc = "",
                    get = function() return NameplateSCT.db.global.formatting.icon; end,
                    set = function(_, newValue) NameplateSCT.db.global.formatting.icon = newValue; end,
                    values = iconValues,
                    order = 51,
                },
                size = {
                    type = 'range',
                    name = "Size",
                    desc = "",
                    min = 5,
                    max = 72,
                    step = 1,
                    get = function() return NameplateSCT.db.global.formatting.size; end,
                    set = function(_, newValue) NameplateSCT.db.global.formatting.size = newValue; end,
                    order = 52,
                },
                alpha = {
                    type = 'range',
                    name = "Start Alpha",
                    desc = "",
                    min = 0.1,
                    max = 1,
                    step = .01,
                    get = function() return NameplateSCT.db.global.formatting.alpha; end,
                    set = function(_, newValue) NameplateSCT.db.global.formatting.alpha = newValue; end,
                    order = 53,
                },

                useOffTarget = {
                    type = 'toggle',
                    name = "Use Seperate Off-Target Text Appearence",
                    desc = "",
                    get = function() return NameplateSCT.db.global.useOffTarget; end,
                    set = function(_, newValue) NameplateSCT.db.global.useOffTarget = newValue; end,
                    order = 100,
                    width = "full",
                },
                offTarget = {
                    type = 'group',
                    name = "Off-Target Text Appearence",
                    hidden = function() return not NameplateSCT.db.global.useOffTarget; end,
                    order = 101,
                    inline = true,
                    args = {
                        icon = {
                            type = 'select',
                            name = "Icon",
                            desc = "",
                            get = function() return NameplateSCT.db.global.offTargetFormatting.icon; end,
                            set = function(_, newValue) NameplateSCT.db.global.offTargetFormatting.icon = newValue; end,
                            values = iconValues,
                            order = 1,
                        },
                        size = {
                            type = 'range',
                            name = "Size",
                            desc = "",
                            min = 5,
                            max = 72,
                            step = 1,
                            get = function() return NameplateSCT.db.global.offTargetFormatting.size; end,
                            set = function(_, newValue) NameplateSCT.db.global.offTargetFormatting.size = newValue; end,
                            order = 2,
                        },
                        alpha = {
                            type = 'range',
                            name = "Start Alpha",
                            desc = "",
                            min = 0.1,
                            max = 1,
                            step = .01,
                            get = function() return NameplateSCT.db.global.offTargetFormatting.alpha; end,
                            set = function(_, newValue) NameplateSCT.db.global.offTargetFormatting.alpha = newValue; end,
                            order = 3,
                        },
                    },
                },
            },
        },
    },
};

function NameplateSCT:OpenMenu()
    -- just open to the frame, double call because blizz bug
    InterfaceOptionsFrame_OpenToCategory(self.menu);
    InterfaceOptionsFrame_OpenToCategory(self.menu);
end

function NameplateSCT:RegisterMenu()
    LibStub("AceConfigRegistry-3.0"):RegisterOptionsTable("NameplateSCT", menu);
    self.menu = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("NameplateSCT", "NameplateSCT");
end

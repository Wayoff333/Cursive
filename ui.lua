if not Cursive.nampower then
	return
end

local L = AceLibrary("AceLocale-2.2"):new("Cursive")

local utils = Cursive.utils
local filter = Cursive.filter

local ui = CreateFrame("Frame", "CursiveUI", UIParent)
-- Empirically-adjusted duration for the Shadow Vulnerability local
-- countdown timer -- see comment at its usage for why this isn't 12s.
local SHADOW_VULN_DURATION = 9
-- Registry of currently-expiring curse icon frames that should flash.
-- Populated/cleared during row updates, animated by a shared ticker below.
ui.flashingCurseIcons = {}

ui.border = {
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 8,
	insets = { left = 2, right = 2, top = 2, bottom = 2 }
}

ui.background = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	tile = true, tileSize = 16, edgeSize = 8,
	insets = { left = 0, right = 0, top = 0, bottom = 0 }
}

ui.rootBarFrame = nil
ui.targetIndicatorSize = 8
ui.padding = 2

ui.row = 1
ui.col = 1
ui.maxBarsDisplayed = false
ui.numDisplayed = 0

local function GetBarFirstSectionWidth()
	local config = Cursive.db.profile

	local size = 1
	if config.showraidicons then
		size = size + config.raidiconsize
	end
	if config.showtargetindicator then
		size = size + ui.targetIndicatorSize
	end
	if size > 0 then
		size = size + ui.padding
	end

	return size
end

local function GetBarSecondSectionWidth()
	local config = Cursive.db.profile

	if config.showhealthbar == false and config.showunitname == false then
		return 1
	end

	return config.healthwidth + ui.padding
end

local function GetBarThirdSectionWidth()
	local config = Cursive.db.profile

	return config.maxcurses * (config.curseiconsize + ui.padding)
end

local function GetBarWidth()
	return GetBarFirstSectionWidth() +
			GetBarSecondSectionWidth() +
			GetBarThirdSectionWidth()
end

local function UpdateRootBarFrame()
	local config = Cursive.db.profile

	if config.showbackdrop then
		ui.rootBarFrame:SetBackdrop(ui.background)
	else
		ui.rootBarFrame:SetBackdrop(nil)
	end

	ui.rootBarFrame:EnableMouse(not config.clickthrough)

	ui.rootBarFrame.pos = config.anchor .. config.x .. config.y .. config.scale
	ui.rootBarFrame:ClearAllPoints()
	ui.rootBarFrame:SetPoint(config.anchor, config.x, config.y)

	ui.rootBarFrame:SetScale(config.scale)

	ui.rootBarFrame.caption:SetFont(STANDARD_TEXT_FONT, Cursive.db.profile.textsize, "THINOUTLINE")
	ui.rootBarFrame.caption:SetText(Cursive.db.profile.caption)
	if Cursive.db.profile.showtitle then
		ui.rootBarFrame.caption:Show()
	else
		ui.rootBarFrame.caption:Hide()
	end

	ui.rootBarFrame:SetWidth(config.maxcol * GetBarWidth())
	-- Calculate height: title area + GCD bar (if shown) + all rows + extra spacing
	local title_size = 12 + config.spacing
	local gcdbar_size = config.showgcdbar and (config.gcdbarheight + config.spacing) or 0
	local total_height = title_size + gcdbar_size + (config.maxrow * (config.height + config.spacing)) + config.spacing
	ui.rootBarFrame:SetHeight(total_height)

	-- GCD swing-timer bar: thin strip spanning the frame width, sitting
	-- just below the title caption and above the first row of bars.
	if ui.rootBarFrame.gcdBar then
		ui.rootBarFrame.gcdBar:SetHeight(config.gcdbarheight)
		ui.rootBarFrame.gcdBar:SetWidth(config.gcdbarwidth)
		ui.rootBarFrame.gcdBar:SetStatusBarTexture(config.bartexture)
		ui.rootBarFrame.gcdBar:SetStatusBarColor(config.gcdbarcolor.r, config.gcdbarcolor.g, config.gcdbarcolor.b, 0.9)
		ui.rootBarFrame.gcdBar.enabled = config.showgcdbar
		if not config.showgcdbar then
			ui.rootBarFrame.gcdBar:Hide()
		end
	end
end

local function CreateRoot()
	local frame = CreateFrame("Frame", Cursive.db.profile.caption, UIParent)
	ui.rootBarFrame = frame

	frame.id = Cursive.db.profile.caption

	frame:RegisterForDrag("LeftButton")
	frame:SetMovable(true)

	frame:SetScript("OnDragStart", function()
		this.lock = true
		this:StartMoving()
	end)

	frame:SetScript("OnDragStop", function()
		-- convert to best anchor depending on position
		local new_anchor = utils.GetBestAnchor(this)
		local anchor, x, y = utils.ConvertFrameAnchor(this, new_anchor)
		this:ClearAllPoints()
		this:SetPoint(anchor, UIParent, anchor, x, y)

		-- save new position
		anchor, _, _, x, y = this:GetPoint()
		Cursive.db.profile.anchor, Cursive.db.profile.x, Cursive.db.profile.y = anchor, x, y

		-- stop drag
		this:StopMovingOrSizing()
		this.lock = false

		this:ClearAllPoints()
		this:SetPoint(anchor, x, y)
	end)

	-- create title text
	frame.caption = frame:CreateFontString(nil, "HIGH", "GameFontWhite")
	frame.caption:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -2)
	frame.caption:SetTextColor(1, 1, 1, 1)

	-- GCD swing-timer bar
	local gcdBar = CreateFrame("StatusBar", "CursiveGcdBar", frame)
	gcdBar:SetHeight(Cursive.db.profile.gcdbarheight)
	gcdBar:SetWidth(Cursive.db.profile.gcdbarwidth)
	gcdBar:SetPoint("TOPLEFT", frame.caption, "BOTTOMLEFT", -8, -2)
	gcdBar:SetStatusBarTexture(Cursive.db.profile.bartexture)
	gcdBar:SetStatusBarColor(Cursive.db.profile.gcdbarcolor.r, Cursive.db.profile.gcdbarcolor.g, Cursive.db.profile.gcdbarcolor.b, 0.9)
	gcdBar:SetMinMaxValues(0, 1)
	gcdBar:SetValue(0)
	gcdBar.enabled = Cursive.db.profile.showgcdbar

	local gcdBarBg = gcdBar:CreateTexture(nil, "BACKGROUND")
	gcdBarBg:SetAllPoints(gcdBar)
	gcdBarBg:SetTexture(0, 0, 0)
	gcdBarBg:SetAlpha(0.4)

	gcdBar:Hide()
	frame.gcdBar = gcdBar

	UpdateRootBarFrame()

	frame:Show()

	return frame
end

ui.unitFrames = {} -- holds all unitFrames for all columns/rows

Cursive.UpdateFramesFromConfig = function()
	for col, rows in pairs(ui.unitFrames) do
		for row, unitFrame in pairs(rows) do
			if unitFrame and unitFrame:IsShown() then
				unitFrame:Hide()
			end
		end
	end

	if ui.rootBarFrame then
		UpdateRootBarFrame()
	end

	-- after 3 seconds reset the unit frames so all changes are applied
	Cursive:ScheduleEvent("resetUnitFrames", Cursive.ResetUnitFrames, 3)
end

Cursive.ResetUnitFrames = function()
	-- hide all existing unit frames
	for col, rows in pairs(ui.unitFrames) do
		for row, unitFrame in pairs(rows) do
			if unitFrame and unitFrame:IsShown() then
				unitFrame:Hide()
			end
		end
	end
	-- clear cached frames so they are recreated
	ui.unitFrames = {}
end

ui.BarEnter = function()
	if this.parent.healthBar then
		this.parent.healthBar.border:SetBackdropBorderColor(1, 1, 1, 1)
	end
	this.parent.hover = true

  SetMouseoverUnit(this.parent.guid)
	GameTooltip_SetDefaultAnchor(GameTooltip, this)
	GameTooltip:SetUnit(this.parent.guid)
	GameTooltip:Show()
end

ui.BarLeave = function()
	this.parent.hover = false
  SetMouseoverUnit()
	GameTooltip:Hide()
end

ui.BarUpdate = function()
	if not this.guid or this.guid == 0 then
		this:Hide()
		return
	end

	if (this.tick or 1) > GetTime() then
		return
	else
		this.tick = GetTime() + 0.05
	end

	-- update statusbar values if it exists
	if this.healthBar then
		this.healthBar:SetMinMaxValues(0, UnitHealthMax(this.guid))
		this.healthBar:SetValue(UnitHealth(this.guid))

		-- update health bar color
		local hex, r, g, b, a = utils.GetUnitColor(this.guid)
		this.healthBar:SetStatusBarColor(r, g, b, a)

		-- update health bar border
		if this.healthBar.border then
			if this.hover then
				this.healthBar.border:SetBackdropBorderColor(1, 1, 1, 1)
			elseif UnitAffectingCombat(this.guid) then
				this.healthBar.border:SetBackdropBorderColor(.8, .2, .2, 1)
			else
				this.healthBar.border:SetBackdropBorderColor(.2, .2, .2, 1)
			end
		end
	end

	-- update caption text
	local name = UnitName(this.guid)
	if name and this.nameText then
		this.nameText:SetText(name)
	end

	if this.hpText then
		local hp = UnitHealth(this.guid)
		if GetLocale() == "zhCN" then
			if hp then
				if hp >= 10000 then
					hp = math.floor(hp / 1000) / 10 .. "万"
					-- elseif hp >= 1000 then
					-- 	hp = math.floor(hp / 100) / 10 .. "k"
				end
			end
		else
			-- convert hp to k if > 1000
			if hp then
				if hp >= 1000000 then
					hp = math.floor(hp / 100000) / 10 .. "m"
				elseif hp >= 1000 then
					hp = math.floor(hp / 100) / 10 .. "k"
				end
			end
		end

		if hp then
			this.hpText:SetText(hp)
		end
	end

	-- show raid icon if existing
	if this.icon then
		if GetRaidTargetIndex(this.guid) and Cursive.filter.alive(this.guid) then
			SetRaidTargetIconTexture(this.icon, GetRaidTargetIndex(this.guid))
			this.icon:Show()
		else
			this.icon:Hide()
		end
	end

	-- update target indicator
	if this.target_left then
		if UnitIsUnit("target", this.guid) then
			this.target_left:Show()
		else
			this.target_left:Hide()
		end
	end
end

ui.BarClick = function()
	if arg1 == "LeftButton" then
		TargetUnit(this.parent.guid)
	elseif arg1 == "RightButton" then
		TargetUnit(this.parent.guid)
		if (not PlayerFrame.inCombat) then
			AttackTarget()
		end
	end
end

local function CreateBarFirstSection(unitFrame, guid)
	local config = Cursive.db.profile
	local firstSection = CreateFrame("Frame", "Cursive1stSection", unitFrame)

	if config.invertbars then
		-- When inverted, position relative to second section (rightmost)
		firstSection:SetPoint("LEFT", unitFrame.secondSection, "RIGHT", 0, 0)
	else
		-- Normal positioning (leftmost)
		firstSection:SetPoint("LEFT", unitFrame, "LEFT", 0, 0)
	end
	
	firstSection:SetWidth(GetBarFirstSectionWidth())
	firstSection:SetHeight(config.height)
	firstSection:EnableMouse(false)
	unitFrame.firstSection = firstSection

	-- create target indicator
	if config.showtargetindicator then
		local targetLeft = firstSection:CreateTexture(nil, "OVERLAY")
		targetLeft:SetWidth(ui.targetIndicatorSize)
		targetLeft:SetHeight(8)
		if config.invertbars then
			targetLeft:SetPoint("RIGHT", firstSection, "RIGHT", 0, 0)
			targetLeft:SetTexture("Interface\\AddOns\\Cursive\\img\\target-right")
		else
			targetLeft:SetPoint("LEFT", unitFrame, "LEFT", 0, 0)
			targetLeft:SetTexture("Interface\\AddOns\\Cursive\\img\\target-left")
		end
		targetLeft:Hide()
		unitFrame.target_left = targetLeft
	end

	-- create raid icon textures
	if config.showraidicons then
		local icon = firstSection:CreateTexture(nil, "OVERLAY")
		icon:SetWidth(config.raidiconsize)
		icon:SetHeight(config.raidiconsize)
		if config.invertbars then
			icon:SetPoint("LEFT", firstSection, "LEFT", 0, 0)
		else
			icon:SetPoint("RIGHT", firstSection, "RIGHT", 0, 0)
		end
		icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
		icon:Hide()
		unitFrame.icon = icon
	end
end

local function CreateBarSecondSection(unitFrame, guid)
	local config = Cursive.db.profile
	local secondSection = CreateFrame("Button", "Cursive2ndSection", unitFrame)

	if config.invertbars then
		-- When inverted, position relative to third section (which is created first)
		secondSection:SetPoint("LEFT", unitFrame.thirdSection, "RIGHT", 0, 0)
	else
		-- Normal positioning relative to first section
		secondSection:SetPoint("LEFT", unitFrame.firstSection, "RIGHT", 0, 0)
	end
	
	secondSection:SetWidth(GetBarSecondSectionWidth())
	secondSection:SetHeight(config.height)
	unitFrame.secondSection = secondSection
	secondSection.parent = unitFrame

	secondSection:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	secondSection:SetScript("OnClick", ui.BarClick)
	secondSection:SetScript("OnEnter", ui.BarEnter)
	secondSection:SetScript("OnLeave", ui.BarLeave)

	-- create health bar
	if config.showhealthbar then
		local healthBar = CreateFrame("StatusBar", "CursiveHealthBar", secondSection)
		healthBar:SetStatusBarTexture(config.bartexture)
		healthBar:SetStatusBarColor(1, .8, .2, 1)
		healthBar:SetMinMaxValues(0, 100)
		healthBar:SetValue(20)
		healthBar:SetPoint("LEFT", secondSection, "LEFT", ui.padding, 0)
		healthBar:SetWidth(config.healthwidth)
		healthBar:SetHeight(config.height)
		unitFrame.healthBar = healthBar

		local hp = healthBar:CreateFontString(nil, "HIGH", "GameFontWhite")
		hp:SetPoint("TOPRIGHT", healthBar, "TOPRIGHT", -2, -2)
		hp:SetWidth(30)
		hp:SetHeight(config.height - 4)
		hp:SetFont(STANDARD_TEXT_FONT, config.textsize, "THINOUTLINE")
		hp:SetJustifyH("RIGHT")
		unitFrame.hpText = hp

		if config.showunitname then
			local name = healthBar:CreateFontString(nil, "HIGH", "GameFontWhite")
			name:SetPoint("TOPLEFT", healthBar, "TOPLEFT", 2, -2)
			name:SetPoint("BOTTOMRIGHT", hp, "BOTTOMLEFT", 2, 0)
			name:SetFont(STANDARD_TEXT_FONT, config.textsize, "THINOUTLINE")
			name:SetJustifyH("LEFT")
			unitFrame.nameText = name
		end

		-- create health bar backdrops
		if pfUI and pfUI.uf then
			pfUI.api.CreateBackdrop(healthBar)
			healthBar.border = healthBar.backdrop
		else
			healthBar:SetBackdrop(ui.background)
			healthBar:SetBackdropColor(0, 0, 0, 1)

			local border = CreateFrame("Frame", "CursiveBorder", healthBar.bar)
			border:SetBackdrop(ui.border)
			border:SetBackdropColor(.2, .2, .2, 1)
			border:SetPoint("TOPLEFT", healthBar.bar, "TOPLEFT", -2, 2)
			border:SetPoint("BOTTOMRIGHT", healthBar.bar, "BOTTOMRIGHT", 2, -2)
			healthBar.border = border
		end
	else
		if config.showunitname then
			local name = secondSection:CreateFontString(nil, "HIGH", "GameFontWhite")
			name:SetPoint("TOPLEFT", secondSection, "TOPLEFT", 2, -2)
			name:SetPoint("BOTTOMRIGHT", secondSection, "BOTTOMRIGHT", 2, 0)
			name:SetFont(STANDARD_TEXT_FONT, config.textsize, "THINOUTLINE")
			name:SetWidth(config.healthwidth)
			name:SetHeight(config.height - 4)
			name:SetJustifyH("LEFT")
			unitFrame.nameText = name
		end
	end
end

local function CreateBarThirdSection(unitFrame, guid)
	local config = Cursive.db.profile

	local thirdSection = CreateFrame("Frame", "Cursive3rdSection", unitFrame)

	if config.invertbars then
		-- When inverted, this is positioned first (leftmost)
		thirdSection:SetPoint("LEFT", unitFrame, "LEFT", 0, 0)
	else
		-- Normal positioning relative to second section
		thirdSection:SetPoint("LEFT", unitFrame.secondSection, "RIGHT", 0, 0)
	end
	
	thirdSection:SetWidth(GetBarThirdSectionWidth())
	thirdSection:SetHeight(config.height)
	thirdSection:EnableMouse(false)
	unitFrame.thirdSection = thirdSection

	-- display up to maxcurses curses
	for i = 1, config.maxcurses do
		local curse = thirdSection:CreateTexture(nil, "OVERLAY")
		curse:SetWidth(config.curseiconsize)
		curse:SetHeight(config.curseiconsize)

		if config.invertbars then
			-- When inverted, position from right to left
			local rightOffset = i * ui.padding + ((i - 1) * config.curseiconsize)
			curse:SetPoint("RIGHT", thirdSection, "RIGHT", -rightOffset, 0)
		else
			-- Normal positioning from left to right
			curse:SetPoint("LEFT", thirdSection, "LEFT", i * ui.padding + ((i - 1) * config.curseiconsize), 0)
		end

		curse.timer = thirdSection:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		curse.timer:SetFontObject(GameFontHighlight)
		curse.timer:SetFont(STANDARD_TEXT_FONT, config.cursetimersize, "OUTLINE")
		curse.timer:SetTextColor(1, 1, 1)
		curse.timer:SetAllPoints(curse)

		curse.timer:Hide()
		curse:Hide()
		unitFrame["curse" .. i] = curse
	end

	-- Ghost icons: faded icons showing missing curse/DoT(s) to cast on
	-- this target. One frame per possible slot (same count as real curse
	-- icons), so "show all missing" mode can display several at once.
	-- Repositioned dynamically on each refresh to slot into wherever the
	-- next real curse icon would actually go.
	unitFrame.ghostIcons = {}
	for i = 1, config.maxcurses do
		local ghost = thirdSection:CreateTexture(nil, "OVERLAY")
		ghost:SetWidth(config.curseiconsize)
		ghost:SetHeight(config.curseiconsize)
		ghost:SetAlpha(config.ghosticonalpha)
		ghost:Hide()
		unitFrame.ghostIcons[i] = ghost
	end

	-- Shadow Vulnerability indicator: always claims slot 1 when enabled.
	-- Dim (ghost-like) when inactive, brightens and flashes when actually
	-- active -- position gets set dynamically on each refresh.
	local shadowVulnIcon = thirdSection:CreateTexture(nil, "OVERLAY")
	shadowVulnIcon:SetWidth(config.curseiconsize)
	shadowVulnIcon:SetHeight(config.curseiconsize)
	shadowVulnIcon:SetTexture("Interface\\Icons\\Spell_Shadow_ShadowBolt")
	shadowVulnIcon:SetAlpha(0.3)

	shadowVulnIcon.timer = thirdSection:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	shadowVulnIcon.timer:SetFontObject(GameFontHighlight)
	shadowVulnIcon.timer:SetFont(STANDARD_TEXT_FONT, config.cursetimersize, "OUTLINE")
	shadowVulnIcon.timer:SetTextColor(1, 1, 1)
	shadowVulnIcon.timer:SetAllPoints(shadowVulnIcon)
	shadowVulnIcon.timer:Hide()

	shadowVulnIcon:Hide()
	unitFrame.shadowVulnIcon = shadowVulnIcon
end

local function CreateBar(row, col, guid)
	local unitFrame = CreateFrame("Frame", "CursiveUnitFrame", ui.rootBarFrame)
	unitFrame.guid = guid

	unitFrame:SetScript("OnUpdate", ui.BarUpdate)

	local config = Cursive.db.profile
	local width = GetBarWidth()
	unitFrame:SetWidth(width)
	unitFrame:SetHeight(config.height)

	local config = Cursive.db.profile
	if config.invertbars then
		-- Create sections in reverse order: 3 -> 2 -> 1
		CreateBarThirdSection(unitFrame, guid)
		CreateBarSecondSection(unitFrame, guid)
		CreateBarFirstSection(unitFrame, guid)
	else
		-- Normal order: 1 -> 2 -> 3
		CreateBarFirstSection(unitFrame, guid)
		CreateBarSecondSection(unitFrame, guid)
		CreateBarThirdSection(unitFrame, guid)
	end

	ui.unitFrames[col][row] = unitFrame
	return unitFrame
end

local function GetBarCords(row, col)
	local config = Cursive.db.profile
	local x = (col - 1) * GetBarWidth()
	local y
	if config.expandupwards then
		-- For upward expansion: start from bottom with spacing, then go up
		y = config.spacing + ((row - 1) * (config.height + config.spacing))
	else
		-- For downward expansion: use original logic (don't subtract 1 to account for header)
		local gcdOffset = config.showgcdbar and (config.gcdbarheight + config.spacing) or 0
		y = -(row * (config.height + config.spacing)) - gcdOffset
	end
	return x, y
end

local function hasAnySpellId(guid, spellIds)
	local auras = GetUnitField(guid, "aura")
	for i, spellId in pairs(auras) do
		if spellIds[spellId] then
			return spellId
		end
	end
	return nil
end

-- Priority list for the ghost icon: checks curse presence first (via
-- Cursive's own tracked curse data), then DoTs in order, returning the
-- icon path for whichever is missing first. Curse icon textures (CoE/CoS/
-- CoR/CoW) are confirmed-correct from prior testing; the DoT textures and
-- the Curse of Agony fallback below are reasonable but UNVERIFIED guesses
-- -- worth checking in-game and reporting back if any look wrong.
local GHOST_DOT_ICONS = {
	{ name = "Corruption",  texture = "Spell_Shadow_AbominationExplosion", settingKey = "showghostcorruption" },
	{ name = "Immolate",    texture = "Spell_Fire_Immolation",             settingKey = "showghostimmolate" },
	{ name = "Siphon Life", texture = "Spell_Shadow_Requiem",              settingKey = "showghostsiphonlife" },
}
local GHOST_CURSE_FALLBACK_ICON = "Interface\\Icons\\Spell_Shadow_CurseOfSargeras" -- Curse of Agony

-- UnitDebuff(guid, i) via the GUID extension has been confirmed (via live
-- /cgd diagnostic) to sometimes return nothing at all for a guid, even
-- when that guid IS the player's own current target. Unit tokens are
-- always reliable, so substitute one whenever the guid matches something
-- checkable -- covers being directly targeted, or being your target's
-- target (common on bosses when tanking/watching a tank). Other tracked
-- guids (raid members' own targets etc) still have no equivalent safe
-- substitute without a broader token scan. Note: "focus" was tried here
-- too but removed -- confirmed via live error that vanilla 1.12 has no
-- focus frame support at all (that's a later-expansion addition), and
-- UnitExists("focus") hard-errors here rather than just returning nil.
local function SafeUnitDebuff(guid, i)
	local _, targetGuid = UnitExists("target")
	if targetGuid and guid == targetGuid then
		return UnitDebuff("target", i)
	end
	local _, totGuid = UnitExists("targettarget")
	if totGuid and guid == totGuid then
		return UnitDebuff("targettarget", i)
	end
	return UnitDebuff(guid, i)
end

local function GetGhostTextures(guid)
	local config = Cursive.db.profile
	local textures = {}

	-- Curse check: specifically checks Curse of Agony via Cursive's own
	-- tested HasCurse API, rather than a custom table check. This matters
	-- for Malediction warlocks -- casting Elements/Shadow/Recklessness also
	-- applies Agony, so "is any curse present" isn't the right question;
	-- what matters is whether Agony itself has fallen off and needs
	-- refreshing, even if another curse is technically still ticking.
	-- malediction=0 here since we're already asking about Agony directly,
	-- not one of the curses that would normally redirect to it.
	if config.showghostcurse then
		local hasCurse = Cursive.curses:HasCurse(L["curse of agony"], guid, 0, 0)
		if not hasCurse then
			table.insert(textures, GHOST_CURSE_FALLBACK_ICON)
			if not config.showallmissingghosts then
				return textures
			end
		end
	end

	-- DoT check: direct debuff scan via SuperWoW's GUID-based UnitDebuff,
	-- since these aren't part of Cursive's own curse tracking. Each DoT
	-- checked individually against its own toggle, since not everyone
	-- runs all three (e.g. pure Affliction warlocks often skip Immolate).
	for _, dot in ipairs(GHOST_DOT_ICONS) do
		if config[dot.settingKey] then
			local found = false
			local i = 1
			while true do
				local tex = SafeUnitDebuff(guid, i)
				if not tex then break end
				if string.find(tex, dot.texture, 1, true) then
					found = true
					break
				end
				i = i + 1
			end
			if not found then
				table.insert(textures, "Interface\\Icons\\" .. dot.texture)
				if not config.showallmissingghosts then
					return textures
				end
			end
		end
	end

	return textures -- empty if everything's up (or all checks disabled)
end

local function GetSortedCurses(guidCurses)
	-- Collect keys
	local curseNames = {}
	for key in pairs(guidCurses) do
		table.insert(curseNames, key)
	end

	if Cursive.db.profile.curseordering == L["Order applied"] then
		table.sort(curseNames, function(a, b)
			return guidCurses[a].start < guidCurses[b].start
		end)
	elseif Cursive.db.profile.curseordering == L["Expiring soonest -> latest"] then
		table.sort(curseNames, function(a, b)
			return Cursive.curses:TimeRemaining(guidCurses[a]) < Cursive.curses:TimeRemaining(guidCurses[b])
		end)
	elseif Cursive.db.profile.curseordering == L["Expiring latest -> soonest"] then
		table.sort(curseNames, function(a, b)
			return Cursive.curses:TimeRemaining(guidCurses[a]) > Cursive.curses:TimeRemaining(guidCurses[b])
		end)
	end

	local i = 0
	return function()
		i = i + 1
		local key = curseNames[i]
		if key then
			return key, guidCurses[key]
		end
	end
end

local function DisplayGuid(guid)
	if not ui.unitFrames[ui.col] then
		ui.unitFrames[ui.col] = {}
	end

	local unitFrame
	if ui.unitFrames[ui.col][ui.row] then
		unitFrame = ui.unitFrames[ui.col][ui.row]
		unitFrame.guid = guid
	else
		unitFrame = CreateBar(ui.row, ui.col, guid)
		ui.unitFrames[ui.col][ui.row] = unitFrame
	end

	local x, y = GetBarCords(ui.row, ui.col)

	-- update position if required
	local config = Cursive.db.profile
	if not unitFrame.pos or unitFrame.pos ~= x .. y then
		unitFrame:ClearAllPoints()
		if config.expandupwards then
			unitFrame:SetPoint("BOTTOMLEFT", ui.rootBarFrame, "BOTTOMLEFT", x, y)
		else
			unitFrame:SetPoint("TOPLEFT", ui.rootBarFrame, "TOPLEFT", x, y)
		end
		unitFrame.pos = x .. y
	end

	-- check for shared debuffs
	for sharedDebuffKey, guids in pairs(Cursive.curses.sharedDebuffGuids) do
		if guids[guid] then
			local sharedDebuffSpellIds = Cursive.curses.sharedDebuffs[sharedDebuffKey]
			local spellId = hasAnySpellId(guid, sharedDebuffSpellIds)
			if spellId ~= nil then
				-- add curse to curses
				Cursive.curses:ApplySharedCurse(sharedDebuffKey, spellId, guid, GetTime())
				-- remove guid
				Cursive.curses.sharedDebuffGuids[sharedDebuffKey][guid] = nil
			end
		end
	end

	-- update curses
	local cfg = Cursive.db.profile
	-- Shadow Vulnerability always claims slot 1 when enabled, so real
	-- curses/ghosts start filling from slot 2 instead.
	local curseNumber = cfg.notifyshadowvuln and 2 or 1

	-- Shadow Vulnerability indicator: always visible (dim) once enabled,
	-- brightens and flashes when actually active, rather than showing/
	-- hiding entirely -- reuses the same flash-ticker infrastructure as
	-- the (currently unused) curse-expiring flash.
	if cfg.notifyshadowvuln then
		local hasShadowVuln = false
		local i = 1
		while true do
			local tex = SafeUnitDebuff(guid, i)
			if not tex then break end
			if string.find(tex, "Spell_Shadow_ShadowBolt", 1, true) then
				hasShadowVuln = true
				break
			end
			i = i + 1
		end
		-- Preview mode: force the flashing state regardless of real debuff
		-- presence while previewing a flash-speed change in settings.
		if ui.shadowVulnPreviewUntil and GetTime() < ui.shadowVulnPreviewUntil then
			hasShadowVuln = true
		end
		unitFrame.shadowVulnIcon:ClearAllPoints()
		if cfg.invertbars then
			unitFrame.shadowVulnIcon:SetPoint("RIGHT", unitFrame.thirdSection, "RIGHT", -(1 * ui.padding), 0)
		else
			unitFrame.shadowVulnIcon:SetPoint("LEFT", unitFrame.thirdSection, "LEFT", 1 * ui.padding, 0)
		end
		unitFrame.shadowVulnIcon:Show()
		if hasShadowVuln then
			if not unitFrame.shadowVulnActive then
				-- Newly appeared -- start our own countdown, since this
				-- client has no API for a third party's remaining aura
				-- duration. Wowhead's classic spell page listed 12 seconds,
				-- but real observed behavior showed the icon disappearing
				-- ~3s before that countdown hit zero -- adjusted to 9s to
				-- match what's actually been seen in practice (Wowhead's
				-- value may reflect a different talent rank, or this
				-- server's own tuning differs from stock classic data).
				unitFrame.shadowVulnAppliedAt = GetTime()
			end
			unitFrame.shadowVulnActive = true
			local remaining = SHADOW_VULN_DURATION - (GetTime() - unitFrame.shadowVulnAppliedAt)
			if remaining > 0 then
				unitFrame.shadowVulnIcon.timer:SetText(math.ceil(remaining))
				unitFrame.shadowVulnIcon.timer:Show()
			else
				unitFrame.shadowVulnIcon.timer:Hide()
			end
			ui.flashingCurseIcons[unitFrame.shadowVulnIcon] = cfg.shadowvulnflashspeed
		else
			unitFrame.shadowVulnActive = false
			ui.flashingCurseIcons[unitFrame.shadowVulnIcon] = nil
			unitFrame.shadowVulnIcon:SetAlpha(0.3)
			unitFrame.shadowVulnIcon.timer:Hide()
		end
	else
		unitFrame.shadowVulnIcon:Hide()
		unitFrame.shadowVulnIcon.timer:Hide()
		unitFrame.shadowVulnActive = false
		ui.flashingCurseIcons[unitFrame.shadowVulnIcon] = nil
	end

	-- make sure old curses are hidden
	for i = 1, Cursive.db.profile.maxcurses do
		local curse = unitFrame["curse" .. i]
		curse:Hide()
		curse.timer:Hide()
		ui.flashingCurseIcons[curse] = nil
		curse:SetAlpha(1)
	end

	local guidCurses = Cursive.curses.guids[guid]
	if guidCurses then
		for curseName, curseData in GetSortedCurses(guidCurses) do
			if curseNumber > Cursive.db.profile.maxcurses then
				break
			end

			local remaining = Cursive.curses:TimeRemaining(curseData)
			local curse = unitFrame["curse" .. curseNumber]
			if remaining >= 0 then
        curse:SetTexture(Cursive.curses.trackedCurseIds[curseData.spellID].texture)

        if curseData["currentPlayer"] == false then
          curse:SetDesaturated(true); -- desaturate if not applied by current player
          curse:SetAlpha(Cursive.db.profile.othercursealpha or 1)
        else
          curse:SetDesaturated(false); -- saturate if applied by current player
          curse:SetAlpha(1)
        end

        -- curse:SetTexCoord(.078, .92, .079, .937) rounded icons
        curse.timer:SetText(remaining)
        curse.timer:Show()
        curse:Show()

      if remaining < 1 then
          if Cursive.curses:ShouldPlayExpiringSound(curseName, guid) then
            PlaySoundFile("Interface\\AddOns\\Cursive\\sounds\\expiring.mp3")
          end
        else
          if Cursive.curses:HasRequestedExpiringSound(curseName, guid) then
            Cursive.curses:EnableExpiringSound(curseName, guid)
          end
        end

        -- Flash check: independent, wider threshold than the sound's <1.
        -- Confirmed via live diagnostic earlier that "remaining" is
        -- integer-quantized and stays at 2 for nearly a full second --
        -- using <=2 catches that reliably-observed value directly, rather
        -- than gambling on 1/0 ever actually appearing before the curse
        -- disappears from the list entirely.
        if Cursive.db.profile.flashonexpiring and remaining <= 2 then
          ui.flashingCurseIcons[curse] = 3
        else
          ui.flashingCurseIcons[curse] = nil
          curse:SetAlpha(1)
        end

        curseNumber = curseNumber + 1
      end
		end
	end

	-- Hide all ghost slots first, matching the same pattern used for real
	-- curse icons above.
	for i = 1, cfg.maxcurses do
		if unitFrame.ghostIcons[i] then
			unitFrame.ghostIcons[i]:Hide()
		end
	end

	if cfg.showghostcurse or cfg.showghostcorruption or cfg.showghostimmolate or cfg.showghostsiphonlife then
		local ghostTextures = GetGhostTextures(guid)
		local slot = curseNumber
		for _, tex in ipairs(ghostTextures) do
			if slot > cfg.maxcurses then
				break
			end
			local ghostIcon = unitFrame.ghostIcons[slot]
			ghostIcon:ClearAllPoints()
			if cfg.invertbars then
				local rightOffset = slot * ui.padding + ((slot - 1) * cfg.curseiconsize)
				ghostIcon:SetPoint("RIGHT", unitFrame.thirdSection, "RIGHT", -rightOffset, 0)
			else
				ghostIcon:SetPoint("LEFT", unitFrame.thirdSection, "LEFT", slot * ui.padding + ((slot - 1) * cfg.curseiconsize), 0)
			end
			ghostIcon:SetTexture(tex)
			ghostIcon:SetDesaturated(cfg.ghosticongreyscale and true or false)
			ghostIcon:Show()
			slot = slot + 1
		end
	end

	unitFrame:Show()
	ui.numDisplayed = ui.numDisplayed + 1

	local config = Cursive.db.profile

	-- update row/col
	ui.row = ui.row + 1
	if ui.row > config.maxrow then
		ui.row = 1
		ui.col = ui.col + 1
		if ui.col > config.maxcol then
			ui.maxBarsDisplayed = true
		end
	end
end

local function CheckForCleanup(guid, time)
	local active = UnitExists(guid) and Cursive.filter.alive(guid)
	if active then
		local old = GetTime() - time >= 900 -- >= 15 minutes old
		if old and not UnitIsVisible(guid) then
			active = false
		end
	end

	if not active then
		-- remove from core
		Cursive.core.remove(guid)
		-- remove from curses
		Cursive.curses:RemoveGuid(guid)

		-- remove from sharedDebuffGuids
		for sharedDebuffKey, guids in pairs(Cursive.curses.sharedDebuffGuids) do
			if guids[guid] then
				Cursive.curses.sharedDebuffGuids[sharedDebuffKey][guid] = nil
			end
		end
	end
end

local shouldDisplayGuids = {};
local displayedGuids = {};

ui:SetAllPoints()
ui:SetScript("OnUpdate", function()
	local config = Cursive.db.profile

	if not config.enabled then
		return
	end

	if (this.tick or 1) > GetTime() then
		return
	else
		this.tick = GetTime() + 0.1
	end

	if not ui.rootBarFrame then
		ui.rootBarFrame = CreateRoot()
	end

	-- skip if locked (due to moving)
	if ui.rootBarFrame.lock then
		return
	end

	-- reset display data
	ui.row = 1
	ui.col = 1
	ui.maxBarsDisplayed = false
	ui.numDisplayed = 0

	-- clear shouldDisplayGuids
	for guid, _ in pairs(shouldDisplayGuids) do
		shouldDisplayGuids[guid] = nil
	end

	-- clear displayedGuids
	for guid, _ in pairs(displayedGuids) do
		displayedGuids[guid] = nil
	end

	-- run through all guids and fill with bars
	local title_size = 12 + config.spacing

	local topMaxHp = 0
	local secondMaxHp = 0
	local thirdMaxHp = 0

	local topMaxGuid = 0
	local secondMaxGuid = 0
	local thirdMaxGuid = 0

	local numDisplayable = 0

	local averageMaxHp = 0

	local _, currentTargetGuid = UnitExists("target")

	-- first consider raid marks
	for i = 8, 1, -1 do
		local _, guid = UnitExists("mark" .. i)
		if guid then
			if Cursive:ShouldDisplayGuid(guid) then
				numDisplayable = numDisplayable + 1

				-- display guid
				displayedGuids[guid] = true
				DisplayGuid(guid)
				if ui.maxBarsDisplayed then
					break
				end
			end
			-- don't try to display this guid again
			shouldDisplayGuids[guid] = false
		end
	end

	for guid, time in pairs(Cursive.core.guids) do
		-- calculate shouldDisplay
		local shouldDisplay = false
		if shouldDisplayGuids[guid] == nil then
			shouldDisplay = Cursive:ShouldDisplayGuid(guid)
			shouldDisplayGuids[guid] = shouldDisplay

			if shouldDisplay then
				numDisplayable = numDisplayable + 1
			end
		else
			shouldDisplay = shouldDisplayGuids[guid]
		end

		-- calculate top 3 max hps
		if shouldDisplay then
			local maxHp = UnitHealthMax(guid)
			if maxHp > topMaxHp then
				thirdMaxHp = secondMaxHp
				thirdMaxGuid = secondMaxGuid
				secondMaxHp = topMaxHp
				secondMaxGuid = topMaxGuid
				topMaxHp = maxHp
				topMaxGuid = guid
			elseif maxHp > secondMaxHp then
				thirdMaxHp = secondMaxHp
				thirdMaxGuid = secondMaxGuid
				secondMaxHp = maxHp
				secondMaxGuid = guid
			elseif maxHp > thirdMaxHp then
				thirdMaxHp = maxHp
				thirdMaxGuid = guid
			end
		else
			CheckForCleanup(guid, time)
		end
	end

	-- top max hp
	if not ui.maxBarsDisplayed and numDisplayable > ui.numDisplayed and not displayedGuids[topMaxGuid] then
		displayedGuids[topMaxGuid] = true
		DisplayGuid(topMaxGuid)
	end

	-- second max hp
	if not ui.maxBarsDisplayed and numDisplayable > ui.numDisplayed and not displayedGuids[secondMaxGuid] then
		displayedGuids[secondMaxGuid] = true
		DisplayGuid(secondMaxGuid)
	end

	-- third max hp
	if not ui.maxBarsDisplayed and numDisplayable > ui.numDisplayed and not displayedGuids[thirdMaxGuid] then
		displayedGuids[thirdMaxGuid] = true

		DisplayGuid(thirdMaxGuid)
	end

	-- fill in remaining slots
	for guid, time in pairs(Cursive.core.guids) do
		if ui.maxBarsDisplayed or numDisplayable <= ui.numDisplayed then
			break
		end

		if not displayedGuids[guid] and shouldDisplayGuids[guid] == true then
			displayedGuids[guid] = true
			DisplayGuid(guid)
		end
	end

	-- if current target not yet displayed, show it at maxrow/maxcol
	if currentTargetGuid and
			shouldDisplayGuids[currentTargetGuid] and
			not displayedGuids[currentTargetGuid] and
			Cursive.db.profile.alwaysshowcurrenttarget then
		-- replace the last displayed guid with the current target
		displayedGuids[currentTargetGuid] = true
		ui.col = config.maxcol
		ui.row = config.maxrow
		DisplayGuid(currentTargetGuid)
	end

	-- hide any remaining unit frames
	for col, rows in pairs(ui.unitFrames) do
		for row, unitFrame in pairs(rows) do
			if unitFrame:IsShown() then
				if not displayedGuids[unitFrame.guid] then
					unitFrame:Hide()
				else
					displayedGuids[unitFrame.guid] = nil -- avoid displaying duplicate rows
				end
			end
		end
	end

end)

-- GCD swing-timer bar. Cursive.ui.StartGcdBar(duration) is called from
-- curses.lua's SPELL_GO_SELF handler, using nampower's precise
-- GetSpellIdCooldown() data at the moment a curse actually goes off.
-- This ticker just smoothly drains the bar from that snapshot every
-- frame (unlike the throttled 0.1s main UI loop above).
ui.gcdBarStart = nil
ui.gcdBarDuration = nil

ui.StartGcdBar = function(duration)
	if not ui.rootBarFrame or not ui.rootBarFrame.gcdBar then
		return
	end
	if not ui.rootBarFrame.gcdBar.enabled then
		return
	end
	ui.gcdBarStart = GetTime()
	ui.gcdBarDuration = duration
end

local gcdTicker = CreateFrame("Frame", "CursiveGcdTicker", UIParent)
ui.gcdPreviewUntil = nil

-- Call this from any GCD bar setting's set() callback to show a temporary
-- static preview fill, since the real bar normally only appears during an
-- actual GCD -- this lets color/size changes be seen immediately.
function ui.PreviewGcdBar()
	ui.gcdPreviewUntil = GetTime() + 4
end

ui.shadowVulnPreviewUntil = nil

-- Call this from the flash-speed setting's set() callback to force any
-- currently-displayed Shadow Vulnerability icon into its flashing state
-- temporarily, regardless of real debuff presence -- only affects rows
-- that are actually displayed right now (requires a target/row visible).
function ui.PreviewShadowVulnFlash()
	ui.shadowVulnPreviewUntil = GetTime() + 4
end

gcdTicker:SetScript("OnUpdate", function()
	if not ui.rootBarFrame or not ui.rootBarFrame.gcdBar then
		return
	end

	local bar = ui.rootBarFrame.gcdBar

	-- Preview mode: triggered directly by changing a GCD bar setting,
	-- rather than trying to detect whether the options menu is open.
	if ui.gcdPreviewUntil and GetTime() < ui.gcdPreviewUntil then
		bar:SetMinMaxValues(0, 1)
		bar:SetValue(0.6)
		if not bar:IsShown() then
			bar:Show()
		end
		return
	end

	if not bar.enabled or not ui.gcdBarStart then
		if bar:IsShown() then
			bar:Hide()
		end
		return
	end

	local remaining = (ui.gcdBarStart + ui.gcdBarDuration) - GetTime()
	if remaining > 0 then
		bar:SetMinMaxValues(0, ui.gcdBarDuration)
		bar:SetValue(remaining)
		if not bar:IsShown() then
			bar:Show()
		end
	else
		ui.gcdBarStart = nil
		if bar:IsShown() then
			bar:Hide()
		end
	end
end)

-------------------------------------------------------------------------------
-- Sacrifice shield tracking (Voidwalker's damage-absorb shield on the
-- warlock). Detection and initial-absorb-value reading use a tooltip scan
-- of the player's own buff (robust across all ranks, since it reads the
-- actual computed value including any Demonic Brutality talent bonus,
-- rather than guessing based on rank). Duration is a fixed 30s regardless
-- of rank (confirmed).
--
-- IMPORTANT CAVEAT: remaining-absorb tracking (damage taken while the
-- shield is up) is UNVERIFIED. Vanilla's combat log is chat-message-based
-- and its exact wording for absorbed hits hasn't been confirmed on this
-- server. Diagnostic mode (/cursivesacdebug) prints every combat message
-- received while the shield is active, so the real format can be seen and
-- the parsing refined -- until then, the absorb estimate may be inaccurate
-- or simply not update at all if the message format doesn't match what's
-- guessed below.
-------------------------------------------------------------------------------

local SACRIFICE_DURATION = 30
ui.sacrificeDebugMode = false
ui.cachedSacrificeAbsorb = nil

local sacrificeState = {
	active = false,
	initialAbsorb = 0,
	appliedAt = 0,
	damageTaken = 0,
}

-- The APPLIED buff's own tooltip is confirmed abbreviated ("Absorbs all
-- damage", no number) -- the real absorb value only appears in the full
-- spell description, shown on the Voidwalker's pet action bar. Since the
-- Voidwalker is consumed by the cast, this has to be scanned proactively
-- while it's still alive and cached, rather than read after the fact.
local function ScanPetBarForSacrifice()
	local slot = 1
	while slot <= 10 do
		local button = getglobal("pfActionBarPetButton"..slot) or getglobal("PetActionButton"..slot)
		if button and button:IsVisible() then
			Cursive.core.tooltipScan:SetOwner(UIParent, "ANCHOR_NONE")
			Cursive.core.tooltipScan:SetPetAction(slot)
			local nameLine = getglobal("CursiveTooltipScanTextLeft1")
			local nameText = nameLine and nameLine:GetText()
			if nameText and string.find(nameText, "Sacrifice", 1, true) then
				local lineNum = 2
				while lineNum <= 6 do
					local descLine = getglobal("CursiveTooltipScanTextLeft"..lineNum)
					local desc = descLine and descLine:GetText()
					if desc then
						local _, _, num = string.find(desc, "absorb (%d+)")
						if num then
							if ui.sacrificeDebugMode and ui.cachedSacrificeAbsorb ~= tonumber(num) then
								DEFAULT_CHAT_FRAME:AddMessage("|cff60ffff[SacDebug]|r Cached Sacrifice absorb value from pet bar: "..num)
							end
							ui.cachedSacrificeAbsorb = tonumber(num)
							Cursive.core.tooltipScan:Hide()
							return
						end
					end
					lineNum = lineNum + 1
				end
			end
			Cursive.core.tooltipScan:Hide()
		end
		slot = slot + 1
	end
end

-- One-shot diagnostic: dumps the full state of PetActionButton1-10 --
-- whether each exists, is visible, and what its tooltip shows (regardless
-- of whether it matches "Sacrifice"). Run this with your Voidwalker
-- summoned if the pet-bar scan above isn't finding anything -- likely
-- explanation is a UI replacement addon (e.g. pfUI) using different pet
-- bar frame names than the vanilla default.
-- Guessing frame naming conventions has failed twice -- this reports
-- exactly which frame is under the mouse cursor, no guessing involved.
-- Run the command, THEN hover over the Sacrifice icon on the pet bar
-- within 3 seconds (gives time to move the mouse after typing/hitting
-- enter, since GetMouseFocus needs the cursor there at the exact moment
-- it's checked).
local whatFrameChecker = CreateFrame("Frame")
SLASH_CURSIVEWHATFRAME1 = "/cursivewhatframe"
SlashCmdList["CURSIVEWHATFRAME"] = function()
	DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Cursive:|r hover over the Sacrifice pet icon now -- checking in 3 seconds...")
	local elapsed = 0
	whatFrameChecker:SetScript("OnUpdate", function()
		elapsed = elapsed + arg1
		if elapsed < 3 then return end
		whatFrameChecker:SetScript("OnUpdate", nil)

		local frame = GetMouseFocus()
		if not frame then
			DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Cursive:|r no frame under mouse")
			return
		end
		local name = frame.GetName and frame:GetName()
		DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Cursive:|r frame under mouse: "..tostring(name))
		local parent = frame.GetParent and frame:GetParent()
		if parent then
			local parentName = parent.GetName and parent:GetName()
			DEFAULT_CHAT_FRAME:AddMessage("  parent: "..tostring(parentName))
		end
	end)
end

SLASH_CURSIVEPETDEBUG1 = "/cursivepetdebug"
SlashCmdList["CURSIVEPETDEBUG"] = function()
	DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Cursive pet bar debug|r")
	local prefixes = { "pfActionBarPetButton", "PetActionButton", "ActionBarPetButton", "ActionBarPet" }
	local anyFound = false
	local pIdx = 1
	while pIdx <= 4 do
		local prefix = prefixes[pIdx]
		local slot = 1
		while slot <= 10 do
			local buttonName = prefix..slot
			local button = getglobal(buttonName)
			if button then
				anyFound = true
				local visible = button:IsVisible()
				DEFAULT_CHAT_FRAME:AddMessage("  "..buttonName..": exists, visible="..tostring(visible))
				if visible then
					-- Try SetPetAction directly on this slot number (works
					-- regardless of the button's frame naming convention,
					-- since SetPetAction addresses pet action slots by
					-- index, not frame name).
					Cursive.core.tooltipScan:SetOwner(UIParent, "ANCHOR_NONE")
					local ok = pcall(function() Cursive.core.tooltipScan:SetPetAction(slot) end)
					local nameLine = getglobal("CursiveTooltipScanTextLeft1")
					local nameText = nameLine and nameLine:GetText()
					DEFAULT_CHAT_FRAME:AddMessage("    SetPetAction("..slot..") tooltip name: "..tostring(nameText).." (call ok: "..tostring(ok)..")")
					Cursive.core.tooltipScan:Hide()
				end
			end
			slot = slot + 1
		end
		pIdx = pIdx + 1
	end
	if not anyFound then
		DEFAULT_CHAT_FRAME:AddMessage("  None of PetActionButton/ActionBarPetButton/ActionBarPet 1-10 exist -- naming convention is something else entirely.")
	end
end

local function ScanForSacrificeBuff()
	local found = false
	local i = 1
	while true do
		local tex = UnitBuff("player", i)
		if not tex then break end
		Cursive.core.tooltipScan:SetOwner(UIParent, "ANCHOR_NONE")
		Cursive.core.tooltipScan:SetUnitBuff("player", i)
		local nameLine = getglobal("CursiveTooltipScanTextLeft1")
		local name = nameLine and nameLine:GetText()
		if name and string.find(name, "Sacrifice", 1, true) then
			found = true
			if not sacrificeState.active then
				sacrificeState.active = true
				sacrificeState.appliedAt = GetTime()
				sacrificeState.damageTaken = 0
				sacrificeState.initialAbsorb = ui.cachedSacrificeAbsorb or 0

				if ui.sacrificeDebugMode then
					DEFAULT_CHAT_FRAME:AddMessage("|cff60ffff[SacDebug]|r Shield applied, using cached absorb value: "..tostring(ui.cachedSacrificeAbsorb))
				end
			end
			break
		end
		i = i + 1
	end
	Cursive.core.tooltipScan:Hide()
	if not found and sacrificeState.active then
		if ui.sacrificeDebugMode then
			DEFAULT_CHAT_FRAME:AddMessage("|cff60ffff[SacDebug]|r Shield no longer detected (expired or broken)")
		end
		sacrificeState.active = false
	end
	return found
end

-- Diagnostic: logs every combat message received while the shield is
-- active, to determine the real absorb-message wording on this server.
-- Also attempts a best-effort parse (any number immediately preceding or
-- following "absorb") to estimate damage taken, but this is unverified.
local sacDebugFrame = CreateFrame("Frame")
-- Confirmed (via community-documented vanilla 1.12.1 event listings) as
-- the correct events for damage TAKEN by the player -- the original guess
-- above was wrong: CHAT_MSG_SPELL_SELF_DAMAGE and CHAT_MSG_COMBAT_SELF_HITS
-- report damage the player DEALS to others, not damage taken, which is why
-- zero debug messages ever fired despite the player clearly taking damage.
sacDebugFrame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")   -- melee from a creature to the player
sacDebugFrame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE")  -- spell from a creature to the player
sacDebugFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS")      -- melee from a hostile player (PvP)
sacDebugFrame:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE")     -- spell from a hostile player (PvP)
sacDebugFrame:SetScript("OnEvent", function()
	if not sacrificeState.active then return end
	local msg = arg1
	if not msg then return end

	if ui.sacrificeDebugMode then
		DEFAULT_CHAT_FRAME:AddMessage("|cff60ffff[SacDebug]|r ["..event.."] "..msg)
	end

	if string.find(string.lower(msg), "absorb", 1, true) then
		local _, _, num = string.find(msg, "%((%d+) absorbed%)")
		if num then
			sacrificeState.damageTaken = sacrificeState.damageTaken + tonumber(num)
			if ui.sacrificeDebugMode then
				DEFAULT_CHAT_FRAME:AddMessage("|cff60ffff[SacDebug]|r Parsed absorbed amount: "..num..", running total: "..sacrificeState.damageTaken)
			end
		end
	end
end)

SLASH_CURSIVESACDEBUG1 = "/cursivesacdebug"
SlashCmdList["CURSIVESACDEBUG"] = function()
	ui.sacrificeDebugMode = not ui.sacrificeDebugMode
	DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Cursive|r sacrifice debug mode: "..(ui.sacrificeDebugMode and "|cff00ff00ON|r" or "|cffff6060OFF|r"))
end

-- Standalone, draggable Sacrifice shield bar. Depletes visually with time
-- remaining (same mechanic as the GCD bar); the damage-remaining estimate
-- is shown as text overlaid on the bar rather than driving the bar's fill,
-- since only the time value is fully reliable.
-- Repositions the label/absorb text based on orientation. Horizontal keeps
-- them side-by-side inside the bar; vertical stacks them below the bar
-- instead, since a narrow vertical bar can't fit readable text inside it.
local function UpdateSacrificeBarTextLayout(bar, isVertical)
	bar.label:ClearAllPoints()
	bar.absorbText:ClearAllPoints()
	if isVertical then
		bar.label:SetPoint("Top", bar, "Bottom", 0, -4)
		bar.label:SetJustifyH("Center")
		bar.absorbText:SetPoint("Top", bar.label, "Bottom", 0, -2)
		bar.absorbText:SetJustifyH("Center")
	else
		bar.label:SetPoint("Left", bar, "Left", 4, 0)
		bar.label:SetJustifyH("Left")
		bar.absorbText:SetPoint("Right", bar, "Right", -4, 0)
		bar.absorbText:SetJustifyH("Right")
	end
end

local function CreateSacrificeBar()
	local p = Cursive.db.profile

	local bar = CreateFrame("StatusBar", "CursiveSacrificeBar", UIParent)
	bar:SetWidth(p.sacrificebarwidth or 200)
	bar:SetHeight(p.sacrificebarheight or 14)

	if p.sacrificebaranchor then
		bar:SetPoint(p.sacrificebaranchor, UIParent, p.sacrificebaranchor, p.sacrificebarx or 0, p.sacrificebary or 0)
	else
		bar:SetPoint("Center", UIParent, "Center", 0, -100)
	end

	bar:SetStatusBarTexture(Cursive.db.profile.bartexture)
	bar:SetOrientation(p.sacrificebarorientation or "HORIZONTAL")
	local c = p.sacrificebarcolor or { r = 0.6, g = 0.2, b = 0.85 }
	bar:SetStatusBarColor(c.r, c.g, c.b, 0.9)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)

	-- Border color reflects % of absorb remaining (green -> red), as an
	-- at-a-glance cue independent of the text number.
	bar:SetBackdrop({
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
	})
	bar:SetBackdropBorderColor(0, 1, 0, 1)

	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(bar)
	bg:SetTexture(0, 0, 0)
	bg:SetAlpha(0.4)

	local label = bar:CreateFontString(nil, "OVERLAY")
	label:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
	label:SetTextColor(1, 1, 1, 1)
	label:SetText("Sacrifice")

	local absorbText = bar:CreateFontString(nil, "OVERLAY")
	absorbText:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
	absorbText:SetTextColor(1, 1, 1, 1)

	bar.label = label
	bar.absorbText = absorbText
	UpdateSacrificeBarTextLayout(bar, (p.sacrificebarorientation == "VERTICAL"))

	bar:EnableMouse(true)
	bar:SetMovable(true)
	bar:RegisterForDrag("LeftButton")
	bar:SetScript("OnDragStart", function()
		this:StartMoving()
	end)
	bar:SetScript("OnDragStop", function()
		this:StopMovingOrSizing()
		local newAnchor = utils.GetBestAnchor(this)
		local anchor, x, y = utils.ConvertFrameAnchor(this, newAnchor)
		this:ClearAllPoints()
		this:SetPoint(anchor, UIParent, anchor, x, y)

		Cursive.db.profile.sacrificebaranchor = anchor
		Cursive.db.profile.sacrificebarx = x
		Cursive.db.profile.sacrificebary = y
	end)

	bar:Hide()
	ui.sacrificeBar = bar
	return bar
end

ui.UpdateSacrificeBarTextLayout = UpdateSacrificeBarTextLayout

local sacrificeTicker = CreateFrame("Frame", "CursiveSacrificeTicker", UIParent)
local sacrificeTickAccum = 0
ui.sacrificeBarPreviewUntil = nil

-- Call this from any Sacrifice bar setting's set() callback to show a
-- temporary static preview fill, since the real bar normally only
-- appears while the shield is actually active -- lets color/size changes
-- be seen immediately.
function ui.PreviewSacrificeBar()
	ui.sacrificeBarPreviewUntil = GetTime() + 4
end

sacrificeTicker:SetScript("OnUpdate", function()
	sacrificeTickAccum = sacrificeTickAccum + arg1
	if sacrificeTickAccum < 0.5 then return end
	sacrificeTickAccum = 0

	ScanPetBarForSacrifice()
	ScanForSacrificeBuff()

	if not ui.sacrificeBar then
		CreateSacrificeBar()
	end
	local bar = ui.sacrificeBar

	-- Preview mode: triggered directly by changing a Sacrifice bar
	-- setting, rather than trying to detect whether the options menu is
	-- open.
	if ui.sacrificeBarPreviewUntil and GetTime() < ui.sacrificeBarPreviewUntil then
		bar:SetMinMaxValues(0, 30)
		bar:SetValue(18)
		bar.absorbText:SetText("18s  |  1200 absorb")
		if not bar:IsShown() then bar:Show() end
		return
	end

	if not sacrificeState.active then
		if bar:IsShown() then bar:Hide() end
		return
	end

	local remaining = SACRIFICE_DURATION - (GetTime() - sacrificeState.appliedAt)
	if remaining <= 0 then
		sacrificeState.active = false
		bar:Hide()
		return
	end

	if not bar:IsShown() then bar:Show() end
	bar:SetMinMaxValues(0, SACRIFICE_DURATION)
	bar:SetValue(remaining)

	local remainingAbsorb = sacrificeState.initialAbsorb - sacrificeState.damageTaken
	if remainingAbsorb < 0 then remainingAbsorb = 0 end
	bar.absorbText:SetText(math.floor(remaining + 1).."s  |  "..remainingAbsorb.." absorb")

	if sacrificeState.initialAbsorb > 0 then
		local pct = remainingAbsorb / sacrificeState.initialAbsorb
		if pct > 1 then pct = 1 end
		bar.borderR, bar.borderG, bar.borderB = 1 - pct, pct, 0
	else
		bar.borderR, bar.borderG, bar.borderB = 0.5, 0.5, 0.5
	end
end)

-- Glowing border: pulses the border alpha smoothly via sin() oscillation.
-- Runs every frame (unthrottled), separate from the main 0.5s update
-- above, since a visible pulse needs much more frequent updates than the
-- bar's actual data does.
local sacrificeGlowTicker = CreateFrame("Frame", "CursiveSacrificeGlowTicker", UIParent)
sacrificeGlowTicker:SetScript("OnUpdate", function()
	local bar = ui.sacrificeBar
	if not bar or not bar:IsShown() then return end
	local r = bar.borderR or 0.5
	local g = bar.borderG or 0.5
	local b = bar.borderB or 0.5
	local alpha = 0.5 + 0.5 * math.sin(GetTime() * 4)
	bar:SetBackdropBorderColor(r, g, b, alpha)
end)

-- Flashes any icon currently registered, via a smooth alpha oscillation.
-- Single shared ticker for all rows rather than one per icon. Registry
-- values are a speed multiplier (falls back to 3 if just `true`), so
-- different icons can flash at different rates using the same ticker.
local flashTicker = CreateFrame("Frame", "CursiveFlashTicker", UIParent)
flashTicker:SetScript("OnUpdate", function()
	local any = false
	for icon in pairs(ui.flashingCurseIcons) do
		any = true
		break
	end
	if not any then
		return
	end
	local now = GetTime()
	for icon, speed in pairs(ui.flashingCurseIcons) do
		local s = (type(speed) == "number") and speed or 3
		local alpha = 0.35 + (0.65 * (0.5 + 0.5 * math.sin(now * s)))
		icon:SetAlpha(alpha)
	end
end)

-------------------------------------------------------------------------------
-- Standalone settings window (alternative to the Dewdrop dropdown menu).
-- Generic renderer reads the EXISTING Ace2-style options table (Cursive.
-- cmdtable) directly rather than hand-transcribing every setting, so it
-- automatically stays in sync with whatever settings.lua defines.
-------------------------------------------------------------------------------

local settingsWindow = nil

-- Ace2 options entries can specify get/set as either a direct function, or
-- a STRING naming a method to call on a "handler" object (falling back to
-- Cursive itself, since Cursive.cmdtable.handler = Cursive). This resolves
-- either form correctly. Fixed-arity (not vararg) since this client runs
-- Lua 5.0, where "..." can't be used directly as a forwarded expression
-- the way Lua 5.1 allows -- 3 args covers every case used here (color
-- needs r,g,b; toggle/range need at most 1; get calls need 0).
local function CallGetSet(entry, isSet, a1, a2, a3)
	local fn = isSet and entry.set or entry.get
	if type(fn) == "function" then
		return fn(a1, a2, a3)
	elseif type(fn) == "string" then
		local handler = entry.handler or Cursive
		return handler[fn](handler, a1, a2, a3)
	end
end

local function MakeHeaderWidget(parent, text, yOff)
	local hdr = parent:CreateFontString(nil, "OVERLAY")
	hdr:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
	hdr:SetTextColor(0.7, 0.5, 1, 1)
	hdr:SetPoint("TopLeft", parent, "TopLeft", 4, yOff)
	hdr:SetText(text)

	local divider = parent:CreateTexture(nil, "ARTWORK")
	divider:SetHeight(1)
	divider:SetPoint("TopLeft", parent, "TopLeft", 4, yOff - 12)
	divider:SetPoint("TopRight", parent, "TopRight", -4, yOff - 12)
	divider:SetTexture(0.3, 0.15, 0.5, 0.8)

	return 18
end

local function MakeToggleWidget(parent, entry, yOff)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetWidth(20) cb:SetHeight(20)
	cb:SetPoint("TopLeft", parent, "TopLeft", 8, yOff)
	cb:SetChecked(CallGetSet(entry, false) and true or false)
	cb:SetScript("OnClick", function()
		CallGetSet(entry, true, this:GetChecked() and true or false)
		this:SetChecked(CallGetSet(entry, false) and true or false)
	end)

	local label = parent:CreateFontString(nil, "OVERLAY")
	label:SetFont(STANDARD_TEXT_FONT, 10, "")
	label:SetTextColor(0.9, 0.9, 0.9, 1)
	label:SetPoint("Left", cb, "Right", 2, 0)
	label:SetWidth(230)
	label:SetJustifyH("Left")
	label:SetText(entry.name or "")

	return 24
end

local sliderCounter = 0
local function MakeRangeWidget(parent, entry, yOff)
	local label = parent:CreateFontString(nil, "OVERLAY")
	label:SetFont(STANDARD_TEXT_FONT, 10, "")
	label:SetTextColor(0.9, 0.9, 0.9, 1)
	label:SetPoint("TopLeft", parent, "TopLeft", 8, yOff)
	label:SetText(entry.name or "")

	local valLbl = parent:CreateFontString(nil, "OVERLAY")
	valLbl:SetFont(STANDARD_TEXT_FONT, 10, "")
	valLbl:SetTextColor(0.6, 0.85, 1, 1)
	valLbl:SetPoint("TopRight", parent, "TopRight", -10, yOff)
	valLbl:SetJustifyH("Right")
	valLbl:SetText(tostring(CallGetSet(entry, false)))

	sliderCounter = sliderCounter + 1
	local sliderName = "CursiveSettingsWindowSlider" .. sliderCounter
	local slider = CreateFrame("Slider", sliderName, parent, "OptionsSliderTemplate")
	slider:SetWidth(250)
	slider:SetHeight(14)
	slider:SetPoint("TopLeft", parent, "TopLeft", 10, yOff - 16)
	slider:SetMinMaxValues(entry.min or 0, entry.max or 100)
	slider:SetValueStep(entry.step or 1)
	slider:SetValue(CallGetSet(entry, false) or 0)
	getglobal(sliderName .. "Low"):SetText(tostring(entry.min or 0))
	getglobal(sliderName .. "High"):SetText(tostring(entry.max or 100))
	getglobal(sliderName .. "Text"):SetText("")
	slider:SetScript("OnValueChanged", function()
		CallGetSet(entry, true, this:GetValue())
		valLbl:SetText(tostring(CallGetSet(entry, false)))
	end)

	return 40
end

local function MakeColorWidget(parent, entry, yOff)
	local label = parent:CreateFontString(nil, "OVERLAY")
	label:SetFont(STANDARD_TEXT_FONT, 10, "")
	label:SetTextColor(0.9, 0.9, 0.9, 1)
	label:SetPoint("TopLeft", parent, "TopLeft", 8, yOff)
	label:SetText(entry.name or "")

	local swatch = CreateFrame("Button", nil, parent)
	swatch:SetWidth(16) swatch:SetHeight(16)
	swatch:SetPoint("TopRight", parent, "TopRight", -10, yOff)
	local tex = swatch:CreateTexture(nil, "OVERLAY")
	tex:SetAllPoints(swatch)
	local r, g, b = CallGetSet(entry, false)
	tex:SetTexture(r, g, b)
	swatch.tex = tex

	swatch:SetScript("OnClick", function()
		local r2, g2, b2 = CallGetSet(entry, false)
		ColorPickerFrame.func = function()
			local nr, ng, nb = ColorPickerFrame:GetColorRGB()
			CallGetSet(entry, true, nr, ng, nb)
			swatch.tex:SetTexture(nr, ng, nb)
		end
		ColorPickerFrame.cancelFunc = function(prev)
			CallGetSet(entry, true, prev.r, prev.g, prev.b)
			swatch.tex:SetTexture(prev.r, prev.g, prev.b)
		end
		ColorPickerFrame.hasOpacity = false
		ColorPickerFrame.previousValues = { r = r2, g = g2, b = b2 }
		ColorPickerFrame:SetColorRGB(r2, g2, b2)
		ShowUIPanel(ColorPickerFrame)
	end)

	return 24
end

local function RenderOptionsInto(parent, argsTable, yStart)
	local sorted = {}
	for k, v in pairs(argsTable) do
		table.insert(sorted, { key = k, entry = v })
	end
	table.sort(sorted, function(a, b)
		return (a.entry.order or 999) < (b.entry.order or 999)
	end)

	local y = yStart
	for _, item in ipairs(sorted) do
		local entry = item.entry
		if (not entry.name or entry.name == "") and entry.type ~= "group" then
			entry.name = item.key
		end
		if entry.type == "toggle" then
			y = y - MakeToggleWidget(parent, entry, y)
		elseif entry.type == "range" then
			y = y - MakeRangeWidget(parent, entry, y)
		elseif entry.type == "color" then
			y = y - MakeColorWidget(parent, entry, y)
		elseif entry.type == "header" then
			y = y - MakeHeaderWidget(parent, entry.name or "", y)
		elseif entry.type == "group" then
			y = y - 8
			y = y - MakeHeaderWidget(parent, "== " .. (entry.name or item.key) .. " ==", y)
			if entry.args then
				y = RenderOptionsInto(parent, entry.args, y)
			end
		end
	end
	return y
end

function ui.CreateSettingsWindow()
	if settingsWindow then
		return settingsWindow
	end

	local f = CreateFrame("Frame", "CursiveSettingsWindow", UIParent)
	f:SetWidth(320)
	f:SetHeight(480)
	f:SetPoint("Center", UIParent, "Center", 0, 0)
	f:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
		insets   = { left = 1, right = 1, top = 1, bottom = 1 }
	})
	f:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
	f:SetBackdropBorderColor(0.25, 0.25, 0.35, 1)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function() this:StartMoving() end)
	f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
	f:SetFrameStrata("DIALOG")
	f:Hide()

	local titleBar = CreateFrame("Frame", nil, f)
	titleBar:SetHeight(24)
	titleBar:SetPoint("TopLeft", f, "TopLeft", 0, 0)
	titleBar:SetPoint("TopRight", f, "TopRight", 0, 0)
	titleBar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
	titleBar:SetBackdropColor(0.22, 0.08, 0.38, 1)

	local title = titleBar:CreateFontString(nil, "OVERLAY")
	title:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
	title:SetTextColor(1, 0.84, 0, 1)
	title:SetPoint("Left", titleBar, "Left", 8, 0)
	title:SetText("Cursive — Settings")

	local closeBtn = CreateFrame("Button", nil, titleBar)
	closeBtn:SetWidth(16) closeBtn:SetHeight(16)
	closeBtn:SetPoint("Right", titleBar, "Right", -6, 0)
	local closeTxt = closeBtn:CreateFontString(nil, "OVERLAY")
	closeTxt:SetFont(STANDARD_TEXT_FONT, 13, "OUTLINE")
	closeTxt:SetAllPoints(closeBtn)
	closeTxt:SetText("|cffaaaaaaX|r")
	closeBtn:SetScript("OnEnter", function() closeTxt:SetText("|cffffffffX|r") end)
	closeBtn:SetScript("OnLeave", function() closeTxt:SetText("|cffaaaaaaX|r") end)
	closeBtn:SetScript("OnClick", function() f:Hide() end)

	local scrollFrame = CreateFrame("ScrollFrame", "CursiveSettingsScrollFrame", f, "UIPanelScrollFrameTemplate")
	scrollFrame:SetPoint("TopLeft", f, "TopLeft", 16, -32)
	scrollFrame:SetPoint("BottomRight", f, "BottomRight", -32, 16)

	local content = CreateFrame("Frame", nil, scrollFrame)
	content:SetWidth(272)
	content:SetHeight(1)
	scrollFrame:SetScrollChild(content)

	local finalY = RenderOptionsInto(content, Cursive.cmdtable.args, -4)
	content:SetHeight(math.abs(finalY) + 30)

	settingsWindow = f
	return f
end

-------------------------------------------------------------------------------
-- Diagnostic: /cgd prints exactly what UnitDebuff sees for the current
-- target, and whether each GHOST_DOT_ICONS entry matches -- run this while
-- a ghost icon is stuck showing despite the DoT clearly being active, to
-- get real data instead of guessing further.
-------------------------------------------------------------------------------

SLASH_CURSIVEGHOSTDEBUG1 = "/cgd"
SlashCmdList["CURSIVEGHOSTDEBUG"] = function()
	local _, guid = UnitExists("target")
	if not guid then
		DEFAULT_CHAT_FRAME:AddMessage("|cffff6060Cursive ghost debug:|r no target selected")
		return
	end
	DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Cursive ghost debug|r -- guid: "..guid)
	DEFAULT_CHAT_FRAME:AddMessage("(this is your current target, so the fix resolves it via the \"target\" token)")
	DEFAULT_CHAT_FRAME:AddMessage("Raw UnitDebuff scan:")
	local i = 1
	local foundAny = false
	while true do
		local tex = SafeUnitDebuff(guid, i)
		if not tex then break end
		foundAny = true
		DEFAULT_CHAT_FRAME:AddMessage("  slot "..i..": "..tex)
		i = i + 1
	end
	if not foundAny then
		DEFAULT_CHAT_FRAME:AddMessage("  (UnitDebuff returned nothing at all for this guid)")
	end
	DEFAULT_CHAT_FRAME:AddMessage("Checking against GHOST_DOT_ICONS:")
	for _, dot in ipairs(GHOST_DOT_ICONS) do
		local found = false
		local j = 1
		while true do
			local tex = SafeUnitDebuff(guid, j)
			if not tex then break end
			if string.find(tex, dot.texture, 1, true) then
				found = true
				break
			end
			j = j + 1
		end
		DEFAULT_CHAT_FRAME:AddMessage("  "..dot.name..": "..(found and "|cff00ff00FOUND|r" or "|cffff6060NOT FOUND|r").." (looking for '"..dot.texture.."')")
	end
end

Cursive.ui = ui

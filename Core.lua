--[[ Hi-Lo Casino  (named Roll Casino before 2.2.0)
     Original author: Pytte
     2.0 rewrite: Ace3 (AceAddon / AceDB / LibDBIcon)
     2.1: hand-built window in the NaowhForever house look (follows its
          live theme and fonts when NaowhForever is loaded).
     Game logic preserved 1:1 from the original 1.3.1 release.
--]]

local ADDON = ...

local RC      = LibStub("AceAddon-3.0"):NewAddon("HiLoCasino", "AceConsole-3.0", "AceEvent-3.0")
local LDB     = LibStub("LibDataBroker-1.1", true)
local LDBIcon = LibStub("LibDBIcon-1.0", true)

local format, floor, tonumber, tostring = string.format, math.floor, tonumber, tostring
local strsplit, strlower, strsub = strsplit, strlower, string.sub
local tinsert, tgetn = table.insert, function(t) return #t end

--==========================================================================
--  STATE
--==========================================================================

-- Roll-to-gold ratio: roll cap = gold * ratio, displayed gold = roll / ratio.
-- Selectable in the UI. e.g. 100:1 -> 20g gambles with a /roll 1-2000.
local RATIO_OPTIONS = { [1] = "1 : 1", [10] = "10 : 1", [100] = "100 : 1", [1000] = "1000 : 1" }
local RATIO_ORDER   = { 1, 10, 100, 1000 }

local CHAT_METHODS = { "SAY", "PARTY", "RAID", "GUILD", "CHANNEL" }
local CHAT_LABELS  = {
	SAY     = "Say",
	PARTY   = "Party",
	RAID    = "Raid",
	GUILD   = "Guild",
	CHANNEL = "Custom Channel",
}

local PHASE_LABELS = {
	[0] = "Start Round",
	[1] = "Announce Last Call",
	[2] = "Begin Rolling",
	[3] = "Waiting for rolls...",
}

local defaults = {
	global  = {
		allTime = {},          -- pre-2.2 running totals (roll units); imported into rounds once
		rounds  = {},          -- one record per finished round (see RC:ReportResults)
	},
	profile = {
		enterMsg      = "1",
		withdrawMsg   = "-1",
		chatMethod    = "RAID",
		customChannel = "hilocasino",
		stakesGold    = 20,        -- gold the host wants to gamble for
		ratio         = 100,       -- roll cap = stakesGold * ratio
		rulesName     = "Hi/Lo",
		minimap       = { hide = false },
		histPeriod    = "session", -- period for overviews and the quick post buttons
		topN          = 5,         -- how many players "Top"/"Bottom" posts list
	},
}

local db                 -- AceDB
local round              -- current round table
local personalEntered = false
local personalRolled  = false

-- Chat lines that could not be sent from an event handler (Say outdoors and
-- custom channels need a real click/keypress); posted by "Announce Results".
local pendingMsgs
local deferChat = false

-- Chat payloads can be "secret" on newer clients (chat messaging lockdown);
-- comparing a secret string errors, so such messages are skipped.
local issecret = issecretvalue or function() return false end

local SendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage

local function NewRound()
	return {
		phase         = 0,
		stakes        = 0,
		entrants      = {},
		entrantsCount = 0,
		acceptEntries = false,
		acceptRolls   = false,
		highRoller    = nil,
		lowRoller     = nil,
		highTyers     = {},
		lowTyers      = {},
	}
end

--==========================================================================
--  HELPERS
--==========================================================================

local function has_value(arr, val)
	for _, v in ipairs(arr) do
		if v == val then return true end
	end
	return false
end

local function CurrentRatio()
	return (db and db.profile and db.profile.ratio) or 100
end

local function ConvertRollToGold(value)
	return format("%sg", floor((tonumber(value) or 0) / CurrentRatio()))
end

function RC:ChatMsg(msg)
	local method = db.profile.chatMethod
	local channelNum
	if method == "CHANNEL" then
		channelNum = GetChannelName(db.profile.customChannel)
		if not channelNum or channelNum == 0 then
			self:Print("|cffff5555Custom channel '"..db.profile.customChannel.."' not joined.|r")
			return
		end
	end
	-- SendChatMessage treats a lone '|' as the start of an escape code and
	-- rejects the whole message; escape any literal pipes to '||'.
	msg = tostring(msg):gsub("|", "||")
	if deferChat and self:NeedsHardwareEvent() then
		pendingMsgs = pendingMsgs or {}
		tinsert(pendingMsgs, msg)
		return
	end
	SendChat(msg, method, nil, channelNum)
end

-- Say/Yell outside instances and custom channels can only be sent from a
-- click or keypress, not from an event handler.
function RC:NeedsHardwareEvent()
	local method = db.profile.chatMethod
	if method == "CHANNEL" then return true end
	if method == "SAY" or method == "YELL" then
		local inInstance = IsInInstance()
		return not inInstance
	end
	return false
end

function RC:FlushPending()
	if not pendingMsgs then return false end
	local method, channelNum = db.profile.chatMethod, nil
	if method == "CHANNEL" then
		channelNum = GetChannelName(db.profile.customChannel)
		if not channelNum or channelNum == 0 then
			self:Print("|cffff5555Custom channel '"..db.profile.customChannel.."' not joined.|r")
			return true
		end
	end
	local msgs = pendingMsgs
	pendingMsgs = nil
	for _, m in ipairs(msgs) do
		SendChat(m, method, nil, channelNum)   -- already pipe-escaped in ChatMsg
	end
	self:RefreshControls()
	return true
end

-- The actual /roll cap = gold amount * ratio.
function RC:RollCap()
	return math.max(1, floor((db.profile.stakesGold or 1) * CurrentRatio()))
end

--==========================================================================
--  ROLL / ENTRANT TRACKING (ported logic)
--==========================================================================

function RC:GetHighRoll()
	if not round.highRoller then return 0 end
	return round.entrants[round.highRoller].roll
end

function RC:GetLowRoll()
	if not round.lowRoller then return round.stakes end
	return round.entrants[round.lowRoller].roll
end

function RC:GetRemainingToRollCount()
	local count = 0
	for _, v in pairs(round.entrants) do
		if v.entered and not v.rolled then count = count + 1 end
	end
	return count
end

-- WoW Forever character names contain a space ("Pytte Soulreaper"), which
-- chat senders may carry as a hyphen ("Pytte-Soulreaper"), and cross-realm
-- names add "-Realm". Entrants are keyed by a normalized form: hyphens as
-- spaces, single-spaced, lower case. The display name is kept separately.
local function DisplayName(name)
	name = name:gsub("%-", " "):gsub("%s+", " ")
	name = name:gsub("^ ", ""):gsub(" $", "")
	return name
end

local function NameKey(name)
	return DisplayName(name):lower()
end

-- Entrant key for a name from a roll line: exact match first, then a match
-- that differs only by a trailing realm on either side.
local function FindEntrantKey(name)
	local key = NameKey(name)
	if round.entrants[key] then return key end
	for k in pairs(round.entrants) do
		if k:sub(1, #key + 1) == key .. " " or key:sub(1, #k + 1) == k .. " " then
			return k
		end
	end
	return nil
end

function RC:AddPlayer(name)
	if not name or name == "" then return end
	local key = NameKey(name)
	if round.entrants[key] == nil then
		round.entrants[key] = { key = key, name = DisplayName(name), rolled = false, roll = -1, entered = true }
		round.entrantsCount = round.entrantsCount + 1
	else
		round.entrants[key].entered = true
	end
	self:UpdateActionList()
	self:RefreshControls()
end

function RC:WithdrawPlayer(name)
	if not name or name == "" then return end
	local key = NameKey(name)
	if round.entrants[key] == nil then return end
	round.entrants[key].entered = false
	self:UpdateActionList()
end

function RC:ParseEntry(msg, name)
	if msg == db.profile.enterMsg then
		self:AddPlayer(name)
	elseif msg == db.profile.withdrawMsg then
		self:WithdrawPlayer(name)
	end
end

-- Lua pattern for the system roll line, built from the client's own
-- RANDOM_ROLL_RESULT ("%s rolls %d (%d-%d)") so it follows the client's text;
-- captures name, roll, min, max.
local ROLL_PATTERN
do
	local fmt = RANDOM_ROLL_RESULT
	if type(fmt) == "string" and fmt:find("%%s") then
		local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
		p = p:gsub("%%%d*%$?s", "(.+)")
		p = p:gsub("%%%d*%$?d", "(%%d+)")
		ROLL_PATTERN = "^" .. p .. "$"
	else
		ROLL_PATTERN = "^(.+) rolls (%d+) %((%d+)%-(%d+)%)$"
	end
end

function RC:ParseRoll(msg)
	local playerName, roll, minRoll, maxRoll = msg:match(ROLL_PATTERN)
	if not playerName then return end

	local key = FindEntrantKey(playerName)
	local player = key and round.entrants[key]
	if player == nil or not player.entered or player.rolled then
		return
	end

	minRoll = tonumber(minRoll)
	maxRoll = tonumber(maxRoll)
	roll    = tonumber(roll)

	if minRoll ~= 1 or maxRoll ~= round.stakes or not roll or roll > maxRoll or roll < minRoll then
		return
	end

	player.rolled = true
	player.roll   = roll
	player.name   = DisplayName(playerName)   -- the name exactly as the game prints it
	playerName    = key                       -- high/low trackers hold entrant keys

	if roll > self:GetHighRoll() then
		round.highRoller = playerName
		round.highTyers  = { playerName }
	elseif roll == self:GetHighRoll() then
		tinsert(round.highTyers, playerName)
	end

	if roll < self:GetLowRoll() then
		round.lowRoller = playerName
		round.lowTyers  = { playerName }
	elseif roll == self:GetLowRoll() then
		tinsert(round.lowTyers, playerName)
	end

	if self:GetRemainingToRollCount() == 0 then
		self:RoundWrapup()
	end

	self:UpdateActionList()
	self:RefreshControls()
end

--==========================================================================
--  HISTORY  (every finished round is stored; all overviews and chat posts
--  are computed from those records, in gold, for any period)
--==========================================================================

local MAX_ROUNDS = 5000
local DAY = 86400

local PERIODS = {
	{ "session", "This session" },
	{ "today",   "Today" },
	{ "week",    "Last 7 days" },
	{ "month",   "Last 30 days" },
	{ "all",     "All time" },
}
local PERIOD_LABEL = {}
for _, p in ipairs(PERIODS) do PERIOD_LABEL[p[1]] = p[2] end

local sessionStart = time()   -- "This session" = since login, or since "New session"

local function Rounds()
	db.global.rounds = db.global.rounds or {}
	return db.global.rounds
end

local function InPeriod(rec, period)
	if period == "all" then return true end
	if rec.legacy then return false end          -- imported pre-2.2 totals: all time only
	local t = rec.t or 0
	if period == "session" then return t >= sessionStart end
	if period == "today"   then return date("%Y%m%d", t) == date("%Y%m%d") end
	if period == "week"    then return t >= time() - 7 * DAY end
	if period == "month"   then return t >= time() - 30 * DAY end
	return true
end

-- 1234 -> "1,234g"; signed adds "+" to gains.
local function Gold(n, signed)
	n = n or 0
	local neg = n < 0
	local digits = tostring(floor(math.abs(n) + 0.5))
	digits = (digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
	local sign = neg and "-" or ((signed and n > 0) and "+" or "")
	return sign .. digits .. "g"
end

local function Plural(n, one, many) return n == 1 and one or many end

function RC:RecordRound(rec)
	local rounds = Rounds()
	tinsert(rounds, rec)
	while #rounds > MAX_ROUNDS do
		local drop = rounds[1].legacy and 2 or 1     -- never drop the imported totals
		table.remove(rounds, drop)
	end
	if self.RefreshHistory then self:RefreshHistory() end
end

-- Per-player overview for a period, best net first, plus period totals.
function RC:Aggregate(period)
	local players, order = {}, {}
	local totals = { rounds = 0, ties = 0, moved = 0, biggest = nil }
	local function P(name)
		local key = strlower(name)
		local p = players[key]
		if not p then
			p = { name = name, net = 0, rounds = 0, wins = 0, losses = 0, best = 0, worst = 0 }
			players[key] = p
			order[#order + 1] = p
		end
		return p
	end
	for _, rec in ipairs(Rounds()) do
		if InPeriod(rec, period) then
			if rec.legacy then
				for name, d in pairs(rec.deltas or {}) do
					local p = P(name)
					p.net, p.imported = p.net + d, true
				end
			else
				totals.rounds = totals.rounds + 1
				if rec.tie then totals.ties = totals.ties + 1 end
				for _, pl in ipairs(rec.players or {}) do
					local p = P(pl.n)
					p.rounds = p.rounds + 1
				end
				for name, d in pairs(rec.deltas or {}) do
					local p = P(name)
					p.net = p.net + d
					if d > 0 then
						p.wins, p.best = p.wins + 1, math.max(p.best, d)
						totals.moved = totals.moved + d
					elseif d < 0 then
						p.losses, p.worst = p.losses + 1, math.min(p.worst, d)
					end
				end
				if rec.each and rec.each > 0 and (not totals.biggest or rec.each > totals.biggest.each) then
					totals.biggest = rec
				end
			end
		end
	end
	table.sort(order, function(a, b)
		if a.net ~= b.net then return a.net > b.net end
		return a.name < b.name
	end)
	return order, totals
end

function RC:PeriodName(period) return PERIOD_LABEL[period] or PERIOD_LABEL.session end

-- which = "top" (biggest winners) or "bottom" (biggest losers).
function RC:PostLeaderboard(which, n, period)
	period = period or db.profile.histPeriod
	n = n or db.profile.topN
	local order = self:Aggregate(period)
	local list = {}
	if which == "bottom" then
		for i = #order, 1, -1 do
			if #list >= n then break end
			list[#list + 1] = order[i]
		end
	else
		for i = 1, #order do
			if #list >= n then break end
			list[#list + 1] = order[i]
		end
	end
	if #list == 0 then
		self:Print("No rounds recorded for " .. self:PeriodName(period) .. ".")
		return
	end
	self:ChatMsg(format(".:HiLo %s %d - %s:.", which == "bottom" and "Bottom" or "Top", #list, self:PeriodName(period)))
	for i, p in ipairs(list) do
		local detail
		if p.rounds == 0 then
			detail = "imported"
		else
			detail = format("%d %s, %dW/%dL", p.rounds, Plural(p.rounds, "round", "rounds"), p.wins, p.losses)
		end
		self:ChatMsg(format("%d. %s  %s  (%s)", i, p.name, Gold(p.net, true), detail))
	end
end

local function RoundResult(rec)
	if rec.tie then return "Tie - no payout" end
	return format("%s owes %s %s%s", table.concat(rec.losers or {}, ", "), table.concat(rec.winners or {}, ", "),
		Gold(rec.each), (#(rec.losers or {}) + #(rec.winners or {}) > 2) and " each" or "")
end

function RC:PostSummary(period)
	period = period or db.profile.histPeriod
	local order, totals = self:Aggregate(period)
	if totals.rounds == 0 and #order == 0 then
		self:Print("No rounds recorded for " .. self:PeriodName(period) .. ".")
		return
	end
	self:ChatMsg(format(".:HiLo Stats - %s:. %d %s (%d %s), %s changed hands",
		self:PeriodName(period), totals.rounds, Plural(totals.rounds, "round", "rounds"),
		totals.ties, Plural(totals.ties, "tie", "ties"), Gold(totals.moved)))
	if totals.biggest then
		self:ChatMsg(format(".:HiLo:. Biggest round: %s (%s)", RoundResult(totals.biggest),
			date("%d %b %H:%M", totals.biggest.t)))
	end
	local top, bottom = order[1], order[#order]
	if top and top.net > 0 then
		self:ChatMsg(format(".:HiLo:. Luckiest: %s %s  -  Unluckiest: %s %s", top.name, Gold(top.net, true),
			bottom.name, Gold(bottom.net, true)))
	end
end

function RC:PostRound(rec)
	if not rec or rec.legacy then return end
	local rolls = {}
	for _, pl in ipairs(rec.players or {}) do rolls[#rolls + 1] = pl.n .. " " .. pl.r end
	self:ChatMsg(format(".:HiLo Round %s:. %s", date("%H:%M", rec.t), RoundResult(rec)))
	if #rolls > 0 then self:ChatMsg(".:HiLo:. Rolls: " .. table.concat(rolls, ", ")) end
end

function RC:DeleteRound(rec)
	local rounds = Rounds()
	for i = #rounds, 1, -1 do
		if rounds[i] == rec then table.remove(rounds, i) break end
	end
	if self.RefreshHistory then self:RefreshHistory() end
end

function RC:CountPeriod(period)
	local n = 0
	for _, rec in ipairs(Rounds()) do if InPeriod(rec, period) then n = n + 1 end end
	return n
end

function RC:ClearPeriod(period)
	local rounds, removed = Rounds(), 0
	for i = #rounds, 1, -1 do
		if InPeriod(rounds[i], period) then
			table.remove(rounds, i)
			removed = removed + 1
		end
	end
	self:Print(format("Deleted %d %s (%s).", removed, Plural(removed, "round", "rounds"), self:PeriodName(period)))
	if self.RefreshHistory then self:RefreshHistory() end
end

function RC:NewSession()
	sessionStart = time()
	self:Print("New session started - \"This session\" counts from now. History is kept.")
	if self.RefreshHistory then self:RefreshHistory() end
	self:RefreshControls()
end

-- Older entry points (minimap right-click, old buttons) map onto history.
function RC:BroadcastSessionStats() self:PostLeaderboard("top", nil, "session") end
function RC:BroadcastAllTimeStats() self:PostLeaderboard("top", nil, "all") end
function RC:ResetSessionStats() self:NewSession() end

--==========================================================================
--  RULES / RESULTS
--==========================================================================

function RC:PrintRules()
	self:ChatMsg(format(".:HiLo:. %s RULES:.", db.profile.rulesName))
	self:ChatMsg(".:Players will /roll the STAKES:.")
	self:ChatMsg(".:High roll wins. Low Roll loses. Loser pays out the roll difference:.")
end

function RC:ReportResults()
	local highRoll = self:GetHighRoll()
	local lowRoll  = self:GetLowRoll()
	local goldOwed = highRoll - lowRoll
	local splitCount = #round.lowTyers + #round.highTyers - 1
	if splitCount < 1 then splitCount = 1 end
	goldOwed = goldOwed / splitCount

	-- The history record for this round (gold, as announced).
	local rec = { t = time(), cap = round.stakes, ratio = CurrentRatio(), players = {}, deltas = {} }
	for _, v in pairs(round.entrants) do
		if v.entered and v.rolled then tinsert(rec.players, { n = v.name, r = v.roll }) end
	end
	table.sort(rec.players, function(a, b) return a.r > b.r end)

	if goldOwed ~= 0 and highRoll > 0 and lowRoll > 0 then
		-- Trackers hold entrant keys; chat and stats use the display names.
		local function nameOf(key) return round.entrants[key] and round.entrants[key].name or key end
		local each = floor(goldOwed / CurrentRatio())   -- same figure ConvertRollToGold announces
		rec.each, rec.winners, rec.losers = each, {}, {}

		local lowNames = nameOf(round.lowRoller)
		tinsert(rec.losers, lowNames)
		for idx = 2, #round.lowTyers do
			local n = nameOf(round.lowTyers[idx])
			lowNames = lowNames .. ", " .. n
			tinsert(rec.losers, n)
		end

		local highNames = nameOf(round.highRoller)
		tinsert(rec.winners, highNames)
		for idx = 2, #round.highTyers do
			local n = nameOf(round.highTyers[idx])
			highNames = highNames .. ", " .. n
			tinsert(rec.winners, n)
		end

		for _, n in ipairs(rec.losers)  do rec.deltas[n] = (rec.deltas[n] or 0) - each end
		for _, n in ipairs(rec.winners) do rec.deltas[n] = (rec.deltas[n] or 0) + each end

		local msg = format("%s owes %s < %s >", lowNames, highNames, ConvertRollToGold(goldOwed))
		if splitCount > 1 then msg = msg .. " each." end
		self:ChatMsg(format(".:HiLo Payouts:. %s", msg))
	else
		rec.tie = true
		self:ChatMsg(".:HiLo:. TIE! No payouts on this roll!")
	end

	self:RecordRound(rec)
end

--==========================================================================
--  ROUND STATE MACHINE
--==========================================================================

function RC:ResetRound()
	round = NewRound()
	round.stakes = self:RollCap()
	personalEntered = false
	personalRolled  = false
	self:UpdateActionList()
	self:RefreshControls()
end

function RC:StartRound()
	personalEntered     = false
	personalRolled      = false
	round.stakes        = self:RollCap()
	round.entrants      = {}
	round.entrantsCount = 0
	round.highRoller    = nil
	round.lowRoller     = nil
	round.highTyers     = {}
	round.lowTyers      = {}
	round.acceptEntries = true
	round.acceptRolls   = false

	self:ChatMsg(format(".:Hi-Lo Casino:. RULES: %s .:. STAKES << %s >>", db.profile.rulesName, ConvertRollToGold(round.stakes)))
	self:ChatMsg(format(".:HiLo:. To enter: type %s", db.profile.enterMsg))
end

function RC:AnnounceLastCall()
	self:ChatMsg(format(".:HiLo:. Last Call to join! To withdraw, type %s", db.profile.withdrawMsg))
end

function RC:AnnounceRolling()
	if round.entrantsCount > 1 then
		round.acceptEntries = false
		round.acceptRolls   = true
		self:ChatMsg(format(".:HiLo - /roll %s NOW:.", round.stakes))
	else
		self:ChatMsg("Not enough Players!")
	end
end

function RC:RoundWrapup()
	-- Runs from the CHAT_MSG_SYSTEM roll event, so Say/channel lines are queued.
	deferChat = true
	self:ReportResults()
	deferChat = false
	self:ResetRound()
	if pendingMsgs then
		self:Print("|cffffff00Round complete.|r Click |cff59f0dcAnnounce Results|r (or type /hilo next) to post the payouts.")
	else
		self:Print("|cffffff00Round complete and reset.|r")
	end
end

function RC:NextPhase()
	if self:FlushPending() then return end
	if round.phase == 0 then
		self:StartRound()
	elseif round.phase == 1 then
		self:AnnounceLastCall()
	elseif round.phase == 2 then
		self:AnnounceRolling()
		if not round.acceptRolls then return end   -- not enough players, stay on this phase
	end
	round.phase = round.phase + 1
	self:RefreshControls()
end

function RC:ListRemaining()
	local rollers = ""
	for _, info in pairs(round.entrants) do
		if info.entered and not info.rolled then
			rollers = info.name .. (rollers == "" and "" or ", ") .. rollers
		end
	end
	local function nameOf(key) return key and round.entrants[key] and round.entrants[key].name or tostring(key) end
	if rollers == "" then
		self:ChatMsg("Everyone has rolled.")
	else
		self:ChatMsg(format("Remaining Rollers: %s  .:.  High: %s (%s)  Low: %s (%s)",
			rollers, nameOf(round.highRoller), self:GetHighRoll(), nameOf(round.lowRoller), self:GetLowRoll()))
	end
end

--==========================================================================
--  USER ACTIONS (button callbacks)
--==========================================================================

function RC:DoPersonalEnter()
	self:ChatMsg(db.profile.enterMsg)
	personalEntered = true
	self:RefreshControls()
end

function RC:DoPersonalRoll()
	if RandomRoll then
		RandomRoll(1, round.stakes)
	else
		hash_SlashCmdList[SLASH_RANDOM1:upper()](round.stakes)
	end
	personalRolled = true
	self:RefreshControls()
end

--==========================================================================
--  UI  (NaowhForever house look: follows its live theme and fonts when it
--  is loaded, otherwise its "Midnight" palette)
--==========================================================================

local FALLBACK_THEME = {   -- NaowhForever "Midnight" preset
	bg         = { r = 0x0b / 255, g = 0x10 / 255, b = 0x20 / 255 },
	panel      = { r = 0x15 / 255, g = 0x1c / 255, b = 0x30 / 255 },
	line       = { r = 0x2a / 255, g = 0x35 / 255, b = 0x50 / 255 },
	fg         = { r = 0xee / 255, g = 0xf2 / 255, b = 0xff / 255 },
	muted      = { r = 0x9b / 255, g = 0xa7 / 255, b = 0xc8 / 255 },
	accent     = { r = 0x5b / 255, g = 0x8c / 255, b = 0xff / 255 },
	accentSoft = { r = 0x8f / 255, g = 0xb0 / 255, b = 0xff / 255 },
}
local WIN_RGB     = { r = 0.30, g = 0.82, b = 0.48 }   -- Naowh "have" green
local LOSE_RGB    = { r = 0.97, g = 0.44, b = 0.44 }   -- Naowh red
local PENDING_RGB = { r = 0.98, g = 0.80, b = 0.08 }   -- Naowh "time low" amber

local WIN_W, WIN_H = 520, 660
local HEADER, PAD, FOOTER = 52, 12, 20
local CARD_PAD, CARD_GAP, CARD_TITLE = 10, 8, 30
local INNER = WIN_W - PAD * 2 - CARD_PAD * 2      -- usable width inside a card
local ROW_H = 22
local DISABLED_ALPHA = 0.4
local BACKDROP_ALPHA = 0.97
local CARD_FILL, CARD_EDGE = 0.035, 0.7
local ICON = "Interface\\AddOns\\HiLoCasino\\media\\icon"

local function Naowh()
	local N = _G.NaowhForever
	if type(N) == "table" and type(N.THEME) == "table" then return N end
end

local function Theme()
	local N = Naowh()
	local T = N and N.THEME
	if T and T.bg and T.fg and T.accent then return T end
	return FALLBACK_THEME
end

local function FontPath(heading)
	local N = Naowh()
	local fn = N and (heading and N.HeadingFontPath or N.UIFontPath)
	if fn then
		local ok, path = pcall(fn)
		if ok and type(path) == "string" and path ~= "" then return path end
	end
	return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

local function Px(region)
	return PixelUtil.GetPixelToUIUnitFactor() / math.max(region:GetEffectiveScale(), 0.01)
end

local function Hex(c)
	return format("|cff%02x%02x%02x", floor(c.r * 255 + 0.5), floor(c.g * 255 + 0.5), floor(c.b * 255 + 0.5))
end

-- Static widgets register a painter; the window re-runs them all on show,
-- so a theme or font change in NaowhForever is picked up next time it opens.
local painters = {}
local function Paint(fn)
	painters[#painters + 1] = fn
	fn(Theme())
end
local function RepaintAll()
	local T = Theme()
	for i = 1, #painters do painters[i](T) end
end

local function Border(frame, layer)
	local edges = {}
	for i = 1, 4 do edges[i] = frame:CreateTexture(nil, layer or "BORDER", nil, 7) end
	edges[1]:SetPoint("TOPLEFT");    edges[1]:SetPoint("TOPRIGHT")
	edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT")
	edges[3]:SetPoint("TOPLEFT");    edges[3]:SetPoint("BOTTOMLEFT")
	edges[4]:SetPoint("TOPRIGHT");   edges[4]:SetPoint("BOTTOMRIGHT")
	local border = {}
	function border.SetColor(_, r, g, b, a)
		for i = 1, 4 do edges[i]:SetColorTexture(r, g, b, a or 1) end
	end
	function border.Fit()
		local p = Px(frame)
		edges[1]:SetHeight(p); edges[2]:SetHeight(p)
		edges[3]:SetWidth(p);  edges[4]:SetWidth(p)
	end
	border.Fit()
	return border
end

-- colorKey: a THEME key repainted with the theme, or nil for caller-set color.
local function Text(parent, size, colorKey, heading, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	if heading then
		fs:SetShadowColor(0, 0, 0, 1)
		fs:SetShadowOffset(1, -1)
	end
	if justify then fs:SetJustifyH(justify) end
	Paint(function(T)
		fs:SetFont(FontPath(heading), size, "")
		if colorKey then
			local c = T[colorKey] or T.fg
			fs:SetTextColor(c.r, c.g, c.b, 1)
		end
	end)
	return fs
end

local function Click()
	if SOUNDKIT and SOUNDKIT.U_CHAT_SCROLL_BUTTON then PlaySound(SOUNDKIT.U_CHAT_SCROLL_BUTTON) end
end

local function ButtonRest(btn)
	local T = Theme()
	if btn.primary then
		btn.bg:SetColorTexture(T.accent.r, T.accent.g, T.accent.b, 1)
		btn.border:SetColor(T.accent.r, T.accent.g, T.accent.b, 1)
		btn.label:SetTextColor(T.bg.r, T.bg.g, T.bg.b, 1)
	else
		btn.bg:SetColorTexture(T.panel.r, T.panel.g, T.panel.b, 0.9)
		btn.border:SetColor(T.line.r, T.line.g, T.line.b, 1)
		btn.label:SetTextColor(T.fg.r, T.fg.g, T.fg.b, 1)
	end
end

local function ButtonHover(btn)
	if btn.disabled then return end
	local T = Theme()
	local soft = T.accentSoft or T.accent
	if btn.primary then
		btn.bg:SetColorTexture(soft.r, soft.g, soft.b, 1)
	else
		btn.bg:SetColorTexture(T.panel.r, T.panel.g, T.panel.b, 1)
	end
	btn.border:SetColor(T.accent.r, T.accent.g, T.accent.b, 1)
	if btn.tip then
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		GameTooltip:SetText(btn.tip, 1, 1, 1, 1, true)
		GameTooltip:Show()
	end
end

local function Button(parent, text, w, h, onClick, primary, tip)
	local btn = CreateFrame("Button", nil, parent)
	btn:SetSize(w, h)
	btn.bg = btn:CreateTexture(nil, "BACKGROUND")
	btn.bg:SetAllPoints()
	btn.border = Border(btn)
	btn.label = Text(btn, 12, nil, true)
	btn.label:SetPoint("CENTER")
	btn.label:SetText(text)
	btn.primary, btn.tip = primary, tip
	btn:SetScript("OnEnter", ButtonHover)
	btn:SetScript("OnLeave", function(self) ButtonRest(self); GameTooltip:Hide() end)
	btn:SetScript("OnClick", function(self)
		if self.disabled then return end
		Click()
		if onClick then onClick(self) end
	end)
	-- AceGUI-compatible calls used by RefreshControls.
	btn.SetText = function(self, t) self.label:SetText(t) end
	btn.SetDisabled = function(self, disabled)
		self.disabled = disabled and true or false
		self:SetAlpha(self.disabled and DISABLED_ALPHA or 1)
		if self.disabled then ButtonRest(self) end
	end
	Paint(function() ButtonRest(btn); btn.border.Fit() end)
	return btn
end

local function Field(parent, w, h, onCommit)
	local box = CreateFrame("EditBox", nil, parent)
	box:SetSize(w, h)
	box:SetAutoFocus(false)
	box:SetTextInsets(8, 8, 0, 0)
	box.bg = box:CreateTexture(nil, "BACKGROUND")
	box.bg:SetAllPoints()
	box.border = Border(box)
	local function Rest(self)
		local T = Theme()
		local c = self:HasFocus() and T.accent or T.line
		self.border:SetColor(c.r, c.g, c.b, 1)
	end
	local function Commit(self)
		if self.committing then return end
		self.committing = true
		onCommit(self, self:GetText())
		self.committing = false
	end
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	box:SetScript("OnEditFocusGained", Rest)
	box:SetScript("OnEditFocusLost", function(self) Commit(self); Rest(self) end)
	box.SetDisabled = function(self, disabled)
		self:SetEnabled(not disabled)
		self:SetAlpha(disabled and DISABLED_ALPHA or 1)
		if disabled then self:ClearFocus() end
	end
	Paint(function(T)
		box:SetFont(FontPath(false), 12, "")
		box:SetTextColor(T.fg.r, T.fg.g, T.fg.b, 1)
		box.bg:SetColorTexture(T.bg.r, T.bg.g, T.bg.b, 0.9)
		Rest(box)
		box.border.Fit()
	end)
	return box
end

-- options: array of { value, text }.
local function Dropdown(parent, w, h, options, getValue, setValue)
	local dd = Button(parent, "", w, h)
	dd.label:ClearAllPoints()
	dd.label:SetPoint("LEFT", 10, 0)
	dd.label:SetPoint("RIGHT", -24, 0)
	dd.label:SetJustifyH("LEFT")
	dd.label:SetWordWrap(false)

	local N = Naowh()
	local arrow = dd:CreateTexture(nil, "OVERLAY")
	arrow:SetSize(12, 12)
	arrow:SetPoint("RIGHT", -8, 0)
	if N and N.MEDIA then
		arrow:SetTexture(N.MEDIA .. "chevron", nil, nil, "TRILINEAR")
		arrow:SetRotation(-math.pi / 2)
	else
		arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
	end
	Paint(function(T) arrow:SetVertexColor(T.muted.r, T.muted.g, T.muted.b, 1) end)

	function dd:Refresh()
		local v = getValue()
		for _, o in ipairs(options) do
			if o[1] == v then self.label:SetText(o[2]); return end
		end
		self.label:SetText(tostring(v))
	end
	dd:SetScript("OnClick", function(self)
		if self.disabled then return end
		Click()
		MenuUtil.CreateContextMenu(self, function(_, root)
			for _, o in ipairs(options) do
				root:CreateRadio(o[2],
					function() return getValue() == o[1] end,
					function() setValue(o[1]); dd:Refresh() end)
			end
		end)
	end)
	dd:Refresh()
	return dd
end

local function Card(parent, title)
	local card = CreateFrame("Frame", nil, parent)
	card.fill = card:CreateTexture(nil, "BACKGROUND")
	card.fill:SetAllPoints()
	card.border = Border(card)
	card.title = Text(card, 12, "accent", true, "LEFT")
	card.title:SetPoint("TOPLEFT", CARD_PAD, -10)
	card.title:SetText(title)
	Paint(function(T)
		card.fill:SetColorTexture(T.fg.r, T.fg.g, T.fg.b, CARD_FILL)
		card.border:SetColor(0, 0, 0, CARD_EDGE)
		card.border.Fit()
	end)
	return card
end

local function FieldLabel(parent, text, x, y)
	local fs = Text(parent, 11, "muted", false, "LEFT")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
	return fs
end

------------------------------------------------------------------------
--  Controls state
------------------------------------------------------------------------

function RC:RefreshControls()
	local ui = self.ui
	if not ui or not ui.frame then return end
	local p = round.phase
	local T = Theme()

	if pendingMsgs then
		ui.phaseBtn:SetText("Announce Results")
		ui.phaseBtn:SetDisabled(false)
	else
		ui.phaseBtn:SetText(PHASE_LABELS[p] or PHASE_LABELS[0])
		ui.phaseBtn:SetDisabled(p >= 3)
	end

	ui.listBtn:SetDisabled(not (p >= 3 and self:GetRemainingToRollCount() > 0))
	ui.resetBtn:SetDisabled(p == 0)
	ui.enterBtn:SetDisabled(personalEntered or not round.acceptEntries)
	ui.rollBtn:SetDisabled(personalRolled or not round.acceptRolls)

	ui.stakesEdit:SetDisabled(p ~= 0)
	ui.ratioDrop:SetDisabled(p ~= 0)
	if p == 0 and not ui.stakesEdit:HasFocus() then ui.stakesEdit:SetText(tostring(db.profile.stakesGold)) end
	ui.ratioDrop:Refresh()
	ui.channelDrop:Refresh()

	local cap = round.stakes
	ui.rollFor:SetText(format("Rolling for %s%s|r   %s·|r   players %s/roll 1-%d|r",
		Hex(T.accent), ConvertRollToGold(cap), Hex(T.muted), Hex(T.fg), cap))
	ui.ratioNote:SetText(RATIO_OPTIONS[CurrentRatio()] or (CurrentRatio() .. " : 1"))

	local phaseName = ({ [0] = "Idle", [1] = "Entry open", [2] = "Last call", [3] = "Rolling" })[p] or "Idle"
	ui.subtitle:SetText(format("%s   ·   %d entrants   ·   %d yet to roll",
		phaseName, round.entrantsCount or 0, self:GetRemainingToRollCount()))
	ui.potNote:SetText(format("Pot %s  ·  1-%d", ConvertRollToGold(cap), cap))

	ui.topBtn:SetText("Post Top " .. db.profile.topN)
	ui.bottomBtn:SetText("Post Bottom " .. db.profile.topN)
	ui.statsPeriod:SetText(self:PeriodName(db.profile.histPeriod))
end

------------------------------------------------------------------------
--  The Action (entrant list, pooled rows)
------------------------------------------------------------------------

local function ActionRow(ui, i)
	local row = ui.rows[i]
	if row then return row end
	row = CreateFrame("Frame", nil, ui.listChild)
	row:SetHeight(ROW_H)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
	row:SetPoint("RIGHT", ui.listChild, "RIGHT")
	row.stripe = row:CreateTexture(nil, "BACKGROUND")
	row.stripe:SetAllPoints()
	row.idx = Text(row, 11, "muted", false, "RIGHT")
	row.idx:SetPoint("LEFT", 0, 0)
	row.idx:SetWidth(22)
	row.name = Text(row, 12, nil, false, "LEFT")
	row.name:SetPoint("LEFT", row.idx, "RIGHT", 10, 0)
	row.roll = Text(row, 12, nil, true, "RIGHT")
	row.roll:SetPoint("RIGHT", -10, 0)
	row.mark = row:CreateTexture(nil, "ARTWORK")
	row.mark:SetSize(2, ROW_H - 8)
	row.mark:SetPoint("LEFT", row.idx, "RIGHT", 4, 0)
	ui.rows[i] = row
	return row
end

function RC:UpdateActionList()
	local ui = self.ui
	if not ui or not ui.listChild then return end
	local T = Theme()

	-- Stable order: by roll (high first) once rolled, then by name.
	local list = {}
	for _, v in pairs(round.entrants) do list[#list + 1] = v end
	table.sort(list, function(a, b)
		local ra, rb = tonumber(a.roll) or -1, tonumber(b.roll) or -1
		if ra ~= rb then return ra > rb end
		return a.name < b.name
	end)

	for i, v in ipairs(list) do
		local row = ActionRow(ui, i)
		row:Show()
		row.stripe:SetColorTexture(T.fg.r, T.fg.g, T.fg.b, (i % 2 == 0) and 0.025 or 0)
		row.idx:SetText(i .. ".")
		row.name:SetText(v.name)

		local c, rollText, mark = T.fg, tostring(v.roll), nil
		if not v.entered then
			c, rollText = T.muted, "withdrawn"
		elseif (tonumber(v.roll) or 0) <= 0 then
			c, rollText = PENDING_RGB, "—"
		elseif has_value(round.highTyers, v.key) then
			c, mark = WIN_RGB, WIN_RGB
		elseif has_value(round.lowTyers, v.key) then
			c, mark = LOSE_RGB, LOSE_RGB
		end
		row.name:SetTextColor(v.entered and T.fg.r or T.muted.r, v.entered and T.fg.g or T.muted.g, v.entered and T.fg.b or T.muted.b, 1)
		row.roll:SetText(rollText)
		row.roll:SetTextColor(c.r, c.g, c.b, 1)
		if mark then
			row.mark:SetColorTexture(mark.r, mark.g, mark.b, 1)
			row.mark:Show()
		else
			row.mark:Hide()
		end
	end
	for i = #list + 1, #ui.rows do ui.rows[i]:Hide() end

	ui.listChild:SetHeight(math.max(1, #list * ROW_H))
	ui.empty:SetShown(#list == 0)
	if #list == 0 then
		ui.empty:SetText(format("No entrants yet.\nStart a round and have players type  %s%s|r",
			Hex(T.accent), db.profile.enterMsg))
	end
	ui.actionCount:SetText(#list > 0 and format("%d %s", #list, #list == 1 and "player" or "players") or "")
end

------------------------------------------------------------------------
--  Game card (custom channel row only when "Custom Channel" is picked)
------------------------------------------------------------------------

function RC:RebuildGameGroup()
	local ui = self.ui
	if not ui or not ui.gameCard then return end
	local showChannel = db.profile.chatMethod == "CHANNEL"
	ui.channelLabel:SetShown(showChannel)
	ui.channelEdit:SetShown(showChannel)
	if showChannel then ui.channelEdit:SetText(db.profile.customChannel) end

	local y = showChannel and -134 or -86
	ui.rollFor:ClearAllPoints()
	ui.rollFor:SetPoint("TOPLEFT", CARD_PAD, y)
	ui.ratioNote:ClearAllPoints()
	ui.ratioNote:SetPoint("TOPRIGHT", -CARD_PAD, y)
	ui.rulesBtn:ClearAllPoints()
	ui.rulesBtn:SetPoint("TOPLEFT", CARD_PAD, y - 24)
	ui.gameCard:SetHeight(-(y - 24) + 24 + CARD_PAD)
	self:RefreshControls()
end

------------------------------------------------------------------------
--  Window
------------------------------------------------------------------------

local function SavePosition(frame)
	local point, _, relPoint, x, y = frame:GetPoint()
	db.profile.window = { point, relPoint, x, y }
end

function RC:BuildWindow()
	if self.ui and self.ui.frame then return end
	local ui = { rows = {} }
	self.ui = ui

	local f = CreateFrame("Frame", "HiLoCasinoWindow", UIParent)
	f:Hide()
	f:SetSize(WIN_W, WIN_H)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition(self) end)
	local pos = db.profile.window
	if type(pos) == "table" and pos[1] then
		f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
	else
		f:SetPoint("CENTER")
	end
	tinsert(UISpecialFrames, "HiLoCasinoWindow")   -- Esc closes it
	ui.frame = f

	-- Backdrop, outer border, header rule.
	local bg = f:CreateTexture(nil, "BACKGROUND", nil, -8)
	bg:SetAllPoints()
	local outer = Border(f, "OVERLAY")
	local rule = f:CreateTexture(nil, "ARTWORK")
	rule:SetPoint("TOPLEFT", 0, -HEADER)
	rule:SetPoint("TOPRIGHT", 0, -HEADER)
	local headTint = f:CreateTexture(nil, "BACKGROUND", nil, -7)
	headTint:SetPoint("TOPLEFT")
	headTint:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", 0, -HEADER)
	Paint(function(T)
		bg:SetColorTexture(T.bg.r, T.bg.g, T.bg.b, BACKDROP_ALPHA)
		headTint:SetColorTexture(T.panel.r, T.panel.g, T.panel.b, 0.6)
		outer:SetColor(0, 0, 0, 1)
		outer.Fit()
		rule:SetColorTexture(0, 0, 0, 1)
		rule:SetHeight(Px(f))
	end)

	-- Header: logo, title, live status line, close.
	local logo = f:CreateTexture(nil, "ARTWORK")
	logo:SetSize(32, 32)
	logo:SetPoint("LEFT", f, "TOPLEFT", PAD, -HEADER / 2)
	logo:SetTexture(ICON)
	local title = Text(f, 20, "fg", true, "LEFT")
	title:SetPoint("TOPLEFT", logo, "TOPRIGHT", 10, 1)
	Paint(function(T) title:SetText("Hi-Lo " .. Hex(T.accent) .. "Casino|r") end)
	ui.subtitle = Text(f, 11, "muted", false, "LEFT")
	ui.subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
	local close = Button(f, "x", 24, 24, function() f:Hide() end)
	close:SetPoint("RIGHT", f, "TOPRIGHT", -8, -HEADER / 2)

	-- Footer: brand and pot.
	local brand = Text(f, 10, "muted", false, "LEFT")
	brand:SetPoint("BOTTOMLEFT", PAD + 2, 6)
	local version = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version") or ""
	Paint(function(T) brand:SetText(Hex(T.fg) .. "Hi-Lo|r " .. Hex(T.accent) .. "Casino|r  " .. version) end)
	ui.potNote = Text(f, 10, "muted", false, "RIGHT")
	ui.potNote:SetPoint("BOTTOMRIGHT", -PAD - 2, 6)

	-- ===== Game card =====
	local game = Card(f, "Game")
	game:SetPoint("TOPLEFT", PAD, -HEADER - PAD)
	game:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
	ui.gameCard = game

	local colW = floor((INNER - 2 * 10) / 3)
	FieldLabel(game, "Stakes (gold)", CARD_PAD, -CARD_TITLE)
	FieldLabel(game, "Ratio  (roll : gold)", CARD_PAD + colW + 10, -CARD_TITLE)
	FieldLabel(game, "Broadcast to", CARD_PAD + 2 * (colW + 10), -CARD_TITLE)

	ui.stakesEdit = Field(game, colW, 26, function(box, text)
		local v = tonumber(text)
		if v and v > 0 then
			db.profile.stakesGold = floor(v)
			if round.phase == 0 then round.stakes = RC:RollCap() end
		end
		box:SetText(tostring(db.profile.stakesGold))
		RC:RefreshControls()
	end)
	ui.stakesEdit:SetPoint("TOPLEFT", CARD_PAD, -CARD_TITLE - 16)
	ui.stakesEdit:SetNumeric(true)

	local ratioOptions = {}
	for _, k in ipairs(RATIO_ORDER) do ratioOptions[#ratioOptions + 1] = { k, RATIO_OPTIONS[k] } end
	ui.ratioDrop = Dropdown(game, colW, 26, ratioOptions,
		function() return db.profile.ratio end,
		function(v)
			db.profile.ratio = v
			if round.phase == 0 then round.stakes = RC:RollCap() end
			RC:RefreshControls()
		end)
	ui.ratioDrop:SetPoint("TOPLEFT", CARD_PAD + colW + 10, -CARD_TITLE - 16)

	local chanOptions = {}
	for _, k in ipairs(CHAT_METHODS) do chanOptions[#chanOptions + 1] = { k, CHAT_LABELS[k] } end
	ui.channelDrop = Dropdown(game, INNER - 2 * (colW + 10), 26, chanOptions,
		function() return db.profile.chatMethod end,
		function(v)
			db.profile.chatMethod = v
			RC:RebuildGameGroup()
		end)
	ui.channelDrop:SetPoint("TOPLEFT", CARD_PAD + 2 * (colW + 10), -CARD_TITLE - 16)

	ui.channelLabel = FieldLabel(game, "Custom channel name", CARD_PAD, -84)
	ui.channelEdit = Field(game, INNER, 26, function(box, text)
		text = text and text:gsub("^%s+", ""):gsub("%s+$", "") or ""
		if text ~= "" then db.profile.customChannel = text end
		box:SetText(db.profile.customChannel)
	end)
	ui.channelEdit:SetPoint("TOPLEFT", CARD_PAD, -100)

	ui.rollFor = Text(game, 13, "fg", false, "LEFT")
	ui.ratioNote = Text(game, 11, "muted", false, "RIGHT")
	ui.rulesBtn = Button(game, "Broadcast Rules", INNER, 24, function() RC:PrintRules() end, false,
		"Post the Hi/Lo rules to the broadcast channel.")

	-- ===== Round card =====
	local rc = Card(f, "Round")
	rc:SetPoint("TOPLEFT", game, "BOTTOMLEFT", 0, -CARD_GAP)
	rc:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
	rc:SetHeight(CARD_TITLE + 32 + 6 + 24 + 6 + 24 + CARD_PAD)

	local half = floor((INNER - 8) / 2)
	ui.phaseBtn = Button(rc, PHASE_LABELS[0], INNER, 32, function() RC:NextPhase() end, true)
	ui.phaseBtn:SetPoint("TOPLEFT", CARD_PAD, -CARD_TITLE)
	ui.listBtn = Button(rc, "List Remaining", half, 24, function() RC:ListRemaining() end, false,
		"Post who still has to roll, plus the current high and low.")
	ui.listBtn:SetPoint("TOPLEFT", ui.phaseBtn, "BOTTOMLEFT", 0, -6)
	ui.resetBtn = Button(rc, "Reset Round", INNER - half - 8, 24, function() RC:ResetRound() end)
	ui.resetBtn:SetPoint("LEFT", ui.listBtn, "RIGHT", 8, 0)
	ui.enterBtn = Button(rc, "Enter  (me)", half, 24, function() RC:DoPersonalEnter() end, false,
		"Join the round yourself.")
	ui.enterBtn:SetPoint("TOPLEFT", ui.listBtn, "BOTTOMLEFT", 0, -6)
	ui.rollBtn = Button(rc, "Roll  (me)", INNER - half - 8, 24, function() RC:DoPersonalRoll() end, false,
		"Do your /roll for this round.")
	ui.rollBtn:SetPoint("LEFT", ui.enterBtn, "RIGHT", 8, 0)

	-- ===== Stats card =====
	local st = Card(f, "Stats")
	st:SetPoint("TOPLEFT", rc, "BOTTOMLEFT", 0, -CARD_GAP)
	st:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
	st:SetHeight(CARD_TITLE + 24 + CARD_PAD)
	local third = floor((INNER - 16) / 3)
	ui.statsPeriod = Text(st, 11, "muted", false, "RIGHT")
	ui.statsPeriod:SetPoint("TOPRIGHT", -CARD_PAD, -11)
	ui.topBtn = Button(st, "Post Top 5", third, 24, function() RC:PostLeaderboard("top") end, false,
		"Post the biggest winners for the period chosen in History.")
	ui.topBtn:SetPoint("TOPLEFT", CARD_PAD, -CARD_TITLE)
	ui.bottomBtn = Button(st, "Post Bottom 5", third, 24, function() RC:PostLeaderboard("bottom") end, false,
		"Post the biggest losers for the period chosen in History.")
	ui.bottomBtn:SetPoint("LEFT", ui.topBtn, "RIGHT", 8, 0)
	local histBtn = Button(st, "History", INNER - 2 * third - 16, 24, function() RC:ToggleHistory() end, false,
		"Leaderboard, round log, summaries and clean-up for any period.")
	histBtn:SetPoint("LEFT", ui.bottomBtn, "RIGHT", 8, 0)

	-- ===== The Action card (fills the rest) =====
	local act = Card(f, "The Action")
	act:SetPoint("TOPLEFT", st, "BOTTOMLEFT", 0, -CARD_GAP)
	act:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, FOOTER + 6)
	ui.actionCount = Text(act, 11, "muted", false, "RIGHT")
	ui.actionCount:SetPoint("TOPRIGHT", -CARD_PAD, -11)

	local scroll = CreateFrame("ScrollFrame", nil, act)
	scroll:SetPoint("TOPLEFT", CARD_PAD, -CARD_TITLE)
	scroll:SetPoint("BOTTOMRIGHT", -CARD_PAD, CARD_PAD)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local maxScroll = math.max(0, ui.listChild:GetHeight() - self:GetHeight())
		self:SetVerticalScroll(math.min(maxScroll, math.max(0, self:GetVerticalScroll() - delta * ROW_H * 2)))
	end)
	ui.listChild = CreateFrame("Frame", nil, scroll)
	ui.listChild:SetSize(INNER, 1)
	scroll:SetScrollChild(ui.listChild)
	ui.empty = Text(act, 12, "muted", false, "CENTER")
	ui.empty:SetPoint("CENTER", scroll, "CENTER")

	f:SetScript("OnShow", function()
		RepaintAll()
		RC:RebuildGameGroup()
		RC:UpdateActionList()
	end)

	self:RebuildGameGroup()
	self:UpdateActionList()
end

function RC:ShowWindow()
	self:BuildWindow()
	self.ui.frame:Show()
end

function RC:HideWindow()
	if self.ui and self.ui.frame then self.ui.frame:Hide() end
end

function RC:ToggleWindow()
	if self.ui and self.ui.frame and self.ui.frame:IsShown() then
		self:HideWindow()
	else
		self:ShowWindow()
	end
end

------------------------------------------------------------------------
--  History window: leaderboard + round log for a chosen period
------------------------------------------------------------------------

local HIST_W, HIST_H = 600, 640
local HIST_INNER = HIST_W - PAD * 2 - CARD_PAD * 2
local LB_H = 280
local LOG_ROW = 22
local ARM_SECONDS = 3

-- Leaderboard columns, right-aligned, measured from the row's right edge.
local LB_COLS = {
	{ key = "worst",  title = "Worst",  w = 64, right = 0 },
	{ key = "best",   title = "Best",   w = 64, right = 70 },
	{ key = "wl",     title = "W / L",  w = 56, right = 140 },
	{ key = "rounds", title = "Rounds", w = 56, right = 202 },
	{ key = "net",    title = "Net",    w = 84, right = 264 },
}
local LB_NAME_RIGHT = 356

-- A button that needs a second click within a few seconds to fire.
local function Arm(btn, armedText, restText, onConfirm)
	if btn.armed then
		btn.armed = nil
		btn:SetText(restText)
		onConfirm()
		return
	end
	btn.armed = true
	btn:SetText(armedText)
	C_Timer.After(ARM_SECONDS, function()
		if btn.armed then btn.armed = nil; btn:SetText(restText) end
	end)
end

local function SetRGB(fs, c) fs:SetTextColor(c.r, c.g, c.b, 1) end

local function NetColor(T, n)
	if n > 0 then return WIN_RGB elseif n < 0 then return LOSE_RGB end
	return T.muted
end

local function HistoryScroll(card, top)
	local scroll = CreateFrame("ScrollFrame", nil, card)
	scroll:SetPoint("TOPLEFT", CARD_PAD, top)
	scroll:SetPoint("BOTTOMRIGHT", -CARD_PAD, CARD_PAD)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(HIST_INNER, 1)
	scroll:SetScrollChild(child)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local maxScroll = math.max(0, child:GetHeight() - self:GetHeight())
		self:SetVerticalScroll(math.min(maxScroll, math.max(0, self:GetVerticalScroll() - delta * LOG_ROW * 3)))
	end)
	return scroll, child
end

local function LeaderRow(h, i)
	local row = h.lbRows[i]
	if row then return row end
	row = CreateFrame("Frame", nil, h.lbChild)
	row:SetHeight(LOG_ROW)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * LOG_ROW)
	row:SetPoint("RIGHT", h.lbChild, "RIGHT")
	row.stripe = row:CreateTexture(nil, "BACKGROUND")
	row.stripe:SetAllPoints()
	row.rank = Text(row, 11, "muted", false, "RIGHT")
	row.rank:SetPoint("LEFT", 0, 0)
	row.rank:SetWidth(22)
	row.name = Text(row, 12, "fg", false, "LEFT")
	row.name:SetPoint("LEFT", row.rank, "RIGHT", 8, 0)
	row.name:SetPoint("RIGHT", row, "RIGHT", -LB_NAME_RIGHT, 0)
	row.name:SetWordWrap(false)
	row.cols = {}
	for _, col in ipairs(LB_COLS) do
		local fs = Text(row, 12, nil, col.key == "net", "RIGHT")
		fs:SetPoint("RIGHT", row, "RIGHT", -col.right - 4, 0)
		fs:SetWidth(col.w)
		row.cols[col.key] = fs
	end
	h.lbRows[i] = row
	return row
end

local function LogRow(h, i)
	local row = h.logRows[i]
	if row then return row end
	row = CreateFrame("Frame", nil, h.logChild)
	row:SetHeight(LOG_ROW)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * LOG_ROW)
	row:SetPoint("RIGHT", h.logChild, "RIGHT")
	row:EnableMouse(true)
	row.stripe = row:CreateTexture(nil, "BACKGROUND")
	row.stripe:SetAllPoints()
	row.when = Text(row, 11, "muted", false, "LEFT")
	row.when:SetPoint("LEFT", 2, 0)
	row.when:SetWidth(92)
	row.del = Button(row, "x", 20, 18, function(btn)
		Arm(btn, "?", "x", function() RC:DeleteRound(row.rec) end)
	end, false, "Delete this round from history (click twice).")
	row.del:SetPoint("RIGHT", -2, 0)
	row.post = Button(row, "Post", 40, 18, function() RC:PostRound(row.rec) end, false,
		"Post this round's result and rolls to the broadcast channel.")
	row.post:SetPoint("RIGHT", row.del, "LEFT", -4, 0)
	row.amount = Text(row, 12, nil, true, "RIGHT")
	row.amount:SetPoint("RIGHT", row.post, "LEFT", -10, 0)
	row.amount:SetWidth(70)
	row.result = Text(row, 12, "fg", false, "LEFT")
	row.result:SetPoint("LEFT", row.when, "RIGHT", 6, 0)
	row.result:SetPoint("RIGHT", row.amount, "LEFT", -8, 0)
	row.result:SetWordWrap(false)
	-- Hover: every roll of the round.
	row:SetScript("OnEnter", function(self)
		local rec = self.rec
		if not rec or rec.legacy then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(date("%A %d %B  %H:%M", rec.t), 1, 1, 1)
		GameTooltip:AddLine(format("Stakes %s  (1-%d, %d : 1)", Gold((rec.cap or 0) / (rec.ratio or 1)), rec.cap or 0, rec.ratio or 1), 0.7, 0.7, 0.7)
		for _, pl in ipairs(rec.players or {}) do
			local d = rec.deltas and rec.deltas[pl.n]
			local c = (d and d > 0 and WIN_RGB) or (d and d < 0 and LOSE_RGB) or { r = 0.9, g = 0.9, b = 0.9 }
			GameTooltip:AddDoubleLine(pl.n, tostring(pl.r), c.r, c.g, c.b, c.r, c.g, c.b)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	h.logRows[i] = row
	return row
end

local function ResultText(T, rec)
	if rec.legacy then return Hex(T.muted) .. "Imported totals from before 2.2|r" end
	if rec.tie then return Hex(T.muted) .. "Tie - no payout|r" end
	local each = (#(rec.losers or {}) + #(rec.winners or {}) > 2) and Hex(T.muted) .. " each|r" or ""
	return Hex(LOSE_RGB) .. table.concat(rec.losers or {}, ", ") .. "|r" .. Hex(T.muted) .. "  owes  |r"
		.. Hex(WIN_RGB) .. table.concat(rec.winners or {}, ", ") .. "|r" .. each
end

function RC:RefreshHistory()
	local h = self.hist
	if not h or not h.frame or not h.frame:IsShown() then return end
	local T = Theme()
	local period = db.profile.histPeriod
	local order, totals = self:Aggregate(period)

	h.periodDrop:Refresh()
	h.countDrop:Refresh()
	h.topBtn:SetText("Post Top " .. db.profile.topN)
	h.bottomBtn:SetText("Post Bottom " .. db.profile.topN)
	h.subtitle:SetText(format("%s   ·   %d %s   ·   %d %s   ·   %s changed hands", self:PeriodName(period),
		totals.rounds, Plural(totals.rounds, "round", "rounds"), totals.ties, Plural(totals.ties, "tie", "ties"),
		Gold(totals.moved)))
	h.lbCount:SetText(#order > 0 and format("%d %s", #order, Plural(#order, "player", "players")) or "")

	-- Leaderboard
	for i, p in ipairs(order) do
		local row = LeaderRow(h, i)
		row:Show()
		row.stripe:SetColorTexture(T.fg.r, T.fg.g, T.fg.b, (i % 2 == 0) and 0.025 or 0)
		row.rank:SetText(i .. ".")
		row.name:SetText(p.name)
		row.cols.net:SetText(Gold(p.net, true))
		SetRGB(row.cols.net, NetColor(T, p.net))
		row.cols.rounds:SetText(p.rounds > 0 and tostring(p.rounds) or "-")
		row.cols.wl:SetText(p.rounds > 0 and format("%d / %d", p.wins, p.losses) or "-")
		row.cols.best:SetText(p.best > 0 and Gold(p.best, true) or "-")
		row.cols.worst:SetText(p.worst < 0 and Gold(p.worst, true) or "-")
		SetRGB(row.cols.rounds, T.fg); SetRGB(row.cols.wl, T.muted)
		SetRGB(row.cols.best, p.best > 0 and WIN_RGB or T.muted)
		SetRGB(row.cols.worst, p.worst < 0 and LOSE_RGB or T.muted)
	end
	for i = #order + 1, #h.lbRows do h.lbRows[i]:Hide() end
	h.lbChild:SetHeight(math.max(1, #order * LOG_ROW))
	h.lbEmpty:SetShown(#order == 0)

	-- Round log, newest first
	local recs = {}
	local all = Rounds()
	for i = #all, 1, -1 do
		if InPeriod(all[i], period) then recs[#recs + 1] = all[i] end
	end
	for i, rec in ipairs(recs) do
		local row = LogRow(h, i)
		row:Show()
		row.rec = rec
		row.del.armed = nil
		row.del:SetText("x")
		row.stripe:SetColorTexture(T.fg.r, T.fg.g, T.fg.b, (i % 2 == 0) and 0.025 or 0)
		row.when:SetText(rec.legacy and "-" or date("%d %b  %H:%M", rec.t))
		row.result:SetText(ResultText(T, rec))
		if rec.legacy or rec.tie then
			row.amount:SetText("-")
			SetRGB(row.amount, T.muted)
		else
			row.amount:SetText(Gold(rec.each))
			SetRGB(row.amount, T.accent)
		end
		row.post:SetShown(not rec.legacy)
	end
	for i = #recs + 1, #h.logRows do h.logRows[i]:Hide() end
	h.logChild:SetHeight(math.max(1, #recs * LOG_ROW))
	h.logEmpty:SetShown(#recs == 0)
	h.logCount:SetText(#recs > 0 and format("%d %s", #recs, Plural(#recs, "round", "rounds")) or "")
	h.clearBtn.armed = nil
	h.clearBtn:SetText("Clear period")
	h.stored:SetText(format("%d %s stored", #all, Plural(#all, "round", "rounds")))
end

function RC:BuildHistory()
	if self.hist and self.hist.frame then return end
	local h = { lbRows = {}, logRows = {} }
	self.hist = h

	local f = CreateFrame("Frame", "HiLoCasinoHistory", UIParent)
	f:Hide()
	f:SetSize(HIST_W, HIST_H)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		db.profile.historyWindow = { point, relPoint, x, y }
	end)
	local pos = db.profile.historyWindow
	if type(pos) == "table" and pos[1] then
		f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
	elseif self.ui and self.ui.frame and self.ui.frame:IsShown() then
		f:SetPoint("TOPLEFT", self.ui.frame, "TOPRIGHT", 6, 0)
	else
		f:SetPoint("CENTER")
	end
	tinsert(UISpecialFrames, "HiLoCasinoHistory")
	h.frame = f

	local bg = f:CreateTexture(nil, "BACKGROUND", nil, -8)
	bg:SetAllPoints()
	local headTint = f:CreateTexture(nil, "BACKGROUND", nil, -7)
	headTint:SetPoint("TOPLEFT")
	headTint:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", 0, -HEADER)
	local outer = Border(f, "OVERLAY")
	local rule = f:CreateTexture(nil, "ARTWORK")
	rule:SetPoint("TOPLEFT", 0, -HEADER)
	rule:SetPoint("TOPRIGHT", 0, -HEADER)
	Paint(function(T)
		bg:SetColorTexture(T.bg.r, T.bg.g, T.bg.b, BACKDROP_ALPHA)
		headTint:SetColorTexture(T.panel.r, T.panel.g, T.panel.b, 0.6)
		outer:SetColor(0, 0, 0, 1)
		outer.Fit()
		rule:SetColorTexture(0, 0, 0, 1)
		rule:SetHeight(Px(f))
	end)

	local logo = f:CreateTexture(nil, "ARTWORK")
	logo:SetSize(32, 32)
	logo:SetPoint("LEFT", f, "TOPLEFT", PAD, -HEADER / 2)
	logo:SetTexture(ICON)
	local title = Text(f, 20, "fg", true, "LEFT")
	title:SetPoint("TOPLEFT", logo, "TOPRIGHT", 10, 1)
	Paint(function(T) title:SetText("Casino " .. Hex(T.accent) .. "History|r") end)
	h.subtitle = Text(f, 11, "muted", false, "LEFT")
	h.subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
	h.subtitle:SetPoint("RIGHT", f, "RIGHT", -44, 0)
	h.subtitle:SetWordWrap(false)
	local close = Button(f, "x", 24, 24, function() f:Hide() end)
	close:SetPoint("RIGHT", f, "TOPRIGHT", -8, -HEADER / 2)

	-- Toolbar: period, count, post buttons.
	local y = -HEADER - PAD
	local periodDW, countDW, gap = 150, 84, 8
	local postW = floor((HIST_W - PAD * 2 - periodDW - countDW - gap * 4) / 3)
	h.periodDrop = Dropdown(f, periodDW, 26, PERIODS,
		function() return db.profile.histPeriod end,
		function(v) db.profile.histPeriod = v; RC:RefreshHistory(); RC:RefreshControls() end)
	h.periodDrop:SetPoint("TOPLEFT", PAD, y)
	h.countDrop = Dropdown(f, countDW, 26, { { 3, "Top 3" }, { 5, "Top 5" }, { 10, "Top 10" } },
		function() return db.profile.topN end,
		function(v) db.profile.topN = v; RC:RefreshHistory(); RC:RefreshControls() end)
	h.countDrop:SetPoint("LEFT", h.periodDrop, "RIGHT", gap, 0)
	h.topBtn = Button(f, "Post Top 5", postW, 26, function() RC:PostLeaderboard("top") end, true,
		"Post the biggest winners for the selected period.")
	h.topBtn:SetPoint("LEFT", h.countDrop, "RIGHT", gap, 0)
	h.bottomBtn = Button(f, "Post Bottom 5", postW, 26, function() RC:PostLeaderboard("bottom") end, false,
		"Post the biggest losers for the selected period.")
	h.bottomBtn:SetPoint("LEFT", h.topBtn, "RIGHT", gap, 0)
	local summary = Button(f, "Post Summary", postW, 26, function() RC:PostSummary() end, false,
		"Post rounds played, gold that changed hands, the biggest round and the luckiest/unluckiest player.")
	summary:SetPoint("LEFT", h.bottomBtn, "RIGHT", gap, 0)

	-- Leaderboard card.
	local lb = Card(f, "Leaderboard")
	lb:SetPoint("TOPLEFT", PAD, y - 26 - PAD)
	lb:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
	lb:SetHeight(LB_H)
	h.lbCount = Text(lb, 11, "muted", false, "RIGHT")
	h.lbCount:SetPoint("TOPRIGHT", -CARD_PAD, -11)
	local headerY = -CARD_TITLE + 2
	local playerHead = Text(lb, 10, "muted", false, "LEFT")
	playerHead:SetPoint("TOPLEFT", CARD_PAD + 30, headerY)
	playerHead:SetText("PLAYER")
	for _, col in ipairs(LB_COLS) do
		local fs = Text(lb, 10, "muted", false, "RIGHT")
		fs:SetPoint("TOPRIGHT", lb, "TOPRIGHT", -CARD_PAD - col.right - 4, headerY)
		fs:SetWidth(col.w)
		fs:SetText(col.title:upper())
	end
	local lbScroll
	lbScroll, h.lbChild = HistoryScroll(lb, headerY - 16)
	h.lbEmpty = Text(lb, 12, "muted", false, "CENTER")
	h.lbEmpty:SetPoint("CENTER", lbScroll, "CENTER")
	h.lbEmpty:SetText("No rounds in this period yet.")

	-- Round log card.
	local log = Card(f, "Rounds")
	log:SetPoint("TOPLEFT", lb, "BOTTOMLEFT", 0, -CARD_GAP)
	log:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, FOOTER + 6)
	h.clearBtn = Button(log, "Clear period", 96, 20, function(btn)
		local n = RC:CountPeriod(db.profile.histPeriod)
		if n == 0 then return end
		Arm(btn, format("Delete %d?", n), "Clear period", function() RC:ClearPeriod(db.profile.histPeriod) end)
	end, false, "Delete every round in the selected period (click twice to confirm).")
	h.clearBtn:SetPoint("TOPRIGHT", -CARD_PAD, -6)
	local newSession = Button(log, "New session", 96, 20, function() RC:NewSession() end, false,
		"Start counting \"This session\" from now. Nothing is deleted.")
	newSession:SetPoint("RIGHT", h.clearBtn, "LEFT", -6, 0)
	h.logCount = Text(log, 11, "muted", false, "RIGHT")
	h.logCount:SetPoint("RIGHT", newSession, "LEFT", -10, 0)
	local logScroll
	logScroll, h.logChild = HistoryScroll(log, -CARD_TITLE)
	h.logEmpty = Text(log, 12, "muted", false, "CENTER")
	h.logEmpty:SetPoint("CENTER", logScroll, "CENTER")
	h.logEmpty:SetText("No rounds in this period yet.")

	-- Footer.
	local hint = Text(f, 10, "muted", false, "LEFT")
	hint:SetPoint("BOTTOMLEFT", PAD + 2, 6)
	hint:SetText("Hover a round for every roll")
	h.stored = Text(f, 10, "muted", false, "RIGHT")
	h.stored:SetPoint("BOTTOMRIGHT", -PAD - 2, 6)

	f:SetScript("OnShow", function()
		RepaintAll()
		RC:RefreshHistory()
	end)
end

function RC:ToggleHistory()
	self:BuildHistory()
	if self.hist.frame:IsShown() then self.hist.frame:Hide() else self.hist.frame:Show() end
end

--==========================================================================
--  CHAT EVENT HANDLERS
--==========================================================================

local function entryAllowed(method)
	return round and round.acceptEntries and db.profile.chatMethod == method
end

local function readable(...)
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if v == nil or issecret(v) then return false end
	end
	return true
end

function RC:Chat_RAID(event, text, sender)
	if entryAllowed("RAID") and readable(text, sender) then self:ParseEntry(text, sender) end
end
function RC:Chat_PARTY(event, text, sender)
	if entryAllowed("PARTY") and readable(text, sender) then self:ParseEntry(text, sender) end
end
function RC:Chat_GUILD(event, text, sender)
	if entryAllowed("GUILD") and readable(text, sender) then self:ParseEntry(text, sender) end
end
function RC:Chat_SAY(event, text, sender)
	if entryAllowed("SAY") and readable(text, sender) then self:ParseEntry(text, sender) end
end
function RC:Chat_CHANNEL(event, ...)
	if not entryAllowed("CHANNEL") then return end
	local text, _, _, _, sender, _, _, _, channel = ...
	if readable(text, sender, channel) and channel == db.profile.customChannel then
		self:ParseEntry(text, sender)
	end
end
function RC:Chat_SYSTEM(event, text)
	if round and round.acceptRolls and readable(text) then self:ParseRoll(text) end
end

--==========================================================================
--  SLASH COMMANDS
--==========================================================================

function RC:SlashCmd(input)
	local cmd, rest = self:GetArgs(input, 2)
	cmd = cmd and strlower(cmd) or ""

	if cmd == "" or cmd == "show" or cmd == "toggle" then
		self:ToggleWindow()
	elseif cmd == "hide" then
		self:HideWindow()
	elseif cmd == "reset" then
		self:ResetRound()
		self:Print("Round reset.")
	elseif cmd == "next" then
		self:NextPhase()
	elseif cmd == "gold" and tonumber(rest) then
		db.profile.stakesGold = math.max(1, floor(tonumber(rest)))
		if round.phase == 0 then round.stakes = self:RollCap() end
		self:RefreshControls()
		self:Print(format("Stakes set to %dg (roll 1-%d).", db.profile.stakesGold, self:RollCap()))
	elseif cmd == "ratio" and tonumber(rest) then
		db.profile.ratio = math.max(1, floor(tonumber(rest)))
		if round.phase == 0 then round.stakes = self:RollCap() end
		self:RefreshControls()
		self:Print(format("Ratio set to %d:1 (roll 1-%d).", db.profile.ratio, self:RollCap()))
	elseif cmd == "channel" and rest and rest ~= "" then
		db.profile.customChannel = rest
		self:Print("Custom channel set to: "..rest)
	elseif cmd == "minimap" then
		db.profile.minimap.hide = not db.profile.minimap.hide
		if LDBIcon then
			if db.profile.minimap.hide then LDBIcon:Hide("HiLoCasino") else LDBIcon:Show("HiLoCasino") end
		end
		self:Print("Minimap button "..(db.profile.minimap.hide and "hidden" or "shown")..".")
	elseif cmd == "history" or cmd == "stats" then
		self:ToggleHistory()
	elseif cmd == "top" or cmd == "bottom" or cmd == "summary" then
		-- /rc top [n] [period]  - n and period in either order, both optional
		local n, period
		for word in (rest or ""):gmatch("%S+") do
			word = strlower(word)
			if tonumber(word) then n = math.max(1, math.min(25, floor(tonumber(word))))
			elseif PERIOD_LABEL[word] then period = word
			elseif word == "day" then period = "today"
			elseif word == "alltime" then period = "all" end
		end
		if cmd == "summary" then self:PostSummary(period) else self:PostLeaderboard(cmd, n, period) end
	elseif cmd == "newsession" then
		self:NewSession()
	elseif cmd == "version" then
		self:Print("Hi-Lo Casino v"..(C_AddOns and C_AddOns.GetAddOnMetadata(ADDON, "Version") or GetAddOnMetadata(ADDON, "Version") or "2.0.0"))
	else
		self:Print("|cffffff00Hi-Lo Casino commands:|r  (/rc works too)")
		self:Print("/hilo  - toggle the window")
		self:Print("/hilo next  - advance the round phase")
		self:Print("/hilo reset  - reset the current round")
		self:Print("/hilo gold <n>  - set stakes in gold")
		self:Print("/hilo ratio <n>  - set roll:gold ratio (e.g. 10 or 100)")
		self:Print("/hilo channel <name>  - set custom chat channel")
		self:Print("/hilo history  - leaderboard and round log")
		self:Print("/hilo top [n] [period]  - post the top n winners (period: session, today, week, month, all)")
		self:Print("/hilo bottom [n] [period]  - post the n biggest losers")
		self:Print("/hilo summary [period]  - post a summary of the period")
		self:Print("/hilo newsession  - start a new \"This session\"")
		self:Print("/hilo minimap  - toggle the minimap button")
		self:Print("/hilo version")
	end
end

--==========================================================================
--  ADDON LIFECYCLE
--==========================================================================

function RC:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("HiLoCasinoDB", defaults, true)
	db = self.db

	-- Old default channel -> new default
	if db.profile.customChannel == "RollGamble" then
		db.profile.customChannel = "hilocasino"
	end

	-- Migrate v2.0 roll-cap setting -> gold amount
	if db.profile.stakes then
		db.profile.stakesGold = math.max(1, floor(db.profile.stakes / (db.profile.ratio or 100)))
		db.profile.stakes = nil
	end

	-- 2.2: the old running totals (roll units, no per-round detail) become one
	-- "imported totals" record that only counts toward All time.
	if not db.global.legacyImported then
		local ratio, deltas, any = db.profile.ratio or 100, {}, false
		for name, total in pairs(db.global.allTime or {}) do
			if type(name) == "string" and type(total) == "number" and total ~= 0 then
				local g = total / ratio
				deltas[name] = g < 0 and -floor(-g + 0.5) or floor(g + 0.5)
				any = true
			end
		end
		if any then tinsert(Rounds(), 1, { legacy = true, t = 0, deltas = deltas }) end
		db.global.legacyImported = true
	end
	if PERIOD_LABEL[db.profile.histPeriod] == nil then db.profile.histPeriod = "session" end

	round = NewRound()
	round.stakes = self:RollCap()

	-- Minimap launcher
	if LDB and LDBIcon then
		local obj = LDB:NewDataObject("HiLoCasino", {
			type = "launcher",
			text = "Hi-Lo Casino",
			icon = "Interface\\AddOns\\HiLoCasino\\media\\icon",
			OnClick = function(_, button)
				if button == "RightButton" then
					RC:PostLeaderboard("top")
				elseif IsShiftKeyDown() then
					RC:ToggleHistory()
				else
					RC:ToggleWindow()
				end
			end,
			OnTooltipShow = function(tt)
				tt:AddLine("Hi-Lo Casino")
				tt:AddLine("|cffffffffLeft-click:|r toggle window")
				tt:AddLine("|cffffffffShift-click:|r history")
				tt:AddLine(format("|cffffffffRight-click:|r post top %d (%s)", db.profile.topN, RC:PeriodName(db.profile.histPeriod)))
			end,
		})
		LDBIcon:Register("HiLoCasino", obj, db.profile.minimap)
	end

	self:RegisterChatCommand("rc", "SlashCmd")
	self:RegisterChatCommand("hilo", "SlashCmd")
	self:RegisterChatCommand("hilocasino", "SlashCmd")
end

function RC:OnEnable()
	self:RegisterEvent("CHAT_MSG_RAID",        "Chat_RAID")
	self:RegisterEvent("CHAT_MSG_RAID_LEADER", "Chat_RAID")
	self:RegisterEvent("CHAT_MSG_PARTY",       "Chat_PARTY")
	self:RegisterEvent("CHAT_MSG_PARTY_LEADER","Chat_PARTY")
	self:RegisterEvent("CHAT_MSG_GUILD",       "Chat_GUILD")
	self:RegisterEvent("CHAT_MSG_SAY",         "Chat_SAY")
	self:RegisterEvent("CHAT_MSG_CHANNEL",     "Chat_CHANNEL")
	self:RegisterEvent("CHAT_MSG_SYSTEM",      "Chat_SYSTEM")

	self:Print("|cffffff00Hi-Lo Casino|r loaded. Type |cff59f0dc/hilo|r to open.")
end

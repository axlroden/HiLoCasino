--[[ Hi-Lo Casino  (named Roll Casino before 2.2.0)
     Host Hi/Lo gold roll games: entries, rolls, payouts, per-round history,
     leaderboards and chat posts. Original author: Pytte.
     The windows follow NaowhForever's live theme and fonts when it is loaded.
--]]

local ADDON = ...
local RC      = LibStub("AceAddon-3.0"):NewAddon("HiLoCasino", "AceConsole-3.0", "AceEvent-3.0")
local LDB     = LibStub("LibDataBroker-1.1", true)
local LDBIcon = LibStub("LibDBIcon-1.0", true)

local format, floor, max, min = string.format, math.floor, math.max, math.min
local tinsert, concat, strlower = table.insert, table.concat, strlower

--==========================================================================
--  CONSTANTS AND STATE
--==========================================================================

-- Roll cap = gold * ratio; e.g. 100 : 1 turns 20g stakes into /roll 1-2000.
local RATIOS = { { 1, "1 : 1" }, { 10, "10 : 1" }, { 100, "100 : 1" }, { 1000, "1000 : 1" } }
local CHATS = { { "SAY", "Say" }, { "PARTY", "Party" }, { "RAID", "Raid" }, { "GUILD", "Guild" }, { "CHANNEL", "Custom Channel" } }
local PERIODS = { { "session", "This session" }, { "today", "Today" }, { "week", "Last 7 days" },
	{ "month", "Last 30 days" }, { "all", "All time" } }
local TOP_COUNTS = { { 3, "Top 3" }, { 5, "Top 5" }, { 10, "Top 10" } }
local SCALES = { { 0.8, "80%" }, { 0.9, "90%" }, { 1, "100%" }, { 1.1, "110%" }, { 1.25, "125%" } }
local PHASE_BUTTON = { [0] = "Start Round", "Announce Last Call", "Begin Rolling", "Waiting for rolls..." }
local PHASE_NAME = { [0] = "Idle", "Entry open", "Last call", "Rolling" }
local MAX_ROUNDS, DAY = 5000, 86400

local function Label(list, value)
	for _, o in ipairs(list) do if o[1] == value then return o[2] end end
	return tostring(value)
end

local defaults = {
	global = {
		allTime = {},      -- pre-2.2 running totals (roll units); imported into rounds once
		rounds  = {},      -- one record per finished round (see RC:ReportResults)
	},
	profile = {
		enterMsg = "1", withdrawMsg = "-1",
		chatMethod = "RAID", customChannel = "hilocasino",
		stakesGold = 20, ratio = 100, rulesName = "Hi/Lo",
		histPeriod = "all", topN = 5,              -- overviews and the quick post buttons (all rounds by default)
		minimap = { hide = false },
		scale = 1, lockWindows = false, clickSound = true, loginMessage = true,
	},
}

local db, round
local personalEntered, personalRolled = false, false
-- Chat lines an event handler may not send (Say outdoors, custom channels);
-- posted by the "Announce Results" click.
local pendingMsgs, deferChat
local missed = { entries = 0, rolls = 0 }   -- chat lines hidden in combat (see CHAT EVENTS)
-- "This session" = since you logged in, or since "New session". Saved, so a /reload
-- keeps it; a fresh login starts a new one (PLAYER_ENTERING_WORLD below).
local sessionStart = time()

-- Chat payloads can be secret on this client (chat messaging lockdown);
-- touching a secret string errors, so such messages are skipped.
local issecret = issecretvalue or function() return false end
local SendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage

-- True while chat reaches us hidden: you're in combat (or chat lockdown). The
-- round waits then - nothing typed or rolled could be read.
local function ChatHidden()
	local lockdown = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
	return InCombatLockdown() or (lockdown and lockdown()) or false
end

local function Version()
	return (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version") or ""
end

local function NewRound(stakes)
	return { phase = 0, stakes = stakes or 0, entrants = {}, entrantsCount = 0, highTyers = {}, lowTyers = {} }
end

--==========================================================================
--  HELPERS
--==========================================================================

local function Contains(list, v)
	for _, x in ipairs(list) do if x == v then return true end end
	return false
end

local function Plural(n, one, many) return n == 1 and one or many end

local function CurrentRatio() return db and db.profile.ratio or 100 end

local function ConvertRollToGold(value)
	return format("%sg", floor((tonumber(value) or 0) / CurrentRatio()))
end

-- 1234 -> "1,234g"; signed adds "+" to gains.
local function Gold(n, signed)
	n = n or 0
	local digits = tostring(floor(math.abs(n) + 0.5)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return (n < 0 and "-" or (signed and n > 0 and "+" or "")) .. digits .. "g"
end

local function Trim(s) return s and (s:gsub("^%s+", ""):gsub("%s+$", "")) or "" end

function RC:RollCap()
	return max(1, floor((db.profile.stakesGold or 1) * CurrentRatio()))
end

-- ok, channel number; warns and returns nil when the custom channel isn't joined.
local function ChannelTarget(self)
	if db.profile.chatMethod ~= "CHANNEL" then return true end
	local n = GetChannelName(db.profile.customChannel)
	if n and n ~= 0 then return true, n end
	self:Print("|cffff5555Custom channel '" .. db.profile.customChannel .. "' not joined.|r")
end

-- Say/Yell outside instances and custom channels can only be sent from a
-- click or keypress, never from an event handler.
function RC:NeedsHardwareEvent()
	local m = db.profile.chatMethod
	return m == "CHANNEL" or ((m == "SAY" or m == "YELL") and not IsInInstance())
end

function RC:ChatMsg(msg)
	local ok, channel = ChannelTarget(self)
	if not ok then return end
	-- SendChatMessage rejects a lone '|' (escape code start); double them.
	msg = tostring(msg):gsub("|", "||")
	if deferChat and self:NeedsHardwareEvent() then
		pendingMsgs = pendingMsgs or {}
		tinsert(pendingMsgs, msg)
	else
		SendChat(msg, db.profile.chatMethod, nil, channel)
	end
end

function RC:FlushPending()
	if not pendingMsgs then return false end
	local ok, channel = ChannelTarget(self)
	if ok then
		local msgs = pendingMsgs
		pendingMsgs = nil
		for _, m in ipairs(msgs) do SendChat(m, db.profile.chatMethod, nil, channel) end
		self:RefreshControls()
	end
	return true
end

--==========================================================================
--  SETTINGS  (one entry point for the window, the options panel and /hilo)
--==========================================================================

local function Number(min_)
	return function(v)
		v = tonumber(v)
		if v and v >= min_ then return floor(v) end
	end
end
local function Text_(v) v = Trim(v); if v ~= "" then return v end end

local VALIDATE = {
	stakesGold = Number(1), ratio = Number(1),
	customChannel = Text_, enterMsg = Text_, withdrawMsg = Text_,
}

function RC:Set(key, value)
	if VALIDATE[key] then value = VALIDATE[key](value) end
	if value == nil then return false end
	db.profile[key] = value
	self:ApplySettings()
	return true
end

function RC:SetMinimapShown(shown)
	db.profile.minimap.hide = not shown
	self:ApplySettings()
end

local RepaintAll   -- defined with the UI kit

function RC:ApplySettings()
	if round and round.phase == 0 then round.stakes = self:RollCap() end
	if LDBIcon then
		if db.profile.minimap.hide then LDBIcon:Hide("HiLoCasino") else LDBIcon:Show("HiLoCasino") end
	end
	if RepaintAll then RepaintAll() end   -- scale, theme, fonts
	self:RebuildGameGroup()
	self:RefreshHistory()
	if self.options then self.options:Refresh() end
end

--==========================================================================
--  ENTRANTS AND ROLLS
--==========================================================================

function RC:GetHighRoll()
	return round.highRoller and round.entrants[round.highRoller].roll or 0
end

function RC:GetLowRoll()
	return round.lowRoller and round.entrants[round.lowRoller].roll or round.stakes
end

function RC:GetRemainingToRollCount()
	local count = 0
	for _, v in pairs(round.entrants) do
		if v.entered and not v.rolled then count = count + 1 end
	end
	return count
end

-- WoW Forever names contain a space ("Pytte Soulreaper"), chat senders may
-- carry it as a hyphen, and cross-realm names add "-Realm". Entrants are keyed
-- by a normalized form (hyphens as spaces, single-spaced, lower case).
local function DisplayName(name)
	return (name:gsub("%-", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function NameKey(name) return DisplayName(name):lower() end

-- Exact match first, then one that differs only by a trailing realm.
local function FindEntrantKey(name)
	local key = NameKey(name)
	if round.entrants[key] then return key end
	for k in pairs(round.entrants) do
		if k:sub(1, #key + 1) == key .. " " or key:sub(1, #k + 1) == k .. " " then return k end
	end
end

function RC:ParseEntry(msg, name)
	local enter = msg == db.profile.enterMsg
	if not (enter or msg == db.profile.withdrawMsg) or not name or name == "" then return end
	local key = NameKey(name)
	local e = round.entrants[key]
	if e then
		e.entered = enter
	elseif enter then
		round.entrants[key] = { key = key, name = DisplayName(name), roll = -1, entered = true }
		round.entrantsCount = round.entrantsCount + 1
	else
		return
	end
	self:UpdateActionList()
	self:RefreshControls()
end

-- Pattern for the system roll line, built from the client's own
-- RANDOM_ROLL_RESULT ("%s rolls %d (%d-%d)"); captures name, roll, min, max.
local ROLL_PATTERN = "^(.+) rolls (%d+) %((%d+)%-(%d+)%)$"
if type(RANDOM_ROLL_RESULT) == "string" and RANDOM_ROLL_RESULT:find("%%s") then
	ROLL_PATTERN = "^" .. RANDOM_ROLL_RESULT:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
		:gsub("%%%d*%$?s", "(.+)"):gsub("%%%d*%$?d", "(%%d+)") .. "$"
end

function RC:ParseRoll(msg)
	local name, roll, lo, hi = msg:match(ROLL_PATTERN)
	if not name then return end
	local key = FindEntrantKey(name)
	local p = key and round.entrants[key]
	roll, lo, hi = tonumber(roll), tonumber(lo), tonumber(hi)
	if not p or not p.entered or p.rolled or lo ~= 1 or hi ~= round.stakes or not roll or roll > hi then return end
	self:AddRoll(key, roll, DisplayName(name))   -- the name as the game prints it
end

-- A roll you type in yourself (one the addon couldn't read, e.g. in combat).
-- Returns an error text when it can't be taken.
function RC:EnterRoll(name, roll)
	roll = tonumber(roll)
	if not round.acceptRolls then return "nobody is rolling right now" end
	local key = name and FindEntrantKey(name)
	local p = key and round.entrants[key]
	if not p or not p.entered then return format("%s isn't in this round", name or "?") end
	if p.rolled then return format("%s already rolled %d", p.name, p.roll) end
	if not roll or roll ~= floor(roll) or roll < 1 or roll > round.stakes then
		return format("the roll must be 1-%d", round.stakes)
	end
	self:Print(format("Entered %d for %s.", roll, p.name))
	self:AddRoll(key, roll, nil, true)
end

function RC:AddRoll(key, roll, name, byHand)
	local p = round.entrants[key]
	p.rolled, p.roll, p.name, p.byHand = true, roll, name or p.name, byHand
	local high, low = self:GetHighRoll(), self:GetLowRoll()
	if not round.highRoller or roll > high then
		round.highRoller, round.highTyers = key, { key }
	elseif roll == high then
		tinsert(round.highTyers, key)
	end
	if not round.lowRoller or roll < low then
		round.lowRoller, round.lowTyers = key, { key }
	elseif roll == low then
		tinsert(round.lowTyers, key)
	end

	if self:GetRemainingToRollCount() == 0 then self:RoundWrapup(byHand) end
	self:UpdateActionList()
	self:RefreshControls()
end

--==========================================================================
--  HISTORY  (every finished round is stored; overviews and chat posts are
--  computed from those records, in gold, for any period)
--==========================================================================

local PERIOD_LABEL = {}
for _, p in ipairs(PERIODS) do PERIOD_LABEL[p[1]] = p[2] end

local function Rounds()
	db.global.rounds = db.global.rounds or {}
	return db.global.rounds
end

local function InPeriod(rec, period)
	if period == "all" then return true end
	if rec.legacy then return false end          -- imported pre-2.2 totals: all time only
	local t = rec.t or 0
	if period == "session" then return t >= sessionStart end
	if period == "today" then return date("%Y%m%d", t) == date("%Y%m%d") end
	if period == "week" then return t >= time() - 7 * DAY end
	if period == "month" then return t >= time() - 30 * DAY end
	return true
end

function RC:PeriodName(period) return PERIOD_LABEL[period] or PERIOD_LABEL.session end

local function NoRounds(self, period)
	self:Print("No rounds recorded for " .. self:PeriodName(period) .. ".")
end

function RC:RecordRound(rec)
	local rounds = Rounds()
	tinsert(rounds, rec)
	while #rounds > MAX_ROUNDS do table.remove(rounds, rounds[1].legacy and 2 or 1) end   -- keep imported totals
	self:RefreshHistory()
end

-- What each player won (+) or lost (-) in a round. Every loser pays every winner
-- the announced amount: "A, B owes C 5g each" = C gets 10g, "A owes B, C 5g each"
-- = A pays 10g. Worked out from losers / winners so rounds saved earlier (which
-- counted tied rounds only once) come out right too.
local function RoundDeltas(rec)
	if rec.legacy or not rec.each or not rec.losers or not rec.winners then return rec.deltas or {} end
	local d = {}
	for _, n in ipairs(rec.losers) do d[n] = (d[n] or 0) - rec.each * #rec.winners end
	for _, n in ipairs(rec.winners) do d[n] = (d[n] or 0) + rec.each * #rec.losers end
	return d
end

-- Per-player overview for a period (best net first) plus period totals.
function RC:Aggregate(period)
	local players, order = {}, {}
	local totals = { rounds = 0, ties = 0, moved = 0 }
	local function P(name)
		local key = NameKey(name)
		if not players[key] then
			players[key] = { name = name, net = 0, rounds = 0, wins = 0, losses = 0, best = 0, worst = 0 }
			order[#order + 1] = players[key]
		end
		return players[key]
	end
	for _, rec in ipairs(Rounds()) do
		if InPeriod(rec, period) then
			if not rec.legacy then
				totals.rounds = totals.rounds + 1
				if rec.tie then totals.ties = totals.ties + 1 end
				for _, pl in ipairs(rec.players or {}) do local p = P(pl.n); p.rounds = p.rounds + 1 end
				if rec.each and rec.each > 0 and (not totals.biggest or rec.each > totals.biggest.each) then
					totals.biggest = rec
				end
			end
			for name, d in pairs(RoundDeltas(rec)) do
				local p = P(name)
				p.net = p.net + d
				if not rec.legacy and d > 0 then
					p.wins, p.best, totals.moved = p.wins + 1, max(p.best, d), totals.moved + d
				elseif not rec.legacy and d < 0 then
					p.losses, p.worst = p.losses + 1, min(p.worst, d)
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

local function Each(rec) return #(rec.losers or {}) + #(rec.winners or {}) > 2 end

local function RoundResult(rec)
	if rec.tie then return "Tie - no payout" end
	return format("%s owes %s %s%s", concat(rec.losers or {}, ", "), concat(rec.winners or {}, ", "),
		Gold(rec.each), Each(rec) and " each" or "")
end

-- which = "top" (biggest winners) or "bottom" (biggest losers). Only players who
-- are up go on the top list and only players who are down on the bottom one.
function RC:PostLeaderboard(which, n, period)
	period, n = period or db.profile.histPeriod, n or db.profile.topN
	local order = self:Aggregate(period)
	if #order == 0 then return NoRounds(self, period) end
	local bottom, list = which == "bottom", {}
	for i = 1, #order do
		local p = order[bottom and #order - i + 1 or i]
		if (bottom and p.net < 0) or (not bottom and p.net > 0) then list[#list + 1] = p end
	end
	if #list == 0 then
		return self:Print(format("Nobody is %s for %s.", bottom and "down" or "up", self:PeriodName(period)))
	end
	local count = min(n, #list)
	self:ChatMsg(format(".:HiLo %s %d - %s:.", bottom and "Bottom" or "Top", count, self:PeriodName(period)))
	for i = 1, count do
		local p = list[i]
		local detail = p.rounds == 0 and "imported"
			or format("%d %s, %dW/%dL", p.rounds, Plural(p.rounds, "round", "rounds"), p.wins, p.losses)
		self:ChatMsg(format("%d. %s  %s  (%s)", i, p.name, Gold(p.net, true), detail))
	end
end

function RC:PostSummary(period)
	period = period or db.profile.histPeriod
	local order, t = self:Aggregate(period)
	if t.rounds == 0 and #order == 0 then return NoRounds(self, period) end
	self:ChatMsg(format(".:HiLo Stats - %s:. %d %s (%d %s), %s changed hands", self:PeriodName(period),
		t.rounds, Plural(t.rounds, "round", "rounds"), t.ties, Plural(t.ties, "tie", "ties"), Gold(t.moved)))
	if t.biggest then
		self:ChatMsg(format(".:HiLo:. Biggest round: %s (%s)", RoundResult(t.biggest), date("%d %b %H:%M", t.biggest.t)))
	end
	local top, bottom = order[1], order[#order]
	if top and top.net > 0 and bottom.net < 0 then
		self:ChatMsg(format(".:HiLo:. Luckiest: %s %s  -  Unluckiest: %s %s",
			top.name, Gold(top.net, true), bottom.name, Gold(bottom.net, true)))
	end
end

function RC:PostRound(rec)
	if not rec or rec.legacy then return end
	local rolls = {}
	for _, pl in ipairs(rec.players or {}) do rolls[#rolls + 1] = pl.n .. " " .. pl.r end
	self:ChatMsg(format(".:HiLo Round %s:. %s", date("%H:%M", rec.t), RoundResult(rec)))
	if #rolls > 0 then self:ChatMsg(".:HiLo:. Rolls: " .. concat(rolls, ", ")) end
end

-- Removes the given record, or every record in a period; returns how many.
local function RemoveRounds(match)
	local rounds, removed = Rounds(), 0
	for i = #rounds, 1, -1 do
		if match(rounds[i]) then table.remove(rounds, i); removed = removed + 1 end
	end
	return removed
end

function RC:DeleteRound(rec)
	RemoveRounds(function(r) return r == rec end)
	self:RefreshHistory()
end

function RC:CountPeriod(period)
	local n = 0
	for _, rec in ipairs(Rounds()) do if InPeriod(rec, period) then n = n + 1 end end
	return n
end

function RC:ClearPeriod(period)
	local removed = RemoveRounds(function(r) return InPeriod(r, period) end)
	self:Print(format("Deleted %d %s (%s).", removed, Plural(removed, "round", "rounds"), self:PeriodName(period)))
	self:RefreshHistory()
end

function RC:NewSession()
	sessionStart = time()
	db.global.sessionStart = sessionStart
	self:Print("New session started - \"This session\" counts from now. History is kept.")
	self:RefreshHistory()
	self:RefreshControls()
end

--==========================================================================
--  ROUND FLOW
--==========================================================================

function RC:PrintRules()
	self:ChatMsg(format(".:HiLo:. %s RULES:.", db.profile.rulesName))
	self:ChatMsg(".:Players will /roll the STAKES:.")
	self:ChatMsg(".:High roll wins. Low Roll loses. Loser pays out the roll difference:.")
end

function RC:ReportResults()
	local high, low = self:GetHighRoll(), self:GetLowRoll()
	local split = max(1, #round.lowTyers + #round.highTyers - 1)
	local owed = (high - low) / split
	local rec = { t = time(), cap = round.stakes, ratio = CurrentRatio(), players = {}, deltas = {} }
	for _, v in pairs(round.entrants) do
		if v.entered and v.rolled then tinsert(rec.players, { n = v.name, r = v.roll }) end
	end
	table.sort(rec.players, function(a, b) return a.r > b.r end)

	if owed ~= 0 and high > 0 and low > 0 then
		local each = floor(owed / CurrentRatio())   -- the figure ConvertRollToGold announces
		rec.each, rec.losers, rec.winners = each, {}, {}
		for _, k in ipairs(round.lowTyers) do tinsert(rec.losers, round.entrants[k].name) end
		for _, k in ipairs(round.highTyers) do tinsert(rec.winners, round.entrants[k].name) end
		rec.deltas = RoundDeltas(rec)
		self:ChatMsg(format(".:HiLo Payouts:. %s owes %s < %s >%s", concat(rec.losers, ", "),
			concat(rec.winners, ", "), ConvertRollToGold(owed), split > 1 and " each." or ""))
	else
		rec.tie = true
		self:ChatMsg(".:HiLo:. TIE! No payouts on this roll!")
	end
	self:RecordRound(rec)
end

function RC:ResetRound()
	round = NewRound(self:RollCap())
	missed.entries, missed.rolls = 0, 0
	personalEntered, personalRolled = false, false
	self:UpdateActionList()
	self:RefreshControls()
end

function RC:RoundWrapup(byHand)
	-- Runs from the CHAT_MSG_SYSTEM roll event, so Say/channel lines are queued
	-- (not for a roll you typed in: that is a keypress, which may post).
	deferChat = not byHand
	local ok, err = pcall(self.ReportResults, self)
	deferChat = nil
	self:ResetRound()
	if not ok then geterrorhandler()(err) end
	self:Print(pendingMsgs
		and "|cffffff00Round complete.|r Click |cff59f0dcAnnounce Results|r (or type /hilo next) to post the payouts."
		or "|cffffff00Round complete and reset.|r")
end

function RC:NextPhase()
	if self:FlushPending() then return end
	local p = round.phase
	if p < 3 and ChatHidden() then
		return self:Print("You're in combat - the round waits until it's over (chat can't be read in combat).")
	end
	if p == 0 then
		round = NewRound(self:RollCap())
		round.acceptEntries = true
		personalEntered, personalRolled = false, false
		self:ChatMsg(format(".:Hi-Lo Casino:. RULES: %s .:. STAKES << %s >>", db.profile.rulesName, ConvertRollToGold(round.stakes)))
		self:ChatMsg(format(".:HiLo:. To enter: type %s", db.profile.enterMsg))
	elseif p == 1 then
		self:ChatMsg(format(".:HiLo:. Last Call to join! To withdraw, type %s", db.profile.withdrawMsg))
	elseif p == 2 then
		if round.entrantsCount < 2 then return self:ChatMsg("Not enough Players!") end
		round.acceptEntries, round.acceptRolls = false, true
		self:ChatMsg(format(".:HiLo - /roll %s NOW:.", round.stakes))
	else
		return   -- rolling: the round ends with the last roll
	end
	round.phase = p + 1
	self:UpdateActionList()
	self:RefreshControls()
end

function RC:ListRemaining()
	local names = {}
	for _, v in pairs(round.entrants) do
		if v.entered and not v.rolled then names[#names + 1] = v.name end
	end
	if #names == 0 then return self:ChatMsg("Everyone has rolled.") end
	table.sort(names)
	local function nameOf(key) return key and round.entrants[key].name or "nil" end
	self:ChatMsg(format("Remaining Rollers: %s  .:.  High: %s (%s)  Low: %s (%s)", concat(names, ", "),
		nameOf(round.highRoller), self:GetHighRoll(), nameOf(round.lowRoller), self:GetLowRoll()))
end

function RC:DoPersonalEnter()
	self:ChatMsg(db.profile.enterMsg)
	personalEntered = true
	self:RefreshControls()
end

function RC:DoPersonalRoll()
	RandomRoll(1, round.stakes)
	personalRolled = true
	self:RefreshControls()
end

--==========================================================================
--  UI KIT  (NaowhForever house look; follows its live theme and fonts when
--  it is loaded, otherwise its "Midnight" palette)
--==========================================================================

local FALLBACK_THEME = {
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
local FALLBACK_MEDIA = { chevron = "Interface\\Buttons\\Arrow-Down-Up", cog = "Interface\\Buttons\\UI-OptionsButton" }

local HEADER, PAD, FOOTER = 52, 12, 20
local CARD_PAD, CARD_GAP, CARD_TITLE = 10, 8, 30
local DISABLED_ALPHA, BACKDROP_ALPHA, CARD_FILL, CARD_EDGE = 0.4, 0.97, 0.035, 0.7
local ICON = "Interface\\AddOns\\HiLoCasino\\media\\icon"

local function Naowh()
	local N = _G.NaowhForever
	if type(N) == "table" and type(N.THEME) == "table" then return N end
end

local function Theme()
	local T = Naowh() and _G.NaowhForever.THEME
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
	return PixelUtil.GetPixelToUIUnitFactor() / max(region:GetEffectiveScale(), 0.01)
end

local function Hex(c)
	return format("|cff%02x%02x%02x", floor(c.r * 255 + 0.5), floor(c.g * 255 + 0.5), floor(c.b * 255 + 0.5))
end

local function SetRGB(fs, c) fs:SetTextColor(c.r, c.g, c.b, 1) end

-- Widgets register a painter; windows re-run them all on show, so a theme,
-- font or scale change is picked up.
local painters = {}
local function Paint(fn)
	painters[#painters + 1] = fn
	fn(Theme())
end
function RepaintAll()
	local T = Theme()
	for i = 1, #painters do painters[i](T) end
end

local function Border(frame, layer)
	local e = {}
	for i = 1, 4 do e[i] = frame:CreateTexture(nil, layer or "BORDER", nil, 7) end
	e[1]:SetPoint("TOPLEFT"); e[1]:SetPoint("TOPRIGHT")
	e[2]:SetPoint("BOTTOMLEFT"); e[2]:SetPoint("BOTTOMRIGHT")
	e[3]:SetPoint("TOPLEFT"); e[3]:SetPoint("BOTTOMLEFT")
	e[4]:SetPoint("TOPRIGHT"); e[4]:SetPoint("BOTTOMRIGHT")
	local border = {}
	function border.SetColor(_, r, g, b, a) for i = 1, 4 do e[i]:SetColorTexture(r, g, b, a or 1) end end
	function border.Fit()
		local p = Px(frame)
		e[1]:SetHeight(p); e[2]:SetHeight(p); e[3]:SetWidth(p); e[4]:SetWidth(p)
	end
	border.Fit()
	return border
end

-- colorKey: a theme key repainted with the theme, or nil for caller-set color.
local function Text(parent, size, colorKey, heading, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	if heading then fs:SetShadowColor(0, 0, 0, 1); fs:SetShadowOffset(1, -1) end
	if justify then fs:SetJustifyH(justify) end
	Paint(function(T)
		fs:SetFont(FontPath(heading), size, "")
		if colorKey then SetRGB(fs, T[colorKey] or T.fg) end
	end)
	return fs
end

local function Click()
	if db.profile.clickSound and SOUNDKIT and SOUNDKIT.U_CHAT_SCROLL_BUTTON then PlaySound(SOUNDKIT.U_CHAT_SCROLL_BUTTON) end
end

local function Icon(parent, name, size)
	local tex, N = parent:CreateTexture(nil, "OVERLAY"), Naowh()
	tex:SetSize(size, size)
	if N and N.MEDIA then tex:SetTexture(N.MEDIA .. name, nil, nil, "TRILINEAR") else tex:SetTexture(FALLBACK_MEDIA[name]) end
	Paint(function(T) tex:SetVertexColor(T.muted.r, T.muted.g, T.muted.b, 1) end)
	return tex, N and N.MEDIA
end

local function ButtonRest(btn)
	local T = Theme()
	local fill = btn.primary and T.accent or T.panel
	btn.bg:SetColorTexture(fill.r, fill.g, fill.b, btn.primary and 1 or 0.9)
	local edge = btn.primary and T.accent or T.line
	btn.border:SetColor(edge.r, edge.g, edge.b, 1)
	SetRGB(btn.label, btn.primary and T.bg or T.fg)
end

local function ButtonHover(btn)
	if btn.disabled then return end
	local T = Theme()
	local fill = btn.primary and (T.accentSoft or T.accent) or T.panel
	btn.bg:SetColorTexture(fill.r, fill.g, fill.b, 1)
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
	btn.SetText = function(self, t) self.label:SetText(t) end
	btn.SetDisabled = function(self, disabled)
		self.disabled = disabled and true or false
		self:SetAlpha(self.disabled and DISABLED_ALPHA or 1)
		if self.disabled then ButtonRest(self) end
	end
	Paint(function() ButtonRest(btn); btn.border.Fit() end)
	return btn
end

-- Buttons side by side across width w; specs = { { text, onClick, primary, tip }, ... }.
local function ButtonRow(parent, x, y, w, h, specs)
	local n, out = #specs, {}
	local bw = floor((w - 8 * (n - 1)) / n)
	for i, s in ipairs(specs) do
		out[i] = Button(parent, s[1], i == n and w - (bw + 8) * (n - 1) or bw, h, s[2], s[3], s[4])
		if i == 1 then out[i]:SetPoint("TOPLEFT", x, y) else out[i]:SetPoint("LEFT", out[i - 1], "RIGHT", 8, 0) end
	end
	return unpack(out)
end

-- An edit box that commits on Enter or focus loss; get() feeds :Refresh().
local function Field(parent, w, h, onCommit, get)
	local box = CreateFrame("EditBox", nil, parent)
	box:SetSize(w, h)
	box:SetAutoFocus(false)
	box:SetTextInsets(8, 8, 0, 0)
	box.bg = box:CreateTexture(nil, "BACKGROUND")
	box.bg:SetAllPoints()
	box.border = Border(box)
	local function Rest(self)
		local c = self:HasFocus() and Theme().accent or Theme().line
		self.border:SetColor(c.r, c.g, c.b, 1)
	end
	box:SetScript("OnEscapePressed", box.ClearFocus)
	box:SetScript("OnEnterPressed", box.ClearFocus)
	box:SetScript("OnEditFocusGained", Rest)
	box:SetScript("OnEditFocusLost", function(self)
		if not self.committing then
			self.committing = true
			onCommit(self, self:GetText())
			self.committing = nil
		end
		Rest(self)
	end)
	box.SetDisabled = function(self, disabled)
		self:SetEnabled(not disabled)
		self:SetAlpha(disabled and DISABLED_ALPHA or 1)
		if disabled then self:ClearFocus() end
	end
	box.Refresh = function(self) if get and not self:HasFocus() then self:SetText(tostring(get())) end end
	Paint(function(T)
		box:SetFont(FontPath(false), 12, "")
		SetRGB(box, T.fg)
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
	local arrow, naowh = Icon(dd, "chevron", 12)
	arrow:SetPoint("RIGHT", -8, 0)
	if naowh then arrow:SetRotation(-math.pi / 2) end
	function dd:Refresh() self.label:SetText(Label(options, getValue())) end
	dd:SetScript("OnClick", function(self)
		if self.disabled then return end
		Click()
		MenuUtil.CreateContextMenu(self, function(_, root)
			for _, o in ipairs(options) do
				root:CreateRadio(o[2], function() return getValue() == o[1] end, function() setValue(o[1]); dd:Refresh() end)
			end
		end)
	end)
	dd:Refresh()
	return dd
end

-- A themed checkbox with a label.
local function Toggle(parent, text, get, set)
	local btn = CreateFrame("Button", nil, parent)
	btn:SetSize(250, 22)
	local box = CreateFrame("Frame", nil, btn)
	box:SetSize(16, 16)
	box:SetPoint("LEFT")
	local bg, border = box:CreateTexture(nil, "BACKGROUND"), Border(box)
	bg:SetAllPoints()
	local check = box:CreateTexture(nil, "ARTWORK")
	check:SetPoint("TOPLEFT", 4, -4)
	check:SetPoint("BOTTOMRIGHT", -4, 4)
	local label = Text(btn, 12, "fg", false, "LEFT")
	label:SetPoint("LEFT", box, "RIGHT", 8, 0)
	label:SetText(text)
	function btn:Refresh()
		local T, on = Theme(), get() and true or false
		bg:SetColorTexture(T.bg.r, T.bg.g, T.bg.b, 0.9)
		local edge = on and T.accent or T.line
		border:SetColor(edge.r, edge.g, edge.b, 1)
		border.Fit()
		check:SetColorTexture(T.accent.r, T.accent.g, T.accent.b, 1)
		check:SetShown(on)
	end
	btn:SetScript("OnClick", function(self) Click(); set(not get()); self:Refresh() end)
	Paint(function() btn:Refresh() end)
	return btn
end

-- below: a card to sit under, or a y offset from the top. Every card gets a
-- right-aligned muted note in its title row.
local function Card(parent, title, below, height)
	local card = CreateFrame("Frame", nil, parent)
	if type(below) == "table" then
		card:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, -CARD_GAP)
		card:SetPoint("RIGHT", parent, "RIGHT", -PAD, 0)
	elseif below then
		card:SetPoint("TOPLEFT", PAD, below)
		card:SetPoint("RIGHT", parent, "RIGHT", -PAD, 0)
	end
	if height then card:SetHeight(height) end
	local fill, border = card:CreateTexture(nil, "BACKGROUND"), Border(card)
	fill:SetAllPoints()
	local head = Text(card, 12, "accent", true, "LEFT")
	head:SetPoint("TOPLEFT", CARD_PAD, -10)
	head:SetText(title)
	card.note = Text(card, 11, "muted", false, "RIGHT")
	card.note:SetPoint("TOPRIGHT", -CARD_PAD, -11)
	Paint(function(T)
		fill:SetColorTexture(T.fg.r, T.fg.g, T.fg.b, CARD_FILL)
		border:SetColor(0, 0, 0, CARD_EDGE)
		border.Fit()
	end)
	return card
end

local function FieldLabel(parent, text, x, y, size, color)
	local fs = Text(parent, size or 11, color or "muted", false, "LEFT")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
	return fs
end

-- A mouse-wheel scroll area inside a card; returns the scroll child and an
-- empty-state text.
local function ScrollList(card, top, width, step)
	local scroll = CreateFrame("ScrollFrame", nil, card)
	scroll:SetPoint("TOPLEFT", CARD_PAD, top)
	scroll:SetPoint("BOTTOMRIGHT", -CARD_PAD, CARD_PAD)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(width, 1)
	scroll:SetScrollChild(child)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		self:SetVerticalScroll(min(max(0, child:GetHeight() - self:GetHeight()), max(0, self:GetVerticalScroll() - delta * step)))
	end)
	local empty = Text(card, 12, "muted", false, "CENTER")
	empty:SetPoint("CENTER", scroll, "CENTER")
	return child, empty
end

-- Pooled, striped list rows; build(row) adds the row's own parts once.
local function PoolRow(pool, child, i, h, build)
	local row = pool[i]
	if not row then
		row = CreateFrame("Frame", nil, child)
		row:SetHeight(h)
		row:SetPoint("TOPLEFT", 0, -(i - 1) * h)
		row:SetPoint("RIGHT", child, "RIGHT")
		row.stripe = row:CreateTexture(nil, "BACKGROUND")
		row.stripe:SetAllPoints()
		build(row)
		pool[i] = row
	end
	local fg = Theme().fg
	row.stripe:SetColorTexture(fg.r, fg.g, fg.b, i % 2 == 0 and 0.025 or 0)
	row:Show()
	return row
end

local function HidePool(pool, from)
	for i = from, #pool do pool[i]:Hide() end
end

local function RankText(row)
	row.rank = Text(row, 11, "muted", false, "RIGHT")
	row.rank:SetPoint("LEFT")
	row.rank:SetWidth(22)
end

-- A movable, Esc-closable window: backdrop, header with logo, title,
-- subtitle, settings and close buttons, and two footer texts.
local function Window(name, w, h, posKey, word1, word2, place)
	local f = CreateFrame("Frame", name, UIParent)
	f:Hide()
	f:SetSize(w, h)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) if not db.profile.lockWindows then self:StartMoving() end end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		db.profile[posKey] = { point, relPoint, x, y }
	end)
	function f:Place()
		self:ClearAllPoints()
		local pos = db.profile[posKey]
		if type(pos) == "table" and pos[1] then self:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else place(self) end
	end
	f:Place()
	tinsert(UISpecialFrames, name)

	local bg, tint, rule = f:CreateTexture(nil, "BACKGROUND", nil, -8), f:CreateTexture(nil, "BACKGROUND", nil, -7), f:CreateTexture(nil, "ARTWORK")
	bg:SetAllPoints()
	tint:SetPoint("TOPLEFT")
	tint:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", 0, -HEADER)
	rule:SetPoint("TOPLEFT", 0, -HEADER)
	rule:SetPoint("TOPRIGHT", 0, -HEADER)
	local outer = Border(f, "OVERLAY")
	local title = Text(f, 20, "fg", true, "LEFT")
	Paint(function(T)
		f:SetScale(db.profile.scale or 1)
		bg:SetColorTexture(T.bg.r, T.bg.g, T.bg.b, BACKDROP_ALPHA)
		tint:SetColorTexture(T.panel.r, T.panel.g, T.panel.b, 0.6)
		outer:SetColor(0, 0, 0, 1)
		outer.Fit()
		rule:SetColorTexture(0, 0, 0, 1)
		rule:SetHeight(Px(f))
		title:SetText(word1 .. " " .. Hex(T.accent) .. word2 .. "|r")
	end)

	local logo = f:CreateTexture(nil, "ARTWORK")
	logo:SetSize(32, 32)
	logo:SetPoint("LEFT", f, "TOPLEFT", PAD, -HEADER / 2)
	logo:SetTexture(ICON)
	title:SetPoint("TOPLEFT", logo, "TOPRIGHT", 10, 1)
	local close = Button(f, "x", 24, 24, function() f:Hide() end)
	close:SetPoint("RIGHT", f, "TOPRIGHT", -8, -HEADER / 2)
	local cog = Button(f, "", 24, 24, function() RC:OpenOptions() end, false, "Settings")
	cog:SetPoint("RIGHT", close, "LEFT", -6, 0)
	Icon(cog, "cog", 14):SetPoint("CENTER")
	f.subtitle = Text(f, 11, "muted", false, "LEFT")
	f.subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
	f.subtitle:SetPoint("RIGHT", cog, "LEFT", -10, 0)
	f.subtitle:SetWordWrap(false)
	f.footLeft = Text(f, 10, "muted", false, "LEFT")
	f.footLeft:SetPoint("BOTTOMLEFT", PAD + 2, 6)
	f.footRight = Text(f, 10, "muted", false, "RIGHT")
	f.footRight:SetPoint("BOTTOMRIGHT", -PAD - 2, 6)
	return f
end

local function Get(key) return function() return db.profile[key] end end
local function Put(key) return function(v) RC:Set(key, v) end end

--==========================================================================
--  MAIN WINDOW
--==========================================================================

local WIN_W, WIN_H, ROW_H = 520, 660, 22
local INNER = WIN_W - PAD * 2 - CARD_PAD * 2      -- usable width inside a card

function RC:RefreshControls()
	local ui = self.ui
	if not ui or not ui.frame:IsShown() then return end
	local p, T, cap = round.phase, Theme(), round.stakes

	ui.phaseBtn:SetText(pendingMsgs and "Announce Results" or PHASE_BUTTON[p] or PHASE_BUTTON[0])
	local paused = ChatHidden()
	ui.phaseBtn:SetDisabled(not pendingMsgs and (p >= 3 or paused))
	ui.listBtn:SetDisabled(not (p >= 3 and self:GetRemainingToRollCount() > 0))
	ui.resetBtn:SetDisabled(p == 0)
	ui.enterBtn:SetDisabled(paused or personalEntered or not round.acceptEntries)
	ui.rollBtn:SetDisabled(paused or personalRolled or not round.acceptRolls)
	ui.stakesEdit:SetDisabled(p ~= 0)
	ui.ratioDrop:SetDisabled(p ~= 0)
	if p == 0 then ui.stakesEdit:Refresh() end
	ui.ratioDrop:Refresh()
	ui.channelDrop:Refresh()

	ui.rollFor:SetText(format("Rolling for %s%s|r   %s·|r   players %s/roll 1-%d|r",
		Hex(T.accent), ConvertRollToGold(cap), Hex(T.muted), Hex(T.fg), cap))
	ui.ratioNote:SetText(Label(RATIOS, CurrentRatio()))
	ui.subtitle:SetText(format("%s%s   ·   %d entrants   ·   %d yet to roll",
		PHASE_NAME[p] or PHASE_NAME[0], (paused and p > 0) and " (paused: combat)" or "",
		round.entrantsCount, self:GetRemainingToRollCount()))
	ui.potNote:SetText(format("Pot %s  ·  1-%d", ConvertRollToGold(cap), cap))
	local n = db.profile.topN
	ui.topBtn:SetText("Session Top " .. n)
	ui.bottomBtn:SetText("Session Bottom " .. n)
	ui.allTopBtn:SetText("All-time Top " .. n)
	ui.allBottomBtn:SetText("All-time Bottom " .. n)
	ui.statsPeriod:SetText("")
end

local function BuildActionRow(row)
	RankText(row)
	row.name = Text(row, 12, nil, false, "LEFT")
	row.name:SetPoint("LEFT", row.rank, "RIGHT", 10, 0)
	row.roll = Text(row, 12, nil, true, "RIGHT")
	row.roll:SetPoint("RIGHT", -10, 0)
	row.mark = row:CreateTexture(nil, "ARTWORK")
	row.mark:SetSize(2, ROW_H - 8)
	row.mark:SetPoint("LEFT", row.rank, "RIGHT", 4, 0)
	-- Click a player still to roll to type in the roll chat shows (Enter = take it, Esc = cancel).
	row.edit = Field(row, 70, ROW_H - 4, function(box, text)
		box:Hide()
		text = Trim(text)
		box:SetText("")
		if text == "" or not row.entrant then return end
		local err = RC:EnterRoll(row.entrant.name, text)
		if err then RC:Print("|cffff5555Roll not entered:|r " .. err .. ".") end
	end)
	row.edit:SetPoint("RIGHT", -4, 0)
	row.edit:SetNumeric(true)
	row.edit:SetScript("OnEscapePressed", function(box) box:SetText(""); box:ClearFocus() end)
	row.edit:Hide()
	local function CanType(v) return v and round.acceptRolls and v.entered and not v.rolled end
	row:EnableMouse(true)
	row:SetScript("OnMouseUp", function(self)
		if not CanType(self.entrant) then return end
		self.edit:SetText("")
		self.edit:Show()
		self.edit:SetFocus()
	end)
	row:SetScript("OnEnter", function(self)
		if not CanType(self.entrant) then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(self.entrant.name, 1, 1, 1)
		GameTooltip:AddLine("Click to type in their roll, if the addon missed it (e.g. in combat).", 0.61, 0.65, 0.78, true)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function RC:UpdateActionList()
	local ui = self.ui
	if not ui or not ui.frame:IsShown() then return end
	local T, list = Theme(), {}
	for _, v in pairs(round.entrants) do list[#list + 1] = v end
	table.sort(list, function(a, b)   -- highest roll first, then by name
		if a.roll ~= b.roll then return a.roll > b.roll end
		return a.name < b.name
	end)

	for i, v in ipairs(list) do
		local row = PoolRow(ui.rows, ui.listChild, i, ROW_H, BuildActionRow)
		local c, text, mark = T.fg, tostring(v.roll), nil
		if not v.entered then
			c, text = T.muted, "withdrawn"
		elseif v.roll <= 0 then
			c, text = PENDING_RGB, "—"
		elseif Contains(round.highTyers, v.key) then
			c, mark = WIN_RGB, WIN_RGB
		elseif Contains(round.lowTyers, v.key) then
			c, mark = LOSE_RGB, LOSE_RGB
		end
		row.entrant = v
		if not (round.acceptRolls and v.entered and not v.rolled) and row.edit:IsShown() then
			row.edit:SetText(""); row.edit:ClearFocus(); row.edit:Hide()
		end
		if v.byHand then text = text .. "*" end
		row.rank:SetText(i .. ".")
		row.name:SetText(v.name)
		SetRGB(row.name, v.entered and T.fg or T.muted)
		row.roll:SetText(text)
		SetRGB(row.roll, c)
		row.mark:SetShown(mark ~= nil)
		if mark then row.mark:SetColorTexture(mark.r, mark.g, mark.b, 1) end
	end
	HidePool(ui.rows, #list + 1)
	ui.listChild:SetHeight(max(1, #list * ROW_H))
	ui.empty:SetShown(#list == 0)
	ui.empty:SetText(format("No entrants yet.\nStart a round and have players type  %s%s|r", Hex(T.accent), db.profile.enterMsg))
	ui.actionCount:SetText(#list > 0 and format("%d %s", #list, Plural(#list, "player", "players")) or "")
end

-- The custom channel row only shows when "Custom Channel" is picked.
function RC:RebuildGameGroup()
	local ui = self.ui
	if not ui then return end
	local showChannel = db.profile.chatMethod == "CHANNEL"
	ui.channelLabel:SetShown(showChannel)
	ui.channelEdit:SetShown(showChannel)
	ui.channelEdit:Refresh()
	local y = showChannel and -134 or -86
	ui.rollFor:SetPoint("TOPLEFT", CARD_PAD, y)
	ui.ratioNote:SetPoint("TOPRIGHT", -CARD_PAD, y)
	ui.rulesBtn:SetPoint("TOPLEFT", CARD_PAD, y - 24)
	ui.gameCard:SetHeight(-y + 24 + 24 + CARD_PAD)
	self:RefreshControls()
end

function RC:BuildWindow()
	if self.ui then return end
	local ui = { rows = {} }
	self.ui = ui
	local f = Window("HiLoCasinoWindow", WIN_W, WIN_H, "window", "Hi-Lo", "Casino", function(w) w:SetPoint("CENTER") end)
	ui.frame, ui.subtitle, ui.potNote = f, f.subtitle, f.footRight
	Paint(function(T) f.footLeft:SetText(Hex(T.fg) .. "Hi-Lo|r " .. Hex(T.accent) .. "Casino|r  " .. Version()) end)

	-- Game
	local game = Card(f, "Game", -HEADER - PAD)
	ui.gameCard = game
	local colW = floor((INNER - 20) / 3)
	local x2, x3 = CARD_PAD + colW + 10, CARD_PAD + 2 * (colW + 10)
	FieldLabel(game, "Stakes (gold)", CARD_PAD, -CARD_TITLE)
	FieldLabel(game, "Ratio  (roll : gold)", x2, -CARD_TITLE)
	FieldLabel(game, "Broadcast to", x3, -CARD_TITLE)
	ui.stakesEdit = Field(game, colW, 26, function(box, text) RC:Set("stakesGold", text); box:Refresh() end, Get("stakesGold"))
	ui.stakesEdit:SetPoint("TOPLEFT", CARD_PAD, -CARD_TITLE - 16)
	ui.stakesEdit:SetNumeric(true)
	ui.ratioDrop = Dropdown(game, colW, 26, RATIOS, Get("ratio"), Put("ratio"))
	ui.ratioDrop:SetPoint("TOPLEFT", x2, -CARD_TITLE - 16)
	ui.channelDrop = Dropdown(game, INNER - 2 * (colW + 10), 26, CHATS, Get("chatMethod"), Put("chatMethod"))
	ui.channelDrop:SetPoint("TOPLEFT", x3, -CARD_TITLE - 16)
	ui.channelLabel = FieldLabel(game, "Custom channel name", CARD_PAD, -84)
	ui.channelEdit = Field(game, INNER, 26, function(box, text) RC:Set("customChannel", text); box:Refresh() end, Get("customChannel"))
	ui.channelEdit:SetPoint("TOPLEFT", CARD_PAD, -100)
	ui.rollFor = Text(game, 13, "fg", false, "LEFT")
	ui.ratioNote = Text(game, 11, "muted", false, "RIGHT")
	ui.rulesBtn = Button(game, "Broadcast Rules", INNER, 24, function() RC:PrintRules() end, false,
		"Post the Hi/Lo rules to the broadcast channel.")

	-- Round
	local rc = Card(f, "Round", game, CARD_TITLE + 32 + 6 + 24 + 6 + 24 + CARD_PAD)
	ui.phaseBtn = Button(rc, PHASE_BUTTON[0], INNER, 32, function() RC:NextPhase() end, true)
	ui.phaseBtn:SetPoint("TOPLEFT", CARD_PAD, -CARD_TITLE)
	ui.listBtn, ui.resetBtn = ButtonRow(rc, CARD_PAD, -CARD_TITLE - 38, INNER, 24, {
		{ "List Remaining", function() RC:ListRemaining() end, false, "Post who still has to roll, plus the current high and low." },
		{ "Reset Round", function() RC:ResetRound() end },
	})
	ui.enterBtn, ui.rollBtn = ButtonRow(rc, CARD_PAD, -CARD_TITLE - 68, INNER, 24, {
		{ "Enter  (me)", function() RC:DoPersonalEnter() end, false, "Join the round yourself." },
		{ "Roll  (me)", function() RC:DoPersonalRoll() end, false, "Do your /roll for this round." },
	})

	-- Stats
	-- One pair of post buttons for this session, one for all time.
	local st = Card(f, "Stats", rc, CARD_TITLE + 24 + 6 + 24 + CARD_PAD)
	ui.statsPeriod = st.note
	ui.topBtn, ui.bottomBtn = ButtonRow(st, CARD_PAD, -CARD_TITLE, INNER, 24, {
		{ "Session Top 5", function() RC:PostLeaderboard("top", nil, "session") end, false, "Post the biggest winners since you logged in (or since New session)." },
		{ "Session Bottom 5", function() RC:PostLeaderboard("bottom", nil, "session") end, false, "Post the biggest losers since you logged in (or since New session)." },
		{ "History", function() RC:ToggleHistory() end, false, "Leaderboard, round log, summaries and clean-up for any period." },
	})
	local third = floor((INNER - 16) / 3)
	ui.allTopBtn, ui.allBottomBtn = ButtonRow(st, CARD_PAD, -CARD_TITLE - 30, INNER - third - 8, 24, {
		{ "All-time Top 5", function() RC:PostLeaderboard("top", nil, "all") end, false, "Post the biggest winners over every round recorded." },
		{ "All-time Bottom 5", function() RC:PostLeaderboard("bottom", nil, "all") end, false, "Post the biggest losers over every round recorded." },
	})

	-- The Action (fills the rest)
	local act = Card(f, "The Action", st)
	act:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, FOOTER + 6)
	ui.actionCount = act.note
	ui.listChild, ui.empty = ScrollList(act, -CARD_TITLE, INNER, ROW_H * 2)

	f:SetScript("OnShow", function()
		RepaintAll()
		RC:RebuildGameGroup()
		RC:UpdateActionList()
	end)
end

function RC:ShowWindow() self:BuildWindow(); self.ui.frame:Show() end
function RC:HideWindow() if self.ui then self.ui.frame:Hide() end end
function RC:ToggleWindow()
	if self.ui and self.ui.frame:IsShown() then self:HideWindow() else self:ShowWindow() end
end

--==========================================================================
--  HISTORY WINDOW  (leaderboard + round log for a chosen period)
--==========================================================================

local HIST_W, HIST_H, LB_H, LOG_ROW, ARM_SECONDS = 600, 640, 280, 22, 3
local HIST_INNER = HIST_W - PAD * 2 - CARD_PAD * 2
-- Leaderboard columns, right-aligned, measured from the row's right edge.
local LB_COLS = {
	{ key = "worst", title = "WORST", w = 64, right = 0 },
	{ key = "best", title = "BEST", w = 64, right = 70 },
	{ key = "wl", title = "W / L", w = 56, right = 140 },
	{ key = "rounds", title = "ROUNDS", w = 56, right = 202 },
	{ key = "net", title = "NET", w = 84, right = 264 },
}
local LB_NAME_RIGHT = 356

-- A button that needs a second click within a few seconds to fire.
local function Arm(btn, armedText, restText, onConfirm)
	if btn.armed then
		btn.armed = nil
		btn:SetText(restText)
		return onConfirm()
	end
	btn.armed = true
	btn:SetText(armedText)
	C_Timer.After(ARM_SECONDS, function()
		if btn.armed then btn.armed = nil; btn:SetText(restText) end
	end)
end

local function NetColor(T, n) return n > 0 and WIN_RGB or n < 0 and LOSE_RGB or T.muted end

local function BuildLeaderRow(row)
	RankText(row)
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
end

local function RoundTooltip(row)
	local rec = row.rec
	if not rec or rec.legacy then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:AddLine(date("%A %d %B  %H:%M", rec.t), 1, 1, 1)
	GameTooltip:AddLine(format("Stakes %s  (1-%d, %d : 1)", Gold((rec.cap or 0) / (rec.ratio or 1)), rec.cap or 0, rec.ratio or 1), 0.7, 0.7, 0.7)
	for _, pl in ipairs(rec.players or {}) do
		local d = RoundDeltas(rec)[pl.n] or 0
		local c = d > 0 and WIN_RGB or d < 0 and LOSE_RGB or { r = 0.9, g = 0.9, b = 0.9 }
		GameTooltip:AddDoubleLine(pl.n, tostring(pl.r), c.r, c.g, c.b, c.r, c.g, c.b)
	end
	GameTooltip:Show()
end

local function BuildLogRow(row)
	row:EnableMouse(true)
	row:SetScript("OnEnter", RoundTooltip)
	row:SetScript("OnLeave", GameTooltip_Hide or function() GameTooltip:Hide() end)
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
end

local function ResultText(T, rec)
	if rec.legacy then return Hex(T.muted) .. "Imported totals from before 2.2|r" end
	if rec.tie then return Hex(T.muted) .. "Tie - no payout|r" end
	return Hex(LOSE_RGB) .. concat(rec.losers or {}, ", ") .. "|r" .. Hex(T.muted) .. "  owes  |r"
		.. Hex(WIN_RGB) .. concat(rec.winners or {}, ", ") .. "|r" .. (Each(rec) and Hex(T.muted) .. " each|r" or "")
end

function RC:RefreshHistory()
	local h = self.hist
	if not h or not h.frame:IsShown() then return end
	local T, period = Theme(), db.profile.histPeriod
	local order, totals = self:Aggregate(period)

	h.periodDrop:Refresh()
	h.countDrop:Refresh()
	h.topBtn:SetText("Post Top " .. db.profile.topN)
	h.bottomBtn:SetText("Post Bottom " .. db.profile.topN)
	h.subtitle:SetText(format("%s   ·   %d %s   ·   %d %s   ·   %s changed hands", self:PeriodName(period),
		totals.rounds, Plural(totals.rounds, "round", "rounds"), totals.ties, Plural(totals.ties, "tie", "ties"),
		Gold(totals.moved)))
	h.lbCount:SetText(#order > 0 and format("%d %s", #order, Plural(#order, "player", "players")) or "")

	for i, p in ipairs(order) do
		local row = PoolRow(h.lbRows, h.lbChild, i, LOG_ROW, BuildLeaderRow)
		local c = row.cols
		row.rank:SetText(i .. ".")
		row.name:SetText(p.name)
		c.net:SetText(Gold(p.net, true))
		c.rounds:SetText(p.rounds > 0 and tostring(p.rounds) or "-")
		c.wl:SetText(p.rounds > 0 and format("%d / %d", p.wins, p.losses) or "-")
		c.best:SetText(p.best > 0 and Gold(p.best, true) or "-")
		c.worst:SetText(p.worst < 0 and Gold(p.worst, true) or "-")
		SetRGB(c.net, NetColor(T, p.net))
		SetRGB(c.rounds, T.fg)
		SetRGB(c.wl, T.muted)
		SetRGB(c.best, p.best > 0 and WIN_RGB or T.muted)
		SetRGB(c.worst, p.worst < 0 and LOSE_RGB or T.muted)
	end
	HidePool(h.lbRows, #order + 1)
	h.lbChild:SetHeight(max(1, #order * LOG_ROW))
	h.lbEmpty:SetShown(#order == 0)

	local all, recs = Rounds(), {}
	for i = #all, 1, -1 do   -- newest first
		if InPeriod(all[i], period) then recs[#recs + 1] = all[i] end
	end
	for i, rec in ipairs(recs) do
		local row = PoolRow(h.logRows, h.logChild, i, LOG_ROW, BuildLogRow)
		row.rec, row.del.armed = rec, nil
		row.del:SetText("x")
		row.when:SetText(rec.legacy and "-" or date("%d %b  %H:%M", rec.t))
		row.result:SetText(ResultText(T, rec))
		row.amount:SetText((rec.legacy or rec.tie) and "-" or Gold(rec.each))
		SetRGB(row.amount, (rec.legacy or rec.tie) and T.muted or T.accent)
		row.post:SetShown(not rec.legacy)
	end
	HidePool(h.logRows, #recs + 1)
	h.logChild:SetHeight(max(1, #recs * LOG_ROW))
	h.logEmpty:SetShown(#recs == 0)
	h.logCount:SetText(#recs > 0 and format("%d %s", #recs, Plural(#recs, "round", "rounds")) or "")
	h.clearBtn.armed = nil
	h.clearBtn:SetText("Clear period")
	h.stored:SetText(format("%d %s stored", #all, Plural(#all, "round", "rounds")))
end

function RC:BuildHistory()
	if self.hist then return end
	local h = { lbRows = {}, logRows = {} }
	self.hist = h
	local f = Window("HiLoCasinoHistory", HIST_W, HIST_H, "historyWindow", "Casino", "History", function(w)
		if RC.ui and RC.ui.frame:IsShown() then w:SetPoint("TOPLEFT", RC.ui.frame, "TOPRIGHT", 6, 0) else w:SetPoint("CENTER") end
	end)
	h.frame, h.subtitle, h.stored = f, f.subtitle, f.footRight
	f.footLeft:SetText("Hover a round for every roll")

	-- Toolbar: period, count, post buttons.
	local y = -HEADER - PAD
	h.periodDrop = Dropdown(f, 150, 26, PERIODS, Get("histPeriod"), Put("histPeriod"))
	h.periodDrop:SetPoint("TOPLEFT", PAD, y)
	h.countDrop = Dropdown(f, 84, 26, TOP_COUNTS, Get("topN"), Put("topN"))
	h.countDrop:SetPoint("LEFT", h.periodDrop, "RIGHT", 8, 0)
	h.topBtn, h.bottomBtn = ButtonRow(f, PAD + 250, y, HIST_W - PAD * 2 - 250, 26, {
		{ "Post Top 5", function() RC:PostLeaderboard("top") end, true, "Post the biggest winners for the selected period." },
		{ "Post Bottom 5", function() RC:PostLeaderboard("bottom") end, false, "Post the biggest losers for the selected period." },
		{ "Post Summary", function() RC:PostSummary() end, false,
			"Post rounds played, gold that changed hands, the biggest round and the luckiest/unluckiest player." },
	})

	-- Leaderboard
	local lb = Card(f, "Leaderboard", y - 26 - PAD, LB_H)
	h.lbCount = lb.note
	local headY = -CARD_TITLE + 2
	FieldLabel(lb, "PLAYER", CARD_PAD + 30, headY, 10)
	for _, col in ipairs(LB_COLS) do
		local fs = Text(lb, 10, "muted", false, "RIGHT")
		fs:SetPoint("TOPRIGHT", lb, "TOPRIGHT", -CARD_PAD - col.right - 4, headY)
		fs:SetWidth(col.w)
		fs:SetText(col.title)
	end
	h.lbChild, h.lbEmpty = ScrollList(lb, headY - 16, HIST_INNER, LOG_ROW * 3)
	h.lbEmpty:SetText("No rounds in this period yet.")

	-- Round log
	local log = Card(f, "Rounds", lb)
	log:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, FOOTER + 6)
	h.clearBtn = Button(log, "Clear period", 96, 20, function(btn)
		local n = RC:CountPeriod(db.profile.histPeriod)
		if n > 0 then
			Arm(btn, format("Delete %d?", n), "Clear period", function() RC:ClearPeriod(db.profile.histPeriod) end)
		end
	end, false, "Delete every round in the selected period (click twice to confirm).")
	h.clearBtn:SetPoint("TOPRIGHT", -CARD_PAD, -6)
	local newSession = Button(log, "New session", 96, 20, function() RC:NewSession() end, false,
		"Start counting \"This session\" from now. Nothing is deleted.")
	newSession:SetPoint("RIGHT", h.clearBtn, "LEFT", -6, 0)
	h.logCount = log.note
	log.note:ClearAllPoints()
	log.note:SetPoint("RIGHT", newSession, "LEFT", -10, 0)
	h.logChild, h.logEmpty = ScrollList(log, -CARD_TITLE, HIST_INNER, LOG_ROW * 3)
	h.logEmpty:SetText("No rounds in this period yet.")

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
--  OPTIONS PANEL  (Options > AddOns > Hi-Lo Casino, the gear buttons,
--  /hilo options, or Ctrl-click the minimap icon)
--==========================================================================

local OPT_LABEL_W, OPT_CTRL_W, OPT_ROW = 120, 150, 34

function RC:BuildOptions()
	if self.options or not (Settings and Settings.RegisterCanvasLayoutCategory) then return end
	local panel, controls = CreateFrame("Frame"), {}
	panel.controls = controls
	self.options = panel
	function panel:Refresh() for _, c in pairs(controls) do c:Refresh() end end

	local logo = panel:CreateTexture(nil, "ARTWORK")
	logo:SetSize(36, 36)
	logo:SetPoint("TOPLEFT", PAD + 4, -14)
	logo:SetTexture(ICON)
	local title = Text(panel, 20, "fg", true, "LEFT")
	title:SetPoint("TOPLEFT", logo, "TOPRIGHT", 10, -1)
	Paint(function(T) title:SetText("Hi-Lo " .. Hex(T.accent) .. "Casino|r  " .. Hex(T.muted) .. Version() .. "|r") end)
	FieldLabel(panel, "Settings save automatically. Text fields apply when you press Enter or click away.",
		PAD + 50, -38)

	-- Two columns of cards.
	local function Column(title_, left, y, height)
		local card = Card(panel, title_, nil, height)
		card:SetPoint("TOPLEFT", panel, left and "TOPLEFT" or "TOP", left and PAD or PAD / 2, y)
		card:SetPoint("RIGHT", panel, left and "CENTER" or "RIGHT", left and -PAD / 2 or -PAD, 0)
		return card
	end
	local function Row(card, i, label, control, key)
		FieldLabel(card, label, CARD_PAD, -CARD_TITLE - (i - 1) * OPT_ROW - 6, 12, "fg")
		control:SetPoint("TOPLEFT", CARD_PAD + OPT_LABEL_W, -CARD_TITLE - (i - 1) * OPT_ROW)
		controls[key] = control
	end
	local function TextOption(card, i, label, key, numeric)
		local box = Field(card, OPT_CTRL_W, 26, function(b, text) RC:Set(key, text); b:Refresh() end, Get(key))
		if numeric then box:SetNumeric(true) end
		Row(card, i, label, box, key)
	end
	local function ChoiceOption(card, i, label, key, list)
		Row(card, i, label, Dropdown(card, OPT_CTRL_W, 26, list, Get(key), Put(key)), key)
	end

	local top = -64
	local roundCard = Column("Round", true, top, CARD_TITLE + 4 * OPT_ROW + CARD_PAD)
	TextOption(roundCard, 1, "Stakes (gold)", "stakesGold", true)
	ChoiceOption(roundCard, 2, "Ratio (roll : gold)", "ratio", RATIOS)
	ChoiceOption(roundCard, 3, "Broadcast to", "chatMethod", CHATS)
	TextOption(roundCard, 4, "Custom channel", "customChannel")
	roundCard.note:SetText("used by Start Round")

	local words = Card(panel, "Chat keywords", roundCard, CARD_TITLE + 2 * OPT_ROW + CARD_PAD + 16)
	words:SetPoint("RIGHT", roundCard, "RIGHT")
	TextOption(words, 1, "Enter", "enterMsg")
	TextOption(words, 2, "Withdraw", "withdrawMsg")
	FieldLabel(words, "What players type in the broadcast channel.", CARD_PAD, -CARD_TITLE - 2 * OPT_ROW - 2)

	local hist = Column("History", false, top, CARD_TITLE + 2 * OPT_ROW + CARD_PAD)
	ChoiceOption(hist, 1, "Period", "histPeriod", PERIODS)
	ChoiceOption(hist, 2, "Post count", "topN", TOP_COUNTS)
	hist.note:SetText("for Post Top / Bottom")

	local look = Card(panel, "Interface", hist, CARD_TITLE + OPT_ROW + 4 * 24 + 8 + 2 * 30 + CARD_PAD)
	look:SetPoint("RIGHT", hist, "RIGHT")
	ChoiceOption(look, 1, "Window scale", "scale", SCALES)
	local toggles = {
		{ "minimap", "Show minimap button", function() return not db.profile.minimap.hide end, function(v) RC:SetMinimapShown(v) end },
		{ "lockWindows", "Lock window positions", Get("lockWindows"), Put("lockWindows") },
		{ "clickSound", "Click sounds", Get("clickSound"), Put("clickSound") },
		{ "loginMessage", "Message in chat on login", Get("loginMessage"), Put("loginMessage") },
	}
	for i, t in ipairs(toggles) do
		local tg = Toggle(look, t[2], t[3], t[4])
		tg:SetPoint("TOPLEFT", CARD_PAD, -CARD_TITLE - OPT_ROW - (i - 1) * 24)
		controls[t[1]] = tg
	end
	local by, lookW = -CARD_TITLE - OPT_ROW - 4 * 24 - 8, OPT_LABEL_W + OPT_CTRL_W   -- same width as the rows
	ButtonRow(look, CARD_PAD, by, lookW, 24, {
		{ "Open window", function() RC:ShowWindow() end },
		{ "Open history", function() RC:BuildHistory(); RC.hist.frame:Show() end },
	})
	ButtonRow(look, CARD_PAD, by - 30, lookW, 24, {
		{ "Reset window positions", function() RC:ResetPositions() end, false, "Move both windows back to their default spots." },
	})

	panel:SetScript("OnShow", function() RepaintAll(); panel:Refresh() end)
	self.optionsCategory = Settings.RegisterCanvasLayoutCategory(panel, "Hi-Lo Casino")
	Settings.RegisterAddOnCategory(self.optionsCategory)
end

function RC:OpenOptions()
	if self.optionsCategory then
		Settings.OpenToCategory(self.optionsCategory:GetID())
	else
		self:Print("The settings panel isn't available on this client.")
	end
end

function RC:ResetPositions()
	db.profile.window, db.profile.historyWindow = nil, nil
	if self.ui then self.ui.frame:Place() end
	if self.hist then self.hist.frame:Place() end
	self:Print("Window positions reset.")
end

--==========================================================================
--  CHAT EVENTS
--==========================================================================

local function Readable(...)
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if issecret(v) or v == nil then return false end
	end
	return true
end

local function EntriesOpenFor(method)
	return round and round.acceptEntries and db.profile.chatMethod == method
end

local CHAT_EVENTS = {
	RAID = { "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER" }, PARTY = { "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER" },
	GUILD = { "CHAT_MSG_GUILD" }, SAY = { "CHAT_MSG_SAY" }, CHANNEL = { "CHAT_MSG_CHANNEL" }, SYSTEM = { "CHAT_MSG_SYSTEM" },
}

-- In combat Forever hands chat to addons as secret values: we can see a line
-- arrived but not what it says or who sent it, and it stays secret (also in the
-- chat window's history), so it can't be read after combat either. We count
-- those lines and, once combat is over, ask for the entries again (missed).

for _, method in ipairs({ "RAID", "PARTY", "GUILD", "SAY" }) do
	RC["Chat_" .. method] = function(self, _, text, sender)
		if not EntriesOpenFor(method) then return end
		if Readable(text, sender) then self:ParseEntry(text, sender)
		elseif text ~= nil then missed.entries = missed.entries + 1 end
	end
end

function RC:Chat_CHANNEL(_, text, _, _, _, sender, _, _, _, channel)
	if not EntriesOpenFor("CHANNEL") then return end
	if Readable(text, sender, channel) then
		if channel == db.profile.customChannel then self:ParseEntry(text, sender) end
	elseif text ~= nil and (issecret(channel) or channel == db.profile.customChannel) then
		missed.entries = missed.entries + 1
	end
end

function RC:Chat_SYSTEM(_, text)
	if not (round and round.acceptRolls) then return end
	if Readable(text) then self:ParseRoll(text)
	elseif text ~= nil then missed.rolls = missed.rolls + 1 end
end

-- After combat: ask everyone who typed the enter word to type it again, and tell
-- the host (only) who still has to roll - asking for re-rolls would let someone
-- who rolled low in combat roll again.
function RC:ReportMissedChat(tries)
	if missed.entries == 0 and missed.rolls == 0 then return end
	if ChatHidden() and (tries or 0) < 30 then
		return C_Timer.After(2, function() self:ReportMissedChat((tries or 0) + 1) end)
	end
	local entries, rolls = missed.entries, missed.rolls
	missed.entries, missed.rolls = 0, 0
	if entries > 0 and round and round.acceptEntries then
		local word = db.profile.enterMsg
		if self:NeedsHardwareEvent() then
			self:Print(format("%d %s in combat could not be read - ask them to type %s again.",
				entries, Plural(entries, "message", "messages"), word))
		else
			self:ChatMsg(format(".:HiLo:. Chat was hidden during combat - type %s again to join!", word))
		end
	end
	if rolls > 0 and round and round.acceptRolls and self:GetRemainingToRollCount() > 0 then
		local names = {}
		for _, v in pairs(round.entrants) do
			if v.entered and not v.rolled then names[#names + 1] = v.name end
		end
		table.sort(names)
		self:Print(format("Rolls during combat could not be read. Still to roll: %s. Check their rolls in chat and "
			.. "click their name in the list (or /hilo roll <name> <roll>) to type them in.", concat(names, ", ")))
	end
end

--==========================================================================
--  SLASH COMMANDS
--==========================================================================

local HELP = {
	"/hilo  - toggle the window",
	"/hilo options  - open the settings",
	"/hilo next  - advance the round phase",
	"/hilo reset  - reset the current round",
	"/hilo roll <name> <roll>  - type in a roll the addon missed (e.g. in combat)",
	"/hilo gold <n>  - set stakes in gold",
	"/hilo ratio <n>  - set roll:gold ratio (e.g. 10 or 100)",
	"/hilo channel <name>  - set custom chat channel",
	"/hilo history  - leaderboard and round log",
	"/hilo top [n] [period]  - post the top n winners (period: session, today, week, month, all)",
	"/hilo bottom [n] [period]  - post the n biggest losers",
	"/hilo summary [period]  - post a summary of the period",
	"/hilo newsession  - start a new \"This session\"",
	"/hilo minimap  - toggle the minimap button",
	"/hilo version",
}
local PERIOD_ALIAS = { day = "today", alltime = "all" }

function RC:SlashCmd(input)
	local cmd, rest = self:GetArgs(input, 2)
	cmd = cmd and strlower(cmd) or ""
	if cmd == "" or cmd == "show" or cmd == "toggle" then
		self:ToggleWindow()
	elseif cmd == "hide" then
		self:HideWindow()
	elseif cmd == "options" or cmd == "config" or cmd == "settings" then
		self:OpenOptions()
	elseif cmd == "reset" then
		self:ResetRound()
		self:Print("Round reset.")
	elseif cmd == "next" then
		self:NextPhase()
	elseif cmd == "roll" then
		-- names have spaces ("Agi Stack"), so take everything after "roll"
		local name, n = (input or ""):match("^%s*%S+%s+(.-)%s+(%d+)%s*$")
		local err
		if name and name ~= "" then err = self:EnterRoll(name, n) else err = "usage: /hilo roll <name> <roll>" end
		if err then self:Print("|cffff5555Roll not entered:|r " .. err .. ".") end
	elseif (cmd == "gold" or cmd == "ratio") and tonumber(rest) then
		self:Set(cmd == "gold" and "stakesGold" or "ratio", rest)
		self:Print(format("Stakes %dg at %d : 1 (roll 1-%d).", db.profile.stakesGold, db.profile.ratio, self:RollCap()))
	elseif cmd == "channel" and rest and rest ~= "" then
		self:Set("customChannel", rest)
		self:Print("Custom channel set to: " .. db.profile.customChannel)
	elseif cmd == "minimap" then
		self:SetMinimapShown(db.profile.minimap.hide)
		self:Print("Minimap button " .. (db.profile.minimap.hide and "hidden" or "shown") .. ".")
	elseif cmd == "history" or cmd == "stats" then
		self:ToggleHistory()
	elseif cmd == "top" or cmd == "bottom" or cmd == "summary" then
		-- /hilo top [n] [period]  - either order, both optional
		local n, period
		for word in ((input or ""):match("^%s*%S+(.*)$") or ""):gmatch("%S+") do   -- GetArgs only gave the 2nd word
			word = strlower(word)
			if tonumber(word) then n = max(1, min(25, floor(tonumber(word))))
			else period = PERIOD_LABEL[word] and word or PERIOD_ALIAS[word] or period end
		end
		if cmd == "summary" then self:PostSummary(period) else self:PostLeaderboard(cmd, n, period) end
	elseif cmd == "newsession" then
		self:NewSession()
	elseif cmd == "version" then
		self:Print("Hi-Lo Casino v" .. Version())
	else
		self:Print("|cffffff00Hi-Lo Casino commands:|r  (/rc works too)")
		for _, line in ipairs(HELP) do self:Print(line) end
	end
end

--==========================================================================
--  LIFECYCLE
--==========================================================================

function RC:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("HiLoCasinoDB", defaults, true)
	db = self.db

	if db.profile.customChannel == "RollGamble" then db.profile.customChannel = "hilocasino" end
	if db.profile.stakes then   -- 2.0 stored the roll cap; now it's gold
		db.profile.stakesGold = max(1, floor(db.profile.stakes / (db.profile.ratio or 100)))
		db.profile.stakes = nil
	end
	-- 2.2: old running totals (roll units) become one "imported totals" record (All time only).
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
	if not PERIOD_LABEL[db.profile.histPeriod] then db.profile.histPeriod = "all" end
	sessionStart = db.global.sessionStart or sessionStart

	round = NewRound(self:RollCap())

	if LDB and LDBIcon then
		LDBIcon:Register("HiLoCasino", LDB:NewDataObject("HiLoCasino", {
			type = "launcher",
			text = "Hi-Lo Casino",
			icon = ICON,
			OnClick = function(_, button)
				if button == "RightButton" then RC:PostLeaderboard("top")
				elseif IsControlKeyDown() then RC:OpenOptions()
				elseif IsShiftKeyDown() then RC:ToggleHistory()
				else RC:ToggleWindow() end
			end,
			OnTooltipShow = function(tt)
				tt:AddLine("Hi-Lo Casino")
				tt:AddLine("|cffffffffLeft-click:|r toggle window")
				tt:AddLine("|cffffffffShift-click:|r history")
				tt:AddLine("|cffffffffCtrl-click:|r settings")
				tt:AddLine(format("|cffffffffRight-click:|r post top %d (%s)", db.profile.topN, RC:PeriodName(db.profile.histPeriod)))
			end,
		}), db.profile.minimap)
	end

	for _, name in ipairs({ "rc", "hilo", "hilocasino" }) do self:RegisterChatCommand(name, "SlashCmd") end
	self:BuildOptions()
end

function RC:OnEnable()
	for method, events in pairs(CHAT_EVENTS) do
		for _, event in ipairs(events) do self:RegisterEvent(event, "Chat_" .. method) end
	end
	self:RegisterEvent("PLAYER_REGEN_DISABLED", function()
		if round.phase == 1 or round.phase == 2 then
			self:Print("In combat - the round is paused until it's over.")
		elseif round.phase == 3 then
			self:Print("In combat - rolls made now can't be read; you can type them in afterwards.")
		end
		self:RefreshControls()
	end)
	self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
		if round.phase == 1 or round.phase == 2 then self:Print("Combat over - the round continues.") end
		self:RefreshControls()
		self:ReportMissedChat()
	end)
	self:RegisterEvent("PLAYER_ENTERING_WORLD", function(_, isInitialLogin)
		if isInitialLogin == true or not db.global.sessionStart then
			sessionStart = time()
			db.global.sessionStart = sessionStart
		end
		self:RefreshHistory()
	end)
	if db.profile.loginMessage then
		self:Print("|cffffff00Hi-Lo Casino|r loaded. Type |cff59f0dc/hilo|r to open, |cff59f0dc/hilo options|r for settings.")
	end
end

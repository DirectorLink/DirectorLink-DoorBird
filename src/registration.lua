--[[=============================================================================
    DirectorLink DoorBird - the driver's HTTP calls on the DoorBird
    (favorites.cgi and schedule.cgi), the way Home Assistant registers them.

    One HTTP favorite per event, titled "DirectorLink (<event>)", whose URL
    points at this driver's event server with the event and the token:
      doorbell:<n>   each doorbell button   (schedule input "doorbell", param <n>)
      keypad:<code>  each keypad code       (input "doorbell", param <code>: on keypad
                     models a code is a "doorbell" entry; codes have 4 or more digits
                     or a leading zero, buttons do not)
      motion         the motion sensor      (input "motion")
      rfid           any RFID tag           (every "rfid" entry the DoorBird has)
      relay:<n>      each relay of the DoorBird itself (input "relay", param <n>)
    An "http" output for that favorite is added to the matching schedule
    entries, active the whole week.

    Only what this driver made is ever changed:
      - its favorites are the ones whose URL carries its token;
      - in a schedule entry, only the outputs that point at its favorites;
        every other output (the DoorBird app's push notifications, the
        official DoorBird driver's and other apps' HTTP calls, SIP calls,
        relays) is written back exactly as it was read;
      - each entry is read just before it is written (the DoorBird has no
        "change only if unchanged"), and read again right after: if any
        other output went missing or changed (a DoorBird may keep one HTTP
        call per event and time), the entry is put back as it was read and
        the event is reported as taken. Such an entry, and one the DoorBird
        refuses or does not keep, is then left alone (no retry every 30
        minutes) until its other outputs change or Reconnect runs;
      - an entry is created only when a read the DoorBird answered with a
        JSON list shows it is not there; an entry is removed whole only when
        this driver created it and nothing else is in it;
      - leaving (Remove From DoorBird, a new address, the driver deleted),
        its outputs are taken out first; its favorites are deleted only
        after a read shows none of them is in the schedule any more (the
        DoorBird removes schedule entries that use a deleted favorite);
      - a write whose read back never came (the DoorBird stopped answering,
        or took a new password at that moment) is remembered with the entry
        as it was before; at the next chance (the next check, after a
        restart, or when leaving that DoorBird) any other output missing
        from it is put back;
      - a change of address or login waits for the job on its way to end,
        and anything still made for the old one is cancelled: nothing made
        for one DoorBird reaches another.
    Favorites of an earlier copy of this driver on the same controller
    ("DirectorLink (...)" at /doorbird on this controller's address, any
    port, another token) are removed the same way.

    Copyright 2026 DirectorLink
    SPDX-License-Identifier: Apache-2.0
===============================================================================]]

REG_TITLE_PREFIX = "DirectorLink ("
-- The whole week: a window that wraps around (from > to), as Home Assistant writes it
REG_WEEK_FROM, REG_WEEK_TO = "104400", "104399"
REG_WEEK_SECONDS = 604800

gReg = {
	favorites = {},  -- key -> favorite id (this driver's, on gReg.host)
	created = {},    -- EntryKey(input, param) -> true: schedule entries this driver created there
	skip = {},       -- EntryKey -> { sig = the entry's other outputs then, text = why }: left alone
	unchecked = {},  -- EntryKey -> the entry as it was before a write whose read back never came
	host = "",       -- the DoorBird they are on
	wrote = nil,     -- the DoorBird this driver has written to (set before the first write: a job cut
	                 -- short by a new address still leaves the old DoorBird to clean up)
	state = "idle",  -- idle, working, ok, partial, refused, failed, removed
	summary = "", problems = {}, registered = {}, keys = nil, lastSync = nil, lastError = nil,
	busy = false, job = nil, again = false, entries = nil, favs = nil, sipCount = 0,
}

--[[------------------------------------------------------------------ Event keys ]]
function KeyParts(key)
	local kind, param = string.match(tostring(key), "^(%a+):(.+)$")
	if kind then return kind, param end
	return tostring(key), ""
end

function KeyLabel(key)
	local kind, param = KeyParts(key)
	if kind == "rfid" then return "RFID" end
	if kind == "keypad" then return "keypad code " .. param end
	return kind .. (param ~= "" and (" " .. param) or "")
end

function KeyTitle(key)
	return REG_TITLE_PREFIX .. KeyLabel(key) .. ")"
end

-- The URL the DoorBird calls for this event
function KeyUrl(ctx, key)
	local kind, param = KeyParts(key)
	local q = { { "e", kind } }
	if param ~= "" then q[#q + 1] = { "p", param } end
	q[#q + 1] = { "t", ctx.token }
	return "http://" .. ctx.ctrl .. ":" .. ctx.port .. EVENT_PATH .. "?" .. QueryString(q)
end

-- Does this key's favorite belong in this schedule entry?
function KeyMatchesEntry(key, input, param)
	local kind, p = KeyParts(key)
	if kind == "motion" then return input == "motion" end
	if kind == "rfid" then return input == "rfid" end
	if kind == "keypad" then return input == "doorbell" and param == p end
	return input == kind and param == p
end

-- The schedule entry this driver creates for a key when the DoorBird has none (RFID never: it
-- needs a tag's id)
local function CreatableEntry(key)
	local kind, p = KeyParts(key)
	if kind == "doorbell" or kind == "relay" then return kind, p end
	if kind == "motion" then return "motion", "" end
	return nil
end

-- host:port, path and query of a favorite's URL
local function SplitUrl(url)
	local hostport, path, query = string.match(tostring(url or ""), "^%a+://([^/?#]+)([^?#]*)%??([^#]*)")
	if hostport then hostport = string.gsub(hostport, "^[^@]*@", "") end
	return hostport, path, query
end

-- The key of one of this driver's favorites (nil when the favorite is not this driver's)
function OwnFavoriteKey(value, token)
	local _, path, query = SplitUrl(value)
	if path ~= EVENT_PATH or not token or token == "" or QueryValue(query, "t") ~= token then return nil end
	local e, p = QueryValue(query, "e") or "", QueryValue(query, "p") or ""
	if e == "" then return nil end
	return p ~= "" and (e .. ":" .. p) or e
end

-- A favorite an earlier copy of this driver left on this DoorBird from this controller (any port: a
-- copy deleted and added again has another device id, so another port), with another token
-- A favorite of another copy of this driver at this controller (another token). At this driver's
-- port it is an earlier copy's: nothing else listens there. At another port it is an orphan only
-- when nothing answers there (dead[port]): a copy still running keeps its own. Also returns that
-- other port, to be probed.
local function IsOrphan(fav, ctx, dead)
	if string.sub(fav.title or "", 1, #REG_TITLE_PREFIX) ~= REG_TITLE_PREFIX then return false end
	local hostport, path, query = SplitUrl(fav.value)
	local host, port = string.match(hostport or "", "^([^:]+):?(%d*)$")
	local t = QueryValue(query, "t")
	if path ~= EVENT_PATH or host ~= ctx.ctrl or t == nil or t == "" or t == ctx.token then return false end
	port = tonumber(port) or 80
	if port == tonumber(ctx.port) then return true end
	return dead ~= nil and dead[port] == true, port
end

local function SortParams(list)
	table.sort(list, function(a, b)
		local na, nb = tonumber(a), tonumber(b)
		if na and nb then return na < nb end
		if na or nb then return na ~= nil end
		return a < b
	end)
	return list
end

-- The events to register: each doorbell button the schedule knows (button 1 when it knows none),
-- motion, RFID when the DoorBird has tags, each of the DoorBird's own relays, and each keypad code.
function DesiredKeys(entries, relays)
	local buttons, codes, seen, hasRfid, relaySeen = {}, {}, {}, false, {}
	for _, e in ipairs(entries or {}) do
		local input, param = EntryInput(e), EntryParam(e)
		if input == "doorbell" and param ~= "" and not seen[param] then
			seen[param] = true
			if IsKeypadCode(param) then codes[#codes + 1] = param else buttons[#buttons + 1] = param end
		elseif input == "rfid" then
			hasRfid = true
		end
	end
	if #buttons == 0 then buttons = { "1" } end
	SortParams(buttons)
	table.sort(codes)
	local keys = {}
	for _, b in ipairs(buttons) do keys[#keys + 1] = "doorbell:" .. b end
	keys[#keys + 1] = "motion"
	if hasRfid then keys[#keys + 1] = "rfid" end
	local physical = {}
	for _, r in ipairs(relays or {}) do
		if not IsPeripheralRelay(r) and not relaySeen[r] then
			relaySeen[r] = true
			physical[#physical + 1] = r
		end
	end
	if #physical == 0 and #(relays or {}) == 0 then physical = { "1" } end
	SortParams(physical)
	for _, r in ipairs(physical) do keys[#keys + 1] = "relay:" .. r end
	-- Keypad codes last: if the DoorBird has no room for more favorites, the bell, motion, RFID and
	-- the relays come first
	for _, c in ipairs(codes) do keys[#keys + 1] = "keypad:" .. c end
	return keys
end

--[[------------------------------------------------------------------ Outputs ]]
local function OutputEvent(o) return tostring(JsonField(o, "event") or "") end
local function OutputParam(o) return tostring(JsonField(o, "param") or "") end

local function Outputs(e)
	local o = JsonField(e, "output")
	return type(o) == "table" and o or {}
end

-- The week window of another output of the entry when it is the whole week (the DoorBird app's
-- own way of writing it), else Home Assistant's
local function WeekWindow(outputs)
	for _, o in ipairs(outputs or {}) do
		local sched = JsonField(o, "schedule")
		local wd = type(sched) == "table" and JsonField(sched, "weekdays") or nil
		if type(wd) == "table" and #wd == 1 and type(wd[1]) == "table" then
			local f, t = tonumber(JsonField(wd[1], "from")), tonumber(JsonField(wd[1], "to"))
			if f and t and f % 1800 == 0 and (t + 1) % REG_WEEK_SECONDS == f % REG_WEEK_SECONDS then
				return tostring(JsonField(wd[1], "from")), tostring(JsonField(wd[1], "to"))
			end
		end
	end
	return REG_WEEK_FROM, REG_WEEK_TO
end

local function NewOutput(id, outputs)
	local from, to = WeekWindow(outputs)
	return JsonObject({
		event = "http", param = tostring(id), enabled = "1",
		schedule = JsonObject({ weekdays = { JsonObject({ from = from, to = to }) } }),
	})
end

-- A value written so that the DoorBird's own ways of storing it compare equal (1 and "1", key order)
local function Canon(v)
	if type(v) ~= "table" or v == JSON_NULL then
		if type(v) == "number" then return v == math.floor(v) and string.format("%.0f", v) or tostring(v) end
		return tostring(v)
	end
	local out = {}
	if JsonIsObject(v) then
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = tostring(k) end
		table.sort(keys)
		for _, k in ipairs(keys) do out[#out + 1] = k .. "=" .. Canon(v[k]) end
		return "{" .. table.concat(out, ",") .. "}"
	end
	for i = 1, #v do out[i] = Canon(v[i]) end
	return "[" .. table.concat(out, ",") .. "]"
end

-- An output of another app as it must stay: event, param, on/off (missing = on) and its times
local function OtherKey(o)
	local enabled = JsonField(o, "enabled")
	local on = not (enabled == "0" or enabled == 0 or enabled == false)
	return OutputEvent(o) .. "|" .. OutputParam(o) .. "|" .. (on and "on" or "off") .. "|" .. Canon(JsonField(o, "schedule"))
end

-- Multiset of the outputs that are not this driver's: OtherKey -> count
local function OthersOf(entry, managed)
	local out = {}
	for _, o in ipairs(Outputs(entry)) do
		if not (OutputEvent(o) == "http" and managed[OutputParam(o)]) then
			local k = OtherKey(o)
			out[k] = (out[k] or 0) + 1
		end
	end
	return out
end

-- The other outputs of an entry as one string, to see whether they changed
local function OthersSignature(entry, managed)
	if not entry then return "" end
	local list = {}
	for k, n in pairs(OthersOf(entry, managed)) do list[#list + 1] = k .. "*" .. n end
	table.sort(list)
	return table.concat(list, ";")
end

local function OwnIdsIn(entry, managed)
	local out = {}
	for _, o in ipairs(Outputs(entry)) do
		if OutputEvent(o) == "http" and managed[OutputParam(o)] then out[OutputParam(o)] = true end
	end
	return out
end

local function SameSet(a, b)
	for k in pairs(a) do if not b[k] then return false end end
	for k in pairs(b) do if not a[k] then return false end end
	return true
end

local function FindEntry(entries, input, param)
	for _, e in ipairs(entries or {}) do
		if EntryInput(e) == input and EntryParam(e) == param then return e end
	end
	return nil
end

-- What an output of another app is, for the log and Status (titles only: URLs may hold logins)
local function DescribeOther(k, favs)
	local event, param = string.match(k, "^([^|]*)|([^|]*)|")
	if event == "http" then
		local f = favs and favs[param]
		return f and ("HTTP call '" .. f.title .. "'") or ("HTTP call #" .. param)
	end
	if event == "notify" then return "the DoorBird app's notifications" end
	if event == "sip" then return "SIP call #" .. tostring(param) end
	if event == "relay" then return "relay " .. tostring(param) end
	return tostring(event) .. ((param or "") ~= "" and (" " .. param) or "")
end

--[[------------------------------------------------------------------ Requests
    Each carries the generation of its job: after a change of address or
    login it is answered "cancelled" and never sent.                       ]]
local function ReadFavorites(t, gen, cb)
	DoorBirdRequest(t, { path = "/bha-api/favorites.cgi", kind = "operator", label = "favorites.cgi (read)", gen = gen }, function(code, body, err)
		if code ~= 200 then return cb(nil, code, err) end
		local favs, perr, sipCount = ParseFavorites(body)
		if not favs then return cb(nil, code, perr) end
		cb(favs, code, nil, sipCount)
	end)
end

-- The schedule, only from a 200 answer that is a JSON list (anything else is "not read")
local function ReadSchedule(t, gen, cb)
	DoorBirdRequest(t, { path = "/bha-api/schedule.cgi", kind = "operator", label = "schedule.cgi (read)", gen = gen }, function(code, body, err)
		if code ~= 200 then return cb(nil, code, err) end
		local entries, perr = ParseSchedule(body)
		if not entries then return cb(nil, code, perr) end
		LogTrace("schedule.cgi: %s", body)
		cb(entries, code)
	end)
end

-- Before a write: the DoorBird this driver may have left something on
local function Writing(t)
	if gReg.wrote ~= t.host and (gReg.job == nil or gReg.job.kind == "sync") then
		gReg.wrote = t.host
		if RegistrationSaved then pcall(RegistrationSaved) end
	end
end

local function SaveFavorite(t, gen, title, url, id, cb)
	Writing(t)
	local q = { { "action", "save" }, { "type", "http" }, { "title", title }, { "value", url } }
	if id then q[#q + 1] = { "id", id } end
	DoorBirdRequest(t, { path = "/bha-api/favorites.cgi?" .. QueryString(q), kind = "operator", gen = gen,
		label = "favorites.cgi save '" .. title .. "'" .. (id and (" (#" .. id .. ")") or " (new)") }, function(code, _, err, headers)
		cb(code == 200, code, err, HeaderValue(headers, "favoriteid"))
	end)
end

local function DeleteFavorite(t, gen, id, cb)
	DoorBirdRequest(t, { path = "/bha-api/favorites.cgi?" .. QueryString({ { "action", "remove" }, { "type", "http" }, { "id", id } }),
		kind = "operator", gen = gen, label = "favorites.cgi remove #" .. id }, function(code, _, err)
		cb(code == 200, code, err)
	end)
end

local function PostEntry(t, gen, entry, cb)
	Writing(t)
	local label = EntryLabel(EntryInput(entry), EntryParam(entry))
	DoorBirdRequest(t, { method = "POST", path = "/bha-api/schedule.cgi", kind = "operator", body = JsonEncode(entry), gen = gen,
		label = "schedule.cgi save " .. label .. " (" .. #Outputs(entry) .. " outputs)" }, function(code, _, err)
		cb(code == 200, code, err)
	end)
end

local function RemoveEntry(t, gen, input, param, cb)
	DoorBirdRequest(t, { path = "/bha-api/schedule.cgi?" .. QueryString({ { "action", "remove" }, { "input", input }, { "param", param } }),
		kind = "operator", gen = gen, label = "schedule.cgi remove " .. EntryLabel(input, param) }, function(code, _, err)
		cb(code == 200, code, err)
	end)
end

local function Persist()
	if RegistrationSaved then pcall(RegistrationSaved) end
end

local function SetSummary(state, summary)
	gReg.state, gReg.summary = state, summary or ""
	if RegistrationChanged then pcall(RegistrationChanged) end
end

local function WhyNot(code, err)
	if code == 401 then return "the DoorBird user lacks the API-Operator permission" end
	if code == 404 then return "this DoorBird has no favorites or schedules (firmware 000110 or newer is needed)" end
	if code == 507 then return "the DoorBird has no room for more (HTTP 507)" end
	if code and err then return "HTTP " .. code .. " - " .. err end
	if code then return "HTTP " .. code end
	return tostring(err or "no answer")
end

--[[------------------------------------------------------------------ Jobs
    One job at a time (a sync or a removal), never cut short: a write is
    always followed by its read back (and its put-back). The driver applies a
    new address or login only once the job on its way to the DoorBird has
    ended (RegistrationBusyWith). As a last guard, a job whose target's
    generation changed stops at its next step and sends nothing more.      ]]
local function StartJob(t, kind)
	local job = { t = t, gen = t.gen, host = t.host, kind = kind, problems = {}, changes = {} }
	gReg.busy, gReg.job = true, job
	return job
end

local function Current(job)
	return gReg.job == job and job.t.gen == job.gen
end

local function EndJob(job)
	if gReg.job ~= job then return false end
	gReg.busy, gReg.job = false, nil
	return true
end

-- A sync asked for during the job runs now, through the driver's own checks (RegistrationIdle)
local function RunDeferred()
	if gReg.again and not gReg.busy then
		gReg.again = false
		if RegistrationIdle then pcall(RegistrationIdle) end
	end
end

-- Runs fn(item, next) for each item in turn, then done(); stops when the job is no longer current
local function Each(job, list, fn, done)
	local i = 0
	local function step()
		if not Current(job) then return end
		i = i + 1
		if i > #list then return done() end
		fn(list[i], step)
	end
	step()
end

-- The other ports of this controller that favorites of other copies point at, probed in turn:
-- done(dead) with dead[port] = true where nothing answers
local function ProbeOrphanPorts(job, favs, ctx, done)
	local ports, seen, dead = {}, {}, {}
	for _, f in pairs(favs) do
		local orphan, port = IsOrphan(f, ctx)
		if not orphan and port and not seen[port] then
			seen[port] = true
			ports[#ports + 1] = port
		end
	end
	table.sort(ports)
	Each(job, ports, function(port, nextStep)
		EventServerProbe(ctx.ctrl, port, function(answers)
			if not answers then dead[port] = true end
			LogDebug("Port %d of this controller: %s", port, answers and "a copy of this driver may listen there, its favorites stay" or "nothing listens")
			nextStep()
		end)
	end, function() done(dead) end)
end

-- A job on its way to this target
function RegistrationBusyWith(t)
	return gReg.job ~= nil and gReg.job.t == t
end

--[[------------------------------------------------------------------ Writing entries
    job.targets: { input, param, create } in turn. Each one is read fresh,
    planned from that read (PlanChange), written, and checked against the
    next read (CheckChange), which is also the fresh read for the next one.
    An entry where another output went missing or changed is written back as
    it was read. done(entries) gets the last read, or nil when a read failed. ]]
local function SetProblem(job, input, param, text)
	for _, k in ipairs(job.keys or {}) do
		if KeyMatchesEntry(k, input, param) and not job.problems[k] then job.problems[k] = text end
	end
end

-- A write whose read back never came: the other outputs of the entry as it was then that are missing
-- now, put back (and this driver's output taken out: the DoorBird keeps one or the other)
local function PlanRepair(job, target, e)
	local before = target.repair
	local ck = EntryKey(target.input, target.param)
	if e and IsUnknownEntry(e) then return nil end
	local now = e and OthersOf(e, job.managed) or {}
	local counts, missing, names, seen = {}, {}, {}, {}
	for _, o in ipairs(Outputs(before)) do
		if not (OutputEvent(o) == "http" and job.managed[OutputParam(o)]) then
			local k = OtherKey(o)
			counts[k] = (counts[k] or 0) + 1
			if counts[k] > (now[k] or 0) then
				missing[#missing + 1] = JsonCopy(o)
				local what = DescribeOther(k, job.favs)
				if not seen[what] then
					seen[what] = true
					names[#names + 1] = what
				end
			end
		end
	end
	if #missing == 0 then
		-- Nothing was lost then
		job.unchecked[ck] = nil
		Persist()
		return nil
	end
	-- In the order the entry had then; outputs other apps added since go after
	local outputs, used = {}, {}
	local nowList = {}
	for _, o in ipairs(Outputs(e)) do
		if not (OutputEvent(o) == "http" and job.managed[OutputParam(o)]) then nowList[#nowList + 1] = o end
	end
	for _, o in ipairs(Outputs(before)) do
		if not (OutputEvent(o) == "http" and job.managed[OutputParam(o)]) then
			local k, found = OtherKey(o), nil
			for i, x in ipairs(nowList) do
				if not used[i] and OtherKey(x) == k then
					found = i
					break
				end
			end
			if found then used[found] = true end
			outputs[#outputs + 1] = JsonCopy(found and nowList[found] or o)
		end
	end
	for i, x in ipairs(nowList) do
		if not used[i] then outputs[#outputs + 1] = JsonCopy(x) end
	end
	local new = JsonCopy(e or before)
	new.output = outputs
	table.sort(names)
	return { input = target.input, param = target.param, new = new, before = e, wantIds = {}, repair = before, missing = names }
end

local function PlanChange(job, target, e)
	if target.repair then return PlanRepair(job, target, e) end
	local input, param = target.input, target.param
	local ck = EntryKey(input, param)
	local want, wantList = job.want(input, param)
	if e and IsUnknownEntry(e) then
		SetProblem(job, input, param, "the DoorBird's schedule entry for " .. EntryLabel(input, param) .. " has a form this driver does not know: left alone")
		return nil
	end
	if not e then
		if target.create and next(want) then
			local skip = job.skip and job.skip[ck]
			if skip and skip.sig == "" then
				SetProblem(job, input, param, skip.text)
				return nil
			end
			return { input = input, param = param, created = true, wantIds = want,
				new = JsonObject({ input = input, param = param, output = { NewOutput(wantList[1], {}) } }) }
		end
		return nil
	end
	local have = OwnIdsIn(e, job.managed)
	if SameSet(have, want) then return nil end
	local skip = job.skip and job.skip[ck]
	if skip and next(want) then
		if skip.sig == OthersSignature(e, job.managed) then
			SetProblem(job, input, param, skip.text)
			return nil
		end
		job.skip[ck] = nil -- its other outputs changed: one more try
	end
	local outputs, kept = {}, {}
	for _, o in ipairs(Outputs(e)) do
		local own = OutputEvent(o) == "http" and job.managed[OutputParam(o)]
		if not own then
			outputs[#outputs + 1] = JsonCopy(o)
		elseif want[OutputParam(o)] and not kept[OutputParam(o)] then
			kept[OutputParam(o)] = true
			outputs[#outputs + 1] = JsonCopy(o)
		end
	end
	for _, id in ipairs(wantList) do
		if not kept[id] then outputs[#outputs + 1] = NewOutput(id, Outputs(e)) end
	end
	if #outputs == 0 and job.created[ck] then
		return { input = input, param = param, remove = true, wantIds = {}, before = e }
	end
	local new = JsonCopy(e)
	new.output = outputs
	return { input = input, param = param, new = new, before = e, wantIds = want }
end

local function CheckChange(job, ch, entries)
	local now = FindEntry(entries, ch.input, ch.param)
	if ch.remove then
		ch.verified = (now == nil) or next(OwnIdsIn(now, job.managed)) == nil
		return
	end
	local before = ch.before and OthersOf(ch.before, job.managed) or {}
	local after = now and OthersOf(now, job.managed) or {}
	local dropped, seen = {}, {}
	for k, n in pairs(before) do
		if (after[k] or 0) < n then
			local what = DescribeOther(k, job.favs)
			if not seen[what] then
				seen[what] = true
				dropped[#dropped + 1] = what
			end
		end
	end
	table.sort(dropped)
	local have = now and OwnIdsIn(now, job.managed) or {}
	ch.harmed = #dropped > 0
	ch.dropped = dropped
	ch.verified = not ch.harmed and SameSet(have, ch.wantIds)
	if ch.harmed then
		LogWarn("The DoorBird changed %s in %s when this driver's HTTP call was written: putting the entry back as it was",
			table.concat(dropped, ", "), EntryLabel(ch.input, ch.param))
	elseif not ch.verified and ch.ok then
		LogWarn("Schedule %s: the DoorBird did not keep this driver's HTTP call as written", EntryLabel(ch.input, ch.param))
	end
end

local function ApplyChanges(job, done)
	local t = job.t
	local i, pending = 0, nil
	local nextChange
	local function readThen(fn)
		ReadSchedule(t, job.gen, function(entries, code, err)
			if not Current(job) then return end
			if not entries then
				job.readError = "the schedule could not be read back: " .. WhyNot(code, err)
				LogWarn("DoorBird events: %s", job.readError)
				if pending then
					pending.verified, pending.unchecked = false, true
					-- Checked at the next chance, against the entry as it was before this write
					if pending.before and not pending.remove and not pending.repair and job.unchecked then
						job.unchecked[EntryKey(pending.input, pending.param)] = pending.before
						Persist()
					end
				end
				return done(nil)
			end
			fn(entries)
		end)
	end
	nextChange = function(entries)
		if not Current(job) then return end
		if pending then
			local ch = pending
			pending = nil
			CheckChange(job, ch, entries)
			if ch.repair then
				local ck = EntryKey(ch.input, ch.param)
				local now = FindEntry(entries, ch.input, ch.param)
				local have, back = now and OthersOf(now, job.managed) or {}, true
				for k, n in pairs(OthersOf(ch.repair, job.managed)) do
					if (have[k] or 0) < n then back = false end
				end
				if back then
					job.unchecked[ck] = nil
					ch.repaired = true
					local text = "the DoorBird keeps one HTTP call for " .. EntryLabel(ch.input, ch.param) .. ", and " .. table.concat(ch.missing, ", ") .. " has it"
					LogWarn("Put back %s in %s: the DoorBird had dropped it when this driver's HTTP call was written (it could not be checked then)",
						table.concat(ch.missing, ", "), EntryLabel(ch.input, ch.param))
					if job.skip then job.skip[ck] = { sig = OthersSignature(now, job.managed), text = text } end
					SetProblem(job, ch.input, ch.param, text)
				else
					LogError("Putting back %s in %s did not work: it is tried again at the next check", table.concat(ch.missing, ", "), EntryLabel(ch.input, ch.param))
				end
				Persist()
			end
			if ch.harmed and ch.before and not ch.repair then
				return PostEntry(t, job.gen, ch.before, function(ok, code, err)
					ch.restored = ok
					if not ok then LogError("Putting %s back failed: %s", EntryLabel(ch.input, ch.param), WhyNot(code, err)) end
					readThen(nextChange)
				end)
			end
		end
		i = i + 1
		local target = job.targets[i]
		if not target then return done(entries) end
		local ch = PlanChange(job, target, FindEntry(entries, target.input, target.param))
		if not ch then return nextChange(entries) end
		job.changes[#job.changes + 1] = ch
		-- Created from a read that showed no such entry: this driver's from the moment it is sent (a
		-- whole entry is only ever removed when nothing else is in it)
		if ch.created then
			job.created[EntryKey(ch.input, ch.param)] = true
			if RegistrationSaved then pcall(RegistrationSaved) end
		end
		local function after(ok, code, err)
			ch.ok, ch.code, ch.err = ok, code, err
			if not ok then LogWarn("Schedule %s: %s", EntryLabel(ch.input, ch.param), WhyNot(code, err)) end
			pending = ch
			readThen(nextChange)
		end
		if ch.remove then RemoveEntry(t, job.gen, ch.input, ch.param, after) else PostEntry(t, job.gen, ch.new, after) end
	end
	if #job.targets == 0 then return done(job.entries) end
	readThen(nextChange)
end

-- The entries (from a read) that need a change, and the entries to create
local function Targets(job, entries, creatable)
	local targets = {}
	local repairs = {}
	for ck, before in pairs(job.unchecked or {}) do repairs[#repairs + 1] = ck end
	table.sort(repairs)
	for _, ck in ipairs(repairs) do
		local before = job.unchecked[ck]
		targets[#targets + 1] = { input = EntryInput(before), param = EntryParam(before), repair = before }
	end
	for _, e in ipairs(entries) do
		if PlanChange(job, { input = EntryInput(e), param = EntryParam(e) }, e) then
			targets[#targets + 1] = { input = EntryInput(e), param = EntryParam(e) }
		end
	end
	for _, c in ipairs(creatable or {}) do targets[#targets + 1] = c end
	return targets
end

--[[------------------------------------------------------------------ Sync
    RegistrationSync(t, ctx, done)
    ctx: { ctrl = controller IP, port = event server port, token, relays = info.cgi relays }
    done(ok): ok when every event is registered.                           ]]
local function Finish(job, ok, state, summary)
	if not EndJob(job) then return end
	gReg.lastSync = os.time()
	if state then SetSummary(state, summary) end
	if job.done then pcall(job.done, ok) end
	RunDeferred()
end

local function Fail(job, code, err, what)
	if not Current(job) then return end
	local why = WhyNot(code, err)
	gReg.lastError = (what and (what .. ": ") or "") .. why
	LogWarn("DoorBird events: %s", gReg.lastError)
	Finish(job, false, (code == 401 and job.t.verified) and "refused" or "failed", why)
end

local function Results(job, saves, drops, entries, after)
	local t = job.t
	for _, ch in ipairs(job.changes) do
		local ck = EntryKey(ch.input, ch.param)
		if ch.created and ch.verified == false and not ch.unchecked and after and not FindEntry(after, ch.input, ch.param) then
			-- Not there after all: nothing of this driver's to remember
			gReg.created[ck] = nil
		end
		if ch.remove and ch.ok and ch.verified then gReg.created[ck] = nil end
		if ch.repair then
			-- Reported where it was put back
		elseif ch.unchecked and not ch.remove then
			SetProblem(job, ch.input, ch.param, job.readError or "could not be checked")
		elseif not ch.verified and not ch.remove and ch.verified ~= nil then
			local label = EntryLabel(ch.input, ch.param)
			local text
			if ch.harmed then
				text = "the DoorBird keeps one HTTP call for " .. label .. ", and " .. table.concat(ch.dropped, ", ") .. " has it"
			elseif not ch.ok and (ch.code == 400 or ch.created) then
				text = "the DoorBird does not take a schedule for " .. label .. " (" .. WhyNot(ch.code, ch.err) .. ")"
			elseif ch.ok then
				text = "the DoorBird did not keep the HTTP call for " .. label
			else
				text = "the HTTP call for " .. label .. " could not be written (" .. WhyNot(ch.code, ch.err) .. ")"
			end
			-- Taken by another app, refused, or not kept: left alone until its other outputs change
			-- (or Reconnect)
			if ch.harmed or ch.ok or ch.code == 400 then
				gReg.skip[ck] = { sig = OthersSignature(ch.before, job.managed), text = text }
			end
			SetProblem(job, ch.input, ch.param, text)
		end
	end
	gReg.favorites = {}
	for k, id in pairs(job.own) do gReg.favorites[k] = id end
	gReg.host = job.host
	gReg.entries = after or entries
	-- Where each event is registered now
	gReg.registered = {}
	for _, k in ipairs(job.keys) do
		local where = {}
		local id = job.own[k]
		for _, e in ipairs(gReg.entries) do
			if id and KeyMatchesEntry(k, EntryInput(e), EntryParam(e)) and OwnIdsIn(e, { [id] = true })[id] then
				where[#where + 1] = EntryLabel(EntryInput(e), EntryParam(e))
			end
		end
		if #where > 0 then
			gReg.registered[k] = where
			job.problems[k] = nil
		elseif not job.problems[k] then
			job.problems[k] = after and "not registered" or job.readError
		end
	end
	gReg.keys = job.keys
	gReg.problems = job.problems
	gReg.lastError = job.readError
	Persist()
	local okCount, names, bad = 0, {}, {}
	for _, k in ipairs(job.keys) do
		if gReg.registered[k] then
			okCount = okCount + 1
			names[#names + 1] = KeyLabel(k)
		else
			bad[#bad + 1] = KeyLabel(k)
		end
	end
	local summary = "registered: " .. (#names > 0 and table.concat(names, ", ") or "none")
	if #bad > 0 then summary = summary .. " - not registered: " .. table.concat(bad, ", ") end
	local changed = #saves + #job.changes + #drops
	if changed > 0 then
		LogInfo("DoorBird events %s (%d change%s) at %s", summary, changed, changed == 1 and "" or "s", t.host)
	else
		LogDebug("DoorBird events checked: %s", summary)
	end
	Finish(job, #bad == 0, #bad == 0 and "ok" or (okCount > 0 and "partial" or "failed"), summary)
end

function RegistrationSync(t, ctx, done)
	if gReg.busy then
		gReg.again = true
		return
	end
	local job = StartJob(t, "sync")
	job.done, job.ctx = done, ctx
	job.created, job.skip, job.unchecked = gReg.created, gReg.skip, gReg.unchecked
	SetSummary("working", "checking the DoorBird's HTTP calls")
	ReadFavorites(t, job.gen, function(favs, code, err, sipCount)
		if not Current(job) then return end
		if not favs then return Fail(job, code, err, "favorites") end
		job.favs = favs
		gReg.favs, gReg.sipCount = favs, sipCount or 0
		ProbeOrphanPorts(job, favs, ctx, function(dead)
			if not Current(job) then return end
			ReadSchedule(t, job.gen, function(entries, scode, serr)
				if not Current(job) then return end
				if not entries then return Fail(job, scode, serr, "schedule") end
				job.entries = entries
				job.keys = DesiredKeys(entries, ctx.relays)
				if RegistrationKeysFound then pcall(RegistrationKeysFound, job.keys) end
				-- This driver's favorites by key; duplicates, old keys and orphans go
				job.own, job.drop = {}, {}
				local ids = {}
				for id in pairs(favs) do ids[#ids + 1] = id end
				SortParams(ids)
				local wanted = {}
				for _, k in ipairs(job.keys) do wanted[k] = true end
				for _, id in ipairs(ids) do
					local f = favs[id]
					local key = OwnFavoriteKey(f.value, ctx.token)
					if key and wanted[key] and not job.own[key] then
						job.own[key] = id
					elseif key then
						job.drop[#job.drop + 1] = id
					elseif IsOrphan(f, ctx, dead) then
						LogInfo("Removing '%s' (#%s): an earlier copy of this driver made it", f.title, id)
						job.drop[#job.drop + 1] = id
					end
				end
				-- Save the favorites that are missing or point at an old address
				local saves = {}
				for _, k in ipairs(job.keys) do
					local url, title = KeyUrl(ctx, k), KeyTitle(k)
					local id = job.own[k]
					if not id or favs[id].value ~= url or favs[id].title ~= title then
						saves[#saves + 1] = { key = k, url = url, title = title, id = id }
					end
				end
				local needReread = false
				Each(job, saves, function(s, nextStep)
					SaveFavorite(t, job.gen, s.title, s.url, s.id, function(ok, fcode, ferr, newId)
						if not Current(job) then return end
						if not ok then
							job.problems[s.key] = "the HTTP call could not be saved: " .. WhyNot(fcode, ferr)
							LogWarn("Saving '%s': %s", s.title, WhyNot(fcode, ferr))
						elseif s.id then
							favs[s.id] = { title = s.title, value = s.url }
						elseif newId and tostring(newId) ~= "" then
							job.own[s.key] = tostring(newId)
							favs[tostring(newId)] = { title = s.title, value = s.url }
						else
							needReread = true
						end
						nextStep()
					end)
				end, function()
					local function plan()
						job.managed = {}
						for _, id in pairs(job.own) do job.managed[id] = true end
						for _, id in ipairs(job.drop) do job.managed[id] = true end
						job.want = function(input, param)
							local want, list = {}, {}
							for _, k in ipairs(job.keys) do
								local id = job.own[k]
								if id and KeyMatchesEntry(k, input, param) and not want[id] then
									want[id] = true
									list[#list + 1] = id
								end
							end
							return want, list
						end
						-- Entries the DoorBird does not have yet (a relay, a first doorbell button, motion)
						local creatable = {}
						for _, k in ipairs(job.keys) do
							if job.own[k] then
								local found = false
								for _, e in ipairs(entries) do
									if KeyMatchesEntry(k, EntryInput(e), EntryParam(e)) then found = true end
								end
								if not found then
									local input, param = CreatableEntry(k)
									if input then
										creatable[#creatable + 1] = { input = input, param = param, create = true }
									elseif not job.problems[k] then
										job.problems[k] = "the DoorBird has no " .. KeyLabel(k) .. " in its schedule"
									end
								end
							end
						end
						job.targets = Targets(job, entries, creatable)
						ApplyChanges(job, function(after)
							if not Current(job) then return end
							-- The favorites that go: only once a read shows none of them in the schedule
							local drops = {}
							for _, id in ipairs(after and job.drop or {}) do
								local still = false
								for _, e in ipairs(after) do
									if OwnIdsIn(e, { [id] = true })[id] then still = true end
								end
								if still then
									LogWarn("Favorite #%s is still in the schedule: not deleting it now", id)
								else
									drops[#drops + 1] = id
								end
							end
							if not after and #job.drop > 0 then LogWarn("Not deleting old favorites now: the schedule could not be read back") end
							local function results() Results(job, saves, drops, entries, after) end
							if #drops == 0 then return results() end
							-- Read once more right before deleting: a favorite still in the schedule is not deleted
							ReadSchedule(t, job.gen, function(fresh)
								if not Current(job) then return end
								local sure = {}
								for _, id in ipairs(drops) do
									local still = not fresh
									for _, e in ipairs(fresh or {}) do
										if OwnIdsIn(e, { [id] = true })[id] then still = true end
									end
									if not still then sure[#sure + 1] = id end
								end
								drops = sure
								Each(job, drops, function(id, nextStep)
									DeleteFavorite(t, job.gen, id, function() nextStep() end)
								end, results)
							end)
						end)
					end
					if not needReread then return plan() end
					ReadFavorites(t, job.gen, function(again, rcode, rerr)
						if not Current(job) then return end
						if not again then return Fail(job, rcode, rerr, "favorites") end
						favs = again
						job.favs = again
						gReg.favs = again
						for id, f in pairs(again) do
							local key = OwnFavoriteKey(f.value, ctx.token)
							if key and wanted[key] and not job.own[key] then job.own[key] = id end
						end
						plan()
					end)
				end)
			end)
		end)
	end)
end

--[[------------------------------------------------------------------ Remove
    RegistrationRemove(t, token, done, why, created): this driver's outputs out
    of the schedule (an entry it created and holds alone goes whole), then its
    favorites, once a read shows none of them is in the schedule any more.
    done(ok, count, err).
    created: the entries this driver created on that DoorBird; nil for the
    current one (gReg.created, cleared once it is left).                    ]]
function RegistrationRemove(t, token, done, why, created, unchecked)
	if gReg.busy then
		-- After the job on its way
		SetTimer("REG_REMOVE_LATER_" .. t.host, 2000, function() RegistrationRemove(t, token, done, why, created, unchecked) end)
		return
	end
	local current = created == nil
	local job = StartJob(t, "remove")
	job.created = created or gReg.created
	job.unchecked = unchecked or gReg.unchecked
	LogInfo("Removing this driver's HTTP calls from the DoorBird at %s (%s)", t.host, why or "")
	local function finish(ok, count, err)
		if not EndJob(job) then return end
		if ok and current then
			gReg.favorites, gReg.registered, gReg.problems = {}, {}, {}
			gReg.created = {}
			if gReg.wrote == t.host then gReg.wrote = nil end
			Persist()
		elseif err and current then
			gReg.lastError = err
		end
		if done then pcall(done, ok, count or 0, err) end
		RunDeferred()
	end
	ReadFavorites(t, job.gen, function(favs, code, err)
		if not Current(job) then return end
		if not favs then return finish(false, 0, WhyNot(code, err)) end
		local own, ids = {}, {}
		for id, f in pairs(favs) do
			if OwnFavoriteKey(f.value, token) then
				own[id] = true
				ids[#ids + 1] = id
			end
		end
		SortParams(ids)
		ReadSchedule(t, job.gen, function(entries, scode, serr)
			if not Current(job) then return end
			if not entries then return finish(false, 0, WhyNot(scode, serr)) end
			job.managed, job.favs, job.entries = own, favs, entries
			job.want = function() return {}, {} end
			job.targets = Targets(job, entries, nil)
			ApplyChanges(job, function(after)
				if not Current(job) then return end
				if not after then return finish(false, 0, job.readError or "the schedule could not be read back") end
				if next(job.unchecked) then return finish(false, 0, "an entry could not be put back yet") end
				-- Read once more right before deleting: favorites are deleted only when none is in the schedule
				ReadSchedule(t, job.gen, function(fresh, fcode, ferr)
				if not Current(job) then return end
				if not fresh then return finish(false, 0, WhyNot(fcode, ferr)) end
				local left = 0
				for _, e in ipairs(fresh) do
					if next(OwnIdsIn(e, own)) then left = left + 1 end
				end
				if left > 0 then
					return finish(false, 0, left .. " schedule entr" .. (left == 1 and "y still has" or "ies still have") .. " this driver's HTTP calls")
				end
				local deleted = 0
				Each(job, ids, function(id, nextStep)
					DeleteFavorite(t, job.gen, id, function(ok)
						if ok then deleted = deleted + 1 end
						nextStep()
					end)
				end, function()
					LogInfo("Removed %d HTTP call%s from the DoorBird at %s", deleted, deleted == 1 and "" or "s", t.host)
					finish(deleted == #ids, deleted, deleted == #ids and nil or "some favorites could not be deleted")
				end)
				end)
			end)
		end)
	end)
end

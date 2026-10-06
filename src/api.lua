--[[=============================================================================
    DirectorLink DoorBird - LAN API client
    HTTP requests to a DoorBird ("target") with the dedicated user's login.

    A target is a table made by NewTarget({ host, user, pass, name }).

    The DoorBird's rules (LAN API 0.36, "Concurrent connections and rate
    limits"), which also protect the official DoorBird driver on the same
    controller:
      - one API connection at a time, at most one per second: requests wait
        in a queue and start at least API_MIN_GAP_MS apart;
      - wrong logins make it block the controller's address (or the user) for
        a minute (HTTP 423). So a refused login stops every request to that
        target until the login changes or Reconnect runs: the official driver
        on the same controller is never locked out by this one;
      - 204 means the user lacks a permission (Watch Always, History,
        Motion); 401 on favorites.cgi and schedule.cgi means it lacks
        API-Operator, once the same login has worked (until then a 401 is
        a refused login, whatever the request).

    A new address or login starts a new "generation": what waits in the
    queue, what is on its way and every request made for the old one are
    answered "cancelled" and never reach the new DoorBird.

    Logs show the method, the path (or a label), the answer and the time. The
    password travels only in the Authorization header and is never logged;
    the favorites' URLs (the event token, other apps' logins) never are.

    Copyright 2026 DirectorLink
    SPDX-License-Identifier: Apache-2.0
===============================================================================]]

API_MIN_GAP_MS = 1000
API_TIMEOUT_S = 10
API_LOCKOUT_S = 65
API_HISTORY = 20

function NewTarget(t)
	t = t or {}
	t.host = trim(t.host or "")
	t.user = trim(t.user or "")
	t.pass = t.pass or ""
	t.name = t.name or "DoorBird"
	t.authFailed = false
	t.verified = false -- this login has had a 2xx answer
	t.gen = 1          -- a new address or login: a new generation
	t.lockedUntil = 0  -- NowMs() until which the DoorBird blocks this controller (423)
	t.queue = {}
	t.busy = false
	t.inflight = false -- a request sent and not answered yet
	t.lastStartMs = 0
	t.history = {}
	t.requests, t.failures = 0, 0
	RegisterSecret(t.pass)
	return t
end

-- New login or address: a new generation (nothing made for the old one is sent); a refused login
-- may be tried again (once)
function SetTargetLogin(t, host, user, pass)
	host, user, pass = trim(host or ""), trim(user or ""), pass or ""
	if t.host == host and t.user == user and t.pass == pass then return false end
	TargetCancelQueue(t, "cancelled: the login changed")
	t.host, t.user, t.pass = host, user, pass
	t.verified = false
	RegisterSecret(pass)
	SetTargetAuthFailed(t, false)
	return true
end

function SetTargetAuthFailed(t, failed)
	if t.authFailed == failed then return end
	t.authFailed = failed
	if failed then
		LogError("The DoorBird at %s refused the login of user '%s': no more requests until the Username or Password changes (or Reconnect runs)", t.host, t.user)
	end
	if t.onAuthChange then pcall(t.onAuthChange, t, failed) end
end

function TargetReady(t)
	return ValidAddress(t.host) and t.user ~= "" and t.pass ~= ""
end

function HeaderValue(headers, name)
	if type(headers) ~= "table" then return nil end
	name = string.lower(name)
	for k, v in pairs(headers) do
		if string.lower(tostring(k)) == name then
			if type(v) == "table" then return v[1] end
			return v
		end
	end
	return nil
end

local function Remember(t, entry)
	table.insert(t.history, 1, entry)
	while #t.history > API_HISTORY do table.remove(t.history) end
end

local RunNext -- forward

local function Send(t, job)
	local opts, cb = job.opts, job.cb
	if job.gen ~= t.gen then
		-- Made for an earlier address or login: never sent
		local ok, err = pcall(cb, nil, nil, "cancelled: the login changed")
		if not ok then LogError("Callback failed: %s", err) end
		t.busy = false
		return RunNext(t)
	end
	local finished = false
	local guard
	local started = NowMs()
	t.lastStartMs = started
	t.requests = t.requests + 1
	local label = opts.label or opts.path
	local function finish(code, body, err, headers)
		if finished then return end
		finished = true
		t.inflight = false
		if guard then pcall(function() guard:Cancel() end) end
		local ms = NowMs() - started
		if job.gen ~= t.gen then
			-- The answer of an earlier address or login: not for this one
			code, body, err, headers = nil, nil, "cancelled: the login changed", nil
		end
		local size = type(body) == "string" and #body or 0
		if err and not code then t.failures = t.failures + 1 end
		Remember(t, { at = os.time(), method = opts.method, label = label, code = code, ms = ms, err = err })
		if code then
			LogDebug("%s %s -> %d in %d ms%s", opts.method, label, code, ms, size > 0 and (" (" .. ByteSize(size) .. ")") or "")
		else
			LogDebug("%s %s -> no answer after %d ms: %s", opts.method, label, ms, tostring(err))
		end
		local ok, cbErr = pcall(cb, code, body, err, headers, ms)
		if not ok then LogError("Callback of %s failed: %s", label, cbErr) end
		t.busy = false
		RunNext(t)
	end
	local ok, err = pcall(function()
		guard = C4:SetTimer(((opts.timeout or API_TIMEOUT_S) + 5) * 1000, function() finish(nil, nil, "no answer") end)
	end)
	if not ok then LogDebug("Request guard timer: %s", tostring(err)) end
	local url = "http://" .. t.host .. opts.path
	local headers = {
		["Authorization"] = "Basic " .. Base64Encode(t.user .. ":" .. t.pass),
		["User-Agent"] = UserAgent(),
		["Accept"] = opts.accept or "*/*",
	}
	if opts.body then headers["Content-Type"] = opts.contentType or "application/json" end
	LogTrace("%s %s (sending)", opts.method, label)
	t.inflight = true
	local sent, sendErr = pcall(function()
		local x = C4:url()
		x:SetOptions({ fail_on_error = false, timeout = opts.timeout or API_TIMEOUT_S, connect_timeout = 5 })
		x:OnDone(function(_, responses, errCode, errMsg)
			local resp = responses and responses[#responses]
			if (errCode ~= nil and errCode ~= 0) or resp == nil then
				return finish(nil, nil, errMsg or ("transfer error " .. tostring(errCode)))
			end
			if job.gen ~= t.gen then return finish(nil, nil, "cancelled: the login changed") end
			local code = tonumber(resp.code) or 0
			local body = resp.body or ""
			if code == 401 then
				-- favorites.cgi and schedule.cgi answer 401 to a login without API-Operator; a login
				-- that never worked is taken as refused, whatever the request
				if opts.kind == "operator" and t.verified then
					return finish(401, body, "no API-Operator permission", resp.headers)
				end
				SetTargetAuthFailed(t, true)
				return finish(401, body, "login refused", resp.headers)
			end
			if code == 423 then
				t.lockedUntil = NowMs() + API_LOCKOUT_S * 1000
				LogError("The DoorBird blocks requests from this controller for a minute (HTTP 423, too many wrong logins)")
				return finish(423, body, "the DoorBird blocks this controller for a minute", resp.headers)
			end
			if code >= 200 and code < 300 then
				t.verified = true
				SetTargetAuthFailed(t, false)
			end
			finish(code, body, nil, resp.headers)
		end)
		if opts.method == "POST" then
			x:Post(url, opts.body or "", headers)
		else
			x:Get(url, headers)
		end
	end)
	if not sent then finish(nil, nil, tostring(sendErr)) end
end

RunNext = function(t)
	if t.busy then return end
	local job = table.remove(t.queue, 1)
	if not job then return end
	-- Checked when the request's turn comes: an earlier answer may have changed them
	local refuse
	if job.gen ~= t.gen then
		refuse = "cancelled: the login changed"
	elseif not ValidAddress(t.host) then
		refuse = "the DoorBird's address is not set"
	elseif t.user == "" or t.pass == "" then
		refuse = "the DoorBird's username or password is not set"
	elseif t.authFailed and not job.opts.force then
		refuse = "the DoorBird refused this login"
	elseif NowMs() < t.lockedUntil and not job.opts.force then
		refuse = "the DoorBird blocks this controller for a minute"
	end
	if refuse then
		local ok, err = pcall(job.cb, nil, nil, refuse)
		if not ok then LogError("Callback failed: %s", err) end
		return RunNext(t)
	end
	t.busy = true
	local wait = API_MIN_GAP_MS - (NowMs() - t.lastStartMs)
	if wait <= 0 then
		Send(t, job)
	else
		local ok = pcall(function()
			C4:SetTimer(wait, function() Send(t, job) end)
		end)
		if not ok then Send(t, job) end
	end
end

--[[ DoorBirdRequest(t, opts, cb)
     opts: method ("GET"/"POST"), path ("/bha-api/info.cgi?..."), body, label (what the log shows
     instead of the path), kind ("operator" for favorites.cgi and schedule.cgi), priority (go first:
     a door to open), force (even after a refused login), timeout (s), accept, gen (the generation
     the request belongs to: refused at once when the login changed since).
     cb(code, body, err, headers, ms): code nil when there was no answer.                 ]]
function DoorBirdRequest(t, opts, cb)
	opts.method = opts.method or "GET"
	local job = { opts = opts, cb = cb or function() end, gen = opts.gen or t.gen }
	if job.gen ~= t.gen then
		local ok, err = pcall(job.cb, nil, nil, "cancelled: the login changed")
		if not ok then LogError("Callback failed: %s", err) end
		return
	end
	if opts.priority then
		local i = 1
		while t.queue[i] and t.queue[i].opts.priority do i = i + 1 end
		table.insert(t.queue, i, job)
	else
		t.queue[#t.queue + 1] = job
	end
	RunNext(t)
end

-- Requests waiting (not counting the one on its way)
function TargetQueueLength(t)
	return #t.queue
end

-- A new generation: what waits is answered "cancelled", what is on its way is too when it comes
-- back, and requests made for the old generation are never sent
function TargetCancelQueue(t, why)
	t.gen = t.gen + 1
	local q = t.queue
	t.queue = {}
	for _, job in ipairs(q) do pcall(job.cb, nil, nil, why or "cancelled") end
end

--[[------------------------------------------------------------------ Answers ]]
-- BHA.VERSION[1] of info.cgi as a table, or nil and why
function ParseInfo(body)
	local doc, err = JsonDecode(body or "")
	if type(doc) ~= "table" then return nil, "not JSON (" .. tostring(err) .. ")" end
	local bha = JsonField(doc, "BHA")
	if type(bha) ~= "table" then return nil, "no BHA object" end
	if tostring(JsonField(bha, "RETURNCODE") or "") ~= "1" then return nil, "RETURNCODE " .. tostring(JsonField(bha, "RETURNCODE")) end
	local v = JsonField(bha, "VERSION")
	v = type(v) == "table" and v[1] or nil
	if type(v) ~= "table" then return nil, "no VERSION" end
	local info = {
		firmware = tostring(JsonField(v, "FIRMWARE") or ""),
		build = tostring(JsonField(v, "BUILD_NUMBER") or ""),
		mac = tostring(JsonField(v, "PRIMARY_MAC_ADDR") or JsonField(v, "WIFI_MAC_ADDR") or ""),
		wifiMac = tostring(JsonField(v, "WIFI_MAC_ADDR") or ""),
		model = tostring(JsonField(v, "DEVICE-TYPE") or ""),
		relays = {},
	}
	local relays = JsonField(v, "RELAYS")
	if type(relays) == "table" then
		for _, r in ipairs(relays) do
			if type(r) == "string" or type(r) == "number" then info.relays[#info.relays + 1] = tostring(r) end
		end
	end
	return info
end

-- A peripheral relay is "<door controller id>@<relay>", e.g. "gggaaa@1"
function IsPeripheralRelay(r)
	return string.find(tostring(r), "@", 1, true) ~= nil
end

-- Firmware "000125" -> 125
function FirmwareNumber(fw)
	return tonumber(string.match(tostring(fw or ""), "(%d+)")) or 0
end

-- The http favorites of favorites.cgi: { [id] = { title, value } }, or nil and why. An empty answer
-- is no favorites (nothing is ever deleted on the strength of a favorites list alone).
-- A "doorbell" entry that is a keypad code (4 or more digits, or a leading zero), not a bell button
function IsKeypadCode(param)
	param = tostring(param or "")
	return string.match(param, "^%d%d%d%d+$") ~= nil or string.match(param, "^0%d+$") ~= nil
end

-- A keypad code in a favorite of this driver or of an earlier copy (its address or its title): never in
-- a log from here on
local function RegisterFavoriteCodes(title, value)
	local q = string.match(value, "^%a+://[^/?#]+/doorbird%?([^#]*)")
	if q then
		local e, p = QueryValue(q, "e"), QueryValue(q, "p")
		if (e == "keypad" or e == "doorbell") and IsKeypadCode(p) then RegisterCode(p) end
	end
	local c = string.match(title, "^DirectorLink %(keypad code (%d+)%)$") or string.match(title, "^DirectorLink %(doorbell (%d+)%)$")
	if c and IsKeypadCode(c) then RegisterCode(c) end
end

function ParseFavorites(body)
	if body == nil or trim(body) == "" then return {}, nil, 0 end
	local doc, err = JsonDecode(body)
	if not JsonIsObject(doc) then return nil, "not a JSON object (" .. tostring(err or "a list") .. ")" end
	local out = {}
	local http = JsonField(doc, "http")
	if type(http) == "table" and next(http) ~= nil and not JsonIsObject(http) then
		return nil, "the HTTP favorites are in a form this driver does not know"
	end
	if type(http) == "table" then
		for id, f in pairs(http) do
			if type(f) == "table" then
				out[tostring(id)] = { title = tostring(JsonField(f, "title") or ""), value = tostring(JsonField(f, "value") or "") }
				RegisterFavoriteCodes(out[tostring(id)].title, out[tostring(id)].value)
			end
		end
	end
	local sip = JsonField(doc, "sip")
	local sipCount = 0
	if type(sip) == "table" then
		for _ in pairs(sip) do sipCount = sipCount + 1 end
	end
	return out, nil, sipCount
end

-- Entries whose form this driver does not know (an "output" that is not a list): never written
local gUnknownEntries = setmetatable({}, { __mode = "k" })

function IsUnknownEntry(e)
	return gUnknownEntries[e] == true
end

-- The entries of schedule.cgi (each { input, param, output = { ... } } as the DoorBird sent it), or nil
-- and why. Only a JSON list counts: an empty answer is "not read", never "no entries" (the driver
-- decides what to create and what to delete from it).
function ParseSchedule(body)
	if body == nil or trim(body) == "" then return nil, "an empty answer" end
	local doc, err = JsonDecode(body)
	if type(doc) ~= "table" then return nil, "not JSON (" .. tostring(err) .. ")" end
	if JsonIsObject(doc) then return nil, "not a list" end
	local out = {}
	for _, e in ipairs(doc) do
		if JsonIsObject(e) and JsonField(e, "input") then
			local o = JsonField(e, "output")
			if type(o) ~= "table" or o == JSON_NULL or (next(o) ~= nil and JsonIsObject(o)) then gUnknownEntries[e] = true end
			-- A keypad code or an RFID tag opens the door: never in a log from here on
			local input, param = tostring(JsonField(e, "input")), tostring(JsonField(e, "param") or "")
			if (input == "doorbell" and IsKeypadCode(param)) or input == "rfid" then RegisterCode(param) end
			out[#out + 1] = e
		end
	end
	return out
end

function EntryInput(e) return tostring(JsonField(e, "input") or "") end
function EntryParam(e) return tostring(JsonField(e, "param") or "") end
function EntryKey(input, param) return tostring(input) .. "|" .. tostring(param or "") end

-- "doorbell 1", "motion", "RFID 0012345", "relay 1"
function EntryLabel(input, param)
	if input == "rfid" then return "RFID" .. ((param or "") ~= "" and (" " .. param) or "") end
	return input .. ((param or "") ~= "" and (" " .. param) or "")
end

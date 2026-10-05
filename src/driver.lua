--[[=============================================================================
    DirectorLink · DoorBird for Control4 - DriverWorks driver
    https://directorlink.io/drivers/doorbird

    One DoorBird video door station (DoorBird D10x, D11x, D21x, BirdGuard)
    on Control4, the way Home Assistant's DoorBird integration works with the
    DoorBird's official LAN API:
      - info.cgi on connect: model, firmware, MAC, relays (with the relays of
        paired I/O door controllers);
      - events: a small HTTP server on the controller, and an HTTP favorite on
        the DoorBird for each event (each doorbell button, motion, RFID, each
        relay), attached to the DoorBird's schedule (registration.lua);
      - pictures: image.cgi live, history.cgi for the last ring and motion;
      - live video: RTSP H.264 (port 554, or RTSP over HTTP on 8557), MJPEG
        video.cgi as the fallback, through Control4's camera proxy;
      - open-door.cgi for each relay (a pulse: a relay is never held) and
        light-on.cgi for the IR light.

    The installer makes a DoorBird user for Control4 (API-Operator, Watch
    Always, History, Motion) and enters its login in the driver's properties.
    Control4 Intercom and audio/SIP are not part of this driver.

    DirectorLink camera agreement v1: variables DIRECTORLINK_CAMERA = "1" and
    DIRECTORLINK_CAMERA_KIND = "doorbell"; a doorbell press sets LAST_RING
    (ISO 8601 UTC), then fires "Ring"; a motion alert sets LAST_ALERT =
    "Motion", then fires "Alert".

    Copyright 2026 DirectorLink
    SPDX-License-Identifier: Apache-2.0
    DirectorLink is an independent project, not affiliated with Control4 or Snap One.
    Not affiliated with or endorsed by Bird Home Automation. Product names are trademarks of their owners.
===============================================================================]]

local CAMERA_PROXY = 5001
LOG_PREFIX = "DoorBird"
HEALTH_MS = 60000             -- info.cgi once a minute: online or not
RESYNC_S = 1800               -- the HTTP calls are checked again every 30 minutes
OFFLINE_AFTER = 2             -- failed checks in a row before the DoorBird counts as offline
REPEAT_HOLD_S = 5             -- the same event again within this time is a repeat (one press, one ring)
PICTURE_WAIT_MS = 1500        -- Ring and Alert wait this long for their picture (Picture With Events)
RELAY_SHOWN_CLOSED_MS = 1000  -- a relay connection shows CLOSED this long after a pulse
RELAY_DEBOUNCE_S = 2          -- a second pulse for the same relay within this time is not sent
OLD_RETRY_S = 900             -- leaving an old DoorBird that did not answer: tried again this often
OLD_RETRY_MAX = 96            -- for a day
EVENT_PORT_BASE = 47300
BUTTON_EVENT_BASE, RELAY_EVENT_BASE, RELAY_BINDING_BASE = 100, 200, 300
RTSP_PATH = "mpeg/media.amp"
SNAPSHOT_PATH = "bha-api/image.cgi"
MJPEG_PATH = "bha-api/video.cgi"
SAVED_VARS = { "LAST_ALERT", "LAST_RING", "LAST_MOTION", "LAST_DOORBELL", "LAST_RFID", "LAST_RELAY", "LAST_DOOR_OPENED", "LAST_EVENT" }

--[[=============================================================================
    State
===============================================================================]]
gBird = NewTarget({ name = "DoorBird" })

gInfo = { model = "", firmware = "", build = "", mac = "", relays = {}, at = nil }

-- nil = not known yet, true / false, or "empty" (a history with no picture)
gPerm = { operator = nil, watch = nil, history = nil, motion = nil, checkedAt = nil }

gState = {
	online = nil, fails = 0, connecting = false, connectAgain = nil, notDoorBird = false, lastError = nil,
	doorbirdIp = nil, ctrlIp = nil, attention = {}, events = {}, lastSeen = {}, alertEpisodeAt = nil,
	eventPicture = nil, pictureSeq = 0, relayPulseAt = {}, pageWrittenAt = 0, savedVars = {},
	lastSyncAt = 0, syncedCtx = "", selfTest = nil, removed = false, startedAt = os.time(),
	pageFor = nil,  -- the address and login the camera page was last written with (only once it worked)
}

-- Saved: the event token, the event server's port, the dynamic events and relay connections,
-- the last device info, and an old DoorBird still to leave
gCfg = {
	token = nil, port = nil,
	buttons = {},   -- doorbell button -> event id
	relays = {},    -- relay -> { binding = id, event = id }
	olds = {},      -- DoorBirds still to leave: { host, user, mac, tries, created = { EntryKey = true } }
	oldPass = {},   -- host -> the password that made the HTTP calls there (saved encrypted)
	paused = false, -- Remove From DoorBird ran: no events until Reconnect
}
OLD_MAX = 3

local function DoorBirdName()
	local ok, n = pcall(function() return C4:GetDeviceDisplayName(ProxyId()) end)
	return (ok and type(n) == "string" and n ~= "") and n or "DoorBird"
end

local function SetLogPrefix()
	LOG_PREFIX = "DoorBird '" .. DoorBirdName() .. "'"
end

--[[=============================================================================
    Saved settings
===============================================================================]]
local function SaveCfg()
	pcall(function()
		local relays = {}
		for r, v in pairs(gCfg.relays) do relays[#relays + 1] = { r, v.binding, v.event } end
		local buttons = {}
		for b, id in pairs(gCfg.buttons) do buttons[#buttons + 1] = { b, id } end
		local favorites = {}
		for k, id in pairs(gReg.favorites) do favorites[#favorites + 1] = { k, id } end
		local created = {}
		for k in pairs(gReg.created) do created[#created + 1] = k end
		local skip = {}
		for k, v in pairs(gReg.skip) do skip[#skip + 1] = { k, v.sig, v.text } end
		local olds = {}
		for _, o in ipairs(gCfg.olds) do
			local oc = {}
			for k in pairs(o.created or {}) do oc[#oc + 1] = k end
			olds[#olds + 1] = { host = o.host, user = o.user, mac = o.mac, tries = o.tries, created = oc }
		end
		C4:PersistSetValue("DL_STATE", JsonEncode({
			port = gCfg.port, relays = relays, buttons = buttons,
			info = { model = gInfo.model, firmware = gInfo.firmware, build = gInfo.build, mac = gInfo.mac, relays = gInfo.relays },
			reg = { host = gReg.host, wrote = gReg.wrote, favorites = favorites, created = created, skip = skip },
			olds = olds, paused = gCfg.paused,
		}))
		local vars = {}
		for _, name in ipairs(SAVED_VARS) do vars[name] = GetVar(name) or "" end
		C4:PersistSetValue("DL_VARS", JsonEncode(vars))
		-- Director refuses to encrypt an empty value
		if gCfg.token then C4:PersistSetValue("DL_TOKEN", gCfg.token, true) end
		if #gCfg.olds > 0 then
			C4:PersistSetValue("DL_OLD_PASS", JsonEncode(JsonObject(gCfg.oldPass)), true)
		else
			C4:PersistDeleteValue("DL_OLD_PASS")
		end
	end)
end

local function LoadCfg()
	pcall(function()
		local s = JsonDecode(C4:PersistGetValue("DL_STATE") or "")
		if type(s) == "table" then
			gCfg.port = tonumber(JsonField(s, "port"))
			for _, r in ipairs(JsonField(s, "relays") or {}) do
				if type(r) == "table" and r[1] then gCfg.relays[tostring(r[1])] = { binding = tonumber(r[2]), event = tonumber(r[3]) } end
			end
			for _, b in ipairs(JsonField(s, "buttons") or {}) do
				if type(b) == "table" and b[1] then gCfg.buttons[tostring(b[1])] = tonumber(b[2]) end
			end
			local info = JsonField(s, "info")
			if type(info) == "table" then
				gInfo.model, gInfo.firmware = tostring(JsonField(info, "model") or ""), tostring(JsonField(info, "firmware") or "")
				gInfo.build, gInfo.mac = tostring(JsonField(info, "build") or ""), tostring(JsonField(info, "mac") or "")
				gInfo.relays = {}
				for _, r in ipairs(JsonField(info, "relays") or {}) do gInfo.relays[#gInfo.relays + 1] = tostring(r) end
			end
			local reg = JsonField(s, "reg")
			if type(reg) == "table" then
				gReg.host = tostring(JsonField(reg, "host") or "")
				gReg.wrote = JsonField(reg, "wrote") and tostring(JsonField(reg, "wrote")) or nil
				for _, f in ipairs(JsonField(reg, "favorites") or {}) do
					if type(f) == "table" and f[1] then gReg.favorites[tostring(f[1])] = tostring(f[2]) end
				end
				for _, k in ipairs(JsonField(reg, "created") or {}) do gReg.created[tostring(k)] = true end
				for _, v in ipairs(JsonField(reg, "skip") or {}) do
					if type(v) == "table" and v[1] then gReg.skip[tostring(v[1])] = { sig = tostring(v[2] or ""), text = tostring(v[3] or "") } end
				end
			end
			gCfg.paused = JsonField(s, "paused") == true
			for _, o in ipairs(JsonField(s, "olds") or {}) do
				if type(o) == "table" and JsonField(o, "host") then
					local oc = {}
					for _, k in ipairs(JsonField(o, "created") or {}) do oc[tostring(k)] = true end
					gCfg.olds[#gCfg.olds + 1] = { host = tostring(JsonField(o, "host")), user = tostring(JsonField(o, "user") or ""),
						mac = tostring(JsonField(o, "mac") or ""), tries = tonumber(JsonField(o, "tries")) or 0, created = oc }
				end
			end
		end
		local v = JsonDecode(C4:PersistGetValue("DL_VARS") or "")
		if type(v) == "table" then gState.savedVars = v end
		local token = C4:PersistGetValue("DL_TOKEN", true)
		if type(token) == "string" and #token >= 16 then gCfg.token = token end
		local op = JsonDecode(C4:PersistGetValue("DL_OLD_PASS", true) or "")
		if type(op) == "table" then
			for h, pw in pairs(op) do gCfg.oldPass[tostring(h)] = tostring(pw) end
		end
	end)
	if not gCfg.token then
		gCfg.token = string.sub(NewSecret("token"), 1, 32)
		SaveCfg()
	end
	RegisterSecret(gCfg.token)
	for _, pw in pairs(gCfg.oldPass) do RegisterSecret(pw) end
end

RegistrationSaved = SaveCfg

--[[=============================================================================
    Dynamic events (one per doorbell button, one per relay) and relay
    connections (one per relay). Kept in the saved settings and added again at
    every start with the same ids, so programming and bindings stay.
===============================================================================]]
local gBindingsAdded, gEventsAdded = {}, {}

local function RelayLabel(r)
	return "Relay " .. tostring(r)
end

local function AddRelayBinding(r, binding)
	if gBindingsAdded[binding] then return end
	local ok, err = pcall(function() C4:AddDynamicBinding(binding, "CONTROL", true, RelayLabel(r), "RELAY", false, false) end)
	if ok then gBindingsAdded[binding] = r else LogError("Adding the relay connection %s failed: %s", RelayLabel(r), err) end
end

local function AddDynamicEvent(id, name, description)
	if gEventsAdded[id] == name then return end
	local ok, err = pcall(function() C4:AddEvent(id, name, description) end)
	if ok then gEventsAdded[id] = name else LogError("Adding the event '%s' failed: %s", name, err) end
end

local function ButtonEventName(b) return "Doorbell Pressed (Button " .. b .. ")" end
local function RelayEventName(r) return "Door Opened (" .. RelayLabel(r) .. ")" end

local function NextFree(base, used)
	local id = base + 1
	while used[id] do id = id + 1 end
	return id
end

-- Relay connections must exist before Director restores their bindings: called from the main
-- body of the script (see the end of this file), as Snap One asks
function RestoreRelayBindings()
	local ok = pcall(function()
		local s = JsonDecode(C4:PersistGetValue("DL_STATE") or "")
		for _, r in ipairs(type(s) == "table" and JsonField(s, "relays") or {}) do
			if type(r) == "table" and r[1] and tonumber(r[2]) then AddRelayBinding(tostring(r[1]), tonumber(r[2])) end
		end
	end)
	return ok
end

local function RestoreDynamicEvents()
	for b, id in pairs(gCfg.buttons) do AddDynamicEvent(id, ButtonEventName(b), "When doorbell button " .. b .. " of NAME is pressed") end
	for r, v in pairs(gCfg.relays) do
		if v.event then AddDynamicEvent(v.event, RelayEventName(r), "When relay " .. r .. " of NAME opens the door or gate") end
		if v.binding then AddRelayBinding(r, v.binding) end
	end
end

local function EnsureButton(b)
	if gCfg.buttons[b] then return false end
	local used = {}
	for _, id in pairs(gCfg.buttons) do used[id] = true end
	local id = NextFree(BUTTON_EVENT_BASE, used)
	gCfg.buttons[b] = id
	AddDynamicEvent(id, ButtonEventName(b), "When doorbell button " .. b .. " of NAME is pressed")
	LogInfo("Doorbell button %s: programming event '%s'", b, ButtonEventName(b))
	return true
end

local function EnsureRelay(r)
	if gCfg.relays[r] then return false end
	local usedB, usedE = {}, {}
	for _, v in pairs(gCfg.relays) do
		if v.binding then usedB[v.binding] = true end
		if v.event then usedE[v.event] = true end
	end
	local v = { binding = NextFree(RELAY_BINDING_BASE, usedB), event = NextFree(RELAY_EVENT_BASE, usedE) }
	gCfg.relays[r] = v
	AddRelayBinding(r, v.binding)
	AddDynamicEvent(v.event, RelayEventName(r), "When relay " .. r .. " of NAME opens the door or gate")
	LogInfo("Relay %s: connection '%s' and programming event '%s'", r, RelayLabel(r), RelayEventName(r))
	return true
end

local function RelayOfBinding(binding)
	for r, v in pairs(gCfg.relays) do
		if v.binding == binding then return r end
	end
	return nil
end

--[[=============================================================================
    Status and attention
===============================================================================]]
local SyncEvents, Connect, UpdateEventsProperty, KeepOld -- forward

local ATTENTION_ORDER = { "login", "address", "operator", "watch", "history", "firmware", "events", "server", "proxy", "old" }

local function SetAttention(key, text, force)
	if gState.attention[key] == text and not force then return end
	gState.attention[key] = text
	local items = {}
	for _, k in ipairs(ATTENTION_ORDER) do
		if gState.attention[k] then items[#items + 1] = gState.attention[k] end
	end
	UpdateProperty("Attention", table.concat(items, "  |  "))
	pcall(function() C4:SetPropertyAttribs("Attention", #items > 0 and 0 or 1) end)
end

local function Configured()
	return TargetReady(gBird)
end

local function SetOnline(on)
	if gState.online == on then return end
	local prev = gState.online
	gState.online = on
	SetVar("ONLINE", on == true)
	if prev ~= nil and on ~= nil then FireEvent(on and "DoorBird Online" or "DoorBird Offline") end
end

function UpdateStatus()
	local s
	local host = gBird.host
	if not Configured() then
		s = "Setup: enter the DoorBird's Address, and the Username and Password of the DoorBird user made for Control4"
	elseif gBird.authFailed then
		s = "Login refused by the DoorBird at " .. host .. " for user '" .. gBird.user .. "' - check the Username and Password"
			.. " (no more requests until they change, so the DoorBird does not block this controller)"
	elseif NowMs() < gBird.lockedUntil then
		s = "The DoorBird blocks this controller for a minute (too many wrong logins) - waiting"
	elseif gState.notDoorBird then
		s = "No DoorBird answers at " .. host .. " (" .. tostring(gState.lastError or "?") .. ")"
	elseif gState.online == false then
		s = "Offline - cannot reach the DoorBird at " .. host .. (gState.lastError and (" (" .. gState.lastError .. ")") or "")
	elseif gState.online == nil then
		s = "Connecting to " .. host .. "..."
	elseif gPerm.operator == false then
		s = "Online, but no events: the DoorBird user '" .. gBird.user .. "' lacks the API-Operator permission"
	elseif gCfg.paused then
		s = "Online - events off: removed from the DoorBird (run Reconnect to register them again)"
	elseif FirmwareNumber(gInfo.firmware) > 0 and FirmwareNumber(gInfo.firmware) < 110 then
		s = "Online, but no events: firmware " .. gInfo.firmware .. " is too old for them (000110 or newer)"
	elseif gReg.state == "ok" then
		s = "Online - events live"
	elseif gReg.state == "partial" then
		s = "Online - some events not registered (see Attention)"
	elseif gReg.state == "working" or gReg.state == "idle" then
		s = "Online - setting up events..."
	else
		s = "Online - events not registered: " .. tostring(gReg.summary ~= "" and gReg.summary or gReg.lastError or "?")
	end
	UpdateProperty("Status", s)
end

local function PermText(v, missing)
	if v == true then return "yes" end
	if v == false then return "NO (" .. missing .. ")" end
	if v == "empty" then return "yes, no picture yet" end
	return "?"
end

local function UpdatePermissions()
	UpdateProperty("Permissions", "API-Operator: " .. PermText(gPerm.operator, "no events")
		.. " · Watch Always: " .. PermText(gPerm.watch, "no live video")
		.. " · History: " .. PermText(gPerm.history, "no ring pictures")
		.. " · Motion: " .. PermText(gPerm.motion, "no motion pictures"))
	local user = "'" .. gBird.user .. "'"
	SetAttention("operator", gPerm.operator == false and ("Give the DoorBird user " .. user
		.. " the API-Operator permission (DoorBird app: Administration, Users): without it the driver cannot register events") or nil)
	local missing = {}
	if gPerm.watch == false then missing[#missing + 1] = "Watch Always (live video, pictures, opening the door at any time)" end
	if gPerm.history == false then missing[#missing + 1] = "History (ring pictures)" end
	if gPerm.motion == false then missing[#missing + 1] = "Motion (motion pictures)" end
	SetAttention("watch", #missing > 0 and ("The DoorBird user " .. user .. " also needs: " .. table.concat(missing, ", ")) or nil)
	UpdateStatus()
end

local function UpdateDeviceProperties()
	local parts = {}
	if gInfo.model ~= "" then parts[#parts + 1] = gInfo.model end
	if gInfo.firmware ~= "" then parts[#parts + 1] = "firmware " .. gInfo.firmware .. (gInfo.build ~= "" and (" (build " .. gInfo.build .. ")") or "") end
	UpdateProperty("DoorBird", #parts > 0 and table.concat(parts, " - ") or "")
	local mac = gInfo.mac
	if #mac == 12 and not string.find(mac, ":", 1, true) then mac = string.gsub(mac, "(%x%x)", "%1:"):sub(1, 17) end
	UpdateProperty("MAC Address", mac)
	local own, peri = {}, {}
	for _, r in ipairs(gInfo.relays) do
		if IsPeripheralRelay(r) then peri[#peri + 1] = r else own[#own + 1] = r end
	end
	local text = #own > 0 and table.concat(own, ", ") or (#gInfo.relays == 0 and "" or "none")
	if #peri > 0 then text = text .. (text ~= "" and " · " or "") .. "door controllers: " .. table.concat(peri, ", ") end
	UpdateProperty("Relays", text)
	local fw = FirmwareNumber(gInfo.firmware)
	SetAttention("firmware", (fw > 0 and fw < 110) and ("Firmware " .. gInfo.firmware .. " is too old for events and schedules: update the DoorBird (000110 or newer)") or nil)
end

local function RememberEvent(what)
	table.insert(gState.events, 1, os.date("%Y-%m-%d %H:%M:%S") .. " " .. what)
	while #gState.events > 10 do table.remove(gState.events) end
	UpdateProperty("Last Event", os.date("%H:%M:%S") .. " " .. what)
end

--[[=============================================================================
    The Control4 camera page (camera proxy)
    Address, HTTP port 80, RTSP port 554 (or 8557), Basic login of the
    DoorBird user: Control4 apps and DirectorLink take pictures and video from
    exactly these values. The driver's Address, Username and Password are the
    place to edit; edits on the camera page are put back.
===============================================================================]]
local function RtspPort()
	return string.find(Properties["Live Video"] or "", "8557", 1, true) and 8557 or 554
end

local function ReadProxyProperties()
	local pid = ProxyId()
	if not pid then return nil end
	local ok, xml = pcall(function() return C4:SendUIRequest(pid, "GET_PROPERTIES", {}) end)
	if not ok or type(xml) ~= "string" or not string.find(xml, "<address>", 1, true) then return nil end
	return {
		address = XmlTag(xml, "address"), httpPort = tonumber(XmlTag(xml, "http_port") or ""),
		rtspPort = tonumber(XmlTag(xml, "rtsp_port") or ""), authRequired = XmlTag(xml, "authentication_required"),
		authType = XmlTag(xml, "authentication_type"), username = XmlTag(xml, "username"), useHttps = XmlTag(xml, "use_https"),
	}
end

local function PageMatches(p)
	return p ~= nil and trim(p.address or "") == gBird.host and p.httpPort == 80 and p.rtspPort == RtspPort()
		and string.upper(p.authType or "") == "BASIC" and toboolean(p.authRequired)
		and (p.username == nil or p.username == "" or IsMasked(p.username) or p.username == gBird.user)
		and not toboolean(p.useHttps)
end

-- Written only with a login the DoorBird took: Control4 apps and DirectorLink use the page, and a wrong
-- password there would make the DoorBird block their addresses (the controller's among them)
local function WriteProxySettings(reason)
	local pid = ProxyId()
	if not pid or not Configured() then return end
	if not gBird.verified then
		LogDebug("Camera page: waiting until the DoorBird takes this login (%s)", reason or "")
		return
	end
	gState.pageFor = gBird.host .. "\n" .. gBird.user .. "\n" .. gBird.pass
	local function cmd(c, p) pcall(function() C4:SendToDevice(pid, c, p, true, false) end) end
	local function notify(c, p) pcall(function() C4:SendToProxy(CAMERA_PROXY, c, p, "NOTIFY") end) end
	LogInfo("Writing the camera page: %s, RTSP port %d, Basic login of '%s' (%s)", gBird.host, RtspPort(), gBird.user, reason or "settings")
	gState.pageWrittenAt = os.time()
	cmd("SET_ADDRESS", { ADDRESS = gBird.host })
	cmd("SET_HTTP_PORT", { PORT = "80" })
	cmd("SET_RTSP_PORT", { PORT = tostring(RtspPort()) })
	cmd("SET_USE_HTTPS", { USE_HTTPS = "False" })
	cmd("SET_AUTHENTICATION_REQUIRED", { REQUIRED = "True" })
	cmd("SET_AUTHENTICATION_TYPE", { TYPE = "BASIC" })
	cmd("SET_USERNAME", { USERNAME = gBird.user })
	cmd("SET_PASSWORD", { PASSWORD = gBird.pass })
	notify("ADDRESS_CHANGED", { ADDRESS = gBird.host })
	notify("HTTP_PORT_CHANGED", { PORT = "80" })
	notify("RTSP_PORT_CHANGED", { PORT = tostring(RtspPort()) })
	notify("USE_HTTPS_CHANGED", { USE_HTTPS = "False" })
	SetTimer("PROXY_VERIFY", 3000, function()
		local p = ReadProxyProperties()
		if not p then return end
		if PageMatches(p) then
			LogDebug("Camera page verified: %s:%s, RTSP %s, %s", tostring(p.address), tostring(p.httpPort), tostring(p.rtspPort), tostring(p.authType))
			SetAttention("proxy", nil)
		else
			LogWarn("Camera page shows address=%s port=%s rtsp=%s auth=%s required=%s", tostring(p.address), tostring(p.httpPort),
				tostring(p.rtspPort), tostring(p.authType), tostring(p.authRequired))
			SetAttention("proxy", "Open the camera's Properties page and set Address " .. gBird.host .. ", HTTP Port 80, RTSP Port " .. RtspPort()
				.. ", Authentication Required, type BASIC, and the DoorBird user's login")
		end
	end)
end

local function SyncCameraPage(reason)
	if not Configured() or not gBird.verified then return end
	if gState.pageFor ~= (gBird.host .. "\n" .. gBird.user .. "\n" .. gBird.pass) then return WriteProxySettings(reason) end
	local p = ReadProxyProperties()
	if p and PageMatches(p) then return end
	WriteProxySettings(reason)
end

--[[=============================================================================
    Pictures
    image.cgi: the live picture (Watch Always). history.cgi: the picture the
    DoorBird kept of the last ring (History) or motion (Motion).
===============================================================================]]
local function GetPicture(path, label, cb)
	DoorBirdRequest(gBird, { path = path, label = label, accept = "image/jpeg", priority = true, timeout = 15 }, function(code, body, err, _, ms)
		if code == 200 and IsJpeg(body) then return cb(body, code, nil, ms) end
		cb(nil, code, err or (code == 204 and "no permission" or (code and ("HTTP " .. code) or "no answer")), ms)
	end)
end

local function LivePicture(cb) GetPicture("/bha-api/image.cgi", "image.cgi", cb) end

local function HistoryPicture(kind, cb)
	GetPicture("/bha-api/history.cgi?" .. QueryString({ { "event", kind }, { "index", "1" } }), "history.cgi " .. kind .. " 1", cb)
end

-- Fire an event once its picture is in (for the notification attachment), or after PICTURE_WAIT_MS:
-- the picture attached is always this event's. The live picture first; without Watch Always, the
-- DoorBird's own picture of the event (history.cgi).
local function FireWithPicture(event, historyKind)
	gState.eventPicture = nil
	gState.pictureSeq = gState.pictureSeq + 1
	local seq, fired = gState.pictureSeq, false
	local function fire()
		if fired then return end
		fired = true
		KillTimer("PICTURE_WAIT_" .. event)
		FireEvent(event)
	end
	if (Properties["Picture With Events"] or "Yes") ~= "Yes" or not Configured() then return fire() end
	SetTimer("PICTURE_WAIT_" .. event, PICTURE_WAIT_MS, fire)
	local function got(jpeg, from)
		if seq ~= gState.pictureSeq then return end
		gState.eventPicture = jpeg
		LogDebug("Picture for %s from %s (%s)", event, from, ByteSize(#jpeg))
		fire()
	end
	LivePicture(function(jpeg, code)
		if jpeg then return got(jpeg, "image.cgi") end
		if code == 204 and historyKind then
			HistoryPicture(historyKind, function(h)
				if h then return got(h, "history.cgi") end
				fire()
			end)
			return
		end
		fire()
	end)
end

--[[=============================================================================
    Events from the DoorBird
===============================================================================]]
local function SaveVars()
	SaveCfg()
end

local function RecordHistory(what)
	if (Properties["Record In History"] or "Yes") ~= "Yes" then return end
	pcall(function() C4:RecordHistory("Info", what, "Cameras", DoorBirdName(), { doorbird = DoorBirdName() }) end)
end

local function AlertOnMotion()
	return (Properties["Alert On Motion"] or "Off") == "On"
end

local function HoldSeconds()
	return tonumber(Properties["Motion Alert Hold Time (s)"]) or 60
end

local function Ring(button)
	button = button ~= "" and button or "1"
	EnsureButton(button)
	SetVar("LAST_DOORBELL", button)
	SetVar("LAST_RING", IsoUtc())       -- DirectorLink reads LAST_RING when "Ring" fires: set it first
	SetVar("LAST_EVENT", "Doorbell " .. button)
	SaveVars()
	RememberEvent("doorbell button " .. button)
	local id = gCfg.buttons[button]
	if id then FireEventById(id, ButtonEventName(button)) end
	FireWithPicture("Ring", "doorbell")
	RecordHistory("Doorbell pressed" .. (button ~= "1" and (" (button " .. button .. ")") or ""))
end

local function Motion()
	local now = NowMs() / 1000
	SetVar("LAST_MOTION", IsoUtc())
	SetVar("LAST_EVENT", "Motion")
	FireEvent("Motion Detected")
	local alerted = false
	if AlertOnMotion() then
		if gState.alertEpisodeAt and now - gState.alertEpisodeAt < HoldSeconds() then
			LogDebug("Motion within the hold time (%d s) of the last alert: no new alert", HoldSeconds())
		else
			alerted = true
			SetVar("LAST_ALERT", "Motion")   -- DirectorLink reads LAST_ALERT when "Alert" fires: set it first
			FireWithPicture("Alert", "motionsensor")
			RecordHistory("Motion at the door")
		end
		gState.alertEpisodeAt = now
	end
	SaveVars()
	RememberEvent("motion" .. (alerted and " (alert)" or ""))
end

local function RfidRead()
	SetVar("LAST_RFID", IsoUtc())
	SetVar("LAST_EVENT", "RFID")
	SaveVars()
	RememberEvent("RFID tag")
	FireEvent("RFID Read")
end

-- A relay connection shows the pulse: CLOSED, then OPENED again
local function ShowPulse(relay)
	local v = gCfg.relays[relay]
	if not v or not v.binding then return end
	pcall(function() C4:SendToProxy(v.binding, "CLOSED", {}, "NOTIFY") end)
	SetTimer("RELAY_SHOWN_" .. relay, RELAY_SHOWN_CLOSED_MS, function()
		pcall(function() C4:SendToProxy(v.binding, "OPENED", {}, "NOTIFY") end)
	end)
end

local function DoorOpened(relay, source)
	EnsureRelay(relay)
	SetVar("LAST_RELAY", relay)
	SetVar("LAST_DOOR_OPENED", IsoUtc())
	SetVar("LAST_EVENT", "Door opened (relay " .. relay .. ")")
	SaveVars()
	RememberEvent("door opened, relay " .. relay .. " (" .. source .. ")")
	ShowPulse(relay)
	local v = gCfg.relays[relay]
	if v and v.event then FireEventById(v.event, RelayEventName(relay)) end
	FireEvent("Door Opened")
	RecordHistory("Door opened (relay " .. relay .. ")")
end

local KNOWN_EVENTS = { doorbell = true, motion = true, rfid = true, relay = true }

-- A repeat of the same event within REPEAT_HOLD_S is one event (one press, one ring)
local function IsRepeat(key)
	local now = NowMs()
	local last = gState.lastSeen[key]
	if last and now - last < REPEAT_HOLD_S * 1000 then return true end
	gState.lastSeen[key] = now
	return false
end

function EventServerToken()
	return gCfg.token
end

function EventServerSource()
	if IsIPv4(gBird.host) then return gBird.host end
	return gState.doorbirdIp
end

function EventServerDeliver(e, p, ip)
	if not KNOWN_EVENTS[e] then
		LogDebug("Event call '%s' from the DoorBird: not an event this driver knows", e)
		return
	end
	local key = (e == "doorbell" or e == "relay") and (e .. ":" .. p) or e
	if IsRepeat(key) then
		LogDebug("%s again within %d s: a repeat, ignored", KeyLabel(key), REPEAT_HOLD_S)
		return
	end
	if gState.online ~= true then
		gState.fails = 0
		SetOnline(true)
		UpdateStatus()
	end
	if e == "doorbell" then Ring(p)
	elseif e == "motion" then Motion()
	elseif e == "rfid" then RfidRead()
	elseif e == "relay" then DoorOpened(p ~= "" and p or "1", "DoorBird")
	end
end

--[[=============================================================================
    Actions on the DoorBird
===============================================================================]]
local function ReturnCodeOk(body)
	local doc = JsonDecode(body or "")
	local bha = type(doc) == "table" and JsonField(doc, "BHA") or nil
	if type(bha) ~= "table" then return true end -- some firmware answers 200 without a body
	return tostring(JsonField(bha, "RETURNCODE") or "1") == "1"
end

-- Pulse a relay (open-door.cgi). The DoorBird energizes it for its own set time: a relay is never held.
function OpenDoor(relay, source)
	relay = trim(tostring(relay or ""))
	if relay == "" then relay = "1" end
	if not Configured() then
		LogWarn("Open door (relay %s): the DoorBird is not set up", relay)
		return
	end
	local now = NowMs() / 1000
	if gState.relayPulseAt[relay] and now - gState.relayPulseAt[relay] < RELAY_DEBOUNCE_S then
		LogInfo("Relay %s was pulsed %.1f s ago: not again", relay, now - gState.relayPulseAt[relay])
		return
	end
	gState.relayPulseAt[relay] = now
	LogInfo("Opening the door: relay %s (%s)", relay, source or "Control4")
	DoorBirdRequest(gBird, { path = "/bha-api/open-door.cgi?" .. QueryString({ { "r", relay } }), priority = true,
		label = "open-door.cgi relay " .. relay }, function(code, body, err)
		if code == 200 and ReturnCodeOk(body) then
			gState.lastSeen["relay:" .. relay] = NowMs() -- the DoorBird's own call for this pulse is a repeat
			DoorOpened(relay, source or "Control4")
		elseif code == 204 then
			gPerm.watch = false
			UpdatePermissions()
			LogWarn("Relay %s not opened: the DoorBird user lacks Watch Always (it may open the door only within 5 minutes of a ring)", relay)
		else
			gState.relayPulseAt[relay] = nil
			LogWarn("Relay %s not opened: %s", relay, err or (code and ("HTTP " .. code)) or "no answer")
		end
	end)
end

function LightOn(source)
	if not Configured() then return end
	LogInfo("IR light on (%s)", source or "Control4")
	DoorBirdRequest(gBird, { path = "/bha-api/light-on.cgi", priority = true, label = "light-on.cgi" }, function(code, body, err)
		if code == 200 and ReturnCodeOk(body) then
			RememberEvent("IR light on (" .. (source or "Control4") .. ")")
		elseif code == 204 then
			gPerm.watch = false
			UpdatePermissions()
			LogWarn("IR light not turned on: the DoorBird user lacks Watch Always")
		else
			LogWarn("IR light not turned on: %s", err or (code and ("HTTP " .. code)) or "no answer")
		end
	end)
end

--[[=============================================================================
    Connecting, permissions, events
===============================================================================]]
local function ApplyInfo(info)
	local changed = info.model ~= gInfo.model or info.firmware ~= gInfo.firmware or info.mac ~= gInfo.mac
		or table.concat(info.relays, ",") ~= table.concat(gInfo.relays, ",")
	gInfo.model, gInfo.firmware, gInfo.build, gInfo.mac = info.model, info.firmware, info.build, info.mac
	gInfo.relays, gInfo.at = info.relays, os.time()
	if changed then
		LogInfo("DoorBird: %s, firmware %s (build %s), MAC %s, relays %s", info.model ~= "" and info.model or "model not reported",
			info.firmware, info.build, info.mac ~= "" and info.mac or "?", #info.relays > 0 and table.concat(info.relays, ", ") or "none reported")
	end
	local added = false
	for _, r in ipairs(info.relays) do
		if EnsureRelay(r) then added = true end
	end
	if #info.relays == 0 and FirmwareNumber(info.firmware) < 108 then
		-- Before firmware 000108 the DoorBird does not list its relays: it has relay 1
		if EnsureRelay("1") then added = true end
	end
	if changed or added then SaveCfg() end
	UpdateDeviceProperties()
end

function RegistrationKeysFound(keys)
	local buttons, added = {}, false
	for _, k in ipairs(keys) do
		local kind, p = KeyParts(k)
		if kind == "doorbell" then
			buttons[#buttons + 1] = p
			if EnsureButton(p) then added = true end
		end
	end
	UpdateProperty("Doorbell Buttons", table.concat(buttons, ", "))
	if added then SaveCfg() end
end

function RegistrationChanged()
	if UpdateEventsProperty then UpdateEventsProperty() end
	UpdateStatus()
end

-- A sync asked for while another job ran: now, through SyncEvents' checks (paused, removed, ...)
function RegistrationIdle()
	if SyncEvents then SyncEvents("deferred") end
end

UpdateEventsProperty = function()
	local server
	if EventServerListening() then
		server = "server " .. tostring(gState.ctrlIp or ControllerAddress() or "?") .. ":" .. gServer.port
	else
		server = "server " .. gServer.state .. (gServer.error and (" (" .. gServer.error .. ")") or "")
	end
	local text = gReg.summary ~= "" and gReg.summary or gReg.state
	UpdateProperty("Events", text .. " - " .. server)
	local problems = {}
	for _, k in ipairs(gReg.keys or {}) do
		if gReg.problems[k] then problems[#problems + 1] = KeyLabel(k) .. ": " .. gReg.problems[k] end
	end
	if gReg.state == "failed" and gReg.lastError and #problems == 0 and gPerm.operator ~= false then
		problems[#problems + 1] = gReg.lastError
	end
	SetAttention("events", #problems > 0 and ("Events - " .. table.concat(problems, "; ")) or nil)
	SetAttention("server", (gServer.state == "error") and ("The event server cannot listen on the controller (" .. tostring(gServer.error) .. ")") or nil)
end

local function SyncContext()
	local ctrl = ControllerAddress()
	if not ctrl or not EventServerListening() or not gCfg.token then return nil end
	return { ctrl = ctrl, port = gServer.port, token = gCfg.token, relays = gInfo.relays }
end

-- Register (or check) this driver's HTTP calls on the DoorBird
SyncEvents = function(reason)
	if not Configured() or gBird.authFailed or gState.removed then return end
	if gCfg.paused and reason ~= "reconnect" then return end
	-- Only once info.cgi took this login (a wrong password costs one request, not more)
	if gState.online ~= true or not gBird.verified then return end
	local fw = FirmwareNumber(gInfo.firmware)
	if fw > 0 and fw < 110 then return end
	local ctx = SyncContext()
	if not ctx then
		LogDebug("Events: waiting for the event server and the controller's address")
		return
	end
	gState.lastSyncAt = os.time()
	gState.syncedCtx = ctx.ctrl .. ":" .. ctx.port
	LogDebug("Checking the DoorBird's HTTP calls (%s)", reason or "")
	RegistrationSync(gBird, ctx, function(ok)
		if gReg.state == "refused" then
			gPerm.operator = false
		elseif gReg.state ~= "failed" or gReg.favs then
			gPerm.operator = true
		end
		UpdatePermissions()
		UpdateEventsProperty()
	end)
end

-- Watch Always, History, Motion: what the DoorBird answers image.cgi and history.cgi
local function CheckPermissions(done)
	LivePicture(function(jpeg, code)
		if jpeg then gPerm.watch = true elseif code == 204 then gPerm.watch = false end
		HistoryPicture("doorbell", function(h, hcode)
			-- 204: no History permission, or no ring kept yet; 404 or another answer: nothing kept yet
			if h then gPerm.history = true elseif hcode == 204 then gPerm.history = false elseif hcode then gPerm.history = "empty" end
			HistoryPicture("motionsensor", function(m, mcode)
				if m then gPerm.motion = true elseif mcode == 204 then gPerm.motion = false elseif mcode then gPerm.motion = "empty" end
				gPerm.checkedAt = os.time()
				UpdatePermissions()
				if done then done() end
			end)
		end)
	end)
end

-- The DoorBird's IP address, for the event server to know its calls (resolved when Address is a name)
local function ResolveDoorBird()
	if IsIPv4(gBird.host) or not ValidAddress(gBird.host) then
		gState.doorbirdIp = IsIPv4(gBird.host) and gBird.host or nil
		SetAttention("address", nil)
		return
	end
	local host = gBird.host
	local ok, err = pcall(function()
		local client = C4:CreateTCPClient()
		gState.resolver = client
		client
			:OnResolve(function(_, endpoints)
				local ip
				for _, ep in ipairs(endpoints or {}) do
					if IsIPv4(ep.ip) then ip = ep.ip break end
				end
				if host == gBird.host then
					gState.doorbirdIp = ip
					LogInfo("The DoorBird %s is at %s", host, tostring(ip))
					SetAttention("address", ip and nil or ("The address " .. host .. " does not resolve to an IPv4 address: enter the DoorBird's IP address"))
				end
				return 0 -- only the address was wanted: no connection
			end)
			:OnConnect(function(c) pcall(function() c:Close() end) end) -- if a firmware connects anyway
			:OnError(function() if gState.resolver == client then gState.resolver = nil end end)
			:Connect(host, 80)
	end)
	if not ok then
		LogWarn("Cannot resolve %s: %s", host, tostring(err))
		SetAttention("address", "Enter the DoorBird's IP address as Address (" .. host .. " cannot be resolved)")
	end
end

local function OnInfo(code, body, err, reason)
	gState.connecting = false
	if code == 200 then
		local info, why = ParseInfo(body)
		if not info then
			gState.notDoorBird, gState.lastError = true, why
			SetOnline(false)
			LogWarn("No DoorBird answers at %s: info.cgi %s", gBird.host, why)
			UpdateStatus()
			return
		end
		gState.notDoorBird, gState.lastError, gState.fails = false, nil, 0
		SetAttention("login", nil)
		SyncCameraPage("the DoorBird took the login")
		ApplyInfo(info)
		-- The DoorBird an old address pointed at, now at this one (the same MAC): its HTTP calls stay
		for i = #gCfg.olds, 1, -1 do
			local o = gCfg.olds[i]
			if o and o.mac ~= "" and info.mac ~= "" and o.mac == info.mac and o.host ~= gBird.host then
				KeepOld(o, "The DoorBird at " .. gBird.host .. " is the one that was at " .. o.host .. " (the same MAC)")
			end
		end
		SetOnline(true)
		UpdateStatus()
		local first = reason ~= "health"
		if first or gPerm.checkedAt == nil then
			CheckPermissions(function() SyncEvents(reason) end)
		elseif os.time() - gState.lastSyncAt >= RESYNC_S or gState.syncedCtx ~= ((ControllerAddress() or "") .. ":" .. tostring(gServer.port)) then
			SyncEvents("check")
		end
		return
	end
	if code == 401 then
		SetOnline(false)
		SetAttention("login", "The DoorBird refused the login of '" .. gBird.user .. "': check the Username and Password (the user made for Control4 in the DoorBird app)")
	elseif code == 423 then
		SetTimer("LOCK_WAIT", (API_LOCKOUT_S + 1) * 1000, function() Connect("after the lock") end)
	else
		gState.fails = gState.fails + 1
		gState.lastError = err or (code and ("HTTP " .. code)) or "no answer"
		if code and code ~= 200 then gState.notDoorBird = code == 404 end
		if gState.fails >= OFFLINE_AFTER or gState.online == nil then SetOnline(false) end
	end
	UpdateStatus()
end

-- info.cgi: the connection, the device and (first time) the permissions and events. A Connect asked
-- for while a request is on its way runs after it.
local function RequestInfo(reason, label, force)
	gState.connecting = true
	DoorBirdRequest(gBird, { path = "/bha-api/info.cgi", label = label, force = force }, function(code, body, err)
		local ok, e = pcall(OnInfo, code, body, err, reason)
		if not ok then
			gState.connecting = false
			LogError("Connecting failed: %s", e)
		end
		local again = gState.connectAgain
		gState.connectAgain = nil
		if again then Connect(again) end
	end)
end

Connect = function(reason)
	if gState.removed then return end
	UpdateStatus()
	if not Configured() then return end
	if gState.connecting then
		gState.connectAgain = reason
		return
	end
	ResolveDoorBird()
	RequestInfo(reason, "info.cgi", reason == "reconnect")
end

local function HealthCheck()
	if not Configured() or gBird.authFailed or gState.connecting or gState.removed then return end
	-- The controller's address changed: the HTTP calls must point at the new one
	local ctrl = ControllerAddress()
	if ctrl and gState.ctrlIp and ctrl ~= gState.ctrlIp then
		LogInfo("The controller's address changed from %s to %s: updating the DoorBird's HTTP calls", gState.ctrlIp, ctrl)
	end
	gState.ctrlIp = ctrl or gState.ctrlIp
	RequestInfo("health", "info.cgi (check)", false)
end

--[[------------------------------------------------------------------ Leaving an old DoorBird
    When the Address changes, this driver's HTTP calls leave the DoorBird it
    was on, with the login that made them. One that does not answer is tried
    again every OLD_RETRY_S for a day. A DoorBird that only moved to a new
    address (the same MAC) keeps them: they are updated, not removed.       ]]
local function DropOld(o)
	for i, x in ipairs(gCfg.olds) do
		if x == o then
			table.remove(gCfg.olds, i)
			break
		end
	end
	gCfg.oldPass[o.host] = nil
end

local function UpdateOldAttention()
	local hosts = {}
	for _, o in ipairs(gCfg.olds) do
		if (o.tries or 0) > 0 then hosts[#hosts + 1] = o.host end
	end
	SetAttention("old", #hosts > 0 and ("This driver's HTTP calls are still on the DoorBird at " .. table.concat(hosts, ", ")
		.. ": it tries again every " .. (OLD_RETRY_S / 60) .. " minutes") or nil)
end

-- An old DoorBird that is the current one again (by address, or by MAC once connected): nothing to leave
KeepOld = function(o, why)
	LogInfo("%s: this driver's HTTP calls there are kept and updated, not removed", why)
	for k in pairs(o.created or {}) do gReg.created[k] = true end
	DropOld(o)
	SaveCfg()
	UpdateOldAttention()
end

local function LeaveOldDoorBird()
	local o = gCfg.olds[1]
	if not o or gState.removed or gState.leaving then return end
	if o.host == gBird.host then
		KeepOld(o, "Back at the DoorBird " .. o.host)
		return LeaveOldDoorBird()
	end
	gState.leaving = o
	local t = NewTarget({ host = o.host, user = o.user, pass = gCfg.oldPass[o.host] or "", name = "old DoorBird" })
	RegistrationRemove(t, gCfg.token, function(ok, count, err)
		gState.leaving = nil
		local still = false
		for _, x in ipairs(gCfg.olds) do
			if x == o then still = true end
		end
		if still then
			if ok then
				LogInfo("Left the DoorBird at %s: %d HTTP call%s removed", o.host, count, count == 1 and "" or "s")
				DropOld(o)
			elseif t.authFailed then
				LogWarn("The DoorBird at %s refused the login that made this driver's HTTP calls there: not trying again (remove its 'DirectorLink (...)' HTTP calls there by hand)", o.host)
				DropOld(o)
			else
				o.tries = (o.tries or 0) + 1
				if o.tries >= OLD_RETRY_MAX then
					LogWarn("Gave up removing this driver's HTTP calls from the DoorBird at %s (%s): remove its 'DirectorLink (...)' HTTP calls there by hand",
						o.host, tostring(err))
					DropOld(o)
				else
					LogWarn("This driver's HTTP calls are still on the DoorBird at %s (%s): trying again in %d minutes", o.host, tostring(err), OLD_RETRY_S / 60)
					-- The others get their turn
					DropOld(o)
					gCfg.olds[#gCfg.olds + 1] = o
					gCfg.oldPass[o.host] = t.pass
				end
			end
			SaveCfg()
			UpdateOldAttention()
		end
		if #gCfg.olds > 0 then
			if ok or not still then LeaveOldDoorBird() else SetTimer("OLD_RETRY", OLD_RETRY_S * 1000, LeaveOldDoorBird) end
		else
			KillTimer("OLD_RETRY")
		end
		SyncEvents("address changed")
	end, "the address changed", o.created or {})
end

-- The Address, Username or Password changed (applied once the installer is done typing)
local function ApplyLogin()
	local host, user, pass = trim(Properties["Address"] or ""), trim(Properties["Username"] or ""), Properties["Password"] or ""
	if host == gBird.host and user == gBird.user and pass == gBird.pass then return end
	local oldHost, oldUser, oldPass = gBird.host, gBird.user, gBird.pass
	if host ~= oldHost then
		-- Also when a job was cut short there: what it wrote goes too
		if oldHost ~= "" and ((gReg.host == oldHost and next(gReg.favorites)) or gReg.wrote == oldHost) then
			-- The HTTP calls on the old DoorBird go, with the login that made them
			local known = false
			for _, o in ipairs(gCfg.olds) do
				if o.host == oldHost then known = true end
			end
			if not known then
				if #gCfg.olds >= OLD_MAX then
					local dropped = table.remove(gCfg.olds, 1)
					gCfg.oldPass[dropped.host] = nil
					LogWarn("Too many DoorBirds to leave: %s is no longer tried (remove its 'DirectorLink (...)' HTTP calls by hand)", dropped.host)
				end
				gCfg.olds[#gCfg.olds + 1] = { host = oldHost, user = oldUser, mac = gInfo.mac, tries = 0, created = gReg.created }
				gCfg.oldPass[oldHost] = oldPass
			end
		end
		-- What was made on the old DoorBird belongs to it, not to the new one
		gReg.created, gReg.favorites, gReg.skip, gReg.host, gReg.wrote = {}, {}, {}, "", nil
		for i = #gCfg.olds, 1, -1 do
			if gCfg.olds[i].host == host then KeepOld(gCfg.olds[i], "Back at the DoorBird " .. host) end
		end
	end
	-- What was on its way to the DoorBird stops: nothing made for the old login or address reaches the new one
	RegistrationAbort(gBird)
	SetTargetLogin(gBird, host, user, pass)
	gState.connecting = false
	if host ~= oldHost then
		gInfo = { model = "", firmware = "", build = "", mac = "", relays = gInfo.relays, at = nil }
		gPerm = { operator = nil, watch = nil, history = nil, motion = nil, checkedAt = nil }
		gState.online, gState.fails, gState.notDoorBird, gState.lastError = nil, 0, false, nil
		gState.doorbirdIp = nil
		gReg.state, gReg.summary, gReg.problems = "idle", "", {}
		UpdateDeviceProperties()
	end
	SaveCfg()
	LogInfo("DoorBird login: %s, user '%s'", host ~= "" and host or "(no address)", user)
	SetAttention("login", nil)
	UpdatePermissions()
	if #gCfg.olds > 0 then LeaveOldDoorBird() end
	Connect("login changed")
end

--[[=============================================================================
    Diagnostics
===============================================================================]]
local function SelfTest(cb)
	if not EventServerListening() then return cb("the event server is not listening") end
	local ctrl = ControllerAddress() or "127.0.0.1"
	local url = "http://" .. ctrl .. ":" .. gServer.port .. EVENT_PATH .. "?" .. QueryString({ { "e", "selftest" }, { "t", gCfg.token } })
	local ok, err = pcall(function()
		local x = C4:url()
		x:SetOptions({ fail_on_error = false, timeout = 5, connect_timeout = 3 })
		x:OnDone(function(_, responses, errCode, errMsg)
			local resp = responses and responses[#responses]
			if (errCode ~= nil and errCode ~= 0) or not resp then return cb("no answer (" .. tostring(errMsg or errCode) .. ")") end
			cb(tonumber(resp.code) == 200 and "OK" or ("HTTP " .. tostring(resp.code)))
		end)
		x:Get(url, { ["User-Agent"] = UserAgent() })
	end)
	if not ok then cb(tostring(err)) end
end

local function OutputText(o, own, favs)
	local event, param = tostring(JsonField(o, "event") or ""), tostring(JsonField(o, "param") or "")
	if event == "http" then
		if own[param] then return "HTTP #" .. param .. " (this driver)" end
		local f = favs and favs[param]
		return "HTTP #" .. param .. (f and (" '" .. f.title .. "'") or "")
	end
	if event == "notify" then return "push notifications" end
	return event .. (param ~= "" and (" " .. param) or "")
end

local function PrintDiagnostics()
	local function render(selfTest)
		local v = ControllerVersion()
		local lines = {
			"===== DirectorLink · DoorBird - diagnostics =====",
			"Driver        : " .. DRIVER_SEMVER .. " on Control4 OS " .. (v and v.text or "?") .. ", device " .. tostring(MyDeviceId()),
			"Status        : " .. tostring(Properties["Status"]),
			"DoorBird      : " .. (gBird.host ~= "" and gBird.host or "(no address)") .. (EventServerSource() and EventServerSource() ~= gBird.host and (" = " .. EventServerSource()) or "")
				.. ", user '" .. gBird.user .. "', password " .. (gBird.pass ~= "" and "set" or "NOT SET")
				.. (gBird.authFailed and " - LOGIN REFUSED" or "") .. (NowMs() < gBird.lockedUntil and " - BLOCKED FOR A MINUTE" or ""),
			"Device        : " .. (gInfo.model ~= "" and gInfo.model or "model ?") .. ", firmware " .. (gInfo.firmware ~= "" and gInfo.firmware or "?")
				.. (gInfo.build ~= "" and (" (build " .. gInfo.build .. ")") or "") .. ", MAC " .. (gInfo.mac ~= "" and gInfo.mac or "?"),
			"Relays        : " .. (#gInfo.relays > 0 and table.concat(gInfo.relays, ", ") or "none reported"),
			"Permissions   : " .. tostring(Properties["Permissions"]),
			"Online        : " .. tostring(gState.online) .. (gState.lastError and (" (last error: " .. gState.lastError .. ")") or ""),
		}
		local srv = EventServerListening() and ("listening on " .. tostring(ControllerAddress()) .. ":" .. gServer.port) or ("not listening: " .. gServer.state .. " " .. tostring(gServer.error or ""))
		lines[#lines + 1] = "Event server  : " .. srv .. " - self-test " .. tostring(selfTest) .. " - " .. gServer.accepted .. " calls taken, " .. gServer.refused .. " refused"
			.. (gServer.lastRefused and (" (last refused " .. os.date("%H:%M:%S", gServer.lastRefused.at) .. " from " .. gServer.lastRefused.ip .. ": " .. gServer.lastRefused.why .. ")") or "")
		lines[#lines + 1] = "Events        : " .. tostring(Properties["Events"])
		-- This driver's favorites, then a count of the others (their URLs may hold logins: not shown)
		local own, others, ids = {}, {}, {}
		for id, f in pairs(gReg.favs or {}) do
			if OwnFavoriteKey(f.value, gCfg.token) then own[id] = f else others[#others + 1] = "'" .. f.title .. "'" end
			ids[#ids + 1] = id
		end
		table.sort(ids, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
		lines[#lines + 1] = "HTTP calls    : this driver's favorites on the DoorBird" .. (gReg.lastSync and (" (read " .. os.date("%H:%M:%S", gReg.lastSync) .. ")") or " (not read yet)") .. ":"
		local n = 0
		for _, id in ipairs(ids) do
			if own[id] then
				n = n + 1
				lines[#lines + 1] = "   #" .. id .. " '" .. own[id].title .. "' -> " .. own[id].value
			end
		end
		if n == 0 then lines[#lines + 1] = "   none" end
		table.sort(others)
		lines[#lines + 1] = "   other HTTP favorites: " .. #others .. (#others > 0 and (" (" .. table.concat(others, ", ") .. ")") or "") .. ", SIP favorites: " .. tostring(gReg.sipCount or 0) .. " - left as they are"
		lines[#lines + 1] = "Schedule      : the entries with this driver's HTTP calls:"
		local m = 0
		for _, e in ipairs(gReg.entries or {}) do
			local outs, mine = {}, false
			for _, o in ipairs(JsonField(e, "output") or {}) do
				outs[#outs + 1] = OutputText(o, own, gReg.favs)
				if tostring(JsonField(o, "event") or "") == "http" and own[tostring(JsonField(o, "param") or "")] then mine = true end
			end
			if mine then
				m = m + 1
				local ck = EntryKey(EntryInput(e), EntryParam(e))
				lines[#lines + 1] = "   " .. EntryLabel(EntryInput(e), EntryParam(e)) .. ": " .. table.concat(outs, ", ") .. (gReg.created[ck] and "  [entry made by this driver]" or "")
			end
		end
		if m == 0 then lines[#lines + 1] = "   none" end
		lines[#lines + 1] = "Last events   :"
		if #gState.events == 0 then lines[#lines + 1] = "   none since the driver started" end
		for _, ev in ipairs(gState.events) do lines[#lines + 1] = "   " .. ev end
		lines[#lines + 1] = "Requests      : " .. gBird.requests .. " sent, " .. gBird.failures .. " without an answer; the last ones:"
		for i = 1, math.min(10, #gBird.history) do
			local h = gBird.history[i]
			lines[#lines + 1] = string.format("   %s %s %s -> %s %s", os.date("%H:%M:%S", h.at), h.method, h.label,
				h.code and tostring(h.code) or "no answer", h.code and (h.ms .. " ms") or tostring(h.err or ""))
		end
		local p = ReadProxyProperties()
		lines[#lines + 1] = "Camera page   : " .. (p and (tostring(p.address) .. ":" .. tostring(p.httpPort) .. ", RTSP " .. tostring(p.rtspPort) .. ", auth " .. tostring(p.authType)
			.. " required " .. tostring(p.authRequired) .. (PageMatches(p) and " (as it should be)" or " (DIFFERS - see Attention)")) or "cannot be read")
		lines[#lines + 1] = "Video         : rtsp://" .. gBird.host .. ":" .. RtspPort() .. "/" .. RTSP_PATH .. " (H.264), MJPEG http://" .. gBird.host .. "/" .. MJPEG_PATH
			.. ", snapshot http://" .. gBird.host .. "/" .. SNAPSHOT_PATH
		lines[#lines + 1] = "Variables     : DIRECTORLINK_CAMERA=" .. tostring(GetVar("DIRECTORLINK_CAMERA")) .. " KIND=" .. tostring(GetVar("DIRECTORLINK_CAMERA_KIND"))
			.. " LAST_RING=" .. tostring(GetVar("LAST_RING")) .. " LAST_ALERT=" .. tostring(GetVar("LAST_ALERT")) .. " LAST_MOTION=" .. tostring(GetVar("LAST_MOTION"))
		lines[#lines + 1] = "Alerts        : Alert On Motion " .. tostring(Properties["Alert On Motion"]) .. ", hold " .. HoldSeconds() .. " s"
		for _, o in ipairs(gCfg.olds) do
			lines[#lines + 1] = "Old DoorBird  : " .. o.host .. " still has this driver's HTTP calls (tried " .. tostring(o.tries) .. " times)"
		end
		if (Properties["Attention"] or "") ~= "" then lines[#lines + 1] = "ATTENTION     : " .. Properties["Attention"] end
		lines[#lines + 1] = "================================================="
		PrintReport(lines)
	end
	SelfTest(function(result)
		gState.selfTest = result
		-- Read the DoorBird's favorites and schedule fresh when it can be asked
		if Configured() and not gBird.authFailed and gPerm.operator ~= false and not gReg.busy then
			DoorBirdRequest(gBird, { path = "/bha-api/favorites.cgi", kind = "operator", label = "favorites.cgi (read)" }, function(code, body)
				if code == 200 then
					local favs, _, sipCount = ParseFavorites(body)
					if favs then gReg.favs, gReg.sipCount = favs, sipCount or 0 end
				end
				DoorBirdRequest(gBird, { path = "/bha-api/schedule.cgi", kind = "operator", label = "schedule.cgi (read)" }, function(scode, sbody)
					if scode == 200 then
						local entries = ParseSchedule(sbody)
						if entries then gReg.entries = entries end
					end
					gReg.lastSync = os.time()
					render(result)
				end)
			end)
		else
			render(result)
		end
	end)
end

local function TestPictures()
	local function line(what, jpeg, code, err, ms)
		if jpeg then
			local w, h = JpegSize(jpeg)
			return string.format("Test Pictures %s: OK in %d ms - %sx%s, %s", what, ms or 0, tostring(w or "?"), tostring(h or "?"), ByteSize(#jpeg))
		end
		local why = err or ("HTTP " .. tostring(code))
		if code == 204 then why = "204 - the DoorBird user lacks the permission (" .. (what == "live" and "Watch Always" or (what == "last ring" and "History" or "Motion")) .. ")" end
		return "Test Pictures " .. what .. ": FAILED - " .. why
	end
	LivePicture(function(jpeg, code, err, ms)
		PrintReport({ line("live", jpeg, code, err, ms) })
		HistoryPicture("doorbell", function(h, hcode, herr, hms)
			PrintReport({ line("last ring", h, hcode, herr, hms) })
			HistoryPicture("motionsensor", function(m, mcode, merr, mms)
				PrintReport({ line("last motion", m, mcode, merr, mms) })
			end)
		end)
	end)
end

local function RemoveFromDoorBird()
	if not Configured() then return PrintReport({ "Remove From DoorBird: the DoorBird is not set up" }) end
	-- No sync while (and after) it runs; a failed removal leaves the events as they are
	gCfg.paused = true
	RegistrationRemove(gBird, gCfg.token, function(ok, count, err)
		gCfg.paused = ok
		SaveCfg()
		gReg.state, gReg.summary = ok and "removed" or "failed", ok and ("removed from the DoorBird (" .. count .. " HTTP calls) - Reconnect registers them again") or tostring(err)
		PrintReport({ "Remove From DoorBird: " .. (ok and ("OK, " .. count .. " HTTP call" .. (count == 1 and "" or "s") .. " removed. Run Reconnect to register them again.") or ("FAILED - " .. tostring(err))) })
		UpdateEventsProperty()
		UpdateStatus()
	end, "Remove From DoorBird")
end

--[[=============================================================================
    Commands, actions, proxy messages
===============================================================================]]
local ACTIONS = {
	PrintDiagnostics = PrintDiagnostics,
	TestPictures = TestPictures,
	Reconnect = function()
		-- Entries left alone (taken by another app, or refused) are tried once more
		gReg.skip = {}
		gCfg.paused = false
		SaveCfg()
		SetTargetAuthFailed(gBird, false)
		gBird.lockedUntil = 0
		gPerm.checkedAt = nil
		gState.pageFor = nil
		Connect("reconnect")
	end,
	OpenDoor = function() OpenDoor("1", "Composer action") end,
	LightOn = function() LightOn("Composer action") end,
	RemoveFromDoorBird = RemoveFromDoorBird,
}

local function SetAlertOnMotion(on)
	UpdateProperty("Alert On Motion", on and "On" or "Off")
	gState.alertEpisodeAt = nil
	LogInfo("Alert on motion: %s", on and "On" or "Off")
end

local COMMANDS = {
	OPEN_DOOR = function(p) OpenDoor(p["Relay"] or p.RELAY or p.relay or "1", "programming") end,
	LIGHT_ON = function() LightOn("programming") end,
	SET_ALERT_ON_MOTION = function(p)
		local s = string.upper(p["State"] or p.STATE or "TOGGLE")
		if s == "ON" then SetAlertOnMotion(true)
		elseif s == "OFF" then SetAlertOnMotion(false)
		else SetAlertOnMotion(not AlertOnMotion()) end
	end,
}

-- Edits on the camera's Properties page: the driver's properties own those values, so they are put back
local PAGE_COMMANDS = { SET_ADDRESS = true, SET_HTTP_PORT = true, SET_HTTPS_PORT = true, SET_USE_HTTPS = true, SET_USERNAME = true,
	SET_PASSWORD = true, SET_AUTHENTICATION_REQUIRED = true, SET_AUTHENTICATION_TYPE = true, SET_RTSP_PORT = true, SET_RSTP_PORT = true }

local function PageEdited(cmd)
	if os.time() - (gState.pageWrittenAt or 0) <= 10 then return end -- our own write coming back
	if not Configured() then return end
	local login = cmd == "SET_USERNAME" or cmd == "SET_PASSWORD"
	SetTimer("PAGE_RESTORE", 2000, function()
		local p = ReadProxyProperties()
		if p and PageMatches(p) and not login then return end
		LogInfo("The camera page follows the driver's Address, Username and Password (%s changed): putting it back", cmd)
		WriteProxySettings("camera page edited")
	end)
end

local function LogRequest(name, tParams, result)
	if LOG_LEVEL >= 4 then
		local parts = {}
		for k, v in pairs(tParams or {}) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
		table.sort(parts)
		LogDebug("%s(%s) -> %s", name, table.concat(parts, ", "), result)
	end
end

-- The camera proxy builds http://<address>/<path> and rtsp://<address>:<rtsp port>/<path> with the page's login
UI_REQ = {}
UI_REQ.GET_SNAPSHOT_QUERY_STRING = function(tParams)
	LogRequest("GET_SNAPSHOT_QUERY_STRING", tParams, SNAPSHOT_PATH)
	return "<snapshot_query_string>" .. XmlEscape(SNAPSHOT_PATH) .. "</snapshot_query_string>"
end
UI_REQ.GET_RTSP_H264_QUERY_STRING = function(tParams)
	LogRequest("GET_RTSP_H264_QUERY_STRING", tParams, RTSP_PATH .. " (port " .. RtspPort() .. ")")
	return "<rtsp_h264_query_string>" .. XmlEscape(RTSP_PATH) .. "</rtsp_h264_query_string>"
end
UI_REQ.GET_RTSP_H264_QUERY = UI_REQ.GET_RTSP_H264_QUERY_STRING
UI_REQ.GET_MJPEG_QUERY_STRING = function(tParams)
	LogRequest("GET_MJPEG_QUERY_STRING", tParams, MJPEG_PATH)
	return "<mjpeg_query_string>" .. XmlEscape(MJPEG_PATH) .. "</mjpeg_query_string>"
end
UI_REQ.GET_MJPEG_QUERY = UI_REQ.GET_MJPEG_QUERY_STRING

--[[=============================================================================
    DriverWorks entry points
===============================================================================]]
-- Never reorder: Director numbers variables in this order and other drivers read them.
local VARIABLES = {
	{ "DIRECTORLINK_CAMERA", "1", "STRING" },
	{ "DIRECTORLINK_CAMERA_KIND", "doorbell", "STRING" },
	{ "LAST_ALERT", "", "STRING" },
	{ "LAST_RING", "", "STRING" },
	{ "LAST_MOTION", "", "STRING" },
	{ "LAST_DOORBELL", "", "STRING" },
	{ "LAST_RFID", "", "STRING" },
	{ "LAST_RELAY", "", "STRING" },
	{ "LAST_DOOR_OPENED", "", "STRING" },
	{ "LAST_EVENT", "", "STRING" },
	{ "ONLINE", "0", "BOOL" },
}

-- Written on every start, so they are right after a driver update too
local function SetAgreementVariables()
	SetVar("DIRECTORLINK_CAMERA", "1", true)
	SetVar("DIRECTORLINK_CAMERA_KIND", "doorbell", true)
end

function OnDriverInit()
	math.randomseed(os.time())
	gState.startedAt = os.time()
	LoadCfg()
	-- Director starts added variables at their default: the last ring, alert and the rest come back
	for _, v in ipairs(VARIABLES) do
		local saved = gState.savedVars[v[1]]
		if type(saved) == "string" and v[3] == "STRING" and v[1] ~= "DIRECTORLINK_CAMERA" and v[1] ~= "DIRECTORLINK_CAMERA_KIND" then v[2] = saved end
	end
	AddVariables(VARIABLES)
	RestoreRelayBindings()
	gBird.onAuthChange = function() UpdateStatus() end
	SetTargetLogin(gBird, Properties["Address"], Properties["Username"], Properties["Password"])
end

local function StartEventServer()
	gServer.onState = function(state)
		if state == "listening" and gServer.port ~= gCfg.port then
			gCfg.port = gServer.port
			SaveCfg()
		end
		if UpdateEventsProperty then UpdateEventsProperty() end
		-- A new port once connected: the HTTP calls must point at it (at startup, Connect registers them)
		if state == "listening" and gState.online == true then SyncEvents("event server") end
	end
	local base = gCfg.port or (EVENT_PORT_BASE + ((MyDeviceId() or 0) % 100))
	EventServerStart(base)
end

function OnDriverLateInit(dit)
	ApplyLogSettings()
	SetLogPrefix()
	pcall(function()
		local build = tostring(C4:GetDriverConfigInfo("version") or "")
		UpdateProperty("Driver Version", DRIVER_SEMVER ~= "dev" and (DRIVER_SEMVER .. " (" .. build .. ")") or build)
	end)
	SetAgreementVariables()
	SetVar("ONLINE", false)
	if dit == "DIT_ADDING" or (DIT_ADDING ~= nil and dit == DIT_ADDING) then
		pcall(function()
			C4:SendToProxy(CAMERA_PROXY, "PROPERTY_DEFAULTS", {
				HTTP_PORT = "80", RTSP_PORT = "554", AUTHENTICATION_REQUIRED = "true", AUTHENTICATION_TYPE = "BASIC",
			}, "NOTIFY")
		end)
	end
	RestoreDynamicEvents()
	for _, v in pairs(gCfg.relays) do
		if v.binding then pcall(function() C4:SendToProxy(v.binding, "STATE_OPENED", {}, "NOTIFY") end) end
	end
	gState.ctrlIp = ControllerAddress()
	SetAttention("proxy", nil, true) -- also hides the empty Attention line
	UpdateDeviceProperties()
	UpdatePermissions()
	UpdateEventsProperty()
	UpdateStatus()
	StartEventServer()
	SetTimer("HEALTH", HEALTH_MS, HealthCheck, true)
	if #gCfg.olds > 0 then SetTimer("OLD_RETRY", 30000, LeaveOldDoorBird) end
	if Configured() then SetTimer("CONNECT", 2000, function() Connect("startup") end) end
end

function OnDriverDestroyed()
	EventServerStop()
	KillAllTimers()
end

-- Deleted from the project: this driver's HTTP calls leave the DoorBird, at the DoorBird's usual pace.
-- Control4 may stop the driver before that is done: Remove From DoorBird first is the sure way.
function OnDriverRemovedFromProject()
	if gState.removed then return end
	gState.removed = true
	if not Configured() or not gCfg.token then return end
	LogInfo("The driver was deleted: removing its HTTP calls from the DoorBird at %s", gBird.host)
	RegistrationAbort(gBird)
	TargetCancelQueue(gBird, "the driver was deleted")
	RegistrationRemove(gBird, gCfg.token, function(ok, count, err)
		if ok then LogInfo("Removed %d HTTP calls from the DoorBird", count) else LogWarn("Removing the HTTP calls: %s", tostring(err)) end
	end, "the driver was deleted")
end

function OnPropertyChanged(name)
	local value = Properties[name]
	if name == "Password" then value = "***" end
	LogDebug("Property changed: %s = %s", name, value)
	if name == "Log Level" then
		ApplyLogSettings()
	elseif name == "Address" or name == "Username" or name == "Password" then
		-- Applied once the installer is done typing
		SetTimer("LOGIN_APPLY", 1500, ApplyLogin)
	elseif name == "Live Video" then
		WriteProxySettings("Live Video " .. tostring(Properties["Live Video"]))
		if not gBird.verified then gState.pageFor = nil end
	elseif name == "Alert On Motion" then
		gState.alertEpisodeAt = nil
	end
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
	tParams = tParams or {}
	if LOG_LEVEL >= 4 and string.sub(strCommand, 1, 4) ~= "GET_" then
		local parts = {}
		for k, v in pairs(tParams) do
			parts[#parts + 1] = tostring(k) .. "=" .. (string.find(string.upper(tostring(k)), "PASSWORD", 1, true) and "***" or tostring(v))
		end
		LogDebug("ReceivedFromProxy(%s, %s, {%s})", idBinding, strCommand, table.concat(parts, ", "))
	end

	-- A relay connection (a Relay Door, Gate or Garage Controller bound to it): a pulse only
	local relay = RelayOfBinding(idBinding)
	if relay then
		if strCommand == "CLOSE" or strCommand == "TRIGGER" or strCommand == "TOGGLE" then
			OpenDoor(relay, RelayLabel(relay) .. " connection")
		elseif strCommand == "OPEN" then
			-- The relay is at rest already: nothing to send
			pcall(function() C4:SendToProxy(idBinding, "OPENED", {}, "NOTIFY") end)
		elseif strCommand == "GET_STATE" then
			pcall(function() C4:SendToProxy(idBinding, "STATE_OPENED", {}, "NOTIFY") end)
		end
		return
	end

	if UI_REQ[strCommand] then
		local ok, res = pcall(UI_REQ[strCommand], tParams)
		if ok then return res end
		LogError("%s failed: %s", strCommand, res)
		return
	end

	if PAGE_COMMANDS[strCommand] then PageEdited(strCommand) end
end

-- The camera proxy takes its answers (snapshot and video paths) from UIRequest
function UIRequest(strCommand, tParams)
	local handler = UI_REQ[strCommand]
	if handler then
		local ok, res = pcall(handler, tParams or {})
		if ok then return res end
		LogError("UIRequest %s failed: %s", strCommand, res)
	end
	return ""
end

function ExecuteCommand(strCommand, tParams)
	tParams = tParams or {}
	if strCommand == "LUA_ACTION" then
		local action = ACTIONS[tParams.ACTION]
		if action then
			LogDebug("Action %s", tostring(tParams.ACTION))
			local ok, err = pcall(action)
			if not ok then LogError("Action %s failed: %s", tostring(tParams.ACTION), err) end
		end
		return
	end
	local cmd = COMMANDS[strCommand]
	if cmd then
		LogInfo("Command %s", strCommand)
		local ok, err = pcall(cmd, tParams)
		if not ok then LogError("Command %s failed: %s", strCommand, err) end
	end
end

-- The Relay list of Open Door (a DYNAMIC_LIST parameter)
function GetCommandParamList(commandName, paramName)
	if commandName == "OPEN_DOOR" and paramName == "Relay" then
		local list = {}
		for _, r in ipairs(gInfo.relays) do list[#list + 1] = r end
		if #list == 0 then
			for r in pairs(gCfg.relays) do list[#list + 1] = r end
			table.sort(list)
		end
		if #list == 0 then list = { "1" } end
		return list
	end
	return {}
end

function TestCondition(name, tParams)
	tParams = tParams or {}
	if name == "DOORBIRD_ONLINE" then return TestBool(gState.online == true, tParams, "Online")
	elseif name == "ALERT_ON_MOTION" then return TestBool(AlertOnMotion(), tParams, "On")
	end
	return false
end

-- Notification attachment: the picture taken at the last ring or motion alert
function GetNotificationAttachmentURL()
	return ""
end

function GetNotificationAttachmentBytes()
	if gState.eventPicture then return Base64Encode(gState.eventPicture) end
	return ""
end

function FinishedWithNotificationAttachment()
end

-- Relay connections are restored here, in the main body, before Director restores their bindings
RestoreRelayBindings()

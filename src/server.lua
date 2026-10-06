--[[=============================================================================
    DirectorLink DoorBird - event server on the controller
    The DoorBird calls this driver's HTTP favorites when a schedule entry
    fires (a doorbell press, motion, an RFID tag, a relay):

      GET /doorbird?e=<event>&p=<param>&t=<token>

    A call is taken only from the DoorBird's own address and with this
    driver's token (a random secret that is never logged). Everything else
    is refused with 403 and logged at Debug with where it came from.
    "selftest" (Print Diagnostics) is taken from the controller itself only
    and fires nothing.

    The driver sets:
      EventServerSource()         -> the DoorBird's IP address (nil until known)
      EventServerToken()          -> the token
      EventServerDeliver(e, p, ip)   called after the answer is sent

    Copyright 2026 DirectorLink
    SPDX-License-Identifier: Apache-2.0
===============================================================================]]

EVENT_PATH = "/doorbird"
EVENT_MAX_CLIENTS = 16
EVENT_HEAD_TIMEOUT_S = 5
EVENT_MAX_HEADER = 4096
EVENT_PORT_TRIES = 20

gServer = {
	server = nil, port = nil, wantPort = nil, state = "stopped", error = nil, tries = 0,
	clients = {}, clientCount = 0, accepted = 0, refused = 0, lastRefused = nil, onState = nil,
}

local STATUS_TEXT = { [200] = "OK", [400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found",
	[405] = "Method Not Allowed", [503] = "Service Unavailable" }

local function RemoteIp(client)
	local ok, a = pcall(function() return client:GetRemoteAddress() end)
	if ok and type(a) == "table" and a.ip then return tostring(a.ip) end
	return "?"
end

local function Forget(client)
	if gServer.clients[client] then
		gServer.clients[client] = nil
		gServer.clientCount = gServer.clientCount - 1
	end
end

local function Respond(client, code, body)
	body = body or ""
	local data = table.concat({
		"HTTP/1.1 " .. code .. " " .. (STATUS_TEXT[code] or "Error"),
		"Content-Type: text/plain; charset=utf-8",
		"Content-Length: " .. #body,
		"Cache-Control: no-store",
		"Connection: close",
	}, "\r\n") .. "\r\n\r\n" .. body
	pcall(function() client:Write(data):Close(true) end)
	Forget(client)
end

-- method, path, query from a request head
function ParseRequestHead(text)
	local method, target = string.match(text, "^(%u+)%s+(%S+)%s+HTTP/%d%.%d\r?\n")
	if not method then return nil end
	local path, query = string.match(target, "^([^?]*)%??(.*)$")
	return method, path, query or ""
end

-- An IPv4 address as the server reports it ("::ffff:192.168.1.20" on a dual-stack socket)
local function PlainIp(ip)
	return string.match(tostring(ip or ""), "(%d+%.%d+%.%d+%.%d+)$") or tostring(ip or "")
end

local function Refuse(client, ip, why)
	gServer.refused = gServer.refused + 1
	gServer.lastRefused = { at = os.time(), ip = ip, why = why }
	LogDebug("Event call from %s refused: %s", ip, why)
	Respond(client, 403, "Forbidden\n")
end

local function HandleRequest(client, text)
	if not gServer.clients[client] then return end
	local ip = PlainIp(RemoteIp(client))
	if #text > EVENT_MAX_HEADER then return Refuse(client, ip, "request too long") end
	local method, path, query = ParseRequestHead(text)
	if not method then
		LogDebug("Event call from %s: not HTTP", ip)
		return Respond(client, 400, "Bad request\n")
	end
	if path ~= EVENT_PATH then
		LogDebug("Event call from %s for another path -> 404", ip)
		return Respond(client, 404, "Not found\n")
	end
	if method ~= "GET" then return Respond(client, 405, "Only GET\n") end
	local token = EventServerToken()
	local e, p, t = QueryValue(query, "e") or "", QueryValue(query, "p") or "", QueryValue(query, "t")
	if not token or token == "" or t ~= token then
		return Refuse(client, ip, t and "wrong token" or "no token")
	end
	if e == "selftest" then
		local own = ControllerAddress()
		if ip == "127.0.0.1" or (own and ip == own) then
			LogDebug("Event server self-test from %s: OK", ip)
			return Respond(client, 200, "OK\n")
		end
		return Refuse(client, ip, "self-test from another address")
	end
	local source = EventServerSource()
	if not source then return Refuse(client, ip, "the DoorBird's address is not known yet") end
	if ip ~= source then return Refuse(client, ip, "not the DoorBird (" .. source .. ")") end
	gServer.accepted = gServer.accepted + 1
	if e == "keypad" then RegisterCode(p) end
	LogDebug("Event call from the DoorBird (%s): %s%s", ip, e, p ~= "" and (" " .. p) or "")
	Respond(client, 200, "OK\n")
	local ok, err = pcall(EventServerDeliver, e, p, ip)
	if not ok then LogError("Event %s failed: %s", e, err) end
end

local function Accept(srv, client)
	if gServer.clientCount >= EVENT_MAX_CLIENTS then
		LogDebug("Event server: too many connections, refusing one")
		pcall(function() client:Write("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"):Close(true) end)
		return
	end
	gServer.clients[client] = { at = os.time() }
	gServer.clientCount = gServer.clientCount + 1
	pcall(function()
		client
			:OnRead(function(_, data)
				local ok, err = pcall(HandleRequest, client, data or "")
				if not ok then
					LogError("Event call failed: %s", err)
					Respond(client, 503, "Error\n")
				end
			end)
			:OnDisconnect(function() Forget(client) end)
			:OnError(function() Forget(client) end)
			:ReadUntil("\r\n\r\n")
	end)
end

local function SetState(state, err)
	gServer.state, gServer.error = state, err
	if gServer.onState then pcall(gServer.onState, state, err) end
end

local function Sweep()
	local now = os.time()
	for client, info in pairs(gServer.clients) do
		if now - info.at > EVENT_HEAD_TIMEOUT_S then
			pcall(function() client:Close() end)
			Forget(client)
		end
	end
end

function EventServerStop()
	KillTimer("EVENT_SWEEP")
	KillTimer("EVENT_RETRY")
	if gServer.server then
		local s = gServer.server
		gServer.server = nil
		pcall(function() s:Close() end)
	end
	for client in pairs(gServer.clients) do pcall(function() client:Close() end) end
	gServer.clients, gServer.clientCount = {}, 0
	gServer.port = nil
	SetState("stopped")
end

local Listen -- forward

-- Does anything answer at host:port (another copy of this driver)? done(true) on any HTTP answer,
-- and on doubt (a timeout); done(false) only when the connection is refused: nothing listens there.
-- It asks for "/", which a copy answers with 404 without counting a refused call. Without an
-- answer in EVENT_PROBE_WAIT_MS it counts as doubt: done(true).
EVENT_PROBE_WAIT_MS = 10000

function EventServerProbe(host, port, done)
	local called, timer = false, "EVENT_PROBE_" .. tostring(port)
	local function finish(answers)
		if called then return end
		called = true
		KillTimer(timer)
		done(answers)
	end
	SetTimer(timer, EVENT_PROBE_WAIT_MS, function() finish(true) end)
	local ok = pcall(function()
		local x = C4:url()
		x:SetOptions({ fail_on_error = false, timeout = 5, connect_timeout = 3 })
		x:OnDone(function(_, responses, errCode, errMsg)
			local resp = type(responses) == "table" and responses[#responses] or nil
			if resp and tonumber(resp.code) and tonumber(resp.code) > 0 then return finish(true) end
			local refused = errCode == 7 or string.find(string.lower(tostring(errMsg or "")), "couldn't connect", 1, true) ~= nil
			finish(not refused)
		end)
		x:Get("http://" .. host .. ":" .. port .. "/", {})
	end)
	if not ok then finish(true) end
end

-- A port in use: the next one (each copy of the driver on a controller needs its own)
local function NextPort()
	gServer.tries = gServer.tries + 1
	if gServer.tries >= EVENT_PORT_TRIES then
		SetState("error", gServer.error)
		LogError("Event server: no free port from %d to %d", gServer.firstPort, gServer.firstPort + EVENT_PORT_TRIES - 1)
		SetTimer("EVENT_RETRY", 60000, function() EventServerStart(gServer.firstPort) end)
		return
	end
	Listen(gServer.firstPort + gServer.tries)
end

Listen = function(port)
	if gServer.server then
		local s = gServer.server
		gServer.server = nil
		pcall(function() s:Close() end)
	end
	gServer.wantPort = port
	local server
	local ok, err = pcall(function()
		server = C4:CreateTCPServer()
		gServer.server = server
		server
			:OnListen(function(srv)
				if gServer.server ~= srv then return end
				local okA, addr = pcall(function() return srv:GetLocalAddress() end)
				gServer.port = okA and type(addr) == "table" and tonumber(addr.port) or port
				LogInfo("Event server listening on port %d", gServer.port)
				SetState("listening")
			end)
			:OnError(function(srv, code, msg)
				if gServer.server ~= srv then return end
				gServer.error = tostring(msg or code)
				if gServer.state ~= "listening" then
					LogDebug("Event server: port %d not available (%s)", port, tostring(msg or code))
					gServer.server = nil
					pcall(function() srv:Close() end)
					NextPort()
				else
					LogError("Event server error: %s (%s)", tostring(msg), tostring(code))
				end
			end)
			:OnAccept(Accept)
			:Listen("*", port)
	end)
	if not ok then
		LogError("Event server could not start on port %d: %s", port, tostring(err))
		gServer.error = tostring(err)
		gServer.server = nil
		NextPort()
	end
end

function EventServerStart(firstPort)
	EventServerStop()
	gServer.firstPort = tonumber(firstPort) or 47300
	gServer.tries = 0
	SetState("starting")
	Listen(gServer.firstPort)
	SetTimer("EVENT_SWEEP", 5000, Sweep, true)
end

function EventServerListening()
	return gServer.state == "listening" and gServer.port ~= nil
end

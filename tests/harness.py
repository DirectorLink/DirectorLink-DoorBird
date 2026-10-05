"""In-process test harness: runs the driver's assembled Lua in a real Lua 5.1 runtime
(lupa) against a stubbed Control4 API. No network access.

HTTP (C4:url) is answered by a Python `responder(method, url, headers, body)` that
returns (code, headers, body). With d.async_http() replies wait for d.flush_http(),
so ordering bugs show. The TCP server (the event server), TCP clients (name
resolution), dynamic events and bindings, the clock and timers are stubbed too,
and every log line is captured.

The clock is virtual: NOW_MS starts at 2025-10-05 18:00 UTC (ms) and d.pump() runs the one-shot
timers in the order they fall due, moving the clock to each one, so the driver's
one-request-per-second pacing runs as it would on a controller.
"""
import base64
import hashlib
import json
import os
import re
import sys

import lupa.lua51 as lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "tests", "fixtures")
sys.path.insert(0, os.path.join(ROOT, "tools"))
import build  # noqa: E402  (assemble_lua)

STUB = r"""
EVENTS = {}; VARS = {}; PROXY = {}; DEVICE_CMDS = {}; TIMERS = {}; PERSIST = {}; HISTORY = {}; ATTRIBS = {}
HTTP_LOG = {}; LOGS = {}; HTTP_QUEUE = {}; DYN_EVENTS = {}; BINDINGS = {}; EVENT_VARS = {}; VAR_LOG = {}
PROXY_PROPS = ""; DEVICE_ID = 900; PROXY_DEVICE = 901; CONTROLLER_IP = "192.168.50.10"; OS_VERSION = "3.4.3.123"
NOW_MS = 1759687200000; HTTP_ASYNC = false; BUSY_PORTS = {}; SERVERS = {}; RESOLVE = {}; DISPLAY_NAME = "Front Door"
local timerSeq = 0
C4 = {}
VAR_ORDER = {}
function C4:AddVariable(n, v) VARS[n] = v; VAR_ORDER[#VAR_ORDER + 1] = n; return 1, true end
function C4:SetVariable(n, v) VARS[n] = v; VAR_LOG[#VAR_LOG + 1] = n end
local function snapshotVars(n) EVENT_VARS[#EVENT_VARS + 1] = { n, VARS["LAST_ALERT"], VARS["LAST_RING"], VARS["LAST_DOORBELL"] } end
function C4:FireEvent(n) EVENTS[#EVENTS + 1] = n; snapshotVars(n) end
function C4:FireEventByID(id) local n = DYN_EVENTS[id] or ("#" .. tostring(id)); EVENTS[#EVENTS + 1] = n; snapshotVars(n) end
function C4:AddEvent(id, name, desc) DYN_EVENTS[id] = name; return true end
function C4:AddDynamicBinding(id, kind, provider, name, class, hidden, auto) BINDINGS[id] = { name = name, class = class, kind = kind, provider = provider } end
function C4:UpdateProperty(n, v) Properties[n] = v end
function C4:SetPropertyAttribs(n, v) ATTRIBS[n] = v end
function C4:SendToProxy(b, c, p, k) PROXY[#PROXY + 1] = { b, c, p } end
function C4:SendToDevice(id, c, p, allowEmpty, log) DEVICE_CMDS[#DEVICE_CMDS + 1] = { id, c, p, log } end
function C4:GetProxyDevices() return PROXY_DEVICE end
function C4:GetDeviceID() return DEVICE_ID end
function C4:GetDeviceDisplayName(id) return DISPLAY_NAME end
function C4:SendUIRequest(id) return PROXY_PROPS end
function C4:RecordHistory(...) HISTORY[#HISTORY + 1] = { ... } end
function C4:GetControllerNetworkAddress() return CONTROLLER_IP end
function C4:GetVersionInfo() return { version = OS_VERSION } end
function C4:GetTime() return NOW_MS end
function C4:PersistSetValue(n, v, enc) PERSIST[n] = v; PERSIST_ENC = PERSIST_ENC or {}; PERSIST_ENC[n] = enc and true or false end
function C4:PersistGetValue(n) return PERSIST[n] end
function C4:PersistDeleteValue(n) PERSIST[n] = nil end
function C4:GetDriverConfigInfo() return "1000001" end
function C4:DebugLog(s) LOGS[#LOGS + 1] = s end
function C4:ErrorLog(s) LOGS[#LOGS + 1] = s end
function C4:Hash(alg, s, opts) return PY_HASH(alg, s, opts and opts.return_encoding or "HEX") end
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function C4:Base64Encode(s)  -- pure Lua: binary data must not cross into Python as text
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = string.byte(s, i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1, c2 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64
    local c3, c4 = math.floor(n / 64) % 64, n % 64
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end
function C4:Base64Decode(s) return PY_B64D(s) end
function C4:SetTimer(ms, fn, rep)
  timerSeq = timerSeq + 1
  local t = { id = timerSeq, ms = ms, due = NOW_MS + ms, fn = fn, rep = rep, active = true }
  function t:Cancel() self.active = false end
  TIMERS[#TIMERS + 1] = t
  return t
end
-- Run the one-shot timers that fall due within `window` ms of the clock, earliest first, moving the
-- clock to each (so a chain of paced requests runs to its end; a timer further away waits)
function Pump(window, maxRuns)
  local runs = 0
  while runs < (maxRuns or 1000) do
    local limit = NOW_MS + (window or 5000)
    local best, bi
    for i, t in ipairs(TIMERS) do
      if t.active and not t.rep and t.due <= limit and (not best or t.due < best.due or (t.due == best.due and t.id < best.id)) then best, bi = t, i end
    end
    if not best then break end
    table.remove(TIMERS, bi)
    best.active = false
    if best.due > NOW_MS then NOW_MS = best.due end
    best.fn(best)
    runs = runs + 1
    if #TIMERS > 2000 then
      local keep = {}
      for _, t in ipairs(TIMERS) do if t.active then keep[#keep + 1] = t end end
      TIMERS = keep
    end
  end
  return runs
end
function RunRepeatingTimers(name)
  for _, t in ipairs(TIMERS) do if t.active and t.rep and (not name or t.ms == name) then t.fn(t) end end
end
function PendingTimers()
  local out = {}
  for _, t in ipairs(TIMERS) do if t.active then out[#out + 1] = t.ms end end
  return out
end
-- C4:url(): answered by PY_HTTP, at once or (HTTP_ASYNC) when FlushHttp() runs
function C4:url()
  local x = { opts = {} }
  function x:SetOptions(o) self.opts = o; return self end
  function x:OnDone(f) self.done = f; return self end
  local function run(self, method, url, body, headers)
    HTTP_LOG[#HTTP_LOG + 1] = { method = method, url = url, headers = headers, body = body, opts = self.opts, at = NOW_MS }
    local function answer()
      local code, hdrs, rbody = PY_HTTP(method, url, headers, body)
      if code == nil then self.done(self, {}, 7, "Couldn't connect to server") return end
      self.done(self, { { code = code, headers = hdrs, body = rbody } }, 0, nil)
    end
    if HTTP_ASYNC then HTTP_QUEUE[#HTTP_QUEUE + 1] = answer else answer() end
    return self
  end
  function x:Get(url, headers) return run(self, "GET", url, nil, headers) end
  function x:Post(url, body, headers) return run(self, "POST", url, body, headers) end
  function x:Put(url, body, headers) return run(self, "PUT", url, body, headers) end
  function x:Custom(url, m, body, headers) return run(self, m, url, body, headers) end
  return x
end
function FlushHttp()
  local n = 0
  while #HTTP_QUEUE > 0 do
    local q = HTTP_QUEUE; HTTP_QUEUE = {}
    for _, f in ipairs(q) do f(); n = n + 1 end
  end
  return n
end
-- TCP server: Listen succeeds at once unless the port is in BUSY_PORTS
function C4:CreateTCPServer()
  local s = { cb = {} }
  for _, m in ipairs({ "OnResolve", "OnListen", "OnError", "OnAccept" }) do s[m] = function(self, f) self.cb[m] = f; return self end end
  function s:Listen(host, port)
    self.host, self.port = host, port
    SERVERS[#SERVERS + 1] = self
    if BUSY_PORTS[port] then self.cb.OnError(self, 98, "Address already in use") else self.cb.OnListen(self, { ip = "0.0.0.0", port = port }) end
    return self
  end
  function s:GetLocalAddress() return { ip = "0.0.0.0", port = self.port } end
  function s:Close() self.closed = true end
  return s
end
-- TCP client: only name resolution is used (OnResolve, then the driver cancels)
function C4:CreateTCPClient()
  local c = { cb = {} }
  for _, m in ipairs({ "OnResolve", "OnConnect", "OnError", "OnRead", "OnDisconnect" }) do c[m] = function(self, f) self.cb[m] = f; return self end end
  function c:Connect(host, port)
    local ip = RESOLVE[host]
    local endpoints = ip and { { ip = ip, port = port } } or {}
    local choice = self.cb.OnResolve and self.cb.OnResolve(self, endpoints, function() end)
    if choice == 0 and self.cb.OnError then self.cb.OnError(self, 22, "Invalid argument") end
    return self
  end
  function c:Close() return self end
  return c
end
-- A client connection to the open server: FakeRequest(client, text) delivers a request head
function FakeConnect(ip)
  local srv
  for i = #SERVERS, 1, -1 do if not SERVERS[i].closed then srv = SERVERS[i] break end end
  local c = { cb = {}, written = {}, closed = false, ip = ip or "192.168.50.20" }
  for _, m in ipairs({ "OnRead", "OnWrite", "OnDisconnect", "OnError" }) do c[m] = function(self, f) self.cb[m] = f; return self end end
  function c:ReadUntil(d) self.reading = d; return self end
  function c:Write(data) self.written[#self.written + 1] = data; return self end
  function c:Close() self.closed = true; return self end
  function c:GetRemoteAddress() return { ip = self.ip, port = 50000 } end
  srv.cb.OnAccept(srv, c)
  return c
end
function FakeRequest(c, text) if c.cb.OnRead then c.cb.OnRead(c, text) end end
function Written(c) return table.concat(c.written) end
print = function(s) LOGS[#LOGS + 1] = tostring(s) end
"""


def defaults_from_xml(path):
    xml = open(path, encoding="utf-8").read()
    props = {}
    for block in re.findall(r"<property>(.*?)</property>", xml, re.S):
        name = re.search(r"<name>(.*?)</name>", block).group(1)
        d = re.search(r"<default>(.*?)</default>", block, re.S)
        props[name] = d.group(1) if d else ""
    return props


def fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return f.read()


def fixture_json(name):
    return json.loads(fixture(name))


def py_hash(alg, s, enc):
    data = s.encode("latin-1")
    h = {"MD5": hashlib.md5, "SHA1": hashlib.sha1, "SHA256": hashlib.sha256}[str(alg).upper()](data)
    if str(enc).upper() == "BASE64":
        return base64.b64encode(h.digest()).decode()
    return h.hexdigest().upper()


class Driver:
    """The driver in a fresh Lua state. props: property values; persist: saved values (a restart)."""

    def __init__(self, responder=None, props=None, persist=None, device_id=900, controller_ip=None):
        self.lua = lupa.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
        g = self.lua.globals()
        self.responder = responder or (lambda m, u, h, b: (None, None, None))
        g.PY_HASH = py_hash
        g.PY_B64D = lambda s: base64.b64decode(s).decode("latin-1")
        g.PY_HTTP = self._http
        defaults = defaults_from_xml(os.path.join(ROOT, "src", "driver.xml"))
        defaults.update(props or {})
        g.Properties = self.lua.table_from(defaults)
        self.lua.execute(STUB)
        g.DEVICE_ID = device_id
        if controller_ip:
            g.CONTROLLER_IP = controller_ip
        for k, v in (persist or {}).items():
            g.PERSIST[k] = v
        self.lua.execute(build.assemble_lua("test"))
        self.g = g

    def _http(self, method, url, headers, body):
        h = dict(headers) if headers is not None else {}
        code, rh, rb = self.responder(method, url, h, body)
        if code is None:
            return None, None, None
        return code, self.lua.table_from(rh or {}), rb

    # ---- lifecycle
    def start(self, dit="DIT_ADDING", pump=True):
        self.call("OnDriverInit", dit)
        self.call("OnDriverLateInit", dit)
        if pump:
            self.pump()
        return self

    # ---- helpers
    def call(self, fn, *args):
        return self.g[fn](*args)

    def table(self, d):
        return self.lua.table_from(d)

    def run(self, code):
        self.lua.execute(code)

    def eval(self, code):
        return self.lua.eval(code)

    def pump(self, window=5000, max_runs=1000):
        return self.call("Pump", window, max_runs)

    def now(self):
        return self.g.NOW_MS

    def advance(self, ms):
        self.g.NOW_MS = self.g.NOW_MS + ms

    def events(self):
        return list(self.g.EVENTS.values())

    def event_vars(self):
        return [list(x.values()) for x in self.g.EVENT_VARS.values()]

    def clear(self):
        self.lua.execute("EVENTS = {}; PROXY = {}; DEVICE_CMDS = {}; HTTP_LOG = {}; HISTORY = {}; EVENT_VARS = {}; VAR_LOG = {}")

    def var(self, name):
        return self.g.VARS[name]

    def prop(self, name):
        return self.g.Properties[name]

    def set_prop(self, name, value, apply=True):
        self.g.Properties[name] = value
        self.call("OnPropertyChanged", name)
        if apply:
            self.pump()

    def action(self, name):
        self.call("ExecuteCommand", "LUA_ACTION", self.table({"ACTION": name}))

    def command(self, name, params=None):
        self.call("ExecuteCommand", name, self.table(params or {}))

    def proxy(self, cmd=None, binding=None):
        out = []
        for m in self.g.PROXY.values():
            if (cmd is None or m[2] == cmd) and (binding is None or m[1] == binding):
                out.append((m[1], m[2], dict(m[3]) if m[3] is not None else {}))
        return out

    def device_cmds(self, cmd=None):
        out = []
        for m in self.g.DEVICE_CMDS.values():
            if cmd is None or m[2] == cmd:
                out.append((m[1], m[2], dict(m[3]) if m[3] is not None else {}, m[4]))
        return out

    def http_log(self):
        out = []
        for e in self.g.HTTP_LOG.values():
            out.append({"method": e.method, "url": e.url, "headers": dict(e.headers) if e.headers else {}, "body": e.body,
                        "at": e.at})
        return out

    def logs(self):
        return [str(x) for x in self.g.LOGS.values()]

    def dyn_events(self):
        return {int(k): v for k, v in self.g.DYN_EVENTS.items()}

    def bindings(self):
        return {int(k): dict(v) for k, v in self.g.BINDINGS.items()}

    def persisted(self):
        def to_py(v):
            if lupa.lua_type(v) == "table":
                return {k: to_py(x) for k, x in v.items()}
            return v
        return {k: to_py(v) for k, v in self.g.PERSIST.items()}

    def async_http(self, on=True):
        self.g.HTTP_ASYNC = on

    def flush_http(self):
        return self.call("FlushHttp")

    # ---- the event server
    def callback(self, query, ip="192.168.50.30", method="GET", path="/doorbird"):
        """A call to the event server, as the DoorBird makes it. Returns (status code, response text)."""
        c = self.call("FakeConnect", ip)
        self.call("FakeRequest", c, f"{method} {path}?{query} HTTP/1.1\r\nHost: {self.g.CONTROLLER_IP}\r\nConnection: close\r\n\r\n")
        text = self.call("Written", c)
        m = re.match(r"HTTP/1\.1 (\d+)", text or "")
        return (int(m.group(1)) if m else None), text

    def server_port(self):
        return self.eval("gServer.port")

    def token(self):
        return self.eval("gCfg.token")


FAILS = []


def check(cond, label):
    print(("PASS " if cond else "FAIL ") + label)
    if not cond:
        FAILS.append(label)


def finish():
    print()
    if FAILS:
        print(f"{len(FAILS)} FAILED")
        sys.exit(1)
    print("ALL PASSED")

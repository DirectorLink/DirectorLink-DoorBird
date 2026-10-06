"""The driver against a DoorBird (tests/fake_doorbird.py, answers from tests/fixtures).
    python tests/test_driver.py

Connecting and reading info.cgi, the permission checks, registering the HTTP calls
(favorites and schedule) without touching anything else on the DoorBird, the event
server, the DirectorLink camera agreement, alerts, pictures, relays (a pulse only),
the camera page, a refused login, the lockout, leaving the DoorBird (address change,
Remove From DoorBird, the driver deleted), a restart, and that no log line shows the
password, the event token or another app's URL.
"""
import base64
import copy
import re

from harness import Driver, check, finish
from fake_doorbird import HOST, PASSWORD, USER, DoorBird

PROPS = {"Address": HOST, "Username": USER, "Password": PASSWORD, "Log Level": "Debug"}
OTHER_SECRET = "Xq7-server-Secret"  # in another app's favorite URL (fixture favorites_d2101v.json)


def setup(bird=None, props=None, persist=None, start=True, controller_ip=None, **kw):
    bird = bird or DoorBird(**kw)
    p = dict(PROPS)
    p.update(props or {})
    d = Driver(bird, props=p, persist=persist, controller_ip=controller_ip)
    bird.clock = d.now
    if start:
        d.start()
    return d, bird


def logs_clean(d, *extra):
    text = "\n".join(d.logs())
    leaks = [s for s in (PASSWORD, d.token(), OTHER_SECRET) + extra if s and s in text]
    return not leaks, leaks


def tick(d, seconds=60):
    """A minute (or more) on the controller: the health check runs."""
    d.advance(seconds * 1000)
    d.call("RunRepeatingTimers")
    d.pump()


def gaps(bird, calls=None):
    ats = [c["at"] for c in (calls or bird.calls)]
    return [b - a for a, b in zip(ats, ats[1:])]


def own_output(bird, input_, param, fid):
    e = bird.entry(input_, param)
    return next((o for o in (e or {}).get("output", []) if o["event"] == "http" and o["param"] == fid), None)


# ================================================================ connecting and registering
d, bird = setup()
token = d.token()
check(isinstance(token, str) and re.fullmatch(r"[0-9a-f]{32}", token or "") is not None, "a random 32-character event token")
check(d.var("DIRECTORLINK_CAMERA") == "1" and d.var("DIRECTORLINK_CAMERA_KIND") == "doorbell", "DirectorLink agreement: DIRECTORLINK_CAMERA = 1, kind doorbell")
order = list(d.g.VAR_ORDER.values())
check(order[:4] == ["DIRECTORLINK_CAMERA", "DIRECTORLINK_CAMERA_KIND", "LAST_ALERT", "LAST_RING"], f"variables keep their order ({order[:4]})")
check(d.server_port() == 47300, f"event server on port 47300 ({d.server_port()})")
check(bird.requests("/bha-api/info.cgi")[0]["user"] == USER, "info.cgi with the Control4 user's Basic login")
check(d.prop("DoorBird") == "DoorBird D2101V · firmware 000141 · relays 1, 2", f"the DoorBird line: model, firmware, its own relays ({d.prop('DoorBird')})")
check(all(d.eval(f"gPerm.{k}") is True for k in ("operator", "watch", "history", "motion")), "permissions checked")
check(d.prop("Status") == "Online - events live" and d.eval("ProblemsText()") == "", f"Status, nothing to fix ({d.prop('Status')})")
check(d.eval("gReg.summary") == "registered: doorbell 1, motion, RFID, relay 1, relay 2", f"events registered ({d.eval('gReg.summary')})")
b = d.bindings()
check({k: v["name"] for k, v in b.items()} == {301: "Relay 1", 302: "Relay 2", 303: "Relay ghchdi@1", 304: "Relay ghchdi@2"}
      and all(v["class"] == "RELAY" and v["kind"] == "CONTROL" and v["provider"] for v in b.values()), "one RELAY connection per DoorBird relay")
check(d.dyn_events() == {}, f"one bell button: no per-button events (Ring is it), no per-relay events ({d.dyn_events()})")
check(d.proxy("ICON_CHANGED", 5001) and d.proxy("ICON_CHANGED", 5001)[-1][2]["icon"] == "idle", "the DoorBird tile shows idle")

own = bird.own_favorite_ids(token)
favs = bird.http_favorites()
titles = sorted(favs[i]["title"] for i in own)
check(titles == sorted(["DirectorLink (doorbell 1)", "DirectorLink (motion)", "DirectorLink (RFID)", "DirectorLink (relay 1)", "DirectorLink (relay 2)"]),
      f"one HTTP favorite per event ({titles})")
fid = {favs[i]["title"]: i for i in own}
check(favs[fid["DirectorLink (doorbell 1)"]]["value"] == f"http://192.168.50.10:47300/doorbird?e=doorbell&p=1&t={token}", "the favorite calls the controller with the event and the token")
check(bird.outputs_of("doorbell", "1") == [("notify", ""), ("http", "0"), ("sip", "0"), ("http", fid["DirectorLink (doorbell 1)"])],
      f"doorbell 1: the other outputs kept, this driver's added last ({bird.outputs_of('doorbell', '1')})")
o = own_output(bird, "doorbell", "1", fid["DirectorLink (doorbell 1)"])
check(o == {"event": "http", "param": fid["DirectorLink (doorbell 1)"], "enabled": "1", "schedule": {"weekdays": [{"from": "108000", "to": "107999"}]}},
      f"the output is active the whole week, written like the DoorBird's own ({o})")
check(own_output(bird, "relay", "2", fid["DirectorLink (relay 2)"])["schedule"] == {"weekdays": [{"from": "104400", "to": "104399"}]},
      "a new entry: the whole week as Home Assistant writes it")
check([x[1] for x in bird.outputs_of("motion")] == ["", "1", "2", fid["DirectorLink (motion)"]], "motion: registered")
check(own_output(bird, "rfid", "0012345678", fid["DirectorLink (RFID)"]) and own_output(bird, "rfid", "0087654321", fid["DirectorLink (RFID)"]),
      "RFID: one favorite, on each tag")
check(bird.outputs_of("relay", "1") == [("http", fid["DirectorLink (relay 1)"])], "relay 1: the DoorBird's empty entry gets the HTTP call")
check(bird.outputs_of("relay", "2") == [("http", fid["DirectorLink (relay 2)"])], "relay 2: entry created")
check(bird.entry("relay", "ghchdi@1") is None, "a door controller's relay gets no schedule (the DoorBird does not report those)")
same, why = bird.others_unchanged(token)
check(same, f"every other favorite and schedule output is exactly as it was {why}")
check(any('"schedule":{}' in p for p in bird.raw_posts) and any('"valid":1' in p for p in bird.raw_posts),
      "an entry written back keeps {} and numbers as they were")
g = gaps(bird)
check(len(bird.calls) > 10 and min(g) >= 1000, f"requests one at a time, at least one second apart ({len(bird.calls)} requests, smallest gap {min(g)} ms)")
check(all(c["headers"].get("User-Agent", "").startswith("DirectorLink-DoorBird/") for c in bird.calls), "User-Agent DirectorLink-DoorBird/<version>")
logs = "\n".join(d.logs())
check("GET info.cgi -> 200" in logs and "POST schedule.cgi save doorbell 1 (4 outputs) -> 200" in logs
      and "GET favorites.cgi save 'DirectorLink (motion)' (new) -> 200" in logs, "Debug: a line for every request")
clean, leaks = logs_clean(d)
check(clean, f"no log line shows the password, the token or another app's URL {leaks}")
check(not [x for x in d.logs() if "0012345678" in x or "0087654321" in x] and "save RFID *** (2 outputs)" in logs,
      "nor the RFID tag numbers (a tag can be copied from its number)")

# the camera page
cmds = {c[1]: c[2] for c in d.device_cmds()}
check(cmds.get("SET_ADDRESS") == {"ADDRESS": HOST} and cmds.get("SET_HTTP_PORT") == {"PORT": "80"} and cmds.get("SET_RTSP_PORT") == {"PORT": "554"}
      and cmds.get("SET_AUTHENTICATION_TYPE") == {"TYPE": "BASIC"} and cmds.get("SET_AUTHENTICATION_REQUIRED") == {"REQUIRED": "True"},
      "camera page: address, HTTP 80, RTSP 554, Basic login required")
check(cmds.get("SET_USERNAME") == {"USERNAME": USER} and cmds.get("SET_PASSWORD") == {"PASSWORD": PASSWORD}
      and all(c[3] is False for c in d.device_cmds()), "camera page: the Control4 user's login (not logged by Director)")
check(d.device_cmds() and all(c[0] == 902 for c in d.device_cmds()), "written to the DoorBird Camera device (not the tile)")
check(d.call("UIRequest", "GET_SNAPSHOT_QUERY_STRING", d.table({"SIZE_X": "320"})) == "<snapshot_query_string>bha-api/image.cgi</snapshot_query_string>", "snapshot: image.cgi")
check(d.call("UIRequest", "GET_RTSP_H264_QUERY_STRING", d.table({})) == "<rtsp_h264_query_string>mpeg/media.amp</rtsp_h264_query_string>", "live video: RTSP H.264 mpeg/media.amp")
check(d.call("UIRequest", "GET_MJPEG_QUERY_STRING", d.table({})) == "<mjpeg_query_string>bha-api/video.cgi</mjpeg_query_string>", "fallback: MJPEG video.cgi")
d.clear()
tick(d)
check(not [c for c in d.device_cmds()] and d.eval("gState.pageFor ~= nil") is True, "the camera page is not read or written again every minute")
# RTSP over HTTP: port 8557 set on the camera page is kept (for networks where 554 is blocked)
page = ("<properties><address>{a}</address><http_port>80</http_port><rtsp_port>{r}</rtsp_port><authentication_required>True</authentication_required>"
        "<authentication_type>BASIC</authentication_type><username>{u}</username><use_https>False</use_https></properties>")
d.g.PROXY_PROPS = page.format(a=HOST, r=8557, u=USER)
d.call("ReceivedFromProxy", 5002, "SET_RTSP_PORT", d.table({"PORT": "8557"}))
d.advance(12000)
d.pump()
check(not d.device_cmds(), "RTSP Port 8557 on the camera page is kept")
d.g.PROXY_PROPS = page.format(a=HOST, r=1554, u=USER)
d.eval("(function() gState.pageWrittenAt = 0 end)()")
d.call("ReceivedFromProxy", 5002, "SET_RTSP_PORT", d.table({"PORT": "1554"}))
d.advance(3000)
d.pump()
check({c[1]: c[2] for c in d.device_cmds()}.get("SET_RTSP_PORT") == {"PORT": "554"}, "another port is put back to 554")
d.g.PROXY_PROPS = page.format(a=HOST, r=8557, u=USER)
d.clear()
d.action("Reconnect")
for _ in range(3):
    d.pump()
check({c[1]: c[2] for c in d.device_cmds()}.get("SET_RTSP_PORT") == {"PORT": "8557"}, "and kept when the page is written again (Reconnect)")
d.g.PROXY_PROPS = ""

# a later check changes nothing
before = len(bird.calls)
d.eval("(function() gState.lastSyncAt = 0 end)()")
tick(d)
later = bird.calls[before:]
check([c["path"] for c in later] == ["/bha-api/info.cgi", "/bha-api/favorites.cgi", "/bha-api/schedule.cgi"]
      and all(c["method"] == "GET" and not c["query"] for c in later), f"the 30-minute check only reads ({[c['path'] for c in later]})")

# ================================================================ events from the DoorBird
d.clear()
code, _ = d.callback(f"e=doorbell&p=1&t={token}", ip=HOST)
check(code == 200, "the DoorBird's call is answered 200")
check(d.proxy("ICON_CHANGED", 5001)[-1][2] == {"icon": "ring", "icon_description": "Someone rang"}, "the tile shows the ring at once")
d.pump()
ev = d.events()
check(ev == ["Ring"], f"Ring, with its picture ({ev})")
ring = [x for x in d.event_vars() if x[0] == "Ring"][0]
check(re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", ring[2] or "") is not None and ring[3] == "1",
      f"LAST_RING (ISO 8601 UTC) and LAST_DOORBELL are set when Ring fires ({ring})")
pic = base64.b64decode(d.call("GetNotificationAttachmentBytes"))
check(pic[:2] == b"\xff\xd8" and b"LIVE" in pic, "the notification picture is the live picture at the ring")
check(d.var("LAST_EVENT") == "Doorbell 1", "LAST_EVENT")
check("Event call from the DoorBird (192.168.50.30): doorbell 1" in "\n".join(d.logs()), "Debug: a line for every call")
d.clear()
d.advance(2000)
code, _ = d.callback(f"e=doorbell&p=1&t={token}", ip=HOST)
check(code == 200 and d.events() == [], "a repeat within 5 s: answered, but one press is one ring")
d.advance(6000)
d.callback(f"e=doorbell&p=1&t={token}", ip=HOST)
d.pump()
check(d.events() == ["Ring"], "after 5 s it rings again")
d.callback(f"e=motion&t={token}", ip=HOST)
check(d.proxy("ICON_CHANGED", 5001)[-1][2]["icon"] == "ring", "motion right after a ring does not hide the ring on the tile")
d.advance(31000)
d.pump()
check(d.proxy("ICON_CHANGED", 5001)[-1][2]["icon"] == "idle", "30 s later the tile is back to idle")

# refused calls
d.clear()
for label, q, ip in (("from another address", f"e=doorbell&p=1&t={token}", "192.168.50.99"),
                     ("with a wrong token", "e=doorbell&p=1&t=0000", HOST), ("without a token", "e=doorbell&p=1", HOST),
                     ("a self-test from the DoorBird", f"e=selftest&t={token}", HOST)):
    code, _ = d.callback(q, ip=ip)
    check(code == 403, f"refused (403): a call {label}")
check(d.events() == [], "refused calls fire nothing")
check(d.callback(f"e=doorbell&p=1&t={token}", ip=HOST, path="/other")[0] == 404, "another path: 404")
check(d.callback(f"e=doorbell&p=1&t={token}", ip=HOST, method="POST")[0] == 405, "not GET: 405")
check(d.eval("gServer.refused") >= 4 and "refused: not the DoorBird (192.168.50.30)" in "\n".join(d.logs()), "refused calls are counted and logged")
d.advance(6000)
check(d.callback(f"e=garage&t={token}", ip=HOST)[0] == 200 and d.events() == [], "an event the driver does not know: answered, nothing fires")

# motion and alerts
d.clear()
d.callback(f"e=motion&t={token}", ip=HOST)
d.pump()
check(d.events() == ["Motion Detected"] and d.var("LAST_MOTION"), "motion: Motion Detected, LAST_MOTION; Alert On Motion is Off by default")
d.set_prop("Alert On Motion", "On")
d.clear()
d.advance(6000)
d.callback(f"e=motion&t={token}", ip=HOST)
d.pump()
check(d.events() == ["Motion Detected", "Alert"], f"Alert On Motion: Motion Detected, then Alert ({d.events()})")
alert = [x for x in d.event_vars() if x[0] == "Alert"][0]
check(alert[1] == "Motion", "LAST_ALERT is 'Motion' when Alert fires")
d.clear()
d.advance(20000)
d.callback(f"e=motion&t={token}", ip=HOST)
d.pump()
check(d.events() == ["Motion Detected"], "more motion within the hold time: no new alert")
d.clear()
d.advance(45000)
d.callback(f"e=motion&t={token}", ip=HOST)
d.pump()
check(d.events() == ["Motion Detected"], "the hold time runs from the last motion: still one alert")
d.clear()
d.advance(61000)
d.callback(f"e=motion&t={token}", ip=HOST)
d.pump()
check(d.events() == ["Motion Detected", "Alert"], "after the hold time without motion: a new alert")
d.command("SET_ALERT_ON_MOTION", {"State": "Off"})
check(d.prop("Alert On Motion") == "Off" and d.call("TestCondition", "ALERT_ON_MOTION", d.table({"VALUE": "On"})) is False, "SET_ALERT_ON_MOTION and its conditional")

# RFID, relays
d.clear()
d.callback(f"e=rfid&t={token}", ip=HOST)
check(d.events() == ["RFID Read"] and d.var("LAST_RFID"), "RFID: RFID Read, LAST_RFID")
d.clear()
d.callback(f"e=relay&p=2&t={token}", ip=HOST)
check(d.events() == ["Door Opened"] and d.var("LAST_RELAY") == "2", f"relay 2: Door Opened, LAST_RELAY 2 ({d.events()})")
check(d.proxy("ICON_CHANGED", 5001)[-1][2]["icon"] == "open", "the tile shows the gate opening")
check([p[1] for p in d.proxy(binding=302)] == ["CLOSED"], "the Relay 2 connection shows the pulse")
d.pump()
# As at a real gate: a ring, the gate opened for the visitor 10 s later, motion as they walk in
g, _ = setup()
gt = g.token()
g.callback(f"e=doorbell&p=1&t={gt}", ip=HOST)
g.pump(100)
g.advance(10000)
g.callback(f"e=relay&p=1&t={gt}", ip=HOST)
check(g.proxy("ICON_CHANGED", 5001)[-1][2]["icon"] == "open", "a ring, then the gate opening: the tile shows the gate opening")
g.callback(f"e=motion&t={gt}", ip=HOST)
check(g.proxy("ICON_CHANGED", 5001)[-1][2]["icon"] == "open", "motion right after does not hide it")
g.advance(6000)
g.callback(f"e=doorbell&p=1&t={gt}", ip=HOST)
check(g.proxy("ICON_CHANGED", 5001)[-1][2]["icon"] == "ring", "a new ring shows again at once")
check([p[1] for p in d.proxy(binding=302)] == ["CLOSED", "OPENED"], "then OPENED again")
check(d.call("TestCondition", "DOORBIRD_ONLINE", d.table({"VALUE": "Online"})) is True, "DoorBird is Online")

# ================================================================ opening doors: a pulse only
d.clear()
n0 = len(bird.opened)
d.call("ReceivedFromProxy", 301, "CLOSE", d.table({}))
d.pump()
check(bird.opened[n0:] == ["1"], "a Gate Controller's CLOSE on Relay 1: open-door.cgi?r=1, once")
check(d.events() == ["Door Opened"] and d.var("LAST_RELAY") == "1", "Door Opened fires, LAST_RELAY 1")
d.clear()
d.callback(f"e=relay&p=1&t={token}", ip=HOST)
check(d.events() == [], "the DoorBird's own call for that pulse is a repeat")
d.call("ReceivedFromProxy", 301, "OPEN", d.table({}))
d.call("ReceivedFromProxy", 301, "TRIGGER", d.table({"TIME": "500"}))
d.pump()
check(bird.opened[n0:] == ["1"], "OPEN sends nothing; a second pulse within 2 s is not sent: the relay is never held")
check(d.proxy("OPENED", 301), "OPEN answers OPENED")
d.advance(3000)
d.call("ReceivedFromProxy", 301, "TOGGLE", d.table({}))
d.pump()
check(bird.opened[n0:] == ["1", "1"], "TOGGLE later: one more pulse")
d.clear()
d.call("ReceivedFromProxy", 301, "GET_STATE", d.table({}))
check(d.proxy("STATE_OPENED", 301), "GET_STATE: at rest (STATE_OPENED)")
d.command("OPEN_DOOR", {"Relay": "ghchdi@1"})
d.pump()
check(bird.opened[-1] == "ghchdi@1", "OPEN_DOOR on a door controller's relay")
lst = d.call("GetCommandParamList", "OPEN_DOOR", "Relay")
check(list(lst.values()) == ["1", "2", "ghchdi@1", "ghchdi@2"], "OPEN_DOOR lists the DoorBird's relays")
d.advance(3000)
d.action("OpenGate")
d.command("LIGHT_ON")
d.pump()
check(bird.opened[-1] == "1" and bird.lights == 1, "Open Gate action (Gate Relay: Relay 1) and the IR light")

# the tile: a tap opens the gate (Gate Relay)
d.advance(3000)
n0 = len(bird.opened)
d.call("ReceivedFromProxy", 5001, "SELECT", d.table({}))
d.pump()
check(bird.opened[n0:] == ["1"], "a tap on the DoorBird tile opens relay 1")
d.set_prop("Gate Relay", "Relay 2")
d.advance(3000)
d.call("ReceivedFromProxy", 5001, "SELECT", d.table({}))
d.pump()
check(bird.opened[n0:] == ["1", "2"], "Gate Relay = Relay 2: the tap opens relay 2")
d.set_prop("Gate Relay", "Nothing")
d.advance(3000)
d.call("ReceivedFromProxy", 5001, "SELECT", d.table({}))
d.pump()
check(bird.opened[n0:] == ["1", "2"], "Gate Relay = Nothing: a tap opens nothing")
d.set_prop("Gate Relay", "Relay 1")
check(all(c["path"] != "/bha-api/open-door.cgi" or "r" in c["query"] for c in bird.calls), "open-door.cgi always names its relay")

# ================================================================ diagnostics
def self_test_router(drv):
    def route(method, url, headers, body):
        m = re.match(r"http://192\.168\.50\.10:(\d+)/doorbird\?(.*)$", url)
        if m:
            code, text = drv.callback(m.group(2), ip="192.168.50.10")
            return code, {}, text.split("\r\n\r\n", 1)[1]
        return bird(method, url, headers, body)
    return route


d.responder = self_test_router(d)
d.g.LOGS = d.table({})
d.action("PrintDiagnostics")
d.pump()
report = "\n".join(d.logs())
check("DoorBird D2101V, firmware 000141 (build 16418935), MAC 1C:CA:E3:71:2A:4F" in report and "Relays        : 1, 2, ghchdi@1, ghchdi@2 - Gate Relay: Relay 1" in report
      and "API-Operator: yes, Watch Always: yes" in report, "Print Diagnostics: device, firmware, MAC, relays, permissions")
check("self-test OK" in report, "Print Diagnostics: the event server answers its self-test")
check(f"'DirectorLink (doorbell 1)' -> http://192.168.50.10:47300/doorbird?e=doorbell&p=1&t=***" in report, "Print Diagnostics: this driver's favorites, token hidden")
check("other HTTP favorites: 3 ('Gate log', 'Home Assistant (front_door_motion)', 'ServerX'), SIP favorites: 1" in report
      and "192.168.50.40" not in report and OTHER_SECRET not in report, "Print Diagnostics: other favorites by title only, never their URLs")
check("doorbell 1: push notifications, HTTP #0 'Gate log', sip 0, HTTP #" in report and "relay 2: HTTP #" in report and "[entry made by this driver]" in report,
      "Print Diagnostics: the schedule entries with this driver's HTTP calls")
check("door opened, relay 1 (Relay 1 connection)" in report and "IR light on (programming)" in report and "motion (alert)" in report,
      "Print Diagnostics: the last events")
check(token not in report and PASSWORD not in report, "Print Diagnostics shows neither the token nor the password")
d.responder = bird
d.g.LOGS = d.table({})
d.action("TestPictures")
d.pump()
tp = "\n".join(d.logs())
check("Test Pictures live: OK" in tp and "Test Pictures last ring: OK" in tp and "Test Pictures last motion: OK" in tp, "Test Pictures: live, last ring, last motion")
clean, leaks = logs_clean(d)
check(clean, f"still nothing secret in the log {leaks}")

# ================================================================ a restart keeps everything
d2, _ = setup(bird=bird, persist=d.persisted(), start=False)
check(d2.bindings().keys() == b.keys(), "a restart: the relay connections are back before Director restores bindings (main body)")
calls_before = len(bird.calls)
d2.start(dit="DIT_STARTUP")
for _ in range(3):
    d2.pump()
writes = [c for c in bird.calls[calls_before:] if c["method"] == "POST" or c["query"].get("action")]
check(not writes, f"a restart writes nothing to the DoorBird ({[(c['path'], c['query']) for c in writes]})")
check(d2.token() == token and d2.dyn_events() == d.dyn_events(), "same token, same programming events")
check(d2.var("LAST_RING") == d.var("LAST_RING") and d2.var("LAST_DOORBELL") == "1", "LAST_RING and the rest come back after a restart")
check(d2.prop("Status") == "Online - events live", f"and it is live again ({d2.prop('Status')})")

# ================================================================ the controller's address changes
d2.g.CONTROLLER_IP = "192.168.50.11"
ids_before = bird.own_favorite_ids(token)
tick(d2)
for _ in range(3):
    d2.pump()
check(bird.own_favorite_ids(token) == ids_before and all("192.168.50.11:47300" in bird.http_favorites()[i]["value"] for i in ids_before),
      "a new controller address: the same favorites now point at it")

# ================================================================ Remove From DoorBird
d2.g.LOGS = d2.table({})
d2.action("RemoveFromDoorBird")
for _ in range(3):
    d2.pump()
check(bird.own_favorite_ids(token) == [], "Remove From DoorBird: this driver's favorites are gone")
check(bird.entry("relay", "2") is None and bird.outputs_of("relay", "1") == [], "the relay 2 entry it made is gone; relay 1 is back to the DoorBird's empty entry")
same, why = bird.others_unchanged(token)
check(same, f"and everything else is as it was {why}")
check("Remove From DoorBird: OK" in "\n".join(d2.logs()) and d2.prop("Status").startswith("Online - events off"), f"Status says so ({d2.prop('Status')})")
calls_before = len(bird.calls)
d2.eval("(function() gState.lastSyncAt = 0 end)()")
tick(d2)
check(not [c for c in bird.calls[calls_before:] if c["path"] != "/bha-api/info.cgi"], "it does not register again by itself")
d2.action("Reconnect")
for _ in range(3):
    d2.pump()
check(len(bird.own_favorite_ids(token)) == 5 and d2.prop("Status") == "Online - events live", "Reconnect registers them again")

# ================================================================ permissions
d, bird = setup(operator=False)
check(d.prop("Status") == f"Online, but no events: give the DoorBird user '{USER}' the API-Operator permission (DoorBird app: Administration, Users)",
      f"no API-Operator: refused clearly ({d.prop('Status')})")
check("lacks API-Operator" in d.eval("ProblemsText()") and d.eval("gPerm.operator") is False, "and listed as the thing to fix")
check(not [c for c in bird.calls if c["method"] == "POST" or c["query"].get("action")], "nothing is written")
n = len(bird.calls)
d.eval("(function() gState.lastSyncAt = 0 end)()")
tick(d)
check([c["path"] for c in bird.calls[n:]] == ["/bha-api/info.cgi", "/bha-api/favorites.cgi"], "it asks again once per 30 minutes (one read)")
n = len(bird.calls)
tick(d)
check([c["path"] for c in bird.calls[n:]] == ["/bha-api/info.cgi"], "and not every minute")
check(bird.wrong_logins == 0, "a missing permission is not taken for a wrong password")
bird.operator = True
d.eval("(function() gState.lastSyncAt = 0 end)()")
tick(d)
for _ in range(3):
    d.pump()
check(d.prop("Status") == "Online - events live", f"once the permission is given, the events register by themselves ({d.prop('Status')})")

d, bird = setup(watch=False, history=False, motion=False)
check(d.eval("gPerm.watch") is False and d.eval("gPerm.history") is False and d.eval("gPerm.motion") is False, "no Watch Always, History, Motion: found")
check(d.prop("Status").startswith("Online - events live. The DoorBird user 'ghchdi0002' also needs: Watch Always"), f"Status says it ({d.prop('Status')})")
d.clear()
d.call("ReceivedFromProxy", 301, "CLOSE", d.table({}))
d.pump()
check(bird.opened == [] and d.events() == [] and "lacks Watch Always" in "\n".join(d.logs()), "a door not opened (204) says why and fires nothing")
d.clear()
d.callback(f"e=doorbell&p=1&t={d.token()}", ip=HOST)
d.pump()
check(d.events() == ["Ring"] and d.call("GetNotificationAttachmentBytes") == "", "a ring without pictures still rings")

d, bird = setup(watch=False)
d.callback(f"e=doorbell&p=1&t={d.token()}", ip=HOST)
d.pump()
check(b"HIST" in base64.b64decode(d.call("GetNotificationAttachmentBytes")), "without Watch Always: the DoorBird's own ring picture (history.cgi)")

# ================================================================ a wrong password costs one try
d, bird = setup(props={"Password": "wrong"})
check(len(bird.calls) == 1 and bird.wrong_logins == 1, f"a refused login: one request ({len(bird.calls)})")
check(d.prop("Status").startswith(f"Login refused by the DoorBird at {HOST} for user '{USER}'"), f"Status says so ({d.prop('Status')})")
for _ in range(5):
    tick(d)
check(len(bird.calls) == 1 and not bird.locked, "no more requests: the DoorBird never blocks this controller (or the official driver on it)")
d.set_prop("Password", PASSWORD)
d.pump()
check(d.prop("Status") == "Online - events live", f"the right password: connected ({d.prop('Status')})")
clean, leaks = logs_clean(d, "wrong")
check(clean, f"neither password is logged {leaks}")

d, bird = setup(start=False)
bird.locked = True
d.start()
check(d.prop("Status").startswith("The DoorBird blocks this controller for a minute"), f"423: waits ({d.prop('Status')})")
n = len(bird.calls)
tick(d, 30)
check(len(bird.calls) == n, "nothing is sent while blocked")
bird.locked = False
d.advance(40000)
d.pump(70000)
for _ in range(3):
    d.pump()
check(d.prop("Status") == "Online - events live", f"after the minute: connected ({d.prop('Status')})")

# ================================================================ a DoorBird that keeps one HTTP call per event
d, bird = setup(one_http_per_input=True)
same, why = bird.others_unchanged(d.token())
check(same, f"the other apps' HTTP calls are put back {why}")
check(bird.outputs_of("doorbell", "1") == [("notify", ""), ("http", "0"), ("sip", "0")], "doorbell 1 is exactly as it was")
check("doorbell 1: the DoorBird keeps one HTTP call for doorbell 1, and HTTP call 'Gate log' has it" in d.eval("ProblemsText()"),
      f"it names who has it ({d.eval('ProblemsText()')})")
check(d.prop("Status").startswith("Online - some events not registered. Events - doorbell 1: the DoorBird keeps one HTTP call")
      and "not registered: doorbell 1, motion" in d.eval("gReg.summary"), f"Status and summary ({d.prop('Status')} / {d.eval('gReg.summary')})")
check("relay 1" in d.eval("gReg.summary").split(" - ")[0] and "RFID" in d.eval("gReg.summary").split(" - ")[0], "the events nobody else uses are registered")
n = len(bird.calls)
for _ in range(3):
    d.eval("(function() gState.lastSyncAt = 0 end)()")
    tick(d)
check(not [c for c in bird.calls[n:] if c["method"] == "POST"], "the taken entries are left alone at the next checks (no retry that would push the other app's call out again)")
check("Gate log" in d.eval("ProblemsText()"), "and it still says who has them")
d2, _ = setup(bird=bird, persist=d.persisted(), start=False)
d2.start(dit="DIT_STARTUP")
for _ in range(3):
    d2.pump()
check(not [c for c in bird.calls[n:] if c["method"] == "POST"], "also after a restart")
bird.entry("doorbell", "1")["output"] = [o for o in bird.entry("doorbell", "1")["output"] if o["param"] != "0" or o["event"] != "http"]
bird.original_schedule[0]["output"] = list(bird.entry("doorbell", "1")["output"])
d2.eval("(function() gState.lastSyncAt = 0 end)()")
tick(d2)
for _ in range(3):
    d2.pump()
check(("http", bird.own_favorite_ids(d2.token())[0]) in bird.outputs_of("doorbell", "1"), "once the other app's call is gone, doorbell 1 is registered")
n = len(bird.calls)
d2.action("Reconnect")
for _ in range(4):
    d2.pump()
motion_posts = [c for c in bird.calls[n:] if c["method"] == "POST" and '"input":"motion"' in c["body"]]
check(len(motion_posts) == 2 and d2.eval("gReg.skip['motion|'] ~= nil") is True and bird.others_unchanged(d2.token())[0],
      f"Reconnect tries a taken entry once more (one try, one put-back), then leaves it alone again ({len(motion_posts)} posts)")

# ================================================================ a DoorBird without relay schedules
d, bird = setup(relay_input=False)
same, why = bird.others_unchanged(d.token())
check(same, f"nothing else touched {why}")
att = d.eval("ProblemsText()")
check("relay 2: the DoorBird does not take a schedule for relay 2 (HTTP 400)" in att and "relay 1: the DoorBird does not take a schedule for relay 1 (HTTP 400)" in att,
      f"relay events not available: said plainly ({att})")
n = len(bird.calls)
d.eval("(function() gState.lastSyncAt = 0 end)()")
tick(d)
check(not [c for c in bird.calls[n:] if c["method"] == "POST"] and "relay 2: the DoorBird does not take a schedule" in d.eval("ProblemsText()"),
      "and it does not keep asking")
check(d.prop("Status").startswith("Online - some events not registered"), "the rest works")

# ================================================================ no favoriteid header: the ids are read back
d, bird = setup(favoriteid_header=False)
check(d.prop("Status") == "Online - events live" and len(bird.own_favorite_ids(d.token())) == 5, "without the favoriteid header the ids are read back")

# ================================================================ two buttons, old firmware, a busy port
d, bird = setup(schedule="schedule_two_buttons.json", info="info_d1101v_wifi.json", favorites="favorites_empty.json")
check(d.dyn_events() == {101: "Ring (Button 1)", 102: "Ring (Button 2)"}, f"two buttons: a Ring event each ({d.dyn_events()})")
check(d.eval("gInfo.mac") == "1CCAE3712B70", "a WiFi DoorBird's MAC")
d.clear()
d.callback(f"e=doorbell&p=2&t={d.token()}", ip=HOST)
d.pump()
check(d.events() == ["Ring (Button 2)", "Ring"] and d.var("LAST_DOORBELL") == "2", f"button 2 rings as button 2 ({d.events()})")

d, bird = setup(info="info_d101_000096.json")
check(d.prop("Status") == "Online, but no events: firmware 000096 is too old for them (000110 or newer)", f"old firmware: said plainly ({d.prop('Status')})")
check(not bird.requests("/bha-api/favorites.cgi") and d.bindings().get(301, {}).get("name") == "Relay 1", "no favorites asked; relay 1 assumed")

d, bird = setup(start=False)
d.g.BUSY_PORTS[47300] = True
d.start()
check(d.server_port() == 47301 and ":47301/doorbird" in bird.http_favorites()[bird.own_favorite_ids(d.token())[0]]["value"], "a busy port: the next one, and the favorites use it")

# ================================================================ an address by name
d, bird = setup(bird=DoorBird(host="frontdoor.local"), props={"Address": "frontdoor.local"}, start=False)
d.g.RESOLVE["frontdoor.local"] = "192.168.50.30"
d.start()
check(d.callback(f"e=rfid&t={d.token()}", ip="192.168.50.30")[0] == 200, "an Address by name: calls from its IP are taken")
d.advance(6000)
check(d.callback(f"e=rfid&t={d.token()}", ip="192.168.50.31")[0] == 403, "and from another IP refused")

# ================================================================ earlier copies of this driver
bird = DoorBird()
stale = "ffffffffffffffffffffffffffffffff"
bird.http_favorites()["8"] = {"title": "DirectorLink (doorbell 1)", "value": f"http://192.168.50.10:47300/doorbird?e=doorbell&p=1&t={stale}"}
bird.http_favorites()["9"] = {"title": "DirectorLink (doorbell 1)", "value": f"http://192.168.50.77:47300/doorbird?e=doorbell&p=1&t={stale}"}
bird.entry("doorbell", "1")["output"].append({"event": "http", "param": "8", "schedule": {"weekdays": [{"from": "0", "to": "604799"}]}})
bird.entry("doorbell", "1")["output"].append({"event": "http", "param": "9", "schedule": {"weekdays": [{"from": "0", "to": "604799"}]}})
d, _ = setup(bird=bird)
check("8" not in bird.http_favorites() and ("http", "8") not in bird.outputs_of("doorbell", "1"),
      "a favorite an earlier copy left at this controller and port is removed (output first)")
check("9" in bird.http_favorites() and ("http", "9") in bird.outputs_of("doorbell", "1"), "one at another controller is left alone")

# At another port of this controller: removed only when nothing answers there (a copy still
# running, as when a new version is added next to the old one, keeps its own)
bird = DoorBird()
live, dead = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "dddddddddddddddddddddddddddddddd"
bird.http_favorites()["10"] = {"title": "DirectorLink (doorbell 1)", "value": f"http://192.168.50.10:47301/doorbird?e=doorbell&p=1&t={live}"}
bird.http_favorites()["11"] = {"title": "DirectorLink (doorbell 1)", "value": f"http://192.168.50.10:47305/doorbird?e=doorbell&p=1&t={dead}"}
bird.http_favorites()["12"] = {"title": "Gate log", "value": f"http://192.168.50.10:47306/doorbird?e=doorbell&p=1&t={dead}"}
for fid in ("10", "11", "12"):
    bird.entry("doorbell", "1")["output"].append({"event": "http", "param": fid, "schedule": {"weekdays": [{"from": "0", "to": "604799"}]}})
d, _ = setup(bird=bird, start=False)
d.listening = {47301}
d.start()
check("10" in bird.http_favorites() and ("http", "10") in bird.outputs_of("doorbell", "1"),
      "a copy of this driver that answers at another port keeps its favorite (no tug of war)")
check("11" not in bird.http_favorites() and ("http", "11") not in bird.outputs_of("doorbell", "1"),
      "one at a port where nothing answers is an earlier copy's: removed (output first)")
check("12" in bird.http_favorites() and ("http", "12") in bird.outputs_of("doorbell", "1"), "a favorite with another title is never this driver's")
check(d.prop("Status") == "Online - events live" and logs_clean(d, live, dead)[0], "and the driver works")

# ================================================================ keypad codes
# A D2101KV keeps a keypad code as a "doorbell" entry with the code as param (0047 opens relay 1 by itself)
bird = DoorBird()
bird.schedule.append({"input": "doorbell", "param": "0047", "output": [
    {"event": "relay", "param": "1", "schedule": {"weekdays": [{"from": "108000", "to": "107999"}]}}]})
bird.original_schedule = copy.deepcopy(bird.schedule)
d, _ = setup(bird=bird)
kfav = [i for i in bird.own_favorite_ids(d.token()) if bird.http_favorites()[i]["title"] == "DirectorLink (keypad code 0047)"]
check(len(kfav) == 1 and "e=keypad&p=0047&" in bird.http_favorites()[kfav[0]]["value"], "a keypad code gets its own favorite")
check(bird.outputs_of("doorbell", "0047") == [("relay", "1"), ("http", kfav[0])], "the code still opens relay 1 itself, the HTTP call is added last")
check(d.dyn_events() == {} and "keypad code 0047" in d.eval("gReg.summary"),
      f"registered, and a code is not a bell button: no Ring event for it ({d.dyn_events()})")
check(bird.others_unchanged(d.token())[0], "nothing else touched")
d.clear()
d.callback(f"e=keypad&p=0047&t={d.token()}", ip=HOST)
d.pump()
check(d.events() == ["Keypad Code Entered"] and d.var("LAST_KEYPAD_CODE") == "0047" and d.var("LAST_EVENT") == "Keypad code",
      f"Keypad Code Entered, LAST_KEYPAD_CODE 0047 for programming, not in LAST_EVENT ({d.events()})")
check(not d.proxy("ICON_CHANGED", 5001), "a code does not show as a ring")
d.callback(f"e=relay&p=1&t={d.token()}", ip=HOST)
check(d.events() == ["Keypad Code Entered", "Door Opened"], "then the gate it opened: Door Opened")
hist = [list(h.values()) for h in d.g.HISTORY.values()]
check(any("Keypad code entered" in str(h) for h in hist) and not any("0047" in str(h) for h in hist),
      f"the code opens the gate: not in Control4 History ({hist})")
d.action("PrintDiagnostics")
d.pump()
text = "\n".join(d.logs())
check(logs_clean(d, "0047")[0] and "keypad code ***" in text and "e=keypad&p=***&t=***" in text,
      "nor in any log line or Print Diagnostics (masked like the password)")
check("47300" in text and "000141" in text, "other numbers in the log are left as they are")
d2, _ = setup(bird=DoorBird(), persist=d.persisted(), start=False)
d2.start(dit="DIT_STARTUP", pump=False)
d2.action("PrintDiagnostics")
d2.pump()
check(logs_clean(d2, "0047")[0], "after a restart too, before the DoorBird is read")



def keypad_bird(other_http=False, **kw):
    """Codes 0047 and 5791, each opening relay 1 (other_http: 0047 also calls another app's favorite #0)."""
    b = DoorBird(**kw)
    week = {"weekdays": [{"from": "108000", "to": "107999"}]}
    for code in ("0047", "5791"):
        outs = [{"event": "relay", "param": "1", "schedule": week}]
        if other_http and code == "0047":
            outs.append({"event": "http", "param": "0", "schedule": week})
        b.schedule.append({"input": "doorbell", "param": code, "output": copy.deepcopy(outs)})
    b.original_schedule = copy.deepcopy(b.schedule)
    return b


def hold_port(d, port):
    """Requests to this port of the controller never end (no answer, no error)."""
    d.run(f"""
    local url = C4.url
    function C4:url()
      local x = url(self)
      local get = x.Get
      function x:Get(u, h)
        if string.find(u, ":{port}/", 1, true) then HELD = (HELD or 0) + 1; return self end
        return get(self, u, h)
      end
      return x
    end""")


# Keypad codes come after the bell, motion, RFID and the relays (a DoorBird with no room left keeps those)
check(d.eval("gReg.summary").index("keypad code") > d.eval("gReg.summary").index("relay 2"), f"keypad codes are registered last ({d.eval('gReg.summary')})")

# Status never shows a code
d, bird = setup(bird=keypad_bird(other_http=True, one_http_per_input=True))
check("keypad code ***: the DoorBird keeps one HTTP call for doorbell ***" in d.prop("Status") and "0047" not in d.prop("Status") and "5791" not in d.prop("Status")
      and logs_clean(d, "0047", "5791")[0], f"a problem with a keypad entry: Status says it without the code ({d.prop('Status')})")

# An earlier copy's favorite for a code that is no longer in the schedule
bird = DoorBird()
bird.http_favorites()["8"] = {"title": "DirectorLink (keypad code 9876)",
                              "value": "http://192.168.50.10:47300/doorbird?e=keypad&p=9876&t=ffffffffffffffffffffffffffffffff"}
d, _ = setup(bird=bird)
check("8" not in bird.http_favorites() and logs_clean(d, "9876")[0], "an earlier copy's keypad favorite: removed, its code not logged")

# A probe that never gets an answer: after a while it counts as doubt, the sync ends, and the other copy keeps its favorite
bird = keypad_bird()
d, _ = setup(bird=bird)
persist = d.persisted()
copy_fav = {"title": "DirectorLink (doorbell 1)", "value": "http://192.168.50.10:47377/doorbird?e=doorbell&p=1&t=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}
bird.http_favorites()["20"] = copy_fav
d, _ = setup(bird=bird, persist=persist, start=False)
hold_port(d, 47377)
d.start(dit="DIT_STARTUP", pump=False)
for _ in range(50):
    d.pump(5000, 1)
    if d.eval("HELD"):
        break
check(d.eval("HELD") == 1 and d.eval("gReg.busy") is True, "while the probe waits, the sync waits")
d.action("PrintDiagnostics")
d.pump(2000)
check(logs_clean(d, "0047", "5791")[0], "Print Diagnostics meanwhile shows no keypad code (known from the saved and the read favorites)")
d.pump(15000)
for _ in range(3):
    d.pump()
check(d.eval("gReg.busy") is False and d.prop("Status") == "Online - events live" and bird.http_favorites().get("20") == copy_fav,
      f"no answer in 10 s: the sync goes on, the other copy's favorite stays ({d.prop('Status')})")

# The camera page: a problem with it is cleared once someone fixes the page by hand
d, bird = setup()
page = ("<properties><address>{a}</address><http_port>80</http_port><rtsp_port>554</rtsp_port><authentication_required>True</authentication_required>"
        "<authentication_type>BASIC</authentication_type><username>{u}</username><use_https>False</use_https></properties>")
d.g.PROXY_PROPS = page.format(a="10.0.0.9", u=USER)
d.action("Reconnect")
for _ in range(3):
    d.pump()
d.advance(4000)
d.pump()
check("Open the DoorBird Camera's Properties page" in d.prop("Status"), f"a camera page that does not take the values: said in Status ({d.prop('Status')})")
d.g.PROXY_PROPS = page.format(a=HOST, u=USER)
d.eval("(function() gState.pageWrittenAt = 0 end)()")  # os.time() is the real clock: as if the write was long ago
d.call("ReceivedFromProxy", 5002, "SET_ADDRESS", d.table({"ADDRESS": HOST}))
d.advance(3000)
d.pump()
check(d.prop("Status") == "Online - events live", f"fixed by hand on the camera page: Status is clear again ({d.prop('Status')})")
d.g.PROXY_PROPS = ""

# ================================================================ offline and back
d, bird = setup()
d.clear()
bird.up = False
tick(d)
check("DoorBird Offline" not in d.events(), "one missed check is not offline yet")
tick(d)
check(d.events() == ["DoorBird Offline"] and d.prop("Status").startswith("Offline - cannot reach the DoorBird at 192.168.50.30"), f"two: offline ({d.prop('Status')})")
check(d.proxy("ICON_CHANGED", 5001)[-1][2] == {"icon": "offline", "icon_description": "DoorBird offline"}, "the tile shows it")
bird.up = True
tick(d)
check(d.events() == ["DoorBird Offline", "DoorBird Online"], "and back online")
check(d.proxy("ICON_CHANGED", 5001)[-1][2]["icon"] == "idle", "the tile too")

# ================================================================ a new address: the old DoorBird is left clean
a = DoorBird(cascade="entry")
bnew = DoorBird(host="192.168.50.31", favorites="favorites_empty.json", schedule="schedule_two_buttons.json", info="info_d1101v_wifi.json")
assert "1CCAE3712B70" in bnew.info and "1CCAE3712A4F" in a.info  # two DoorBirds (two MACs)


def both(method, url, headers, body):
    code, h, body2 = a(method, url, headers, body)
    if code is None:
        return bnew(method, url, headers, body)
    return code, h, body2


d = Driver(both, props=PROPS)
a.clock = bnew.clock = d.now
d.start()
tok = d.token()
check(len(a.own_favorite_ids(tok)) == 5, "registered on the first DoorBird")
d.set_prop("Address", "192.168.50.31")
for _ in range(5):
    d.pump()
check(a.own_favorite_ids(tok) == [] and a.entry("relay", "2") is None, "the old DoorBird: this driver's favorites and the entry it made are gone")
same, why = a.others_unchanged(tok)
check(same, f"and its other entries are whole (outputs removed before the favorites, even where deleting a favorite would drop an entry) {why}")
removals = [i for i, c in enumerate(a.calls) if c["path"] == "/bha-api/favorites.cgi" and c["query"].get("action") == "remove"]
posts = [i for i, c in enumerate(a.calls) if c["path"] == "/bha-api/schedule.cgi" and (c["method"] == "POST" or c["query"].get("action") == "remove")]
check(removals and posts and max(posts) < min(removals), "the schedule first, then the favorites")
check(len(bnew.own_favorite_ids(tok)) == 4 and d.prop("Status") == "Online - events live", f"registered on the new one ({d.prop('Status')})")
check(a.calls[-1]["user"] == USER, "the old one is left with the login that made the calls")

# the old DoorBird is not there: tried again later
a = DoorBird()
bnew = DoorBird(host="192.168.50.31", favorites="favorites_empty.json", schedule="schedule_empty.json", info="info_d1101v_wifi.json")
d = Driver(both, props=PROPS)
a.clock = bnew.clock = d.now
d.start()
tok = d.token()
a.up = False
d.set_prop("Address", "192.168.50.31")
for _ in range(5):
    d.pump()
check("still on the DoorBird at 192.168.50.30" in d.eval("ProblemsText()") and d.prop("Status").startswith("Online - events live"),
      f"the old one does not answer: said so, and the new one works ({d.prop('Status')})")
a.up = True
d.advance(900 * 1000)
d.pump(10000)
for _ in range(5):
    d.pump()
check(a.own_favorite_ids(tok) == [] and "still on the DoorBird" not in d.eval("ProblemsText()"), "when it answers again, it is left clean")

# the same DoorBird at a new address (DHCP): the same MAC, so its HTTP calls are kept and updated
moved = DoorBird()
d = Driver(lambda m, u, h, b: moved(m, u, h, b), props=PROPS)
moved.clock = d.now
d.start()
tok = d.token()
ids = moved.own_favorite_ids(tok)
moved.host = "192.168.50.44"
d.set_prop("Address", "192.168.50.44")
for _ in range(5):
    d.pump()
check(moved.own_favorite_ids(tok) == ids and moved.entry("relay", "2") is not None, "a DoorBird that moved: the same favorites, nothing removed")
check(d.eval("#gCfg.olds") == 0 and d.eval("gReg.created['relay|2']") is True and d.eval("ProblemsText()") == "",
      "it is not an old DoorBird to leave, and the entry it created is still known as its own")
d.g.CONTROLLER_IP = "192.168.50.10"
d.action("RemoveFromDoorBird")
for _ in range(3):
    d.pump()
check(moved.own_favorite_ids(tok) == [] and moved.entry("relay", "2") is None and moved.others_unchanged(tok)[0], "and it can still leave it clean")

# ================================================================ the driver deleted
d, bird = setup()
tok = d.token()
n = len(bird.calls)
d.call("OnDriverRemovedFromProject")
d.call("OnDriverDestroyed")
d.pump()
check(bird.own_favorite_ids(tok) == [] and bird.entry("relay", "2") is None, "deleted from the project: its HTTP calls leave the DoorBird")
same, why = bird.others_unchanged(tok)
check(same, f"everything else stays {why}")
check(min(gaps(bird, bird.calls[n:])) >= 1000, "at the DoorBird's pace (one request per second)")

# ================================================================ the review's cases: nothing destructive on doubt
# A read back that fails: Remove From DoorBird deletes no favorite (deleting one would make the
# DoorBird drop every entry that still uses it)
reads = {"n": 0}


def fail_read_after_post(method, path, query, body):
    if path == "/bha-api/schedule.cgi" and method == "POST":
        reads["armed"] = True
    if path == "/bha-api/schedule.cgi" and method == "GET" and not query and reads.get("armed"):
        reads["n"] += 1
        return None, None, None
    return None


d, bird = setup(cascade="entry")
tok = d.token()
own_before = bird.own_favorite_ids(tok)
bird.hook = lambda m, p, q, b: fail_read_after_post(m, p, q, b) if (m, p) != ("GET", "/bha-api/schedule.cgi") or reads.get("armed") else None
d.action("RemoveFromDoorBird")
for _ in range(4):
    d.pump()
check(reads["n"] >= 1 and bird.own_favorite_ids(tok) == own_before, "a read back that fails: no favorite is deleted")
check(bird.entry("doorbell", "1") is not None and ("notify", "") in bird.outputs_of("doorbell", "1"), "and every entry is still there (even on a DoorBird that drops entries with a deleted favorite)")
check("FAILED" in "\n".join(d.logs()) and d.eval("gCfg.paused") is False, "Remove From DoorBird says it failed, and events are not paused")
bird.hook = None
reads.clear()

# A schedule answered with 204, or an empty body: nothing is created or replaced
for answer in ((204, {}, ""), (200, {}, "")):
    bird = DoorBird(hook=lambda m, p, q, b, a=answer: a if (m, p) == ("GET", "/bha-api/schedule.cgi") and not q else None)
    d, _ = setup(bird=bird)
    check(not bird.posted and not [c for c in bird.calls if c["query"].get("action") in ("remove",)], f"schedule answered {answer[0]} {answer[2]!r}: nothing written")
    check(d.prop("Status").startswith("Online - events not registered"), f"and the Status says so ({d.prop('Status')})")

# Another app changes an entry between this driver's first read and its write: kept
added = {"done": False}


def other_app_writes(method, path, query, body):
    if path == "/bha-api/favorites.cgi" and query.get("action") == "save" and not added["done"]:
        added["done"] = True
        bird.entry("doorbell", "1")["output"].append({"event": "http", "param": "1", "schedule": {"weekdays": [{"from": "0", "to": "604799"}]}})
        bird.original_schedule[0]["output"].append({"event": "http", "param": "1", "schedule": {"weekdays": [{"from": "0", "to": "604799"}]}})
    return None


bird = DoorBird()
bird.hook = other_app_writes
d, _ = setup(bird=bird)
check(added["done"] and ("http", "1") in bird.outputs_of("doorbell", "1") and bird.others_unchanged(d.token())[0],
      "an output another app added after the first read is kept (each entry is read just before it is written)")

# A DoorBird that keeps the first HTTP call (this driver's goes): reported, not retried every 30 minutes
d, bird = setup(one_http_per_input=True, keep="first")
check(bird.others_unchanged(d.token())[0] and "the DoorBird did not keep the HTTP call for doorbell 1" in d.eval("ProblemsText()"),
      f"keep-first: the other app keeps it, and it is said ({d.eval('ProblemsText()')})")
n = len(bird.calls)
d.eval("(function() gState.lastSyncAt = 0 end)()")
tick(d)
check(not [c for c in bird.calls[n:] if c["method"] == "POST"], "and it is not written again at the next check")

# A DoorBird that changes another app's times when a second HTTP call comes: put back
d, bird = setup(trim_others=True)
check(bird.others_unchanged(d.token())[0], "another app's output changed (not dropped) is put back as it was")
check("the DoorBird keeps one HTTP call for doorbell 1, and HTTP call 'Gate log' has it" in d.eval("ProblemsText()"), "and reported")

# An entry whose output is not a list: left alone
bird = DoorBird()
bird.schedule[0]["output"] = {"0": bird.schedule[0]["output"][0]}
bird.original_schedule[0]["output"] = dict(bird.schedule[0]["output"])
d, _ = setup(bird=bird)
check(isinstance(bird.entry("doorbell", "1")["output"], dict) and "has a form this driver does not know" in d.eval("ProblemsText()"),
      "an entry in a form the driver does not know is left alone, and said so")

# The address changes while a request is on its way: nothing of the old DoorBird reaches the new one
a = DoorBird()
bnew = DoorBird(host="192.168.50.31", favorites="favorites_empty.json", schedule="schedule_two_buttons.json", info="info_d1101v_wifi.json")
d = Driver(both, props=PROPS)
a.clock = bnew.clock = d.now
d.async_http()
d.call("OnDriverInit", "DIT_ADDING")
d.call("OnDriverLateInit", "DIT_ADDING")
for _ in range(12):           # well into the first sync: requests on their way to the old DoorBird
    d.pump()
    d.flush_http()
    if any(c["path"] == "/bha-api/favorites.cgi" and c["query"].get("action") == "save" for c in a.calls):
        break
d.pump()                      # the next request waits for its answer
d.g.Properties["Address"] = "192.168.50.31"
d.call("OnPropertyChanged", "Address")
for _ in range(40):
    d.pump()
    d.flush_http()
foreign = [c for c in bnew.calls if (c["path"] == "/bha-api/favorites.cgi" and c["query"].get("id")) or c["method"] == "POST" and '"param":"1","input":"relay"' in (c["body"] or "")]
check(not [c for c in bnew.calls if c["query"].get("id") and c["query"].get("action")], f"no favorite id of the old DoorBird is used on the new one ({foreign})")
check(bnew.others_unchanged(d.token())[0] and a.others_unchanged(d.token())[0], "both DoorBirds keep everything else")
check(d.prop("DoorBird").startswith("DoorBird D1101V"), f"the new DoorBird's info, not the old one's answer ({d.prop('DoorBird')})")
d.async_http(False)
for _ in range(6):
    d.pump()
check(len(bnew.own_favorite_ids(d.token())) == 4 and a.own_favorite_ids(d.token()) == [], "in the end: registered on the new one, gone from the old one")

# A wrong password on a new address costs one request there, even while the old DoorBird is left
a = DoorBird()
bnew = DoorBird(host="192.168.50.31", favorites="favorites_empty.json", schedule="schedule_empty.json", info="info_d1101v_wifi.json")
d = Driver(both, props=PROPS)
a.clock = bnew.clock = d.now
d.start()
d.g.Properties["Password"] = "wrong-for-the-new-one"
d.g.Properties["Address"] = "192.168.50.31"
d.call("OnPropertyChanged", "Address")
for _ in range(8):
    d.pump()
check(len(bnew.calls) == 1 and bnew.wrong_logins == 1, f"the new DoorBird gets one request with the wrong password ({[c['path'] for c in bnew.calls]})")
check(not [c for c in d.device_cmds("SET_PASSWORD") if c[2].get("PASSWORD") == "wrong-for-the-new-one"],
      "the camera page never gets a password the DoorBird refused (Control4 apps would repeat it)")
d.set_prop("Password", PASSWORD)
for _ in range(4):
    d.pump()
check([c for c in d.device_cmds("SET_ADDRESS") if c[2].get("ADDRESS") == "192.168.50.31"], "once the DoorBird takes the login, the camera page follows")

# Reconnect while a check is on its way is not lost
d, bird = setup()
d.async_http()
d.advance(60000)
d.call("RunRepeatingTimers")       # the health check: on its way
d.action("Reconnect")
n = len(bird.calls)
for _ in range(6):
    d.pump()
    d.flush_http()
check(len([c for c in bird.calls if c["path"] == "/bha-api/image.cgi"]) >= 2, "a Reconnect asked for during a check still runs (permissions checked again)")
d.async_http(False)

# Remove From DoorBird: a sync asked for meanwhile does not register again
d, bird = setup()
d.async_http()
d.action("RemoveFromDoorBird")
d.flush_http()
d.eval("(function() gState.lastSyncAt = 0 end)()")
d.call("SyncEvents" if d.eval("SyncEvents") else "RegistrationIdle")
for _ in range(10):
    d.pump()
    d.flush_http()
d.async_http(False)
for _ in range(3):
    d.pump()
check(bird.own_favorite_ids(d.token()) == [] and d.prop("Status").startswith("Online - events off"), f"Remove From DoorBird stays removed ({d.prop('Status')})")

# An old DoorBird that refuses the old login is not tried again
a = DoorBird()
bnew = DoorBird(host="192.168.50.31", favorites="favorites_empty.json", schedule="schedule_empty.json", info="info_d1101v_wifi.json")
d = Driver(both, props=PROPS)
a.clock = bnew.clock = d.now
d.start()
a.password = "changed-in-the-app"
d.set_prop("Address", "192.168.50.31")
for _ in range(5):
    d.pump()
d.advance(900 * 1000)
d.pump(10000)
check(a.wrong_logins == 1 and d.eval("#gCfg.olds") == 0, f"an old DoorBird that refuses the old login: one try, then given up ({a.wrong_logins})")

# ================================================================ a write never left without its check
def run_until_post(d, marker):
    """Async HTTP: run the driver until a POST whose body has `marker` has been answered."""
    for _ in range(400):
        d.pump(5000, 1)
        if d.eval("#HTTP_QUEUE") > 0:
            last = d.g.HTTP_LOG[d.eval("#HTTP_LOG")]
            hit = last.method == "POST" and marker in (last.body or "")
            d.flush_http()
            if hit:
                return True
    return False


def settle(d, rounds=60):
    for _ in range(rounds):
        d.pump()
        d.flush_http()
    d.async_http(False)
    for _ in range(5):
        d.pump()


# The DoorBird takes a new password (in the DoorBird app and in Composer) just after this driver wrote an
# entry on a DoorBird that keeps one HTTP call: the read back is refused, so the check happens later
bird = DoorBird(one_http_per_input=True, keep="last")
d = Driver(bird, props=PROPS)
bird.clock = d.now
d.async_http()
d.call("OnDriverInit", "DIT_ADDING")
d.call("OnDriverLateInit", "DIT_ADDING")
check(run_until_post(d, '"input":"doorbell"'), "the doorbell 1 write went out")
check(("http", "0") not in bird.outputs_of("doorbell", "1"), "(that DoorBird dropped the other app's call)")
d.g.Properties["Password"] = "New-Pass-1"
d.call("OnPropertyChanged", "Password")
bird.password = "New-Pass-1"
settle(d)
check(bird.outputs_of("doorbell", "1") == [("notify", ""), ("http", "0"), ("sip", "0")] and bird.others_unchanged(d.token())[0],
      "the other app's call is put back where it was, once the DoorBird answers again")
check("the DoorBird keeps one HTTP call for doorbell 1, and HTTP call 'Gate log' has it" in d.eval("ProblemsText()"), "and it is said")

# Director restarts between a write and its read back: the check follows after the restart
bird = DoorBird(one_http_per_input=True, keep="last")
d = Driver(bird, props=PROPS)
bird.clock = d.now
d.async_http()
d.call("OnDriverInit", "DIT_ADDING")
d.call("OnDriverLateInit", "DIT_ADDING")
run_until_post(d, '"input":"doorbell"')
bird.up = False
settle(d, 20)
check(d.eval("next(gReg.unchecked) ~= nil") is True, "a write without its read back is remembered (saved)")
bird.up = True
d2 = Driver(bird, props=PROPS, persist=d.persisted())
bird.clock = d2.now
d2.start(dit="DIT_STARTUP")
for _ in range(4):
    d2.pump()
check(bird.others_unchanged(d2.token())[0] and d2.eval("next(gReg.unchecked) == nil") is True, "after the restart it is checked and the other app's call put back")

# The Address becomes the same DoorBird's name: nothing is removed (the same MAC)
bird = DoorBird()


def by_name(m, u, h, b):
    from urllib.parse import urlsplit, urlunsplit
    p = urlsplit(u)
    if p.hostname == "frontdoor.local":
        u = urlunsplit((p.scheme, HOST, p.path, p.query, p.fragment))
    return bird(m, u, h, b)


d = Driver(by_name, props=PROPS)
bird.clock = d.now
d.start()
ids = bird.own_favorite_ids(d.token())
d.g.RESOLVE["frontdoor.local"] = HOST
n = len(bird.calls)
d.set_prop("Address", "frontdoor.local")
for _ in range(6):
    d.pump()
check(not [c for c in bird.calls[n:] if c["query"].get("action") == "remove"] and bird.own_favorite_ids(d.token()) == ids,
      "the same DoorBird under another address: nothing removed, the same favorites")

# A check on its way when the Address changes: no false Offline / Online, no stale answer applied
a = DoorBird()
bnew = DoorBird(host="192.168.50.31", favorites="favorites_empty.json", schedule="schedule_empty.json", info="info_d1101v_wifi.json")
d = Driver(both, props=PROPS)
a.clock = bnew.clock = d.now
d.start()
d.clear()
d.async_http()
d.advance(60000)
d.call("RunRepeatingTimers")
d.g.Properties["Address"] = "192.168.50.31"
d.call("OnPropertyChanged", "Address")
settle(d)
check(d.events() == [] and d.prop("Status") == "Online - events live" and d.prop("DoorBird").startswith("DoorBird D1101V"),
      f"a check on its way when the Address changes: no Offline/Online events, the new DoorBird's info ({d.events()}, {d.prop('Status')})")
check(a.own_favorite_ids(d.token()) == [] and len(bnew.own_favorite_ids(d.token())) == 3, "and the old DoorBird is left clean")

# A new Address while the old DoorBird's relay entry is being created: that entry goes whole
a = DoorBird()
bnew = DoorBird(host="192.168.50.31", favorites="favorites_empty.json", schedule="schedule_empty.json", info="info_d1101v_wifi.json")
d = Driver(both, props=PROPS)
a.clock = bnew.clock = d.now
d.async_http()
d.call("OnDriverInit", "DIT_ADDING")
d.call("OnDriverLateInit", "DIT_ADDING")
for _ in range(400):
    d.pump(5000, 1)
    if d.eval("#HTTP_QUEUE") > 0:
        last = d.g.HTTP_LOG[d.eval("#HTTP_LOG")]
        if last.method == "POST" and '"param":"2"' in (last.body or "") and '"input":"relay"' in (last.body or ""):
            break
        d.flush_http()
d.g.Properties["Address"] = "192.168.50.31"
d.call("OnPropertyChanged", "Address")
settle(d)
check(a.entry("relay", "2") is None and a.own_favorite_ids(d.token()) == [] and a.others_unchanged(d.token())[0],
      "an entry created as the Address changed is removed whole from the old DoorBird")

finish()

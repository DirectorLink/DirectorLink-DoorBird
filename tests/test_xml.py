"""driver.xml checks (offline).   python tests/test_xml.py

Catches definitions Composer rejects at install time - for example a property of
type PASSWORD, which Composer reports as "Property Invalid ... Object reference not
set to an instance of an object". Password fields are STRING + <password>true</password>.
Also the DirectorLink camera agreement (events "Alert" = 1 and "Ring" = 2), the
brand rules (Composer name, maker metadata, no brand on what the family sees), the
two devices (the DoorBird tile and the DoorBird Camera) and the tile's icons.
"""
import os
import re
import xml.etree.ElementTree as ET

from harness import ROOT, check, finish

PROPERTY_TYPES = {"STRING", "LIST", "RANGED_INTEGER", "RANGED_FLOAT", "LABEL", "DYNAMIC_LIST",
                  "DEVICE_SELECTOR", "COLOR_SELECTOR", "LINK", "SCROLL", "TRACK"}
PARAM_TYPES = {"STRING", "LIST", "RANGED_INTEGER", "RANGED_FLOAT", "DEVICE_SELECTOR", "COLOR_SELECTOR", "CUSTOM_SELECT", "DYNAMIC_LIST"}
CONDITIONAL_TYPES = {"SIMPLE", "BOOL", "NUMBER", "STRING", "LIST", "ROOM", "DEVICE"}

path = os.path.join(ROOT, "src", "driver.xml")
root = ET.parse(path).getroot()
props = root.findall("config/properties/property")
names = [p.findtext("name") for p in props]
bad = [(p.findtext("name"), p.findtext("type")) for p in props if (p.findtext("type") or "").strip() not in PROPERTY_TYPES]
check(not bad, f"every property type is one Composer supports {bad or ''}")
check(len(names) == len(set(names)), "property names are unique")
lists = [p.findtext("name") for p in props if p.findtext("type") == "LIST" and p.findtext("default") not in [i.text for i in p.findall("items/item")]]
check(not lists, f"every LIST default is one of its items {lists or ''}")
ranged = [p.findtext("name") for p in props if p.findtext("type") == "RANGED_INTEGER"
          and not (int(p.findtext("minimum")) <= int(p.findtext("default")) <= int(p.findtext("maximum")))]
check(not ranged, f"every RANGED_INTEGER default is in range {ranged or ''}")
params = [(c.findtext("name"), q.findtext("type")) for c in root.findall("config/commands/command") for q in c.findall("params/param")
          if q.findtext("type") not in PARAM_TYPES]
check(not params, f"every command parameter type is valid {params or ''}")
conds = [(c.findtext("name"), c.findtext("type")) for c in root.findall("conditionals/conditional") if c.findtext("type") not in CONDITIONAL_TYPES]
check(not conds, f"every conditional type is valid {conds or ''}")
events = root.findall("events/event")
ids = [e.findtext("id") for e in events]
check(len(ids) == len(set(ids)) and all(int(i) < 100 for i in ids), "event ids are unique and below 100 (101+ and 201+ are added at run time)")
check(all((e.findtext("description") or "").strip() for e in events), "every event has a description (Composer's Programming tab needs one)")
check(root.find("states") is None, "no empty <states/>")
for tag in ("properties", "actions", "script", "documentation"):
    check(root.find("config/" + tag) is not None and root.find(tag) is None, f"<{tag}> is inside <config>")
pw = [p for p in props if p.findtext("name") == "Password"]
check(len(pw) == 1 and pw[0].findtext("password") == "true" and pw[0].findtext("type") == "STRING", "the Password is a masked STRING")
version = root.findtext("version")
check(version is not None and version.isdigit(), f"<version> is an integer ({version})")

# DirectorLink brand: Composer name and maker metadata; no brand on anything the family sees
check(root.findtext("name") == "DirectorLink · DoorBird", f"Composer name is 'DirectorLink · DoorBird' ({root.findtext('name')})")
check(root.findtext("creator") == "DirectorLink" and root.findtext("manufacturer") == "DoorBird"
      and root.findtext("copyright") == "Copyright 2026 DirectorLink", "creator, manufacturer and copyright")
doc = root.find("config/documentation").get("file")
check(doc == "www/documentation.html" and os.path.exists(os.path.join(ROOT, "src", doc)), f"documentation tab file exists ({doc})")
for img in [root.findtext("small"), root.findtext("large")]:
    check(os.path.exists(os.path.join(ROOT, "src", "www", img)), f"icon {img} exists (paths are relative to www/)")
family = ([p.get("name") for p in root.findall("proxies/proxy")] + [e.findtext("name") for e in events]
          + [c.findtext("connectionname") for c in root.findall("connections/connection")]
          + [c.findtext("name") for c in root.findall("conditionals/conditional")])
check(not [n for n in family if "directorlink" in (n or "").lower()], "no brand in proxy, event, connection or conditional names")

# The DirectorLink camera agreement v1: events named exactly "Alert" and "Ring" (ids 1 and 2, never to change)
ev = {e.findtext("name"): e.findtext("id") for e in events}
check(ev.get("Alert") == "1" and ev.get("Ring") == "2", f"events 'Alert' (1) and 'Ring' (2) ({ev.get('Alert')}, {ev.get('Ring')})")
for name in ("Motion Detected", "Keypad Code Entered", "RFID Read", "Door Opened", "DoorBird Online", "DoorBird Offline"):
    check(name in ev, f"programming event '{name}'")
cmds = {c.findtext("name"): c for c in root.findall("config/commands/command")}
check(set(cmds) == {"OPEN_DOOR", "LIGHT_ON", "SET_ALERT_ON_MOTION"}, f"commands: Open Door, IR light, alert on motion ({sorted(cmds)})")
check(cmds["OPEN_DOOR"].find("params/param/type").text == "DYNAMIC_LIST", "Open Door lists the DoorBird's relays (DYNAMIC_LIST)")
actions = [a.findtext("command") for a in root.findall("config/actions/action")]
check(["PrintDiagnostics", "TestPictures", "Reconnect", "OpenGate", "LightOn", "RemoveFromDoorBird"] == actions, f"actions ({actions})")
check(names == ["Status", "DoorBird", "Address", "Username", "Password", "Gate Relay", "Alert On Motion", "Log Level"],
      f"only the properties an installer needs ({names})")

caps = root.find("capabilities")
check(caps.findtext("modes") == "SNAPSHOT, MJPEG, H264", "camera: snapshots, MJPEG and H.264")
check(caps.findtext("default_authentication_type") == "BASIC" and caps.findtext("default_rtsp_port") == "554"
      and caps.findtext("default_http_port") == "80", "camera: Basic login, HTTP 80, RTSP 554")
check(caps.find("requires_dynamic_stream_urls") is None, "camera: static stream paths (work from Control4 OS 3.3.0)")
check(root.findtext("notification_attachment_provider") == "true" and root.find("notification_attachments/attachment/source").text == "MEMORY",
      "a notification picture (MEMORY)")
# Two devices in Composer: the DoorBird (a tile, primary) and the DoorBird Camera
proxies = [(x.get("proxybindingid"), x.text, x.get("name"), x.get("primary")) for x in root.findall("proxies/proxy")]
check(proxies == [("5001", "uibutton", "DoorBird", "True"), ("5002", "camera", "DoorBird Camera", None)],
      f"the DoorBird tile (5001, primary) and the DoorBird Camera (5002) ({proxies})")
for x in root.findall("proxies/proxy"):
    for a in ("small_image", "large_image"):
        check(os.path.exists(os.path.join(ROOT, "src", "www", x.get(a))), f"{x.get('name')}: {a} {x.get(a)} exists")
conns = {c.findtext("id"): c.findtext("classes/class/classname") for c in root.findall("connections/connection")}
check(conns == {"5001": "UIBUTTON", "5002": "CAMERA"}, f"a connection for each proxy ({conns})")

# The tile: an icon set for each state the driver sends, at every size, inside the .c4z
nav = root.find("capabilities/navigator_display_option")
check(nav is not None and nav.get("proxybindingid") == "5001", "the tile's icons are for proxy 5001")
states = {st.get("id"): [i.text for i in st.findall("Icon")] for st in nav.findall("display_icons/state")}
sent = set(re.findall(r'(\w+) = "[^"]*"', re.search(r"TILE_TEXT = \{([^}]*)\}", open(os.path.join(ROOT, "src", "driver.lua"), encoding="utf-8").read()).group(1)))
check(set(states) == sent == {"idle", "ring", "motion", "open", "offline"}, f"a state for each tile state the driver sends ({sorted(states)}, {sorted(sent)})")
prefix = "controller://driver/DirectorLink-DoorBird/icons/"
icons = [i.text for i in nav.findall("display_icons/Icon")] + [i for v in states.values() for i in v]
check(all(i.startswith(prefix) for i in icons), "icon URLs point into this driver's .c4z (named DirectorLink-DoorBird)")
missing = [i for i in icons if not os.path.exists(os.path.join(ROOT, "src", "www", "icons", i[len(prefix):]))]
check(not missing and all(len(v) == 5 for v in states.values()), f"every tile icon exists, 5 sizes each {missing[:3] or ''}")

# Property names the Lua reads all exist
lua = open(os.path.join(ROOT, "src", "driver.lua"), encoding="utf-8").read()
used = set(re.findall(r'Properties\["([^"]+)"\]', lua))
missing = sorted(used - set(names))
check(not missing, f"every property the driver reads is in driver.xml {missing or ''}")
fired = set(re.findall(r'FireEvent\("([^"]+)"\)', lua)) | set(re.findall(r'FireWithPicture\("([^"]+)"', lua))
check(fired <= set(ev), f"every event the driver fires by name is in driver.xml {sorted(fired - set(ev)) or ''}")
check(set(re.findall(r'name == "([A-Z_]+)" then return TestBool', lua)) | set(re.findall(r'elseif name == "([A-Z_]+)" then return TestBool', lua))
      <= {c.findtext("name") for c in root.findall("conditionals/conditional")}, "every conditional the driver answers is in driver.xml")

finish()

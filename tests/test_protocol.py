"""The driver's building blocks against the recorded API answers.   python tests/test_protocol.py

JSON (an empty object stays {}, null stays null, numbers stay numbers), info.cgi,
favorites.cgi and schedule.cgi parsing, the events to register, which favorites are
the driver's, the callback URLs, and the log filter.
"""
import json

from harness import Driver, check, finish, fixture

d = Driver()
L = d.eval

# ---------------------------------------------------------------- JSON
d.run('''
RT = function(s) local v = JsonDecode(s); return JsonEncode(v) end
''')
check(L('RT(\'{"a":{},"b":[],"c":null,"d":1,"e":"1","f":[{"g":{}}]}\')') == '{"a":{},"b":[],"c":null,"d":1,"e":"1","f":[{"g":{}}]}',
      "JSON: {} stays {}, [] stays [], null stays null, 1 stays a number, \"1\" a string")
check(L('RT(\'{"x":"caf\\\\u00e9 \\\\"q\\\\" \\\\\\\\ /"}\')') is not None, "JSON: escapes decode and encode")
check(L('(JsonDecode("{bad"))') is None, "JSON: bad input gives nil, no error")
check(L('(JsonDecode("[1,2] x"))') is None, "JSON: text after the value is refused")

for name in ("schedule_d2101v.json", "schedule_two_buttons.json", "favorites_d2101v.json", "info_d2101v.json"):
    text = fixture(name)
    d.g.TMP = text
    back = L("JsonEncode(JsonDecode(TMP))")
    check(json.loads(back) == json.loads(text), f"JSON: {name} reads and writes back the same")

# ---------------------------------------------------------------- info.cgi
d.g.TMP = fixture("info_d2101v.json")
info = L("ParseInfo(TMP)")
check(info.model == "DoorBird D2101V" and info.firmware == "000141" and info.build == "16418935" and info.mac == "1CCAE3712A4F",
      "info.cgi: model, firmware, build, MAC")
check(list(info.relays.values()) == ["1", "2", "ghchdi@1", "ghchdi@2"], "info.cgi: relays, with the door controller's")
check(L('IsPeripheralRelay("ghchdi@1")') is True and L('IsPeripheralRelay("1")') is False, "a door controller's relay is told apart")
d.g.TMP = fixture("info_d1101v_wifi.json")
check(L("ParseInfo(TMP)").mac == "1CCAE3712B70", "info.cgi: a WiFi DoorBird's MAC")
d.g.TMP = fixture("info_d101_000096.json")
old = L("ParseInfo(TMP)")
check(old.firmware == "000096" and len(list(old.relays.values())) == 0 and old.model == "", "info.cgi: firmware 000096 lists no relays and no model")
check(L('FirmwareNumber("000141")') == 141 and L('FirmwareNumber("")') == 0, "firmware number")
d.g.TMP = '{"BHA":{"RETURNCODE":"0"}}'
check(L("(ParseInfo(TMP))") is None, "info.cgi: RETURNCODE 0 is not a DoorBird answer")
d.g.TMP = "<html>login</html>"
check(L("(ParseInfo(TMP))") is None, "info.cgi: an HTML page is not a DoorBird")

# ---------------------------------------------------------------- favorites.cgi, schedule.cgi
d.g.TMP = fixture("favorites_d2101v.json")
d.run("FAVS, _, SIPS = ParseFavorites(TMP)")
check(sorted(d.g.FAVS.keys()) == ["0", "1", "5"] and d.g.SIPS == 1, "favorites.cgi: three HTTP favorites, one SIP")
d.g.TMP = fixture("schedule_d2101v.json")
d.run("ENTRIES = ParseSchedule(TMP)")
check(len(list(d.g.ENTRIES.values())) == 6, "schedule.cgi: six entries")
check(L("(ParseSchedule(''))") is None, "schedule.cgi: an empty answer is 'not read', never 'no entries'")
check(len(list(L("ParseSchedule('[]')").values())) == 0, "schedule.cgi: [] is no entries")
check(L("(ParseSchedule('null'))") is None and L("(ParseSchedule('{}'))") is None, "schedule.cgi: null or {} is 'not read'")
d.run('U = ParseSchedule(\'[{"input":"doorbell","param":"1","output":{"0":{"event":"http"}}},{"input":"motion","param":"","output":[]}]\')')
check(L("IsUnknownEntry(U[1])") is True and L("IsUnknownEntry(U[2])") is False, "an entry whose output is not a list is marked unknown (never written)")
check(L("(ParseFavorites(''))") is not None, "favorites.cgi: an empty answer is no favorites")
check(L('(ParseFavorites(\'{"http":[{"title":"x","value":"y"}]}\'))') is None, "favorites.cgi: HTTP favorites in a list are refused (no index taken for an id)")
check(L('(ParseSchedule(\'{"a":1}\'))') is None, "schedule.cgi: an object is not a schedule")

# ---------------------------------------------------------------- the events to register
def keys(sched, relays):
    d.g.TMP = fixture(sched)
    d.g.RELAYS = d.table(dict(enumerate(relays, 1)))
    return list(L("DesiredKeys(ParseSchedule(TMP), RELAYS)").values())


check(keys("schedule_d2101v.json", ["1", "2", "ghchdi@1"]) == ["doorbell:1", "motion", "rfid", "relay:1", "relay:2"],
      "D2101V: doorbell 1, motion, RFID (it has tags), its own relays 1 and 2 (not the door controller's)")
check(keys("schedule_two_buttons.json", ["1"]) == ["doorbell:1", "doorbell:2", "motion", "relay:1"], "two buttons: one event each")
check(keys("schedule_empty.json", []) == ["doorbell:1", "motion", "relay:1"], "an empty schedule: button 1, motion, relay 1")
check(L('KeyLabel("doorbell:2")') == "doorbell 2" and L('KeyLabel("rfid")') == "RFID" and L('KeyTitle("relay:1")') == "DirectorLink (relay 1)",
      "event labels and favorite titles")

# ---------------------------------------------------------------- URLs and ownership
TOKEN = "0123456789abcdef0123456789abcdef"
d.run(f'CTX = {{ ctrl = "192.168.50.10", port = 47300, token = "{TOKEN}" }}')
url = L('KeyUrl(CTX, "doorbell:2")')
check(url == f"http://192.168.50.10:47300/doorbird?e=doorbell&p=2&t={TOKEN}", f"callback URL ({url})")
check(L('KeyUrl(CTX, "motion")') == f"http://192.168.50.10:47300/doorbird?e=motion&t={TOKEN}", "motion has no param")
check(L(f'OwnFavoriteKey("{url}", "{TOKEN}")') == "doorbell:2", "the driver knows its favorite by the token")
check(L(f'OwnFavoriteKey("{url}", "ffffffffffffffffffffffffffffffff")') is None, "a favorite with another token is not its")
check(L(f'OwnFavoriteKey("http://192.168.50.5:8123/api/doorbird/x?token={TOKEN}", "{TOKEN}")') is None, "nor one at another path")
check(L('KeyMatchesEntry("rfid", "rfid", "0012345678")') is True and L('KeyMatchesEntry("doorbell:1", "doorbell", "2")') is False
      and L('KeyMatchesEntry("relay:1", "relay", "1")') is True, "which schedule entries an event belongs in")

# ---------------------------------------------------------------- utilities
check(L('QueryValue("e=doorbell&p=1&t=abc", "t")') == "abc" and L('QueryValue("a=b%20c", "a")') == "b c", "query values, decoded")
check(L('QueryString({{"value", "http://x/?a=1&t=2"}})') == "value=http%3A%2F%2Fx%2F%3Fa%3D1%26t%3D2", "query strings encode URLs")
check(L('IsIPv4("192.168.1.20")') is True and L('IsIPv4("doorbird.local")') is False and L('IsIPv4("300.1.1.1")') is False, "IPv4 addresses")
check(L('IsoUtc(1759687200)') == "2025-10-05T18:00:00Z", "ISO 8601 UTC")
d.run('RegisterSecret("Door-Bird-Pa55"); RegisterSecret("' + TOKEN + '")')
check(L('Redact("pw Door-Bird-Pa55 and ' + TOKEN + ' end")') == "pw *** and *** end", "the log filter hides the password and the token")
check(L('Redact("value=http%3A%2F%2Fx%2F%3Ft%3D' + TOKEN + '")').endswith("***"), "also inside an encoded URL")
check(L('Redact(UrlEncode("a:Door-Bird-Pa55"))') == "a%3A***", "and an encoded password")

finish()

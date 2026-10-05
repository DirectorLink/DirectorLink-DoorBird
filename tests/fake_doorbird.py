"""A DoorBird for the tests: answers the LAN API (bha-api) from the recorded answers in
tests/fixtures and keeps its favorites and schedule as a real one does, so what the
driver writes can be read back and checked.

Switches for the behaviours the driver must survive:
  operator / watch / history / motion   the user's permissions (401 / 204 when missing)
  one_http_per_input   a schedule entry keeps one "http" output (the LAN API: "only one schedule
                       entry for each output type, time slot"): keep="last" (the one posted last
                       wins, another app's goes) or keep="first" (the driver's goes)
  trim_others          a second "http" output makes the DoorBird shorten the first one's times
                       (another app's output changed, not dropped)
  hook                 hook(method, path, query, body) -> (code, headers, body) or None: answer a
                       request differently, or change the DoorBird's state on the way
  relay_input          False: POST of an entry with input "relay" is refused (400)
  cascade              "outputs": deleting a favorite removes the outputs that use it;
                       "entry": it removes every schedule entry that uses it, whole
  favoriteid_header    False: a new favorite's id is not in the answer's headers
  up                   False: no answer at all
Every request is recorded with the controller clock (NOW_MS), the user, the path and
the query, so pacing and "one at a time" can be checked.
"""
import base64
import copy
import json
from urllib.parse import parse_qsl, urlsplit

from harness import fixture

HOST = "192.168.50.30"
USER = "ghchdi0002"
PASSWORD = "Door-Bird-Pa55"


def jpeg(w=1280, h=720, pad=600, tag=b""):
    return (b"\xff\xd8" + b"\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
            + b"\xff\xc0\x00\x11\x08" + h.to_bytes(2, "big") + w.to_bytes(2, "big") + b"\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01"
            + tag + b"\x00" * pad + b"\xff\xd9")


class DoorBird:
    def __init__(self, host=HOST, user=USER, password=PASSWORD, info="info_d2101v.json", favorites="favorites_d2101v.json",
                 schedule="schedule_d2101v.json", operator=True, watch=True, history=True, motion=True,
                 one_http_per_input=False, relay_input=True, cascade="outputs", favoriteid_header=True, lock_after=3,
                 keep="last", trim_others=False, hook=None):
        self.host, self.user, self.password = host, user, password
        self.info = fixture(info)
        self.favorites = json.loads(fixture(favorites))
        self.schedule = json.loads(fixture(schedule))
        self.original_favorites = copy.deepcopy(self.favorites)
        self.original_schedule = copy.deepcopy(self.schedule)
        self.operator, self.watch, self.history, self.motion = operator, watch, history, motion
        self.one_http_per_input, self.relay_input = one_http_per_input, relay_input
        self.keep, self.trim_others, self.hook = keep, trim_others, hook
        self.cascade, self.favoriteid_header, self.lock_after = cascade, favoriteid_header, lock_after
        self.up = True
        self.calls = []            # dicts: method, path, query, body, at, user
        self.wrong_logins = 0
        self.locked = False
        self.opened = []           # relays pulsed
        self.lights = 0
        self.posted = []           # schedule entries posted (decoded)
        self.raw_posts = []        # and as sent
        self.clock = lambda: 0     # set by the test: the driver's NOW_MS

    # ---- helpers for the tests
    def http_favorites(self):
        return self.favorites.setdefault("http", {})

    def entry(self, input_, param=""):
        for e in self.schedule:
            if e["input"] == input_ and e["param"] == param:
                return e
        return None

    def own_favorite_ids(self, token):
        return sorted((i for i, f in self.http_favorites().items() if ("t=" + token) in f["value"]), key=int)

    def outputs_of(self, input_, param=""):
        e = self.entry(input_, param)
        return [(o["event"], o["param"]) for o in e["output"]] if e else None

    def others_unchanged(self, token):
        """Every favorite and every schedule output that is not the driver's is exactly as it was."""
        own = set(self.own_favorite_ids(token))
        favs = {i: f for i, f in self.http_favorites().items() if i not in own}
        if favs != self.original_favorites.get("http", {}) or self.favorites.get("sip") != self.original_favorites.get("sip"):
            return False, "favorites differ"
        for orig in self.original_schedule:
            now = self.entry(orig["input"], orig["param"])
            if now is None:
                return False, f"entry {orig['input']} {orig['param']} is gone"
            kept = [o for o in now["output"] if not (o["event"] == "http" and o["param"] in own)]
            if kept != orig["output"]:
                return False, f"entry {orig['input']} {orig['param']}: {kept} != {orig['output']}"
        return True, ""

    def requests(self, path=None):
        return [c for c in self.calls if path is None or c["path"] == path]

    # ---- the API
    def __call__(self, method, url, headers, body):
        parts = urlsplit(url)
        if parts.hostname != self.host:
            return None, None, None
        if not self.up:
            return None, None, None
        query = dict(parse_qsl(parts.query, keep_blank_values=True))
        auth = headers.get("Authorization", "")
        user = None
        if auth.startswith("Basic "):
            user, _, pw = base64.b64decode(auth[6:]).decode("latin-1").partition(":")
        self.calls.append({"method": method, "path": parts.path, "query": query, "body": body, "at": self.clock(), "user": user,
                           "headers": headers})
        if self.hook:
            answer = self.hook(method, parts.path, query, body)
            if answer is not None:
                return answer
        if self.locked:
            return 423, {}, ""
        if user != self.user or pw != self.password:
            self.wrong_logins += 1
            if self.wrong_logins >= self.lock_after:
                self.locked = True
            return 401, {"WWW-Authenticate": 'Basic realm="DoorBird"'}, ""
        path = parts.path
        ok_json = json.dumps({"BHA": {"RETURNCODE": "1"}})
        if path == "/bha-api/info.cgi":
            return 200, {"Content-Type": "application/json"}, self.info
        if path == "/bha-api/image.cgi":
            return (200, {"Content-Type": "image/jpeg"}, jpeg(tag=b"LIVE")) if self.watch else (204, {}, "")
        if path == "/bha-api/history.cgi":
            allowed = self.motion if query.get("event") == "motionsensor" else self.history
            return (200, {"Content-Type": "image/jpeg"}, jpeg(640, 480, tag=b"HIST")) if allowed else (204, {}, "")
        if path == "/bha-api/open-door.cgi":
            if not self.watch:
                return 204, {}, ""
            self.opened.append(query.get("r", "1"))
            return 200, {"Content-Type": "application/json"}, ok_json
        if path == "/bha-api/light-on.cgi":
            if not self.watch:
                return 204, {}, ""
            self.lights += 1
            return 200, {"Content-Type": "application/json"}, ok_json
        if path == "/bha-api/favorites.cgi":
            if not self.operator:
                return 401, {}, ""
            return self._favorites(query)
        if path == "/bha-api/schedule.cgi":
            if not self.operator:
                return 401, {}, ""
            return self._schedule(method, query, headers, body)
        return 404, {}, ""

    def _favorites(self, q):
        action = q.get("action")
        if not action:
            return 200, {"Content-Type": "application/json"}, json.dumps(self.favorites)
        kind = q.get("type")
        if kind not in ("http", "sip"):
            return 400, {}, ""
        favs = self.favorites.setdefault(kind, {})
        if action == "save":
            if not q.get("title") or not q.get("value"):
                return 400, {}, ""
            fid = q.get("id")
            if fid:
                if fid not in favs:
                    return 500, {}, ""
            else:
                used = {int(i) for f in self.favorites.values() for i in f}
                fid = str(min(i for i in range(0, 100) if i not in used))
            favs[fid] = {"title": q["title"], "value": q["value"]}
            return 200, ({"favoriteid": fid} if self.favoriteid_header and not q.get("id") else {}), ""
        if action == "remove":
            fid = q.get("id")
            if fid not in favs:
                return 200, {}, ""
            del favs[fid]
            if kind == "http":
                if self.cascade == "entry":
                    self.schedule = [e for e in self.schedule if not any(o["event"] == "http" and o["param"] == fid for o in e["output"])]
                else:
                    for e in self.schedule:
                        e["output"] = [o for o in e["output"] if not (o["event"] == "http" and o["param"] == fid)]
            return 200, {}, ""
        return 400, {}, ""

    def _schedule(self, method, q, headers, body):
        if method == "GET" and q.get("action") == "remove":
            self.schedule = [e for e in self.schedule if not (e["input"] == q.get("input") and e["param"] == q.get("param", ""))]
            return 200, {}, ""
        if method == "GET":
            return 200, {"Content-Type": "application/json"}, json.dumps(self.schedule)
        if method != "POST":
            return 400, {}, ""
        if headers.get("Content-Type") != "application/json":
            return 400, {}, ""
        self.raw_posts.append(body)
        try:
            entry = json.loads(body)
        except ValueError:
            return 400, {}, ""
        if not isinstance(entry, dict) or not isinstance(entry.get("output"), list) or "input" not in entry or "param" not in entry:
            return 400, {}, ""
        for o in entry["output"]:
            if not isinstance(o.get("schedule"), dict):
                return 400, {}, ""
        if entry["input"] == "relay" and not self.relay_input:
            return 400, {}, ""
        self.posted.append(copy.deepcopy(entry))
        if self.one_http_per_input:
            https = [o for o in entry["output"] if o["event"] == "http"]
            if len(https) > 1:
                keep = https[-1] if self.keep == "last" else https[0]
                entry["output"] = [o for o in entry["output"] if o["event"] != "http" or o is keep]
        if self.trim_others:
            https = [o for o in entry["output"] if o["event"] == "http"]
            if len(https) > 1:
                https[0]["schedule"] = {"weekdays": [{"from": "108000", "to": "151199"}]}
        for i, e in enumerate(self.schedule):
            if e["input"] == entry["input"] and e["param"] == entry["param"]:
                self.schedule[i] = entry
                break
        else:
            self.schedule.append(entry)
        return 200, {}, ""

# Changelog

All notable changes to DirectorLink · DoorBird for Control4. Versions follow the `VERSION` file; the driver version Composer compares is in brackets.

## 1.0.0 (1000099) - 2026-10-06

First full release. The driver is the same as 1.0.0-beta.3, tested on a DoorBird D2101KV (firmware 000152): the login, pictures, registering the events next to other apps' HTTP calls, rings, motion, the gate opening (*Door Opened*), the tile, and opening the gate with a tap on the tile, confirmed in the controller's log.

- From beta.2 or beta.3: updates in place (settings, bindings and programming stay).
- From beta.1: run Remove From DoorBird on beta.1 and delete it, then add this version (since beta.2 the driver adds different devices).

## 1.0.0-beta.3 (1000003) - 2026-10-06

- The tile shows the gate opening after a ring. On the real DoorBird a visitor rang and the gate opened 10 seconds later: *Door Opened* fired, but the tile kept showing the ring, which outranked the gate. A ring and the gate opening now replace each other (the newer shows); motion still hides neither.
- Confirmed on the DoorBird D2101KV: rings, motion and the gate opening reach Control4 as *Ring*, *Motion Detected* and *Door Opened*, the tile shows them (with this fix, the gate after a ring), and a tap on the tile opens the gate (a second tap within 2 seconds sends no second pulse).

## 1.0.0-beta.2 (1000002) - 2026-10-06

Redesigned after the first run on a real DoorBird D2101KV (firmware 000152), where the login, pictures, registering the events, rings and motion were confirmed. **Not an update for beta.1**: run Remove From DoorBird on beta.1, delete it, then add beta.2 (a beta.1 deleted without it leaves HTTP calls that beta.2 removes).

- **Two devices instead of one camera:** **DoorBird**, a tile for the Control4 apps (the primary device), and **DoorBird Camera**. The tile's icon shows a ring, motion, the gate opening or the DoorBird offline; a tap opens the gate.
- **Eight properties instead of nineteen:** Status, DoorBird, Address, Username, Password, Gate Relay, Alert On Motion, Log Level. *Gate Relay* (Relay 1, Relay 2 or Nothing) is what a tap on the tile and the new **Open Gate** action open. **Status** now also says the first thing to fix (*Attention* is gone); MAC, permissions, buttons, the event server, this driver's HTTP calls and the last events are in **Print Diagnostics**. Pictures for notifications and Control4 History entries are always on, a motion alert is held for a minute, and RTSP over HTTP is set as RTSP Port 8557 on the camera page (the driver keeps 554 or 8557 there).
- **Keypad codes:** on a DoorBird with a keypad, each code in the schedule (a `doorbell` entry whose parameter is the code) gets its own HTTP call, next to the code's own relay. **Keypad Code Entered** fires and `LAST_KEYPAD_CODE` holds the code for programming. The code opens a door, so it is masked like the password: never in a log, Status, Print Diagnostics or the Control4 History; RFID tag numbers too. Codes are registered after the other events, so a DoorBird with no room for more favorites keeps the bell, motion, RFID and the relays. (Beta.1 took a code for a doorbell button.)
- **Fewer, clearer events:** *Ring (Button n)* only on a DoorBird with several buttons (*Doorbell Pressed (Button n)* is gone); one *Door Opened* (`LAST_RELAY` says which relay) instead of one per relay. Event ids are new: programming made on beta.1 must be made again.
- HTTP calls an earlier copy of the driver left at another port of this controller are removed only when nothing answers at that port (no answer within 10 seconds counts as a copy still running), so a copy still running keeps its own (no tug of war).
- The camera page is compared once per login instead of read every minute; a camera page fixed by hand clears its warning in Status.

## 1.0.0-beta.1 (1000001) - 2026-10-05

First release, a **beta**: built on DoorBird's published LAN API (revision 0.36) and the way Home Assistant's DoorBird integration uses it, tested against recorded API answers, not yet confirmed on a real DoorBird.

- One driver, `DirectorLink-DoorBird.c4z` (*DirectorLink · DoorBird* in Composer), for a DoorBird D10x, D11x, D21x or BirdGuard. Address, Username and Password of a DoorBird user made for Control4 in the driver's properties; the password is never logged.
- On connect, `info.cgi`: model, firmware, build, MAC and relays (with the relays of paired I/O door controllers) in the properties. The user's permissions are checked (API-Operator, Watch Always, History, Motion) and a missing one is named in **Status** and **Attention**; without API-Operator the driver refuses to register events and says so.
- Events the way Home Assistant gets them: an HTTP server on the controller, and one HTTP favorite per event on the DoorBird (`DirectorLink (doorbell 1)`, `(motion)`, `(RFID)`, `(relay 1)`) with a random token in its address, attached to the DoorBird's schedule for each doorbell button, motion, each RFID tag and each relay, the whole week.
- Only what the driver made is ever changed: every other favorite and schedule output is written back exactly as it was. Each entry is read just before it is written and checked right after (event, parameter, on/off and times of every other output); if the DoorBird drops or changes another app's output to make room, the entry is put back at once, left alone until its other outputs change or Reconnect runs, and **Attention** names who has it. Nothing is created or deleted on an unreliable read; the driver's favorites are deleted only after a read shows none of them in the schedule.
- A write is never left without its check: when the read back does not come, the entry as it was is remembered (saved) and checked at the next chance, and anything of another app's that went missing is put back.
- A new Address or login waits for what is on its way to the DoorBird to finish, then switches; nothing meant for one DoorBird reaches another. The old DoorBird is left once the new address has answered (a DoorBird that only changed address keeps its HTTP calls).
- Calls are taken only from the DoorBird's address and with the token; the same event again within 5 seconds is one event.
- The driver's HTTP calls leave the DoorBird with **Remove From DoorBird** (run it before deleting the driver) and when the Address changes (with the login that made them, tried again for a day; a DoorBird that only moved to a new address keeps them): the schedule first, then the favorites. A deleted driver starts the same.
- Camera proxy: the DoorBird's address and the user's Basic login on the camera page; pictures `image.cgi`, live video RTSP H.264 `mpeg/media.amp` on 554 (or RTSP over HTTP on 8557), MJPEG `video.cgi` as the fallback. A notification picture at the last ring or motion alert (live, or `history.cgi` without Watch Always).
- One RELAY connection per DoorBird relay for Control4 Relay Door, Gate and Garage Controllers: a pulse only (`open-door.cgi`), never held, no second pulse within 2 seconds.
- Programming: *Ring*, *Doorbell Pressed (Button n)* per button, *Motion Detected*, *Alert*, *RFID Read*, *Door Opened (Relay n)* per relay, *Door Opened*, *DoorBird Online/Offline*; `OPEN_DOOR` (with the DoorBird's relays), `LIGHT_ON`, `SET_ALERT_ON_MOTION`.
- DirectorLink camera agreement v1: `DIRECTORLINK_CAMERA` = `1`, `DIRECTORLINK_CAMERA_KIND` = `doorbell`; `LAST_RING` then *Ring*; `LAST_ALERT` = `Motion` then *Alert* (**Alert On Motion**, off by default, once per **Motion Alert Hold Time**).
- The DoorBird's limits respected: one request at a time, at most one per second; a refused login costs one request (the DoorBird never locks out the controller, so the official DoorBird driver keeps working), and the camera page gets a login only once the DoorBird took it; a 423 lockout is waited out.
- **Print Diagnostics** (device, firmware, relays, the event server's self-test, this driver's favorites and schedule entries, the last events and requests), **Test Pictures**, Debug lines for every request and every call, never with the password or the token.
- Not included: Control4 Intercom and audio/SIP (keep the official DoorBird driver for those).

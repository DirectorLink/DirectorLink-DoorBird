# DirectorLink · DoorBird for Control4

Free, open-source Control4 driver for DoorBird video door stations. Part of [DirectorLink Drivers](https://directorlink.io/drivers).

It works on your local network: the driver talks straight to the DoorBird with DoorBird's official LAN API, with no cloud, no extra hardware and no subscription.

Free. No subscription, no license key, no account with us.

Made by [DirectorLink](https://directorlink.io), the open-source management layer for Control4 homes. Works on its own: DirectorLink is not required.

**Download:** [releases](../../releases) · **Help and updates:** [directorlink.io/drivers/doorbird](https://directorlink.io/drivers/doorbird)

> **Beta.** This first release follows DoorBird's published LAN API and the way Home Assistant's DoorBird integration uses it, and passes its tests against recorded API answers, but it has not run on a real DoorBird yet. It stays a beta until an installer's logs confirm rings, motion, pictures, video and the relays. If you try it, please send the log: see [Testing the beta](#testing-the-beta).

## Features

| Feature | Control4 app | Programming |
|---|---|---|
| Doorbell rings, for each button | Notifications with the picture at the ring | *Ring* and *Doorbell Pressed (Button 1)* events, `LAST_RING`, `LAST_DOORBELL` |
| Motion | Optional alerts with a picture, once per visit | *Motion Detected* and *Alert* events, `LAST_MOTION`, `LAST_ALERT` |
| RFID tags | — | *RFID Read* event, `LAST_RFID` |
| Doors and gates on the DoorBird's relays | Control4 Relay Door, Gate and Garage Controllers | One relay connection per relay (a pulse only), *Door Opened (Relay 1)* events, `OPEN_DOOR` |
| Live video and pictures | The camera view: H.264 (RTSP), MJPEG as the fallback | — |
| IR light | — | `LIGHT_ON` |
| Health | — | *DoorBird Online/Offline* events, `ONLINE` |

## Requirements

- **Control4 OS 3.3.0 or newer** and Composer Pro.
- **A DoorBird video door station** (D10x, D11x, D21x) or BirdGuard. Events need **firmware 000110 or newer** (favorites and schedules came with it); older firmware gets pictures, video and the relays.
- **A DoorBird user for Control4** with the permissions **API-Operator**, **Watch Always**, **History** and **Motion** (see [Setup](#setup)).
- The DoorBird and the controller can reach each other on the home network: the controller reaches the DoorBird on port 80 (and 554 or 8557 for video), the DoorBird reaches the controller on the driver's event port: a port from 47300 (47300 plus the last two digits of the driver's device number, or the next free one), shown in the **Events** property.

**Not part of this driver: Control4 Intercom and audio/SIP.** Installers who use Control4 Intercom with the DoorBird keep the official DoorBird driver for that. Both drivers can run side by side on the same DoorBird: see [Next to the official DoorBird driver](#next-to-the-official-doorbird-driver).

## Installation

1. Download `DirectorLink-DoorBird.c4z` from the [releases](../../releases) (the beta is marked *Pre-release*).
2. In Composer Pro: **Driver → Add or Update Driver or Agent**.
3. Search **DirectorLink** and add **DirectorLink · DoorBird** to the room of the door.

> **Keep the exact file name.** If your browser saves a second copy as `DirectorLink-DoorBird (1).c4z`, rename it before you upload. Composer knows a driver by its file name, so a renamed copy installs as a separate driver instead of updating the one you have.

## Setup

1. **Make a DoorBird user for Control4.** In the DoorBird app: **Settings → Administration** (log in with the administration user from the DoorBird's digital passport), **User → Add**. Turn on **API-Operator**, **Watch Always**, **History** and **Motion**, and save. Note the username (for example `ghchdi0002`) and its password.
2. **Give the DoorBird a fixed IP address** in the router.
3. **Enter the login.** In the driver's properties enter **Address** (the DoorBird's IP), **Username** and **Password**. Within half a minute **Status** says *Online - events live*, and **DoorBird**, **MAC Address**, **Relays** and **Permissions** show what the DoorBird reported.
4. **Doors and gates.** Under **Connections → Control**, bind **Relay 1** (and the others) to a Control4 *Relay Door*, *Relay Gate* or *Relay Garage Controller*.

If **Status** or **Attention** names a missing permission, add it to the user in the DoorBird app and run **Reconnect**.

### Next to the official DoorBird driver

The official DoorBird driver and this one can run on the same DoorBird and the same controller. Give each its own DoorBird user. This driver changes only what it made on the DoorBird (see [How events work](#how-events-work)); the official driver's settings, its HTTP calls and the relays bound to it are left alone. Keep the official driver for Control4 Intercom.

A wrong password makes a DoorBird block the controller's address for a minute, which would also stop the official driver. So this driver sends one request with a refused login, then nothing until the **Username** or **Password** changes, or until you run **Reconnect**.

### How events work

The way Home Assistant does it, with the DoorBird's own HTTP calls:

- The driver runs a small HTTP server on the controller, on a port from 47300 (47300 plus the last two digits of the driver's device number, or the next free one), shown in the **Events** property.
- It adds its own **HTTP calls** (favorites) on the DoorBird, one per event: `DirectorLink (doorbell 1)`, `DirectorLink (motion)`, `DirectorLink (RFID)`, `DirectorLink (relay 1)`. Each one's address carries a random token.
- It adds them to the DoorBird's **schedule** for each doorbell button, motion, each RFID tag and each relay of the DoorBird itself, active the whole week. Every other entry of the schedule stays exactly as it was: the DoorBird app's push notifications, other apps' HTTP calls (including the official driver's), SIP calls and relays.
- It reads each entry just before it writes it (so what another app changed a moment ago is kept), and reads it again right after. If any other output went missing or changed (some DoorBirds keep one HTTP call per event), the driver puts the entry back as it was read and **Attention** says which event and who has it. Such an entry, and one the DoorBird refuses or does not keep, is then left alone until its other outputs change or you run **Reconnect**.
- It never creates or deletes on doubt: an entry is created only when the DoorBird's answer shows it is not there, removed whole only when the driver created it and nothing else is in it, and the driver's favorites are deleted only after a read shows none of them in the schedule (the DoorBird drops the entries that use a deleted favorite).
- A new Address or login stops what was on its way: nothing made for one DoorBird reaches another.
- A call is taken only from the DoorBird's address and with the token. The same event again within 5 seconds is one event (one press, one ring).
- Every 30 minutes the driver checks its HTTP calls (for example after a new RFID tag or a new controller address) and fixes only its own.

The DoorBird app shows these HTTP calls under the schedule of each button. Leave them in place. When the **Address** changes, or you run **Remove From DoorBird**, the driver takes its HTTP calls out of the schedule first and deletes them after (an old DoorBird that does not answer is tried again every 15 minutes for a day). **Before deleting the driver, run Remove From DoorBird**: a deleted driver starts the same, but Control4 may stop it before it is done.

The relays of a paired DoorBird I/O Door Controller (shown as `abcdef@1`) can be opened, but the DoorBird does not report when they open by themselves.

### Pictures and video

The camera's **Properties** page gets the DoorBird's address and the Control4 user's **Basic** login, so Control4 apps and DirectorLink take pictures and video straight from the DoorBird:

| | |
|---|---|
| Pictures | `http://<DoorBird>/bha-api/image.cgi` |
| Live video | `rtsp://<DoorBird>:554/mpeg/media.amp` (H.264). **Live Video** = *RTSP over HTTP (port 8557)* for networks where 554 is blocked. |
| Fallback | MJPEG, `http://<DoorBird>/bha-api/video.cgi` |
| Notifications | *Picture at the last ring or motion alert*: the live picture taken at the event, or the DoorBird's own picture of it (`history.cgi`) when the user lacks Watch Always |

Change the login in the driver's properties, not on the camera page: the driver puts the page back.

### Alerts

**Motion Detected** fires for every motion the DoorBird reports. Use it for automations, such as the porch light at night.

**Alert** is the part meant for people (and DirectorLink). With **Alert On Motion** = *On* (it is *Off* by default), motion sets `LAST_ALERT` to `Motion` and fires *Alert*, once per visit: after an alert, more motion raises no new alert until **Motion Alert Hold Time** (60 s) has passed without motion. `SET_ALERT_ON_MOTION` turns it on and off from programming, for example with the alarm.

### Settings

| Property | |
|---|---|
| Address · Username · Password | The DoorBird's IP and the Control4 user's login. The password is never logged. |
| Status · Attention | What the driver is doing; what to fix |
| DoorBird · MAC Address · Relays · Doorbell Buttons · Permissions | What `info.cgi` and the schedule report, and the user's permissions |
| Events · Last Event | The registered events and the event server; the last event |
| Alert On Motion · Motion Alert Hold Time (s) | Motion alerts, off by default; one per visit |
| Picture With Events · Record In History | A picture for notifications (Ring and Alert wait up to 1.5 s for it); Control4 History entries |
| Live Video | RTSP (port 554) or RTSP over HTTP (port 8557) |
| Log Level | *Debug* shows every request to the DoorBird and every call from it |

**Actions:** Print Diagnostics · Test Pictures · Reconnect · Open Door (Relay 1) · IR Light On · Remove From DoorBird

## With DirectorLink

DirectorLink 1.10 and newer shows the DoorBird as a doorbell in the DirectorLink app as soon as both are installed. Nothing needs to be set up: the driver follows the DirectorLink camera agreement, so DirectorLink recognizes it by what it says, not by its file name.

- **Rings with the live picture on the phone.** The driver sets `DIRECTORLINK_CAMERA` = `1` and `DIRECTORLINK_CAMERA_KIND` = `doorbell`. Each press of a button sets `LAST_RING` to the time (ISO 8601 UTC), then fires *Ring*. DirectorLink takes the picture the way Control4 apps do, from the camera's Properties page, so the DoorBird login never leaves the controller.
- **Motion alerts.** With **Alert On Motion** = *On*, motion sets `LAST_ALERT` to `Motion`, then fires *Alert*, once per **Motion Alert Hold Time**.
- **Opening the gate with two taps.** Bind the DoorBird's relay to a Control4 Relay Gate (or Door) Controller and DirectorLink opens it with two taps. The driver pulses the relay: it is never held.

Without DirectorLink the driver works the same.

## Programming examples

- **The doorbell.** *When* **Ring** → announce "Someone is at the front door", show the DoorBird on the touchscreens, and send a notification with the attachment **Picture at the last ring or motion alert**.
- **A second button.** *When* **Doorbell Pressed (Button 2)** → ring the chime upstairs.
- **Motion at night.** *When* **Motion Detected**, *if* it is dark, run `LIGHT_ON` (the IR light) and turn on the porch light.
- **Alerts follow the alarm.** When the security system arms, run `SET_ALERT_ON_MOTION On`; when it disarms, `Off`.
- **Who opened the gate.** *When* **Door Opened (Relay 1)** → add it to the Control4 History; *when* **RFID Read** → turn on the hall light.

### Reference

- **Events:** Ring · Doorbell Pressed (Button 1), one per button · Motion Detected · Alert · RFID Read · Door Opened (Relay 1), one per relay · Door Opened (any relay) · DoorBird Online · DoorBird Offline
- **Variables:** `DIRECTORLINK_CAMERA` `DIRECTORLINK_CAMERA_KIND` `LAST_ALERT` `LAST_RING` `LAST_MOTION` `LAST_DOORBELL` `LAST_RFID` `LAST_RELAY` `LAST_DOOR_OPENED` `LAST_EVENT` (STRING) · `ONLINE` (BOOL). Times are ISO 8601 UTC.
- **Conditionals:** DoorBird is Online · Alert on motion is On
- **Commands:** `OPEN_DOOR` (a relay, from the DoorBird's list) · `LIGHT_ON` · `SET_ALERT_ON_MOTION` (On/Off/Toggle)
- **Connections** (Connections → Control): Relay 1, Relay 2, ... one per DoorBird relay (RELAY). CLOSE, TRIGGER and TOGGLE pulse the relay once; OPEN sends nothing (the relay is at rest). A second pulse within 2 seconds is not sent.
- **Notification attachment:** picture at the last ring or motion alert

## Updating

1. Download the new `DirectorLink-DoorBird.c4z` from the [releases](../../releases).
2. Check that the name is exactly `DirectorLink-DoorBird.c4z`, not `... (1).c4z`.
3. **Driver → Add or Update Driver or Agent**. The driver keeps its settings, its HTTP calls on the DoorBird, the relay connections and the programming.

## Troubleshooting

| What you see | What to do |
|---|---|
| "Login refused by the DoorBird" | Check **Username** and **Password** (the user made for Control4, not the administration user). The driver sends nothing more until they change, then connects by itself. |
| "lacks the API-Operator permission" | In the DoorBird app, give the user **API-Operator**, then run **Reconnect**. Pictures, video and relays work without it; events do not. |
| *Attention*: "also needs: Watch Always" | Without it the DoorBird gives live video and pictures, and opens doors, only within 5 minutes of a ring. |
| *Attention*: "the DoorBird keeps one HTTP call for doorbell 1, and ... has it" | Another app has the DoorBird's HTTP call for that event. The driver put it back as it was and leaves that entry alone. Remove that HTTP call from the DoorBird's schedule if it is not needed: the driver then registers by itself within 30 minutes (or run **Reconnect**). |
| *Attention*: "the DoorBird did not keep the HTTP call for ..." | The DoorBird kept another app's HTTP call instead. Same as above. |
| *Attention*: "the DoorBird does not take a schedule for relay 1" | This DoorBird cannot report its relays. Doors opened from Control4 still fire *Door Opened*. |
| No events, *Status* is *Online - events live* | Run **Print Diagnostics**: the event server's self-test, this driver's HTTP calls and the calls refused (from which address and why). The DoorBird must reach the controller on the event port. |
| Pictures, but no live video | Try **Live Video** = *RTSP over HTTP (port 8557)*. Check the user has **Watch Always**. |
| Old firmware | Update the DoorBird (firmware 000110 or newer) for events. |

For details run **Print Diagnostics**, with **Log Level** set to *Debug*. The output appears in the Lua tab and in the driver log.

## Testing the beta

The beta needs confirmation on a real system. A safe way is next to an official DoorBird driver that already works, with its own user:

1. **Before:** note that the official driver's events (ring, motion) and its gate work.
2. In the DoorBird app make a **second** user for this driver (API-Operator, Watch Always, History, Motion).
3. Add **DirectorLink · DoorBird** to a test project, or next to the official driver in the same project. Do not change or remove the official driver or the Gate Controller bound to its relay. Set **Log Level** to **Debug** and enter the address and the new user's login.
4. Run **Print Diagnostics** and **Test Pictures**. Look at the camera on a touchscreen and in the Control4 app (pictures, then live video).
5. Press the doorbell, walk past the DoorBird, use an RFID tag if there is one, and (if the gate may be opened) open it from the DoorBird app. Each should show as an event in the Lua tab and in **Last Event**.
6. **After:** check that the official driver still gets its rings and motion and that its gate still opens. If the DoorBird keeps one HTTP call per event, **Attention** names the event the official driver holds; the official driver keeps it.
7. Open the gate once with **Open Door (Relay 1)** (only if that gate may be opened), and bind a test Relay Gate Controller to **Relay 1** if you want to try the connection.
8. Send the Lua tab output (or `driver_log.log`) and the **Print Diagnostics** output in an [issue](../../issues).

Every line of the driver starts with `DoorBird '<name>':`. At *Debug* the log shows every request to the DoorBird (path, answer, time) and every call from it (or why it was refused). It never shows the password, the event token or another app's HTTP call addresses (they may hold logins); **Print Diagnostics** shows other apps' HTTP calls by title only.

To take the driver off the DoorBird again, run **Remove From DoorBird**, then delete the driver: its HTTP calls go and nothing else changes.

## Privacy

The driver talks only to the DoorBird on your home network. It sends nothing to DirectorLink or to DoorBird's cloud and collects no usage data. (Pictures of past rings and motion, `history.cgi`, are kept by the DoorBird in its cloud; the driver asks the DoorBird for them, never the cloud.)

The DoorBird login stays in your Control4 project. Reports and logs never show the password or the event token.

## Support

Community-supported, best effort. Report problems in [Issues](../../issues).

Please include the DoorBird model and firmware (the **DoorBird** property), your Control4 OS version, the driver's **Driver Version**, the **Print Diagnostics** output and the log with **Log Level** set to *Debug*. Remove addresses and names you don't want to share. Reports that a model works are welcome too. Security problems: see [SECURITY.md](SECURITY.md).

## Building from source

```
pip install lupa pillow
python tools/make_icons.py       # after changing icons
cd tests && python test_static.py && python test_xml.py && python test_protocol.py && python test_driver.py && cd ..
python tools/build.py            # -> dist/DirectorLink-DoorBird.c4z, dist/SHA256SUMS.txt
```

`test_static.py` needs `luac` 5.1 (`apt install lua5.1`).

| Path | Contents |
|---|---|
| `src/core.lua` | Logging with secret redaction, timers, variables and events, utilities |
| `src/json.lua` | JSON that writes back exactly what it read (`{}` stays `{}`) |
| `src/api.lua` | The LAN API client: Basic login, one request at a time and at most one per second, the refused-login guard |
| `src/server.lua` | The event server on the controller (C4:CreateTCPServer) |
| `src/registration.lua` | The driver's HTTP calls on the DoorBird: favorites.cgi and schedule.cgi, each entry read before it is written and checked after |
| `src/driver.lua`, `src/driver.xml`, `src/www/` | The driver, its definition, documentation and icons |
| `tools/` | `build.py` (package), `make_icons.py` (icons) |
| `tests/` | `harness.py` (Lua 5.1 with a stubbed Control4 API and a virtual clock), `fake_doorbird.py` (a DoorBird, from `fixtures/`), and the tests |
| `VERSION`, `CHANGELOG.md`, `docs/releases/` | The version, the change log, and the notes for each release |

`build.py` puts the Lua parts together and stamps the version from `VERSION` and the build date into the packaged copy. The driver version Composer compares is major·1000000 + minor·10000 + patch·100 + build, where build is the beta number, or 99 for the release: `1.0.0-beta.1` → `1000001`, `1.0.0` → `1000099`.

The tests run the real driver code in Lua 5.1 against `fake_doorbird.py`, which answers with recorded answers in the shape of the DoorBird's (invented values) and keeps its favorites and schedule like a DoorBird, so what the driver writes is read back. They cover info.cgi, the permission checks, registering every event without changing anything else (byte for byte), DoorBirds that keep one HTTP call per event (keeping the last or the first), one that changes another app's times, one without relay schedules, schedule answers that are 204, empty or in an unknown form, another app writing between the driver's read and its write, a read back that fails (nothing deleted), the address changing while requests are on their way, the event server (address, token, repeats), the DirectorLink camera agreement, alerts and the hold time, pictures, relays (a pulse only), the camera page (only with a login that worked), a refused login (one request, also on a new address), the 423 lockout, the pacing (one request per second), leaving the DoorBird (address change, a DoorBird that moved, an old DoorBird that refuses the old login, Remove From DoorBird, the driver deleted), a restart, and that no log line shows the password, the token or another app's URL.

**How it works**

- **API:** `bha-api/info.cgi`, `image.cgi`, `history.cgi?event=doorbell|motionsensor&index=1`, `video.cgi`, `open-door.cgi?r=<relay>`, `light-on.cgi`, `favorites.cgi` (read, `action=save`, `action=remove`), `schedule.cgi` (read, POST, `action=remove`), with Basic login on port 80; RTSP `mpeg/media.amp` on 554 or 8557.
- **Events:** favorites `http://<controller>:<port>/doorbird?e=<event>[&p=<button or relay>]&t=<token>`, one `http` output each in the matching schedule entries, the whole week (`weekdays` from 104400 to 104399, a window that wraps around, as Home Assistant writes it, or the DoorBird's own whole-week window when the entry has one).
- **Relay connections and per-button and per-relay events** are added at run time (`C4:AddDynamicBinding`, `C4:AddEvent`) and kept in the driver's saved settings, so bindings and programming stay across restarts and updates.
- **Requests** identify themselves with the User-Agent `DirectorLink-DoorBird/<version>`.

**Rules for new versions**

- `VERSION` is the only place the version is set.
- **Never rename** the `.c4z` file, and **never change or remove** proxy binding ids, the order of variables, event and command ids, property names, or the ids of the run-time events (101+, 201+) and relay connections (301+). Dealers' projects (and DirectorLink) depend on them. Adding new ones is fine.
- Update `VERSION`, `CHANGELOG.md`, the change log in `src/www/documentation.html`, and `docs/releases/v<version>.md`. Then tag `v<version>`: GitHub Actions tests, builds and publishes the release with `SHA256SUMS.txt` (a pre-release for `-beta` versions).

## License and trademarks

[Apache License 2.0](LICENSE). See also [NOTICE](NOTICE).

The driver uses DoorBird's official [LAN API](https://www.doorbird.com/downloads/api_lan.pdf). How events are registered was learned from the open-source [Home Assistant DoorBird integration](https://github.com/home-assistant/core/tree/dev/homeassistant/components/doorbird) and [DoorBirdPy](https://github.com/klikini/doorbirdpy). No code was copied from them. Control4 interfaces follow the public [Snap One DriverWorks documentation](https://snap-one.github.io/docs-driverworks-fundamentals/). DirectorLink's own source code: [github.directorlink.io](https://github.directorlink.io).

Installing third-party drivers or changing a Control4 project can affect compatibility, support, warranty or recovery. Keep a backup of your project.

Apache License 2.0. Copyright 2026 DirectorLink. DirectorLink is an independent project, not affiliated with Control4 or Snap One. Not affiliated with or endorsed by Bird Home Automation. Product names are trademarks of their owners.

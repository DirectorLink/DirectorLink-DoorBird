# Security policy

## Reporting a vulnerability

Please report security problems privately, not in public issues.

Open this repository's **Security** tab and choose **Report a vulnerability**. This uses GitHub's private vulnerability reporting, so only the maintainers see your report.

Include what you found, the driver version (**Driver Version** in Composer), and the steps to reproduce it. Leave out real passwords, addresses and names.

We will confirm the report, fix the problem in a new release, and credit you if you wish.

## Supported versions

Only the [newest release](../../releases) gets security fixes.

## Scope

The driver runs on the Control4 controller and talks only to the DoorBird you enter, with DoorBird's official LAN API.

- **The DoorBird login** (a user made for Control4) is kept in the Control4 project: the driver's Password property, and the camera page, which Control4 apps use for pictures and video. It is sent only to the configured DoorBird, as HTTP Basic authentication on port 80 (the LAN API as DoorBird documents it). Every log line passes through a filter that hides it.
- **Events** reach the driver through a small HTTP server on the controller (a port from 47300, shown in the driver's Events property). A call is taken only from the DoorBird's IP address and with a random 32-character token that is part of the driver's HTTP calls on the DoorBird. The token is saved encrypted and never logged; other calls are refused with 403.
- **Other apps' settings on the DoorBird** (their HTTP calls may hold logins in their addresses) are never logged or shown: Print Diagnostics names them by title only. The driver changes only the favorites that carry its token, and its own outputs in the schedule.
- **A wrong password** costs one request: the driver then stops until the login changes, so the DoorBird does not block the controller's address. The camera page (which Control4 apps and DirectorLink use) gets a login only after the DoorBird has taken it.
- **A change of address or login** waits for what is on its way to finish, then cancels everything still made for the old one: nothing meant for one DoorBird reaches another.

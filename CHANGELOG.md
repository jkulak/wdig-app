# Changelog

All notable changes to WDIG. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Lines under `### Internal` are for the repository, not for a tester's "What to Test".

## Unreleased

### Added

- A status banner over the map: tracking on with the time of the last fix, tracking off,
  the permission to fix with a tap into Settings, coarse mode with its reason, or a daytime
  hole in the fixes; tapping it opens the diagnostics.
- The diagnostics log: every recorder event, launch, kill, gap and settings change with the
  battery, the thermal state and the app's state at that moment, kept thirty days and never
  a position; a screen with a day's events, counts and a filter, and an export of the last
  seven days as JSON Lines through the share sheet. In a Debug build the recorder's numbers
  can be changed there without a build.
- A day exported as GPX from the map's share button: one track with a segment per trip, a
  waypoint per stop, and WDIG's own fields in the `wdig:` namespace, so the file opens in
  any map tool and loses nothing for ours.
- Segmentation on the phone: stops (five minutes within 75 m, at the median of their fixes),
  trips between them with the way of moving voted from the motion classes, the speed as the
  tie-breaker and the pedometer's cadence to tell a walk from a run, trains and flights by
  heuristics, and dotted legs on the map where the recorder had no fixes. It runs after every
  batch of points and when the app comes to the front; a real day now gets its colours and stops.
- Motion classes on every point (walking, running, cycling, automotive, stationary, with a
  confidence) from Core Motion, filled in afterwards for the minutes the app was away, and the
  live configuration chosen by the class instead of by speed; the pedometer's steps for a trip.
- Background location recording within the battery budget: live updates only while moving, a
  ten-minute warm phase and a geofence after a stop, wake-ups on a fence exit or a significant
  change, coarse mode in Low Power Mode or under 20 % battery.
- The map of a day: the route coloured by the way of moving where segments exist, the raw route
  where not, a dot with the time spent at each stop, a day stepper and the list of days.
- The map redraws by itself when the store changes under it: a segmentation run, a demo
  month or its removal shows up on the open day without a relaunch or a day change.
- A legend under the status banner with the ways of moving on the shown day, each a swatch
  and its name, in the palette's order; it is absent on a day with no trips.
- The list of days says what each day holds: its trips, stops and distance, as
  `3 trips · 2 stops · 12.4 km`, with the plural forms of English and Polish; a day with
  points and no segments keeps its point count.
- The nine colours of the ways of moving are colour sets in the asset catalog with a dark
  appearance, lighter and more saturated, so a route is readable on the dark map.
- The Status screen: the tracking switch, the last fix, the counts and the recent events; in a
  Debug build, a demo month to look at and a button to remove it. The demo month runs over
  Warsaw's real streets (Apple Maps routes between home, the Old Town, the Vistula, Łomianki,
  the office, Złote Tarasy, Kinoteka, Łazienki and Hala Koszyki), sampled as the recorder
  keeps fixes.

### Internal

- The recorder takes its clock and Core Location through its initialiser: `ContinuousClock` and
  `LocationBridges` in the app, a hand-moved clock and a fake in the unit tests, which now drive
  the warm phase, coarse mode and a launch without Core Location in the test run.
- The battery protocol, `docs/battery-protocol.md`: how a week on the phone measures the
  recorder against its 8-10 % a day, with every reading's path in Settings and the tuning
  ladder for a FAIL; `docs/battery-results.md` holds the rows.
- The roads to the phone in the repository: `make phone` installs a Debug build over Wi-Fi and
  reports the build the phone has, `make testflight` archives, signs in the cloud and uploads
  once per commit from a clean `main`, `make testflight-status` reads App Store Connect; the
  paperwork, the Test Information and the review note in `docs/testflight.md`.
- The SwiftData store mirroring the backend's tables, with one actor writing and reading.

- The Xcode project: SwiftUI app and unit-test target, the String Catalog in English and Polish,
  the shared scheme pinned to `en`, `PL` and `Europe/Warsaw`, and `make ci` as the gate before a
  merge.

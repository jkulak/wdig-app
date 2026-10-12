# Changelog

All notable changes to WDIG. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Lines under `### Internal` are for the repository, not for a tester's "What to Test".

## Unreleased

### Added

- Background location recording within the battery budget: live updates only while moving, a
  ten-minute warm phase and a geofence after a stop, wake-ups on a fence exit or a significant
  change, coarse mode in Low Power Mode or under 20 % battery.
- The map of a day: the route coloured by the way of moving where segments exist, the raw route
  where not, a dot with the time spent at each stop, a day stepper and the list of days.
- The Status screen: the tracking switch, the last fix, the counts and the recent events; in a
  Debug build, a demo month to look at and a button to remove it.

### Internal

- The SwiftData store mirroring the backend's tables, with one actor writing and reading.

- The Xcode project: SwiftUI app and unit-test target, the String Catalog in English and Polish,
  the shared scheme pinned to `en`, `PL` and `Europe/Warsaw`, and `make ci` as the gate before a
  merge.

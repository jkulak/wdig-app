# TestFlight

Every build is made on the Mac; there is no hosted macOS runner and no workflow that builds,
signs or uploads the app. `make ci` is the gate before a merge, `make testflight` is the road
to the testers, `make phone` the road to the phone on the same network.

## Once per app, in this order

Each of Apple's pages offers only what the step before it created, so the order is fixed.

1. The repository: bundle id `com.jkulak.wdig` and the team in every configuration, a
   1024×1024 icon without alpha, `ITSAppUsesNonExemptEncryption` false, the usage strings in
   `InfoPlist.xcstrings` in English and Polish, `ship.env` at the root. Done.
2. The App Store Connect API key with the Admin role on the Mac, in
   `~/.config/testflight-deploy/config` (`KEY_ID`, `ISSUER_ID`, `TEAM_ID`, `P8_PATH`). App
   Manager is not enough: cloud signing fails on it. Never printed, never committed. Done.
3. The App ID: https://developer.apple.com/account/resources/identifiers/list → + → App IDs →
   App → Explicit, `com.jkulak.wdig`, no capabilities. A click.
4. The app record: https://appstoreconnect.apple.com/apps → + → New App, iOS, the bundle id
   above, SKU `com.jkulak.wdig`. The numeric id in the record's URL goes into `ship.env` as
   `ASC_APP_ID` and is committed. A click.
5. The TestFlight internal group `Friends and family` with automatic distribution, under the
   record's TestFlight tab; me as the first tester; further testers as users of the team under
   Users and Access. Clicks.
6. Test Information, under the TestFlight tab, from the section below.
7. The first upload: `make testflight` on a clean `main`, then "What to Test" from the
   CHANGELOG entry of that build, then the invite accepted and one install from TestFlight.

## Every build

```bash
make testflight
```

archives with `CURRENT_PROJECT_VERSION` equal to `git rev-list --count HEAD`, exports with
`assets/ExportOptions.plist` (`app-store-connect`, `upload`, cloud signing with the key) and
uploads in the same run; it fails unless the log says `Upload succeeded`. Run twice on the same
commit, the second run fails on Apple's duplicate build number, as it should. Processing takes
five to fifteen minutes; `make testflight-status` shows the builds, the groups and the testers.
"What to Test" is set from the CHANGELOG with `scripts/asc.py notes <ASC_APP_ID> <build> "<text>"`.

A TestFlight build expires 90 days after its upload, so a release a month is the floor.

## Test Information

Entered once into App Store Connect, TestFlight tab, Test Information.

- Beta App Description: WDIG records where you go through the day, in the background, with
  as little battery as it can, and draws the day's route with the places you stopped. The
  recorder needs the location permission set to Always; nothing else is required, and no
  account is needed to record.
- Feedback Email: the address of the team's account in App Store Connect.
- Privacy Policy URL: https://wdig.itsnotezra.com/privacy

## Beta App Review note

Needed only for an external group; written now so that adding one is a click.

Background location is the app's purpose, not a side effect: WDIG is a location diary that
records the day's route while the phone is in the pocket. The recorder uses
`CLLocationUpdate.liveUpdates` with the Always authorization and `CLMonitor` geofences, pauses
when the phone is still, and resumes on a fence exit or a significant change. The data stays
on the phone unless the tester signs in to their own account, in which case it goes only to
that account on our server. Recording works without an account, so no sign-in is needed to
review: grant Always when asked, walk for ten minutes, open the app and look at the day map.

## Test steps for a tester

1. Install from TestFlight and open the app.
2. When asked, allow location Always and Motion & Fitness.
3. Switch Tracking on in the Status tab and put the phone away.
4. Walk somewhere for ten minutes, sit for twenty, walk back.
5. Open the Map tab: the walk is a coloured line, the sit a dot with the time spent.
6. The banner over the map says when the last fix was; if it reads anything else, tap it and
   export the diagnostics from the screen it opens.

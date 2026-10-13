# Battery protocol

The recorder is allowed up to 8-10 % of an iPhone 15's battery on an ordinary day with 1.5-2 h
of moving (decision of 2026-10-11). This is how that is measured on a real phone, written so
it can be repeated, by me or by a tester with another phone.

## When it is run again

After any change to the recorder's design (`WDIG/Recorder/`) or to the defaults in
`RecorderSettings`, and after any rung of the tuning ladder below. A design is not a
measurement: the warm phase, the two live configurations and the wake-ups cost what the phone
says they cost, not what the code intends.

## Set-up

1. An iPhone 15 or newer on iOS 26, with a Release build installed through TestFlight
   (`docs/testflight.md`) or over Wi-Fi with `make phone`. Never a Debug build. The build number
   goes into every row of the results.
2. Settings > Privacy & Security > Location Services > WDIG: Always, Precise Location on.
3. Settings > General > Background App Refresh: on, and on for WDIG.
4. Settings > Battery: Low Power Mode off for the whole week (it switches the recorder into
   coarse mode). Adaptive Power off, where the phone offers it.
5. Settings > Privacy & Security > Motion & Fitness: on, and on for WDIG.
6. The app's Status tab shows Location "always" and Motion & Fitness "authorized".

## Days

7. Day 0, the baseline: tracking off for a whole day, from midnight to midnight. WDIG must be
   absent from Settings > Battery or under 1 % of capacity.
8. Days 1-7: tracking on from midnight to midnight, the phone carried as always, WDIG in the
   foreground under 5 minutes a day. The map costs screen time, which is not the recorder's.
9. On at least 3 of the days, note the time of leaving the door; it is compared with the first
   point of that trip in the results.

## Readings, each evening after 22:00 or the next morning for the previous day

10. Settings > Battery > Last 10 Days, the day selected: the day's total battery usage in
    per cent, and under it WDIG's share of it in per cent. WDIG's per cent of capacity is the
    share times the usage divided by 100.
11. The same screen, the Activity view (the tab above the list): WDIG's on-screen minutes and
    background minutes.
12. The app: Map tab, tap the banner, Diagnostics: the day's points kept, warm phases,
    relaunches and minutes in coarse mode are in the header; the worst `thermalState` while
    recording and not charging is read from the events (every event carries it). Export the
    day from there and keep the file with the results.
13. Minutes moving per class: from the day's segments on the map, or from the diagnostics
    export's `configurationChanged` events and the GPX of the day.

## What counts

14. An ordinary day has 1.5-2 h of moving under any mix of walk, run, bike, scooter and car,
    and no minute in coarse mode. Other days are recorded and marked, and do not count for
    the verdict. Fewer than 4 ordinary days extend the week until there are 4.

## Verdict

15. PASS when every ordinary day is at most 10 % of capacity and the median of the ordinary
    days is at most 9 %. FAIL otherwise. Under 5 % every day is noted as headroom, not as a
    reason to record more densely.
16. No ordinary day may log `serious` or `critical` thermal state while recording and not
    charging.

## The tuning ladder, on FAIL

One rung at a time, each measured over 3 more ordinary days, in the Diagnostics screen's
Tuning section of a Debug build or in the defaults of `RecorderSettings`:

1. `warmPhaseSeconds` 600 → 300. The warm phase is the only time the radio is on while I am
   still; warm phases per day × 10 minutes shows its share.
2. `fenceRadiusM` 150 → 250, when relaunches exceed 20 a day. Each relaunch starts a sequence.
3. `classHoldSeconds` 60 → 120, when `configurationChanged` exceeds 10 an hour. Each switch
   restarts the sequence.
4. Thinning 10/25/50 m → 15/40/80 m. Saves writes and upload size, not GPS time; last, with
   little expected.
5. Still over: a design change in the recorder, measured as a variant, as a new task.

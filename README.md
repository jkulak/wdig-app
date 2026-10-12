# WDIG

Where did I go? An iOS app that records where I was through the day with the least battery it
can, and shows the day's route on a map with the places I stopped. iPhone 15 and newer, iOS 26
and newer, SwiftUI.

## Building

Everything runs on the Mac with Xcode; there is no hosted runner.

```bash
make help     # the targets
make test     # build and run the unit tests on a simulator
make lint     # swift format, strict
make ci       # the gate before a merge: lint, build and tests on a clean checkout of the merge result
```

`make ci` prints one line at the end; that line goes into the pull request body in place of a
green tick.

## Layout

| Folder | What | Task |
|--------|------|------|
| `WDIG/App` | The entry point and the app delegate (launch options) | 001 |
| `WDIG/Recorder` | The background location recorder and motion activity | 002, 004 |
| `WDIG/Store` | The SwiftData store | 003 |
| `WDIG/Segmentation` | Stops, trips and modes from raw points | 005 |
| `WDIG/Views` | The screens | 006, 007, 015 |
| `WDIG/Sync` | Account, upload and restore, the generated API client | 009, 010, 013 |
| `WDIG/Export` | GPX export | 011 |
| `WDIGTests` | Unit tests (Swift Testing) | |

Task numbers refer to the task files in `issues/`, which stay out of the repository until they
move to GitHub issues.

# Live native rejection acceptance protocol

Leave Advanced → Observation only and Record system input events off, then Start palm rejection. App sessions run until stopped without a time limit. Record macOS/build, target device family/transport, Trackpad settings, and whether three-finger dragging or tap-to-click are enabled. Export a capture from Advanced after each scenario; each Start resets capture and filter counters. The user has confirmed working rejection, but the full scenario matrix below remains pending.

The previous release's Start, local ⌘D, and automatic cutoff were checked through the UI on macOS 15.7.5. That cutoff has been removed. Verify the current session remains active beyond 60 seconds and stops on request; this does not replace checks during a physical click, drag, or scroll.

| Scenario | What to record | Selective filtering acceptance condition |
| --- | --- | --- |
| Device selection | Bluetooth Magic Trackpad selected; built-in trackpad listed but ineligible | Only selected raw stream changes; other services remain usable |
| Status and controls | Start, Stop, observation mode, disconnect/reconnect, filter failure, quit/reopen | Active/Stopped/Observing/Disconnected/Unavailable/Error match the actual session; reconnect/reopen never starts protection; margin fields, sliders, and canvas stay in sync |
| Installed app | Build, install, launch Applications copy; open Settings and About; Show app in Finder | Running version/build and actual app path are visible; original icon appears; diagnostics are collapsed on launch; startup and minimize preferences are in Settings |
| Orientation | Touch each physical corner individually; compare map | Left/right/top/bottom align with physical device |
| All four edges | Move/tap/click/scroll on each 10% margin, including corners | No unwanted motion, clicks, scrolling, or gestures |
| Single crossing | Move center → edge → center without lifting | Pointer pauses and resumes without a jump |
| Palm resting | Hold a palm on each edge while moving a center finger | Center motion preserved and edge contribution absent |
| Palm moving | Move palm along each edge while moving center finger | Same as above without false suppression |
| Center clicking | Left click, tap-to-click if enabled, secondary click with palm at edge | Correct down/up and click behavior |
| Center dragging | Physical click-drag, and three-finger drag if enabled, with edge palm | Continuous drag; no stuck buttons on margin crossing or disable |
| Center scrolling | Two-finger vertical/horizontal scroll, reversal, momentum with edge palm | Scrolling preserved without edge contribution or stranded phase |
| Native gestures | Pinch, rotate, swipe, Mission Control, desktop/app switching as enabled | Apple gestures preserved with edge contact present |
| Other devices | Move/click/scroll built-in trackpad and another mouse while target edge is touched | Other devices fully usable |
| Startup | Choose Not Now and reopen; enable Open at login; reopen; disable; change approval in macOS Login Items; sign out/in or restart | One-time question stays answered; state matches macOS; enabled app opens after login with saved settings; disabled app does not; filtering starts only on request |
| Window location | Switch Dock/Menu bar; minimize with the button, yellow button, and ⌘M; restore; close in menu bar mode; quit/reopen | Rejection remains active while hidden/minimized; saved mode restores; menu Start/Stop works; Dock close quits |
| Stop/quit | ⌃⌥⌘D, Stop palm rejection, Dock close, ⌘Q during click/drag/scroll | Ordinary input resumes; no stuck buttons |
| Permissions/tap | Revoke Input Monitoring while observing; verify status and restart | Observation stops; input remains normal |
| Auto-start | Turn on Start protection automatically, press Start, quit and reopen; sleep/wake; switch the trackpad off and on; press Stop and reopen; run `kill -9` on the app twice while Active, reopening between | Protection resumes after reopen, wake and reconnect; a manual Stop stays stopped after reopen; after two kills automatic start pauses with a notice until a manual Start |
| Bluetooth disconnect | Switch target off during observation, then reconnect | Observation stops; explicit restart required; other devices work |
| Sleep/session | Sleep/wake or switch session while observing | Observation stops; explicit restart required |

In capture format 2, confirm `mode: experimental-native-raw-rejection`, increasing `nativeFilter.packets`, increasing `removedContactSamples` for edges, and zero `nativeFilter.error`. Check `blockedClicks` for an edge physical press. Original contact dots remain visible as diagnostics. A separate ordinary contact observer should receive center contacts without excluded edge contacts; keep both exports local when verifying routing.

Core Graphics timing is not rejection evidence; its events remain unattributed and unsuppressed because rejection occurs earlier. Blocking center input or forwarding all mixed raw contacts fails acceptance. If a required scenario fails, stop rejection and preserve its capture. Verify Stop palm rejection and local ⌘D before testing more gestures.

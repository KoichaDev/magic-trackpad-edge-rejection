# Native rejection implementation — 2026-10-01

**Experimental raw-contact rejection is implemented; full physical palm/gesture acceptance remains pending.** The previous observer failed the user's hands-on edge test: its dots moved, but edge input still moved the pointer. Its report is preserved in [CAPABILITIES-OBSERVATION.md](CAPABILITIES-OBSERVATION.md).

## Native path

MTDeviceStart bit 30 requests an AppleMultitouchDeviceUserClient of type FLTR. Driver inspection shows original frames routed to filter clients; frames reinjected by a filter client go to ordinary clients, including WindowServer. Startup verifies the process's FilterEnabled registry property. This operates before native recognition and avoids splitting already processed mouse events.

No driver, gesture engine, system input preference, HID seizure, or service is installed. The app saves its own margin and Dock/menu bar settings.

## Evidence and limits

Device/contact captures and detailed verification output stay local under the ignored `verification/` directory. Only aggregate results are included here.

- The correctly flagged five-second passthrough probe opened and closed on macOS 15.7.5 arm64, forwarding **103 packets with zero reinjection errors**, including contact report 0x31 and control report 0x40.
- **101 decoded positions** matched Apple's normalized callbacks with maximum error below **0.000000031** on both axes. Installed Compact V7 code independently confirms scaling raw signed coordinates by two, Y offset by 5000, then normalization against Sensor Surface Descriptor bounds.
- A preliminary probe mistakenly used bit 31, opening an ordinary observer and causing a reinjection feedback loop. It was stopped. Those frames are excluded from successful filter evidence. Production startup uses bit 30 and explicit driver confirmation.
- Sanitizer-enabled packet checks cover mixed contacts, four margins, empty frames, reentry state, edge click starts, accepted releases, admitted liftoff, immutable input, preserved timestamps, duplicate IDs, malformed lengths, output capacity, invalid margins, and unchanged control reports.
- The existing 49 model assertions verify diagnostics, not palm rejection.
- The implemented native rejection probe processed **137 raw packets**, removed **3 edge-contact samples**, received **136 valid contact frames**, and reported **zero filtering/reinjection errors**. It stopped after ten seconds and closed the filter client. This confirms an active filtering path, not the full physical gesture matrix. Its capture is saved locally in `verification/native-rejection-check.json`.
- The original implementation's Start, local ⌘D stop, and 60-second cutoff were verified through the UI. The user subsequently confirmed working palm rejection. App sessions now run until stopped, without that cutoff; command-line probes still end after their requested duration. Physical drag/scroll recovery remains pending.
- Release 0.2 remained active for at least 97 seconds in a UI check. Its explicit Stop and restart were verified; the stopped session reported 3,690 raw packets and 614 rejected contact samples. See `verification/continuous-palm-rejection.md`.

- Release 0.3 clean-source `sh test.sh` and `sh build-app.sh` passed. UI checks verified switching Dock/menu bar while active, remaining active after minimize/hide/close actions, and restoring the menu bar preference and margins after quitting and reopening. Direct interaction with the status icon menu remains a manual check; the automation surface exposes the app window rather than status items.

## Requirement status

| Requirement | Implementation / acceptance |
| --- | --- |
| Four independent exclusion margins | Native filtering implemented; controlled physical orientation test pending. |
| Edge palm removed with simultaneous center finger | Per-record removal implemented before Apple's recognizer; controlled physical acceptance pending. |
| Pause and resume without a pointer jump | Contact removal and make-touch reentry implemented; pointer/drag acceptance pending. |
| Edge physical / tap / force clicks | Button starts and force-stage bits filtered; native tap recognizer sees remaining contacts. Hardware acceptance pending. |
| Center scroll and native gestures with edge palm | Apple's engine receives center contacts only; full gesture matrix pending. |
| Other pointing devices remain usable | Only the selected eligible external service is filtered; physical multi-device test pending. |
| Stop / quit / failures | Filter-client closure and empty release frame implemented; no app-session timeout. Physical drag/scroll/disconnect test pending. |
| Emergency shortcut | Stop palm rejection and local ⌘D available. Global shortcut remains unverified. |
| Dock / menu bar | Saved window-location preference; hiding/minimizing keeps rejection active; menu bar close hides, Dock close quits. Status icon offers Show, Start/Stop, mode selection, and Quit. |
| Coverage | macOS 15.7.5, family 129, driver type 4, parser 1000 / Compact V7 only. |

Do not claim complete palm rejection until [manual acceptance](MANUAL-VERIFICATION.md) passes. Counters show implementation activity, not correct native gesture behavior.

## Other paths examined

[Apple's HID client header](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/HID/Headers/HIDEventSystemClient.h) requires a private entitlement for system event-filter callbacks. MTDeviceEnableBinaryFilters creates filters on the caller's device object and searches /System/Library/MultitouchPlugins; it does not by itself change WindowServer's recognizer. Neither path is used. The old observer limitation does not apply to the separately discovered raw filter-client route.

# Trackpad Edges

<img src="Assets/AppIcon.png" alt="Trackpad Edges app icon" width="96">

The app now removes edge contacts before Apple's native gesture recognizer. It opens the existing multitouch driver's private `FLTR` client and reinjects rewritten raw frames into the driver's ordinary stream. It installs no driver or service and keeps Apple's pointer and gesture engine.

Rejection has been confirmed in a hands-on trial; the full physical gesture matrix remains pending. App sessions have no time limit: click Start palm rejection and leave the app running until you stop it.

**Experimental and version-specific:** the validated environment is an Apple Silicon Mac running **macOS 15.7.5**, with a **Bluetooth Magic Trackpad family 129, driver type 4, parser type 1000 / Compact V7**. The filter refuses other macOS versions and unsupported trackpad protocols. Rebuilding alone does not add support for a different macOS version; the private interfaces and packet format need validation first.

## Build from source

### Prerequisites

- A Mac with Apple's Xcode Command Line Tools, including Swift 6 or later and Clang. Tested with Swift **6.2.3**. Full Xcode is not required.
- The compatible Mac/trackpad environment above to run native rejection.
- Git to clone the repository. There are no third-party package dependencies.

Install the Command Line Tools once if needed, then wait for installation to finish:

```sh
xcode-select --install
```

Check the Swift version, clone, test, and build:

```sh
swift --version
git clone https://github.com/KoichaDev/magic-trackpad-edge-rejection.git
cd magic-trackpad-edge-rejection
sh test.sh
sh build-app.sh
open build/TrackpadEdges.app
```

The build script creates a release executable, includes the app icon and bundle metadata, and signs `build/TrackpadEdges.app` with a local ad hoc signature. This is not an Apple Developer ID signature or notarization. The source repository excludes build outputs and local captures.

### Rebuild an existing checkout

Quit the running app before replacing its executable. From the repository directory:

```sh
sh test.sh
sh build-app.sh
open build/TrackpadEdges.app
```

Both scripts can be rerun after changing the code. If a cache contains paths from a moved checkout, run `swift package clean`, then repeat those commands. To regenerate the original icon after editing its drawing:

```sh
swift scripts/generate-app-icon.swift Assets
sh build-app.sh
```

Swift build caches are in `.build/`; the finished app is in `build/`. The generated iconset is ignored, while the PNG and ICNS used by the project are tracked.

## Use the app

1. Select the Bluetooth Magic Trackpad. Leave **Reject edges** and **Contacts only** checked. Contacts only skips the optional system event observer; raw rejection still runs.
2. Adjust Left, Right, Top, and Bottom with the sliders, percentage fields, or by dragging the green center's edges and corner handles. All three controls stay in sync in 1% steps, with each margin limited to 0–45%. Press Return or leave a percentage field to finish editing; out-of-range numbers are clamped and invalid text restores the current value. All four margins save automatically and are restored when you reopen the app.
3. Click **Start palm rejection**. It stays active without a timeout while the app and selected device remain available. Test a center finger with an edge palm, crossings, clicks, scrolling, and gestures using [MANUAL-VERIFICATION.md](MANUAL-VERIFICATION.md).
4. Choose **Minimize to → Dock** or **Menu bar**. This preference saves automatically. **Minimize**, the yellow window button, and **⌘M** keep rejection running. The original Trackpad Edges icon stays in the menu bar in both modes, with **Show Trackpad Edges**, **Start/Stop palm rejection**, and **Quit**. The Dock icon remains visible while the controls are open. Dock mode minimizes into the Dock; menu bar mode hides the Dock icon only when you hide/minimize the window. Showing the window restores the original Dock icon. Closing the window in menu bar mode also hides it; in Dock mode closing it quits. Reopening shows the controls; starting rejection still requires an explicit click.
5. Dots show original contacts: red contacts are excluded from reinjected packets. Counters count raw packets, rejected contact samples, and blocked physical click starts. Samples are not distinct fingers.
6. **Stop palm rejection**, local **⌘D**, or quit closes the filter client and restores ordinary input. The registered global **⌃⌥⌘D** shortcut still needs physical verification; use Stop palm rejection or local ⌘D during tests. Disconnect, sleep/session changes, or filter validation errors stop the session and require an explicit restart.
7. **Export capture…** saves bounded JSON with contact diagnostics and filter counters. Captures contain device identity and touch positions; keep them local.

Uncheck Reject edges for observation without changing input. Uncheck Contacts only to add a passive Core Graphics observer, which requires Input Monitoring. Raw rejection does not use Core Graphics suppression or timing-based attribution. A sandbox may deny the private client with `kIOReturnNotPermitted`; launch the app normally. No root helper or private entitlement is added.

## Command line

```sh
.build/debug/TrackpadEdges --devices
.build/debug/TrackpadEdges --diagnostics
.build/debug/TrackpadEdges --probe 15 --contacts-only --reject-edges --output /tmp/rejection-test.json
.build/debug/TrackpadEdges --probe 15 --contacts-only --output /tmp/observation-test.json
```

Command-line probes last at most 60 seconds for their requested diagnostic duration; app sessions have no time limit. Use `--device ID` when multiple eligible trackpads exist.

## Implementation and verification

The custom icon is drawn locally with AppKit. Preview [Assets/AppIcon.png](Assets/AppIcon.png); its packaged macOS version is `Assets/AppIcon.icns`. The source drawing is `scripts/generate-app-icon.swift`.

`MultitouchAdapter.c` opens `MTDeviceStart(device, 0x40000000)` and verifies the driver's `FilterEnabled` property for this process. **Bit 30 is the filter flag; bit 31 opens an ordinary observer and must not be used for reinjection.**

`RawContactFilter.c` validates Compact V7 packets, decodes positions against the device's Sensor Surface Descriptor, removes edge records, and preserves center records. Reentry starts with make-touch to reset native history. Admitted liftoffs remain visible. Physical click starts require an active center contact; accepted presses retain their release. Force-stage indication is cleared for excluded input.

Unknown non-contact reports pass unchanged. Invalid touch packets switch immediately to passthrough, followed by session shutdown. Reinjection errors, disconnect, sleep, session changes, and optional event-tap failures stop the session. Normal teardown sends an empty button-release frame to the selected native stream before closing its filter client.

Packet tests cover mixed contacts, all edges, crossings, button lifecycle, malformed packets, immutability, and timestamp preservation under address/undefined-behavior sanitizers. These checks do not replace physical acceptance. See [CAPABILITIES.md](CAPABILITIES.md); the [original observer report](CAPABILITIES-OBSERVATION.md) records the previous app's unsuccessful filtering approach.

No Core Graphics event is dropped: `EventSample.suppressed` stays false. Native filtering is reported separately in capture format 2.

## Sources

- Installed macOS 15.7.5 MultitouchSupport and AppleMultitouchDriver symbol/disassembly inspection: filter client, raw routing, injection, Compact V7 parser, and coordinate transform.
- [Linux Magic Trackpad decoder](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-magicmouse.c): independent reference for Bluetooth report 0x31 and nine-byte contact packing. This decoder is independently implemented and checked against Apple's callbacks.
- [Apple HID client header](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/HID/Headers/HIDEventSystemClient.h): system event-filter callbacks require a private entitlement. This app uses the multitouch driver's separate raw-client path.

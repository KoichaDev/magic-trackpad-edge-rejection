# Capability report — 2026-10-01

This is the historical observer-stage report, superseded by the [native rejection implementation](CAPABILITIES.md). Local device and contact captures mentioned below are intentionally excluded from the public repository.

**Result: the requested selective edge rejection is unsupported by this prototype.** The observation stage works on the connected Bluetooth Magic Trackpad. It does not disable edges, and implementation stops at the selective-filtering gate. No whole-trackpad blocking is supplied as a substitute.

This conclusion is about the implemented raw-contact/Core Graphics approach. It is not a claim that every possible private macOS mechanism has been disproven.

## Requirements

“Working” means demonstrated within the stated scope. “Partially working” means implemented with an explicit missing verification or limited diagnostic scope. “Unsupported” means the requested native filtering behavior is not provided.

| Requirement | Status | Evidence / limitation |
| --- | --- | --- |
| Separate Swift macOS prototype | **Working** | Standalone dependency-free package; debug/release builds succeeded on macOS 15.7.5, arm64, Swift 6.2.3. Ad hoc signed `.app` verified and launched. |
| Target the Bluetooth Magic Trackpad specifically | **Working** | Enumeration found external family 129, product Magic Trackpad, transport Bluetooth. Target contact subscription uses its exact ID. Built-in family 105/SPI is listed but ineligible. |
| Read device-specific raw contacts | **Working** | GUI capture received 139 valid frames, 134 nonempty frames, and 180 active-contact samples. Observed lifecycle states were 1, 3, 4, 5, 6, 7. This proves observation, not filtering. |
| Display contacts, blocked margins, and generated input events | **Partially working** | Window layout, four margin controls, raw capture, and JSON export verified. Margins are proposed exclusion zones only. Core Graphics event observation is implemented but lacked Input Monitoring permission; no event samples were recorded. Physical map orientation needs confirmation. |
| Independently adjustable left/right/top/bottom margins, initially 10% | **Working** | All four defaults visible at 10%; Left changed to 11% independently while the others stayed at 10%, then restored. Model boundary/independence tests passed. Supported range: 0–45% per side. |
| Ignore contacts outside the center | **Unsupported** | Excluding a copied contact from diagnostics does not remove it from Apple's native input processing. |
| Pause crossing finger at edge, resume inside without pointer jump | **Partially working** | Diagnostic per-contact delta model resets its baseline on exit/reentry and passes tests. **Actual native pointer pause/resume is unsupported**; no mouse movement is synthesized or suppressed. |
| Edge-only touches produce no unwanted mouse movement | **Unsupported** | Timing candidates cannot establish originating device or touch. No events are dropped. |
| Edge-only touches produce no unwanted clicks or drags | **Unsupported** | Click/down/up events cannot be safely assigned to the selected edge contact. No click filtering is provided. |
| Edge-only touches produce no unwanted scrolling | **Unsupported** | Processed scroll/momentum events lack the necessary verified contact/device attribution. |
| Edge-only touches produce no unwanted native gestures | **Unsupported** | Observation does not alter Apple's gesture input. Local AppKit gesture monitoring is not global gesture interception. |
| Center pointer movement with resting/moving edge palm | **Unsupported** | Passing a mixed event retains possible edge influence; dropping it also removes possible center influence. No decomposition is available in this implementation. |
| Center clicking/dragging with resting/moving edge palm | **Unsupported** | Same attribution/decomposition limit; no replacement click/drag engine is allowed or included. |
| Center scrolling with resting/moving edge palm | **Unsupported** | Apple's scroll recognition already saw both contacts. Filtering copied contacts cannot preserve native recognition while removing edge influence. |
| Enabled native gestures with resting/moving edge palm | **Unsupported** | A processed gesture cannot be retroactively recognized using only its center contacts through these adapters. No replacement gesture engine is included. |
| Built-in trackpad and other pointing devices remain usable | **Partially working** | Built-in trackpad is never selected; observer tap is listen-only and returns every event. No device settings or power are changed. A simultaneous physical multi-device test was not performed. |
| Keyboard disable shortcut | **Working** for local ⌘D; **Partially working** for global ⌃⌥⌘D | ⌘D stopped a running GUI observation session. Carbon global hotkey registration succeeded, but an automated global chord did not stop observation. Actual global keyboard behavior remains unverified. Disable button is also available. |
| Disable/quit restores ordinary input without stuck buttons | **Partially working** | Local disable and export-after-disable verified; app quit verified. There is no suppression, synthetic button state, power change, or HID seizure to undo. Physical click/drag/scroll during exit was not tested. |
| Lost permissions / tap timeout restores ordinary input | **Partially working** | Missing Input Monitoring is rejected before full observation begins. Permission/tap health paths stop observation. Revocation and forced tap-timeout tests were not performed. All events are passed and no button state is owned. |
| Disconnect restores ordinary input without stuck buttons | **Partially working** | Connected-device registry membership verified during probes. Missing registry membership stops observation; explicit restart required. Physical disconnect/reconnect was not tested. |

## Verification evidence

- Release build succeeded; `codesign --verify --strict` passed; `Info.plist` and shell scripts passed syntax validation.
- Seven standalone automated scenarios passed, comprising **49 assertions**. They cover margin boundaries, invalid data, duplicate IDs, mixed contacts, margin exit/reentry baselines, and refusal to suppress unattributed events. Run `sh test.sh`; full Xcode is not required.
- Device enumeration and environment/permission diagnostics were captured locally from the CLI.
- A three-second CLI contact probe started and stopped without invalid frames but received zero callbacks. No physical touch was requested during that probe. This result alone did not establish raw-contact access.
- A local GUI contact capture subsequently demonstrated actual callback delivery: 139 frames, 134 with contacts, 180 active-contact samples, zero invalid frames, zero Core Graphics event samples, final status `Disabled by user`. The unattended contacts were not a controlled edge/palm/gesture scenario.
- GUI margin independence, contact-only startup, local ⌘D disable, export, and return to 10% defaults were observed through the running UI. A screenshot was inspected for layout. Input Monitoring was not granted or changed during verification.
- Private `MTDeviceIsAlive` returned false on an enumerated connected device, including after starting this client. Connection checks therefore use fresh I/O Registry membership, rather than declaring the device disconnected based on that flag.

Live physical acceptance tests remain unperformed; the complete [manual protocol](MANUAL-VERIFICATION.md) records them. There is no claim of verified palm rejection, jump-free native pointer behavior, or native gesture preservation.

## Why filtering stops here

[Apple's touch-event documentation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html) states that processed mouse events cannot be correlated with an individual touch. The installed Core Graphics event fields provide process/state/subtype information but no verified physical Magic Trackpad/contact identity; [Karabiner-Elements' authors](https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md#cgeventtapcreate) describe this device-attribution limitation as well.

The private adapter exposes a copied raw frame, not a demonstrated input filter upstream of Apple's gesture recognition. [Subsurface](https://github.com/mrkai77/Subsurface/tree/88eb16b0a6f7a44a898cecff9e283298aa413936) provides evidence of contact access and reference signatures; it does not establish that removing a contact from our copy removes it from the native recognizer.

The resulting limitation is an inference from these interfaces and the observed data contract: when center and edge touches coexist, a processed event offers no decomposition of their contributions. Timing-based suppression could block center input or another pointing device. Passing the event through cannot guarantee edge rejection. Both outcomes fail the user's requirement, so no active suppression is implemented. Every assessment reports `safeToSuppress: false` and every captured event would report `suppressed: false`.

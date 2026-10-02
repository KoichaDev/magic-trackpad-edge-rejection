import AppKit
import MultitouchAdapter
import EdgeModel

let arguments = Array(CommandLine.arguments.dropFirst())

func probe(_ args: [String]) throws {
    guard args.count >= 2, let seconds = Double(args[1]), seconds.isFinite, seconds > 0, seconds <= 60 else {
        throw PrototypeError.message("--probe requires a duration from 0.1 to 60 seconds")
    }
    var id: UInt64?
    var output: URL?
    var contactsOnly = false
    var rejectEdges = false
    var rawBytes = false
    var index = 2
    while index < args.count {
        switch args[index] {
        case "--device":
            guard index + 1 < args.count, let parsed = UInt64(args[index + 1]) else { throw PrototypeError.message("Invalid --device ID") }
            id = parsed; index += 2
        case "--output":
            guard index + 1 < args.count else { throw PrototypeError.message("Missing --output path") }
            output = URL(fileURLWithPath: args[index + 1]); index += 2
        case "--contacts-only": contactsOnly = true; index += 1
        case "--reject-edges": rejectEdges = true; index += 1
        case "--raw-bytes": rawBytes = true; index += 1
        default: throw PrototypeError.message("Unknown probe option: \(args[index])")
        }
    }
    let eligible = try enumerateDevices().filter(\.eligible)
    let selected: DeviceInfo
    if let id, let match = eligible.first(where: { $0.id == id }) { selected = match }
    else if id == nil && eligible.count == 1 { selected = eligible[0] }
    else { throw PrototypeError.message("Select an eligible device with --device; see --devices") }
    let session = ObservationSession()
    if rawBytes {
        // Zero margins make the filter admit every contact, so this records
        // the original bytes without changing what the system sees.
        rejectEdges = true
        session.store.setMargins(Margins(left: 0, right: 0, top: 0, bottom: 0))
        te_raw_capture_enable(true)
    }
    defer { if rawBytes { te_raw_capture_enable(false) } }
    try session.start(device: selected, observeEvents: !contactsOnly, rejectEdges: rejectEdges)
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline && session.running {
        RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.05)))
        session.checkHealth()
    }
    if session.running { session.stop(reason: "Probe complete; ordinary input restored") }
    let capture = session.store.capture(device: selected, status: session.status)
    if rawBytes {
        let records = readRawCapture()
        try writeJSON(RawProbeOutput(capture: capture, rawRecordCount: records.count,
            byteSummary: summarize(records), rawContacts: records), to: output)
    } else {
        try writeJSON(capture, to: output)
    }
}

do {
    if arguments.isEmpty {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    } else if arguments == ["--devices"] {
        try writeJSON(enumerateDevices())
    } else if arguments.first == "--probe" {
        try probe(arguments)
    } else if arguments == ["--diagnostics"] {
        try writeJSON([
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "contactABISize": String(te_contact_abi_size()),
            "inputMonitoring": String(CGPreflightListenEventAccess()),
            "mode": "observation or experimental native raw rejection",
            "rejection": "--reject-edges; macOS 15.x / Bluetooth family 129 only; app sessions run until stopped"
        ])
    } else if arguments == ["--help"] {
        print("""
        TrackpadEdges                    Open the palm rejection window (runs until stopped)
        TrackpadEdges --devices          List multitouch devices (no input changes)
        TrackpadEdges --diagnostics      Print environment and permission status
        TrackpadEdges --probe SECONDS [--device ID] [--contacts-only] [--reject-edges] [--raw-bytes] [--output PATH]
        --raw-bytes records the original 9-byte contact records (zero margins, nothing is rejected).
        Rejection removes raw edge contacts before Apple's recognizer. Probes stop within 60 seconds.
        """)
    } else { throw PrototypeError.message("Unknown option; use --help") }
} catch {
    FileHandle.standardError.write(Data("TrackpadEdges: \(error)\n".utf8))
    exit(1)
}

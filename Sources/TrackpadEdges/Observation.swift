import AppKit
import Carbon
import EdgeModel
import MultitouchAdapter

struct DeviceInfo: Codable, Identifiable {
    let id: UInt64
    let family: Int32
    let builtIn: Bool
    let eligible: Bool
    let product: String
    let transport: String
}

func enumerateDevices() throws -> [DeviceInfo] {
    var raw = [TEDevice](repeating: TEDevice(), count: 64)
    let count = te_list_devices(&raw, Int32(raw.count))
    guard count >= 0 else { throw PrototypeError.message(String(cString: te_last_error())) }
    guard count <= raw.count else { throw PrototypeError.message("Too many multitouch devices; refusing truncated selection") }
    return raw.prefix(Int(count)).map { device in
        var product = device.product, transport = device.transport
        let productText = withUnsafePointer(to: &product) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
        }
        let transportText = withUnsafePointer(to: &transport) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
        }
        return DeviceInfo(id: device.id, family: device.family, builtIn: device.built_in,
                          eligible: device.eligible, product: productText, transport: transportText)
    }
}

enum PrototypeError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case let .message(text): return text } }
}

struct FrameSnapshot: Codable {
    let sequence: UInt64
    let receivedUptime: Double
    let frameworkTimestamp: Double
    let frame: Int32
    let valid: Bool
    let contacts: [Contact]
}

struct EventSample: Encodable {
    let receivedUptime: Double
    let eventTimestampNanoseconds: UInt64
    let kind: String
    let deltaX: Double
    let deltaY: Double
    let subtype: Int64
    let sourcePID: Int64
    let sourceState: Int64
    let scrollPhase: Int64
    let momentumPhase: Int64
    let nearestFrameSequence: UInt64?
    let frameAgeSeconds: Double?
    let assessment: ShadowAssessment
    // Device and touch are deliberately not inferred from PID, subtype, or timing.
    let origin: String = "unattributed"
    let suppressed: Bool = false
}

struct GestureSample: Encodable {
    let receivedUptime: Double
    let kind: String
    let value: Double
    let phase: UInt
    let scope: String = "prototype-window-only"
}

struct Capture: Encodable {
    let formatVersion: Int
    let createdAt: String
    let os: String
    let mode: String
    let selectedDevice: DeviceInfo?
    let margins: Margins
    let framesReceived: UInt64
    let invalidFrames: UInt64
    let eventsReceived: UInt64
    let framesOmittedFromRing: UInt64
    let eventsOmittedFromRing: UInt64
    let frames: [FrameSnapshot]
    let events: [EventSample]
    let localGestures: [GestureSample]
    let finalStatus: String
    let nativeFilter: FilterSummary
}

struct FilterSummary: Encodable {
    let packets: UInt64
    let removedContactSamples: UInt64
    let reentries: UInt64
    let blockedClicks: UInt64
    let error: Int32
    init() {
        let s = te_filter_stats()
        packets = s.packets; removedContactSamples = s.removed_contacts
        reentries = s.reentries; blockedClicks = s.blocked_clicks; error = s.error
    }
}

// Callback work is bounded. Both rings use O(1) insertion. UI/JSON work happens
// outside callbacks. No callback writes to disk, posts input, or changes a touch.
struct Ring<Element> {
    private var storage: [Element] = []
    private var next = 0
    let capacity: Int
    init(capacity: Int) { precondition(capacity > 0); self.capacity = capacity }
    mutating func append(_ element: Element) {
        if storage.count < capacity { storage.append(element) }
        else { storage[next] = element; next = (next + 1) % capacity }
    }
    var values: [Element] {
        guard storage.count == capacity else { return storage }
        return Array(storage[next...]) + Array(storage[..<next])
    }
}

final class ObservationStore {
    private let lock = NSLock()
    private var frameRing = Ring<FrameSnapshot>(capacity: 4096)
    private var eventRing = Ring<EventSample>(capacity: 4096)
    private var gestureRing = Ring<GestureSample>(capacity: 256)
    private var latest: FrameSnapshot?
    private var frameCount: UInt64 = 0
    private var eventCount: UInt64 = 0
    private var invalidCount: UInt64 = 0
    private var margins = Margins()
    var rejectionMode = false
    var currentMargins: Margins { lock.lock(); defer { lock.unlock() }; return margins }
    func setMargins(_ value: Margins) {
        lock.lock(); margins = value; lock.unlock()
        te_set_margins(value.left, value.right, value.top, value.bottom)
    }
    func resetSession() {
        lock.lock(); defer { lock.unlock() }
        frameRing = Ring(capacity: 4096); eventRing = Ring(capacity: 4096)
        gestureRing = Ring(capacity: 256)
        latest = nil; frameCount = 0; eventCount = 0; invalidCount = 0
    }
    func localGesture(_ event: NSEvent) {
        let kind: String
        let value: Double
        switch event.type {
        case .magnify: kind = "magnify"; value = event.magnification
        case .rotate: kind = "rotate"; value = Double(event.rotation)
        case .swipe: kind = "swipe"; value = Double(event.deltaX)
        case .beginGesture: kind = "beginGesture"; value = 0
        default: kind = "endGesture"; value = 0
        }
        lock.lock(); defer { lock.unlock() }
        gestureRing.append(GestureSample(receivedUptime: ProcessInfo.processInfo.systemUptime,
            kind: kind, value: value, phase: event.phase.rawValue))
    }
    func receive(_ raw: UnsafePointer<TEContact>?, count: Int32, timestamp: Double, frame: Int32) {
        let now = ProcessInfo.processInfo.systemUptime
        var contacts: [Contact] = []
        if count > 0, let raw {
            contacts = UnsafeBufferPointer(start: raw, count: Int(count)).map {
                Contact(id: $0.id, state: $0.state, x: Double($0.x), y: Double($0.y))
            }
        }
        lock.lock(); defer { lock.unlock() }
        frameCount += 1
        let valid = count >= 0 && composition(contacts, margins: margins, fresh: true) != .invalid
        if !valid { invalidCount += 1 }
        let snapshot = FrameSnapshot(sequence: frameCount, receivedUptime: now,
            frameworkTimestamp: timestamp, frame: frame, valid: valid, contacts: contacts)
        latest = snapshot
        frameRing.append(snapshot)
    }
    func event(type: CGEventType, event: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        let age = latest.map { now - $0.receivedUptime }
        let fresh = age.map { $0 >= 0 && $0 <= 0.15 } ?? false
        let kind = eventName(type)
        let category = latest?.valid == false ? ContactComposition.invalid
            : composition(latest?.contacts ?? [], margins: margins, fresh: fresh)
        let scroll = type == .scrollWheel
        let sample = EventSample(receivedUptime: now, eventTimestampNanoseconds: event.timestamp,
            kind: kind,
            deltaX: event.getDoubleValueField(scroll ? .scrollWheelEventPointDeltaAxis2 : .mouseEventDeltaX),
            deltaY: event.getDoubleValueField(scroll ? .scrollWheelEventPointDeltaAxis1 : .mouseEventDeltaY),
            subtype: event.getIntegerValueField(.mouseEventSubtype),
            sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
            sourceState: event.getIntegerValueField(.eventSourceStateID),
            scrollPhase: scroll ? event.getIntegerValueField(.scrollWheelEventScrollPhase) : 0,
            momentumPhase: scroll ? event.getIntegerValueField(.scrollWheelEventMomentumPhase) : 0,
            nearestFrameSequence: latest?.sequence, frameAgeSeconds: age,
            assessment: ShadowAssessment(composition: category))
        eventRing.append(sample); eventCount += 1
    }
    func snapshot() -> (FrameSnapshot?, [EventSample], UInt64, UInt64, UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (latest, Array(eventRing.values.suffix(14)), frameCount, eventCount, invalidCount)
    }
    func clearLatest() { lock.lock(); latest = nil; lock.unlock() }
    func capture(device: DeviceInfo?, status: String) -> Capture {
        let filter = FilterSummary() // Acquire adapter lock before store lock.
        lock.lock(); defer { lock.unlock() }
        return Capture(formatVersion: 2, createdAt: ISO8601DateFormatter().string(from: Date()),
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            mode: rejectionMode ? "experimental-native-raw-rejection" : "observation-only",
            selectedDevice: device, margins: margins, framesReceived: frameCount,
            invalidFrames: invalidCount, eventsReceived: eventCount,
            framesOmittedFromRing: frameCount > 4096 ? frameCount - 4096 : 0,
            eventsOmittedFromRing: eventCount > 4096 ? eventCount - 4096 : 0,
            frames: frameRing.values, events: eventRing.values, localGestures: gestureRing.values,
            finalStatus: status, nativeFilter: filter)
    }
}

func eventName(_ type: CGEventType) -> String {
    switch type {
    case .mouseMoved: return "move"
    case .leftMouseDown: return "left-down"
    case .leftMouseUp: return "left-up"
    case .rightMouseDown: return "right-down"
    case .rightMouseUp: return "right-up"
    case .otherMouseDown: return "other-down"
    case .otherMouseUp: return "other-up"
    case .leftMouseDragged: return "left-drag"
    case .rightMouseDragged: return "right-drag"
    case .otherMouseDragged: return "other-drag"
    case .scrollWheel: return "scroll"
    default: return "event-\(type.rawValue)"
    }
}

private let frameCallback: TEFrameCallback = { raw, count, timestamp, frame, context in
    guard let context else { return }
    Unmanaged<ObservationStore>.fromOpaque(context).takeUnretainedValue()
        .receive(raw, count: count, timestamp: timestamp, frame: frame)
}

final class ObservationSession {
    let store = ObservationStore()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var running = false
    private(set) var device: DeviceInfo?
    private(set) var status = "Disabled"
    var onStop: ((String) -> Void)?

    func start(device selected: DeviceInfo, observeEvents: Bool = true, rejectEdges: Bool = false) throws {
        stop(reason: "Starting")
        store.resetSession()
        device = selected
        guard selected.eligible else { throw PrototypeError.message("Only a verified Bluetooth Magic Trackpad is eligible") }
        if observeEvents && !CGPreflightListenEventAccess() {
            throw PrototypeError.message("Input Monitoring permission is missing. Grant it, then start again.")
        }
        store.rejectionMode = rejectEdges
        let margins = store.currentMargins
        let context = Unmanaged.passUnretained(store).toOpaque()
        let started = rejectEdges
            ? te_start_rejection(selected.id, frameCallback, context, margins.left, margins.right, margins.top, margins.bottom)
            : te_start(selected.id, frameCallback, context)
        guard started else {
            throw PrototypeError.message(String(cString: te_last_error()))
        }
        if observeEvents {
            let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged,
                .rightMouseDragged, .otherMouseDragged, .scrollWheel]
            let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            let callback: CGEventTapCallBack = { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let session = Unmanaged<ObservationSession>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    session.stop(reason: "Event tap disabled; explicit restart required")
                } else { session.store.event(type: type, event: event) }
                return Unmanaged.passUnretained(event) // Always passes every event.
            }
            guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                options: .listenOnly, eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()),
                let createdSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
                te_stop()
                throw PrototypeError.message("Cannot create passive event tap")
            }
            tap = created; source = createdSource
            CFRunLoopAddSource(CFRunLoopGetMain(), createdSource, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
        }
        running = true
        status = rejectEdges ? "Palm rejection active · runs until stopped"
            : observeEvents ? "Observing contacts and events" : "Observing contacts only"
    }
    func checkHealth() {
        guard running else { return }
        if store.rejectionMode && te_filter_stats().error != 0 {
            stop(reason: "Native filter validation/reinjection failed; ordinary input restored")
        } else if store.snapshot().4 > 0 { stop(reason: "Invalid private-API contact frame; stopped") }
        else if !te_is_alive() { stop(reason: "Trackpad disconnected; explicit restart required") }
        else if tap != nil && !CGPreflightListenEventAccess() { stop(reason: "Input Monitoring permission lost") }
        else if let tap, !CGEvent.tapIsEnabled(tap: tap) { stop(reason: "Event tap disabled; explicit restart required") }
    }
    func stop(reason: String = "Disabled") {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        te_stop()
        running = false; status = reason
        store.clearLatest()
        onStop?(reason)
    }
    deinit { stop() }
}

final class DisableHotKey {
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    var onDisable: () -> Void
    init(onDisable: @escaping () -> Void) { self.onDisable = onDisable }
    func register() -> OSStatus {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<DisableHotKey>.fromOpaque(context).takeUnretainedValue().onDisable()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { return result }
        let keyID = EventHotKeyID(signature: 0x45444745, id: 1) // EDGE
        return RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(cmdKey | optionKey | controlKey),
            keyID, GetApplicationEventTarget(), 0, &hotKey)
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

func writeJSON<T: Encodable>(_ value: T, to url: URL? = nil) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    if let url { try data.write(to: url, options: .atomic) }
    else { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8)) }
}

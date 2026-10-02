import Foundation
import MultitouchAdapter

/// One undecoded contact record from an original V7 packet. Used only by
/// `--probe --raw-bytes` to find which bytes separate a fingertip from a palm.
struct RawContactRecord: Encodable {
    let packet: UInt64
    let header: String
    let contact: String
    let bytes: [UInt8]
}

struct ByteStatistics: Encodable {
    let index: Int
    let min: UInt8
    let max: UInt8
    let distinctValues: Int
}

struct RawProbeOutput: Encodable {
    let note = "Contact bytes 0-3 hold x, y and state, byte 8 holds the id in its low nibble. Compare bytes 4-7 and the high bits of byte 8 between tips and palms."
    let capture: Capture
    let rawRecordCount: Int
    let byteSummary: [ByteStatistics]
    let rawContacts: [RawContactRecord]
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

func readRawCapture() -> [RawContactRecord] {
    var buffer = [TERawRecord](repeating: TERawRecord(), count: Int(TE_RAW_CAPTURE_CAPACITY))
    let count = buffer.withUnsafeMutableBufferPointer { te_raw_capture_read($0.baseAddress, $0.count) }
    return buffer.prefix(count).map { record in
        let header = withUnsafeBytes(of: record.header) { Array($0) }
        let contact = withUnsafeBytes(of: record.contact) { Array($0) }
        return RawContactRecord(packet: record.packet, header: hex(header), contact: hex(contact), bytes: contact)
    }
}

func summarize(_ records: [RawContactRecord]) -> [ByteStatistics] {
    (0..<9).compactMap { index in
        let values = records.map { $0.bytes[index] }
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return ByteStatistics(index: index, min: lo, max: hi, distinctValues: Set(values).count)
    }
}

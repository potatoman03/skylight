import Foundation

/// Reads a LevelDB database from its files, without opening it, so the browser that owns it can
/// keep running. Newest write wins and deleted keys stay gone. A file cut short by a write in
/// progress gives what it has.
enum LevelDB {
    /// The live entries whose key passes `wanted`. Nothing else is held on to.
    static func entries(tables: [Data], logs: [Data], where wanted: ([UInt8]) -> Bool) -> [[UInt8]: [UInt8]] {
        var latest: [[UInt8]: (sequence: UInt64, value: [UInt8]?)] = [:]
        func record(_ key: [UInt8], _ sequence: UInt64, _ value: [UInt8]?) {
            guard wanted(key), (latest[key]?.sequence ?? 0) <= sequence else { return }
            latest[key] = (sequence, value)
        }
        for table in tables { read(table: [UInt8](table), into: record) }
        for log in logs { read(log: [UInt8](log), into: record) }
        return latest.compactMapValues(\.value)
    }

    private typealias Record = ([UInt8], UInt64, [UInt8]?) -> Void

    // MARK: - Tables

    private static func read(table bytes: [UInt8], into record: Record) {
        guard bytes.count >= 48 else { return }
        var footer = Cursor(bytes, from: bytes.count - 48)
        guard footer.block() != nil, let index = footer.block() else { return }
        for (_, handle) in entries(ofBlock: index, in: bytes) {
            var cursor = Cursor(handle)
            guard let block = cursor.block() else { continue }
            for (key, value) in entries(ofBlock: block, in: bytes) where key.count >= 8 {
                // The last eight bytes are the sequence number, then 0 for deleted or 1 for set.
                let tag = key.suffix(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                record(Array(key.dropLast(8)), tag >> 8, tag & 0xFF == 1 ? value : nil)
            }
        }
    }

    private static func entries(ofBlock handle: Range<Int>, in bytes: [UInt8]) -> [(key: [UInt8], value: [UInt8])] {
        // Each block is followed by a byte saying how it's compressed, and a checksum.
        guard handle.upperBound < bytes.count else { return [] }
        let block: [UInt8]
        switch bytes[handle.upperBound] {
        case 0: block = Array(bytes[handle])
        case 1:
            guard let plain = snappy(bytes[handle]) else { return [] }
            block = plain
        default: return []
        }
        guard block.count >= 4 else { return [] }
        let restarts = Int(block.suffix(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard restarts <= (block.count - 4) / 4 else { return [] }
        var cursor = Cursor(block, to: block.count - 4 - restarts * 4)
        var found: [(key: [UInt8], value: [UInt8])] = []
        var key: [UInt8] = []
        while !cursor.isAtEnd {
            guard let shared = cursor.length(), let added = cursor.length(), let size = cursor.length(),
                  shared <= key.count, let more = cursor.take(added), let value = cursor.take(size) else { break }
            key = Array(key.prefix(shared)) + more
            found.append((key, Array(value)))
        }
        return found
    }

    /// Snappy's raw format: a length, then literal runs and copies of what came before.
    static func snappy(_ input: ArraySlice<UInt8>) -> [UInt8]? {
        var cursor = Cursor(Array(input))
        guard let size = cursor.length(), size <= 64 << 20 else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(size)
        while !cursor.isAtEnd {
            guard let tag = cursor.take(1)?.first else { return nil }
            var length: Int
            var offset = 0
            switch tag & 3 {
            case 0:
                length = Int(tag >> 2)
                if length >= 60 {
                    guard let extra = cursor.take(length - 59) else { return nil }
                    length = extra.reversed().reduce(0) { $0 << 8 | Int($1) }
                }
                guard let run = cursor.take(length + 1) else { return nil }
                output += run
                length = 0
            case 1:
                guard let low = cursor.take(1)?.first else { return nil }
                length = 4 + Int(tag >> 2 & 7)
                offset = Int(tag >> 5) << 8 | Int(low)
            default:
                guard let raw = cursor.take(tag & 3 == 2 ? 2 : 4) else { return nil }
                length = Int(tag >> 2) + 1
                offset = raw.reversed().reduce(0) { $0 << 8 | Int($1) }
            }
            if length > 0 {
                guard offset > 0, offset <= output.count, output.count + length <= size else { return nil }
                for _ in 0..<length { output.append(output[output.count - offset]) }
            }
            guard output.count <= size else { return nil }
        }
        return output
    }

    // MARK: - Logs

    private static func read(log bytes: [UInt8], into record: Record) {
        let blockSize = 32768
        var at = 0
        var pending: [UInt8] = []
        while at < bytes.count {
            let left = blockSize - at % blockSize
            if left < 7 { at += left; continue }
            guard at + 7 <= bytes.count else { return }
            let size = Int(bytes[at + 4]) | Int(bytes[at + 5]) << 8
            let kind = bytes[at + 6]
            guard at + 7 + size <= bytes.count else { return }
            let body = bytes[(at + 7)..<(at + 7 + size)]
            at += 7 + size
            switch kind {
            case 1: read(batch: Array(body), into: record)
            case 2: pending = Array(body)
            case 3: pending += body
            case 4:
                pending += body
                read(batch: pending, into: record)
                pending = []
            default: break
            }
        }
    }

    private static func read(batch bytes: [UInt8], into record: Record) {
        guard bytes.count >= 12 else { return }
        var sequence = bytes[0..<8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let count = bytes[8..<12].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var cursor = Cursor(bytes, from: 12)
        for _ in 0..<count {
            guard let kind = cursor.take(1)?.first, let size = cursor.length(), let key = cursor.take(size) else { return }
            var value: [UInt8]?
            if kind == 1 {
                guard let size = cursor.length(), let body = cursor.take(size) else { return }
                value = Array(body)
            }
            record(Array(key), sequence, value)
            sequence &+= 1
        }
    }

    // MARK: - Bytes

    /// Walks bytes that may be cut short: running out gives nil.
    struct Cursor {
        let bytes: [UInt8]
        var at: Int
        let end: Int

        init(_ bytes: [UInt8], from at: Int = 0, to end: Int? = nil) {
            self.bytes = bytes
            self.at = at
            self.end = min(end ?? bytes.count, bytes.count)
        }

        var isAtEnd: Bool { at >= end }

        mutating func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while at < end, shift < 64 {
                let byte = bytes[at]
                at += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
            return nil
        }

        mutating func length() -> Int? { varint().flatMap { Int(exactly: $0) } }

        mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, count <= end - at else { return nil }
            defer { at += count }
            return bytes[at..<(at + count)]
        }

        /// A block's place in a table: where it starts, and how long it is.
        mutating func block() -> Range<Int>? {
            guard let start = length(), let size = length(), size <= Int.max - start else { return nil }
            return start..<(start + size)
        }
    }
}

import Foundation

public indirect enum BValue: Sendable, Equatable {
    case bytes(Data), int(Int64), list([BValue]), dict([String: BValue])

    public static func string(_ value: String) -> BValue { .bytes(Data(value.utf8)) }
    public var data: Data? { if case let .bytes(value) = self { return value }; return nil }
    public var integer: Int64? { if case let .int(value) = self { return value }; return nil }
    public var dictionary: [String: BValue]? { if case let .dict(value) = self { return value }; return nil }
    public var string: String? { data.flatMap { String(data: $0, encoding: .utf8) } }

    public func encoded() -> Data {
        switch self {
        case let .bytes(value): return Data("\(value.count):".utf8) + value
        case let .int(value): return Data("i\(value)e".utf8)
        case let .list(values): return Data([108]) + values.reduce(Data()) { $0 + $1.encoded() } + Data([101])
        case let .dict(values):
            return Data([100]) + values.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }.reduce(Data()) {
                $0 + BValue.string($1).encoded() + values[$1]!.encoded()
            } + Data([101])
        }
    }

    public static func decode(_ data: Data, strict: Bool = true) throws -> BValue {
        guard data.count <= 65_536 else { throw PeerError.invalid("DHT packet too large") }
        var reader = Reader(bytes: Array(data), strict: strict)
        let value = try reader.read(depth: 0)
        guard reader.position == data.count else { throw PeerError.invalid("Trailing bencode data") }
        return value
    }

    private struct Reader {
        let bytes: [UInt8]
        let strict: Bool
        var position = 0

        mutating func read(depth: Int) throws -> BValue {
            guard depth < 20, position < bytes.count else { throw PeerError.invalid("Truncated bencode") }
            let marker = bytes[position]; position += 1
            if marker == 105 {
                let text = try token(until: 101)
                guard let value = Int64(text), String(value) == text else { throw PeerError.invalid("Invalid bencode integer") }
                return .int(value)
            }
            if marker == 108 || marker == 100 {
                var list: [BValue] = []; var dict: [String: BValue] = [:]; var previous: Data?
                while position < bytes.count, bytes[position] != 101 {
                    let value = try read(depth: depth + 1)
                    if marker == 108 { list.append(value) }
                    else {
                        guard let keyData = value.data, let key = String(data: keyData, encoding: .utf8), dict[key] == nil,
                              !strict || previous == nil || previous!.lexicographicallyPrecedes(keyData) else { throw PeerError.invalid("Invalid dictionary key") }
                        previous = keyData
                        dict[key] = try read(depth: depth + 1)
                    }
                }
                guard position < bytes.count else { throw PeerError.invalid("Truncated collection") }
                position += 1
                return marker == 108 ? .list(list) : .dict(dict)
            }
            guard (48...57).contains(marker) else { throw PeerError.invalid("Unknown bencode token") }
            position -= 1
            let lengthText = try token(until: 58)
            guard let length = Int(lengthText), length >= 0, String(length) == lengthText,
                  length <= bytes.count - position else { throw PeerError.invalid("Invalid byte string") }
            let data = Data(bytes[position..<(position + length)]); position += length
            return .bytes(data)
        }

        mutating func token(until delimiter: UInt8) throws -> String {
            let start = position
            while position < bytes.count, bytes[position] != delimiter { position += 1 }
            guard position < bytes.count, position - start <= 24 else { throw PeerError.invalid("Invalid token") }
            let text = String(decoding: bytes[start..<position], as: UTF8.self)
            position += 1
            return text
        }
    }
}

public enum PeerError: LocalizedError, Sendable {
    case invalid(String), unavailable(String)
    public var errorDescription: String? {
        switch self { case .invalid(let text), .unavailable(let text): return text }
    }
}

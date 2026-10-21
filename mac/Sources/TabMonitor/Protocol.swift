import Foundation

/// El protocolo de PROTOCOL.md: encabezado de 5 bytes (tipo, largo big-endian) y contenido.
enum Wire {
    enum Kind: UInt8 {
        case video = 0x01
        case hello = 0x10
        case config = 0x11
        case key = 0x12
        case ping = 0x13
        case pong = 0x14
        case stats = 0x15
    }

    static let headerSize = 5
    static let maxPayload = 16 * 1024 * 1024

    static func header(_ kind: Kind, length: Int) -> [UInt8] {
        let n = UInt32(length)
        return [kind.rawValue, UInt8(n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]
    }

    static func message(_ kind: Kind, _ payload: Data = Data()) -> Data {
        Data(header(kind, length: payload.count)) + payload
    }

    /// Frame de video: flags, hora de captura en µs (u64 BE) y NAL en Annex B.
    static func video(keyframe: Bool, captureMicros: UInt64, annexB: Data) -> Data {
        var out = Data(capacity: headerSize + 9 + annexB.count)
        out.append(contentsOf: header(.video, length: 9 + annexB.count))
        out.append(keyframe ? 1 : 0)
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: captureMicros >> UInt64(shift)))
        }
        out.append(annexB)
        return out
    }

    // El JSON de la Mac se arma a mano para que salga en el orden de PROTOCOL.md
    // (JSONEncoder no garantiza el orden de las claves).

    static func config(codec: String, w: Int, h: Int, fps: Int, bitrate: Int) -> Data {
        message(.config, Data(#"{"codec":"\#(codec)","w":\#(w),"h":\#(h),"fps":\#(fps),"bitrate":\#(bitrate)}"#.utf8))
    }

    static func pong(ts: Int64, mac: Int64) -> Data {
        message(.pong, Data(#"{"ts":\#(ts),"mac":\#(mac)}"#.utf8))
    }

    struct Hello: Decodable {
        struct MaxDecode: Decodable { let w: Int; let h: Int; let fps: Int }
        let w: Int
        let h: Int
        let model: String?
        let android: String?
        let maxDecode: MaxDecode?
    }

    struct Ping: Decodable { let ts: Int64 }

    struct Stats: Decodable {
        struct Latency: Decodable { let avg: Double; let p95: Double }
        let fps: Double?
        let latencyMs: Latency?
        let decodeMs: Double?
        let dropped: Int?
    }

    enum Incoming {
        case hello(Hello)
        case key
        case ping(Ping)
        case stats(Stats)
    }

    enum Failure: Error, CustomStringConvertible {
        case tooLarge(Int)
        case badJSON(Kind, String)

        var description: String {
            switch self {
            case .tooLarge(let n): return "mensaje de \(n) bytes, más que el máximo de 16 MiB"
            case .badJSON(let k, let why): return "JSON inválido en \(k): \(why)"
            }
        }
    }

    /// Arma mensajes a partir de bytes que llegan en pedazos de cualquier tamaño.
    /// Los tipos desconocidos (y los que la Mac manda, no recibe) se saltean.
    struct Parser {
        private var buffer = Data()

        mutating func feed(_ bytes: Data) throws -> [Incoming] {
            buffer.append(bytes)
            var out: [Incoming] = []
            while buffer.count >= Wire.headerSize {
                let b = buffer.startIndex
                let length = Int(buffer[b + 1]) << 24 | Int(buffer[b + 2]) << 16
                    | Int(buffer[b + 3]) << 8 | Int(buffer[b + 4])
                guard length <= Wire.maxPayload else { throw Failure.tooLarge(length) }
                guard buffer.count >= Wire.headerSize + length else { break }
                let type = buffer[b]
                let payload = buffer.subdata(in: (b + Wire.headerSize)..<(b + Wire.headerSize + length))
                buffer.removeSubrange(b..<(b + Wire.headerSize + length))
                if let msg = try Self.decode(type, payload) { out.append(msg) }
            }
            return out
        }

        private static func decode(_ type: UInt8, _ payload: Data) throws -> Incoming? {
            guard let kind = Kind(rawValue: type) else { return nil }
            do {
                switch kind {
                case .hello: return .hello(try JSONDecoder().decode(Hello.self, from: payload))
                case .key: return .key
                case .ping: return .ping(try JSONDecoder().decode(Ping.self, from: payload))
                case .stats: return .stats(try JSONDecoder().decode(Stats.self, from: payload))
                case .video, .config, .pong: return nil
                }
            } catch {
                throw Failure.badJSON(kind, "\(error)")
            }
        }
    }
}

/// El reloj monotónico de la Mac (mach_absolute_time), el mismo que usa ScreenCaptureKit
/// para la hora de cada frame.
enum MacClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func micros(fromMachTime t: UInt64) -> UInt64 {
        t * UInt64(timebase.numer) / UInt64(timebase.denom) / 1000
    }

    static func nowMicros() -> UInt64 { micros(fromMachTime: mach_absolute_time()) }
    static func nowMillis() -> Int64 { Int64(nowMicros() / 1000) }
}

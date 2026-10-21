import Foundation
import os

/// Servidor TCP en 127.0.0.1, una tablet a la vez (PROTOCOL.md).
///
/// Video sin cola: si el frame anterior todavía se está escribiendo, el nuevo se descarta y se
/// pide un keyframe; hasta que llegue, los frames que dependen del descartado tampoco se mandan.
/// TCP_NODELAY y SO_SNDBUF chico para que el kernel no acumule frames viejos.
final class Server {
    /// Se llaman en una cola interna.
    var onHello: ((Wire.Hello) -> Void)?
    var onKeyRequest: (() -> Void)?
    var onStats: ((Wire.Stats) -> Void)?
    var onDisconnect: (() -> Void)?
    /// Un frame descartado; el encoder tiene que mandar un keyframe.
    var onDrop: (() -> Void)?
    /// Un frame terminó de escribirse: bytes y µs que tardó.
    var onSent: ((Int, UInt64) -> Void)?

    let port: UInt16
    static let sendBufferBytes: Int32 = 128 * 1024

    private var listenFD: Int32 = -1
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var client: Connection?
        var sending = false
        var waitingForKeyframe = false
    }

    /// Un socket aceptado. Solo el lector lo cierra, y a través de la cola de envío, para que
    /// ninguna escritura pendiente use un descriptor ya reutilizado.
    private final class Connection {
        let fd: Int32
        let sendQueue = DispatchQueue(label: "tabmonitor.send", qos: .userInteractive)
        init(fd: Int32) { self.fd = fd }
    }

    init(port: UInt16) { self.port = port }

    enum Failure: Error, CustomStringConvertible {
        case socket(String, Int32)

        var description: String {
            switch self {
            case .socket(let call, let err): return "\(call) falló: \(String(cString: strerror(err)))"
            }
        }
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket("socket", errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { let e = errno; close(fd); throw Failure.socket("bind 127.0.0.1:\(port)", e) }
        guard listen(fd, 1) == 0 else { let e = errno; close(fd); throw Failure.socket("listen", e) }
        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "tabmonitor.accept"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    var isConnected: Bool { state.withLock { $0.client != nil } }

    /// Manda un frame si el anterior ya salió; si no, lo descarta. Devuelve si lo mandó.
    @discardableResult
    func sendVideo(_ frame: Encoder.Frame) -> Bool {
        enum Decision { case send(Connection), drop, skip }
        let decision: Decision = state.withLock { s in
            guard let client = s.client else { return .skip }
            if s.waitingForKeyframe && !frame.keyframe { return .skip }
            if s.sending {
                s.waitingForKeyframe = true
                return .drop
            }
            s.sending = true
            s.waitingForKeyframe = false
            return .send(client)
        }
        switch decision {
        case .skip:
            return false
        case .drop:
            onDrop?()
            return false
        case .send(let client):
            let data = Wire.video(keyframe: frame.keyframe, captureMicros: frame.captureMicros, annexB: frame.annexB)
            client.sendQueue.async { [weak self] in
                let started = MacClock.nowMicros()
                let ok = Self.writeAll(client.fd, data)
                self?.state.withLock { $0.sending = false }
                if ok { self?.onSent?(data.count, MacClock.nowMicros() - started) } else { shutdown(client.fd, SHUT_RDWR) }
            }
            return true
        }
    }

    /// Mensajes de control: van siempre, en orden, detrás del frame que se esté escribiendo.
    func sendControl(_ data: Data) {
        guard let client = state.withLock({ $0.client }) else { return }
        client.sendQueue.async {
            if !Self.writeAll(client.fd, data) { shutdown(client.fd, SHUT_RDWR) }
        }
    }

    private func acceptLoop(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                logger.error("accept falló: \(String(cString: strerror(errno)), privacy: .public)")
                return
            }
            var yes: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var sndbuf = Self.sendBufferBytes
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, socklen_t(MemoryLayout<Int32>.size))

            let connection = Connection(fd: fd)
            let accepted = state.withLock { s -> Bool in
                guard s.client == nil else { return false }
                s = State(client: connection)
                return true
            }
            guard accepted else {
                logger.notice("segunda conexión rechazada: ya hay una tablet")
                close(fd)
                continue
            }
            logger.notice("tablet conectada")
            let reader = Thread { [weak self] in self?.readLoop(connection) }
            reader.name = "tabmonitor.read"
            reader.qualityOfService = .userInteractive
            reader.start()
        }
    }

    private func readLoop(_ connection: Connection) {
        var parser = Wire.Parser()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        loop: while true {
            let n = buffer.withUnsafeMutableBytes { recv(connection.fd, $0.baseAddress, $0.count, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            do {
                for message in try parser.feed(Data(buffer[0..<n])) {
                    switch message {
                    case .hello(let hello): onHello?(hello)
                    case .key: onKeyRequest?()
                    case .ping(let ping): sendControl(Wire.pong(ts: ping.ts, mac: MacClock.nowMillis()))
                    case .stats(let stats): onStats?(stats)
                    }
                }
            } catch {
                logger.error("protocolo: \(String(describing: error), privacy: .public); se cierra la conexión")
                break loop
            }
        }
        shutdown(connection.fd, SHUT_RDWR)
        connection.sendQueue.async { close(connection.fd) }
        state.withLock { s in if s.client === connection { s = State() } }
        logger.notice("tablet desconectada")
        onDisconnect?()
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }
}

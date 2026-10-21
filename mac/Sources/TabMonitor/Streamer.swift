import CoreGraphics
import Foundation
import os

/// Captura el monitor virtual, lo codifica y lo manda por el servidor. Uno por conexión.
final class Streamer {
    static let fps = 60
    static let bitrate = 35_000_000

    private let capture = Capture()
    private let encoder: Encoder
    private let server: Server
    private let stats = StreamStats()
    private var timer: DispatchSourceTimer?

    init(width: Int, height: Int, server: Server) throws {
        self.server = server
        encoder = try Encoder(width: width, height: height, fps: Self.fps, bitrate: Self.bitrate)
    }

    func start(displayID: CGDirectDisplayID) async throws {
        let encoder = encoder, server = server, stats = stats
        capture.onFrame = { pixels, pts, micros in
            let now = MacClock.nowMicros()
            stats.captured(delayMicros: now > micros ? now - micros : 0)
            encoder.encode(pixels, pts: pts, captureMicros: micros)
        }
        capture.onStopped = { error in
            logger.error("la captura se detuvo: \(String(describing: error), privacy: .public)")
        }
        encoder.onSkip = { stats.skipped() }
        encoder.onFrame = { frame in
            // Captura + codificación: de la hora del frame a que sale del encoder. La hora del frame
            // es el vsync en que se muestra (displayTime) y puede quedar apenas en el futuro.
            let now = MacClock.nowMicros()
            stats.encoded(totalMicros: now > frame.captureMicros ? now - frame.captureMicros : 0,
                          encodeMicros: frame.encodeMicros,
                          keyframe: frame.keyframe)
            server.sendVideo(frame)
        }
        server.onDrop = { [weak encoder] in
            stats.dropped()
            encoder?.requestKeyframe()
        }
        server.onSent = { bytes, micros in stats.sent(bytes: bytes, micros: micros) }

        server.sendControl(Wire.config(codec: "h264", w: encoder.width, h: encoder.height,
                                       fps: Self.fps, bitrate: Self.bitrate))
        try await capture.start(displayID: displayID, width: encoder.width, height: encoder.height, fps: Self.fps)

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { stats.logAndReset(seconds: 2) }
        timer.resume()
        self.timer = timer
        logger.notice("transmitiendo \(encoder.width)×\(encoder.height) a \(Self.fps) fps, \(Self.bitrate / 1_000_000) Mbps")
    }

    func requestKeyframe() { encoder.requestKeyframe() }

    func stop() {
        timer?.cancel()
        timer = nil
        capture.stop()
        encoder.invalidate()
        server.onDrop = nil
        server.onSent = nil
    }
}

/// Contadores de los últimos segundos, para los logs y docs/latency.md.
final class StreamStats {
    private struct Window {
        var captured = 0
        var skipped = 0
        var captureMicros: [UInt64] = []
        var keyframes = 0
        var dropped = 0
        var bytes = 0
        var totalMicros: [UInt64] = []
        var encodeMicros: [UInt64] = []
        var sendMicros: [UInt64] = []
    }

    private let window = OSAllocatedUnfairLock(initialState: Window())

    func captured(delayMicros: UInt64) {
        window.withLock {
            $0.captured += 1
            $0.captureMicros.append(delayMicros)
        }
    }
    func skipped() { window.withLock { $0.skipped += 1 } }
    func dropped() { window.withLock { $0.dropped += 1 } }

    func encoded(totalMicros: UInt64, encodeMicros: UInt64, keyframe: Bool) {
        window.withLock {
            $0.totalMicros.append(totalMicros)
            $0.encodeMicros.append(encodeMicros)
            if keyframe { $0.keyframes += 1 }
        }
    }

    func sent(bytes: Int, micros: UInt64) {
        window.withLock {
            $0.bytes += bytes
            $0.sendMicros.append(micros)
        }
    }

    func logAndReset(seconds: Double) {
        let w = window.withLock { w -> Window in defer { w = Window() }; return w }
        guard w.captured > 0 || !w.sendMicros.isEmpty else { return }
        func ms(_ values: [UInt64]) -> String {
            guard !values.isEmpty else { return "—" }
            let sorted = values.sorted()
            let avg = Double(sorted.reduce(0, +)) / Double(sorted.count) / 1000
            let p95 = Double(sorted[min(sorted.count - 1, sorted.count * 95 / 100)]) / 1000
            return String(format: "%.1f/%.1f", avg, p95)
        }
        let line = String(format: "capturados %.1f fps, enviados %.1f fps, %.1f Mbps", Double(w.captured) / seconds,
                          Double(w.sendMicros.count) / seconds, Double(w.bytes) * 8 / seconds / 1_000_000)
            + ", llegada de la captura \(ms(w.captureMicros)) ms"
            + ", captura+codificación \(ms(w.totalMicros)) ms, encoder \(ms(w.encodeMicros)) ms"
            + ", envío \(ms(w.sendMicros)) ms (prom/p95), keyframes \(w.keyframes), salteados antes del encoder \(w.skipped), descartados al enviar \(w.dropped)"
        logger.notice("stats: \(line, privacy: .public)")
    }
}

import CoreMedia
import CoreVideo
import Foundation

/// El clip con el que el visor elige su decoder (android/app/src/main/assets/calibration.bin).
///
/// Sale del mismo Encoder que la transmisión, así el visor prueba cada decoder con un SPS igual
/// al real (1 referencia, sin reordenamiento, High 5.1): de eso depende cuántos frames retiene.
/// Son mensajes de video de PROTOCOL.md uno detrás del otro; el primero es keyframe.
///
/// Se regenera cuando cambia la configuración del encoder:
///   .build/debug/TabMonitor --calibration-clip ../android/app/src/main/assets/calibration.bin
enum CalibrationClip {
    static let width = 1280
    static let height = 800
    static let frames = 20

    static func write(to url: URL) throws {
        let encoder = try Encoder(width: width, height: height, fps: 60, bitrate: DisplayPlan.maxBitrate)
        let done = DispatchSemaphore(value: 0)
        var out = Data()
        encoder.onFrame = { frame in
            out.append(Wire.video(keyframe: frame.keyframe, captureMicros: frame.captureMicros, annexB: frame.annexB))
            done.signal()
        }
        for i in 0..<frames {
            let pixels = try frame(i)
            let micros = UInt64(i) * 1_000_000 / 60
            // De a uno: el Encoder descarta un frame si llega otro mientras trabaja.
            encoder.encode(pixels, pts: CMTime(value: CMTimeValue(i), timescale: 60), captureMicros: micros)
            guard done.wait(timeout: .now() + 2) == .success else { throw Failure.timeout(i) }
        }
        encoder.invalidate()
        try out.write(to: url)
        print("\(url.path): \(frames) frames de \(width)×\(height), \(out.count) bytes")
    }

    enum Failure: Error { case pixelBuffer(CVReturn), timeout(Int) }

    /// Un degradé con una barra que se mueve, para que cada frame P tenga algo que codificar.
    private static func frame(_ i: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw Failure.pixelBuffer(status) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let bar = (i * 48) % width
        for y in 0..<height {
            let row = luma + y * lumaStride
            for x in 0..<width {
                row[x] = abs(x - bar) < 40 ? 235 : UInt8(16 + (x + y + i * 4) % 200)
            }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<height / 2 {
            memset(chroma + y * chromaStride, 128, width)
        }
        return buffer
    }
}

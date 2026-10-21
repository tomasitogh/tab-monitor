import CoreMedia
import ScreenCaptureKit

/// Captura el monitor virtual con ScreenCaptureKit, a su tamaño en píxeles.
///
/// Cada frame se entrega apenas llega y el Encoder se queda solo con el más nuevo; el que no se
/// pudo enviar lo descarta el servidor. ScreenCaptureKit solo entrega frames cuando cambia algo.
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Un frame completo: imagen y hora de captura en el reloj de la Mac (µs).
    var onFrame: ((CVPixelBuffer, CMTime, UInt64) -> Void)?
    var onStopped: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "tabmonitor.capture", qos: .userInteractive)

    enum Failure: Error, CustomStringConvertible {
        case displayNotFound(CGDirectDisplayID)

        var description: String {
            switch self {
            case .displayNotFound(let id): return "ScreenCaptureKit no ve el monitor \(id)"
            }
        }
    }

    /// Pide el permiso de Grabación de pantalla la primera vez. ScreenCaptureKit tarda un momento
    /// en ver un monitor recién creado, así que se reintenta durante un par de segundos.
    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        var display: SCDisplay?
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            display = content.displays.first { $0.displayID == displayID }
            if display != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let display else { throw Failure.displayNotFound(displayID) }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange   // lo que come el encoder
        // queueDepth es el pool de superficies, no una cola: el encoder retiene hasta dos (la que
        // codifica y la que espera). Medido en el M1 a pantalla completa: con 3 o 6 el pool se
        // agota y los frames llegan 10–26 ms tarde; con 8 (el máximo), 0,3 ms.
        config.queueDepth = 8
        config.showsCursor = true
        config.capturesAudio = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                          as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sample.imageBuffer else { return }
        let machTime = (info[.displayTime] as? UInt64) ?? mach_absolute_time()
        onFrame?(pixels, sample.presentationTimeStamp, MacClock.micros(fromMachTime: machTime))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }
}

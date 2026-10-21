import CoreMedia
import VideoToolbox
import os

/// H.264 con VideoToolbox según las reglas de latencia de CLAUDE.md: High 5.1, sin B-frames,
/// tiempo real, bitrate fijo y keyframe solo al empezar o cuando se pide.
///
/// Último frame gana también acá: un solo frame en el encoder y una ranura con el más nuevo.
/// Si llega otro mientras el encoder trabaja, reemplaza al que esperaba (que no se codificó, así
/// que nada depende de él). Sin esto `VTCompressionSessionEncodeFrame` bloquea la cola de captura
/// y ScreenCaptureKit acumula frames viejos: medido en el M1, 30–50 ms en vez de ~20.
final class Encoder {
    struct Frame {
        let keyframe: Bool
        let captureMicros: UInt64
        /// Unidades NAL en Annex B; los keyframes llevan SPS y PPS adelante.
        let annexB: Data
        /// Cuánto tardó el encoder, en µs.
        let encodeMicros: UInt64
    }

    var onFrame: ((Frame) -> Void)?
    /// Un frame capturado que no llegó a codificarse porque llegó uno más nuevo.
    var onSkip: (() -> Void)?

    let width: Int
    let height: Int
    private var session: VTCompressionSession?
    private let forceKey = OSAllocatedUnfairLock(initialState: true)   // el primero es keyframe

    private struct Pending {
        let pixels: CVPixelBuffer
        let pts: CMTime
        let captureMicros: UInt64
    }
    private struct Slot {
        var inFlight = false
        var next: Pending?
    }
    private let slot = OSAllocatedUnfairLock(initialState: Slot())
    /// Los frames se mandan al encoder desde acá, nunca desde la captura ni desde el callback.
    private let submitQueue = DispatchQueue(label: "tabmonitor.encode", qos: .userInteractive)

    enum Failure: Error, CustomStringConvertible {
        case create(OSStatus)

        var description: String {
            switch self {
            case .create(let s): return "VTCompressionSessionCreate falló: \(s)"
            }
        }
    }

    init(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        self.width = width
        self.height = height
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
                    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw Failure.create(status) }
        self.session = session

        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_5_1),
            (kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber),
            // Sin keyframes periódicos: solo al empezar o bajo pedido.
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, Int32.max as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 0 as CFNumber),
            (kVTCompressionPropertyKey_ReferenceBufferCount, 1 as CFNumber),
            (kVTCompressionPropertyKey_EnableLTR, kCFBooleanFalse),
            // MaxFrameDelayCount y PrioritizeEncodingSpeedOverQuality no van: con
            // EnableLowLatencyRateControl el encoder del M1 las rechaza (-12900) porque ya
            // entrega cada frame sin demora.
        ]
        for (key, value) in properties {
            let s = VTSessionSetProperty(session, key: key, value: value)
            if s != noErr { logger.error("VideoToolbox rechazó \(key as String, privacy: .public): \(s)") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { invalidate() }

    func invalidate() {
        guard let session else { return }
        self.session = nil
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    /// El próximo frame sale como keyframe.
    func requestKeyframe() {
        forceKey.withLock { $0 = true }
    }

    func encode(_ pixels: CVPixelBuffer, pts: CMTime, captureMicros: UInt64) {
        let frame = Pending(pixels: pixels, pts: pts, captureMicros: captureMicros)
        let (submit, replaced) = slot.withLock { s -> (Bool, Bool) in
            guard s.inFlight else { s.inFlight = true; return (true, false) }
            let replaced = s.next != nil
            s.next = frame
            return (false, replaced)
        }
        if replaced { onSkip?() }
        // Nunca desde la cola de captura: VTCompressionSessionEncodeFrame puede bloquear lo que
        // dura la codificación, y entonces ScreenCaptureKit acumula frames (medido: 120 ms de
        // atraso a 60 fps con el encoder en 19 ms).
        if submit { submitQueue.async { self.submitToEncoder(frame) } }
    }

    /// Termina un frame y, si espera uno más nuevo, lo manda.
    private func finished() {
        let next = slot.withLock { s -> Pending? in
            guard let n = s.next else { s.inFlight = false; return nil }
            s.next = nil
            return n
        }
        if let next { submitQueue.async { self.submitToEncoder(next) } }
    }

    private func submitToEncoder(_ frame: Pending) {
        guard let session else { return slot.withLock { $0 = Slot() } }
        let pixels = frame.pixels, pts = frame.pts, captureMicros = frame.captureMicros
        let key = forceKey.withLock { k -> Bool in defer { k = false }; return k }
        let options = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let started = MacClock.nowMicros()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: options,
                                        infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self else { return }
            defer { self.finished() }
            guard status == noErr, let sample, let annexB = Self.annexB(sample) else {
                if status != noErr { logger.error("encode falló: \(status)") }
                self.requestKeyframe()
                return
            }
            self.onFrame?(Frame(keyframe: Self.isKeyframe(sample), captureMicros: captureMicros,
                                annexB: annexB, encodeMicros: MacClock.nowMicros() - started))
        }
        if status != noErr {   // el callback no va a llegar
            logger.error("no se pudo encolar el frame: \(status)")
            requestKeyframe()
            finished()
        }
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    /// AVCC (largo de 4 bytes antes de cada NAL) a Annex B; SPS y PPS adelante en los keyframes.
    private static func annexB(_ sample: CMSampleBuffer) -> Data? {
        guard let block = sample.dataBuffer else { return nil }
        var out = Data()
        if isKeyframe(sample), let format = sample.formatDescription {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr else { return nil }
                out.append(contentsOf: startCode)
                out.append(ptr, count: size)
            }
        }

        var total = 0
        var base: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total,
                                          dataPointerOut: &base) == noErr, let base else { return nil }
        // VideoToolbox entrega un bloque contiguo para H.264; si no lo fuera, el puntero cubre menos
        // que `total` y se copia antes.
        var contiguous: Data?
        var length = 0
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: nil)
        if length < total {
            var copy = Data(count: total)
            let ok = copy.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!) == noErr
            }
            guard ok else { return nil }
            contiguous = copy
        }

        func appendNALs(_ bytes: UnsafeRawBufferPointer) -> Bool {
            var offset = 0
            while offset + 4 <= bytes.count {
                let n = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                offset += 4
                guard offset + n <= bytes.count else { return false }
                out.append(contentsOf: startCode)
                out.append(contentsOf: bytes[offset..<(offset + n)])
                offset += n
            }
            return true
        }
        let ok: Bool
        if let contiguous {
            ok = contiguous.withUnsafeBytes(appendNALs)
        } else {
            ok = appendNALs(UnsafeRawBufferPointer(start: base, count: total))
        }
        return ok ? out : nil
    }
}

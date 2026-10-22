import Foundation

/// Qué monitor crear y qué transmitir para una tablet, a partir de su `hello`.
///
/// El monitor tiene siempre la proporción de la pantalla de la tablet (sin bandas negras) y
/// prefiere un múltiplo exacto de sus píxeles: así no se reescala y se ve lo más nítido posible.
/// Con 1800 px de ancho o más, 2× da entre ~900 y ~1500 pt, razonable en cualquier tablet de 9" a
/// 14". En pantallas más chicas se usa el tamaño físico para elegir entre 1× y reescalar.
///
/// El `dpi` que informa Android no es confiable: la P11 Pro dice 320 (el escalón de densidad) y
/// tiene 262. Por eso solo decide en pantallas chicas, donde equivocarse cuesta menos.
struct DisplayPlan: Equatable {
    /// El menú Tamaño.
    enum Size: String, CaseIterable {
        /// Texto grande: el modo exacto (2× o 1×) si da un tamaño razonable.
        case larger
        /// 25 % más de puntos, dibujado a 2× y achicado a la pantalla de la tablet.
        case moreSpace
    }

    /// Cuántos píxeles viajan. Medido en la P11 Pro a 60 fps (docs/latency.md): Nítida (2560×1600)
    /// 45–47 ms de promedio, Rápida (1920×1200) 25–29 ms, porque el encoder del M1 y el decoder de
    /// la tablet tardan en proporción a los píxeles.
    enum Quality: String, CaseIterable {
        /// La resolución de la tablet, o lo más grande que su decoder decodifique a 60 fps.
        case sharp
        /// El 75 % de Nítida; la tablet lo estira.
        case fast
    }

    let widthPt: Int
    let heightPt: Int
    let scale: Int
    let streamWidth: Int
    let streamHeight: Int
    let bitrate: Int
    /// Número de serie del monitor: uno por tablet, para que macOS recuerde dónde va cada una.
    let serial: UInt32

    var pixelWidth: Int { widthPt * scale }
    var pixelHeight: Int { heightPt * scale }

    /// Bitrate de la P11 Pro (CLAUDE.md); en otras tablets, el mismo salvo que el decoder acepte menos.
    static let maxBitrate = 35_000_000
    /// Desde este ancho en píxeles, siempre 2× exacto.
    static let twoXMinWidth = 1800
    /// Puntos por pulgada de ancho que se aceptan para 1× en pantallas chicas.
    static let exactRange = 100.0...145.0
    /// Puntos por pulgada de ancho cuando ningún modo exacto entra en el rango.
    static let targetDensity = 120.0

    /// La P11 Pro, para crear el monitor desde el menú sin tablet y para un `hello` sin `dpi`.
    static let p11Pro = Wire.Hello(w: 2560, h: 1600, dpi: 262.5, model: "TB-J706F", android: nil, id: nil,
                                   decoder: nil, maxDecode: nil)

    init(hello: Wire.Hello, size: Size, quality: Quality) {
        let w = max(hello.w, hello.h), h = min(hello.w, hello.h)

        // Tamaño en puntos con texto grande.
        var basePt: (w: Int, h: Int)
        var baseScale: Int
        if w >= Self.twoXMinWidth {
            (basePt, baseScale) = ((w / 2, h / 2), 2)
        } else if let dpi = hello.dpi, (80.0...800.0).contains(dpi) {
            let inches = Double(w) / dpi
            if Self.exactRange.contains(Double(w) / inches) {
                (basePt, baseScale) = ((w, h), 1)
            } else {
                basePt = Self.even(Self.targetDensity * inches, w: w, h: h)
                baseScale = 2
            }
        } else {
            (basePt, baseScale) = ((w, h), 1)
        }

        switch size {
        case .larger:
            widthPt = basePt.w; heightPt = basePt.h; scale = baseScale
        case .moreSpace:
            let pt = Self.even(Double(basePt.w) * 1.25, w: w, h: h)
            widthPt = pt.w; heightPt = pt.h; scale = 2
        }

        // Lo transmitido: nunca más que la pantalla, ni que lo que el decoder hace a 60 fps.
        var sw = w
        if let w60 = hello.maxDecode?.w60, w60 > 0 { sw = min(sw, w60) }
        sw = min(sw, widthPt * scale)
        if quality == .fast { sw = sw * 3 / 4 }
        let stream = Self.even(Double(sw), w: w, h: h, roundDown: true)
        streamWidth = stream.w
        streamHeight = stream.h

        if let limit = hello.maxDecode?.bitrate, limit > 0 {
            bitrate = min(Self.maxBitrate, limit)
        } else {
            bitrate = Self.maxBitrate
        }
        serial = hello.id.map(Self.serial(for:)) ?? 1
    }

    /// Un ancho y su alto con la proporción de w×h, los dos pares.
    private static func even(_ width: Double, w: Int, h: Int, roundDown: Bool = false) -> (w: Int, h: Int) {
        let ew = roundDown ? Int(width) / 2 * 2 : Int((width / 2).rounded()) * 2
        let eh = Int((Double(ew) * Double(h) / Double(w) / 2).rounded()) * 2
        return (ew, eh)
    }

    /// FNV-1a de 32 bits del id de la tablet; nunca 0 (macOS lo trata como "sin número de serie").
    static func serial(for id: String) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash == 0 ? 1 : hash
    }
}

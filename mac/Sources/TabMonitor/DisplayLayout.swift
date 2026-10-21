import CoreGraphics
import Foundation

/// Ubica el monitor virtual junto a los monitores reales, sin volverlo principal.
///
/// Mismo uso de `CGConfigureDisplayOrigin` que Sill-Viewer (DesktopFit.swift): solo se mueve el
/// origen del monitor virtual; el principal sigue en (0, 0) y conserva la barra de menú y el Dock.
enum DisplayLayout {
    enum Side {
        case right, left
    }

    /// Saca a `displayID` de cualquier espejo y lo pone al lado de los monitores reales.
    ///
    /// Si "Duplicar pantallas" quedó activo (por ejemplo, de un monitor externo), macOS mete al
    /// monitor nuevo en el mismo grupo espejo: la MacBook pasa a mostrar 1280×800 y el cursor no
    /// sale de ella. Medido en macOS 15.3 en el M1. Primero se rompe el espejo y se espera a que
    /// macOS lo aplique; recién entonces `place` puede mover el origen.
    static func extend(_ displayID: CGDirectDisplayID, side: Side = .right) async -> Bool {
        if isMirrored(displayID) {
            guard unmirror(displayID) else { return false }
            let deadline = Date().addingTimeInterval(2)
            while isMirrored(displayID), Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if isMirrored(displayID) { return false }
        }
        return place(displayID, side: side)
    }

    /// Pone `displayID` pegado al borde exterior de los demás monitores activos, del lado pedido,
    /// alineado arriba con el principal. Devuelve false si macOS rechazó la configuración.
    ///
    /// Si macOS eligió al monitor virtual como principal, la principal vuelve a ser la real:
    /// se fija en (0, 0), que es lo que define la principal.
    @discardableResult
    static func place(_ displayID: CGDirectDisplayID, side: Side = .right) -> Bool {
        guard displayID != 0 else { return false }
        let others = activeDisplays().filter { $0 != displayID }
        let main = CGMainDisplayID() != displayID ? CGMainDisplayID() : others.first
        guard let main else { return false }

        let mainBounds = CGDisplayBounds(main)
        // Coordenadas relativas a la principal, que va a quedar en (0, 0).
        let otherBounds = others.map { CGDisplayBounds($0).offsetBy(dx: -mainBounds.minX, dy: -mainBounds.minY) }
        let x: CGFloat
        switch side {
        case .right:
            x = otherBounds.map(\.maxX).max() ?? mainBounds.width
        case .left:
            x = (otherBounds.map(\.minX).min() ?? 0) - CGDisplayBounds(displayID).width
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        if mainBounds.origin != .zero {
            for (id, b) in zip(others, otherBounds) {
                CGConfigureDisplayOrigin(config, id, Int32(b.minX), Int32(b.minY))
            }
        }
        guard CGConfigureDisplayOrigin(config, displayID, Int32(x), 0) == .success else {
            _ = CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    /// True si `displayID` espeja a otro o algún monitor en línea lo espeja a él.
    static func isMirrored(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay
            || onlineDisplays().contains { $0 != displayID && CGDisplayMirrorsDisplay($0) == displayID }
    }

    /// Saca del espejo a `displayID` y a los monitores que lo espejan. Los demás espejos del
    /// usuario (por ejemplo, la MacBook duplicando un externo) no se tocan.
    private static func unmirror(_ displayID: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        let mirroring = onlineDisplays().filter { $0 != displayID && CGDisplayMirrorsDisplay($0) == displayID }
        for id in [displayID] + mirroring {
            CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    /// Una línea por monitor en línea, para los logs.
    static func describe() -> String {
        onlineDisplays().map { id in
            let b = CGDisplayBounds(id)
            var s = "\(id): \(Int(b.width))×\(Int(b.height)) en (\(Int(b.minX)), \(Int(b.minY)))"
            if CGDisplayIsMain(id) != 0 { s += " principal" }
            if CGDisplayIsBuiltin(id) != 0 { s += " interno" }
            let master = CGDisplayMirrorsDisplay(id)
            if master != kCGNullDirectDisplay { s += " espeja a \(master)" }
            return s
        }.joined(separator: "; ")
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        displayList(CGGetActiveDisplayList)
    }

    /// Incluye los que espejan por hardware, que no cuentan como activos.
    static func onlineDisplays() -> [CGDirectDisplayID] {
        displayList(CGGetOnlineDisplayList)
    }

    private static func displayList(
        _ get: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    ) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard get(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard get(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}

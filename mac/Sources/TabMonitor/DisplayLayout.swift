import CoreGraphics

/// Ubica el monitor virtual junto a los monitores reales, sin volverlo principal.
///
/// Mismo uso de `CGConfigureDisplayOrigin` que Sill-Viewer (DesktopFit.swift): solo se mueve el
/// origen del monitor virtual; el principal sigue en (0, 0) y conserva la barra de menú y el Dock.
enum DisplayLayout {
    enum Side {
        case right, left
    }

    /// Pone `displayID` pegado al borde exterior de los demás monitores activos, del lado pedido,
    /// alineado arriba con el principal. Devuelve false si macOS rechazó la configuración.
    @discardableResult
    static func place(_ displayID: CGDirectDisplayID, side: Side = .right) -> Bool {
        let main = CGMainDisplayID()
        guard displayID != 0, displayID != main else { return false }

        let others = activeDisplays().filter { $0 != displayID }.map(CGDisplayBounds)
        let mainBounds = CGDisplayBounds(main)
        let x: CGFloat
        switch side {
        case .right:
            x = others.map(\.maxX).max() ?? mainBounds.maxX
        case .left:
            x = (others.map(\.minX).min() ?? mainBounds.minX) - CGDisplayBounds(displayID).width
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard CGConfigureDisplayOrigin(config, displayID, Int32(x), Int32(mainBounds.minY)) == .success else {
            _ = CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}

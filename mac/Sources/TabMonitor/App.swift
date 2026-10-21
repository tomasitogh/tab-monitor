import AppKit
import os

let logger = Logger(subsystem: "dev.tabmonitor.mac", category: "app")

/// App de barra de menú: crea y destruye el monitor virtual y lo transmite a la tablet.
///
/// Cuando una tablet se conecta y manda `hello`, se crea el monitor (si no estaba), se responde
/// `config` y empieza el video; al desconectarse, el monitor se destruye si lo creó la conexión.
///
/// VirtualDisplay necesita el event loop de AppKit (ver sus comentarios), por eso la app corre
/// con `NSApplication.run()` y política `.accessory`, sin ícono en el Dock.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    /// 1280×800 pt a 2× = 2560×1600 px, la resolución nativa de la tablet.
    private let widthPt = 1280
    private let heightPt = 800
    private let scale = 2
    private let refreshHz = 60.0
    private let productID: UInt32 = 0x0010
    private let port: UInt16 = 8081

    private var statusItem: NSStatusItem!
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let clientItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")

    private var display: VirtualDisplay?
    private var starting = false
    /// Termina cuando el monitor está en su modo y ubicado.
    private var ready: Task<Void, Never>?
    /// El monitor lo creó la conexión de la tablet, no el menú: se destruye al desconectarse.
    private var displayForTablet = false

    private lazy var server = Server(port: port)
    private var streamer: Streamer?
    /// El hello de la tablet conectada, para volver a transmitir si el monitor se reactiva desde el menú.
    private var hello: Wire.Hello?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                           accessibilityDescription: "TabMonitor")

        let menu = NSMenu()
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        clientItem.isEnabled = false
        menu.addItem(clientItem)
        menu.addItem(.separator())
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir de TabMonitor", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
        refreshMenu()

        let problems = VirtualDisplay.checkPrivateAPI()
        if !problems.isEmpty {
            logger.error("CGVirtualDisplay no disponible: \(problems.joined(separator: "; "), privacy: .public)")
        }

        server.onHello = { [weak self] hello in Task { @MainActor in await self?.startStreaming(hello) } }
        server.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.hello = nil
                self?.stopStreaming()
            }
        }
        server.onKeyRequest = { [weak self] in Task { @MainActor in self?.streamer?.requestKeyframe() } }
        server.onStats = { stats in
            logger.notice("tablet: \(stats.fps ?? 0) fps, latencia \(stats.latencyMs?.avg ?? 0)/\(stats.latencyMs?.p95 ?? 0) ms, descartados \(stats.dropped ?? 0)")
        }
        do {
            try server.start()
            logger.notice("escuchando en 127.0.0.1:\(self.port)")
        } catch {
            showError("No se pudo abrir el puerto \(port).", detail: "\(error)")
        }

        // Para diagnosticar sin tocar el menú: open TabMonitor.app --args --activate
        if CommandLine.arguments.contains("--activate") { activate() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        deactivate()
    }

    @objc private func toggle() {
        if display != nil {
            deactivate()
        } else if let hello, server.isConnected {
            Task { await startStreaming(hello) }
        } else {
            activate()
        }
    }

    private func activate() {
        let problems = VirtualDisplay.checkPrivateAPI()
        guard problems.isEmpty else {
            showError("Esta versión de macOS no ofrece la API de monitores virtuales que usa TabMonitor.",
                      detail: problems.joined(separator: "\n"))
            return
        }
        let created: VirtualDisplay
        do {
            created = try VirtualDisplay(name: "TabMonitor", widthPt: widthPt, heightPt: heightPt,
                                         scale: scale, refreshHz: refreshHz, productID: productID)
        } catch {
            showError("No se pudo crear el monitor virtual.", detail: "\(error)")
            return
        }
        created.onTerminated = { [weak self, weak created] in
            Task { @MainActor in
                guard let self, let created, self.display === created else { return }
                logger.notice("macOS cerró el monitor virtual")
                self.deactivate()
            }
        }
        display = created
        starting = true
        refreshMenu()
        logger.notice("monitor creado, displayID \(created.displayID)")

        ready = Task { @MainActor in
            let online = await created.waitUntilOnline()
            guard self.display === created else { return }
            if !online {
                logger.error("el monitor no tomó el modo pedido; modos: \(created.availableModes().joined(separator: ", "), privacy: .public)")
            }
            logger.notice("pantallas al crear: \(DisplayLayout.describe(), privacy: .public)")
            if !(await DisplayLayout.extend(created.displayID, side: .right)) {
                logger.error("no se pudo ubicar el monitor a la derecha")
            }
            guard self.display === created else { return }
            logger.notice("pantallas al ubicar: \(DisplayLayout.describe(), privacy: .public)")
            self.starting = false
            self.refreshMenu()
            let b = created.bounds, px = created.pixelSize
            logger.notice("monitor listo: \(Int(b.width))×\(Int(b.height)) pt en (\(Int(b.minX)), \(Int(b.minY))), \(px.width)×\(px.height) px")
        }
    }

    private func startStreaming(_ hello: Wire.Hello) async {
        logger.notice("hello: \(hello.w)×\(hello.h) px, \(hello.model ?? "?", privacy: .public), Android \(hello.android ?? "?", privacy: .public)")
        if hello.w != widthPt * scale || hello.h != heightPt * scale {
            logger.notice("la tablet pidió \(hello.w)×\(hello.h); por ahora el monitor es siempre \(self.widthPt * self.scale)×\(self.heightPt * self.scale)")
        }
        self.hello = hello
        stopStream()
        if display == nil {
            activate()
            displayForTablet = display != nil
        }
        guard let display, let ready else { return }
        await ready.value
        guard self.display === display, server.isConnected, streamer == nil else { return }

        let px = display.pixelSize
        do {
            let created = try Streamer(width: px.width, height: px.height, server: server)
            streamer = created
            refreshMenu()
            try await created.start(displayID: display.displayID)
        } catch {
            stopStream()
            refreshMenu()
            logger.error("no se pudo transmitir: \(String(describing: error), privacy: .public)")
            if (error as NSError).domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
                showError("TabMonitor necesita permiso de Grabación de pantalla.",
                          detail: "Activalo en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y volvé a conectar.\n\n\(error)")
            }
        }
    }

    /// Fin de la conexión: corta el video y quita el monitor si lo había creado la tablet.
    private func stopStreaming() {
        stopStream()
        if displayForTablet { deactivate() }
        refreshMenu()
    }

    private func stopStream() {
        streamer?.stop()
        streamer = nil
    }

    private func deactivate() {
        stopStream()
        guard let display else { return }
        display.destroy()
        self.display = nil
        ready = nil
        displayForTablet = false
        starting = false
        refreshMenu()
        logger.notice("monitor destruido")
    }

    private func refreshMenu() {
        if let display {
            if starting {
                stateItem.title = "Monitor: encendiendo…"
            } else {
                let px = display.pixelSize
                stateItem.title = "Monitor: \(widthPt)×\(heightPt) pt (\(px.width)×\(px.height) px)"
            }
            toggleItem.title = "Desactivar monitor"
        } else {
            stateItem.title = "Monitor: apagado"
            toggleItem.title = "Activar monitor"
        }
        clientItem.title = streamer != nil ? "Tablet: transmitiendo" : "Tablet: esperando conexión"
    }

    private func showError(_ message: String, detail: String) {
        logger.error("\(message, privacy: .public) \(detail, privacy: .public)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}

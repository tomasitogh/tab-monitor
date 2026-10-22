import AppKit
import ServiceManagement
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
        if let i = CommandLine.arguments.firstIndex(of: "--calibration-clip"), i + 1 < CommandLine.arguments.count {
            do { try CalibrationClip.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) } catch {
                print("no se pudo escribir el clip: \(error)")
                exit(1)
            }
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private let refreshHz = 60.0
    private let productID: UInt32 = 0x0010
    private let port: UInt16 = 8081

    typealias Quality = DisplayPlan.Quality
    typealias Size = DisplayPlan.Size

    private var quality: Quality {
        get { UserDefaults.standard.string(forKey: "quality").flatMap(Quality.init) ?? .sharp }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "quality") }
    }

    private var size: Size {
        get { UserDefaults.standard.string(forKey: "size").flatMap(Size.init) ?? .larger }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "size") }
    }

    /// Monitor y transmisión para la tablet conectada; sin tablet, para la P11 Pro.
    private func plan(size: Size? = nil, quality: Quality? = nil) -> DisplayPlan {
        DisplayPlan(hello: hello ?? DisplayPlan.p11Pro, size: size ?? self.size, quality: quality ?? self.quality)
    }

    private var statusItem: NSStatusItem!
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let clientItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
    private lazy var qualityItems: [Quality: NSMenuItem] = Dictionary(uniqueKeysWithValues: Quality.allCases.map { q in
        let item = NSMenuItem(title: "", action: #selector(chooseQuality(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = q.rawValue
        item.indentationLevel = 1
        return (q, item)
    })
    private lazy var sizeItems: [Size: NSMenuItem] = Dictionary(uniqueKeysWithValues: Size.allCases.map { s in
        let item = NSMenuItem(title: "", action: #selector(chooseSize(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = s.rawValue
        item.indentationLevel = 1
        return (s, item)
    })

    private var display: VirtualDisplay?
    private var starting = false
    /// Termina cuando el monitor está en su modo y ubicado.
    private var ready: Task<Void, Never>?
    /// El monitor lo creó la conexión de la tablet, no el menú: se destruye al desconectarse.
    private var displayForTablet = false

    private lazy var server = Server(port: port)
    private lazy var bridge = AdbBridge(port: port)
    private var bridgeState: AdbBridge.State = .waiting
    private let openViewerItem = NSMenuItem(title: "Abrir visor en la tablet", action: #selector(openViewer), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Abrir al iniciar sesión", action: #selector(toggleLogin), keyEquivalent: "")
    private var streamer: Streamer?
    /// El hello de la tablet conectada, para volver a transmitir si el monitor se reactiva desde el menú.
    private var hello: Wire.Hello?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                           accessibilityDescription: "TabMonitor")

        let menu = NSMenu()
        menu.autoenablesItems = false
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        clientItem.isEnabled = false
        menu.addItem(clientItem)
        menu.addItem(.separator())
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        let qualityHeader = NSMenuItem(title: "Calidad", action: nil, keyEquivalent: "")
        qualityHeader.isEnabled = false
        menu.addItem(qualityHeader)
        for q in Quality.allCases { menu.addItem(qualityItems[q]!) }
        let sizeHeader = NSMenuItem(title: "Tamaño", action: nil, keyEquivalent: "")
        sizeHeader.isEnabled = false
        menu.addItem(sizeHeader)
        for s in Size.allCases { menu.addItem(sizeItems[s]!) }
        menu.addItem(.separator())
        openViewerItem.target = self
        menu.addItem(openViewerItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let guideItem = NSMenuItem(title: "Cómo preparar la tablet…", action: #selector(openGuide), keyEquivalent: "")
        guideItem.target = self
        menu.addItem(guideItem)
        let info = Bundle.main.infoDictionary
        let versionItem = NSMenuItem(title: "Versión \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
                                     action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
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

        bridge.onState = { [weak self] state in
            self?.bridgeState = state
            self?.refreshMenu()
        }
        bridge.start()
        let bridge = self.bridge
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { _ in
            logger.notice("la Mac despertó")
            bridge.refresh()
        }

        // Para diagnosticar sin tocar el menú: open TabMonitor.app --args --activate
        if CommandLine.arguments.contains("--activate") { activate() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge.stop()
        deactivate()
    }

    @objc private func openViewer() {
        bridge.openViewer()
    }

    @objc private func openGuide() {
        NSWorkspace.shared.open(URL(string: "https://github.com/tomasitogh/tab-monitor#preparar-la-tablet")!)
    }

    /// SMAppService: la app tiene que estar en /Applications. macOS puede pedir aprobarla en
    /// Ajustes del Sistema › General › Ítems de inicio.
    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showError("No se pudo cambiar el inicio automático.", detail: "\(error)")
        }
        refreshMenu()
    }

    /// Se aplica en caliente: la transmisión vuelve a arrancar con un `config` nuevo.
    @objc private func chooseQuality(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let q = Quality(rawValue: raw), q != quality else { return }
        quality = q
        refreshMenu()
        logger.notice("calidad: \(q.rawValue, privacy: .public)")
        if streamer != nil, let hello, server.isConnected {
            Task { await startStreaming(hello) }
        }
    }

    /// Cambiar el tamaño recrea el monitor; con la tablet conectada, la transmisión vuelve a arrancar.
    @objc private func chooseSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = Size(rawValue: raw), s != size else { return }
        size = s
        logger.notice("tamaño: \(s.rawValue, privacy: .public)")
        if let hello, server.isConnected {
            Task { await startStreaming(hello) }
        } else if display != nil {
            deactivate()
            activate()
        }
        refreshMenu()
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
        let plan = plan()
        let created: VirtualDisplay
        do {
            created = try VirtualDisplay(name: "TabMonitor", widthPt: plan.widthPt, heightPt: plan.heightPt,
                                         scale: plan.scale, refreshHz: refreshHz, productID: productID,
                                         serialNum: plan.serial)
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
        logger.notice("hello: \(hello.w)×\(hello.h) px, \(hello.dpi ?? 0) dpi, \(hello.model ?? "?", privacy: .public), Android \(hello.android ?? "?", privacy: .public), decoder \(hello.decoder ?? "?", privacy: .public)")
        self.hello = hello
        stopStream()
        let plan = plan()
        logger.notice("plan: monitor \(plan.widthPt)×\(plan.heightPt) pt a \(plan.scale)×, transmite \(plan.streamWidth)×\(plan.streamHeight) a \(plan.bitrate / 1_000_000) Mbps, serie \(plan.serial)")
        // Un monitor de otro tamaño u otra tablet (creado desde el menú o antes de cambiar el tamaño) se recrea.
        if let display, display.widthPt != plan.widthPt || display.heightPt != plan.heightPt
            || display.scale != plan.scale || display.serialNum != plan.serial {
            deactivate()
        }
        if display == nil {
            activate()
            displayForTablet = display != nil
        }
        guard let display, let ready else { return }
        await ready.value
        guard self.display === display, server.isConnected, streamer == nil else { return }

        var created: Streamer?
        do {
            created = try Streamer(width: plan.streamWidth, height: plan.streamHeight, bitrate: plan.bitrate, server: server)
            guard let created else { return }
            streamer = created
            refreshMenu()
            try await created.start(displayID: display.displayID)
        } catch {
            logger.error("no se pudo transmitir: \(String(describing: error), privacy: .public)")
            // Solo si sigue siendo el actual: una reconexión rápida pudo haber arrancado otro.
            guard streamer === created else { return }
            stopStream()
            refreshMenu()
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
                stateItem.title = "Monitor: \(display.widthPt)×\(display.heightPt) pt (\(px.width)×\(px.height) px)"
            }
            toggleItem.title = "Desactivar monitor"
        } else {
            stateItem.title = "Monitor: apagado"
            toggleItem.title = "Activar monitor"
        }
        clientItem.title = streamer != nil ? "Tablet: transmitiendo" : Self.describe(bridgeState)
        if case .ready = bridgeState { openViewerItem.isEnabled = streamer == nil } else { openViewerItem.isEnabled = false }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for (q, item) in qualityItems {
            let p = plan(quality: q)
            item.title = "\(q == .sharp ? "Nítida" : "Rápida") (\(p.streamWidth)×\(p.streamHeight))"
            item.state = q == quality ? .on : .off
        }
        for (s, item) in sizeItems {
            let p = plan(size: s)
            item.title = "\(s == .larger ? "Más grande" : "Más espacio") (\(p.widthPt)×\(p.heightPt))"
            item.state = s == size ? .on : .off
        }
    }

    private static func describe(_ state: AdbBridge.State) -> String {
        switch state {
        case .noAdb: return "Falta adb: brew install android-platform-tools"
        case .waiting: return "Tablet: enchufala con la depuración USB activa"
        case .unauthorized: return "Tablet: aceptá \"Permitir depuración USB\" en la tablet"
        case .preparing(let what): return "Tablet: \(what)"
        case .ready: return "Tablet: esperando al visor"
        case .failed(let why): return "Tablet: \(why) (reintentando)"
        }
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

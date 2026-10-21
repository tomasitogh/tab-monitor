import Foundation
import os

/// Enchufar y usar: detecta la tablet por adb y deja el visor andando.
///
/// Escucha `adb track-devices` (adb avisa cada cambio; no se consulta periódicamente). Cuando hay
/// una tablet autorizada: instala o actualiza el visor si el APK cambió, aplica
/// `adb reverse tcp:8081 tcp:8081` y lo abre. Si adb se cae, lo vuelve a levantar.
/// Una tablet a la vez: la primera autorizada.
final class AdbBridge {
    enum State: Equatable {
        /// No se encontró adb.
        case noAdb
        /// adb anda, no hay tablet.
        case waiting
        /// La tablet espera que se acepte "Permitir depuración USB".
        case unauthorized
        /// Instalando, aplicando reverse o abriendo el visor.
        case preparing(String)
        /// El visor fue abierto en esta tablet.
        case ready(serial: String)
        case failed(String)
    }

    /// Siempre en la cola principal.
    var onState: ((State) -> Void)?

    static let package = "dev.tabmonitor"
    static let activity = "dev.tabmonitor/.MainActivity"

    let adbPath: String?
    private let port: UInt16
    private let apk: URL?
    private let apkHash: String?

    private let queue = DispatchQueue(label: "tabmonitor.adb", qos: .utility)
    private var tracker: Process?
    private var stopping = false
    /// La tablet que ya quedó lista; se vuelve a preparar si desaparece y vuelve.
    private var readySerial: String?
    private var state: State = .waiting
    private var lastDevices: [(serial: String, state: String)] = []

    init(port: UInt16, bundle: Bundle = .main) {
        self.port = port
        adbPath = Self.findAdb()
        apk = bundle.url(forResource: "TabMonitor", withExtension: "apk")
        apkHash = bundle.url(forResource: "TabMonitor.apk", withExtension: "sha256")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() {
        guard adbPath != nil else { return set(.noAdb) }
        if apk == nil { logger.notice("adb: la app no trae el APK del visor; no se instala ni actualiza") }
        queue.async { self.track() }
    }

    func stop() {
        queue.sync {
            stopping = true
            tracker?.terminate()
            tracker = nil
        }
    }

    /// Vuelve a abrir el visor en la tablet lista (por ejemplo, si se cerró a mano).
    func openViewer() {
        queue.async {
            guard let serial = self.readySerial else { return }
            self.prepare(serial, force: true)
        }
    }

    /// Vuelve a preparar la tablet enchufada, por ejemplo al despertar la Mac: el visor pudo
    /// haberse cerrado solo mientras la Mac dormía y adb no avisa nada porque la tablet no se fue.
    func refresh(after delay: TimeInterval = 2) {
        queue.asyncAfter(deadline: .now() + delay) {
            guard let device = self.lastDevices.first(where: { $0.state == "device" }) else { return }
            self.readySerial = nil
            self.prepare(device.serial, force: false)
        }
    }

    // MARK: - Seguimiento de dispositivos

    private func track() {
        guard !stopping, let adb = adbPath else { return }
        // Sin capturar la salida: el servidor de adb que arranca hereda la tubería y no la cierra.
        _ = run(["start-server"], timeout: 15, captureOutput: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["track-devices"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.queue.async {
                buffer.append(chunk)
                // Cada aviso: largo en 4 dígitos hexadecimales y "serial\testado" por línea.
                while buffer.count >= 4, let n = Int(String(decoding: buffer.prefix(4), as: UTF8.self), radix: 16),
                      buffer.count >= 4 + n {
                    let text = String(decoding: buffer.dropFirst(4).prefix(n), as: UTF8.self)
                    buffer.removeFirst(4 + n)
                    self.devicesChanged(Self.parseDevices(text))
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 2) {
                guard !self.stopping else { return }
                logger.notice("adb track-devices terminó; se reinicia")
                self.readySerial = nil
                self.track()
            }
        }
        do {
            try process.run()
            tracker = process
        } catch {
            logger.error("adb: no se pudo ejecutar track-devices: \(String(describing: error), privacy: .public)")
            set(.failed("no se pudo ejecutar adb"))
            queue.asyncAfter(deadline: .now() + 5) { self.track() }
        }
    }

    static func parseDevices(_ text: String) -> [(serial: String, state: String)] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t")
            return parts.count >= 2 ? (String(parts[0]), String(parts[1])) : nil
        }
    }

    private func devicesChanged(_ devices: [(serial: String, state: String)]) {
        lastDevices = devices
        if let serial = readySerial, !devices.contains(where: { $0.serial == serial && $0.state == "device" }) {
            logger.notice("adb: la tablet \(serial, privacy: .public) se fue")
            readySerial = nil
        }
        if let device = devices.first(where: { $0.state == "device" }) {
            if readySerial != device.serial { prepare(device.serial, force: false) }
        } else if devices.contains(where: { $0.state == "unauthorized" }) {
            set(.unauthorized)
        } else {
            set(.waiting)
        }
    }

    // MARK: - Preparar la tablet

    /// Instala si hace falta, aplica reverse y abre el visor. En la cola de adb.
    private func prepare(_ serial: String, force: Bool) {
        guard prepareOnce(serial, force: force) else {
            // Reintenta mientras la tablet siga enchufada.
            queue.asyncAfter(deadline: .now() + 5) {
                guard self.readySerial == nil, self.lastDevices.contains(where: { $0.serial == serial && $0.state == "device" }) else { return }
                self.prepare(serial, force: force)
            }
            return
        }
    }

    private func prepareOnce(_ serial: String, force: Bool) -> Bool {
        logger.notice("adb: preparando \(serial, privacy: .public)")
        if let apk, let apkHash, installedHash(serial) != apkHash {
            set(.preparing("instalando el visor…"))
            let r = run(["-s", serial, "install", "-r", apk.path], timeout: 120)
            guard r.ok else {
                logger.error("adb install falló: \(r.output, privacy: .public)")
                set(.failed("no se pudo instalar el visor"))
                return false
            }
            logger.notice("adb: visor instalado")
        }
        set(.preparing("conectando…"))
        let reverse = run(["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"], timeout: 15)
        guard reverse.ok else {
            logger.error("adb reverse falló: \(reverse.output, privacy: .public)")
            set(.failed("no se pudo aplicar adb reverse"))
            return false
        }
        let start = run(["-s", serial, "shell", "am", "start", "-n", Self.activity], timeout: 15)
        guard start.ok, !start.output.contains("Error") else {
            logger.error("no se pudo abrir el visor: \(start.output, privacy: .public)")
            set(.failed("no se pudo abrir el visor"))
            return false
        }
        readySerial = serial
        set(.ready(serial: serial))
        logger.notice("adb: visor abierto en \(serial, privacy: .public)\(force ? " (a pedido)" : "", privacy: .public)")
        return true
    }

    /// SHA-256 del APK instalado, o nil si no está.
    private func installedHash(_ serial: String) -> String? {
        let path = run(["-s", serial, "shell", "pm", "path", Self.package], timeout: 15)
        guard path.ok, let line = path.output.split(separator: "\n").first(where: { $0.hasPrefix("package:") }) else { return nil }
        let file = line.dropFirst("package:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let sum = run(["-s", serial, "shell", "sha256sum", file], timeout: 30)
        return sum.ok ? sum.output.split(separator: " ").first.map(String.init) : nil
    }

    // MARK: - Utilidades

    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        DispatchQueue.main.async { self.onState?(new) }
    }

    /// Corre adb y espera, con tope de tiempo. Solo desde la cola de adb.
    private func run(_ args: [String], timeout: TimeInterval, captureOutput: Bool = true) -> (ok: Bool, output: String) {
        guard let adb = adbPath else { return (false, "sin adb") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = captureOutput ? pipe : FileHandle.nullDevice
        process.standardError = captureOutput ? pipe : FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return (false, "\(error)") }
        // La salida se lee aparte para que el tope de tiempo valga aunque adb se cuelgue.
        var output = Data()
        let read = DispatchSemaphore(value: 0)
        if captureOutput {
            DispatchQueue.global(qos: .utility).async {
                output = pipe.fileHandleForReading.readDataToEndOfFile()
                read.signal()
            }
        } else {
            read.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = read.wait(timeout: .now() + 2)
            return (false, "adb \(args.joined(separator: " ")) no respondió en \(Int(timeout)) s")
        }
        _ = read.wait(timeout: .now() + 2)
        return (process.terminationStatus == 0, String(decoding: output, as: UTF8.self))
    }

    /// adb de Homebrew o del SDK de Android. Las apps abiertas desde el Finder no heredan el PATH
    /// de la terminal, así que se buscan rutas conocidas.
    static func findAdb() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb",
                          "\(home)/Library/Android/sdk/platform-tools/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

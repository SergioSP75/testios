import Foundation

/// Canal de trazas hacia el PC: cada evento importante (lista cargada, relay, reproductor, errores) se manda por HTTP
/// a `<servidor de pruebas>/log` casi en tiempo real. Así se depura sin cable ni Xcode, con la causa exacta de cada fallo.
/// Si el PC no responde se descartan en silencio (nunca estorba al uso normal).
final class Trace: @unchecked Sendable {
    static let shared = Trace()

    private let lock = NSLock()
    private var pending: [[String: String]] = []
    private var recentLines: [String] = []
    private var started = false

    /// Dirección del PC (la misma que usa el modo pruebas).
    var server: String { UserDefaults.standard.string(forKey: "testServer") ?? "http://192.168.0.95:8800" }

    /// Últimas trazas, para enseñarlas dentro de la app.
    var recent: [String] { lock.lock(); defer { lock.unlock() }; return recentLines }

    func log(_ category: String, _ message: String) {
        lock.lock()
        pending.append(["cat": category, "msg": message])
        if pending.count > 500 { pending.removeFirst(pending.count - 500) }     // tope si el PC no contesta
        recentLines.append("[\(category)] \(message)")
        if recentLines.count > 300 { recentLines.removeFirst(recentLines.count - 300) }
        lock.unlock()
        startIfNeeded()
    }

    /// Hilo de envío: cada segundo manda lo acumulado.
    private func startIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        if started { return }
        started = true
        Task.detached(priority: .utility) { [self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await flush()
            }
        }
    }

    private func flush() async {
        lock.lock(); let batch = pending; pending = []; lock.unlock()
        guard !batch.isEmpty, let url = URL(string: server + "/log"),
              let body = try? JSONSerialization.data(withJSONObject: batch) else { return }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "POST"; req.httpBody = body
        do { _ = try await URLSession.shared.data(for: req) }
        catch {
            // No hay PC: se guardan para el siguiente intento (con el tope de arriba)
            lock.lock(); pending = batch + pending; if pending.count > 500 { pending.removeFirst(pending.count - 500) }; lock.unlock()
        }
    }
}

/// Dropbox: los enlaces `dl=0` devuelven una página web; con `dl=1` entregan el fichero (igual que Android).
func directDownloadURL(_ raw: String) -> String {
    raw.lowercased().contains("dropbox.com") ? raw.replacingOccurrences(of: "dl=0", with: "dl=1") : raw
}

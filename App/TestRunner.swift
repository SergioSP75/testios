import Foundation
import AVFoundation
import HLSCore

/// Modo de pruebas automáticas: descarga una lista de casos del PC, reproduce cada uno unos segundos,
/// comprueba que el tiempo avanza y envía el resultado al PC (así se verifica sin mirar la pantalla).
///
/// Formato de `tests.json`: [{"name":…, "url":…, "keys":"{kid:key,…}", "headers":{…}}]
@MainActor
final class TestRunner: ObservableObject {
    @Published var log: [String] = []
    @Published var running = false
    @Published var current: PlayerModel?          // el caso que se está probando (la pantalla lo enseña)

    struct Case: Decodable { let name: String; let url: String; let keys: String?; let headers: [String: String]? }
    struct Result: Encodable { let name: String; let ok: Bool; let seconds: Double; let route: String; let error: String? }

    /// `server` = http://IP-del-PC:8800 (sirve /tests.json y recibe POST /result).
    func run(server: String, secondsPerCase: Double = 12) async {
        running = true; log = []
        defer { running = false }
        guard let listURL = URL(string: server + "/tests.json"),
              let data = try? await URLSessionFetcher().fetch(listURL, headers: [:]),
              let cases = try? JSONDecoder().decode([Case].self, from: data) else {
            log.append("No se pudo leer \(server)/tests.json"); return
        }
        log.append("\(cases.count) casos")
        for c in cases {
            let model = PlayerModel()
            current = model
            guard let url = URL(string: c.url) else { continue }
            let keys = parseClearKeysHexMap(c.keys)
            await model.start(url: url, headers: c.headers ?? [:], clearKeys: keys)
            // Esperar a que avance el tiempo o falle
            var waited = 0.0
            while waited < secondsPerCase && model.errorText == nil {
                try? await Task.sleep(nanoseconds: 500_000_000); waited += 0.5
                if model.lastTime >= 4 && model.videoFrames > 0 { break }          // 4 s con imagen = reproduce
            }
            // OK solo si avanza el tiempo Y llegan fotogramas de vídeo (si solo suena, es FALLO de imagen)
            let hasPicture = model.videoFrames > 0
            let ok = model.errorText == nil && model.lastTime >= 3 && hasPicture
            let size = "\(Int(model.videoSize.width))x\(Int(model.videoSize.height))"
            let info = hasPicture ? "\(model.status) · imagen \(size), \(model.videoFrames) fotogramas" : "\(model.status) · SIN IMAGEN (solo audio)"
            let res = Result(name: c.name, ok: ok, seconds: model.lastTime, route: info, error: model.errorText)
            log.append("\(ok ? "OK " : "FALLO") \(c.name) · \(String(format: "%.1f", model.lastTime)) s · \(model.errorText ?? info)")
            model.stop()
            current = nil
            await post(server: server, res)
        }
        log.append("terminado")
    }

    private func post(server: String, _ r: Result) async {
        guard let url = URL(string: server + "/result"), let body = try? JSONEncoder().encode(r) else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
    }
}

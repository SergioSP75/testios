import Foundation
import HLSCore

/// Descarga con URLSession (cabeceras de la lista incluidas) para el relay.
/// Reintenta ante 403/429/5xx: algunos CDN (p. ej. Movistar VOD) rechazan al azar entre el 10 y el 40 % de las peticiones
/// y la siguiente, que cae en otro nodo, sí pasa. El error incluye el principio de la respuesta para saber la causa.
struct URLSessionFetcher: Fetcher {
    var attempts = 10
    func fetch(_ url: URL, headers: [String: String]) async throws -> Data { try await fetchResolved(url, headers: headers).0 }

    /// Descarga y devuelve también la dirección final tras las redirecciones.
    func fetchResolved(_ url: URL, headers: [String: String]) async throws -> (Data, URL) {
        var last: Error = URLError(.unknown)
        for n in 1...attempts {
            var req = URLRequest(url: url, timeoutInterval: 30)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode >= 400 else { if n > 1 { Trace.shared.log("red", "\(url.host ?? "?") ok al intento \(n)") }; return (data, resp.url ?? url) }
                let snippet = String(decoding: data.prefix(100), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
                last = NSError(domain: "HTTP", code: http.statusCode,
                               userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) en \(url.host ?? "origen") \(snippet)"])
                // Solo se reintentan los fallos que pueden ser pasajeros
                guard http.statusCode == 403 || http.statusCode == 429 || http.statusCode >= 500, n < attempts else { throw last }
                Trace.shared.log("red", "HTTP \(http.statusCode) en \(url.host ?? "?") · reintento \(n)/\(attempts - 1)")
            } catch let e as NSError where e.domain == "HTTP" { if n >= attempts || ![403, 429].contains(e.code) && e.code < 500 { throw e }; last = e }
              catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }      // cancelado: no se reintenta
                last = error; if n >= attempts { throw error }
            }
            try? await Task.sleep(nanoseconds: UInt64(300_000_000 * min(n, 4)))
        }
        throw last
    }
}

/// Decide cómo reproducir una dirección y, si hace falta, la pasa por el relay local.
@MainActor
final class RelayManager {
    static let shared = RelayManager()
    private let server = LocalHttpServer()
    private var started = false
    private var counter = 0

    /// Qué reproducir y por qué (el motivo se enseña si falla: pidió el usuario más causas de error).
    /// MKV ya abiertos (se reabren al instante si se reinicia la reproducción, p. ej. al mover el audio) y su manejador por sesión.
    private var mkvCache: [String: MkvToHls] = [:]
    private var mkvBySession: [String: MkvToHls] = [:]
    func mkv(_ sessionId: String) -> MkvToHls? { mkvBySession[sessionId] }

    struct Plan { var url: URL; var viaRelay: Bool; var reason: String; var sessionId: String? }

    func plan(url: URL, headers: [String: String], clearKeys: [String: String], fixedHeight: Int = 0, minHeight: Int? = nil, audioGroup: String? = nil, labels: Bool = true) async -> Plan {
        // Se mira el contenido del manifiesto, no el nombre del servidor
        var kind = StreamKind.other
        if let data = try? await URLSessionFetcher().fetch(url, headers: headers.merging(["Range": "bytes=0-65535"]) { a, _ in a }) {
            kind = StreamSniffer.isMatroska(data) ? .matroska : StreamSniffer.kind(ofManifest: String(decoding: data, as: UTF8.self))
        } else {
            // El origen no contestó (p. ej. 403 al azar): se adivina por la dirección para no reproducir un MPD «directo»
            let path = (url.absoluteString.removingPercentEncoding ?? url.absoluteString).lowercased()
            if path.contains(".mpd") { kind = .dash } else if path.contains(".ism") { kind = .smooth } else if path.contains(".m3u8") { kind = .hlsPlain }
            Trace.shared.log("plan", "no se pudo leer el manifiesto; por la dirección parece \(kind)")
        }
        Trace.shared.log("plan", "\(url.host ?? "?") tipo=\(kind) claves=\(clearKeys.count) cabeceras=\(headers.keys.sorted())")
        // MKV: AVPlayer no abre el contenedor. Con el ajuste «local» se pasa a HLS fMP4 sin recodificar, en este dispositivo.
        if kind == .matroska {
            guard AppSettings.mkvMode == "local" else {
                return Plan(url: url, viaRelay: false, reason: "MKV directo (ajuste: \(AppSettings.mkvMode))", sessionId: nil)
            }
            do {
                if !started || !server.alive { try server.start(); started = true }
                counter += 1
                let sid = "s\(counter)"
                let key = url.absoluteString
                let mkv: MkvToHls
                if let c = mkvCache[key] { mkv = c }
                else {
                    mkv = try await MkvToHls.open(source: HttpRangeSource(fetcher: URLSessionFetcher(attempts: 4), url: url, headers: headers),
                                                  log: { Trace.shared.log("mkv", "\(sid) \($0)") })
                    mkvCache = [key: mkv]                                  // solo el último
                }
                mkvBySession[sid] = mkv
                server.add(id: sid, core: mkv)
                let base = "http://\(LocalHttpServer.lanAddress() ?? "127.0.0.1"):\(server.port)/\(sid)"
                return Plan(url: URL(string: "\(base)/master.m3u8")!, viaRelay: true, reason: "MKV → HLS en el dispositivo (sin recodificar)", sessionId: sid)
            } catch {
                Trace.shared.log("mkv", "no se puede pasar a HLS: \(error.localizedDescription)")
                return Plan(url: url, viaRelay: false, reason: "MKV directo (\(error.localizedDescription))", sessionId: nil)
            }
        }
        // Calidad fija en HLS normal: también pasa por el relay, que es quien recorta las variantes
        let forceRelay = fixedHeight > 0 && (kind == .hlsPlain)
        guard forceRelay || StreamSniffer.needsRelay(kind: kind, hasClearKeys: !clearKeys.isEmpty) else {
            return Plan(url: url, viaRelay: false, reason: "directo (\(kind))", sessionId: nil)
        }
        do {
            if !started || !server.alive { try server.start(); started = true }
        } catch {
            return Plan(url: url, viaRelay: false, reason: "relay no arrancó: \(error.localizedDescription)", sessionId: nil)
        }
        counter += 1
        let sid = "s\(counter)"
        let base = "http://\(LocalHttpServer.lanAddress() ?? "127.0.0.1"):\(server.port)/\(sid)"
        let core = RelayCore(relayBase: base, fetcher: URLSessionFetcher(), headers: headers, clearKeys: clearKeys)
        core.prefetchDepth = AppSettings.prefetch
        core.fixedHeight = fixedHeight
        core.audioGroup = audioGroup
        core.labelLang = labels ? AppSettings.deviceLang : nil
        core.minHeight = fixedHeight > 0 ? 0 : (minHeight ?? AppSettings.minHeight)
        core.onLog = { Trace.shared.log("relay", "\(sid) \($0)") }
        server.add(id: sid, core: core)
        let entry = URL(string: "\(base)/m3u8?u=\(HlsRewriter.encode(url.absoluteString))")!
        return Plan(url: entry, viaRelay: true, reason: "relay (\(kind))", sessionId: sid)
    }

    func end(_ p: Plan) { if let s = p.sessionId { server.remove(id: s); mkvBySession[s] = nil } }
}

import Foundation

/// Quién descarga los datos del origen (en la app es URLSession; en las pruebas, un simulado).
public protocol Fetcher {
    func fetch(_ url: URL, headers: [String: String]) async throws -> Data
    /// Como `fetch`, pero devuelve también la dirección FINAL tras las redirecciones (302…): las rutas relativas del manifiesto
    /// (BaseURL, segmentos) se resuelven contra esa dirección, no contra la inicial.
    func fetchResolved(_ url: URL, headers: [String: String]) async throws -> (Data, URL)
}

public extension Fetcher {
    /// Por defecto no se sigue la redirección: la dirección final es la pedida.
    func fetchResolved(_ url: URL, headers: [String: String]) async throws -> (Data, URL) { (try await fetch(url, headers: headers), url) }
}

/// Respuesta del relay a AVPlayer.
public struct RelayResponse {
    public var status: Int
    public var contentType: String
    public var body: Data
}

/// Lógica del relay local, sin red propia: recibe una ruta (`/m3u8?u=…`) y devuelve la respuesta.
/// El servidor HTTP de la app (Network.framework) solo traslada peticiones aquí.
///  - m3u8 → lista HLS reescrita (y MPD de DASH convertido a HLS)
///  - init → inicio sin señalización de cifrado
///  - seg  → segmento descifrado con la clave que corresponde a su KID
public final class RelayCore {
    public let relayBase: String                 // http://127.0.0.1:PUERTO/sesion
    private let fetcher: Fetcher
    private let headers: [String: String]
    private let clearKeys: [String: String]      // kid (hex) → clave (hex)
    private let subtitles: [ExternalSubtitle]
    private let durationSec: Int
    private var initCache: [String: InitInfo] = [:]
    private let lock = NSLock()
    /// Segmentos adelantados: mientras AVPlayer reproduce el N, ya se bajan y descifran los N+1…N+k
    /// (sin esto cada segmento se pide justo cuando hace falta y el directo da microcortes).
    public var prefetchDepth = 3
    /// Resolución mínima (alto) y calidad fija: recortan las variantes de la lista maestra (0 = sin límite).
    public var minHeight = 0
    public var fixedHeight = 0
    /// Si se pone, solo se dejan las variantes de ese grupo de audio (cambio de idioma entre grupos).
    public var audioGroup: String?
    /// Idioma que arranca por defecto y etiquetas «idioma · códec canales» en el selector de audio (vacío = no tocar)
    public var labelLang: String?
    private var prefetched: [String: Task<RelayResponse, Never>] = [:]
    /// Orden de segmentos de cada lista de medios vista (vídeo, audios…); la más reciente primero. Antes solo se guardaba la última
    /// y, con vídeo y audio por separado, solo una de las pistas se descargaba por adelantado.
    private var segOrders: [[String]] = []
    private var keyCache: [String: [UInt8]] = [:]
    /// Numeración de los trozos de cada lista de directo (clave: MPD + pista): instante → número. Así cada recarga de la lista
    /// mantiene el mismo número para el mismo trozo y solo sube el del primero al irse los antiguos.
    private var liveSeq: [String: (map: [Int: Int], next: Int)] = [:]

    /// Número del primer trozo de una lista de directo que ahora contiene los trozos de instantes `times`.
    private func sequence(key: String, times: [Int]) -> Int {
        guard !times.isEmpty else { return 0 }
        lock.lock(); defer { lock.unlock() }
        var st = liveSeq[key] ?? (map: [:], next: 0)
        var first = 0
        for (i, t) in times.enumerated() {
            let n: Int
            if let known = st.map[t] { n = known } else { n = st.next; st.map[t] = n }
            st.next = max(st.next, n + 1)
            if i == 0 { first = n }
        }
        let keep = Set(times); st.map = st.map.filter { keep.contains($0.key) }          // solo los que siguen en la lista
        liveSeq[key] = st
        return first
    }

    /// Datos del inicio de una pista: cómo se cifra y con qué clave.
    struct InitInfo {
        var cleaned: [UInt8]
        var scheme: String?
        var key: [UInt8]?
        var tenc: Cenc.Tenc?
        var kid: String?
    }

    public init(relayBase: String, fetcher: Fetcher, headers: [String: String], clearKeys: [String: String],
                subtitles: [ExternalSubtitle] = [], durationSec: Int = 14400) {
        self.relayBase = relayBase; self.fetcher = fetcher
        self.headers = headers; self.clearKeys = clearKeys
        self.subtitles = subtitles; self.durationSec = durationSec
    }

    /// Descarga con cabeceras de la sesión y, si hay, un rango de bytes («a-b»).
    private func get(_ url: URL, range: String?) async throws -> Data {
        var h = headers
        if let r = range { h["Range"] = "bytes=\(r)" }
        return try await fetcher.fetch(url, headers: h)
    }

    /// Aviso de cada petición atendida (ruta, estado, tamaño, tiempo y causa si falló). Lo usa la app para sus trazas.
    public var onLog: ((String) -> Void)?

    public func handle(path: String) async -> RelayResponse {
        let t0 = Date()
        let isSeg = path.hasPrefix("/seg") || path.contains("/seg?")
        var cached: Task<RelayResponse, Never>?
        if isSeg { lock.lock(); cached = prefetched.removeValue(forKey: path); lock.unlock() }
        let r: RelayResponse
        if let c = cached { let v = await c.value; r = v.status < 400 ? v : await route(path: path) } else { r = await route(path: path) }
        if isSeg { prefetchAfter(path) }
        let kind = path.split(separator: "?").first.map { String($0.split(separator: "/").last ?? "") } ?? "?"
        var line = "\(kind) → \(r.status) \(r.body.count) B \(Int(Date().timeIntervalSince(t0) * 1000)) ms"
        if r.status >= 400 { line += " · " + String(decoding: r.body.prefix(200), as: UTF8.self) }
        onLog?(line)
        return r
    }

    /// Lanza la descarga de los segmentos siguientes a `path` según el orden de la última lista vista.
    private func prefetchAfter(_ path: String) {
        guard prefetchDepth > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard let order = segOrders.first(where: { $0.contains(path) }), let i = order.firstIndex(of: path) else { return }
        for n in order[(i + 1)...].prefix(prefetchDepth) where prefetched[n] == nil {
            prefetched[n] = Task { [unowned self] in await self.route(path: n) }
        }
        // Lo que quedó atrás en esta pista se olvida (memoria acotada)
        let behind = Set(order[..<i])
        for k in prefetched.keys where behind.contains(k) { prefetched[k]?.cancel(); prefetched[k] = nil }
    }

    /// Guarda el orden de los segmentos de una lista de medios ya reescrita.
    private func rememberSegments(_ playlist: String) {
        let paths = playlist.components(separatedBy: .newlines).compactMap { l -> String? in
            guard l.hasPrefix(relayBase), l.contains("/seg?") else { return nil }
            return String(l.dropFirst(relayBase.count))
        }
        guard !paths.isEmpty else { return }
        lock.lock()
        segOrders.removeAll { $0.first == paths.first }        // la misma lista vista otra vez: se sustituye
        segOrders.insert(paths, at: 0)
        if segOrders.count > 8 { segOrders.removeLast() }
        lock.unlock()
    }

    private func route(path: String) async -> RelayResponse {
        guard let comps = URLComponents(string: "http://x" + path) else { return fail(400, "ruta no válida") }
        let kind = comps.path.split(separator: "/").last.map(String.init) ?? ""
        func q(_ n: String) -> String? { comps.queryItems?.first { $0.name == n }?.value }
        guard let u = q("u").flatMap(HlsRewriter.decode), let url = URL(string: u) else { return fail(400, "falta u") }
        do {
            switch kind {
            case "m3u8":
                // La dirección puede redirigir (p. ej. a una sesión del CDN): lo relativo se resuelve contra la final
                let (data, base) = try await fetcher.fetchResolved(url, headers: headers)
                let text = String(decoding: data, as: UTF8.self)
                // «full=1»: lista completa (todos los grupos de audio y calidades) para que la app conozca todas las pistas
                let full = q("full") != nil
                func finish(_ m: String) -> String {
                    var o = m
                    if let l = labelLang { o = AudioLabels.annotate(o, preferLang: l) }          // antes de filtrar: el códec sale de las variantes
                    if full { return o }
                    return VariantFilter.apply(VariantFilter.audioGroup(o, group: audioGroup ?? VariantFilter.autoAudioGroup(o)), minHeight: minHeight, fixedHeight: fixedHeight)
                }
                if SmoothToHls.isSmooth(text) {
                    let hls = finish(try SmoothToHls.master(text, manifestUrl: base, relay: relayBase))
                    return RelayResponse(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data(hls.utf8))
                }
                if text.contains("<MPD") {
                    let hls = finish(HlsRewriter.addSubtitles(try MpdToHls.convert(text, base: base, relay: relayBase), subtitles, relay: relayBase, durationSec: durationSec))
                    return RelayResponse(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data(hls.utf8))
                }
                var out = HlsRewriter.rewrite(text, base: base, relay: relayBase)
                if HlsRewriter.isMaster(text) { out = finish(HlsRewriter.addSubtitles(out, subtitles, relay: relayBase, durationSec: durationSec)) } else { rememberSegments(out) }
                return RelayResponse(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data(out.utf8))
            case "mp":
                // Lista de segmentos de una Representation de un MPD
                guard let rep = q("r").flatMap(HlsRewriter.decode) else { return fail(400, "falta r") }
                let (xmlData, finalUrl) = try await fetcher.fetchResolved(url, headers: headers)
                let xml = String(decoding: xmlData, as: UTF8.self)
                let out = try await MpdToHls.mediaPlaylist(xml, base: finalUrl, repId: rep, relay: relayBase,
                                                           liveSequence: { self.sequence(key: u + "|" + rep, times: $0) }) { u, a, b in
                    try await self.get(u, range: "\(a)-\(b)")
                }
                rememberSegments(out)
                return RelayResponse(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data(out.utf8))
            case "ssp", "ssi":
                // Smooth Streaming: lista de fragmentos («ssp») o inicio fabricado («ssi») de una pista
                guard let r = q("r").flatMap(HlsRewriter.decode) else { return fail(400, "falta r") }
                let (data, finalUrl) = try await fetcher.fetchResolved(url, headers: headers)
                let xml = String(decoding: data, as: UTF8.self)
                let bitrate = q("b").flatMap(Int.init) ?? 0
                if kind == "ssi" { return RelayResponse(status: 200, contentType: "video/mp4", body: Data(try SmoothToHls.initSegment(xml, stream: r, bitrate: bitrate))) }
                let pl = try SmoothToHls.mediaPlaylist(xml, manifestUrl: finalUrl, stream: r, bitrate: bitrate, relay: relayBase)
                return RelayResponse(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data(pl.utf8))
            case "ssf":
                // Fragmento Smooth: se pide (la dirección es relativa a la carpeta del manifiesto), se descifra y se le añade el tiempo
                guard let rel = q("f").flatMap(HlsRewriter.decode), let t = q("t").flatMap(Int.init),
                      let fu = SmoothToHls.fragmentUrl(manifestUrl: url, relative: rel) else { return fail(400, "falta f o t") }
                var bytes = [UInt8](try await get(fu, range: nil))
                if Cenc.isMedia(bytes), let hex = q("kid").flatMap({ clearKeys[$0.lowercased()] }) ?? clearKeys.values.first, let key = Self.hexBytes(hex) {
                    try Cenc.decryptSegment(&bytes, key: key)        // clave del KID del manifiesto; si no casa, la primera (como Android)
                }
                return RelayResponse(status: 200, contentType: "video/mp4", body: Data(SmoothToHls.fixFragment(bytes, start: t)))
            case "init":
                let info = try await initInfo(url.absoluteString + (q("r").map { "|\($0)" } ?? ""))
                return RelayResponse(status: 200, contentType: "video/mp4", body: Data(info.cleaned))
            case "seg":
                var bytes = [UInt8](try await get(url, range: q("r")))
                if q("k") != nil || q("kid") != nil {
                    // TS con SAMPLE-AES clásico: clave de 16 bytes (del servidor o de la lista por KeyId) e IV del segmento
                    var key: [UInt8] = []
                    if let ku = q("k").flatMap(HlsRewriter.decode), let keyUrl = URL(string: ku) {
                        // La clave es la misma para todos los segmentos: se pide una vez
                        lock.lock(); let known = keyCache[ku]; lock.unlock()
                        if let kk = known { key = kk } else {
                            key = [UInt8](try await fetcher.fetch(keyUrl, headers: headers))
                            lock.lock(); keyCache[ku] = key; lock.unlock()
                        }
                    } else if let kid = q("kid") {
                        // Como Android: si el KeyId no casa, vale la primera clave de la lista (un canal = una clave)
                        guard let hex = clearKeys[kid.lowercased()] ?? clearKeys.values.first, let kb = Self.hexBytes(hex) else { return fail(403, "sin clave para el KeyId \(kid) (SAMPLE-AES en TS)") }
                        key = kb
                    }
                    let iv = Self.hexBytes(q("v") ?? "") ?? []
                    guard key.count == 16, iv.count == 16 else { return fail(502, "clave o IV de SAMPLE-AES no válidos") }
                    guard let clear = TsSampleAes.decrypt(bytes, key: key, iv: iv) else { return fail(502, "segmento TS SAMPLE-AES no descifrable") }
                    return RelayResponse(status: 200, contentType: "video/mp2t", body: Data(clear))
                }
                if let i = q("i").flatMap(HlsRewriter.decode), Cenc.isMedia(bytes) {
                    let info = try await initInfo(i)
                    if info.scheme != nil {
                        guard let key = info.key else {
                            return fail(403, "sin clave para el KID \(info.kid ?? "?") (esquema \(info.scheme ?? "?"))")
                        }
                        try Cenc.decryptSegment(&bytes, key: key, cbcs: info.scheme == "cbcs" ? info.tenc : nil)
                    }
                }
                return RelayResponse(status: 200, contentType: "video/mp4", body: Data(bytes))
            case "subpl":
                // Lista de un solo trozo que apunta al subtítulo ya convertido
                let d = q("d").flatMap(Int.init) ?? durationSec
                let pl = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(d)", "#EXT-X-PLAYLIST-TYPE:VOD",
                          "#EXTINF:\(d).0,", "\(relayBase)/sub?u=\(HlsRewriter.encode(url.absoluteString))", "#EXT-X-ENDLIST", ""].joined(separator: "\n")
                return RelayResponse(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data(pl.utf8))
            case "sub":
                // TTML → WebVTT (AVPlayer solo entiende WebVTT)
                let text = String(decoding: try await get(url, range: nil), as: UTF8.self)
                return RelayResponse(status: 200, contentType: "text/vtt; charset=utf-8", body: Data(TtmlToVtt.convert(text).utf8))
            case "vtt":
                // Subtítulo que ya es WebVTT (p. ej. el de los MPD de Max): pasa tal cual. Un trozo «opcional» que no existe
                // (más allá del último) se contesta con un WebVTT vacío para no romper la lista.
                if q("opt") != nil {
                    guard let d = try? await get(url, range: nil) else { return RelayResponse(status: 200, contentType: "text/vtt; charset=utf-8", body: Data("WEBVTT\n\n".utf8)) }
                    return RelayResponse(status: 200, contentType: "text/vtt; charset=utf-8", body: d)
                }
                return RelayResponse(status: 200, contentType: "text/vtt; charset=utf-8", body: try await get(url, range: nil))
            case "key":
                return RelayResponse(status: 200, contentType: "application/octet-stream",
                                     body: try await fetcher.fetch(url, headers: headers))
            default:
                return fail(404, "ruta desconocida")
            }
        } catch {
            return fail(502, "origen: \(error.localizedDescription)")
        }
    }

    private func fail(_ status: Int, _ msg: String) -> RelayResponse {
        RelayResponse(status: status, contentType: "text/plain", body: Data(msg.utf8))
    }

    /// Descarga el inicio una sola vez y deduce esquema, KID y clave por contenido.
    // Acceso con candado desde funciones síncronas (los candados no se pueden usar dentro de async)
    private func cacheGet(_ k: String) -> InitInfo? { lock.lock(); defer { lock.unlock() }; return initCache[k] }
    private func cacheSet(_ k: String, _ v: InitInfo) { lock.lock(); defer { lock.unlock() }; initCache[k] = v }

    /// `spec` = dirección del inicio, con «|a-b» detrás si es un rango de un fichero mayor.
    private func initInfo(_ spec: String) async throws -> InitInfo {
        if let c = cacheGet(spec) { return c }
        let parts = spec.components(separatedBy: "|")
        guard let url = URL(string: parts[0]) else { throw URLError(.badURL) }
        let raw = [UInt8](try await get(url, range: parts.count > 1 ? parts[1] : nil))
        let scheme = Cenc.scheme(raw)
        var info = InitInfo(cleaned: scheme == nil ? raw : Cenc.cleanInit(raw), scheme: scheme,
                            key: nil, tenc: Cenc.tenc(raw), kid: Cenc.kid(raw))
        if let kid = info.kid, let hex = clearKeys[kid.lowercased()] { info.key = Self.hexBytes(hex) }
        cacheSet(spec, info)
        return info
    }

    static func hexBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let n = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<n], radix: 16) else { return nil }
            out.append(b); i = n
        }
        return out
    }
}

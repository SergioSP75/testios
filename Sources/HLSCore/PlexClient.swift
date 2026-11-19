import Foundation

/// Un servidor de la cuenta de Plex, con las direcciones que publica y la última que respondió.
public struct PlexServerEntry: Codable, Equatable {
    public var machineId: String
    public var name: String
    public var token: String
    public var owned: Bool
    public var urls: [String]
    public var url: String?
}

/// Código de enlace de plex.tv/link.
public struct PlexPin { public var id: Int64; public var code: String }

/// Configuración de reproducción de UN servidor Plex.
///  · mode: 0 = directa (fichero original); 1 = automática (directa salvo que se pida un tope); 2 = siempre recodificar (HLS).
public struct PlexServerSettings: Codable, Equatable {
    public var mode = 0
    public var directStream = true
    public var maxRes = 0
    public var maxMbps = 0
    public var hevc = false
    public var quality = 100
    public var audioLang = ""
    public var surround = false
    public var audioCodec = "aac"
    public var subLang = ""
    public var subMode = "burn"
    public init() {}
}

/// Cliente de Plex. Los ids de elementos llevan el servidor delante («machineId~ratingKey»).
public final class PlexClient: ServerBackend {
    private let http: ServerHTTP
    private let store: KeyValueStore
    private let slot: String
    private let userAgent: () -> String

    public init(http: ServerHTTP, store: KeyValueStore, slot: String = "plex", userAgent: @escaping () -> String = { ServerUa.standard }) {
        self.http = http; self.store = store; self.slot = slot; self.userAgent = userAgent
    }

    public var kind: String { slot }
    public var type: String { "plex" }
    public var icon: String { "🟧" }

    private var clientId: String {
        if let c = store.string("\(slot).clientId") { return c }
        let c = UUID().uuidString; store.set(c, for: "\(slot).clientId"); return c
    }

    // MARK: Cuenta y servidores guardados

    private var accountToken: String? { store.string("\(slot).accountToken") }
    public func accountTokenForShare() -> String? { accountToken }

    public func servers() -> [PlexServerEntry] {
        store.string("\(slot).servers").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([PlexServerEntry].self, from: $0) } ?? []
    }
    private func saveServers(_ l: [PlexServerEntry]) {
        if let d = try? JSONEncoder().encode(l) { store.set(String(data: d, encoding: .utf8), for: "\(slot).servers") }
    }
    public func isEnabled(_ id: String) -> Bool { store.string("\(slot).on_\(id)") != "0" }
    public func setEnabled(_ id: String, _ on: Bool) { store.set(on ? "1" : "0", for: "\(slot).on_\(id)") }
    private func enabledServers() -> [PlexServerEntry] { servers().filter { isEnabled($0.machineId) } }

    public func hasSession() -> Bool { !(accountToken ?? "").isEmpty && !enabledServers().isEmpty }
    public func serverLabel() -> String { let l = enabledServers(); return l.count == 1 ? l[0].name : "Plex · \(l.count) servidores" }
    public func logout() {
        for s in servers() { store.set(nil, for: "\(slot).on_\(s.machineId)"); store.set(nil, for: "\(slot).cfg_\(s.machineId)") }
        store.set(nil, for: "\(slot).accountToken"); store.set(nil, for: "\(slot).servers")
    }

    public func config(_ id: String) -> PlexServerSettings {
        store.string("\(slot).cfg_\(id)").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(PlexServerSettings.self, from: $0) } ?? PlexServerSettings()
    }
    public func saveConfig(_ id: String, _ c: PlexServerSettings) {
        if let d = try? JSONEncoder().encode(c) { store.set(String(data: d, encoding: .utf8), for: "\(slot).cfg_\(id)") }
    }

    // MARK: Red

    private func plexHeaders(_ token: String? = nil) -> [String: String] {
        var h = ["Accept": "application/json", "X-Plex-Product": "MediaKillerSP75", "X-Plex-Version": "1.0",
                 "X-Plex-Client-Identifier": clientId, "X-Plex-Platform": "iOS", "X-Plex-Device": "iOS",
                 "X-Plex-Device-Name": "MediaKillerSP75"]
        if let t = token { h["X-Plex-Token"] = t }
        return h
    }

    private func request(_ url: String, method: String = "GET", body: String? = nil, headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> Data {
        ServerUa.remember(url)
        var h = headers; h["User-Agent"] = userAgent()
        h = ServerHeaders.applied(to: h)                 // cabeceras propias de Ajustes → Servidores (mandan sobre las demás)
        if body != nil { h["Content-Type"] = "application/x-www-form-urlencoded" }
        let r: (status: Int, data: Data)
        do { r = try await http.send(url: url, method: method, body: body.map { Data($0.utf8) }, headers: h, timeout: timeout) }
        catch { throw ServerError("Sin conexión con \(URL(string: url)?.host ?? url): \(error.localizedDescription)") }
        switch r.status {
        case 200..<300: return r.data
        case 401, 403: throw ServerError("Cuenta o contraseña de Plex no válidas")
        case 404: throw ServerError("No encontrado en el servidor")
        default: throw ServerError("Plex respondió \(r.status)")
        }
    }

    // MARK: Enlace de la cuenta

    /// Pide un código para enlazar el dispositivo: el usuario lo escribe en plex.tv/link desde otro equipo.
    public func startPin() async throws -> PlexPin {
        let j = parseJSON(try await request("https://plex.tv/api/v2/pins?strong=false", method: "POST", headers: plexHeaders()))
        return PlexPin(id: j.int64("id"), code: j.str("code"))
    }

    /// Token de la cuenta cuando el usuario ya introdujo el código; nil mientras siga pendiente.
    public func pollPin(_ pin: PlexPin) async throws -> String? {
        let j = parseJSON(try await request("https://plex.tv/api/v2/pins/\(pin.id)", headers: plexHeaders()))
        let t = j.str("authToken")
        return t.isEmpty || t == "null" ? nil : t
    }

    /// Inicio de sesión con correo y contraseña (con verificación en dos pasos, el código va al final de la contraseña).
    public func signIn(email: String, password: String) async throws -> String {
        do {
            let j = parseJSON(try await request("https://plex.tv/api/v2/users/signin", method: "POST",
                body: "login=\(urlEnc(email))&password=\(urlEnc(password))&rememberMe=true", headers: plexHeaders()))
            return j.str("authToken")
        } catch { throw ServerError("Correo o contraseña de Plex no válidos") }
    }

    /// Vuelve a pedir a plex.tv los servidores de la cuenta. Direcciones ordenadas: local, pública y relay (limitado) al final; https antes que http.
    @discardableResult
    public func refreshServers() async throws -> [PlexServerEntry] {
        guard let tok = accountToken else { throw ServerError("Sin sesión") }
        let old = Dictionary(servers().map { ($0.machineId, $0) }, uniquingKeysWith: { a, _ in a })
        let arr = parseJSONArray(try await request("https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=1", headers: plexHeaders(tok)))
        var list: [PlexServerEntry] = []
        for r in arr {
            guard r.str("provides").split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "server" }) else { continue }
            func rank(_ c: JSON) -> Int { (c.bool("relay") ? 20 : c.bool("local") ? 0 : 10) + (c.str("uri").hasPrefix("https") ? 0 : 1) }
            let urls = r.arr("connections").sorted { rank($0) < rank($1) }
                .map { $0.str("uri").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty }
            let id = r.str("clientIdentifier")
            if id.isEmpty || r.str("accessToken").isEmpty || urls.isEmpty { continue }
            list.append(PlexServerEntry(machineId: id, name: r.str("name").isEmpty ? "Plex" : r.str("name"), token: r.str("accessToken"),
                                        owned: r.bool("owned"), urls: urls, url: old[id]?.url))
        }
        saveServers(list); return list
    }

    /// Acaba el enlace: guarda el token y los servidores. Devuelve sus nombres.
    public func finishLogin(accountToken: String) async throws -> [String] {
        store.set(accountToken, for: "\(slot).accountToken")
        let list = try await refreshServers()
        if list.isEmpty { throw ServerError("Esta cuenta de Plex no tiene servidores") }
        return list.map { $0.name }
    }

    /// Primera dirección del servidor que responde; se recuerda para las siguientes consultas.
    private func baseUrl(_ s: PlexServerEntry) async throws -> String {
        var last = "No se pudo contactar con \(s.name)"
        for u in ([s.url].compactMap { $0 } + s.urls.filter { $0 != s.url }) {
            do {
                _ = try await request("\(u)/identity", headers: plexHeaders(s.token), timeout: 5)
                if u != s.url { saveServers(servers().map { var x = $0; if x.machineId == s.machineId { x.url = u }; return x }) }
                return u
            } catch { last = "\(s.name): \(error.localizedDescription)" }
        }
        throw ServerError(last)
    }

    // MARK: Consultas

    private func split(_ id: String) -> (String, String) {
        guard let i = id.firstIndex(of: "~") else { return (id, "") }
        return (String(id[..<i]), String(id[id.index(after: i)...]))
    }
    private func server(_ machineId: String) throws -> PlexServerEntry {
        guard let s = servers().first(where: { $0.machineId == machineId }) else { throw ServerError("Servidor no disponible") }
        return s
    }
    private func get(_ s: PlexServerEntry, _ path: String) async throws -> JSON {
        let base = try await baseUrl(s)
        let d = try await request(base + path, headers: plexHeaders(s.token))
        return d.isEmpty ? [:] : parseJSON(d)
    }
    private func container(_ j: JSON) -> JSON { j.obj("MediaContainer") ?? [:] }

    /// Elemento de Plex en el formato común (mismos tipos que Emby); el id lleva el servidor delante.
    private func parse(_ s: PlexServerEntry, _ j: JSON) -> EmbyItem? {
        let key = j.str("ratingKey"); if key.isEmpty { return nil }
        let map = ["movie": "Movie", "show": "Series", "season": "Season", "episode": "Episode", "collection": "BoxSet", "clip": "Video"]
        guard let type = map[j.str("type")] else { return nil }
        var it = EmbyItem(id: "\(s.machineId)~\(key)", name: j.str("title"), type: type)
        it.year = j.int("year"); it.overview = j.str("summary")
        it.genres = j.arr("Genre").map { $0.str("tag") }
        if let r = (j["rating"] as? Double) ?? (j["audienceRating"] as? Double) { it.rating = String(format: "%.1f", r) }
        it.runtimeSec = j.int64("duration") / 1000
        it.thumb = j.str("thumb"); it.hasPoster = !it.thumb.isEmpty
        it.seasonNumber = type == "Season" ? j.int("index") : j.int("parentIndex")
        it.episodeNumber = type == "Episode" ? j.int("index") : 0
        it.seriesName = j.str("grandparentTitle"); it.resumeSec = j.int64("viewOffset") / 1000
        return it
    }
    private func metadata(_ s: PlexServerEntry, _ j: JSON) -> [EmbyItem] { container(j).arr("Metadata").compactMap { parse(s, $0) } }

    /// Bibliotecas de todos los servidores activos; con más de uno se antepone su nombre.
    public func libraries() async throws -> [EmbyItem] {
        let on = enabledServers(); var out: [EmbyItem] = []
        for s in on {
            do {
                for d in container(try await get(s, "/library/sections")).arr("Directory") where ["movie", "show"].contains(d.str("type")) {
                    let title = on.count > 1 ? "\(s.name) · \(d.str("title"))" : d.str("title")
                    var art = ""
                    if let j = try? await get(s, "/library/sections/\(d.str("key"))/all?X-Plex-Container-Start=0&X-Plex-Container-Size=1&sort=addedAt:desc"),
                       let m = container(j).arr("Metadata").first { art = m.str("art").isEmpty ? m.str("thumb") : m.str("art") }
                    var it = EmbyItem(id: "\(s.machineId)~\(d.str("key"))", name: title, type: "CollectionFolder")
                    it.hasPoster = !art.isEmpty; it.collectionType = d.str("type"); it.thumb = art
                    out.append(it)
                }
            } catch { if on.count == 1 { throw error } }       // un servidor caído no impide ver los demás
        }
        return out
    }

    private func genreKey(_ s: PlexServerEntry, _ section: String, _ name: String) async -> String? {
        guard let j = try? await get(s, "/library/sections/\(section)/genre") else { return nil }
        return container(j).arr("Directory").first { $0.str("title").lowercased() == name.lowercased() }?.str("key")
    }

    public func report(item: EmbyItem, state: String, positionSec: Int64, durationSec: Int64) async {
        let (mid, key) = split(item.id)
        guard let s = try? server(mid) else { return }
        let st = state == "stop" ? "stopped" : "playing"
        _ = try? await get(s, "/:/timeline?ratingKey=\(key)&key=\(urlEnc("/library/metadata/\(key)"))&state=\(st)&time=\(positionSec * 1000)&duration=\(durationSec * 1000)&identifier=com.plexapp.plugins.library")
    }

    public func genres(parentId: String?) async -> [String] {
        var libs: [String] = []
        if let p = parentId { libs = [p] } else { libs = ((try? await libraries()) ?? []).map { $0.id } }
        var out = Set<String>()
        for lib in libs {
            let (mid, key) = split(lib)
            if let s = try? server(mid), let j = try? await get(s, "/library/sections/\(key)/genre") {
                for d in container(j).arr("Directory") { out.insert(d.str("title")) }
            }
        }
        return out.sorted { $0.lowercased() < $1.lowercased() }
    }

    public func items(parentId: String?, search: String, start: Int, limit: Int, filter: ServerFilter = ServerFilter()) async throws -> EmbyPage {
        var libs: [String] = []
        if let p = parentId { libs = [p] } else { libs = try await libraries().map { $0.id } }
        let single = libs.count == 1
        var out: [EmbyItem] = []; var total = 0
        for lib in libs {
            let (mid, key) = split(lib); let s = try server(mid)
            var q = "/library/sections/\(key)/all?X-Plex-Container-Start=\(single ? start : 0)&X-Plex-Container-Size=\(single ? limit : start + limit)"
            if !search.trimmingCharacters(in: .whitespaces).isEmpty { q += "&title=\(urlEnc(search))" }
            q += "&sort=" + (filter.sort == .name ? "titleSort" : filter.sort == .year ? "year:desc,titleSort" : "addedAt:desc")
            if let g = filter.genre { guard let gk = await genreKey(s, key, g) else { continue }; q += "&genre=\(gk)" }
            do {
                let j = try await get(s, q); out += metadata(s, j)
                total += (container(j)["totalSize"] as? Int) ?? (container(j)["size"] as? Int) ?? 0
            } catch { if single { throw error } }
        }
        if single { return EmbyPage(items: out, total: total) }
        let merged = filter.sort == .year ? out.sorted { $0.year != $1.year ? $0.year > $1.year : $0.name.lowercased() < $1.name.lowercased() }
                                          : out.sorted { $0.name.lowercased() < $1.name.lowercased() }
        return EmbyPage(items: Array(merged.dropFirst(start).prefix(limit)), total: total)
    }
    public func items(parentId: String?, search: String, start: Int, limit: Int) async throws -> EmbyPage {
        try await items(parentId: parentId, search: search, start: start, limit: limit, filter: ServerFilter())
    }

    /// «Seguir viendo» = On Deck de todos los servidores activos.
    public func resume() async throws -> [EmbyItem] {
        var out: [EmbyItem] = []
        for s in enabledServers() {
            if let j = try? await get(s, "/library/onDeck?X-Plex-Container-Start=0&X-Plex-Container-Size=40") { out += metadata(s, j) }
        }
        return out
    }
    public func children(parentId: String) async throws -> [EmbyItem] { let (m, k) = split(parentId); let s = try server(m); return metadata(s, try await get(s, "/library/collections/\(k)/children")) }
    public func seasons(seriesId: String) async throws -> [EmbyItem] { let (m, k) = split(seriesId); let s = try server(m); return metadata(s, try await get(s, "/library/metadata/\(k)/children")) }
    public func episodes(seriesId: String, seasonId: String) async throws -> [EmbyItem] { let (m, k) = split(seasonId); let s = try server(m); return metadata(s, try await get(s, "/library/metadata/\(k)/children")) }

    // MARK: Imágenes y reproducción

    /// Carátula pedida ya reducida al servidor (/photo/:/transcode).
    public func posterUrl(_ item: EmbyItem, maxWidth: Int = 360) -> String? {
        guard !item.thumb.isEmpty, let s = servers().first(where: { $0.machineId == split(item.id).0 }),
              let base = s.url ?? s.urls.first else { return nil }
        return "\(base)/photo/:/transcode?width=\(maxWidth)&height=\(maxWidth * 3 / 2)&minSize=1&upscale=1&url=\(urlEnc(item.thumb))&X-Plex-Token=\(s.token)"
    }

    private func partOf(_ item: EmbyItem) async throws -> (PlexServerEntry, String, JSON)? {
        let (mid, key) = split(item.id); let s = try server(mid)
        let j = try await get(s, "/library/metadata/\(key)")
        guard let part = container(j).arr("Metadata").first?.arr("Media").first?.arr("Part").first else { return nil }
        return (s, key, part)
    }

    /// Fichero original (direct play) o emisión HLS «universal» según la configuración DEL SERVIDOR.
    public func streamUrl(_ item: EmbyItem) async throws -> String? {
        guard let (s, key, part) = try await partOf(item) else { return nil }
        let base = try await baseUrl(s); let c = config(s.machineId)
        let direct = "\(base)\(part.str("key"))?X-Plex-Token=\(s.token)"
        let capped = c.maxMbps > 0 || c.maxRes > 0
        if c.mode == 0 || (c.mode == 1 && !capped) { return direct }
        let streams = part.arr("Stream")
        func sid(_ t: Int, _ lang: String) -> String? { streams.first { $0.int("streamType") == t && $0.str("languageCode").lowercased() == lang.lowercased() }.map { $0.str("id") } }
        return hlsUrl(s, base, key, c, c.maxMbps, c.maxRes, c.audioLang.isEmpty ? nil : sid(2, c.audioLang), c.subLang.isEmpty ? nil : sid(3, c.subLang))
    }

    /// HLS «universal» de Plex con bitrate, resolución, audio y subtítulos indicados.
    private func hlsUrl(_ s: PlexServerEntry, _ base: String, _ key: String, _ c: PlexServerSettings, _ mbps: Int, _ res: Int, _ audio: String?, _ sub: String?) -> String {
        var q: [(String, String)] = [("path", "/library/metadata/\(key)"), ("mediaIndex", "0"), ("partIndex", "0"), ("protocol", "hls"),
            ("offset", "0"), ("fastSeek", "1"), ("directPlay", "0"), ("copyts", "1"),
            ("directStream", c.directStream ? "1" : "0"), ("directStreamAudio", c.directStream ? "1" : "0"),
            ("videoQuality", String(c.quality)), ("session", newId())]
        if mbps > 0 { q.append(("maxVideoBitrate", String(mbps * 1000))) }
        if let r = [1080: "1920x1080", 720: "1280x720", 480: "854x480", 360: "640x360"][res] { q.append(("videoResolution", r)) }
        if let a = audio { q.append(("audioStreamID", a)) }
        if let sb = sub, !sb.isEmpty { q.append(("subtitleStreamID", sb)); q.append(("subtitles", c.subMode)) }
        var extra = ["add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=\(c.hevc ? "h264,hevc" : "h264")&audioCodec=\(c.audioCodec))"]
        if !c.surround { extra.append("add-limitation(scope=audioCodec&scopeName=*&type=upperBound&name=audio.channels&value=2)") }
        q.append(("X-Plex-Client-Profile-Extra", extra.joined(separator: "+")))
        q.append(("X-Plex-Platform", "Chrome")); q.append(("X-Plex-Product", "MediaKillerSP75"))
        q.append(("X-Plex-Client-Identifier", clientId)); q.append(("X-Plex-Token", s.token))
        return "\(base)/video/:/transcode/universal/start.m3u8?" + q.map { "\($0.0)=\(urlEnc($0.1))" }.joined(separator: "&")
    }

    public func streamOffer(_ item: EmbyItem) async -> StreamOffer? {
        guard let (_, _, part) = (try? await partOf(item)) ?? nil else { return nil }
        let o = StreamOffers.fromPlexStreams(part.arr("Stream"))
        return o.isEmpty ? nil : o
    }

    public func streamChoices(_ item: EmbyItem) async -> [StreamChoice] {
        guard let (_, _, part) = (try? await partOf(item)) ?? nil else { return [] }
        var out = [StreamChoice(section: "Calidad", label: "Original (sin recodificar)", id: "0")]
        for m in [20, 8, 4, 2, 1] { out.append(StreamChoice(section: "Calidad", label: "\(m) Mbps (el servidor recodifica)", id: String(m))) }
        for st in part.arr("Stream") where st.int("streamType") == 2 {
            var name = st.str("extendedDisplayTitle"); if name.isEmpty { name = st.str("displayTitle") }; if name.isEmpty { name = "Pista" }
            out.append(StreamChoice(section: "Audio", label: name, id: st.str("id")))
        }
        return out
    }

    public func streamUrlFor(_ item: EmbyItem, _ p: StreamParams) async throws -> String? {
        guard let (s, key, part) = try await partOf(item) else { return nil }
        let base = try await baseUrl(s)
        if p.mbps == 0 && p.audioId == nil && (p.subId ?? "").isEmpty { return "\(base)\(part.str("key"))?X-Plex-Token=\(s.token)" }
        return hlsUrl(s, base, key, config(s.machineId), p.mbps, 0, p.audioId, p.subId)
    }
}

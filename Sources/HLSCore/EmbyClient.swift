import Foundation

/// Datos de la sesión guardada en Emby o Jellyfin.
public struct EmbyAccount: Codable, Equatable {
    public var type: String          // "emby" | "jellyfin"
    public var mode: String          // "connect" | "direct"
    public var email: String         // correo (connect) o usuario (direct)
    public var password: String
    public var serverUrl: String
    public var token: String
    public var userId: String
    public var serverName: String
}

/// Cliente de Emby y Jellyfin (la API es casi la misma; cambian la cabecera del token y el nombre del parámetro de clave).
/// Dos maneras de entrar: Emby Connect (correo + contraseña) o servidor directo (dirección + usuario + contraseña).
public final class EmbyClient: ServerBackend {
    private let http: ServerHTTP
    private let store: KeyValueStore
    private let slot: String
    private let userAgent: () -> String

    public init(http: ServerHTTP, store: KeyValueStore, slot: String = "emby", userAgent: @escaping () -> String = { ServerUa.standard }) {
        self.http = http; self.store = store; self.slot = slot; self.userAgent = userAgent
    }

    public var kind: String { slot }
    public var type: String { String(slot.split(separator: "_").first ?? "emby") }
    public var icon: String { slot.hasPrefix("jellyfin") ? "🟪" : "🟩" }
    public func hasSession() -> Bool { account() != nil }
    public func serverLabel() -> String {
        guard let a = account() else { return "Sin sesión" }
        return (a.serverName.isEmpty ? a.serverUrl : a.serverName) + (a.type == "jellyfin" ? " (Jellyfin)" : "")
    }
    public func logout() { store.set(nil, for: "\(slot).account") }

    // MARK: Cuenta y dispositivo

    private var deviceId: String {
        if let d = store.string("\(slot).deviceId") { return d }
        let d = UUID().uuidString; store.set(d, for: "\(slot).deviceId"); return d
    }

    private func authHeader(_ scheme: String) -> String {
        "\(scheme) Client=\"MediaKillerSP75\", Device=\"iOS\", DeviceId=\"\(deviceId)\", Version=\"1.0\""
    }

    public func account() -> EmbyAccount? {
        store.string("\(slot).account").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(EmbyAccount.self, from: $0) }
    }
    private func save(_ a: EmbyAccount) {
        if let d = try? JSONEncoder().encode(a) { store.set(String(data: d, encoding: .utf8), for: "\(slot).account") }
    }

    // MARK: Red

    private func request(_ url: String, method: String = "GET", body: Data? = nil, json: Bool = false,
                         headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> Data {
        var h = headers
        ServerUa.remember(url)
        h["User-Agent"] = userAgent(); h["Accept"] = "application/json"
        h = ServerHeaders.applied(to: h)                 // cabeceras propias de Ajustes → Servidores (mandan sobre las demás)
        if body != nil { h["Content-Type"] = json ? "application/json" : "application/x-www-form-urlencoded" }
        let r: (status: Int, data: Data)
        do { r = try await http.send(url: url, method: method, body: body, headers: h, timeout: timeout) }
        catch { throw ServerError("Sin conexión con \(URL(string: url)?.host ?? url): \(error.localizedDescription)") }
        switch r.status {
        case 200..<300: return r.data
        case 401, 403: throw ServerError("Usuario o contraseña no válidos")
        case 404: throw ServerError("No encontrado en el servidor")
        default: throw ServerError("El servidor respondió \(r.status)")
        }
    }

    // MARK: Inicio de sesión

    /// Entra con Emby Connect: prueba cada servidor enlazado y cada una de sus direcciones (primero la local).
    @discardableResult
    public func loginConnect(email: String, password: String) async throws -> EmbyAccount {
        let app = ["X-Application": "MediaKillerSP75/1.0"]
        let auth: JSON
        do {
            auth = parseJSON(try await request("https://connect.emby.media/service/user/authenticate", method: "POST",
                body: Data("nameOrEmail=\(urlEnc(email))&rawpw=\(urlEnc(password))".utf8), headers: app))
        } catch { throw ServerError("Correo o contraseña de Emby no válidos") }
        let connectToken = auth.str("AccessToken")
        let connectUser = auth.obj("User")?.str("Id") ?? ""
        var h = app; h["X-Connect-UserToken"] = connectToken
        let servers = parseJSONArray(try await request("https://connect.emby.media/service/servers?userId=\(connectUser)", headers: h))
        if servers.isEmpty { throw ServerError("La cuenta no tiene ningún servidor Emby enlazado") }
        var lastError = "No se pudo contactar con el servidor"
        for s in servers {
            for base in [s.str("LocalAddress"), s.str("Url")].filter({ !$0.isEmpty }).map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }) {
                do {
                    _ = try await request("\(base)/System/Info/Public", timeout: 4)
                    let ex = parseJSON(try await request("\(base)/Connect/Exchange?format=json&ConnectUserId=\(connectUser)",
                                                         headers: ["X-MediaBrowser-Token": s.str("AccessKey")]))
                    let acc = EmbyAccount(type: "emby", mode: "connect", email: email, password: password, serverUrl: base,
                                          token: ex.str("AccessToken"), userId: ex.str("LocalUserId"), serverName: s.str("Name"))
                    save(acc); return acc
                } catch { lastError = "\(s.str("Name")): \(error.localizedDescription)" }
            }
        }
        throw ServerError(lastError)
    }

    /// Entra directamente en un servidor con su usuario y contraseña. `type` = "emby" o "jellyfin".
    @discardableResult
    public func loginDirect(serverUrl: String, user: String, password: String, type: String = "emby") async throws -> EmbyAccount {
        var base = serverUrl.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !base.hasPrefix("http") { base = "http://" + base }
        // Emby documenta su propio esquema («Emby …»); Jellyfin, el heredado «MediaBrowser …» en Authorization
        let h = type == "jellyfin" ? ["Authorization": authHeader("MediaBrowser")] : ["X-Emby-Authorization": authHeader("Emby")]
        let r = parseJSON(try await request("\(base)/Users/AuthenticateByName", method: "POST",
                                            body: jsonData(["Username": user, "Pw": password]), json: true, headers: h))
        let name = (try? await request("\(base)/System/Info/Public", timeout: 5)).map { parseJSON($0).str("ServerName") } ?? ""
        let acc = EmbyAccount(type: type, mode: "direct", email: user, password: password, serverUrl: base,
                              token: r.str("AccessToken"), userId: r.obj("User")?.str("Id") ?? "", serverName: name)
        save(acc); return acc
    }

    /// Repite el inicio de sesión guardado (el token caducó o se cambió de red).
    public func relogin() async -> EmbyAccount? {
        guard let a = account() else { return nil }
        return a.mode == "direct" ? try? await loginDirect(serverUrl: a.serverUrl, user: a.email, password: a.password, type: a.type)
                                  : try? await loginConnect(email: a.email, password: a.password)
    }

    // MARK: Consultas

    /// Emby lleva el token en X-Emby-Token; Jellyfin 12 solo acepta «Authorization: MediaBrowser Token=…».
    private func tokenHeader(_ a: EmbyAccount) -> [String: String] {
        a.type == "jellyfin" ? ["Authorization": "MediaBrowser Token=\"\(a.token)\""] : ["X-Emby-Token": a.token]
    }
    /// Token para direcciones que descarga AsyncImage o AVPlayer (sin cabeceras): Emby «api_key», Jellyfin «ApiKey».
    private func keyParam(_ a: EmbyAccount) -> String { a.type == "jellyfin" ? "ApiKey=\(a.token)" : "api_key=\(a.token)" }

    /// GET con el token; si el servidor lo rechaza se repite el inicio de sesión una vez.
    private func get(_ path: String) async throws -> JSON {
        guard var a = account() else { throw ServerError("Sin sesión") }
        func call(_ acc: EmbyAccount) async throws -> JSON {
            let d = try await request(acc.serverUrl + path, headers: tokenHeader(acc))
            return d.isEmpty ? [:] : parseJSON(d)
        }
        do { return try await call(a) } catch {
            guard let n = await relogin() else { throw error }
            a = n; return try await call(a)
        }
    }

    private static let fields = "Overview,ProductionYear,CommunityRating,RunTimeTicks,Genres,ImageTags"

    private func parse(_ j: JSON) -> EmbyItem {
        let type = j.str("Type")
        var it = EmbyItem(id: j.str("Id"), name: j.str("Name"), type: type)
        it.year = j.int("ProductionYear"); it.overview = j.str("Overview")
        it.genres = (j["Genres"] as? [String]) ?? []
        if let r = j["CommunityRating"] as? Double { it.rating = String(format: "%.1f", r) }
        it.runtimeSec = j.int64("RunTimeTicks") / 10_000_000
        it.hasPoster = j.obj("ImageTags")?["Primary"] != nil
        // En una temporada el número es IndexNumber; en un capítulo, la temporada es ParentIndexNumber
        it.seasonNumber = type == "Season" ? j.int("IndexNumber") : j.int("ParentIndexNumber")
        it.episodeNumber = type == "Episode" ? j.int("IndexNumber") : 0
        it.seriesName = j.str("SeriesName"); it.collectionType = j.str("CollectionType")
        it.resumeSec = (j.obj("UserData")?.int64("PlaybackPositionTicks") ?? 0) / 10_000_000
        return it
    }
    private func page(_ j: JSON) -> EmbyPage {
        let items = j.arr("Items").map(parse)
        return EmbyPage(items: items, total: (j["TotalRecordCount"] as? Int) ?? items.count)
    }

    public func libraries() async throws -> [EmbyItem] {
        guard let a = account() else { return [] }
        return page(try await get("/Users/\(a.userId)/Views")).items
    }

    public func items(parentId: String?, search: String, start: Int, limit: Int, filter: ServerFilter = ServerFilter()) async throws -> EmbyPage {
        guard let a = account() else { return EmbyPage(items: [], total: 0) }
        let (sort, desc): (String, Bool) = {
            switch filter.sort { case .name: return ("SortName", false); case .year: return ("ProductionYear,SortName", true); case .added: return ("DateCreated,SortName", true) }
        }()
        var q = "/Users/\(a.userId)/Items?Recursive=true&Fields=\(Self.fields)&StartIndex=\(start)&Limit=\(limit)"
        q += "&SortBy=\(sort)&SortOrder=\(desc ? "Descending" : "Ascending")"
        if let p = parentId { q += "&ParentId=\(p)" }
        q += "&IncludeItemTypes=Movie,Series,BoxSet,Video"
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { q += "&SearchTerm=\(urlEnc(search))" }
        if let g = filter.genre { q += "&Genres=\(urlEnc(g))" }
        return page(try await get(q))
    }
    public func items(parentId: String?, search: String, start: Int, limit: Int) async throws -> EmbyPage {
        try await items(parentId: parentId, search: search, start: start, limit: limit, filter: ServerFilter())
    }

    public func report(item: EmbyItem, state: String, positionSec: Int64, durationSec: Int64) async {
        guard let a = account() else { return }
        let path = state == "start" ? "/Sessions/Playing" : state == "stop" ? "/Sessions/Playing/Stopped" : "/Sessions/Playing/Progress"
        let body: JSON = ["ItemId": item.id, "MediaSourceId": item.id, "PlaySessionId": "sps-\(item.id)",
                          "PositionTicks": positionSec * 10_000_000, "CanSeek": true, "IsPaused": false, "PlayMethod": "DirectStream"]
        _ = try? await request(a.serverUrl + path, method: "POST", body: jsonData(body), json: true, headers: tokenHeader(a))
    }

    public func genres(parentId: String?) async -> [String] {
        guard let a = account() else { return [] }
        var q = "/Genres?UserId=\(a.userId)&Recursive=true&IncludeItemTypes=Movie,Series&SortBy=SortName"
        if let p = parentId { q += "&ParentId=\(p)" }
        return ((try? await get(q)).map { page($0).items.map { $0.name } }) ?? []
    }

    public func resume() async throws -> [EmbyItem] {
        guard let a = account() else { return [] }
        return page(try await get("/Users/\(a.userId)/Items/Resume?Limit=40&Recursive=true&Fields=\(Self.fields)&MediaTypes=Video")).items
    }
    public func children(parentId: String) async throws -> [EmbyItem] {
        guard let a = account() else { return [] }
        return page(try await get("/Users/\(a.userId)/Items?ParentId=\(parentId)&Fields=\(Self.fields)&SortBy=SortName&Limit=500")).items
    }
    public func seasons(seriesId: String) async throws -> [EmbyItem] {
        guard let a = account() else { return [] }
        return page(try await get("/Shows/\(seriesId)/Seasons?UserId=\(a.userId)&Fields=\(Self.fields)")).items
    }
    public func episodes(seriesId: String, seasonId: String) async throws -> [EmbyItem] {
        guard let a = account() else { return [] }
        return page(try await get("/Shows/\(seriesId)/Episodes?UserId=\(a.userId)&SeasonId=\(seasonId)&Fields=\(Self.fields)")).items
    }

    // MARK: Ajustes y direcciones de reproducción

    public func streamSettings() -> EmbyStreamSettings {
        store.string("\(slot).stream").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(EmbyStreamSettings.self, from: $0) } ?? EmbyStreamSettings()
    }
    public func saveStreamSettings(_ s: EmbyStreamSettings) {
        if let d = try? JSONEncoder().encode(s) { store.set(String(data: d, encoding: .utf8), for: "\(slot).stream") }
    }

    public func posterUrl(_ item: EmbyItem, maxWidth: Int = 360) -> String? {
        guard let a = account(), item.hasPoster else { return nil }
        return "\(a.serverUrl)/Items/\(item.id)/Images/Primary?maxWidth=\(maxWidth)&quality=88&\(keyParam(a))"
    }

    /// Si el elemento es un .strm que apunta a una emisión de Internet, esa dirección (se reproduce directa:
    /// la llamada de reproducción del servidor intenta abrir el .strm y falla con error de E/S).
    private func remoteSource(_ item: EmbyItem) async -> String? {
        guard let a = account(),
              let j = try? await get("/Users/\(a.userId)/Items/\(item.id)?Fields=MediaSources"),
              let src = j.arr("MediaSources").first, src.bool("IsRemote") else { return nil }
        let path = src.str("Path")
        return path.lowercased().hasPrefix("http") ? path : nil
    }

    public func streamUrl(_ item: EmbyItem) async throws -> String? {
        guard let a = account() else { return nil }
        if let r = await remoteSource(item) { return r }
        let st = streamSettings()
        let direct = "\(a.serverUrl)/Videos/\(item.id)/stream?static=true&\(keyParam(a))"
        if !st.transcode && st.maxMbps == 0 { return direct }
        guard let j = try? await get("/Users/\(a.userId)/Items/\(item.id)?Fields=MediaSources"),
              let src = j.arr("MediaSources").first else { return direct }
        let streams = src.arr("MediaStreams")
        func index(_ type: String, _ lang: String) -> String? {
            streams.first { $0.str("Type") == type && $0.str("Language").lowercased() == lang.lowercased() }.map { String($0.int("Index")) }
        }
        return hlsUrl(a, item, src.str("Id"), st, st.maxMbps,
                      st.audioLang.isEmpty ? nil : index("Audio", st.audioLang),
                      st.subLang.isEmpty ? nil : index("Subtitle", st.subLang))
    }

    /// HLS del servidor con bitrate, audio y subtítulos indicados (los subtítulos se queman en la imagen).
    private func hlsUrl(_ a: EmbyAccount, _ item: EmbyItem, _ sourceId: String, _ st: EmbyStreamSettings, _ mbps: Int, _ audio: String?, _ sub: String?) -> String {
        var q = "\(a.serverUrl)/Videos/\(item.id)/master.m3u8?MediaSourceId=\(urlEnc(sourceId))"
        q += "&VideoCodec=\(st.allowHevc ? "hevc,h264" : "h264")&AudioCodec=aac,ac3"
        let ch = st.surround ? 6 : 2
        q += "&MaxAudioChannels=\(ch)&TranscodingMaxAudioChannels=\(ch)"
        q += "&MaxStreamingBitrate=\(mbps > 0 ? mbps * 1_000_000 : 140_000_000)"
        q += "&SegmentContainer=ts&BreakOnNonKeyFrames=True&PlaySessionId=\(newId())"
        if let au = audio { q += "&AudioStreamIndex=\(au)" }
        if let s = sub, !s.isEmpty { q += "&SubtitleStreamIndex=\(s)&SubtitleMethod=Encode" }
        return q + "&\(keyParam(a))"
    }

    public func streamOffer(_ item: EmbyItem) async -> StreamOffer? {
        guard let a = account(), await remoteSource(item) == nil,
              let j = try? await get("/Users/\(a.userId)/Items/\(item.id)?Fields=MediaSources"),
              let src = j.arr("MediaSources").first else { return nil }
        let o = StreamOffers.fromEmbyStreams(src.arr("MediaStreams"))
        return o.isEmpty ? nil : o
    }

    public func streamChoices(_ item: EmbyItem) async -> [StreamChoice] {
        guard let a = account() else { return [] }
        if await remoteSource(item) != nil { return [] }        // emisión directa de Internet: no hay calidades que elegir
        var out = [StreamChoice(section: "Calidad", label: "Original (sin recodificar)", id: "0")]
        for m in [20, 8, 4, 2, 1] { out.append(StreamChoice(section: "Calidad", label: "\(m) Mbps (el servidor recodifica)", id: String(m))) }
        if let j = try? await get("/Users/\(a.userId)/Items/\(item.id)?Fields=MediaSources"), let src = j.arr("MediaSources").first {
            out.append(StreamChoice(section: "Subtítulos", label: "Ninguno", id: ""))
            for s in src.arr("MediaStreams") {
                let idx = String(s.int("Index"))
                var name = s.str("DisplayTitle"); if name.isEmpty { name = s.str("Language") }; if name.isEmpty { name = "Pista \(idx)" }
                if s.str("Type") == "Audio" { out.append(StreamChoice(section: "Audio", label: name, id: idx)) }
                if s.str("Type") == "Subtitle" { out.append(StreamChoice(section: "Subtítulos", label: name, id: idx)) }
            }
        }
        return out
    }

    public func streamUrlFor(_ item: EmbyItem, _ p: StreamParams) async throws -> String? {
        guard let a = account() else { return nil }
        if let r = await remoteSource(item) { return r }
        if p.mbps == 0 && p.audioId == nil && (p.subId ?? "").isEmpty { return "\(a.serverUrl)/Videos/\(item.id)/stream?static=true&\(keyParam(a))" }
        guard let j = try? await get("/Users/\(a.userId)/Items/\(item.id)?Fields=MediaSources"), let src = j.arr("MediaSources").first else { return nil }
        return hlsUrl(a, item, src.str("Id"), streamSettings(), p.mbps, p.audioId, p.subId)
    }
}

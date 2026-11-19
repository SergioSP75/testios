import Foundation
import HLSCore

/// Guarda las listas del usuario y descarga/lee sus canales.
/// Equivale a PlaylistRepository + PlaylistLoader de Android.
@MainActor
final class PlaylistStore: ObservableObject {
    @Published var playlists: [PlaylistConfig] = []
    @Published var channels: [IptvChannel] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var epgReady = false           // la guía ya está cargada (para redibujar)
    let epg = EpgStore()

    private let key = "playlists.v1"

    init() { load(); seedDefaults() }

    // MARK: - Listas por defecto (app_config.json, igual que AppConfig.defaultPlaylists en Android)

    /// Configuración incluida en la app: listas por defecto y guía (EPG) por defecto.
    private static var bundledConfig: [String: Any] {
        guard let url = Bundle.main.url(forResource: "app_config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// Guía por defecto de la configuración (para listas sin `url-tvg`).
    static var defaultEpgUrl: String? {
        if let own = UserDefaults.standard.string(forKey: "set.epgUrl"), !own.isEmpty { return own }       // recibida por transferencia
        return (bundledConfig["epgUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Se siembran una sola vez; después el usuario las añade, borra o activa a su gusto.
    private func seedDefaults() {
        // Cada lista por defecto se siembra una sola vez (las nuevas de versiones posteriores sí llegan; las borradas no vuelven)
        var seeded = Set(UserDefaults.standard.stringArray(forKey: "seededDefaults.v2") ?? [])
        if UserDefaults.standard.bool(forKey: "defaultsSeeded.v1") && seeded.isEmpty { seeded = Set(playlists.map { $0.url }) }
        defer { UserDefaults.standard.set(Array(seeded), forKey: "seededDefaults.v2") }
        let list = (Self.bundledConfig["playlists"] as? [[String: Any]]) ?? []
        var added = false
        for (i, p) in list.enumerated() {
            guard let url = (p["url"] as? String)?.trimmingCharacters(in: .whitespaces), !url.isEmpty,
                  !seeded.contains(url), !playlists.contains(where: { $0.url == url || $0.name == (p["name"] as? String) }) else { seeded.insert((p["url"] as? String) ?? ""); continue }
            seeded.insert(url)
            let name = ((p["name"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            playlists.append(PlaylistConfig(name: name.isEmpty ? "Lista \(i + 1)" : name, url: url))
            added = true
        }
        if added { save() }
    }

    // MARK: - Listas guardadas (UserDefaults)

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([PlaylistConfig].self, from: data) else { return }
        playlists = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func update(_ id: String, name: String, url: String, headers: [String: String]? = nil) {
        if let i = playlists.firstIndex(where: { $0.id == id }) {
            playlists[i].name = name; playlists[i].url = url
            if let h = headers { playlists[i].extraHeaders = h }
            save()
        }
    }
    func setEnabled(_ id: String, _ on: Bool) {
        if let i = playlists.firstIndex(where: { $0.id == id }) { playlists[i].enabled = on; save() }
    }
    /// Vuelve a añadir las listas que trae la app (las borradas) sin tocar las demás.
    func restoreDefaults() {
        for p in (Self.bundledConfig["playlists"] as? [[String: Any]]) ?? [] {
            if let n = p["name"] as? String, let u = p["url"] as? String, !playlists.contains(where: { $0.url == u || $0.name == n }) { playlists.append(PlaylistConfig(name: n, url: u)) }
        }
        save()
    }

    func add(name: String, url: String, headers: [String: String] = [:]) {
        playlists.append(PlaylistConfig(name: name, url: url, extraHeaders: headers))
        save()
    }

    /// Dirección real de una lista: las locales se guardan como `local:<fichero>` y se buscan en Documents
    /// (la ruta absoluta del contenedor cambia al reinstalar la app).
    static func resolve(_ raw: String) -> URL? {
        if raw.hasPrefix("local:") {
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(String(raw.dropFirst(6)))
        }
        return URL(string: directDownloadURL(raw))
    }

    /// Recibida por transferencia: sin la misma dirección → se añade; con el mismo nombre y otra dirección → se sustituye.
    /// Devuelve «added», «replaced» o «same».
    func addOrReplace(name: String, url: String, headers: [String: String] = [:]) -> String {
        if let i = playlists.firstIndex(where: { $0.url == url }) {
            // Misma dirección: si llegan cabeceras distintas se actualizan (cambiarlas en caliente desde el otro aparato)
            if playlists[i].extraHeaders != headers { playlists[i].extraHeaders = headers; save(); return "replaced" }
            return "same"
        }
        if let i = playlists.firstIndex(where: { $0.name == name }) { playlists[i].url = url; playlists[i].enabled = true; playlists[i].extraHeaders = headers; save(); return "replaced" }
        playlists.append(PlaylistConfig(name: name, url: url, extraHeaders: headers)); save(); return "added"
    }

    /// Crea o actualiza una lista local (mismo nombre): también arregla las que se guardaron con ruta absoluta.
    func upsertLocal(name: String, fileName: String, headers: [String: String] = [:]) {
        let url = "local:" + fileName
        if let i = playlists.firstIndex(where: { $0.name == name }) { playlists[i].url = url; playlists[i].extraHeaders = headers } else { playlists.append(PlaylistConfig(name: name, url: url, extraHeaders: headers)) }
        save()
    }

    /// Añade la lista si no existe ya (misma dirección). Devuelve si la añadió.
    @discardableResult
    func addIfMissing(name: String, url: String) -> Bool {
        guard !playlists.contains(where: { $0.url == url }) else { return false }
        playlists.append(PlaylistConfig(name: name, url: url)); save(); return true
    }

    func remove(at offsets: IndexSet) {
        playlists.remove(atOffsets: offsets)
        save()
    }

    // MARK: - Carga de canales

    /// Descarga la lista y reemplaza `channels` con su contenido.
    func open(_ playlist: PlaylistConfig) async {
        guard let url = Self.resolve(playlist.url) else {
            errorMessage = "Dirección no válida"; Trace.shared.log("lista", "\(playlist.name): dirección no válida"); return
        }
        Trace.shared.log("lista", "abriendo «\(playlist.name)»")
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            var req = URLRequest(url: url)
            if !url.isFileURL { req.setValue(DeviceId.playlistUserAgent, forHTTPHeaderField: "User-Agent") }     // como Android: dice qué aparato pide la lista
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let start = String(text.prefix(40)).replacingOccurrences(of: "\n", with: " ")
            Trace.shared.log("lista", "«\(playlist.name)» HTTP \(status) · \(data.count) bytes · empieza por: \(start)")
            let parsed = M3uParser.parse(text)
            let expanded = await Sublists.expand(parsed.channels, fetch: { try await self.fetchText($0) }, log: { Trace.shared.log("lista", $0) })
            // Cabeceras propias de la lista: mandan sobre las del fichero (User-Agent y Referer incluidos)
            channels = playlist.extraHeaders.isEmpty ? expanded : expanded.map { RequestHeaders.apply($0, extra: playlist.extraHeaders) }
            if !playlist.extraHeaders.isEmpty { Trace.shared.log("lista", "«\(playlist.name)»: \(playlist.extraHeaders.count) cabeceras propias aplicadas") }
            Trace.shared.log("lista", "«\(playlist.name)»: \(parsed.channels.count) canales · guía: \(parsed.epgUrl ?? Self.defaultEpgUrl ?? "ninguna")")
            if let guide = parsed.epgUrl ?? Self.defaultEpgUrl { Task { await loadEpg(guide) } }
        } catch {
            errorMessage = "No se pudo cargar la lista: \(error.localizedDescription)"
            Trace.shared.log("lista", "ERROR «\(playlist.name)»: \(error.localizedDescription)")
        }
    }

    /// Descarga una lista (o la lee, si es un fichero local) como texto.
    private func fetchText(_ raw: String) async throws -> String {
        guard let u = Self.resolve(raw) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        if !u.isFileURL { req.setValue(DeviceId.playlistUserAgent, forHTTPHeaderField: "User-Agent") }
        let (data, _) = try await URLSession.shared.data(for: req)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - Guía de programación (EPG)

    /// Fichero de la copia de la guía de una dirección (en la carpeta de cachés: el sistema puede borrarla si falta espacio, y no se copia a iCloud).
    static func epgCacheFile(for url: String) -> URL {
        var h: UInt64 = 5381
        for b in url.utf8 { h = (h &* 33) &+ UInt64(b) }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("epg-\(String(h, radix: 16)).json")
    }

    /// Descarga la guía XMLTV (gzip incluido) y se queda con los días atrás de Ajustes (para el catchup) y 36 h adelante de los canales de la lista.
    /// Caché: la guía ya analizada se guarda en disco. Al abrir la app se carga esa copia al instante (sin descargar ni analizar) y solo se vuelve
    /// a bajar si tiene más de 6 h o cambiaron los canales; entonces se enseña la copia vieja y se refresca por detrás. `force` salta la caché.
    func loadEpg(_ urlString: String, force: Bool = false) async {
        guard let url = URL(string: urlString.components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces)) else {
            Trace.shared.log("guia", "dirección de guía no válida"); return
        }
        let signature = "\(channels.count)|\(AppSettings.epgDays)"
        let cacheFile = Self.epgCacheFile(for: url.absoluteString)
        let store0 = epg
        if !force, let saved = try? Data(contentsOf: cacheFile) {
            let t0 = Date()
            let meta = await Task.detached(priority: .utility) { store0.restore(saved) }.value
            if let meta = meta {
                Trace.shared.log("guia", "copia leída en \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                epgReady = true
                let ageMin = (Int64(Date().timeIntervalSince1970 * 1000) - meta.savedAtMs) / 60_000
                Trace.shared.log("guia", "desde la copia guardada (hace \(ageMin) min, \(saved.count / 1024) KB)")
                if ageMin < 6 * 60, meta.signature == signature { return }
                Trace.shared.log("guia", "la copia está vieja o cambiaron los canales: se refresca por detrás")
            }
        }
        Trace.shared.log("guia", "descargando \(url.absoluteString)")
        do {
            let raw = try await URLSessionFetcher().fetch(url, headers: ["User-Agent": "Mozilla/5.0"])
            let xml = try Gzip.decompress(raw)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let wanted = channels
            // El análisis de guías grandes es pesado: fuera del hilo principal
            let store = epg
            await Task.detached(priority: .utility) {
                store.load(xml: xml, windowStartMs: now - Int64(AppSettings.epgDays) * 86_400_000, windowEndMs: now + 36 * 3_600_000, wanted: wanted)
            }.value
            epgReady = true
            // Copia en disco para la próxima vez
            let winStart = now - Int64(AppSettings.epgDays) * 86_400_000, winEnd = now + 36 * 3_600_000
            Task.detached(priority: .utility) {
                if let d = store.snapshot(signature: signature, windowStartMs: winStart, windowEndMs: winEnd) { try? d.write(to: cacheFile, options: .atomic) }
            }
            Trace.shared.log("guia", "cargada: \(xml.count) bytes; programa actual del primer canal: \(channels.first.flatMap { epg.current(for: $0)?.title } ?? "ninguno")")
        } catch {
            errorMessage = "No se pudo cargar la guía: \(error.localizedDescription)"
            Trace.shared.log("guia", "ERROR: \(error.localizedDescription)")
        }
    }
}

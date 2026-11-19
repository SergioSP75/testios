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

    func update(_ id: String, name: String, url: String) {
        if let i = playlists.firstIndex(where: { $0.id == id }) { playlists[i].name = name; playlists[i].url = url; save() }
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

    func add(name: String, url: String) {
        playlists.append(PlaylistConfig(name: name, url: url))
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
    func addOrReplace(name: String, url: String) -> String {
        if playlists.contains(where: { $0.url == url }) { return "same" }
        if let i = playlists.firstIndex(where: { $0.name == name }) { playlists[i].url = url; playlists[i].enabled = true; save(); return "replaced" }
        playlists.append(PlaylistConfig(name: name, url: url)); save(); return "added"
    }

    /// Crea o actualiza una lista local (mismo nombre): también arregla las que se guardaron con ruta absoluta.
    func upsertLocal(name: String, fileName: String) {
        let url = "local:" + fileName
        if let i = playlists.firstIndex(where: { $0.name == name }) { playlists[i].url = url } else { playlists.append(PlaylistConfig(name: name, url: url)) }
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
            channels = await expandSublists(parsed.channels, depth: 0)
            Trace.shared.log("lista", "«\(playlist.name)»: \(parsed.channels.count) canales · guía: \(parsed.epgUrl ?? Self.defaultEpgUrl ?? "ninguna")")
            if let guide = parsed.epgUrl ?? Self.defaultEpgUrl { Task { await loadEpg(guide) } }
        } catch {
            errorMessage = "No se pudo cargar la lista: \(error.localizedDescription)"
            Trace.shared.log("lista", "ERROR «\(playlist.name)»: \(error.localizedDescription)")
        }
    }

    /// Listas anidadas (entradas con type="playlist"): se descarga cada una y sus canales se añaden en un grupo con el nombre de la
    /// sublista (o «sublista - grupo» si traen grupo propio), como en Android. Hasta dos niveles; un fallo de una sublista no tumba el resto.
    private func expandSublists(_ list: [IptvChannel], depth: Int) async -> [IptvChannel] {
        guard list.contains(where: { $0.isPlaylistGroup }) else { return list }
        var out = list.filter { !$0.isPlaylistGroup }
        for sub in list where sub.isPlaylistGroup {
            guard depth < 2, let u = Self.resolve(sub.nestedUrl ?? sub.url) else { continue }
            do {
                var req = URLRequest(url: u)
                if !u.isFileURL { req.setValue(DeviceId.playlistUserAgent, forHTTPHeaderField: "User-Agent") }
                let (data, _) = try await URLSession.shared.data(for: req)
                let parsed = M3uParser.parse(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
                var inner = await expandSublists(parsed.channels, depth: depth + 1)
                for i in inner.indices {
                    let g = inner[i].group ?? ""
                    inner[i].group = g.isEmpty ? sub.name : "\(sub.name) - \(g)"
                }
                Trace.shared.log("lista", "sublista «\(sub.name)»: \(inner.count) canales")
                out += inner
            } catch {
                Trace.shared.log("lista", "ERROR sublista «\(sub.name)»: \(error.localizedDescription)")
            }
        }
        return out
    }

    // MARK: - Guía de programación (EPG)

    /// Descarga la guía XMLTV (gzip incluido) y se queda con los días atrás de Ajustes (para el catchup) y 36 h adelante de los canales de la lista.
    func loadEpg(_ urlString: String) async {
        guard let url = URL(string: urlString.components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces)) else {
            Trace.shared.log("guia", "dirección de guía no válida"); return
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
            Trace.shared.log("guia", "cargada: \(xml.count) bytes; programa actual del primer canal: \(channels.first.flatMap { epg.current(for: $0)?.title } ?? "ninguno")")
        } catch {
            errorMessage = "No se pudo cargar la guía: \(error.localizedDescription)"
            Trace.shared.log("guia", "ERROR: \(error.localizedDescription)")
        }
    }
}

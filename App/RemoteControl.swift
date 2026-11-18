import Foundation
import HLSCore

/// Una lista de mediateca (JSON de películas/series) guardada por el usuario.
struct MediaListConfig: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var url: String
    var enabled = true
}

/// Listas de mediateca del usuario (equivale a MediaListRepository de Android).
@MainActor
final class MediaLists: ObservableObject {
    static let shared = MediaLists()
    @Published var lists: [MediaListConfig] = []
    private let key = "mediaLists.v1"

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode([MediaListConfig].self, from: d) { lists = l }
    }
    private func save() { if let d = try? JSONEncoder().encode(lists) { UserDefaults.standard.set(d, forKey: key) } }

    /// Añade las que no estén ya (mismo nombre o misma dirección).
    func merge(_ incoming: [MediaListConfig]) {
        for m in incoming where !lists.contains(where: { $0.url == m.url || $0.name == m.name }) { lists.append(m) }
        save()
    }
    func remove(at offsets: IndexSet) { lists.remove(atOffsets: offsets); save() }

    /// Recibida por transferencia: misma dirección → «same»; mismo nombre y otra dirección → se sustituye («replaced»); si no, «added».
    func addOrReplace(name: String, url: String, enabled: Bool, force: Bool = false) -> String {
        if !force, lists.contains(where: { $0.url == url }) { return "same" }
        if let i = lists.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { lists[i].url = url; lists[i].enabled = enabled; save(); return "replaced" }
        lists.append(MediaListConfig(name: name, url: url, enabled: enabled)); save(); return "added"
    }
}

/// Órdenes desde el PC (`GET <servidor>/cmd` cada 2 s). Sirven para depurar sin tocar el iPad:
///  - `import`: manda las listas de canales y de mediateca del usuario (así no hace falta guardarlas en git).
///  - `play`: reproduce una dirección con sus claves y cabeceras.
///  - `trace`: pide una traza de estado (listas, canales cargados).
@MainActor
final class RemoteControl: ObservableObject {
    static let shared = RemoteControl()
    @Published var playRequest: IptvChannel?
    private weak var store: PlaylistStore?
    private var running = false

    func start(store: PlaylistStore) {
        self.store = store
        guard !running else { return }
        running = true
        Trace.shared.log("app", "iniciada · \(UIDeviceInfo.summary)")
        Task { while true { await poll(); try? await Task.sleep(nanoseconds: 2_000_000_000) } }
    }

    private func poll() async {
        guard let url = URL(string: Trace.shared.server + "/cmd") else { return }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let cmd = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = cmd["cmd"] as? String else { return }
        Trace.shared.log("remoto", "orden: \(name)")
        switch name {
        case "import": importConfig(cmd)
        case "play": play(cmd)
        case "download": if let ch = channel(from: cmd) { DownloadManager.shared.enqueue(channel: ch); Trace.shared.log("descarga", "en cola: \(ch.name)") }
        case "playlib": playFromLibrary(cmd)
        case "setmax": UserDefaults.standard.set((cmd["height"] as? Int) ?? 0, forKey: "set.maxHeight"); Trace.shared.log("remoto", "altura máxima = \((cmd["height"] as? Int) ?? 0)")
        case "dlstate": Trace.shared.log("descarga", DownloadManager.shared.jobs.map { "\($0.title): \($0.state) \(Int($0.progress * 100))% \($0.error ?? "")" }.joined(separator: " | "))
        // --- Simulación de lo que haría una persona en el reproductor y en descargas (para probar desde el PC) ---
        case "pstate": playerState()
        case "seek": if let m = PlayerModel.current { m.seek(to: (cmd["secs"] as? Double) ?? Double((cmd["secs"] as? Int) ?? 0)); Trace.shared.log("remoto", "seek a \((cmd["secs"] as? Int) ?? 0) s") }
        case "audio": remoteAudio((cmd["name"] as? String) ?? "")
        case "sub": remoteSub((cmd["name"] as? String) ?? "")
        case "quality": if let m = PlayerModel.current { let h = (cmd["height"] as? Int) ?? 0; Task { await m.setQuality(height: h) } }
        case "pause": PlayerModel.current?.player?.pause(); Trace.shared.log("remoto", "pausa")
        case "resume": PlayerModel.current?.player?.play(); Trace.shared.log("remoto", "reanudar")
        case "stop": playRequest = nil; Trace.shared.log("remoto", "reproductor cerrado")
        case "dlclear": DownloadManager.shared.removeAll()
        case "setpref": for (k, v) in (cmd["values"] as? [String: Any]) ?? [:] { UserDefaults.standard.set(v, forKey: k) }; Trace.shared.log("remoto", "ajustes cambiados: \(((cmd["values"] as? [String: Any]) ?? [:]).keys.sorted())")
        case "trace":
            Trace.shared.log("estado", "listas=\(store?.playlists.map { $0.name } ?? []) · mediateca=\(MediaLists.shared.lists.map { $0.name }) · canales cargados=\(store?.channels.count ?? 0)")
        default: Trace.shared.log("remoto", "orden desconocida: \(name)")
        }
    }

    /// Listas de canales y de mediateca que manda el PC.
    private func importConfig(_ cmd: [String: Any]) {
        var added = 0
        for p in (cmd["lists"] as? [[String: Any]]) ?? [] {
            let name = (p["name"] as? String) ?? "Lista"
            var url = (p["url"] as? String) ?? ""
            // Lista local del móvil: llega su contenido y se guarda como fichero propio
            if (p["isLocal"] as? Bool) == true, let content = p["content"] as? String {
                let fileName = "lista_\(name.replacingOccurrences(of: " ", with: "_")).m3u"
                let f = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(fileName)
                try? content.write(to: f, atomically: true, encoding: .utf8)
                store?.upsertLocal(name: name, fileName: fileName)
                added += 1
                continue
            }
            if !url.isEmpty, store?.addIfMissing(name: name, url: url) == true { added += 1 }
        }
        let media = ((cmd["media"] as? [[String: Any]]) ?? []).compactMap { m -> MediaListConfig? in
            guard let u = m["url"] as? String, !u.isEmpty else { return nil }
            return MediaListConfig(name: (m["name"] as? String) ?? "Mediateca", url: u)
        }
        MediaLists.shared.merge(media)
        Trace.shared.log("remoto", "importadas \(added) listas de canales y \(media.count) de mediateca")
    }

    private func channel(from cmd: [String: Any]) -> IptvChannel? {
        guard let url = cmd["url"] as? String else { return nil }
        let name = (cmd["name"] as? String) ?? "Remoto"
        var ch = IptvChannel(id: (cmd["id"] as? String) ?? "remoto-\(name)", name: name, url: url)
        ch.clearKeys = parseClearKeysHexMap(cmd["keys"] as? String)
        ch.httpHeaders = (cmd["headers"] as? [String: String]) ?? [:]
        ch.userAgent = cmd["userAgent"] as? String
        ch.referrer = cmd["referrer"] as? String
        return ch
    }

    private func play(_ cmd: [String: Any]) { playRequest = channel(from: cmd) }

    /// Busca un título en la mediateca cargada (por nombre y plataforma) y lo reproduce o lo descarga: prueba el camino real de la app.
    /// `season`/`episode` eligen capítulo en las series (por defecto el primero).
    private func playFromLibrary(_ cmd: [String: Any]) {
        let q = (cmd["query"] as? String) ?? ""
        let lib = MediaHub.shared.library
        let found = lib.filter(series: cmd["series"] as? Bool, platformKey: (cmd["platform"] as? String).map(MediaText.platformKey), query: q, sort: .name)
        // Si hay un título que se llama exactamente así, ese: «Superman» no es «Batman v Superman»
        let exact = found.first { $0.name.lowercased() == q.lowercased() }
        guard let item = exact ?? found.first else { Trace.shared.log("remoto", "playlib: sin resultados para «\(q)» (mediateca \(lib.items.count) títulos)"); return }
        var ch = item.asChannel
        if item.isSeries {
            let s = (cmd["season"] as? Int) ?? item.seasons.first?.number ?? 1
            let e = (cmd["episode"] as? Int) ?? 1
            guard let ep = item.seasons.first(where: { $0.number == s })?.episodes.first(where: { $0.number == e }) ?? item.seasons.first?.episodes.first else { return }
            ch = ep.asChannel(series: item.name, headers: item.headers)
        }
        Trace.shared.log("remoto", "playlib: «\(item.name)» [\(item.category ?? "?")] → \(ch.name)")
        if (cmd["download"] as? Bool) == true {
            // Con «options» se simula la ventana de descarga: {"height":720,"audio":["es"],"subs":["en"]}
            var o = DownloadOptions.defaults
            if let d = cmd["options"] as? [String: Any] {
                if let h = d["height"] as? Int { o.height = h }
                if let a = d["audio"] as? [String] { o.audioLangs = a }
                if let sb = d["subs"] as? [String] { o.subLangs = sb }
            }
            DownloadManager.shared.enqueue(channel: ch, options: o)
        } else { playRequest = ch }
    }

    /// Estado del reproductor en una sola línea de traza.
    private func playerState() {
        guard let m = PlayerModel.current else { Trace.shared.log("pstate", "sin reproductor"); return }
        let p = m.player
        let aud = m.audioChoices.map { ($0.selected ? "*" : "") + $0.name }.joined(separator: ",")
        let all = m.allAudio.map { ($0.selected ? "*" : "") + $0.name + ($0.isDescription ? "(AD)" : "") + "@" + $0.group }.joined(separator: ",")
        let subs = m.subtitleChoices.filter { $0.selected }.map { $0.name }
        let spanish = m.subtitleChoices.filter { $0.name.lowercased().contains("spa") || $0.name.lowercased().contains("esp") }.map { $0.name }
        Trace.shared.log("pstate", "t=\(Int(m.lastTime)) s de \(Int(m.duration)) · \(p?.timeControlStatus == .playing ? "suena" : "no suena") · audio activo=\(m.audioInfo) · opciones del reproductor=[\(aud)] · todas=[\(all)] · subtítulos=\(m.subtitleChoices.count) elegido=\(subs) · españoles=\(spanish) · texto=«\(m.subtitleText.prefix(30))» · calidad=\(m.qualityText) · error=\(m.errorText ?? "ninguno")")
    }
    private func remoteAudio(_ name: String) {
        guard let m = PlayerModel.current else { return }
        let n = name.lowercased()
        if let e = m.allAudio.first(where: { $0.name.lowercased().contains(n) }) { Trace.shared.log("remoto", "elijo audio «\(e.name)» (grupo \(e.group))"); m.chooseAudio(e) }
        else { Trace.shared.log("remoto", "audio «\(name)» no existe") }
    }
    private func remoteSub(_ name: String) {
        guard let m = PlayerModel.current else { return }
        if name.isEmpty || name == "none" { m.selectSubtitle(nil); Trace.shared.log("remoto", "sin subtítulos"); return }
        let n = name.lowercased()
        if let c = m.subtitleChoices.first(where: { $0.name.lowercased().contains(n) }) { Trace.shared.log("remoto", "elijo subtítulo «\(c.name)»"); m.selectSubtitle(c.id) }
        else { Trace.shared.log("remoto", "subtítulo «\(name)» no existe") }
    }
}

#if canImport(UIKit)
import UIKit
enum UIDeviceInfo { @MainActor static var summary: String { "\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)" } }
#else
enum UIDeviceInfo { static var summary: String { "?" } }
#endif

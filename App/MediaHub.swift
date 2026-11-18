import Foundation
import SwiftUI
import HLSCore

/// Todo el contenido de la mediateca: carga todas las listas activas en segundo plano y las va sumando
/// (equivale a MediaLibrary de Android). Las pantallas se redibujan según llegan los títulos.
@MainActor
final class MediaHub: ObservableObject {
    static let shared = MediaHub()
    @Published var library = MediaLibrary([])
    @Published var loading = false
    @Published var status = ""
    private var loadedSignature = ""

    /// Carga (o recarga si cambiaron las listas) todas las listas activas.
    func loadAll(force: Bool = false) async {
        // Tarea propia: si la pantalla que la pidió se cierra, la carga sigue (antes salía «cancelled»)
        await Task { await self.doLoadAll(force: force) }.value
    }

    private func doLoadAll(force: Bool) async {
        let lists = MediaLists.shared.lists.filter { $0.enabled }
        let signature = lists.map { $0.url }.joined(separator: "|")
        guard !loading, force || signature != loadedSignature, !lists.isEmpty else { return }
        loading = true; loadedSignature = signature
        defer { loading = false; status = "" }
        var all: [MediaItem] = []
        for l in lists {
            status = "Cargando «\(l.name)»…"
            do {
                var data0 = Data()
                if l.url.hasPrefix("local:") {
                    // Mediateca recibida por transferencia: fichero propio en Documents
                    guard let f = PlaylistStore.resolve(l.url) else { continue }
                    data0 = try Data(contentsOf: f)
                } else {
                    guard let url = URL(string: directDownloadURL(l.url)) else { continue }
                    var req = URLRequest(url: url, timeoutInterval: 600)       // hay listas de más de 60 MB
                    req.setValue(DeviceId.playlistUserAgent, forHTTPHeaderField: "User-Agent")
                    let (d, resp) = try await URLSession.shared.data(for: req)
                    if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw NSError(domain: "HTTP", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(h.statusCode)"]) }
                    data0 = d
                }
                var data = data0
                if Gzip.isGzip(data), let un = try? Gzip.decompress(data) { data = un }
                let id = l.id
                // El análisis de listas grandes es pesado: fuera del hilo principal
                let items = await Task.detached(priority: .userInitiated) { MediaCatalog.parse(data, sourceId: id) }.value
                Trace.shared.log("mediateca", "«\(l.name)»: \(data.count) bytes → \(items.count) títulos (\(items.filter { $0.isSeries }.count) series)")
                all += items
                library = MediaLibrary(all)
            } catch {
                Trace.shared.log("mediateca", "ERROR «\(l.name)»: \(error.localizedDescription)")
            }
        }
    }

    // Selecciones para las filas de inicio

    /// Los títulos del carrusel superior: los más recientes con imagen grande y sinopsis, de plataformas variadas.
    func featuredList(limit: Int = 8) -> [MediaItem] {
        // Al azar (cambia cada vez que se abre la mediateca), no siempre lo más reciente
        let pool = library.items.filter { $0.backdrop != nil && $0.plot != nil }.shuffled()
        var out: [MediaItem] = [], perPlatform: [String: Int] = [:]
        for it in pool where perPlatform[it.platformKey, default: 0] < 2 {
            out.append(it); perPlatform[it.platformKey, default: 0] += 1
            if out.count >= limit { break }
        }
        return out.isEmpty ? Array(library.items.prefix(limit)) : out
    }

    var featured: MediaItem? {
        library.items.filter { $0.backdrop != nil && $0.plot != nil }.max { $0.added < $1.added }
            ?? library.items.max { $0.added < $1.added }
    }
    func recent(series: Bool?, limit: Int = 30) -> [MediaItem] { Array(library.filter(series: series, sort: .added).prefix(limit)) }
    /// «Top 10»: los mejor valorados entre lo añadido recientemente.
    func top10() -> [MediaItem] {
        let pool = library.items.filter { Double($0.rating ?? "") != nil }
        let best = pool.sorted { (Double($0.rating ?? "") ?? 0) > (Double($1.rating ?? "") ?? 0) }
        return Array((best.isEmpty ? recent(series: nil, limit: 10) : best).prefix(10))
    }
    func item(forKey k: String) -> MediaItem? { library.items.first { MediaFavorites.key($0) == k } }
}

/// Favoritos (estrella): se identifican por plataforma, título y año (el id cambia con el orden de las listas).
@MainActor
final class MediaFavorites: ObservableObject {
    static let shared = MediaFavorites()
    @Published private(set) var keys: Set<String>
    private let store = "mediaFavorites.v1"
    private init() { keys = Set(UserDefaults.standard.stringArray(forKey: "mediaFavorites.v1") ?? []) }

    static func key(_ i: MediaItem) -> String { "\(i.platformKey)|\(MediaText.norm(i.name))|\(i.year ?? 0)" }
    func isFavorite(_ i: MediaItem) -> Bool { keys.contains(Self.key(i)) }
    func toggle(_ i: MediaItem) {
        let k = Self.key(i)
        if keys.contains(k) { keys.remove(k) } else { keys.insert(k) }
        UserDefaults.standard.set(Array(keys), forKey: store)
    }
}

/// «Seguir viendo»: posición de cada película o capítulo para continuar donde se dejó.
@MainActor
final class MediaProgress: ObservableObject {
    static let shared = MediaProgress()
    struct Entry: Codable { var itemKey: String; var pos: Double; var dur: Double; var at: Date }
    @Published private(set) var entries: [String: Entry]       // por id del canal reproducido
    private let store = "mediaProgress.v1"
    private init() {
        if let d = UserDefaults.standard.data(forKey: "mediaProgress.v1"), let e = try? JSONDecoder().decode([String: Entry].self, from: d) { entries = e } else { entries = [:] }
    }

    func save(channelId: String, itemKey: String, pos: Double, dur: Double) {
        guard dur > 60 else { return }
        if pos / dur > 0.95 { entries[channelId] = nil } else if pos > 20 { entries[channelId] = Entry(itemKey: itemKey, pos: pos, dur: dur, at: Date()) }
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: store) }
    }
    func position(channelId: String) -> Double { entries[channelId]?.pos ?? 0 }
    /// Claves de título con algo a medias, lo más reciente primero.
    var continueKeys: [String] {
        var seen = Set<String>(); return entries.values.sorted { $0.at > $1.at }.map { $0.itemKey }.filter { seen.insert($0).inserted }
    }
}

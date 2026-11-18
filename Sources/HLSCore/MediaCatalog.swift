import Foundation

// Mediateca: películas y series de listas JSON (port de MediaCatalog.kt de Android).
//
// Formato PELÍCULAS (lista plana):
//   [ { name, category (plataforma), id, video, drm, drmkey, info: { year, poster, plot, genre[], duration (ms), cast[]… } } ]
// Formato SERIES (serie → temporadas → capítulos):
//   [ { name, category, info: {…}, seasons: [ { season, episodes: [ { episode, name, video, drm, drmkey, info: {…} } ] } ] } ]
// El tipo de cada elemento se deduce de su estructura (tiene "seasons" → serie; tiene "video" → película).

/// Un capítulo de una serie.
public struct MediaEpisode: Identifiable, Equatable {
    public var id: String { "\(season)x\(number)" }
    public var season: Int
    public var number: Int
    public var name: String
    public var plot: String
    public var poster: String?
    public var durationSec: Int64
    public var video: String
    public var drm: String
    public var drmKey: String

    /// Canal equivalente para reproducirlo con el mismo flujo que un directo (relay incluido).
    public func asChannel(series: String, headers: [String: String] = [:]) -> IptvChannel {
        MediaItem.makeChannel(id: "\(series)-\(id)", name: "\(series) T\(season)E\(number)", url: video, drm: drm, drmKey: drmKey, poster: poster, headers: headers)
    }
}

public struct MediaSeason: Identifiable, Equatable {
    public var id: Int { number }
    public var number: Int
    public var episodes: [MediaEpisode]
}

/// Película o serie de la Mediateca.
public struct MediaItem: Identifiable, Equatable {
    /// Dos fichas son la misma si tienen el mismo id (comparar todos los capítulos en cada redibujado congelaba la pantalla).
    public static func == (a: MediaItem, b: MediaItem) -> Bool { a.id == b.id }
    public var id: String
    public var name: String
    public var url: String                 // vídeo de la película (vacío en una serie)
    public var category: String?           // plataforma tal como viene
    public var platformKey: String
    public var drm: String?
    public var drmKey: String?
    public var poster: String?
    public var backdrop: String?
    public var plot: String?
    public var year: Int?
    public var headers: [String: String]
    public var genres: [String] = []
    public var rating: String?
    public var durationSec: Int64 = 0
    public var added: Int64 = 0
    public var trailer: String?
    public var cast: [String] = []
    public var director: [String] = []
    public var country: [String] = []
    public var isSeries = false
    public var seasons: [MediaSeason] = []

    public var episodeCount: Int { seasons.reduce(0) { $0 + $1.episodes.count } }
    /// Texto normalizado (sin tildes, minúsculas) para el buscador y nombre normalizado para ordenar: se calculan una vez al leer.
    public var searchKey = ""
    public var nameKey = ""
    mutating func computeKeys() {
        nameKey = MediaText.norm(name)
        searchKey = MediaText.norm("\(name) \(category ?? "") \(genres.joined(separator: " ")) \(year.map(String.init) ?? "") \(cast.joined(separator: " ")) \(director.joined(separator: " "))")
    }

    /// Canal equivalente para reproducir la película con el mismo flujo que un directo (relay incluido).
    public var asChannel: IptvChannel {
        Self.makeChannel(id: id, name: name, url: url, drm: drm ?? "", drmKey: drmKey ?? "", poster: poster, headers: headers, group: category)
    }

    static func makeChannel(id: String, name: String, url: String, drm: String, drmKey: String, poster: String?,
                            headers: [String: String], group: String? = nil) -> IptvChannel {
        let keys = parseClearKeysHexMap(drmKey)
        var ch = IptvChannel(id: id, name: name, url: url, group: group, m3uLogo: poster,
                             httpHeaders: headers, clearKeys: keys,
                             clearKeyJson: KodiPropParser.normalizeClearKeyToJson(drmKey),
                             licenseType: drm.isEmpty ? nil : drm, drmMode: keys.isEmpty ? .none : .clearkey)
        ch.userAgent = headers["User-Agent"]; ch.referrer = headers["Referer"]
        return ch
    }
}

/// Textos de la mediateca: normalización para buscar, nombres de plataforma, títulos limpios.
public enum MediaText {
    public static let noGenre = "Otros"

    public static func norm(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "DISNEY+" y "disney" son la misma plataforma.
    public static func platformKey(_ raw: String) -> String {
        var k = norm(raw).replacingOccurrences(of: "+", with: "plus")
        k = String(k.unicodeScalars.filter { ("a"..."z").contains(Character($0)) || ("0"..."9").contains(Character($0)) })
        if k.hasSuffix("plus") { k = String(k.dropLast(4)) }
        return k.isEmpty ? "otras" : k
    }

    /// Entre dos escrituras de una plataforma, cuál se muestra: más mayúsculas, luego más larga.
    static func betterLabel(_ a: String, _ b: String) -> Bool {
        let ua = a.filter { $0.isUppercase }.count, ub = b.filter { $0.isUppercase }.count
        return ua != ub ? ua > ub : a.count > b.count
    }

    /// "T1:E3 Título" → "Título".
    public static func cleanEpisodeName(_ n: String) -> String {
        let r = n.replacingOccurrences(of: "^\\s*[Tt]\\d+\\s*[:\\-]?\\s*[Ee]\\d+\\s*[:\\-]?\\s*", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return r.isEmpty ? n.trimmingCharacters(in: .whitespaces) : r
    }

    /// "100,000 Acres (2020)" → "100,000 Acres".
    public static func cleanMovieTitle(_ n: String) -> String {
        let r = n.replacingOccurrences(of: "\\s*\\(\\d{4}\\)\\s*$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return r.isEmpty ? n.trimmingCharacters(in: .whitespaces) : r
    }

    /// Línea de datos de una ficha: año · valoración · duración o temporadas · plataforma · géneros.
    public static func summary(_ i: MediaItem) -> String {
        var parts: [String] = []
        if let y = i.year { parts.append(String(y)) }
        if let r = i.rating, !r.isEmpty { parts.append("★ \(r)") }
        if i.isSeries { parts.append("\(i.seasons.count) temp. · \(i.episodeCount) cap.") }
        else if i.durationSec > 0 { parts.append(duration(i.durationSec)) }
        if let c = i.category, !c.isEmpty { parts.append(c) }
        if !i.genres.isEmpty { parts.append(i.genres.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    public static func duration(_ sec: Int64) -> String {
        if sec <= 0 { return "" }
        let h = sec / 3600, m = (sec % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(max(m, 1)) min"
    }
}

public struct MediaFacet: Identifiable, Equatable {
    public var key: String, label: String, count: Int
    public var id: String { key }
}

/// Criterios de orden de la mediateca. `year`, `name` y `added` son los clásicos (año nuevo primero, A–Z, recién añadido primero).
public enum MediaSort: String, CaseIterable {
    case added, year, name
    case addedOldest, yearOldest, nameDesc, rating, duration, episodes
    /// Texto para el menú de orden.
    public var label: String {
        switch self {
        case .added: return "Recién añadido"; case .addedOldest: return "Más antiguo añadido"
        case .year: return "Año (nuevo primero)"; case .yearOldest: return "Año (antiguo primero)"
        case .name: return "Título A–Z"; case .nameDesc: return "Título Z–A"
        case .rating: return "Mejor valoradas"; case .duration: return "Más largas"; case .episodes: return "Más capítulos"
        }
    }
}

/// Todo el contenido cargado, con sus plataformas, géneros y búsquedas (MediaCatalog de Android).
public struct MediaLibrary {
    public let items: [MediaItem]
    public init(_ items: [MediaItem]) {
        self.items = items
        var best: [String: String] = [:]
        for i in items {
            let label = i.category ?? "Sin plataforma"
            if let cur = best[i.platformKey] { if MediaText.betterLabel(label, cur) { best[i.platformKey] = label } } else { best[i.platformKey] = label }
        }
        names = best
    }
    private let names: [String: String]

    public var movieCount: Int { items.filter { !$0.isSeries }.count }
    public var seriesCount: Int { items.filter { $0.isSeries }.count }
    public func platformLabel(_ key: String) -> String { names[key] ?? key }

    /// Plataformas con contenido del tipo pedido, de mayor a menor número de elementos.
    public func platforms(series: Bool?) -> [MediaFacet] {
        var counts: [String: Int] = [:]
        for i in items where series == nil || i.isSeries == series! { counts[i.platformKey, default: 0] += 1 }
        return counts.map { MediaFacet(key: $0.key, label: platformLabel($0.key), count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label.lowercased() < $1.label.lowercased() }
    }

    /// Géneros del tipo (y plataforma, si se indica). El género vacío se agrupa como «Otros».
    public func genres(series: Bool?, platformKey: String?) -> [MediaFacet] {
        var counts: [String: Int] = [:]
        for i in items {
            if let s = series, i.isSeries != s { continue }
            if let p = platformKey, i.platformKey != p { continue }
            for g in (i.genres.isEmpty ? [MediaText.noGenre] : i.genres) { counts[g, default: 0] += 1 }
        }
        return counts.map { MediaFacet(key: $0.key, label: $0.key, count: $0.value) }.sorted {
            if ($0.label != MediaText.noGenre) != ($1.label != MediaText.noGenre) { return $0.label != MediaText.noGenre }
            return $0.count != $1.count ? $0.count > $1.count : $0.label.lowercased() < $1.label.lowercased()
        }
    }

    public func filter(series: Bool? = nil, platformKey: String? = nil, genre: String? = nil, query: String = "", sort: MediaSort = .added) -> [MediaItem] {
        let terms = MediaText.norm(query).split(separator: " ").map(String.init)
        let list = items.filter { i in
            (series == nil || i.isSeries == series!) && (platformKey == nil || i.platformKey == platformKey!)
                && (genre == nil || (genre! == MediaText.noGenre ? i.genres.isEmpty : i.genres.contains(genre!)))
                && terms.allSatisfy { i.searchKey.contains($0) }
        }
        // En todos los criterios, a igualdad se desempata por título para que el orden sea estable
        func by<T: Comparable>(_ v: @escaping (MediaItem) -> T, desc: Bool) -> [MediaItem] {
            list.sorted { v($0) != v($1) ? (desc ? v($0) > v($1) : v($0) < v($1)) : $0.nameKey < $1.nameKey }
        }
        switch sort {
        case .year: return by({ $0.year ?? 0 }, desc: true)
        case .yearOldest: return by({ $0.year ?? Int.max }, desc: false)       // sin año al final
        case .name: return list.sorted { $0.nameKey < $1.nameKey }
        case .nameDesc: return list.sorted { $0.nameKey > $1.nameKey }
        case .added: return by({ $0.added }, desc: true)
        case .addedOldest: return by({ $0.added == 0 ? Int64.max : $0.added }, desc: false)
        case .rating: return by({ Double($0.rating ?? "") ?? 0 }, desc: true)
        case .duration: return by({ $0.durationSec }, desc: true)
        case .episodes: return by({ $0.episodeCount }, desc: true)
        }
    }
}

public enum MediaCatalog {

    /// Lee una lista de Mediateca (película o serie, plana o en objeto con listas). Tolera comas finales y campos que cambian de tipo.
    /// `sourceId` prefija el identificador de cada elemento para que sea único entre listas.
    public static func parse(_ data: Data, sourceId: String = "") -> [MediaItem] {
        guard let root = loadJSON(data) else { return [] }
        var elements: [[String: Any]] = []
        if let arr = root as? [Any] { elements = arr.compactMap { $0 as? [String: Any] } }
        else if let obj = root as? [String: Any] { for (_, v) in obj { if let arr = v as? [Any] { elements += arr.compactMap { $0 as? [String: Any] } } } }
        var out: [MediaItem] = []
        for (idx, e) in elements.enumerated() {
            if let item = toItem(e, key: "\(sourceId)#\(idx)") { out.append(item) }
        }
        return out
    }

    /// JSON estricto y, si falla (comas finales, llaves sobrantes), reparado.
    private static func loadJSON(_ data: Data) -> Any? {
        var d = data
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }
        if let j = try? JSONSerialization.jsonObject(with: d) { return j }
        guard var text = String(data: d, encoding: .utf8) else { return nil }
        text = text.replacingOccurrences(of: ",\\s*([\\]}])", with: "$1", options: .regularExpression)
        return try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    // MARK: Ayudas de lectura (los campos cambian de tipo entre listas)

    private static func str(_ v: Any?) -> String? {
        guard let v = v, !(v is NSNull) else { return nil }
        let t = "\(v)".trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    private static func str(_ m: [String: Any], _ keys: String...) -> String { for k in keys { if let s = str(m[k]) { return s } }; return "" }
    private static func num(_ v: Any?) -> Int64 { Int64(Double(str(v) ?? "") ?? 0) }
    private static func year(_ v: Any?) -> Int? { let y = Int(num(v)); return (1888...2100).contains(y) ? y : nil }
    private static func flat(_ v: Any?) -> [String] {
        var out: [String] = []
        func walk(_ x: Any?) {
            if let s = x as? String { out += s.split(whereSeparator: { ",/".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            else if let a = x as? [Any] { a.forEach(walk) }
        }
        walk(v)
        var seen = Set<String>(); return out.filter { seen.insert($0).inserted }
    }

    private static func toItem(_ m: [String: Any], key: String) -> MediaItem? {
        let info = m["info"] as? [String: Any] ?? [:]
        // El título puede estar en name, en info.title o, en la lista de Max, solo en info
        guard let name = str(m["name"]) ?? str(m["title"]) ?? str(info["title"]) ?? str(m["ID"]) else { return nil }
        var platform: String?
        if let c = m["category"] as? [String: Any] { platform = str(c["name"]) } else { platform = str(m["category"]) ?? str(m["platform"]) ?? str(m["provider"]) }
        var headers: [String: String] = [:]
        if let h = m["headers"] as? [String: Any] { for (k, v) in h { headers[k] = "\(v)" } }
        let trailer = str(info["trailer"]) ?? str(m["trailer"])
        let rating = str(info["rating"]).flatMap { (Double($0) ?? 0) > 0 ? $0 : nil }
        let genres = flat(info["genre"])

        var item = MediaItem(id: key, name: name, url: "", category: platform, platformKey: MediaText.platformKey(platform ?? "Sin plataforma"),
                             drm: nil, drmKey: nil, poster: str(info["poster"]), backdrop: str(info["backdrop"]) ?? str(info["bg"]),
                             plot: str(info["plot"]), year: year(info["year"]), headers: headers)
        item.genres = genres; item.rating = rating; item.trailer = trailer
        item.cast = flat(info["cast"]); item.director = flat(info["director"]); item.country = flat(info["country"])

        if let seasonsRaw = m["seasons"] as? [Any] {
            var bySeason: [Int: [MediaEpisode]] = [:]
            var added: Int64 = 0
            for (si, sRaw) in seasonsRaw.enumerated() {
                guard let s = sRaw as? [String: Any] else { continue }
                let sn = Int(num(s["season"])) > 0 ? Int(num(s["season"])) : si + 1
                for (ei, eRaw) in ((s["episodes"] as? [Any]) ?? []).enumerated() {
                    guard let e = eRaw as? [String: Any] else { continue }
                    let einfo = e["info"] as? [String: Any] ?? [:]
                    let video = str(e, "video", "url"); if video.isEmpty { continue }
                    added = max(added, num(einfo["added"]), num(einfo["add"]))
                    bySeason[sn, default: []].append(MediaEpisode(
                        season: sn, number: Int(num(e["episode"])) > 0 ? Int(num(e["episode"])) : ei + 1,
                        name: MediaText.cleanEpisodeName(str(e, "name", "title")), plot: str(einfo["plot"]) ?? "",
                        poster: str(einfo["poster"]), durationSec: num(einfo["duration"]), video: video,
                        drm: str(e, "drm"), drmKey: str(e, "drmkey")))
                }
            }
            // Los ficheros repiten capítulos y hasta temporadas: se unen por número y se queda el primero de cada capítulo
            let seasons = bySeason.keys.sorted().map { n -> MediaSeason in
                var seen = Set<Int>()
                let eps = bySeason[n]!.filter { seen.insert($0.number).inserted }.sorted { $0.number < $1.number }
                return MediaSeason(number: n, episodes: eps)
            }.filter { !$0.episodes.isEmpty }
            if seasons.isEmpty { return nil }
            item.isSeries = true; item.seasons = seasons
            if item.plot == nil { item.plot = seasons[0].episodes[0].plot.isEmpty ? nil : seasons[0].episodes[0].plot }
            if item.poster == nil { item.poster = seasons.flatMap { $0.episodes }.compactMap { $0.poster }.first }
            item.added = max(added, num(info["added"]), num(info["add"]))
            item.computeKeys()
            return item
        }

        let video = str(m, "video", "url"); if video.isEmpty { return nil }
        item.url = video; item.drm = str(m["drm"]); item.drmKey = str(m["drmkey"])
        item.name = MediaText.cleanMovieTitle(name)
        // Sin «year» en la ficha, el año suele ir al final del título: «Título (2013)»
        if item.year == nil, let r = name.range(of: "\\((\\d{4})\\)\\s*$", options: .regularExpression) {
            item.year = year(String(name[r]).trimmingCharacters(in: CharacterSet(charactersIn: "() ")))
        }
        let raw = num(info["duration"])
        item.durationSec = raw > 100_000 ? raw / 1000 : raw          // películas en milisegundos
        item.added = max(num(info["added"]), num(info["add"]))
        item.computeKeys()
        return item
    }
}

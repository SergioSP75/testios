import Foundation

// Modelos y contrato común de los servidores externos (Emby, Jellyfin, Plex).
// Port de EmbyClient.kt / PlexClient.kt: la pantalla pide bibliotecas, elementos, temporadas, imágenes y la
// dirección de reproducción de la misma manera, sea cual sea el servidor.

/// Un elemento del servidor: película, serie, temporada, capítulo o carpeta.
public struct EmbyItem: Identifiable, Equatable {
    public var id: String
    public var name: String
    /// "Movie", "Series", "Season", "Episode", "CollectionFolder", "BoxSet"…
    public var type: String
    public var year: Int = 0
    public var overview: String = ""
    public var genres: [String] = []
    public var rating: String?
    public var runtimeSec: Int64 = 0
    public var hasPoster = false
    public var seasonNumber = 0
    public var episodeNumber = 0
    public var seriesName = ""
    public var collectionType = ""
    public var resumeSec: Int64 = 0
    /// Solo Plex: ruta de la carátula en el servidor.
    public var thumb = ""
    /// Cuenta de la que viene (clave de la cuenta: «emby», «emby_2»…). Se rellena en la vista mezclada.
    public var source = ""

    public init(id: String, name: String, type: String) { self.id = id; self.name = name; self.type = type }

    public var isFolder: Bool { ["CollectionFolder", "Folder", "BoxSet", "UserView", "Playlist"].contains(type) }
    public var isSeries: Bool { type == "Series" }
    public var isPlayable: Bool { ["Movie", "Episode", "Video", "MusicVideo"].contains(type) }
}

public struct EmbyPage { public var items: [EmbyItem]; public var total: Int }

/// Ajustes de emisión: reproducción directa o recodificada por el servidor (HLS).
public struct EmbyStreamSettings: Codable, Equatable {
    public var transcode = false
    public var maxMbps = 0            // 0 = sin tope; si > 0 se fuerza HLS
    public var audioLang = ""
    public var subLang = ""
    public var surround = false
    public var allowHevc = false
    public init() {}
}

/// Una opción de emisión elegible desde el reproductor («Calidad», «Audio» o «Subtítulos»).
public struct StreamChoice: Equatable { public var section: String; public var label: String; public var id: String }
public struct StreamParams { public var mbps = 0; public var audioId: String?; public var subId: String?
    public init(mbps: Int = 0, audioId: String? = nil, subId: String? = nil) { self.mbps = mbps; self.audioId = audioId; self.subId = subId } }

public enum ServerSort { case name, year, added }
public struct ServerFilter { public var sort: ServerSort = .name; public var genre: String?
    public init(sort: ServerSort = .name, genre: String? = nil) { self.sort = sort; self.genre = genre } }

public struct ServerError: Error, LocalizedError {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// User agent para servidores externos. Debe empezar por «Mozilla»: el relé de los .strm solo entrega DASH con claves
/// ClearKey en ese caso; con otro entrega HLS SAMPLE-AES-CTR (así falló «Avatar: El sentido del agua»). Lleva el nombre
/// de la app para que un proxy pueda distinguirla.
/// Se cambia en Ajustes → Servidores (clave «set.serverUa»); vacío = el de por defecto.
public enum ServerUa {
    public static let defaultValue = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 mediakiller-sp75 MediaKillerSP75"
    static let key = "set.serverUa"

    /// El user agent vigente (el del usuario o el de por defecto).
    public static var standard: String {
        get {
            let v = (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? defaultValue : v
        }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty || v == defaultValue { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(v, forKey: key) }
        }
    }

    /// Servidores (host:puerto) con los que ya se ha hablado: a sus direcciones de vídeo se les pone también este user agent.
    private static var hosts = Set<String>()
    private static let lock = NSLock()
    private static func hostOf(_ url: String) -> String? {
        guard let u = URL(string: url), let h = u.host else { return nil }
        return "\(h):\(u.port ?? (u.scheme == "https" ? 443 : 80))"
    }
    /// Apunta el servidor de `url` como servidor externo.
    public static func remember(_ url: String) { if let h = hostOf(url) { lock.lock(); hosts.insert(h); lock.unlock() } }
    /// El user agent para `url` si es de un servidor externo conocido; si no, nil (queda el de siempre).
    public static func forUrl(_ url: String) -> String? {
        guard let h = hostOf(url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return hosts.contains(h) ? standard : nil
    }
}

/// Red para los clientes (URLSession en la app; simulada en las pruebas).
public protocol ServerHTTP {
    func send(url: String, method: String, body: Data?, headers: [String: String], timeout: TimeInterval) async throws -> (status: Int, data: Data)
}

/// Almacén de pequeños ajustes (UserDefaults en la app, memoria en las pruebas).
public protocol KeyValueStore: AnyObject {
    func string(_ key: String) -> String?
    func set(_ value: String?, for key: String)
}

public final class MemoryStore: KeyValueStore {
    private var d: [String: String] = [:]
    public init() {}
    public func string(_ key: String) -> String? { d[key] }
    public func set(_ value: String?, for key: String) { d[key] = value }
}

/// Lo que necesita la pantalla «Servidor externo» de un servidor.
public protocol ServerBackend: AnyObject {
    /// Identificador de la cuenta («emby», «jellyfin_2», «plex»…): prefijo de ids y clave de sesión.
    var kind: String { get }
    var type: String { get }                 // «emby», «jellyfin» o «plex»
    var icon: String { get }                 // 🟩 Emby, 🟪 Jellyfin, 🟧 Plex
    func hasSession() -> Bool
    func serverLabel() -> String
    func logout()
    func libraries() async throws -> [EmbyItem]
    func items(parentId: String?, search: String, start: Int, limit: Int, filter: ServerFilter) async throws -> EmbyPage
    func resume() async throws -> [EmbyItem]
    func children(parentId: String) async throws -> [EmbyItem]
    func seasons(seriesId: String) async throws -> [EmbyItem]
    func episodes(seriesId: String, seasonId: String) async throws -> [EmbyItem]
    func genres(parentId: String?) async -> [String]
    func report(item: EmbyItem, state: String, positionSec: Int64, durationSec: Int64) async
    func posterUrl(_ item: EmbyItem, maxWidth: Int) -> String?
    func streamUrl(_ item: EmbyItem) async throws -> String?
    func streamChoices(_ item: EmbyItem) async -> [StreamChoice]
    /// Vídeo, audios y subtítulos que tiene el título en el servidor (para elegir qué descargar); nil si el servidor no los da.
    func streamOffer(_ item: EmbyItem) async -> StreamOffer?
    func streamUrlFor(_ item: EmbyItem, _ p: StreamParams) async throws -> String?
}

// MARK: - Ayudas JSON

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String { (self[k] as? String) ?? (self[k].map { "\($0)" } ?? "") }
    func int(_ k: String) -> Int { (self[k] as? Int) ?? Int(self.str(k)) ?? 0 }
    func int64(_ k: String) -> Int64 { (self[k] as? Int64) ?? (self[k] as? Int).map(Int64.init) ?? Int64(self.str(k)) ?? 0 }
    func bool(_ k: String) -> Bool { (self[k] as? Bool) ?? false }
    func obj(_ k: String) -> JSON? { self[k] as? JSON }
    func arr(_ k: String) -> [JSON] { (self[k] as? [JSON]) ?? [] }
}

func parseJSON(_ d: Data) -> JSON { ((try? JSONSerialization.jsonObject(with: d)) as? JSON) ?? [:] }
func parseJSONArray(_ d: Data) -> [JSON] { ((try? JSONSerialization.jsonObject(with: d)) as? [JSON]) ?? [] }
func jsonData(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }
func urlEnc(_ s: String) -> String {
    var a = CharacterSet.alphanumerics; a.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: a) ?? s
}
func newId() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }

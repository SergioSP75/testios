import Foundation
import HLSCore

/// Ajustes pequeños en UserDefaults (sesiones, ids de dispositivo, ajustes de emisión).
final class DefaultsStore: KeyValueStore {
    private let d = UserDefaults.standard
    func string(_ key: String) -> String? { d.string(forKey: "srv." + key) }
    func set(_ value: String?, for key: String) { d.set(value, forKey: "srv." + key) }
}

/// Red de los clientes de servidor con URLSession.
struct URLSessionHTTP: ServerHTTP {
    func send(url: String, method: String, body: Data?, headers: [String: String], timeout: TimeInterval) async throws -> (status: Int, data: Data) {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = method; req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Las cuentas de servidor (Emby, Jellyfin, Plex). De cada tipo puede haber varias: cada una es una «ranura» («emby», «emby_2»…)
/// con su propia sesión y, si se quiere, un nombre (la etiqueta que se enseña en carátulas y fichas).
@MainActor
final class ServerHub: ObservableObject {
    static let shared = ServerHub()
    static let types = ["emby", "jellyfin", "plex"]
    let store = DefaultsStore()
    private let http = URLSessionHTTP()
    private var clients: [String: ServerBackend] = [:]
    @Published var refresh = 0                 // cambia al entrar, salir o renombrar una cuenta, para redibujar
    @Published private(set) var slots: [String]

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: "srv.slotlist") ?? []
        var l = saved.filter { s in Self.types.contains(String(s.split(separator: "_").first ?? "")) }
        for t in Self.types where !l.contains(t) { l.append(t) }         // las tres cuentas base siempre existen
        slots = l
    }

    private func saveSlots() { UserDefaults.standard.set(slots, forKey: "srv.slotlist") }

    /// El cliente de una cuenta (se crea la primera vez).
    func backend(_ slot: String) -> ServerBackend? {
        if let c = clients[slot] { return c }
        guard slots.contains(slot) else { return nil }
        let c: ServerBackend = slot.hasPrefix("plex") ? PlexClient(http: http, store: store, slot: slot) : EmbyClient(http: http, store: store, slot: slot)
        clients[slot] = c
        return c
    }

    var emby: EmbyClient { backend("emby") as! EmbyClient }
    var jellyfin: EmbyClient { backend("jellyfin") as! EmbyClient }
    var plex: PlexClient { backend("plex") as! PlexClient }

    var all: [ServerBackend] { slots.compactMap { backend($0) } }
    func accounts(of type: String) -> [ServerBackend] { all.filter { $0.type == type } }
    /// Cuentas con sesión de un tipo.
    func active(of type: String) -> [ServerBackend] { accounts(of: type).filter { $0.hasSession() } }

    /// Crea una cuenta nueva (vacía) del tipo y devuelve su clave.
    func addAccount(type: String) -> String {
        var n = 2
        while slots.contains("\(type)_\(n)") { n += 1 }
        let slot = "\(type)_\(n)"
        let last = slots.lastIndex { $0 == type || $0.hasPrefix(type + "_") } ?? slots.count - 1
        slots.insert(slot, at: last + 1)
        saveSlots(); touch()
        return slot
    }

    /// Cierra la sesión y, si no es una de las tres base, quita la cuenta.
    func remove(_ slot: String) {
        backend(slot)?.logout()
        UserDefaults.standard.removeObject(forKey: "srv.\(slot).label")
        if !Self.types.contains(slot) { slots.removeAll { $0 == slot }; clients[slot] = nil; saveSlots() }
        touch()
    }

    /// Quita las cuentas extra que se abrieron pero no llegaron a entrar.
    func prune() {
        let dead = slots.filter { !Self.types.contains($0) && backend($0)?.hasSession() != true }
        guard !dead.isEmpty else { return }
        for s in dead { UserDefaults.standard.removeObject(forKey: "srv.\(s).label"); clients[s] = nil }
        slots.removeAll { dead.contains($0) }
        saveSlots(); touch()
    }

    /// Nombre puesto por el usuario a una cuenta (vacío si no tiene).
    func customName(_ slot: String) -> String { UserDefaults.standard.string(forKey: "srv.\(slot).label") ?? "" }
    func setCustomName(_ name: String, for slot: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { UserDefaults.standard.removeObject(forKey: "srv.\(slot).label") } else { UserDefaults.standard.set(n, forKey: "srv.\(slot).label") }
        touch()
    }

    /// Etiqueta de la cuenta: su nombre propio o, si no tiene, el del servidor.
    func tag(_ slot: String) -> String {
        let c = customName(slot)
        if !c.isEmpty { return c }
        return backend(slot)?.serverLabel() ?? slot
    }
    func tag(_ b: ServerBackend) -> String { tag(b.kind) }

    func touch() { refresh += 1 }
}

import Foundation

/// Guía de programación en memoria (equivale a EpgRepository de Android, sin SQLite).
/// Solo guarda la ventana de tiempo pedida y los canales que usan las listas, para no llenar la memoria.
public final class EpgStore {
    public private(set) var channels: [String: EpgChannel] = [:]
    private var programs: [String: [(start: Int64, stop: Int64, program: EpgProgram)]] = [:]
    private var aliases: [String: String] = [:]
    private var resolveCache: [String: String?] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: - Carga

    /// Lee una guía XMLTV (ya descomprimida). `wanted` limita a los canales de las listas (nil = todos).
    @discardableResult
    public func load(xml: Data, windowStartMs: Int64, windowEndMs: Int64, wanted: [IptvChannel]? = nil) -> XmltvParser.Stats {
        var chans: [String: EpgChannel] = [:]
        var progs: [String: [(Int64, Int64, EpgProgram)]] = [:]
        let stats = XmltvParser.parse(xml, windowStartMs: windowStartMs, windowEndMs: windowEndMs,
                                      onChannel: { chans[$0.id] = $0 },
                                      onProgramme: { p, s, e in progs[p.channelId, default: []].append((s, e, p)) })
        // Quedarse solo con las guías de canales que alguna lista puede usar
        lock.lock(); defer { lock.unlock() }
        channels = chans
        aliases = Self.buildAliases(chans)
        resolveCache = [:]
        var kept: [String: [(start: Int64, stop: Int64, program: EpgProgram)]] = [:]
        let allowed: Set<String>? = wanted.map { list in Set(list.compactMap { self.resolveLocked($0) }) }
        for (id, arr) in progs where allowed?.contains(id) ?? true {
            kept[id] = arr.sorted { $0.0 < $1.0 }.map { (start: $0.0, stop: $0.1, program: $0.2) }
        }
        programs = kept
        return stats
    }

    // MARK: - Caché en disco

    /// Datos de la copia guardada: cuándo se hizo y para qué canales y ventana, para decidir si sirve o hay que refrescar.
    public struct SnapshotMeta: Codable, Equatable {
        public var savedAtMs: Int64
        public var signature: String
        public var windowStartMs: Int64
        public var windowEndMs: Int64
    }
    private struct Entry: Codable { var start: Int64; var stop: Int64; var program: EpgProgram }
    private struct Snapshot: Codable { var version: Int; var meta: SnapshotMeta; var channels: [EpgChannel]; var programs: [String: [Entry]] }
    private static let snapshotVersion = 1

    /// Guía ya analizada en un bloque de datos (JSON): se guarda en disco para no tener que descargar y analizar el XML cada vez.
    public func snapshot(signature: String, windowStartMs: Int64, windowEndMs: Int64, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Data? {
        lock.lock(); defer { lock.unlock() }
        var progs: [String: [Entry]] = [:]
        for (id, arr) in programs { progs[id] = arr.map { Entry(start: $0.start, stop: $0.stop, program: $0.program) } }
        let meta = SnapshotMeta(savedAtMs: nowMs, signature: signature, windowStartMs: windowStartMs, windowEndMs: windowEndMs)
        return try? JSONEncoder().encode(Snapshot(version: Self.snapshotVersion, meta: meta, channels: Array(channels.values), programs: progs))
    }

    /// Carga una copia guardada con `snapshot`. Devuelve sus datos, o nil si está estropeada o es de otra versión (entonces no se toca nada).
    @discardableResult
    public func restore(_ data: Data) -> SnapshotMeta? {
        guard let s = try? JSONDecoder().decode(Snapshot.self, from: data), s.version == Self.snapshotVersion else { return nil }
        lock.lock(); defer { lock.unlock() }
        var chans: [String: EpgChannel] = [:]
        for c in s.channels { chans[c.id] = c }
        channels = chans
        aliases = Self.buildAliases(chans)
        resolveCache = [:]
        programs = s.programs.mapValues { $0.map { (start: $0.start, stop: $0.stop, program: $0.program) } }
        return s.meta
    }

    // MARK: - Emparejado de canales

    private static func buildAliases(_ chans: [String: EpgChannel]) -> [String: String] {
        var out: [String: String] = [:]
        for (id, ch) in chans {
            for raw in [id, ch.displayName ?? ""] where !raw.isEmpty {
                if out[raw.lowercased()] == nil { out[raw.lowercased()] = id }
                let n = FuzzyMatcher.normalize(raw)
                if !n.isEmpty && out["n:" + n] == nil { out["n:" + n] = id }
            }
        }
        return out
    }

    /// Identificador de la guía que corresponde a un canal: tvg-id, tvg-name o nombre; si no, difuso.
    public func resolve(_ channel: IptvChannel) -> String? {
        lock.lock(); defer { lock.unlock() }
        return resolveLocked(channel)
    }

    private func resolveLocked(_ channel: IptvChannel) -> String? {
        if channels.isEmpty { return nil }
        // El emparejado difuso es caro y se pide en cada redibujado de las listas: se recuerda el resultado de cada canal
        if let hit = resolveCache[channel.id] { return hit }
        let r = resolveUncached(channel)
        resolveCache[channel.id] = .some(r)
        return r
    }

    private func resolveUncached(_ channel: IptvChannel) -> String? {
        let cands = [channel.tvgId, channel.tvgName, channel.name].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for c in cands {
            if let id = aliases[c.lowercased()] { return id }
            if let id = aliases["n:" + FuzzyMatcher.normalize(c)] { return id }
        }
        // El difuso completo es caro: solo en guías pequeñas
        if channels.count <= 1500, let m = FuzzyMatcher.bestMatch(Array(channels.keys), queries: cands) { return m.0 }
        return nil
    }

    // MARK: - Consultas

    /// Programas de un canal entre dos instantes (ms). `shiftSec` = epg_shift de listas OTC.
    public func programs(for channel: IptvChannel, from: Int64, to: Int64) -> [EpgProgram] {
        lock.lock(); defer { lock.unlock() }
        guard let id = resolveLocked(channel), let arr = programs[id] else { return [] }
        let shift = (channel.otc?.epgShiftSec ?? 0) * 1000
        return arr.filter { $0.stop + shift > from && $0.start + shift < to }.map { $0.program }
    }

    public func current(for channel: IptvChannel, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> EpgProgram? {
        lock.lock(); defer { lock.unlock() }
        guard let id = resolveLocked(channel), let arr = programs[id] else { return nil }
        let shift = (channel.otc?.epgShiftSec ?? 0) * 1000
        return arr.first { $0.start + shift <= now && now < $0.stop + shift }?.program
    }

    /// Programas con sus instantes ya calculados (ms, con el desfase de la lista aplicado), para dibujar la guía.
    public struct Slot: Identifiable, Equatable {
        public let program: EpgProgram
        public let start: Int64
        public let stop: Int64
        public var id: String { program.start + "|" + program.title }
        public init(program: EpgProgram, start: Int64, stop: Int64) { self.program = program; self.start = start; self.stop = stop }
    }

    /// Programas de un canal entre dos instantes, ordenados, con inicio y fin en ms. Sin hora de fin se usa el inicio del siguiente (o 1 h).
    public func slots(for channel: IptvChannel, from: Int64, to: Int64) -> [Slot] {
        lock.lock(); defer { lock.unlock() }
        guard let id = resolveLocked(channel), let arr = programs[id] else { return [] }
        let shift = (channel.otc?.epgShiftSec ?? 0) * 1000
        return arr.filter { $0.stop + shift > from && $0.start + shift < to }
            .map { Slot(program: $0.program, start: $0.start + shift, stop: $0.stop + shift) }
    }

    /// ¿La guía trae programas para este canal?
    public func hasPrograms(for channel: IptvChannel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let id = resolveLocked(channel) else { return false }
        return !(programs[id]?.isEmpty ?? true)
    }

    /// Identificador de la guía → sirve para saber de qué canal es un resultado de búsqueda.
    public func guideId(for channel: IptvChannel) -> String? { resolve(channel) }

    /// Búsqueda por título en toda la guía cargada.
    public func search(_ query: String, limit: Int = 50) -> [EpgProgram] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return [] }
        lock.lock(); defer { lock.unlock() }
        var out: [EpgProgram] = []
        for (_, arr) in programs {
            for e in arr where e.program.title.localizedCaseInsensitiveContains(q) {
                out.append(e.program); if out.count >= limit { return out }
            }
        }
        return out
    }

    public func icon(for channel: IptvChannel) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let id = resolveLocked(channel) else { return nil }
        return channels[id]?.icon
    }
}

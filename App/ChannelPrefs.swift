import SwiftUI
import HLSCore

/// Canales favoritos (como FavoritesRepository de Android): se guardan por identificador de canal.
@MainActor
final class ChannelFavorites: ObservableObject {
    static let shared = ChannelFavorites()
    @Published private(set) var ids: Set<String>
    private let key = "iptv_favs"

    init() { ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    func isFavorite(_ ch: IptvChannel) -> Bool { ids.contains(ch.id) }

    /// Añade o quita el canal. Devuelve si ahora es favorito.
    @discardableResult
    func toggle(_ ch: IptvChannel) -> Bool {
        let on: Bool
        if ids.contains(ch.id) { ids.remove(ch.id); on = false } else { ids.insert(ch.id); on = true }
        UserDefaults.standard.set(Array(ids), forKey: key)
        return on
    }
}

/// Últimos canales vistos (pestaña HISTORIAL), el más reciente primero.
@MainActor
final class ChannelHistory: ObservableObject {
    static let shared = ChannelHistory()
    @Published private(set) var ids: [String]
    private let key = "iptv_history"

    init() { ids = UserDefaults.standard.stringArray(forKey: key) ?? [] }

    func add(_ ch: IptvChannel) {
        ids.removeAll { $0 == ch.id }
        ids.insert(ch.id, at: 0)
        if ids.count > 50 { ids = Array(ids.prefix(50)) }
        UserDefaults.standard.set(ids, forKey: key)
    }

    /// Último canal visto (para arrancar donde se dejó).
    var last: String? { ids.first }
}

/// Reloj de la guía: avisa cada 30 s para que «en emisión», las barras de progreso y la posición de la guía avancen solas con la hora.
@MainActor
final class EpgClock: ObservableObject {
    static let shared = EpgClock()
    @Published private(set) var nowMs: Int64 = EpgClock.currentMs()
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.nowMs = EpgClock.currentMs() }
        }
    }

    nonisolated static func currentMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    /// Fuerza una lectura nueva (al volver a la app o al abrir la guía).
    func refresh() { nowMs = Self.currentMs() }
}

enum EpgFormat {
    private static let hourFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f }()
    private static let fullFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d/M HH:mm"; return f }()
    static func hour(_ ms: Int64) -> String { hourFmt.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }
    static func day(_ ms: Int64) -> String { dayFmt.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)).capitalized }
    static func full(_ ms: Int64) -> String { fullFmt.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }
    /// Las 00:00 del día de `ms` (hora local).
    static func startOfDay(_ ms: Int64) -> Int64 {
        Int64(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double(ms) / 1000)).timeIntervalSince1970 * 1000)
    }
}

extension EpgStore {
    /// Programa que se emite ahora (con su hora de inicio y fin) y el siguiente.
    func nowAndNext(for ch: IptvChannel, now: Int64) -> (now: Slot?, next: Slot?) {
        let list = slots(for: ch, from: now - 1, to: now + 12 * 3_600_000)
        let cur = list.first { $0.start <= now && now < $0.stop }
        let next = list.first { $0.start >= (cur?.stop ?? now) && $0.start > now }
        return (cur, next)
    }
}

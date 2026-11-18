import Foundation

/// Port de EpgTimeUtil.kt: fechas de la guía XMLTV («20261117203000 +0100» y variantes) → milisegundos.
public enum EpgTime {
    private static let patterns = [
        "yyyyMMddHHmmss Z", "yyyyMMddHHmm Z", "yyyyMMddHHmmssZ", "yyyyMMddHHmmZ",
        "yyyyMMddHHmmss", "yyyyMMddHHmm",
        "yyyy-MM-dd'T'HH:mm:ssXXX", "yyyy-MM-dd'T'HH:mm:ss'Z'"
    ]
    private static var cache: [String: Int64?] = [:]
    private static let lock = NSLock()

    /// Formateadores creados una vez (crearlos es caro y se usan miles de veces al pintar la rejilla).
    private static let formatters: [DateFormatter] = {
        patterns.map { p in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = p
            // Sin zona en el patrón → hora local, igual que Android
            if p.hasSuffix("'Z'") { f.timeZone = TimeZone(identifier: "UTC") }
            else if !p.contains("Z") && !p.contains("X") { f.timeZone = .current }
            return f
        }
    }()

    public static func parseMillis(_ value: String?) -> Int64? {
        guard let clean = value?.trimmingCharacters(in: .whitespaces), !clean.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[clean] { return hit }
        var parsed: Int64?
        for f in formatters {
            if let d = f.date(from: clean) { parsed = Int64((d.timeIntervalSince1970 * 1000).rounded()); break }
        }
        if cache.count > 12000 { cache.removeAll() }
        cache[clean] = parsed
        return parsed
    }
}

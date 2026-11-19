import Foundation

/// Cabeceras HTTP propias de una lista o de un servidor externo, editables a mano en la app (una por línea, «Nombre: valor»).
/// Mandan sobre las del fichero de la lista. Mismo comportamiento que ListHeaders.kt de Android, para que las dos apps
/// entiendan igual lo que se escribe y lo que llega por el QR de transferir listas.
public enum RequestHeaders {

    /// Texto del editor → cabeceras. Ignora líneas vacías, comentarios (#) y líneas sin «:»; si un nombre se repite gana la última.
    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            // Un nombre repetido (sin mirar mayúsculas) se queda con el último valor y con la grafía de ese último
            if let old = out.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { out.removeValue(forKey: old) }
            out[name] = value
        }
        return out
    }

    /// Cabeceras → texto del editor (ordenadas por nombre para que se vea estable).
    public static func format(_ headers: [String: String]) -> String {
        headers.keys.sorted { $0.lowercased() < $1.lowercased() }.map { "\($0): \(headers[$0] ?? "")" }.joined(separator: "\n")
    }

    /// Mezcla: las de `override` mandan sobre las de `base` sin distinguir mayúsculas («user-agent» pisa a «User-Agent»).
    public static func merge(_ base: [String: String], _ override: [String: String]) -> [String: String] {
        var out = base
        for (k, v) in override {
            if let old = out.keys.first(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) { out.removeValue(forKey: old) }
            out[k] = v
        }
        return out
    }

    /// Valor de una cabecera sin mirar mayúsculas.
    public static func value(_ headers: [String: String], _ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Aplica las cabeceras propias a un canal: pisan las suyas y, si traen User-Agent o Referer, también los campos propios del canal.
    public static func apply(_ ch: IptvChannel, extra: [String: String]) -> IptvChannel {
        guard !extra.isEmpty else { return ch }
        var c = ch
        c.httpHeaders = merge(c.httpHeaders, extra)
        if let ua = value(extra, "User-Agent") { c.userAgent = ua }
        if let ref = value(extra, "Referer") ?? value(extra, "Referrer") { c.referrer = ref }
        return c
    }

    /// Cabeceras finales para pedir una dirección: las del canal + User-Agent y Referer propios, con las propias de la lista/servidor encima.
    public static func effective(channel ch: IptvChannel, extra: [String: String] = [:]) -> [String: String] {
        var h = ch.httpHeaders
        if let ua = ch.userAgent { h = merge(h, ["User-Agent": ua]) }
        if let r = ch.referrer { h = merge(h, ["Referer": r]) }
        return merge(h, extra)
    }

    /// Pasa las cabeceras a un diccionario JSON (para el QR de transferir) y de vuelta; descarta valores que no sean texto.
    public static func fromJSON(_ any: Any?) -> [String: String] {
        guard let d = any as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in d { if let s = v as? String, !k.trimmingCharacters(in: .whitespaces).isEmpty { out[k] = s } }
        return out
    }
}

/// Cabeceras propias para los servidores externos (Emby, Jellyfin, Plex y los proxies de sus vídeos), editables en Ajustes → Servidores.
/// Se añaden a las peticiones a la API y a las del vídeo (también al descargar) y mandan sobre cualquier otra.
public enum ServerHeaders {
    static let key = "set.serverHeaders"

    /// Texto del editor tal como lo escribió el usuario.
    public static var text: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines); if v.isEmpty { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(v, forKey: key) } }
    }
    public static var extra: [String: String] { RequestHeaders.parse(text) }

    /// Cabeceras propias para `url` si es de un servidor externo conocido; si no, vacío.
    public static func forUrl(_ url: String) -> [String: String] { ServerUa.forUrl(url) == nil ? [:] : extra }

    /// Mezcla las cabeceras de una petición con las propias de los servidores.
    public static func applied(to headers: [String: String]) -> [String: String] { RequestHeaders.merge(headers, extra) }
}

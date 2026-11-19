import Foundation

/// User-Agent de reproducción. AVPlayer, cuando pide un vídeo por sí mismo, se anuncia como «AppleCoreMedia»; algunos CDN solo
/// sirven a ese cliente y contestan 401 a cualquier otro. El relay hace las peticiones en nombre de AVPlayer, así que, si la lista no
/// fija un User-Agent, usa el mismo que enviaría AVPlayer.
public enum PlayerUa {
    public static let native = "AppleCoreMedia/1.0.0.21A329 (iPad; U; CPU OS 17_0 like Mac OS X; es_es)"

    /// Las cabeceras con User-Agent: el de la lista si lo hay (sin importar mayúsculas) y, si no, el nativo.
    public static func applying(to headers: [String: String]) -> [String: String] {
        var h = headers
        if let k = h.keys.first(where: { $0.lowercased() == "user-agent" }) {
            if h[k]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { h[k] = native }
        } else { h["User-Agent"] = native }
        return h
    }
}

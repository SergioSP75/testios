import Foundation

/// Listas anidadas: entradas con type="playlist" cuyo contenido es otra lista M3U.
public enum Sublists {
    /// Sustituye cada entrada de sublista por los canales de la lista a la que apunta. Los canales quedan en un grupo con el nombre
    /// de la sublista (o «sublista - grupo» si traen grupo propio). Hasta `maxDepth` niveles; si una sublista falla o no se puede
    /// descargar, se salta y el resto sigue. `fetch` devuelve el texto de una dirección (en la app, una descarga; en las pruebas, un diccionario).
    public static func expand(_ list: [IptvChannel], maxDepth: Int = 2, depth: Int = 0,
                              fetch: (String) async throws -> String, log: (String) -> Void = { _ in }) async -> [IptvChannel] {
        guard list.contains(where: { $0.isPlaylistGroup }) else { return list }
        var out = list.filter { !$0.isPlaylistGroup }
        for sub in list where sub.isPlaylistGroup {
            guard depth < maxDepth else { log("sublista «\(sub.name)»: demasiado anidada, se ignora"); continue }
            do {
                let text = try await fetch(sub.nestedUrl ?? sub.url)
                var inner = await expand(M3uParser.parse(text).channels, maxDepth: maxDepth, depth: depth + 1, fetch: fetch, log: log)
                for i in inner.indices {
                    let g = inner[i].group ?? ""
                    inner[i].group = g.isEmpty ? sub.name : "\(sub.name) - \(g)"
                }
                log("sublista «\(sub.name)»: \(inner.count) canales")
                out += inner
            } catch {
                log("ERROR sublista «\(sub.name)»: \(error.localizedDescription)")
            }
        }
        return out
    }
}

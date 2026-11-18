import Foundation
import HLSCore

// Prueba de la mediateca con un fichero real. Uso: MediaProbe <fichero.json>
guard CommandLine.arguments.count == 2, let d = FileManager.default.contents(atPath: CommandLine.arguments[1]) else { print("Uso: MediaProbe <fichero.json>"); exit(2) }
let t0 = Date()
let items = MediaCatalog.parse(d, sourceId: "t")
let lib = MediaLibrary(items)
print("bytes=\(d.count) títulos=\(items.count) series=\(lib.seriesCount) pelis=\(lib.movieCount) en \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
print("plataformas:", lib.platforms(series: nil).prefix(5).map { "\($0.label)(\($0.count))" })
print("géneros:", lib.genres(series: nil, platformKey: nil).prefix(6).map { "\($0.label)(\($0.count))" })
if let s = items.first(where: { $0.isSeries }) { print("ejemplo:", s.name, "temporadas=\(s.seasons.count) capítulos=\(s.episodeCount) póster=\(s.poster != nil)") }

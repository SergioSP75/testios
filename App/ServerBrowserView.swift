import SwiftUI
import HLSCore

/// Orden de lo que muestra un servidor. Año y «añadido» también se piden ordenados al servidor (para traer los correctos);
/// el resto se ordena sobre lo ya cargado.
enum ServerSortChoice: String, CaseIterable {
    case name, nameDesc, added, year, yearOldest, rating, runtime
    var label: String {
        switch self {
        case .name: return "Título A–Z"; case .nameDesc: return "Título Z–A"; case .added: return "Recién añadido"
        case .year: return "Año (nuevo primero)"; case .yearOldest: return "Año (antiguo primero)"
        case .rating: return "Mejor valoradas"; case .runtime: return "Más largas"
        }
    }
    /// Orden que se pide al servidor.
    var serverSort: ServerSort { switch self { case .added: return .added; case .year, .yearOldest: return .year; default: return .name } }

    func apply(_ items: [EmbyItem]) -> [EmbyItem] {
        func text(_ a: EmbyItem, _ b: EmbyItem) -> Bool { a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
        switch self {
        case .added: return items                                          // ya viene como lo pidió el servidor
        case .name: return items.sorted(by: text)
        case .nameDesc: return items.sorted { text($1, $0) }
        case .year: return items.sorted { $0.year != $1.year ? $0.year > $1.year : text($0, $1) }
        case .yearOldest: return items.sorted { ($0.year == 0 ? Int.max : $0.year) != ($1.year == 0 ? Int.max : $1.year) ? ($0.year == 0 ? Int.max : $0.year) < ($1.year == 0 ? Int.max : $1.year) : text($0, $1) }
        case .rating: return items.sorted { (Double($0.rating ?? "") ?? 0) != (Double($1.rating ?? "") ?? 0) ? (Double($0.rating ?? "") ?? 0) > (Double($1.rating ?? "") ?? 0) : text($0, $1) }
        case .runtime: return items.sorted { $0.runtimeSec != $1.runtimeSec ? $0.runtimeSec > $1.runtimeSec : text($0, $1) }
        }
    }
}

/// Pasa elementos de un servidor (Emby, Jellyfin, Plex) a la cola de descargas. Cada servidor tiene su dirección, así que
/// descargas de servidores distintos se hacen a la vez (lo decide el DownloadManager por servidor).
@MainActor
enum ServerDownloads {
    /// Pide la dirección de cada elemento y lo encola directamente (sin ventana de opciones). Devuelve cuántos se añadieron.
    static func enqueue(_ backend: ServerBackend, _ items: [EmbyItem], seriesName: String? = nil) async -> Int {
        let chs = await channels(backend, items, seriesName: seriesName)
        for ch in chs { DownloadManager.shared.enqueue(channel: ch) }
        return chs.count
    }

    /// Pide la dirección de cada elemento y devuelve los canales listos para descargar (para la ventana de opciones).
    static func channels(_ backend: ServerBackend, _ items: [EmbyItem], seriesName: String? = nil) async -> [IptvChannel] {
        var out: [IptvChannel] = []
        for it in items {
            guard let s = try? await backend.streamUrlFor(it, StreamParams()), URL(string: s) != nil else { continue }
            ServerUa.remember(s)
            var title = it.name
            if it.type == "Episode" { title = "\(seriesName ?? it.seriesName) T\(it.seasonNumber)E\(it.episodeNumber) \(it.name)" }
            var ch = IptvChannel(id: "\(backend.kind)-\(it.id)", name: title, url: s, group: backend.serverLabel(), m3uLogo: backend.posterUrl(it, maxWidth: 300))
            ch.userAgent = ServerUa.standard
            out.append(ch)
        }
        return out
    }
}

/// Destino al tocar un elemento: ficha (con sinopsis, reproducir y descargar), temporadas o carpeta.
@MainActor @ViewBuilder
private func serverDestination(_ backendIn: ServerBackend, _ it: EmbyItem) -> some View {
    let backend = it.source.isEmpty ? backendIn : (ServerHub.shared.backend(it.source) ?? backendIn)
    if it.isPlayable { ServerDetailView(backend: backend, item: it) }
    else if it.isSeries { SeasonsView(backend: backend, series: it) }
    else { ServerBrowserView(backend: backend, parent: it, title: it.name) }
}

/// Biblioteca de un servidor: carpetas, películas y series, en cuadrícula o en lista con sinopsis, con orden, buscador
/// y «Seguir viendo» en la raíz.
struct ServerBrowserView: View {
    let backend: ServerBackend
    let parent: EmbyItem?
    let title: String
    @State private var items: [EmbyItem] = []
    @State private var resume: [EmbyItem] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var sort = ServerSortChoice.name
    @AppStorage("server.view") private var viewRaw = "grid"                 // cuadrícula por defecto
    @EnvironmentObject var themes: ThemeStore
    @ObservedObject private var hub = ServerHub.shared
    /// Con más de una cuenta del mismo tipo se marca de cuál es cada título.
    private var showTag: Bool { hub.active(of: backend.type).count > 1 }

    private var shown: [EmbyItem] { sort.apply(items) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let e = error { Text(e).foregroundStyle(.red).font(.caption).padding(.horizontal) }
                if parent == nil && search.isEmpty && !resume.isEmpty {
                    Text("Seguir viendo").font(.headline).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(resume) { it in NavigationLink { serverDestination(backend, it) } label: { card(it, width: 120) }.buttonStyle(.plain) }
                        }.padding(.horizontal)
                    }
                }
                HStack {
                    Menu {
                        Picker("Ordenar por", selection: $sort) { ForEach(ServerSortChoice.allCases, id: \.self) { Text($0.label).tag($0) } }
                    } label: { Label(sort.label, systemImage: "arrow.up.arrow.down").font(.footnote) }
                    Spacer()
                    Picker("Vista", selection: $viewRaw) {
                        Image(systemName: "square.grid.3x3").tag("grid"); Image(systemName: "list.bullet.rectangle").tag("list")
                    }.pickerStyle(.segmented).frame(width: 110)
                }.padding(.horizontal)
                Text("\(items.count) elementos").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                if viewRaw == "grid" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], alignment: .leading, spacing: 14) {
                        ForEach(shown) { it in NavigationLink { serverDestination(backend, it) } label: { card(it, width: 110) }.buttonStyle(.plain) }
                    }.padding(.horizontal)
                } else {
                    ForEach(shown) { it in NavigationLink { serverDestination(backend, it) } label: { row(it) }.buttonStyle(.plain).padding(.horizontal) }
                }
            }.padding(.vertical)
        }
        .searchable(text: $search)
        .onSubmit(of: .search) { Task { await load() } }
        .overlay { if loading { ProgressView() } }
        .themedScreen()
        .navigationTitle(title)
        .task(id: sort) { await load() }
    }

    /// Carátula con el título debajo.
    private func card(_ it: EmbyItem, width: CGFloat) -> some View {
        let t = themes.theme
        return VStack(alignment: .leading, spacing: 4) {
            PosterImage(url: backend.posterUrl(it, maxWidth: 360), maxPixel: 360) {
                ZStack { t.c(t.card); Text(it.name).font(.caption).multilineTextAlignment(.center).padding(6) }
            }
            .frame(width: width, height: width * 1.5).clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) { if showTag { ServerTag(text: hub.tag(it.source.isEmpty ? backend.kind : it.source)).padding(4) } }
            Text(it.name).font(.caption).lineLimit(1).frame(width: width, alignment: .leading).foregroundStyle(t.c(t.text2))
        }
    }

    /// Fila con carátula, datos y sinopsis.
    private func row(_ it: EmbyItem) -> some View {
        let t = themes.theme
        return HStack(alignment: .top, spacing: 12) {
            PosterImage(url: backend.posterUrl(it, maxWidth: 300), maxPixel: 300) { ZStack { t.c(t.card); Text(it.name).font(.caption2).padding(4) } }
                .frame(width: 80, height: 120).clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) { if showTag { ServerTag(text: hub.tag(it.source.isEmpty ? backend.kind : it.source)).padding(3) } }
            VStack(alignment: .leading, spacing: 4) {
                Text(it.name).font(.subheadline.bold()).foregroundStyle(t.c(t.text)).lineLimit(2)
                Text(serverMeta(it)).font(.caption).foregroundStyle(t.c(t.dim)).lineLimit(2)
                if !it.overview.isEmpty { Text(it.overview).font(.caption).foregroundStyle(t.c(t.text2)).lineLimit(5) }
            }
            Spacer(minLength: 0)
        }.contentShape(Rectangle())
    }

    private func load() async {
        loading = true; error = nil; defer { loading = false }
        do {
            if let p = parent, p.isFolder && p.type == "BoxSet" { items = try await backend.children(parentId: p.id) }
            else if parent == nil && search.isEmpty { items = try await backend.libraries(); resume = (try? await backend.resume()) ?? [] }
            else { items = try await backend.items(parentId: parent?.id, search: search, start: 0, limit: 500, filter: ServerFilter(sort: sort.serverSort)).items }
        } catch { self.error = error.localizedDescription }
    }
}

/// Línea de datos de un elemento: año · valoración · duración · géneros.
func serverMeta(_ it: EmbyItem) -> String {
    var p: [String] = []
    if it.year > 0 { p.append(String(it.year)) }
    if let r = it.rating, !r.isEmpty { p.append("★ \(r)") }
    if it.runtimeSec > 0 { p.append(MediaText.duration(it.runtimeSec)) }
    if !it.genres.isEmpty { p.append(it.genres.prefix(3).joined(separator: ", ")) }
    return p.joined(separator: " · ")
}

/// Ficha de una película o capítulo del servidor: carátula, datos, sinopsis, reproducir y descargar.
struct ServerDetailView: View {
    let backend: ServerBackend
    let item: EmbyItem
    @ObservedObject private var dl = DownloadManager.shared
    @EnvironmentObject var themes: ThemeStore
    @State private var message = ""
    @State private var request: DownloadRequest?
    @ObservedObject private var hub = ServerHub.shared

    var body: some View {
        let t = themes.theme
        let queued = dl.isQueued("\(backend.kind)-\(item.id)")
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    PosterImage(url: backend.posterUrl(item, maxWidth: 500), maxPixel: 500) { t.c(t.card) }
                        .frame(width: 130, height: 195).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name).font(.title3.bold())
                        Text(serverMeta(item)).font(.footnote).foregroundStyle(t.c(t.dim))
                        Label(hub.tag(backend), systemImage: "externaldrive.connected.to.line.below").font(.footnote).foregroundStyle(t.accentColor)
                        if !item.seriesName.isEmpty { Text("\(item.seriesName) · T\(item.seasonNumber) E\(item.episodeNumber)").font(.footnote).foregroundStyle(t.c(t.dim)) }
                    }
                }
                HStack(spacing: 10) {
                    NavigationLink { ServerPlayerScreen(backend: backend, item: item) } label: {
                        Label("Reproducir", systemImage: "play.fill").font(.subheadline.bold()).padding(.horizontal, 16).padding(.vertical, 8)
                            .background(t.accentColor, in: Capsule()).foregroundStyle(.black)
                    }
                    Button {
                        Task { let chs = await ServerDownloads.channels(backend, [item]); if chs.isEmpty { message = "El servidor no dio la dirección de descarga" } else { request = DownloadRequest(title: item.name, channels: chs) } }
                    } label: {
                        Label(queued ? "En descargas" : "Descargar", systemImage: queued ? "checkmark.circle" : "arrow.down.circle")
                            .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(t.c(t.card), in: Capsule()).foregroundStyle(t.c(t.text2))
                    }.disabled(queued)
                    ExternalPlayerButton(urlProvider: { try? await backend.streamUrlFor(item, StreamParams()) }, label: "Externo").font(.subheadline)
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(t.c(t.dim)) }
                if !item.overview.isEmpty { Text(item.overview).font(.callout).foregroundStyle(t.c(t.text2)) }
                else { Text("Sin sinopsis").font(.callout).italic().foregroundStyle(t.c(t.dim)) }
            }.padding()
        }
        .themedScreen()
        .navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $request) { r in DownloadOptionsSheet(request: r, onStart: { message = "Añadida a Descargas" }).environmentObject(themes) }
    }
}

/// Temporadas de una serie, con su sinopsis y la opción de bajar la serie entera.
struct SeasonsView: View {
    let backend: ServerBackend
    let series: EmbyItem
    @State private var seasons: [EmbyItem] = []
    @State private var message = ""
    @State private var request: DownloadRequest?
    @EnvironmentObject var themes: ThemeStore

    var body: some View {
        let t = themes.theme
        List {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    PosterImage(url: backend.posterUrl(series, maxWidth: 400), maxPixel: 400) { t.c(t.card) }
                        .frame(width: 100, height: 150).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(serverMeta(series)).font(.caption).foregroundStyle(t.c(t.dim))
                        if !series.overview.isEmpty { Text(series.overview).font(.caption).foregroundStyle(t.c(t.text2)) }
                    }
                }
                Button {
                    Task {
                        var chs: [IptvChannel] = []
                        for s in seasons { chs += await ServerDownloads.channels(backend, (try? await backend.episodes(seriesId: series.id, seasonId: s.id)) ?? [], seriesName: series.name) }
                        if chs.isEmpty { message = "No se pudo añadir ningún capítulo" } else { request = DownloadRequest(title: series.name, channels: chs) }
                    }
                } label: { Label("Descargar toda la serie", systemImage: "arrow.down.circle.fill") }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                ForEach(seasons) { s in NavigationLink(s.name) { EpisodesView(backend: backend, series: series, season: s) } }
            }
        }
        .themedScreen()
        .navigationTitle(series.name)
        .sheet(item: $request) { r in DownloadOptionsSheet(request: r, onStart: { message = "\(r.channels.count) capítulos añadidos a Descargas" }).environmentObject(themes) }
        .task { seasons = (try? await backend.seasons(seriesId: series.id)) ?? [] }
    }
}

/// Capítulos de una temporada: sinopsis, descarga de cada uno y de la temporada completa.
struct EpisodesView: View {
    let backend: ServerBackend
    let series: EmbyItem
    let season: EmbyItem
    @State private var episodes: [EmbyItem] = []
    @State private var message = ""
    @State private var request: DownloadRequest?
    @EnvironmentObject var themes: ThemeStore
    @ObservedObject private var dl = DownloadManager.shared

    var body: some View {
        List {
            Section {
                Button {
                    Task { let chs = await ServerDownloads.channels(backend, episodes, seriesName: series.name); if chs.isEmpty { message = "No se pudo añadir ningún capítulo" } else { request = DownloadRequest(title: "\(series.name) · \(season.name)", channels: chs) } }
                } label: { Label("Descargar temporada", systemImage: "arrow.down.circle") }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(episodes) { e in
                HStack(spacing: 10) {
                    NavigationLink { ServerDetailView(backend: backend, item: e) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(e.episodeNumber). \(e.name)")
                            if !e.overview.isEmpty { Text(e.overview).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                    Button {
                        Task { let chs = await ServerDownloads.channels(backend, [e], seriesName: series.name); if !chs.isEmpty { request = DownloadRequest(title: "\(series.name) · \(e.name)", channels: chs) } }
                    } label: { Image(systemName: dl.isQueued("\(backend.kind)-\(e.id)") ? "checkmark.circle" : "arrow.down.circle") }
                        .buttonStyle(.borderless).disabled(dl.isQueued("\(backend.kind)-\(e.id)"))
                }
            }
        }
        .themedScreen()
        .navigationTitle(season.name)
        .sheet(item: $request) { r in DownloadOptionsSheet(request: r, onStart: { message = "\(r.channels.count) capítulos añadidos a Descargas" }).environmentObject(themes) }
        .task { episodes = (try? await backend.episodes(seriesId: series.id, seasonId: season.id)) ?? [] }
    }
}

/// Reproduce un elemento del servidor. Si el original falla (p. ej. AVI/MKV que AVPlayer no abre),
/// reintenta pidiendo al servidor que lo recodifique a HLS, y dice por qué falló.
struct ServerPlayerScreen: View {
    let backend: ServerBackend
    let item: EmbyItem
    @StateObject private var model = PlayerModel()
    @State private var retried = false
    @State private var info = ""
    @State private var tracks: [MkvToHls.TrackReport] = []
    @State private var tracksShown = false

    var body: some View {
        VStack(spacing: 0) {
            if let p = model.player { PlayerSurface(player: p) } else { ProgressView().frame(maxHeight: .infinity) }
            if !tracks.isEmpty { MkvTracksPanel(tracks: tracks).onTapGesture { withAnimation { tracks = [] } }.transition(.opacity) }
            HStack { Spacer(); AudioDelayButton(applied: $model.audioDelayMs, apply: model.setAudioDelay).foregroundStyle(.white) }.padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(info.isEmpty ? model.status : info).font(.caption).foregroundStyle(.secondary)
                if let e = model.errorText { Text(e).font(.caption).foregroundStyle(.red) }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .themedScreen()
        .navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
        .task { await play(StreamParams()) }
        .onChange(of: model.errorText) { err in
            // Reintento único con recodificación del servidor
            if err != nil && !retried && AppSettings.mkvMode != "none" {
                retried = true
                Task { info = "El original no se reproduce («\(err ?? "")»). Probando recodificación del servidor…"; await play(StreamParams(mbps: 20)) }
            }
        }
        .onDisappear {
            Task { await backend.report(item: item, state: "stop", positionSec: Int64(model.lastTime), durationSec: item.runtimeSec) }
            model.stop()
        }
    }

    private func play(_ p: StreamParams) async {
        do {
            guard let s = try await backend.streamUrlFor(item, p), let url = URL(string: s) else { model.errorText = "El servidor no dio dirección de reproducción"; return }
            // Si es un MKV, se avisa de qué pistas pasan directas (verde) y cuáles habría que recodificar (rojo)
            if !tracksShown, AppSettings.mkvMode == "local",
               let r = await MkvToHls.survey(source: HttpRangeSource(fetcher: URLSessionFetcher(attempts: 3), url: url, headers: ["User-Agent": ServerUa.standard])) { tracks = r; tracksShown = true; Task { try? await Task.sleep(nanoseconds: 7_000_000_000); withAnimation { tracks = [] } } }
            await model.start(url: url, headers: ["User-Agent": ServerUa.standard], clearKeys: [:])
            await backend.report(item: item, state: "start", positionSec: item.resumeSec, durationSec: item.runtimeSec)
        } catch { model.errorText = error.localizedDescription }
    }
}


/// Pistas de un MKV: en verde las que se reproducen tal cual al reempaquetar en el dispositivo, en rojo las que habría que recodificar.
struct MkvTracksPanel: View {
    let tracks: [MkvToHls.TrackReport]
    var body: some View {
        let bad = tracks.filter { !$0.direct }
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { _, t in
                HStack(spacing: 6) {
                    Image(systemName: t.direct ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    Text("\(t.kind) · \(t.label) · \(t.codec)").font(.caption)
                    Spacer()
                    Text(t.direct ? "directa" : "recodificar").font(.caption2)
                }
                .foregroundStyle(t.direct ? Color.green : Color.red)
            }
            Text(bad.isEmpty ? "Todas las pistas pasan directas: reempaquetar en local es lo más rápido y sin pérdida."
                             : "En rojo: el iPad no las decodifica, haría falta que el servidor recodifique. Aconsejado: usar las verdes y reempaquetar en local, que no gasta servidor ni pierde calidad.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// Etiqueta pequeña con el nombre de la cuenta de servidor a la que pertenece un título.
struct ServerTag: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .bold)).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.black.opacity(0.7), in: Capsule()).foregroundStyle(.white)
            .frame(maxWidth: 100, alignment: .leading)
    }
}

/// Todas las cuentas de un mismo tipo (p. ej. dos Emby) en una sola vista: bibliotecas, «Seguir viendo» y búsqueda mezclados,
/// cada título con la etiqueta de su cuenta.
struct MergedBrowserView: View {
    let type: String
    @ObservedObject private var hub = ServerHub.shared
    @EnvironmentObject var themes: ThemeStore
    @State private var items: [EmbyItem] = []
    @State private var search = ""
    @State private var mode = "libs"                       // «libs» = bibliotecas · «all» = todos los títulos
    @State private var loading = false

    private func backend(_ it: EmbyItem) -> ServerBackend? { hub.backend(it.source) }

    var body: some View {
        let t = themes.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Ver", selection: $mode) { Text("Bibliotecas").tag("libs"); Text("Todo mezclado").tag("all") }
                    .pickerStyle(.segmented).padding(.horizontal)
                Text("\(items.count) elementos de \(hub.active(of: type).count) cuentas").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], alignment: .leading, spacing: 14) {
                    ForEach(items) { it in
                        if let b = backend(it) {
                            NavigationLink { serverDestination(b, it) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    PosterImage(url: b.posterUrl(it, maxWidth: 360), maxPixel: 360) {
                                        ZStack { t.c(t.card); Text(it.name).font(.caption).multilineTextAlignment(.center).padding(6) }
                                    }
                                    .frame(width: 110, height: 165).clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(alignment: .topLeading) { ServerTag(text: hub.tag(it.source)).padding(4) }
                                    Text(it.name).font(.caption).lineLimit(1).frame(width: 110, alignment: .leading).foregroundStyle(t.c(t.text2))
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.horizontal)
            }.padding(.vertical)
        }
        .searchable(text: $search)
        .onSubmit(of: .search) { Task { await load() } }
        .overlay { if loading { ProgressView() } }
        .themedScreen()
        .navigationTitle("Todos los \(type.capitalized)")
        .task(id: mode) { await load() }
    }

    /// Pide a cada cuenta a la vez y junta el resultado ordenado por nombre.
    private func load() async {
        loading = true; defer { loading = false }
        let backends = hub.active(of: type)
        let q = search, m = mode
        var all: [EmbyItem] = []
        await withTaskGroup(of: [EmbyItem].self) { g in
            for b in backends {
                g.addTask {
                    let l: [EmbyItem]
                    if m == "libs" && q.isEmpty { l = (try? await b.libraries()) ?? [] }
                    else { l = (try? await b.items(parentId: nil, search: q, start: 0, limit: 300, filter: ServerFilter(sort: .name)).items) ?? [] }
                    return l.map { var x = $0; x.source = b.kind; return x }
                }
            }
            for await part in g { all += part }
        }
        items = all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

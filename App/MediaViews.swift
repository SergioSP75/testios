import SwiftUI
import HLSCore

// Piezas de la mediateca que comparten los tres entornos (Clásico, Streaming y Estilo Netflix).

/// Carátula con el título debajo.
struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat = 120
    var rank: Int? = nil                         // número grande del «Top 10»
    @EnvironmentObject var themes: ThemeStore

    /// Etiqueta de proveedor (plataforma) de la que viene el título.
    @ViewBuilder private var providerTag: some View {
        let l = MediaHub.shared.library.platformLabel(item.platformKey)
        if !l.isEmpty { ServerTag(text: l) }
    }

    var body: some View {
        let t = themes.theme
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                PosterImage(url: item.poster, maxPixel: 360) {
                    ZStack { t.c(t.card); Text(item.name).font(.caption).multilineTextAlignment(.center).padding(6) }
                }
                .frame(width: width, height: width * 1.5).clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(RoundedRectangle(cornerRadius: 8))
                if rank == nil { providerTag.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(4) }
                if let r = rank {
                    Text("\(r)").font(.system(size: 54, weight: .heavy)).foregroundStyle(.white)
                        .shadow(color: .black, radius: 4).padding(.leading, 6)
                }
            }
            Text(item.name).font(.caption).lineLimit(1).frame(width: width, alignment: .leading).foregroundStyle(t.c(t.text2))
        }
    }
}

/// Fila horizontal de carátulas con título.
struct Carousel: View {
    let title: String
    let items: [MediaItem]
    var numbered = false
    var width: CGFloat = 120
    var all: [MediaItem]? = nil                     // si se indica, el título lleva «Ver todo» a una cuadrícula completa
    @EnvironmentObject var themes: ThemeStore

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.headline).foregroundStyle(themes.theme.c(themes.theme.text))
                    Spacer()
                    if let all, all.count > items.count {
                        NavigationLink { AllTitlesView(title: title, items: all) } label: { Text("Ver todo (\(all.count)) ›").font(.footnote) }
                    }
                }.padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(items.prefix(40).enumerated()), id: \.element.id) { idx, it in
                            NavigationLink { MediaDetailView(item: it) } label: { PosterCard(item: it, width: width, rank: numbered ? idx + 1 : nil) }
                                .buttonStyle(.plain)
                        }
                    }.padding(.horizontal)
                }
            }
        }
    }
}

/// Carrusel superior de la portada: pasa solo de uno en uno y, al llegar al último, vuelve al primero (sin parar nunca).
/// Se detiene mientras el dedo está encima y sigue al soltar.
struct FeaturedCarousel: View {
    let items: [MediaItem]
    @State private var index = 0
    private let timer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        if items.isEmpty { EmptyView() }
        else {
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, it in FeaturedBanner(item: it).tag(i) }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .automatic : .never))
            .frame(height: 290)
            .onReceive(timer) { _ in
                guard items.count > 1 else { return }
                withAnimation(.easeInOut(duration: 0.5)) { index = (index + 1) % items.count }
            }
            .onChange(of: items.count) { _ in index = 0 }
        }
    }
}

/// Banner destacado de la portada.
struct FeaturedBanner: View {
    let item: MediaItem
    @EnvironmentObject var themes: ThemeStore

    var body: some View {
        let t = themes.theme
        NavigationLink { MediaDetailView(item: item) } label: {
            ZStack(alignment: .bottomLeading) {
                PosterImage(url: item.backdrop ?? item.poster, maxPixel: 1400) { t.c(t.card) }
                    .frame(height: 260).frame(maxWidth: .infinity).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).font(.title.bold()).foregroundStyle(.white).lineLimit(2)
                    if let p = item.plot { Text(p).font(.footnote).foregroundStyle(.white.opacity(0.85)).lineLimit(2) }
                    Label("Ver", systemImage: "play.fill").font(.subheadline.bold()).padding(.horizontal, 14).padding(.vertical, 6)
                        .background(t.accentColor, in: Capsule()).foregroundStyle(.black)
                }.padding()
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).padding(.horizontal)
    }
}

/// Fichas de filtro (plataforma o género).
struct FacetChips: View {
    let facets: [MediaFacet]
    @Binding var selected: String?
    var allLabel = "Todo"
    @EnvironmentObject var themes: ThemeStore

    var body: some View {
        let t = themes.theme
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(allLabel, on: selected == nil) { selected = nil }
                ForEach(facets.prefix(30)) { f in chip("\(f.label) · \(f.count)", on: selected == f.key) { selected = (selected == f.key) ? nil : f.key } }
            }.padding(.horizontal)
        }
        .foregroundStyle(t.c(t.text))
    }

    private func chip(_ text: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        let t = themes.theme
        return Button(action: action) {
            Text(text).font(.footnote).padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? t.accentColor : t.c(t.card), in: Capsule())
                .foregroundStyle(on ? Color.black : t.c(t.text2))
        }.buttonStyle(.plain)
    }
}

/// Forma de ver los títulos: cuadrícula de carátulas, lista con sinopsis o filas por género.
enum MediaViewMode: String, CaseIterable {
    case grid, list, rows
    var icon: String { switch self { case .grid: return "square.grid.3x3"; case .list: return "list.bullet.rectangle"; case .rows: return "rectangle.split.3x1" } }
}

/// Rejilla de carátulas (`.grid`) o lista con carátula, datos y sinopsis (`.list`).
struct PosterGrid: View {
    enum Mode { case grid, list }
    let items: [MediaItem]
    var mode: Mode = .grid
    @EnvironmentObject var themes: ThemeStore

    var body: some View {
        if mode == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], alignment: .leading, spacing: 14) {
                ForEach(items.prefix(2000)) { it in
                    NavigationLink { MediaDetailView(item: it) } label: { PosterCard(item: it, width: 110) }.buttonStyle(.plain)
                }
            }.padding(.horizontal)
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(items.prefix(2000)) { it in
                    NavigationLink { MediaDetailView(item: it) } label: { row(it) }.buttonStyle(.plain)
                }
            }.padding(.horizontal)
        }
    }

    /// Fila con carátula a la izquierda y título, datos y sinopsis a la derecha.
    private func row(_ it: MediaItem) -> some View {
        let t = themes.theme
        return HStack(alignment: .top, spacing: 12) {
            PosterImage(url: it.poster, maxPixel: 300) { ZStack { t.c(t.card); Text(it.name).font(.caption2).padding(4) } }
                .frame(width: 80, height: 120).clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) { ServerTag(text: MediaHub.shared.library.platformLabel(it.platformKey)).padding(3) }
            VStack(alignment: .leading, spacing: 4) {
                Text(it.name).font(.subheadline.bold()).foregroundStyle(t.c(t.text)).lineLimit(2)
                Text(MediaText.summary(it)).font(.caption).foregroundStyle(t.c(t.dim)).lineLimit(2)
                if let p = it.plot, !p.isEmpty { Text(p).font(.caption).foregroundStyle(t.c(t.text2)).lineLimit(5) }
                else { Text("Sin sinopsis").font(.caption).italic().foregroundStyle(t.c(t.dim)) }
            }
            Spacer(minLength: 0)
        }.contentShape(Rectangle())
    }
}

/// Pantalla con todos los títulos de una fila («Ver todo»): cuadrícula o lista con sinopsis, con su propio orden.
struct AllTitlesView: View {
    let title: String
    let items: [MediaItem]
    @AppStorage("media.view") private var viewRaw = MediaViewMode.grid.rawValue
    @State private var sort = MediaSort.added
    @State private var shown: [MediaItem] = []
    @EnvironmentObject var themes: ThemeStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Menu {
                        Picker("Ordenar por", selection: $sort) { ForEach(MediaSort.allCases, id: \.self) { Text($0.label).tag($0) } }
                    } label: { Label(sort.label, systemImage: "arrow.up.arrow.down").font(.footnote) }
                    Spacer()
                    Picker("Vista", selection: $viewRaw) {
                        Image(systemName: MediaViewMode.grid.icon).tag(MediaViewMode.grid.rawValue)
                        Image(systemName: MediaViewMode.list.icon).tag(MediaViewMode.list.rawValue)
                    }.pickerStyle(.segmented).frame(width: 110)
                }.padding(.horizontal)
                PosterGrid(items: shown, mode: viewRaw == MediaViewMode.list.rawValue ? .list : .grid)
            }.padding(.vertical)
        }
        .themedScreen().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task(id: "\(sort.rawValue)|\(items.count)") { shown = MediaLibrary(items).filter(sort: sort) }
    }
}

/// Ficha de una película o serie: sinopsis, favorito, tráiler y reproducción (con temporadas y capítulos).
struct MediaDetailView: View {
    let item: MediaItem
    @EnvironmentObject var themes: ThemeStore
    @ObservedObject private var favs = MediaFavorites.shared
    @State private var season = 0
    @ObservedObject private var dl = DownloadManager.shared
    @State private var request: DownloadRequest?

    /// Abre la ventana de opciones de descarga para estos capítulos o la película.
    private func ask(_ title: String, _ channels: [IptvChannel]) { request = DownloadRequest(title: title, channels: channels) }
    private func channels(of eps: [MediaEpisode]) -> [IptvChannel] { eps.map { $0.asChannel(series: item.name, headers: item.headers) } }

    var body: some View {
        let t = themes.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    PosterImage(url: item.backdrop ?? item.poster, maxPixel: 1400) { t.c(t.card) }
                        .frame(height: 220).frame(maxWidth: .infinity).clipped()
                    LinearGradient(colors: [.clear, t.c(t.panel)], startPoint: .top, endPoint: .bottom)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.name).font(.title2.bold())
                    Text(meta).font(.footnote).foregroundStyle(t.c(t.dim))
                    Label(MediaHub.shared.library.platformLabel(item.platformKey), systemImage: "tag").font(.footnote).foregroundStyle(t.accentColor)
                    HStack(spacing: 10) {
                        if !item.isSeries {
                            NavigationLink { PlayerScreen(channel: item.asChannel, itemKey: MediaFavorites.key(item)) } label: {
                                Label("Reproducir", systemImage: "play.fill").font(.subheadline.bold()).padding(.horizontal, 16).padding(.vertical, 8)
                                    .background(t.accentColor, in: Capsule()).foregroundStyle(.black)
                            }
                        }
                        if !item.isSeries {
                            Button { ask(item.name, [item.asChannel]) } label: {
                                Label(dl.isQueued(item.asChannel.id) ? "En descargas" : "Descargar", systemImage: "arrow.down.circle")
                                    .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(t.c(t.card), in: Capsule()).foregroundStyle(t.c(t.text2))
                            }
                        }
                        if !item.isSeries, item.drm == nil, !item.url.isEmpty { ExternalPlayerButton(urlProvider: { item.url }, label: "Externo").font(.subheadline) }
                        Button { favs.toggle(item) } label: {
                            Image(systemName: favs.isFavorite(item) ? "star.fill" : "star").padding(10)
                                .background(t.c(t.card), in: Circle()).foregroundStyle(favs.isFavorite(item) ? t.c(t.fav) : t.c(t.text2))
                        }
                        if let tr = item.trailer, let u = URL(string: tr.hasPrefix("http") ? tr : "https://www.youtube.com/watch?v=\(tr)") {
                            Link(destination: u) { Label("Tráiler", systemImage: "film").font(.subheadline).padding(.horizontal, 12).padding(.vertical, 8)
                                .background(t.c(t.card), in: Capsule()).foregroundStyle(t.c(t.text2)) }
                        }
                    }
                    if let p = item.plot { Text(p).font(.callout).foregroundStyle(t.c(t.text2)) }
                    if !item.cast.isEmpty { Text("Reparto: " + item.cast.prefix(8).joined(separator: ", ")).font(.caption).foregroundStyle(t.c(t.dim)) }
                    if !item.director.isEmpty { Text("Dirección: " + item.director.joined(separator: ", ")).font(.caption).foregroundStyle(t.c(t.dim)) }
                    if item.isSeries { episodes }
                }.padding(.horizontal)
            }
        }
        .themedScreen()
        .navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $request) { r in DownloadOptionsSheet(request: r).environmentObject(themes) }
        .onAppear { Trace.shared.log("ui", "ficha abierta: \(item.name) (\(item.isSeries ? "serie, \(item.episodeCount) capítulos" : "película"))") }
    }

    private var meta: String {
        var parts: [String] = []
        if let y = item.year { parts.append(String(y)) }
        if let r = item.rating { parts.append("★ \(r)") }
        if item.isSeries { parts.append("\(item.seasons.count) temporadas · \(item.episodeCount) capítulos") }
        else if item.durationSec > 0 { parts.append(MediaText.duration(item.durationSec)) }
        if let c = item.category { parts.append(c) }
        if !item.genres.isEmpty { parts.append(item.genres.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var episodes: some View {
        let t = themes.theme
        if item.seasons.count > 1 {
            Picker("Temporada", selection: $season) {
                ForEach(Array(item.seasons.enumerated()), id: \.offset) { i, s in Text("Temporada \(s.number)").tag(i) }
            }.pickerStyle(.menu)
        }
        if season < item.seasons.count {
            HStack(spacing: 8) {
                Button { ask("\(item.name) · temporada \(item.seasons[season].number)", channels(of: item.seasons[season].episodes)) } label: {
                    Label("Descargar temporada", systemImage: "arrow.down.circle").font(.footnote)
                }.buttonStyle(.bordered).controlSize(.small)
                if item.seasons.count > 1 {
                    Button { ask("\(item.name) · serie completa", channels(of: item.seasons.flatMap { $0.episodes })) } label: {
                        Label("Descargar toda la serie", systemImage: "arrow.down.circle.fill").font(.footnote)
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            ForEach(item.seasons[season].episodes) { ep in
                NavigationLink { PlayerScreen(channel: ep.asChannel(series: item.name, headers: item.headers), itemKey: MediaFavorites.key(item)) } label: {
                    HStack(spacing: 10) {
                        PosterImage(url: ep.poster ?? item.poster, maxPixel: 300) { t.c(t.card) }
                            .frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(ep.number). \(ep.name)").font(.subheadline).foregroundStyle(t.c(t.text))
                            if ep.durationSec > 0 { Text(MediaText.duration(ep.durationSec)).font(.caption).foregroundStyle(t.c(t.dim)) }
                        }
                        Spacer(minLength: 0)
                        Button { ask("\(item.name) T\(item.seasons[season].number)E\(ep.number)", channels(of: [ep])) } label: {
                            Image(systemName: dl.isQueued("\(item.name)-\(ep.id)") ? "checkmark.circle" : "arrow.down.circle")
                        }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())            // toda la barra, no solo la imagen
                }.buttonStyle(.plain)
            }
        }
    }
}

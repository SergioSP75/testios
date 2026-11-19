import SwiftUI
import HLSCore

// Los tres entornos de Android (Configuración → Entorno): Clásico, Streaming y Estilo Netflix.
// Todos usan los mismos datos (mediateca, canales, guía, favoritos, «Seguir viendo»): solo cambia cómo se ven.

enum AppStyle: String, CaseIterable, Identifiable {
    case classic, streaming, netflix
    var id: String { rawValue }
    var label: String { switch self { case .classic: return "Clásico"; case .streaming: return "Streaming"; case .netflix: return "Estilo Netflix" } }
    var desc: String {
        switch self {
        case .classic: return "La de siempre: lista de canales con el reproductor y la Mediateca en rejilla"
        case .streaming: return "Banner destacado y carruseles por plataforma y género, como las apps de operadoras"
        case .netflix: return "Barra lateral, Top 10, filas de carátulas y TV con guía"
        }
    }
}

enum HomeSection: String, CaseIterable, Identifiable {
    case home, movies, series, tv, server, downloads, search, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .home: return "Inicio"; case .movies: return "Películas"; case .series: return "Series"; case .tv: return "TV"
        case .server: return "Server Externo"; case .downloads: return "Descargas"; case .search: return "Buscar"; case .settings: return "Ajustes"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"; case .movies: return "film"; case .series: return "tv"; case .tv: return "antenna.radiowaves.left.and.right"
        case .server: return "externaldrive.connected.to.line.below"; case .downloads: return "arrow.down.circle"; case .search: return "magnifyingglass"; case .settings: return "gearshape"
        }
    }
}

/// Contenido de cada sección (común a Streaming y Netflix).
struct SectionContent: View {
    let section: HomeSection
    let style: AppStyle
    var body: some View {
        switch section {
        case .home: HomeContent(style: style)
        case .movies: CatalogContent(series: false, style: style).navigationTitle("Películas")
        case .series: CatalogContent(series: true, style: style).navigationTitle("Series")
        case .tv: PlaylistsContent(showShortcuts: false)
        case .server: ServersView()
        case .downloads: DownloadsView()
        case .search: SearchContent()
        case .settings: SettingsView()
        }
    }
}

/// Entorno «Streaming»: pestañas arriba, banner y carruseles.
struct StreamingShell: View {
    @State private var section = HomeSection.home
    @EnvironmentObject var themes: ThemeStore

    var body: some View {
        let t = themes.theme
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(HomeSection.allCases) { s in
                            Button { section = s } label: {
                                Label(s.label, systemImage: s.icon).font(.footnote.weight(section == s ? .bold : .regular))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(section == s ? t.accentColor : t.c(t.card), in: Capsule())
                                    .foregroundStyle(section == s ? Color.black : t.c(t.text2))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal).padding(.vertical, 8)
                }
                .background(t.c(t.bar))
                SectionContent(section: section, style: .streaming)
            }
            .themedScreen()
        }
    }
}

/// Entorno «Estilo Netflix»: barra lateral, banner, Top 10 y filas.
struct NetflixShell: View {
    @State private var section: HomeSection? = .home
    @EnvironmentObject var themes: ThemeStore

    var body: some View {
        let t = themes.theme
        NavigationSplitView {
            List(HomeSection.allCases, selection: $section) { s in
                Label(s.label, systemImage: s.icon).tag(s)
                    .listRowBackground(section == s ? t.c(t.selRow) : t.c(t.bar))
            }
            .scrollContentBackground(.hidden).background(t.c(t.bar))
            .navigationTitle("MediaKiller")
        } detail: {
            NavigationStack { SectionContent(section: section ?? .home, style: .netflix).themedScreen() }
        }
        .tint(t.accentColor).preferredColorScheme(t.light ? .light : .dark)
    }
}

/// Portada: banner, «Seguir viendo», favoritos, Top 10 (Netflix), novedades, y filas por plataforma y género.
/// Las filas se calculan una vez cuando cambia la mediateca (no en cada redibujado).
struct HomeContent: View {
    let style: AppStyle
    struct Row: Identifiable { var id: String; var title: String; var items: [MediaItem]; var numbered = false; var all: [MediaItem]? = nil }
    @ObservedObject private var hub = MediaHub.shared
    @ObservedObject private var favs = MediaFavorites.shared
    @ObservedObject private var progress = MediaProgress.shared
    @ObservedObject private var lists = MediaLists.shared
    @EnvironmentObject var themes: ThemeStore
    @State private var rows: [Row] = []
    @State private var featured: [MediaItem] = []

    private func rebuild() {
        let lib = hub.library
        var r: [Row] = []
        let cont = progress.continueKeys.compactMap { hub.item(forKey: $0) }
        if !cont.isEmpty { r.append(Row(id: "cont", title: "Seguir viendo", items: cont)) }
        let fav = lib.items.filter { favs.isFavorite($0) }
        if !fav.isEmpty { r.append(Row(id: "fav", title: "Mi lista", items: fav)) }
        if style == .netflix { r.append(Row(id: "top", title: "Top 10", items: hub.top10(), numbered: true)) }
        r.append(Row(id: "pel", title: "Películas recientes", items: hub.recent(series: false)))
        r.append(Row(id: "ser", title: "Series recientes", items: hub.recent(series: true)))
        for p in lib.platforms(series: nil).prefix(6) { let all = lib.filter(platformKey: p.key, sort: .added); r.append(Row(id: "p" + p.key, title: p.label, items: Array(all.prefix(30)), all: all)) }
        for g in lib.genres(series: nil, platformKey: nil).prefix(6) { let all = lib.filter(genre: g.key, sort: .year); r.append(Row(id: "g" + g.key, title: g.label, items: Array(all.prefix(30)), all: all)) }
        rows = r.filter { !$0.items.isEmpty }
        featured = hub.featuredList()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if hub.loading { HStack { ProgressView(); Text(hub.status).font(.caption).foregroundStyle(themes.theme.c(themes.theme.dim)) }.padding(.horizontal) }
                if !featured.isEmpty { FeaturedCarousel(items: featured) }
                ForEach(rows) { row in Carousel(title: row.title, items: row.items, numbered: row.numbered, width: row.numbered ? 130 : 120, all: row.all) }
                if hub.library.items.isEmpty && !hub.loading {
                    Text(lists.lists.isEmpty ? "Añade listas de mediateca en Ajustes." : "No se pudo cargar la mediateca.").font(.footnote).foregroundStyle(.secondary).padding()
                }
            }.padding(.vertical)
        }
        .task { await hub.loadAll() }
        .task(id: "\(hub.library.items.count)|\(favs.keys.count)|\(progress.entries.count)") { rebuild() }
        .onChange(of: lists.lists.count) { _ in Task { await hub.loadAll() } }
        .navigationTitle("Inicio")
    }
}

/// Películas o series: fichas de plataforma y género, y filas por género o rejilla si se filtra.
/// El filtrado se hace al cambiar un filtro, no en cada redibujado (con 13 000 títulos congelaba los toques).
struct CatalogContent: View {
    let series: Bool
    let style: AppStyle
    @ObservedObject private var hub = MediaHub.shared
    @ObservedObject private var progress = MediaProgress.shared
    @State private var platform: String?
    @State private var genre: String?
    @State private var search = ""
    @State private var continueItems: [MediaItem] = []
    @State private var sort = MediaSort.added
    @AppStorage("media.view") private var viewRaw = MediaViewMode.grid.rawValue      // cuadrícula por defecto
    @State private var list: [MediaItem] = []
    @State private var genreRows: [(MediaFacet, [MediaItem])] = []
    @State private var platforms: [MediaFacet] = []
    @State private var genres: [MediaFacet] = []
    @EnvironmentObject var themes: ThemeStore

    private var mode: MediaViewMode { MediaViewMode(rawValue: viewRaw) ?? .grid }
    private var key: String { "\(progress.entries.count)|\(hub.library.items.count)|\(platform ?? "")|\(genre ?? "")|\(search)|\(sort)|\(series)|\(viewRaw)" }
    /// Filas por género solo si se elige «Filas» y no hay ningún filtro; en cuadrícula o lista siempre se ve todo el catálogo.
    private var showRows: Bool { mode == .rows && platform == nil && genre == nil && search.isEmpty }

    private func recompute() {
        let lib = hub.library
        platforms = lib.platforms(series: series)
        genres = lib.genres(series: series, platformKey: platform)
        // «Seguir viendo» de esta mediateca (películas o series, según la pestaña)
        continueItems = progress.continueKeys.compactMap { hub.item(forKey: $0) }.filter { $0.isSeries == series }
        if showRows {
            genreRows = lib.genres(series: series, platformKey: nil).prefix(10).map { g in (g, Array(lib.filter(series: series, genre: g.key, sort: sort).prefix(30))) }
            list = []
        } else {
            list = lib.filter(series: series, platformKey: platform, genre: genre, query: search, sort: sort)
            genreRows = []
        }
    }

    /// Todos los títulos de un género (para «Ver todo» de una fila).
    private func allOf(_ g: MediaFacet) -> [MediaItem] { hub.library.filter(series: series, genre: g.key, sort: sort) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if hub.loading { HStack { ProgressView(); Text(hub.status).font(.caption).foregroundStyle(.secondary) }.padding(.horizontal) }
                // Buscador dentro de la propia mediateca (siempre visible, sin cambiar de pestaña)
                searchField
                FacetChips(facets: platforms, selected: $platform, allLabel: "Todas las plataformas")
                genreMenu
                // Orden (9 criterios) y forma de ver: cuadrícula, lista con sinopsis o filas por género
                HStack {
                    Menu {
                        Picker("Ordenar por", selection: $sort) { ForEach(MediaSort.allCases, id: \.self) { Text($0.label).tag($0) } }
                    } label: { Label(sort.label, systemImage: "arrow.up.arrow.down").font(.footnote) }
                    Spacer()
                    Picker("Vista", selection: $viewRaw) {
                        ForEach(MediaViewMode.allCases, id: \.rawValue) { Image(systemName: $0.icon).tag($0.rawValue) }
                    }.pickerStyle(.segmented).frame(width: 150)
                }.padding(.horizontal)
                if search.isEmpty, platform == nil, genre == nil, !continueItems.isEmpty {
                    Carousel(title: "Seguir viendo", items: continueItems)
                }
                if showRows {
                    ForEach(genreRows, id: \.0.id) { g, items in Carousel(title: g.label, items: items, all: allOf(g)) }
                } else {
                    Text("\(list.count) títulos").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    PosterGrid(items: list, mode: mode == .list ? .list : .grid)
                }
            }.padding(.vertical)
        }
        .task { await hub.loadAll() }
        .task(id: key) { recompute() }
    }

    /// Campo de búsqueda visible arriba de la mediateca.
    private var searchField: some View {
        let t = themes.theme
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(t.c(t.dim))
            TextField("Buscar en \(series ? "series" : "películas")…", text: $search)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                .foregroundStyle(t.c(t.text))
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(t.c(t.dim)) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(t.c(t.card), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    /// Géneros en una lista desplegable (con scroll si es larga) en vez de una tira de botones.
    private var genreMenu: some View {
        let t = themes.theme
        let current = genres.first { $0.key == genre }
        return HStack {
            Menu {
                Button { genre = nil } label: { Label("Todos los géneros", systemImage: genre == nil ? "checkmark" : "") }
                ForEach(genres) { g in
                    Button { genre = (genre == g.key) ? nil : g.key } label: { Label("\(g.label) · \(g.count)", systemImage: genre == g.key ? "checkmark" : "") }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(current.map { "\($0.label) · \($0.count)" } ?? "Todos los géneros").lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.footnote).padding(.horizontal, 12).padding(.vertical, 8)
                .background(genre == nil ? t.c(t.card) : t.accentColor, in: Capsule())
                .foregroundStyle(genre == nil ? t.c(t.text2) : Color.black)
            }
            Spacer()
        }.padding(.horizontal)
    }
}

/// Buscador de toda la mediateca.
struct SearchContent: View {
    @ObservedObject private var hub = MediaHub.shared
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar películas y series…", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.gray.opacity(0.18), in: Capsule())
            .padding(.horizontal).padding(.vertical, 8)
            ScrollView {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Escribe para buscar películas y series").foregroundStyle(.secondary).padding(.top, 40)
                } else {
                    let found = hub.library.filter(query: query, sort: .name)
                    if found.isEmpty { Text("Sin resultados para «\(query)»").foregroundStyle(.secondary).padding(.top, 40) }
                    else { PosterGrid(items: found).padding(.top) }
                }
            }
        }
        .navigationTitle("Buscar")
        .task { await hub.loadAll() }
    }
}

/// Mediateca del entorno Clásico: rejilla con selector de películas o series.
struct MediatecaView: View {
    @State private var kind = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $kind) { Text("Películas").tag(0); Text("Series").tag(1) }.pickerStyle(.segmented).padding()
            CatalogContent(series: kind == 1, style: .classic)
        }
        .themedScreen()
        .navigationTitle("Mediateca")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { MediaListsView() } label: { Image(systemName: "list.bullet") } } }
    }
}

/// Listas de mediateca (JSON): ver, añadir y borrar.
struct MediaListsView: View {
    @ObservedObject private var lists = MediaLists.shared
    @ObservedObject private var hub = MediaHub.shared
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newUrl = ""

    var body: some View {
        List {
            ForEach(lists.lists) { l in
                VStack(alignment: .leading) { Text("🎬 \(l.name)"); Text(l.url.prefix(60) + "…").font(.caption2).foregroundStyle(.secondary) }.themedRow()
            }
            .onDelete(perform: lists.remove)
            Button("Añadir lista…") { showAdd = true }.themedRow()
            Button("Recargar todas") { Task { await hub.loadAll(force: true) } }.themedRow()
        }
        .themedScreen()
        .navigationTitle("Listas de mediateca")
        .alert("Nueva lista de mediateca", isPresented: $showAdd) {
            TextField("Nombre", text: $newName)
            TextField("Dirección (JSON)", text: $newUrl).textInputAutocapitalization(.never).keyboardType(.URL)
            Button("Añadir") {
                if !newUrl.isEmpty { lists.merge([MediaListConfig(name: newName.isEmpty ? "Mediateca" : newName, url: newUrl)]) }
                newName = ""; newUrl = ""
            }
            Button("Cancelar", role: .cancel) { newName = ""; newUrl = "" }
        }
    }
}

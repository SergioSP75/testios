import SwiftUI
import HLSCore

/// Entorno elegido (Clásico, Streaming o Netflix), como en Android.
struct RootView: View {
    @AppStorage("appStyle") private var styleRaw = AppStyle.classic.rawValue
    @ObservedObject private var remote = RemoteControl.shared
    var body: some View {
        Group {
            switch AppStyle(rawValue: styleRaw) ?? .classic {
            case .classic: ClassicShell()
            case .streaming: StreamingShell()
            case .netflix: NetflixShell()
            }
        }
        .task { DownloadManager.shared.resume() }
        .fullScreenCover(item: $remote.offlineRequest) { r in
            NavigationStack {
                OfflineRouter(file: r.file, title: r.title, subs: r.subs)
            }
        }
        .fullScreenCover(item: $remote.serverPlayRequest) { r in
            NavigationStack {
                ServerPlayerScreen(backend: r.backend, item: r.item)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cerrar") { remote.serverPlayRequest = nil } } }
            }
        }
        .fullScreenCover(item: $remote.playRequest) { ch in
            NavigationStack {
                PlayerScreen(channel: ch)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cerrar") { remote.playRequest = nil } } }
            }
        }
    }
}

/// Entorno Clásico: lista de listas con iconos de acceso.
struct ClassicShell: View {
    @EnvironmentObject var themes: ThemeStore
    var body: some View {
        NavigationStack {
            PlaylistsContent(showShortcuts: true)
        }
    }
}

/// Listas de canales guardadas y botón para añadir una.
struct PlaylistsContent: View {
    var showShortcuts: Bool
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var themes: ThemeStore
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newUrl = ""

    var body: some View {
        Group {
            List {
                ForEach(store.playlists.filter { $0.enabled }) { pl in
                    NavigationLink { ChannelListView(playlist: pl) } label: {
                        Label(pl.name, systemImage: "list.bullet.rectangle").foregroundStyle(themes.theme.accentColor)
                    }
                    .themedRow()
                }
                .onDelete(perform: store.remove)
            }
            .themedScreen()
            .overlay {
                if store.playlists.isEmpty {
                    Text("Añade una lista M3U con el botón +")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Listas")
            .toolbar {
                // Barra superior como la de Android: un icono de color por función
                ToolbarItem(placement: .topBarLeading) {
                    if showShortcuts { HStack(spacing: 14) {
                        NavigationLink { MediatecaView() } label: { Text("🎬") }
                        NavigationLink { ServersView() } label: { Text("🖥") }
                        NavigationLink { TestView() } label: { Text("📋").foregroundStyle(themes.theme.c(themes.theme.ok)) }
                        NavigationLink { SettingsView() } label: { Text("⚙").foregroundStyle(themes.theme.c(themes.theme.dim)) }
                        NavigationLink { DownloadsView() } label: { Text("⬇") }
                    } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .alert("Nueva lista", isPresented: $showAdd) {
                TextField("Nombre", text: $newName)
                TextField("Dirección (URL)", text: $newUrl)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("Añadir") {
                    if !newUrl.isEmpty { store.add(name: newName.isEmpty ? newUrl : newName, url: newUrl) }
                    newName = ""; newUrl = ""
                }
                Button("Cancelar", role: .cancel) { newName = ""; newUrl = "" }
            }
        }
    }
}

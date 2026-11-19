import SwiftUI
import UniformTypeIdentifiers
import HLSCore

/// Ajustes agrupados como en Android (Ajustes → Listas M3U, Entorno, Mediateca, Servidores, Guía, Descargas, Apariencia, Reproducción).
struct SettingsView: View {
    @EnvironmentObject var themes: ThemeStore

    private struct Entry: Identifiable { var id: String { title }; var icon: String; var title: String; var desc: String; var dest: AnyView }

    private var entries: [Entry] {
        [
            Entry(icon: "📋", title: "Listas de directo (M3U)", desc: "Activar, añadir, editar y borrar listas de canales", dest: AnyView(LiveListsView())),
            Entry(icon: "🏠", title: "Entorno", desc: "Pantalla de inicio: Clásico, Streaming o Estilo Netflix", dest: AnyView(EnvironmentSettingsView())),
            Entry(icon: "🎬", title: "Mediateca", desc: "Listas de películas y series (JSON) y su carga", dest: AnyView(MediaListsView())),
            Entry(icon: "📲", title: "Transferir listas", desc: "Enviar o recibir listas con un código QR (iPad ↔ Android)", dest: AnyView(ListTransferView())),
            Entry(icon: "☁", title: "Servidores externos", desc: "Cuentas de Emby, Jellyfin y Plex", dest: AnyView(ServersView())),
            Entry(icon: "📺", title: "Guía EPG", desc: "Fuente XMLTV y recarga", dest: AnyView(EpgSettingsView())),
            Entry(icon: "⬇", title: "Descargas", desc: "Calidad y audio por defecto, y las descargas hechas", dest: AnyView(DownloadSettingsView())),
            Entry(icon: "🎨", title: "Apariencia", desc: "Las 12 interfaces de color", dest: AnyView(AppearanceView())),
            Entry(icon: "▶", title: "Reproducción", desc: "Pantalla completa, resolución mínima, colchón y directo", dest: AnyView(PlaybackSettingsView())),
            Entry(icon: "💬", title: "Subtítulos", desc: "Tamaño, color, fondo y posición", dest: AnyView(SubtitleSettingsView())),
            Entry(icon: "🖼", title: "Caché de imágenes", desc: "Espacio máximo y borrado automático", dest: AnyView(ImageCacheSettingsView())),
            Entry(icon: "ℹ", title: "Acerca de", desc: "Versión de la aplicación", dest: AnyView(AboutView()))
        ]
    }

    var body: some View {
        List(entries) { e in
            NavigationLink { e.dest } label: {
                HStack(spacing: 12) {
                    Text(e.icon).font(.title2).frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).foregroundStyle(themes.theme.c(themes.theme.text))
                        Text(e.desc).font(.caption).foregroundStyle(themes.theme.c(themes.theme.dim))
                    }
                }
            }.themedRow()
        }
        .themedScreen().navigationTitle("Configuración")
    }
}

/// Listas de canales en directo: activar, añadir, editar, borrar y restaurar las que trae la app.
struct LiveListsView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var themes: ThemeStore
    @State private var editing: PlaylistConfig?
    @State private var adding = false
    @State private var name = ""
    @State private var url = ""
    @State private var headersText = ""          // cabeceras propias de la lista, una por línea («Nombre: valor»)

    var body: some View {
        List {
            Section {
                ForEach(store.playlists) { pl in
                    HStack {
                        Toggle("", isOn: Binding(get: { pl.enabled }, set: { store.setEnabled(pl.id, $0) })).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pl.name)
                            Text(pl.url.hasPrefix("local:") ? "Lista local" : String(pl.url.prefix(58)) + "…").font(.caption2).foregroundStyle(themes.theme.c(themes.theme.dim))
                            if !pl.extraHeaders.isEmpty { Text("\(pl.extraHeaders.count) cabeceras propias").font(.caption2).foregroundStyle(themes.theme.accentColor) }
                        }
                        Spacer()
                        Button { editing = pl; name = pl.name; url = pl.url; headersText = RequestHeaders.format(pl.extraHeaders) } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                    }.themedRow()
                }
                .onDelete(perform: store.remove)
            } footer: { Text("Solo las activadas salen en la pantalla principal. Desliza para borrar.") }
            Section {
                Button { name = ""; url = ""; headersText = ""; adding = true } label: { Label("Añadir lista…", systemImage: "plus.circle") }.themedRow()
                NavigationLink { ListTransferView() } label: { Label("📡 Enviar / recibir listas", systemImage: "qrcode") }.themedRow()
                Button { store.restoreDefaults() } label: { Label("Restaurar las listas de la app", systemImage: "arrow.counterclockwise") }.themedRow()
            }
        }
        .themedScreen().navigationTitle("Listas de directo")
        .sheet(isPresented: $adding) {
            ListEditSheet(title: "Nueva lista", name: $name, url: $url, headers: $headersText, saveLabel: "Añadir") {
                if !url.isEmpty { store.add(name: name.isEmpty ? url : name, url: url, headers: RequestHeaders.parse(headersText)) }
                adding = false
            } cancel: { adding = false }
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            ListEditSheet(title: "Editar lista", name: $name, url: $url, headers: $headersText, saveLabel: "Guardar") {
                if let e = editing { store.update(e.id, name: name, url: url, headers: RequestHeaders.parse(headersText)) }
                editing = nil
            } cancel: { editing = nil }
        }
    }
}

struct EnvironmentSettingsView: View {
    @AppStorage("appStyle") private var styleRaw = AppStyle.classic.rawValue
    @EnvironmentObject var themes: ThemeStore
    var body: some View {
        List {
            ForEach(AppStyle.allCases) { st in
                Button { styleRaw = st.rawValue } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(st.label).foregroundStyle(themes.theme.c(themes.theme.text))
                            Text(st.desc).font(.caption).foregroundStyle(themes.theme.c(themes.theme.dim))
                        }
                        Spacer()
                        if styleRaw == st.rawValue { Image(systemName: "checkmark").foregroundStyle(themes.theme.accentColor) }
                    }
                }.themedRow()
            }
        }
        .themedScreen().navigationTitle("Entorno")
    }
}

/// Guía XMLTV: fuente por defecto y recarga.
struct EpgSettingsView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var themes: ThemeStore
    @AppStorage("epg.customUrl") private var custom = ""
    var body: some View {
        List {
            Section("Fuente de la guía") {
                Text(PlaylistStore.defaultEpgUrl ?? "ninguna").font(.caption).foregroundStyle(themes.theme.c(themes.theme.dim)).themedRow()
                TextField("Otra dirección XMLTV (opcional)", text: $custom).textInputAutocapitalization(.never).keyboardType(.URL).themedRow()
            }
            Section {
                Button { Task { await store.loadEpg(custom.isEmpty ? (PlaylistStore.defaultEpgUrl ?? "") : custom, force: true) } } label: { Label("Recargar la guía ahora", systemImage: "arrow.clockwise") }.themedRow()
                Text(store.epgReady ? "Guía cargada." : "Guía sin cargar.").font(.caption).foregroundStyle(themes.theme.c(themes.theme.dim)).themedRow()
            }
        }
        .themedScreen().navigationTitle("Guía EPG")
    }
}

/// Descargas: calidad, idiomas por defecto, descargas a la vez y lista de lo descargado.
struct DownloadSettingsView: View {
    @AppStorage("set.dlQuality") private var quality = 0
    @AppStorage("set.dlAudioLangs") private var audioLangs = ""
    @AppStorage("set.dlSubLangs") private var subLangs = "en"
    @AppStorage("set.dlParallel") private var parallel = 3
    @AppStorage("set.dlConn") private var conn = 4
    @AppStorage("set.dlPausePlay") private var pausePlay = true
    @EnvironmentObject var themes: ThemeStore
    @State private var pickFolder = false
    @State private var folderName = DownloadFolder.displayName
    @State private var folderError: String?

    /// Idiomas que se ofrecen en Ajustes (la ventana de descarga enseña los que trae cada título).
    private static let langs: [(code: String, name: String)] = [("es", "Español"), ("en", "Inglés"), ("fr", "Francés"), ("de", "Alemán"), ("it", "Italiano"), ("pt", "Portugués"), ("ca", "Catalán")]

    private func toggle(_ store: Binding<String>, _ code: String, fallback: String) -> Binding<Bool> {
        Binding(get: { (store.wrappedValue.isEmpty ? fallback : store.wrappedValue).split(separator: ",").contains(Substring(code)) },
                set: { on in
                    var l = (store.wrappedValue.isEmpty ? fallback : store.wrappedValue).split(separator: ",").map(String.init)
                    if on { if !l.contains(code) { l.append(code) } } else { l.removeAll { $0 == code } }
                    store.wrappedValue = l.isEmpty ? "-" : l.joined(separator: ",")      // «-» = ninguno (vacío significa «por defecto»)
                })
    }

    var body: some View {
        let audioDefault = "\(AppSettings.deviceLang),en"
        List {
            Section {
                Picker("Calidad", selection: $quality) {
                    Text("La mejor").tag(0); Text("1080p").tag(1080); Text("720p").tag(720); Text("480p").tag(480)
                }.themedRow()
            } header: { Text("Por defecto") } footer: { Text("Cada vez que descargas se abre una ventana con estas opciones ya marcadas.") }
            Section {
                ForEach(Self.langs, id: \.code) { l in Toggle(l.name, isOn: toggle($audioLangs, l.code, fallback: audioDefault)).themedRow() }
            } header: { Text("Idiomas de audio") } footer: { Text("Por defecto: el idioma del iPad (\(AppSettings.deviceLang)) y el inglés. Si el título no tiene ninguno, se baja el primero.") }
            Section("Idiomas de subtítulos") {
                ForEach(Self.langs, id: \.code) { l in Toggle(l.name, isOn: toggle($subLangs, l.code, fallback: "en")).themedRow() }
            }
            Section {
                Stepper("Descargas a la vez: \(parallel)", value: $parallel, in: 1...6).themedRow()
                Stepper("Trozos a la vez por vídeo: \(conn)", value: $conn, in: 1...8).themedRow()
                Toggle("Pausar mientras se reproduce algo", isOn: $pausePlay).themedRow()
            } header: { Text("Velocidad") } footer: { Text("Varias descargas a la vez solo se hacen si son de servidores distintos. Más trozos por vídeo suele acelerar mucho.") }
            Section {
                Label(folderName, systemImage: "folder").themedRow()
                Button("Elegir otra carpeta…") { pickFolder = true }.themedRow()
                if DownloadFolder.isCustom { Button("Usar la carpeta de la app") { DownloadFolder.useAppFolder(); folderName = DownloadFolder.displayName }.themedRow() }
                if let e = folderError { Text(e).font(.caption).foregroundStyle(.red) }
            } header: { Text("Carpeta de destino") } footer: {
                Text("Por defecto es la carpeta de la app, que se ve en la app Archivos → En mi iPad → HLS → Descargas (y se puede compartir o copiar desde ahí). También puedes elegir otra, como iCloud Drive o un disco externo. Lo ya descargado se queda donde estaba: solo cambia el destino de las nuevas.")
            }
            Section { NavigationLink { DownloadsView() } label: { Label("Ver descargas", systemImage: "arrow.down.circle") }.themedRow() }
        }
        .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { r in
            switch r {
            case .success(let u): if DownloadFolder.choose(u) { folderName = DownloadFolder.displayName; folderError = nil } else { folderError = "No se pudo usar esa carpeta" }
            case .failure(let e): folderError = e.localizedDescription
            }
        }
        .themedScreen().navigationTitle("Descargas")
    }
}

/// Caché de imágenes: tope en MB, días que se guardan y borrado a mano.
struct ImageCacheSettingsView: View {
    @AppStorage("set.imgMB") private var mb = 300
    @AppStorage("set.imgDays") private var days = 14
    @EnvironmentObject var themes: ThemeStore
    @State private var used = ImageLoader.diskMB()

    var body: some View {
        List {
            Section {
                Text("Ahora ocupa \(used) MB").themedRow()
                Picker("Tope de espacio", selection: $mb) { ForEach([100, 200, 300, 500, 1000, 2000], id: \.self) { Text("\($0) MB").tag($0) }; Text("Sin tope").tag(0) }.themedRow()
                Picker("Borrar lo que lleve más de", selection: $days) { ForEach([1, 3, 7, 14, 30, 90], id: \.self) { Text("\($0) días").tag($0) }; Text("Nunca").tag(0) }.themedRow()
            } footer: { Text("Las carátulas ya vistas se guardan en el iPad para que carguen al instante. Al abrir la app se borra lo más viejo y, si se pasa del tope, lo menos usado.") }
            Section {
                Button { ImageLoader.prune(); used = ImageLoader.diskMB() } label: { Label("Limpiar ahora según estos límites", systemImage: "sparkles") }.themedRow()
                Button(role: .destructive) { ImageLoader.prune(clearAll: true); used = ImageLoader.diskMB() } label: { Label("Borrar todas las imágenes", systemImage: "trash") }.themedRow()
            }
        }
        .themedScreen().navigationTitle("Caché de imágenes")
    }
}

/// Reproducción: pantalla completa, resolución mínima y colchón.
struct PlaybackSettingsView: View {
    @AppStorage("set.minRes") private var minRes = -1
    @EnvironmentObject var themes: ThemeStore
    var body: some View {
        List {
            Section {
                Picker("Resolución mínima", selection: $minRes) {
                    Text("Automática").tag(0); Text("720p").tag(720); Text("1080p").tag(1080)
                    Text("La de esta pantalla (\(AppSettings.deviceVideoHeight)p)").tag(-1); Text("2160p").tag(2160)
                }.themedRow()
            } footer: { Text("El reproductor no baja de esta calidad si el vídeo la tiene (si no, usa la mejor disponible). Con red lenta puede cortarse. También se puede fijar a mano desde el reproductor.") }
            PlayerSettingsSection()
        }
        .themedScreen().navigationTitle("Reproducción")
    }
}

struct AboutView: View {
    var body: some View {
        List {
            LabeledContent("Versión", value: AppInfo.versionText).themedRow()
            LabeledContent("Dispositivo", value: UIDeviceInfo.summary).themedRow()
            Section {
                LabeledContent("ID del dispositivo", value: DeviceId.get).font(.body.monospaced()).textSelection(.enabled).themedRow()
            } footer: { Text("Se envía en el User-Agent al descargar las listas, para identificar qué aparato las pide:\n\(DeviceId.playlistUserAgent)") }
        }
        .themedScreen().navigationTitle("Acerca de")
    }
}

/// Formulario de una lista: nombre, dirección y cabeceras HTTP propias (una por línea). Las propias mandan sobre las del fichero
/// y viajan con la lista al enviarla por QR a otro aparato.
struct ListEditSheet: View {
    let title: String
    @Binding var name: String
    @Binding var url: String
    @Binding var headers: String
    let saveLabel: String
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Lista") {
                    TextField("Nombre", text: $name)
                    TextField("Dirección (M3U)", text: $url).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                }
                Section {
                    TextEditor(text: $headers).font(.system(.footnote, design: .monospaced)).frame(minHeight: 110)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Cabeceras propias") } footer: {
                    Text("Una por línea, «Nombre: valor». Ejemplo:\nUser-Agent: AppleCoreMedia\nReferer: https://sitio.tv/\nMandan sobre las del fichero de la lista y se envían con ella al transferirla.")
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar", action: cancel) }
                ToolbarItem(placement: .confirmationAction) { Button(saveLabel, action: save) }
            }
        }
    }
}

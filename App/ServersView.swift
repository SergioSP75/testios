import SwiftUI
import HLSCore

/// Servidores externos: Emby, Jellyfin y Plex. Entrada de cuenta y acceso a la biblioteca.
struct ServersView: View {
    @StateObject private var hub = ServerHub.shared
    @State private var loginFor: String?          // "emby" | "jellyfin" | "plex"
    @State private var ua = ServerUa.standard
    @AppStorage("set.mkvMode") private var mkvMode = "local"

    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?

    private static let titles = ["emby": "Emby", "jellyfin": "Jellyfin", "plex": "Plex"]

    var body: some View {
        List {
            ForEach(ServerHub.types, id: \.self) { type in
                let accounts = hub.accounts(of: type)
                Section {
                    ForEach(accounts, id: \.kind) { s in
                        if s.hasSession() {
                            NavigationLink { ServerBrowserView(backend: s, parent: nil, title: hub.tag(s)) } label: {
                                Label("\(s.icon) \(hub.tag(s))", systemImage: "externaldrive.connected.to.line.below")
                            }
                            .swipeActions {
                                Button("Borrar", role: .destructive) { deleting = s.kind }
                                Button("Editar") { loginFor = s.kind }.tint(.blue)
                                Button("Nombre") { newName = hub.customName(s.kind); renaming = s.kind }.tint(.orange)
                            }
                            .contextMenu {
                                Button { newName = hub.customName(s.kind); renaming = s.kind } label: { Label("Poner nombre", systemImage: "tag") }
                                Button { loginFor = s.kind } label: { Label("Editar acceso", systemImage: "pencil") }
                                Button(role: .destructive) { deleting = s.kind } label: { Label("Borrar cuenta", systemImage: "trash") }
                            }
                        } else {
                            Button { loginFor = s.kind } label: { Label("\(s.icon) Conectar \(Self.titles[type] ?? type)", systemImage: "plus.circle") }
                        }
                    }
                    if accounts.contains(where: { $0.hasSession() }) {
                        Button { loginFor = hub.addAccount(type: type) } label: { Label("Añadir otra cuenta de \(Self.titles[type] ?? type)", systemImage: "plus.square.on.square") }
                    }
                    if hub.active(of: type).count > 1 {
                        NavigationLink { MergedBrowserView(type: type) } label: {
                            Label("🔀 Todos los \(Self.titles[type] ?? type) (mezclados)", systemImage: "square.stack.3d.up")
                        }
                    }
                } header: { Text(Self.titles[type] ?? type) }
            }
            Text("Desliza hacia la izquierda una cuenta para borrarla, editarla o ponerle nombre. El nombre sale como etiqueta en las carátulas y fichas.").font(.caption).foregroundStyle(.secondary)
            Section {
                Picker("Si un vídeo es MKV", selection: $mkvMode) {
                    Text("Pasarlo a HLS aquí; si no, al servidor").tag("local")
                    Text("Pedirlo recodificado al servidor").tag("server")
                    Text("Solo avisar").tag("none")
                }.pickerStyle(.inline).labelsHidden()
            } header: { Text("Vídeos MKV (películas de servidores)") } footer: {
                Text("El iPad no abre el contenedor MKV. «Pasarlo a HLS aquí» lo reempaqueta en el propio dispositivo sin recodificar (H.264/HEVC con AAC, AC-3 o E-AC-3). Con audio DTS/TrueHD o vídeo AV1 no se puede y se pide al servidor que lo recodifique (si ese ajuste lo permite). También se usa al descargar.")
            }
            Section {
                TextField("User agent", text: $ua, axis: .vertical).font(.footnote).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("💾 Guardar") { ServerUa.standard = ua; ua = ServerUa.standard }
                Button("↺ Valor por defecto") { ServerUa.standard = ""; ua = ServerUa.standard }
            } header: { Text("User agent hacia los servidores") } footer: {
                Text("Se envía a Emby, Jellyfin, Plex y a los proxies de los .strm. Por defecto: \(ServerUa.defaultValue). Sirve para que un proxy reconozca la app. Ojo: el relé de los .strm solo da DASH (reproducible) si empieza por «Mozilla».")
            }
        }
        .id(hub.refresh)
        .themedScreen()
        .navigationTitle("Servidores")
        .onAppear { hub.prune() }
        .sheet(item: Binding(get: { loginFor.map { LoginTarget(slot: $0) } }, set: { if $0 == nil { loginFor = nil; hub.prune() } })) { t in
            ServerLoginView(slot: t.slot) { loginFor = nil; hub.prune(); hub.touch() }
        }
        .alert("Nombre de la cuenta", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Por ejemplo: Casa", text: $newName)
            Button("Guardar") { if let r = renaming { hub.setCustomName(newName, for: r) }; renaming = nil }
            Button("Cancelar", role: .cancel) { renaming = nil }
        } message: { Text("Se enseña como etiqueta en las películas de esta cuenta. Vacío = el nombre del servidor.") }
        .confirmationDialog("¿Borrar esta cuenta?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Borrar cuenta", role: .destructive) { if let d = deleting { hub.remove(d) }; deleting = nil }
            Button("Cancelar", role: .cancel) { deleting = nil }
        } message: { Text("Solo se cierra la sesión en este iPad; lo ya descargado se conserva.") }
    }
    struct LoginTarget: Identifiable { let slot: String; var id: String { slot } }
}

/// Formulario de entrada: servidor directo (Emby/Jellyfin), Emby Connect o enlace por código de plex.tv/link.
struct ServerLoginView: View {
    let slot: String
    let done: () -> Void
    private var type: String { String(slot.split(separator: "_").first ?? "emby") }
    @State private var accountName = ""
    @State private var url = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var useConnect = false
    @State private var busy = false
    @State private var message: String?
    @State private var pin: PlexPin?

    var body: some View {
        NavigationStack {
            Form {
                Section("Nombre (etiqueta)") { TextField("Por ejemplo: Casa, Trabajo…", text: $accountName) }
                if type == "plex" {
                    Section("Enlazar con plex.tv/link") {
                        if let pin { Text("Escribe este código en plex.tv/link: \(pin.code)").font(.headline) }
                        Button(pin == nil ? "Pedir código" : "Comprobar enlace") { Task { await plexLink() } }
                    }
                    Section("O con correo y contraseña") {
                        TextField("Correo", text: $user).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                        SecureField("Contraseña", text: $pass)
                        Button("Entrar") { Task { await plexPassword() } }
                    }
                } else {
                    if type == "emby" { Toggle("Emby Connect (correo)", isOn: $useConnect) }
                    if !useConnect {
                        TextField("Dirección (http://host:8096)", text: $url).textInputAutocapitalization(.never).keyboardType(.URL)
                    }
                    TextField(useConnect ? "Correo" : "Usuario", text: $user).textInputAutocapitalization(.never)
                    SecureField("Contraseña", text: $pass)
                    Button("Entrar") { Task { await login() } }
                }
                if busy { ProgressView() }
                if let m = message { Text(m).foregroundStyle(.red).font(.caption) }
            }
            .themedScreen()
            .navigationTitle(ServerHub.shared.backend(slot)?.hasSession() == true ? "Editar \(type.capitalized)" : "Conectar \(type.capitalized)")
            .toolbar { Button("Cerrar", action: done) }
            .onAppear { prefill() }
        }
    }

    /// Al editar una cuenta existente se rellenan sus datos.
    private func prefill() {
        accountName = ServerHub.shared.customName(slot)
        if let e = ServerHub.shared.backend(slot) as? EmbyClient, let a = e.account() {
            url = a.serverUrl; user = a.email; pass = a.password; useConnect = a.mode == "connect"
        }
    }

    @MainActor private func login() async {
        busy = true; message = nil; defer { busy = false }
        let hub = ServerHub.shared
        guard let c = hub.backend(slot) as? EmbyClient else { return }
        do {
            if useConnect && type == "emby" { try await c.loginConnect(email: user, password: pass) }
            else { try await c.loginDirect(serverUrl: url, user: user, password: pass, type: type) }
            hub.setCustomName(accountName, for: slot)
            done()
        } catch { message = error.localizedDescription }
    }

    @MainActor private func plexLink() async {
        busy = true; message = nil; defer { busy = false }
        guard let plex = ServerHub.shared.backend(slot) as? PlexClient else { return }
        do {
            if let p = pin {
                if let tok = try await plex.pollPin(p) { _ = try await plex.finishLogin(accountToken: tok); ServerHub.shared.setCustomName(accountName, for: slot); done() }
                else { message = "Todavía no se ha introducido el código" }
            } else { pin = try await plex.startPin() }
        } catch { message = error.localizedDescription }
    }

    @MainActor private func plexPassword() async {
        busy = true; message = nil; defer { busy = false }
        guard let plex = ServerHub.shared.backend(slot) as? PlexClient else { return }
        do { let tok = try await plex.signIn(email: user, password: pass); _ = try await plex.finishLogin(accountToken: tok); ServerHub.shared.setCustomName(accountName, for: slot); done() }
        catch { message = error.localizedDescription }
    }
}

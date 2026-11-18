import SwiftUI
import AVKit
import HLSCore

/// Vista de TV, como el reproductor de Android: lista de canales a la izquierda, el vídeo en el centro y la guía (EPG) del canal a la derecha.
/// Cada panel se puede activar o desactivar. En vertical el vídeo va arriba y los paneles debajo.
/// Con el tema «Transparente» el vídeo ocupa toda la pantalla y los paneles son de cristal encima.
struct ChannelListView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var themes: ThemeStore
    @Environment(\.dismiss) private var dismiss
    let playlist: PlaylistConfig

    @StateObject private var model = PlayerModel()
    @ObservedObject private var favs = ChannelFavorites.shared
    @ObservedObject private var history = ChannelHistory.shared
    @AppStorage("tv.showChannels") private var showChannels = true
    @AppStorage("tv.showEpg") private var showEpg = true

    @State private var current: IptvChannel?            // canal que suena
    @State private var watching: EpgProgram?            // programa pasado que se ve con catchup (nil = directo)
    @State private var guideChannel: IptvChannel?       // canal cuya guía se enseña a la derecha
    @State private var fullscreen = false
    @State private var showGrid = false
    @State private var overlayVisible = false
    @State private var overlayTask: Task<Void, Never>?
    @State private var toast: String?
    @State private var started = false

    // Lista de canales
    @State private var tab = 0                           // 0 todos · 1 favoritos · 2 historial
    @State private var search = ""
    @State private var groups: [ChannelGroupRows] = []
    @State private var numbers: [String: Int] = [:]
    @State private var expanded = Set<String>()
    @State private var collapsed = Set<String>()

    struct ChannelGroupRows: Identifiable { var id: String; var channels: [IptvChannel] }

    private var t: AppTheme { themes.theme }

    // MARK: - Estructura

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 700
            ZStack {
                (t.transparent ? Color.black : t.c(t.bg)).ignoresSafeArea()
                if t.transparent && !fullscreen { videoLayer.ignoresSafeArea() }
                VStack(spacing: 0) {
                    if !fullscreen { controlsBar }
                    if fullscreen {
                        videoLayer.ignoresSafeArea().overlay(alignment: .top) { fullscreenTop }.overlay(alignment: .bottom) { fullscreenStrip }
                    } else if wide {
                        HStack(spacing: 0) {
                            if showChannels { channelPanel.frame(width: geo.size.width * (showEpg ? 2.0 / 9 : 0.32)) }
                            videoSlot.frame(maxWidth: .infinity)
                            if showEpg { epgPanel.frame(width: geo.size.width * (showChannels ? 3.0 / 9 : 0.4)) }
                        }
                    } else {
                        videoSlot.frame(height: geo.size.width * 9 / 16)
                        HStack(spacing: 0) {
                            if showChannels { channelPanel.frame(maxWidth: .infinity) }
                            if showEpg { epgPanel.frame(maxWidth: .infinity) }
                            if !showChannels && !showEpg { Spacer() }
                        }
                    }
                }
                if let m = toast {
                    VStack { Spacer(); Text(m).font(.footnote.bold()).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.8), in: Capsule()).foregroundStyle(.white).padding(.bottom, 40) }
                        .transition(.opacity).allowsHitTesting(false)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(fullscreen)
        .persistentSystemOverlays(fullscreen ? .hidden : .automatic)
        .tint(t.accentColor)
        .preferredColorScheme(t.light && !t.transparent ? .light : .dark)
        .task { await store.open(playlist) }
        .task(id: "\(store.channels.count)") { rebuildNumbers(); rebuildGroups(); startLast() }
        .task(id: "\(tab)|\(search)|\(favs.ids.count)|\(history.ids.count)|\(store.channels.count)|\(current?.id ?? "")") { rebuildGroups() }
        .onAppear { EpgClock.shared.refresh() }
        .onDisappear { model.stop() }
        .fullScreenCover(isPresented: $showGrid) {
            EpgGridView(channels: store.channels, current: current,
                        onPlay: { ch, p in showGrid = false; play(ch, program: p) }, onClose: { showGrid = false })
                .environmentObject(store).environmentObject(themes)
        }
        .alert("Error", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("Vale", role: .cancel) {}
        } message: { Text(store.errorMessage ?? "") }
    }

    // MARK: - Barra de controles

    private var controlsBar: some View {
        HStack(spacing: 8) {
            barButton("chevron.left") { dismiss() }
            Text(playlist.name).font(.subheadline.bold()).lineLimit(1).foregroundStyle(t.accentColor)
            Spacer(minLength: 4)
            barButton("sidebar.left", on: showChannels) { withAnimation { showChannels.toggle() } }
            barButton("sidebar.right", on: showEpg) { withAnimation { showEpg.toggle() } }
            barButton("calendar") { EpgClock.shared.refresh(); showGrid = true }
            barButton("arrow.up.left.and.arrow.down.right") { withAnimation { fullscreen = true }; flashOverlay() }
            if model.player != nil { QualityMenu(model: model); TrackMenus(model: model) }
        }
        .foregroundStyle(t.c(t.icon)).padding(.horizontal, 10).padding(.vertical, 6)
        .background(t.transparent ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(t.c(t.bar)))
    }

    private func barButton(_ symbol: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body).frame(width: 40, height: 40)
                .foregroundStyle(on ? t.accentColor : t.c(t.icon))
                .background(on ? t.c(t.focusBg) : Color.clear, in: Circle())
        }
    }

    // MARK: - Vídeo

    /// Hueco del vídeo: el vídeo mismo, o (tema transparente) un hueco que deja ver el vídeo de fondo.
    @ViewBuilder private var videoSlot: some View {
        if t.transparent { Color.clear.contentShape(Rectangle()).onTapGesture { fullscreen = true; flashOverlay() } }
        else { videoLayer }
    }

    private var videoLayer: some View {
        ZStack {
            Color.black
            if let p = model.player { FullscreenVideo(player: p, onTap: { if fullscreen { flashOverlay() } }) }
            else if current == nil { Text("Elige un canal").foregroundStyle(.white.opacity(0.6)) }
            else { ProgressView().tint(.white) }
            if AppSettings.ownSubtitles { SubtitleOverlay(text: model.subtitleText) }
            VStack {
                Spacer()
                if let n = model.notice {
                    HStack(spacing: 8) { ProgressView().tint(.white); Text(n).font(.caption.bold()) }
                        .padding(.horizontal, 12).padding(.vertical, 6).background(.black.opacity(0.75), in: Capsule()).foregroundStyle(.white).padding(8)
                } else if let e = model.errorText {
                    Text(e).font(.caption2).lineLimit(3).foregroundStyle(.red).padding(6).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8)).padding(8)
                }
            }
        }
    }

    // MARK: - Pantalla completa

    private var fullscreenTop: some View {
        HStack(spacing: 10) {
            if overlayVisible {
                Button { withAnimation { fullscreen = false } } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle())
                }
                Spacer()
                QualityMenu(model: model); TrackMenus(model: model)
            }
        }.foregroundStyle(.white).padding(.horizontal, 12).padding(.top, 44)
    }

    /// Franja con el programa en emisión (o el que se ve con catchup) y el siguiente, unos segundos al cambiar de canal o tocar.
    @ViewBuilder private var fullscreenStrip: some View {
        if overlayVisible, let ch = current {
            FullscreenStrip(channel: ch, watching: watching).environmentObject(store).environmentObject(themes)
                .padding(.horizontal, 12).padding(.bottom, 16)
        }
    }

    private func flashOverlay() {
        overlayVisible = true
        overlayTask?.cancel()
        overlayTask = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if !Task.isCancelled { withAnimation { overlayVisible = false } } }
    }

    // MARK: - Reproducción

    /// Arranca un canal; con `program` (ya emitido) lo ve con catchup si la lista lo permite.
    private func play(_ ch: IptvChannel, program: EpgProgram? = nil) {
        var target = ch
        if let p = program {
            let r = CatchupUrlBuilder.build(channel: ch, program: p)
            guard r.allowed, let c = r.channel else { showToast("Catchup no disponible: \(r.reason)"); return }
            target = c; watching = p
        } else { watching = nil }
        current = ch; guideChannel = ch; history.add(ch)
        flashOverlay()
        Task { await model.play(target) }
    }

    /// Al abrir, sigue con el último canal visto de esta lista.
    private func startLast() {
        guard !started, current == nil, let id = history.last, let ch = store.channels.first(where: { $0.id == id }) else { return }
        started = true
        play(ch)
    }

    private func showToast(_ m: String) {
        withAnimation { toast = m }
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); withAnimation { toast = nil } }
    }

    // MARK: - Panel de canales

    private func rebuildNumbers() {
        var n: [String: Int] = [:]
        for (i, c) in store.channels.enumerated() where n[c.id] == nil { n[c.id] = i + 1 }
        numbers = n
    }

    private func rebuildGroups() {
        var base = store.channels
        switch tab {
        case 1: base = base.filter { favs.ids.contains($0.id) }
        case 2:
            let order = Dictionary(uniqueKeysWithValues: history.ids.enumerated().map { ($1, $0) })
            base = base.filter { order[$0.id] != nil }.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        default: break
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { base = base.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        if tab == 0 {
            var order: [String] = [], map: [String: [IptvChannel]] = [:]
            for c in base { let g = c.group ?? "CANALES"; if map[g] == nil { order.append(g) }; map[g, default: []].append(c) }
            groups = order.map { ChannelGroupRows(id: $0, channels: map[$0] ?? []) }
        } else {
            groups = base.isEmpty ? [] : [ChannelGroupRows(id: tab == 1 ? "FAVORITOS" : "HISTORIAL", channels: base)]
        }
    }

    private func isExpanded(_ g: ChannelGroupRows) -> Bool {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if expanded.contains(g.id) { return true }
        if collapsed.contains(g.id) { return false }
        // Un solo grupo (o favoritos e historial) se ve abierto; en los demás, el del canal que suena
        return groups.count == 1 || g.channels.contains { $0.id == current?.id }
    }

    private var channelPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("MediaKillerSP75").font(.headline).foregroundStyle(t.accentColor).lineLimit(1)
                Spacer()
                pill("chevron.up") { expanded = []; collapsed = Set(groups.map { $0.id }) }
                pill("chevron.down") { collapsed = []; expanded = Set(groups.map { $0.id }) }
            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            HStack(spacing: 0) {
                ForEach(Array(["TODOS", "FAVS", "HISTOR"].enumerated()), id: \.offset) { i, name in
                    Button { tab = i } label: {
                        Text(name).font(.caption.bold()).frame(maxWidth: .infinity).padding(.vertical, 8)
                            .foregroundStyle(tab == i ? t.accentColor : t.c(t.tabOff))
                    }.buttonStyle(.plain)
                }
            }
            Rectangle().fill(t.accentColor).frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(t.c(t.dim))
                TextField("Buscar canal...", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(t.c(t.dim)) } }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(t.c(t.input), in: Capsule()).overlay(Capsule().stroke(t.c(t.border), lineWidth: 1))
            .padding(.horizontal, 10).padding(.vertical, 6)
            if store.isLoading && store.channels.isEmpty { ProgressView().padding() }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(groups) { g in
                        let open = isExpanded(g)
                        Button {
                            if open { expanded.remove(g.id); collapsed.insert(g.id) } else { collapsed.remove(g.id); expanded.insert(g.id) }
                        } label: {
                            HStack {
                                Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
                                Text("\(g.id.uppercased()) (\(g.channels.count))").font(.caption.bold()).lineLimit(1)
                                Spacer()
                            }
                            .foregroundStyle(t.accentColor).padding(.horizontal, 10).padding(.vertical, 9)
                            .background(t.c(t.group))
                        }.buttonStyle(.plain)
                        if open {
                            ForEach(g.channels) { ch in
                                ChannelRow(channel: ch, number: numbers[ch.id] ?? 0, selected: ch.id == current?.id, previewing: ch.id == guideChannel?.id,
                                           isFav: favs.ids.contains(ch.id),
                                           onPlay: { play(ch) }, onFav: { toggleFav(ch) }, onGuide: { guideChannel = ch; if !showEpg { showEpg = true } })
                            }
                        }
                    }
                    if groups.isEmpty && !store.isLoading {
                        Text(tab == 1 ? "Aún no hay favoritos: toca la estrella de un canal" : tab == 2 ? "Aún no has visto ningún canal" : "Sin canales")
                            .font(.footnote).foregroundStyle(t.c(t.dim)).padding(20)
                    }
                }
            }
        }
        .background(panelBackground(t.panel))
        .foregroundStyle(t.c(t.text))
    }

    private func pill(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.caption.bold()).foregroundStyle(t.accentColor).padding(.horizontal, 12).padding(.vertical, 6)
                .background(t.c(t.card), in: Capsule()).overlay(Capsule().stroke(t.accentColor.opacity(0.5), lineWidth: 1))
        }
    }

    private func toggleFav(_ ch: IptvChannel) {
        let on = favs.toggle(ch)
        showToast(on ? "Añadido a favoritos: \(ch.name)" : "Quitado de favoritos: \(ch.name)")
    }

    private func panelBackground(_ color: UInt32) -> some View {
        Group { if t.transparent { Rectangle().fill(.ultraThinMaterial) } else { t.c(color) } }.ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Panel de guía

    private var epgPanel: some View {
        EpgPanel(channel: guideChannel ?? current, playing: (guideChannel ?? current)?.id == current?.id,
                 watching: (guideChannel ?? current)?.id == current?.id ? watching : nil,
                 onPlay: { prog in if let ch = guideChannel ?? current { play(ch, program: prog) } },
                 onClose: { withAnimation { showEpg = false } })
            .background(panelBackground(t.panelEpg))
    }
}

// MARK: - Fila de canal

/// Un canal de la lista: número, logo, nombre, programa en emisión con su barra de avance (se actualiza sola con la hora) y estrella de favorito.
struct ChannelRow: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var themes: ThemeStore
    @ObservedObject private var clock = EpgClock.shared
    let channel: IptvChannel
    let number: Int
    let selected: Bool
    let previewing: Bool
    let isFav: Bool
    let onPlay: () -> Void
    let onFav: () -> Void
    let onGuide: () -> Void

    var body: some View {
        let t = themes.theme
        let prog = store.epgReady ? store.epg.nowAndNext(for: channel, now: clock.nowMs).now : nil
        HStack(spacing: 8) {
            Text(number > 0 ? "\(number)" : "").font(.caption2.monospacedDigit()).foregroundStyle(t.c(t.tabOff)).frame(width: 30, alignment: .trailing)
            PosterImage(url: channel.bestLogo ?? store.epg.icon(for: channel), maxPixel: 120, fit: true) { Color.gray.opacity(0.15) }
                .frame(width: 38, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.subheadline.weight(selected ? .bold : .regular)).lineLimit(1)
                if let p = prog {
                    Text(p.program.title).font(.caption2).foregroundStyle(t.c(t.dim)).lineLimit(1)
                    ProgressView(value: min(1, max(0, Double(clock.nowMs - p.start) / Double(max(1, p.stop - p.start)))))
                        .tint(t.accentColor).scaleEffect(x: 1, y: 0.6, anchor: .center)
                } else if let g = channel.group, !store.epgReady { Text(g).font(.caption2).foregroundStyle(t.c(t.dim)).lineLimit(1) }
            }
            Spacer(minLength: 2)
            Button(action: onGuide) { Image(systemName: "list.bullet.rectangle").font(.caption).foregroundStyle(previewing ? t.accentColor : t.c(t.dim)) }
                .buttonStyle(.borderless)
            Button(action: onFav) { Image(systemName: isFav ? "star.fill" : "star").font(.subheadline).foregroundStyle(isFav ? t.c(t.fav) : t.c(t.dim)) }
                .buttonStyle(.borderless)
        }
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 6)
        .background(selected ? t.c(t.selRow) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .contextMenu {
            Button { onFav() } label: { Label(isFav ? "Quitar de favoritos" : "Añadir a favoritos", systemImage: isFav ? "star.slash" : "star") }
            Button { onGuide() } label: { Label("Ver su guía", systemImage: "list.bullet.rectangle") }
        }
    }
}

// MARK: - Franja de pantalla completa

struct FullscreenStrip: View {
    @EnvironmentObject var store: PlaylistStore
    @ObservedObject private var clock = EpgClock.shared
    let channel: IptvChannel
    let watching: EpgProgram?

    var body: some View {
        let nn: (now: EpgStore.Slot?, next: EpgStore.Slot?) = store.epgReady ? store.epg.nowAndNext(for: channel, now: clock.nowMs) : (nil, nil)
        let shownTitle = watching?.title ?? nn.now?.program.title
        let ws = EpgTime.parseMillis(watching?.start), we = EpgTime.parseMillis(watching?.stop)
        let startMs = ws ?? nn.now?.start, stopMs = we ?? nn.now?.stop
        VStack(alignment: .leading, spacing: 3) {
            Text(channel.name).font(.caption.bold()).foregroundStyle(.cyan)
            Text((shownTitle ?? channel.name) + ((startMs != nil && stopMs != nil) ? "  (\(EpgFormat.hour(startMs!)) - \(EpgFormat.hour(stopMs!)))" : ""))
                .font(.headline).lineLimit(1)
            if let d = nn.now?.program.description, watching == nil { Text(d).font(.caption).lineLimit(2).foregroundStyle(.white.opacity(0.8)) }
            if let n = nn.next { Text("A continuación: \(EpgFormat.hour(n.start))  \(n.program.title)").font(.caption).foregroundStyle(.white.opacity(0.7)) }
        }
        .foregroundStyle(.white).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }
}

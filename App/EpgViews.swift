import SwiftUI
import HLSCore

// MARK: - Panel de guía del reproductor (derecha)

/// Guía de un canal junto al vídeo, como el panel EPG de Android: imagen, detalle del programa y lista desde el principio del día.
/// Se coloca sola sobre el programa en emisión (o el que se ve con catchup) y avanza con la hora. Tocar un programa pasado lo ve con catchup.
struct EpgPanel: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var themes: ThemeStore
    @ObservedObject private var clock = EpgClock.shared
    let channel: IptvChannel?
    let playing: Bool                       // el canal de la guía es el que suena
    let watching: EpgProgram?               // programa pasado en catchup
    let onPlay: (EpgProgram?) -> Void       // nil = volver al directo
    let onClose: () -> Void

    @State private var detailId: String?
    @State private var daysBack = 0         // días anteriores añadidos a mano
    @State private var blocksAhead = 0      // bloques de 10 h añadidos al final

    private let day: Int64 = 86_400_000, hour: Int64 = 3_600_000

    private var from: Int64 {
        let watchStart = EpgTime.parseMillis(watching?.start).map { $0 - 2 * hour } ?? Int64.max
        return min(EpgFormat.startOfDay(clock.nowMs), watchStart) - Int64(daysBack) * day
    }
    private var to: Int64 { clock.nowMs + 10 * hour + Int64(blocksAhead) * 10 * hour }

    private func isNow(_ s: EpgStore.Slot) -> Bool {
        if let w = watching { return w.start == s.program.start && w.title == s.program.title }
        return s.start <= clock.nowMs && clock.nowMs < s.stop
    }

    var body: some View {
        let t = themes.theme
        let slots: [EpgStore.Slot] = (store.epgReady && channel != nil) ? store.epg.slots(for: channel!, from: from, to: to) : []
        let nowSlot = slots.first(where: isNow)
        let shown = slots.first(where: { $0.id == detailId }) ?? nowSlot
        let live = store.epgReady && channel != nil ? store.epg.nowAndNext(for: channel!, now: clock.nowMs).now : nil
        VStack(spacing: 0) {
            // Cabecera: canal y lo que se emite
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel?.name ?? "Guía").font(.headline).foregroundStyle(t.accentColor).lineLimit(1)
                    Text(watching != nil && playing ? "⏮ Catchup: \(shown?.program.title ?? watching!.title)" : (live?.program.title ?? (store.epgReady ? "Sin guía" : "Cargando guía...")))
                        .font(.caption).foregroundStyle(t.c(t.dim)).lineLimit(1)
                    if !playing, channel != nil { Text("👁 Vista previa · toca el canal para verlo").font(.caption2).foregroundStyle(t.c(t.dim)) }
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(t.c(t.dim)).frame(width: 36, height: 36) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(t.c(t.header))

            if let ch = channel {
                PosterImage(url: shown?.program.bestImage ?? store.epg.icon(for: ch) ?? ch.bestLogo, maxPixel: 600, fit: true) { Color.clear }
                    .frame(height: 110).padding(.vertical, 4)
            }
            // Detalle del programa elegido (el que suena, o el que se toca)
            VStack(alignment: .leading, spacing: 3) {
                Text(shown?.program.title ?? "Sin guía").font(.subheadline.bold()).lineLimit(2).foregroundStyle(t.c(t.text))
                if let s = shown { Text("\(EpgFormat.hour(s.start)) - \(EpgFormat.hour(s.stop))").font(.caption).foregroundStyle(t.accentColor) }
                if shown != nil {
                    Text(shown?.program.description.flatMap { $0.isEmpty ? nil : $0 } ?? "Sin sinopsis disponible.")
                        .font(.caption).foregroundStyle(t.c(t.text3)).lineLimit(5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6).background(t.c(t.header))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if daysBack < AppSettings.epgDays {
                            Button { daysBack += 1 } label: { Text("▲ Programas anteriores").font(.caption).frame(maxWidth: .infinity).padding(8) }
                                .buttonStyle(.plain).foregroundStyle(t.accentColor)
                        }
                        ForEach(slots) { s in row(s, isNow: isNow(s), t: t) }
                        if slots.isEmpty { Text(store.epgReady ? "Sin programas disponibles" : "Cargando guía...").font(.footnote).foregroundStyle(t.c(t.dim)).padding(20) }
                        else if blocksAhead < 4 {
                            Button { blocksAhead += 1 } label: { Text("▼ Más programas").font(.caption).frame(maxWidth: .infinity).padding(8) }
                                .buttonStyle(.plain).foregroundStyle(t.accentColor)
                        }
                    }
                }
                // Al abrir y al cambiar de canal se coloca sobre el programa actual; con el paso del tiempo, sigue al que toca
                .task(id: "\(channel?.id ?? "")|\(store.epgReady)|\(watching?.start ?? "")") {
                    detailId = nil; daysBack = 0; blocksAhead = 0
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if let id = nowSlot?.id { proxy.scrollTo(id, anchor: .top) }
                }
                .onChange(of: nowSlot?.id) { id in
                    if let id = id { withAnimation { proxy.scrollTo(id, anchor: .top) } }
                }
            }
        }
        .foregroundStyle(t.c(t.text))
    }

    private func row(_ s: EpgStore.Slot, isNow now: Bool, t: AppTheme) -> some View {
        let past = s.stop <= clock.nowMs && !now
        let canCatchup = !(channel?.catchup ?? "").isEmpty || !(channel?.catchupSource ?? "").isEmpty
        return HStack(spacing: 10) {
            if let u = s.program.icon ?? s.program.image, !u.isEmpty {
                PosterImage(url: u, maxPixel: 200) { Color.gray.opacity(0.15) }.frame(width: 70, height: 44).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(s.program.title).font(.subheadline.weight(now ? .bold : .regular)).foregroundStyle(now ? t.c(t.text) : t.c(t.text2)).lineLimit(2)
                    if past && canCatchup { Image(systemName: "backward.end.alt").font(.caption2).foregroundStyle(t.accentColor) }
                }
                Text("\(EpgFormat.hour(s.start)) - \(EpgFormat.hour(s.stop))").font(.caption).foregroundStyle(t.c(t.dim))
                if let d = s.program.description, !d.isEmpty { Text(d).font(.caption2).foregroundStyle(t.c(t.dim)).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(now ? t.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .id(s.id)
        .onTapGesture {
            if past { detailId = s.id; onPlay(s.program) }                    // ya emitido → catchup
            else if now && (watching != nil || !playing) { detailId = nil; onPlay(nil) }   // volver al directo / ver el canal
            else { detailId = s.id }                                          // en emisión o futuro → solo detalle
        }
    }
}

// MARK: - Guía completa en rejilla

/// Rejilla de toda la programación (canales en vertical, horas en horizontal), como EpgActivity de Android:
/// se abre sobre la hora actual, la línea roja de «ahora» y la posición avanzan solas, y se puede ir por horas, por días o buscar.
/// Tocar un programa en emisión lo pone en directo; tocar uno ya emitido lo ve con catchup.
struct EpgGridView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var themes: ThemeStore
    @ObservedObject private var clock = EpgClock.shared
    @ObservedObject private var favs = ChannelFavorites.shared
    let channels: [IptvChannel]
    let current: IptvChannel?
    let onPlay: (IptvChannel, EpgProgram?) -> Void
    let onClose: () -> Void

    private let slotW: CGFloat = 150            // ancho de media hora
    private let rowH: CGFloat = 62
    private let chanW: CGFloat = 170
    private let slotMs: Int64 = 1_800_000
    private let windowHours = 24

    @State private var visibleStart: Int64 = EpgFormat.startOfDay(EpgClock.currentMs())
    @State private var anchor: Int64 = EpgClock.currentMs()
    @State private var followNow = true
    @State private var kick = 0
    @State private var offsetX: CGFloat = 0
    @State private var rows: [IptvChannel] = []
    @State private var guideToChannel: [String: IptvChannel] = [:]
    @State private var preview: (ch: IptvChannel, slot: EpgStore.Slot)?
    @State private var showSearch = false
    @State private var toast: String?

    private var windowEnd: Int64 { visibleStart + Int64(windowHours) * 3_600_000 }
    private func px(_ ms: Int64) -> CGFloat { CGFloat(ms - visibleStart) / CGFloat(slotMs) * slotW }

    var body: some View {
        // El ancho de la rejilla (48 franjas) es enorme: se fija el de la pantalla para que no ensanche la vista y
        // deje fuera la columna de canales y los botones.
        GeometryReader { geo in gridBody(width: geo.size.width).frame(width: geo.size.width, height: geo.size.height).clipped() }
            .background(themes.theme.c(themes.theme.panel).ignoresSafeArea())
    }

    private func gridBody(width w: CGFloat) -> some View {
        let t = themes.theme
        let scrollW = max(100, w - chanW)
        return VStack(spacing: 0) {
            previewPanel(t)
            navBar(t)
            // Cabecera de horas: sigue el desplazamiento horizontal de la rejilla
            HStack(spacing: 0) {
                Color.clear.frame(width: chanW, height: 26)
                HStack(spacing: 0) {
                    ForEach(0..<(windowHours * 2), id: \.self) { i in
                        let ms = visibleStart + Int64(i) * slotMs
                        let midnight = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: Double(ms) / 1000)) == 0
                            && Calendar.current.component(.minute, from: Date(timeIntervalSince1970: Double(ms) / 1000)) == 0
                        Text(midnight ? EpgFormat.day(ms) : EpgFormat.hour(ms)).font(.caption.monospacedDigit())
                            .foregroundStyle(t.c(t.dim)).frame(width: slotW, alignment: .leading).padding(.leading, 4)
                    }
                }
                .offset(x: -offsetX).frame(width: scrollW, alignment: .leading).clipped()
            }
            .background(t.c(t.header))
            grid(t, scrollW: scrollW)
        }
        .background(t.c(t.panel).ignoresSafeArea())
        .foregroundStyle(t.c(t.text))
        .tint(t.accentColor)
        .preferredColorScheme(t.light ? .light : .dark)
        .overlay(alignment: .bottom) {
            if let m = toast { Text(m).font(.footnote.bold()).padding(.horizontal, 14).padding(.vertical, 8).background(.black.opacity(0.8), in: Capsule())
                .foregroundStyle(.white).padding(.bottom, 30).allowsHitTesting(false) }
        }
        .task(id: "\(channels.count)|\(store.epgReady)") { rebuildRows() }
        .sheet(isPresented: $showSearch) { searchSheet.environmentObject(themes) }
        .onAppear { clock.refresh() }
    }

    // MARK: Partes

    private func previewPanel(_ t: AppTheme) -> some View {
        HStack(spacing: 12) {
            PosterImage(url: preview?.slot.program.bestImage ?? preview?.slot.program.icon ?? preview.flatMap { store.epg.icon(for: $0.ch) ?? $0.ch.bestLogo }, maxPixel: 400, fit: true) { Color.gray.opacity(0.12) }
                .frame(width: 130, height: 80)
            VStack(alignment: .leading, spacing: 3) {
                if let p = preview {
                    Text(p.slot.program.title).font(.headline).lineLimit(1)
                    Text("\(p.ch.name) | \(EpgFormat.hour(p.slot.start)) - \(EpgFormat.hour(p.slot.stop))").font(.caption).foregroundStyle(t.accentColor)
                    Text(p.slot.program.description ?? "").font(.caption).foregroundStyle(t.c(t.dim)).lineLimit(3)
                } else {
                    Text("Selecciona un programa").font(.headline)
                    Text("Toca para ver detalles").font(.caption).foregroundStyle(t.c(t.dim))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 96).background(t.c(t.panelEpg))
    }

    private func navBar(_ t: AppTheme) -> some View {
        HStack(spacing: 8) {
            navButton("✕ Salir", t) { onClose() }
            navButton("◀ -2h", t) { move(-2 * 3_600_000) }
            navButton("Hoy", t) { goToday() }
            navButton("+2h ▶", t) { move(2 * 3_600_000) }
            Menu {
                let cal = Calendar.current
                ForEach(-AppSettings.epgDays...1, id: \.self) { i in
                    let d = cal.date(byAdding: .day, value: i, to: cal.startOfDay(for: Date())) ?? Date()
                    let ms = Int64(d.timeIntervalSince1970 * 1000)
                    Button(i == 0 ? "Hoy · \(EpgFormat.day(ms))" : EpgFormat.day(ms)) {
                        // Día elegido: ventana desde las 00:00; ancla = ahora si es hoy, si no las 20:00
                        visibleStart = ms; followNow = (i == 0)
                        anchor = i == 0 ? clock.nowMs : ms + 20 * 3_600_000
                        kick += 1
                    }
                }
            } label: { navLabel("📅 Día", t) }
            navButton("🔍 Buscar", t) { showSearch = true }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6).background(t.c(t.bar))
    }

    private func navLabel(_ text: String, _ t: AppTheme) -> some View {
        Text(text).font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 8)
            .background(t.c(t.card), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(t.c(t.text))
    }
    private func navButton(_ text: String, _ t: AppTheme, action: @escaping () -> Void) -> some View {
        Button(action: action) { navLabel(text, t) }.buttonStyle(.plain)
    }

    private func grid(_ t: AppTheme, scrollW: CGFloat) -> some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                // Columna de canales (fija a la izquierda)
                LazyVStack(spacing: 0) {
                    ForEach(rows) { ch in channelCell(ch, t) }
                }.frame(width: chanW)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                // Marcas de cada media hora: a donde se desplaza la rejilla
                                HStack(spacing: 0) { ForEach(0..<(windowHours * 2), id: \.self) { i in Color.clear.frame(width: slotW, height: 1).id(i) } }
                                    .background(GeometryReader { g in Color.clear.preference(key: GridOffsetKey.self, value: -g.frame(in: .named("grid")).minX) })
                                LazyVStack(spacing: 0) { ForEach(rows) { ch in programRow(ch, t) } }
                            }
                            // Línea roja de «ahora»
                            if clock.nowMs >= visibleStart && clock.nowMs < windowEnd {
                                Rectangle().fill(Color.red).frame(width: 2, height: CGFloat(rows.count) * rowH + 1).offset(x: px(clock.nowMs))
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(width: CGFloat(windowHours * 2) * slotW, alignment: .topLeading)
                    }
                    .frame(width: scrollW)
                    .coordinateSpace(name: "grid")
                    .onPreferenceChange(GridOffsetKey.self) { offsetX = max(0, $0) }
                    // Si el usuario mueve la rejilla a mano, deja de seguir la hora
                    .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in followNow = false })
                    // Se coloca en la hora ancla (una hora de margen a la izquierda) al abrir, al navegar y, si sigue la hora, al cambiar de franja
                    .task(id: "\(visibleStart)|\(kick)|\(rows.count)") {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        let i = max(0, min(windowHours * 2 - 1, Int((anchor - 3_600_000 - visibleStart) / slotMs)))
                        proxy.scrollTo(i, anchor: .leading)
                    }
                    .onChange(of: Int((clock.nowMs - visibleStart) / slotMs)) { _ in
                        if followNow { anchor = clock.nowMs; kick += 1 }
                    }
                }
            }
        }
    }

    private func channelCell(_ ch: IptvChannel, _ t: AppTheme) -> some View {
        let focus = ch.id == current?.id || ch.id == preview?.ch.id
        return HStack(spacing: 8) {
            PosterImage(url: ch.bestLogo ?? store.epg.icon(for: ch), maxPixel: 120, fit: true) { Color.gray.opacity(0.15) }.frame(width: 44, height: 34)
            Text(ch.name).font(.caption.weight(.semibold)).lineLimit(2)
            Spacer(minLength: 0)
            if favs.ids.contains(ch.id) { Image(systemName: "star.fill").font(.caption2).foregroundStyle(t.c(t.fav)) }
        }
        .padding(.horizontal, 8).frame(height: rowH)
        .background(focus ? t.c(t.selRow) : t.c(t.panelEpg))
        .overlay(Rectangle().fill(t.c(t.divider)).frame(height: 0.5), alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture { onPlay(ch, nil) }
        .contextMenu {
            let on = favs.ids.contains(ch.id)
            Button { let now = favs.toggle(ch); flash(now ? "Añadido a favoritos: \(ch.name)" : "Quitado de favoritos: \(ch.name)") } label: {
                Label(on ? "Quitar de favoritos" : "Añadir a favoritos", systemImage: on ? "star.slash" : "star")
            }
            Button { onPlay(ch, nil) } label: { Label("Ver en directo", systemImage: "play.fill") }
        }
    }

    private struct Cell: Identifiable { var id: String; var width: CGFloat; var slot: EpgStore.Slot? }

    /// Programas de una fila con huecos entre medias, cada uno con su ancho según la duración.
    private func cells(_ ch: IptvChannel) -> [Cell] {
        var out: [Cell] = []
        var cursor = visibleStart
        for s in store.epg.slots(for: ch, from: visibleStart, to: windowEnd) {
            let st = max(s.start, visibleStart), en = min(s.stop, windowEnd)
            if en <= cursor { continue }
            let from = max(st, cursor)
            if from > cursor { out.append(Cell(id: "g\(cursor)", width: px(from) - px(cursor), slot: nil)) }
            out.append(Cell(id: s.id, width: max(10, px(en) - px(from)), slot: s))
            cursor = en
        }
        if cursor < windowEnd { out.append(Cell(id: "e\(cursor)", width: px(windowEnd) - px(cursor), slot: nil)) }
        return out
    }

    private func programRow(_ ch: IptvChannel, _ t: AppTheme) -> some View {
        HStack(spacing: 0) {
            ForEach(cells(ch)) { c in
                if let s = c.slot { programCell(ch, s, width: c.width, t) } else { Color.clear.frame(width: c.width, height: rowH) }
            }
        }
        .frame(height: rowH, alignment: .leading)
    }

    private func programCell(_ ch: IptvChannel, _ s: EpgStore.Slot, width: CGFloat, _ t: AppTheme) -> some View {
        let now = s.start <= clock.nowMs && clock.nowMs < s.stop
        let selected = preview?.slot.id == s.id && preview?.ch.id == ch.id
        return VStack(alignment: .leading, spacing: 2) {
            Text(s.program.title).font(.caption.weight(now ? .bold : .regular)).lineLimit(1)
            Text(EpgFormat.hour(s.start)).font(.caption2).foregroundStyle(now ? t.c(t.text2) : t.c(t.dim))
        }
        .padding(.leading, 8).padding(.trailing, 4)
        .frame(width: max(1, width - 1), height: rowH - 1, alignment: .leading)
        .background(selected ? t.accentColor.opacity(0.45) : now ? t.accentColor.opacity(0.28) : t.c(t.card))
        .clipped()
        .padding(.trailing, 1).padding(.bottom, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            preview = (ch, s)
            if now { onPlay(ch, nil) }
            else if s.stop <= clock.nowMs {
                let r = CatchupUrlBuilder.build(channel: ch, program: s.program)
                if r.allowed { onPlay(ch, s.program) } else { flash("Catchup no disponible: \(r.reason)") }
            }
        }
    }

    // MARK: Navegación

    private func rebuildRows() {
        guard store.epgReady else { rows = []; return }
        rows = channels.filter { !$0.isPlaylistGroup && store.epg.hasPrograms(for: $0) }
        var m: [String: IptvChannel] = [:]
        for ch in rows { if let id = store.epg.guideId(for: ch), m[id] == nil { m[id] = ch } }
        guideToChannel = m
    }

    /// Hora que se ve ahora a la izquierda de la rejilla.
    private func scrollTime() -> Int64 { visibleStart + Int64(offsetX / slotW * CGFloat(slotMs)) }

    /// Mueve la vista ±2 h; si se sale de las 24 h cargadas, se mueve la ventana.
    private func move(_ delta: Int64) {
        followNow = false
        anchor = scrollTime() + 3_600_000 + delta
        if anchor < visibleStart || anchor > windowEnd - 4 * 3_600_000 { visibleStart = anchor - 12 * 3_600_000 }
        kick += 1
    }

    private func goToday() {
        visibleStart = EpgFormat.startOfDay(clock.nowMs); anchor = clock.nowMs; followNow = true; kick += 1
    }

    private func flash(_ m: String) {
        withAnimation { toast = m }
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); withAnimation { toast = nil } }
    }

    // MARK: Búsqueda

    @State private var query = ""
    private var results: [(EpgProgram, IptvChannel, Int64)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { return [] }
        return store.epg.search(q, limit: 80).compactMap { p in
            guard let ch = guideToChannel[p.channelId], let ms = EpgTime.parseMillis(p.start) else { return nil }
            return (p, ch, ms)
        }.sorted { $0.2 < $1.2 }
    }

    private var searchSheet: some View {
        let t = themes.theme
        return NavigationStack {
            List {
                if query.count < 3 { Text("Escribe al menos 3 letras").foregroundStyle(t.c(t.dim)).listRowBackground(t.c(t.card)) }
                ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                    Button {
                        // Lleva la rejilla a ese programa
                        visibleStart = EpgFormat.startOfDay(r.2); anchor = r.2; followNow = false; kick += 1
                        preview = (r.1, EpgStore.Slot(program: r.0, start: r.2, stop: EpgTime.parseMillis(r.0.stop) ?? r.2 + 3_600_000))
                        showSearch = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.0.title).foregroundStyle(t.c(t.text))
                            Text("\(r.1.name) - \(EpgFormat.full(r.2))").font(.caption).foregroundStyle(t.c(t.dim))
                        }
                    }.listRowBackground(t.c(t.card))
                }
            }
            .scrollContentBackground(.hidden).background(t.c(t.panel))
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar programa")
            .navigationTitle("Buscar en la guía").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cerrar") { showSearch = false } } }
        }
        .tint(t.accentColor).preferredColorScheme(t.light ? .light : .dark)
    }
}

private struct GridOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

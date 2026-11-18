import SwiftUI
import AVFoundation
import HLSCore

/// Aspecto de los subtítulos (como en Android: tamaño, color, fondo y posición).
enum SubtitleStyle {
    static let colors: [(key: String, label: String, color: Color)] = [
        ("white", "Blanco", .white), ("yellow", "Amarillo", .yellow), ("cyan", "Cian", .cyan), ("green", "Verde", .green), ("orange", "Naranja", .orange)
    ]
    static func color(_ key: String) -> Color { colors.first { $0.key == key }?.color ?? .white }
}

/// Dibuja el subtítulo actual con el estilo de Ajustes. No recibe toques (no estorba al reproductor).
struct SubtitleOverlay: View {
    let text: String
    @AppStorage("sub.size") private var size = 28.0
    @AppStorage("sub.color") private var colorKey = "white"
    @AppStorage("sub.bg") private var bg = 0.45
    @AppStorage("sub.bottom") private var bottom = 0.10        // distancia al borde de abajo, en fracción de la altura
    @AppStorage("sub.bold") private var bold = true

    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer()
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: size, weight: bold ? .bold : .regular))
                        .foregroundStyle(SubtitleStyle.color(colorKey))
                        .multilineTextAlignment(.center)
                        .shadow(color: .black, radius: 2).shadow(color: .black, radius: 2)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.black.opacity(bg), in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: geo.size.width * 0.9)
                        .padding(.bottom, geo.size.height * bottom)
                }
            }.frame(maxWidth: .infinity)
        }.allowsHitTesting(false)
    }
}

/// Menú «Aa» del reproductor: tamaño, posición y color de los subtítulos sin salir de la película.
struct SubtitleStyleMenu: View {
    @AppStorage("sub.size") private var size = 28.0
    @AppStorage("sub.color") private var colorKey = "white"
    @AppStorage("sub.bottom") private var bottom = 0.10
    var body: some View {
        Menu {
            Button { size = min(80, size + 4) } label: { Label("Más grandes", systemImage: "textformat.size.larger") }
            Button { size = max(14, size - 4) } label: { Label("Más pequeños", systemImage: "textformat.size.smaller") }
            Button { bottom = min(0.6, bottom + 0.05) } label: { Label("Subir", systemImage: "arrow.up") }
            Button { bottom = max(0.02, bottom - 0.05) } label: { Label("Bajar", systemImage: "arrow.down") }
            Menu("Color") {
                ForEach(SubtitleStyle.colors, id: \.key) { c in Button { colorKey = c.key } label: { Label(c.label, systemImage: colorKey == c.key ? "checkmark" : "circle") } }
            }
        } label: { Image(systemName: "textformat").frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle()) }
    }
}

/// Recibe los subtítulos que AVPlayer iba a dibujar y los entrega como texto (para dibujarlos con el estilo propio).
final class LegibleBridge: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    var onText: (String) -> Void = { _ in }
    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        let t = strings.map { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        DispatchQueue.main.async { self.onText(t) }
    }
}

/// Ajustes → Subtítulos: vista previa que se puede arrastrar, tamaño, color, fondo y posición.
struct SubtitleSettingsView: View {
    @AppStorage("sub.own") private var own = true
    @AppStorage("sub.size") private var size = 28.0
    @AppStorage("sub.color") private var colorKey = "white"
    @AppStorage("sub.bg") private var bg = 0.45
    @AppStorage("sub.bottom") private var bottom = 0.10
    @AppStorage("sub.bold") private var bold = true
    @EnvironmentObject var themes: ThemeStore

    var body: some View {
        List {
            Section {
                Toggle("Dibujar los subtítulos con la app", isOn: $own).themedRow()
            } footer: { Text("Permite cambiar color, tamaño y posición. Con esto desactivado los dibuja el reproductor del sistema (y valen los de Ajustes del iPad).") }
            Section("Vista previa (arrastra el texto para moverlo)") {
                GeometryReader { geo in
                    ZStack {
                        Color.black
                        SubtitleOverlay(text: "Así se verán los subtítulos")
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        bottom = min(0.6, max(0.02, 1 - Double(v.location.y / geo.size.height)))
                    })
                }.frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 10)).listRowInsets(EdgeInsets())
            }
            Section {
                VStack(alignment: .leading) { Text("Tamaño: \(Int(size)) pt"); Slider(value: $size, in: 14...80, step: 2) }.themedRow()
                VStack(alignment: .leading) { Text("Fondo: \(Int(bg * 100)) %"); Slider(value: $bg, in: 0...0.9, step: 0.05) }.themedRow()
                VStack(alignment: .leading) { Text("Altura desde abajo: \(Int(bottom * 100)) %"); Slider(value: $bottom, in: 0.02...0.6, step: 0.01) }.themedRow()
                Toggle("Negrita", isOn: $bold).themedRow()
                Picker("Color", selection: $colorKey) { ForEach(SubtitleStyle.colors, id: \.key) { Text($0.label).tag($0.key) } }.themedRow()
            }
            Section { Button("Valores de fábrica") { size = 28; colorKey = "white"; bg = 0.45; bottom = 0.10; bold = true }.themedRow() }
        }
        .themedScreen().navigationTitle("Subtítulos")
    }
}

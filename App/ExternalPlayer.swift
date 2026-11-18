import SwiftUI
import UIKit

/// Abre un vídeo en otra app de reproducción (VLC, Infuse, nPlayer, Outplayer) o deja copiar el enlace.
/// Es útil con formatos que el reproductor de la app no abre (DTS, AV1…): esas apps los decodifican por su cuenta.
struct ExternalPlayerButton: View {
    /// Dirección del vídeo; se pide al pulsar (en los servidores hay que preguntársela al servidor).
    let urlProvider: () async -> String?
    var label = "Abrir en otro reproductor"
    var iconOnly = false                       // en las barras del reproductor: solo el icono
    @State private var message = ""

    private struct Player { let name: String; let make: (String) -> String }
    private static let players: [Player] = [
        Player(name: "VLC") { "vlc-x-callback://x-callback-url/stream?url=\(enc($0))" },
        Player(name: "Infuse") { "infuse://x-callback-url/play?url=\(enc($0))" },
        Player(name: "nPlayer") { "nplayer-\($0)" },
        Player(name: "Outplayer") { "outplayer://\($0)" },
    ]
    private static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "").union(.alphanumerics)) ?? s }

    var body: some View {
        Menu {
            ForEach(Self.players, id: \.name) { p in Button(p.name) { open(p) } }
            Button("Copiar enlace") {
                Task { if let u = await urlProvider() { UIPasteboard.general.string = u; message = "Enlace copiado" } else { message = "No se pudo obtener el enlace" } }
            }
        } label: {
            if iconOnly { Image(systemName: "arrow.up.forward.app").frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle()).foregroundStyle(.white) }
            else { Label(label, systemImage: "arrow.up.forward.app").font(.subheadline).padding(.horizontal, 12).padding(.vertical, 8).background(.quaternary, in: Capsule()) }
        }
        .alert(message, isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) { Button("Vale", role: .cancel) {} }
    }

    private func open(_ p: Player) {
        Task {
            guard let u = await urlProvider() else { message = "No se pudo obtener el enlace"; return }
            guard let url = URL(string: p.make(u)) else { message = "Enlace no válido"; return }
            let ok = await UIApplication.shared.open(url)
            if !ok { message = "\(p.name) no está instalado en este iPad" }
        }
    }
}

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

/// Película ya descargada: la ofrece a otro reproductor (VLC, Infuse, nPlayer…) por la hoja de compartir del sistema.
/// Una app externa no puede leer la carpeta de esta app por su cuenta, así que se le entrega el fichero (copiar a VLC, Abrir en Infuse…).
struct ExternalFileButton: View {
    let file: URL
    var iconOnly = false
    var body: some View {
        Button { OpenInPresenter.shared.present(file) } label: {
            if iconOnly { Image(systemName: "arrow.up.forward.app").frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle()).foregroundStyle(.white) }
            else { Label("Abrir en otro reproductor", systemImage: "arrow.up.forward.app").font(.footnote) }
        }
    }
}

/// Muestra el menú «Abrir en…» del sistema con las apps que saben abrir el fichero (VLC, Infuse, nPlayer…), anclado al centro de la pantalla.
/// La hoja de compartir de SwiftUI no lo ofrecía dentro del reproductor a pantalla completa. Si ninguna app lo abre, se cae a compartir.
@MainActor
final class OpenInPresenter: NSObject, UIDocumentInteractionControllerDelegate {
    static let shared = OpenInPresenter()
    private var controller: UIDocumentInteractionController?

    func present(_ file: URL) {
        guard let top = Self.topViewController() else { return }
        let rect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        let c = UIDocumentInteractionController(url: file)
        c.delegate = self
        controller = c
        if !c.presentOpenInMenu(from: rect, in: top.view, animated: true) {
            let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = top.view
            share.popoverPresentationController?.sourceRect = rect
            top.present(share, animated: true)
        }
    }

    /// Pantalla que está más arriba ahora mismo (el reproductor va dentro de una pantalla modal).
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }
}

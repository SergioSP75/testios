import SwiftUI
import AVFoundation

/// Botón del reproductor para adelantar o retrasar el sonido respecto a la imagen (sincronía de audio).
/// El valor se aplica al pulsar «Aplicar»: `apply` devuelve un texto de error si ese tipo de reproducción no lo admite.
struct AudioDelayButton: View {
    @Binding var applied: Int                    // milisegundos aplicados ahora (+ retrasa el audio, − lo adelanta)
    let apply: (Int) async -> String?
    @State private var open = false
    @State private var draft = 0
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        Button { draft = applied; message = nil; open = true } label: {
            Image(systemName: "waveform.path").frame(width: 44, height: 44)
                .background(.black.opacity(0.6), in: Circle())
                .overlay(alignment: .topTrailing) { if applied != 0 { Circle().fill(.orange).frame(width: 10, height: 10) } }
        }
        .popover(isPresented: $open) {
            VStack(spacing: 14) {
                Text("Sincronía del audio").font(.headline)
                Text("\(draft > 0 ? "+" : "")\(draft) ms").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                Text(draft == 0 ? "Sin ajuste" : draft > 0 ? "El sonido sale más tarde" : "El sonido sale antes").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach([-500, -100, -10], id: \.self) { d in step(d) }
                    ForEach([10, 100, 500], id: \.self) { d in step(d) }
                }
                HStack {
                    Button("A cero") { draft = 0 }.buttonStyle(.bordered)
                    Button {
                        Task {
                            busy = true; message = await apply(draft); busy = false
                            if message == nil { applied = draft; open = false }
                        }
                    } label: { Text(busy ? "Aplicando…" : "Aplicar").frame(minWidth: 90) }
                        .buttonStyle(.borderedProminent).disabled(busy || draft == applied)
                }
                if let m = message { Text(m).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 280) }
                Text("Si el sonido va por delante de la imagen, pon un valor positivo; si va por detrás, negativo.").font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 280)
            }
            .padding(18)
        }
    }

    private func step(_ d: Int) -> some View {
        Button { draft = max(-5000, min(5000, draft + d)) } label: { Text("\(d > 0 ? "+" : "")\(d)").font(.footnote.monospacedDigit()).frame(minWidth: 38) }
            .buttonStyle(.bordered)
    }
}

/// Un asset con el audio desplazado respecto al vídeo (para ficheros locales). `ms` > 0 retrasa el sonido, < 0 lo adelanta.
enum AudioDelayAsset {
    static func make(file: URL, ms: Int) async throws -> AVAsset {
        let src = AVURLAsset(url: file)
        guard ms != 0 else { return src }
        let comp = AVMutableComposition()
        let dur = try await src.load(.duration)
        for t in try await src.loadTracks(withMediaType: .video) {
            guard let c = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try c.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: t, at: .zero)
            c.preferredTransform = try await t.load(.preferredTransform)
        }
        let shift = CMTime(seconds: Double(abs(ms)) / 1000, preferredTimescale: 600)
        for t in try await src.loadTracks(withMediaType: .audio) {
            guard let c = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            if ms > 0 { try c.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: t, at: shift) }                      // audio más tarde
            else { try c.insertTimeRange(CMTimeRange(start: shift, duration: CMTimeSubtract(dur, shift)), of: t, at: .zero) }    // audio más pronto
            if let tag = try? await t.load(.extendedLanguageTag) { c.extendedLanguageTag = tag }
        }
        return comp
    }
}

import Foundation

/// Decide qué hay detrás de una URL mirando el CONTENIDO del manifiesto, nunca el nombre del proveedor
/// (criterio acordado con el usuario: igual que el relay de Cast en Android).
public enum StreamKind: Equatable {
    case hlsPlain          // HLS normal: AVPlayer lo reproduce directo
    case hlsEncrypted      // HLS con SAMPLE-AES / CENC: necesita el relay
    case dash              // MPD: AVPlayer no lo reproduce, el relay lo convierte a HLS
    case smooth            // Smooth Streaming (SS/ISML): el relay lo convierte a HLS fMP4 y lo descifra
    case matroska          // MKV/WebM: AVPlayer no abre el contenedor; MkvToHls lo pasa a HLS fMP4 sin recodificar
    case other             // MP4, TS… (se intenta directo)
}

public enum StreamSniffer {

    public static func kind(ofManifest text: String) -> StreamKind {
        if text.contains("<MPD") { return .dash }
        if text.contains("<SmoothStreamingMedia") { return .smooth }
        if text.contains("#EXTM3U") {
            let upper = text.uppercased()
            if upper.contains("METHOD=SAMPLE-AES") { return .hlsEncrypted }
            return .hlsPlain
        }
        return .other
    }

    /// Los primeros bytes de un fichero: ¿es Matroska (cabecera EBML 1A 45 DF A3)?
    public static func isMatroska(_ head: Data) -> Bool { head.count >= 4 && head.prefix(4).elementsEqual([0x1A, 0x45, 0xDF, 0xA3]) }

    /// ¿Hay que pasar por el relay? Sí si es DASH, si el HLS va cifrado o si el canal trae claves ClearKey.
    public static func needsRelay(kind: StreamKind, hasClearKeys: Bool) -> Bool {
        switch kind {
        case .dash, .hlsEncrypted, .smooth: return true
        case .hlsPlain: return hasClearKeys        // HLS fMP4 con claves en la lista: puede venir cifrado sin etiquetarlo
        case .other, .matroska: return false           // el MKV lo decide el reproductor según el ajuste (MkvToHls)
        }
    }
}

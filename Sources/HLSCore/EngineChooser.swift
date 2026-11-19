import Foundation

/// Reproductor que abre un título: AVPlayer (el del sistema, con el relay propio) o VLC (decodifica casi todo por software).
public enum PlaybackEngine: String, Codable, Equatable {
    case avplayer, vlc
}

/// Ajuste de Ajustes → Reproductor → Motor.
public enum EngineSetting: String, Codable, CaseIterable {
    case auto      // AVPlayer donde funciona y VLC donde no
    case avplayer  // siempre AVPlayer
    case vlc       // siempre VLC

    public var label: String {
        switch self {
        case .auto: return "Automático (AVPlayer, y VLC si no puede)"
        case .avplayer: return "Siempre AVPlayer"
        case .vlc: return "Siempre VLC"
        }
    }
}

/// Lo que se sabe de un título antes de abrirlo. Los códecs van en minúsculas como en los manifiestos («avc1», «hvc1», «ec-3»,
/// «mp4a.40.2») o con el nombre de Matroska («V_MPEG4/ISO/AVC», «A_DTS»); el selector reconoce los dos.
public struct MediaFacts: Equatable {
    public var kind: StreamKind
    public var fileExtension: String
    public var videoCodecs: [String]
    public var audioCodecs: [String]
    public var hasSubtitleFormats: [String]
    /// El aparato decodifica por hardware (lo rellena la app con VideoToolbox)
    public var hardwareHevc: Bool
    public var hardwareVp9: Bool
    public var hardwareAv1: Bool

    public init(kind: StreamKind = .other, fileExtension: String = "", videoCodecs: [String] = [], audioCodecs: [String] = [],
                subtitleFormats: [String] = [], hardwareHevc: Bool = true, hardwareVp9: Bool = false, hardwareAv1: Bool = false) {
        self.kind = kind; self.fileExtension = fileExtension.lowercased(); self.videoCodecs = videoCodecs.map { $0.lowercased() }
        self.audioCodecs = audioCodecs.map { $0.lowercased() }; self.hasSubtitleFormats = subtitleFormats.map { $0.lowercased() }
        self.hardwareHevc = hardwareHevc; self.hardwareVp9 = hardwareVp9; self.hardwareAv1 = hardwareAv1
    }
}

public enum EngineChooser {

    /// Contenedores que AVPlayer no abre (o abre mal): solo VLC.
    public static let vlcOnlyExtensions: Set<String> = ["avi", "wmv", "asf", "flv", "f4v", "ogv", "ogg", "ogm", "mpg", "mpeg", "vob", "rmvb", "rm",
                                                 "divx", "xvid", "3gp2", "mka", "flac", "opus", "wma", "ape", "wv", "dts", "dtshd", "tta", "mpc", "m2ts", "mts"]
    /// Contenedores que AVPlayer abre directo.
    public static let avExtensions: Set<String> = ["mp4", "m4v", "mov", "m4a", "mp3", "aac", "wav", "aif", "aiff", "caf", "m3u8", "ts", "ac3", "ec3"]

    /// ¿Códec de vídeo que AVPlayer no decodifica en este aparato?
    public static func videoNeedsVlc(_ codec: String, _ f: MediaFacts) -> Bool {
        let c = codec.lowercased()
        if c.hasPrefix("avc") || c.contains("avc") || c.hasPrefix("h264") { return false }
        if c.hasPrefix("hvc") || c.hasPrefix("hev") || c.hasPrefix("dvh") || c.contains("hevc") || c.contains("h265") { return !f.hardwareHevc }
        if c.hasPrefix("vp09") || c.contains("vp9") { return !f.hardwareVp9 }
        if c.hasPrefix("av01") || c.contains("av1") { return !f.hardwareAv1 }
        if c.contains("prores") || c.hasPrefix("apc") { return false }         // ProRes lo decodifica el sistema
        // MPEG-2, MPEG-4 parte 2 (Xvid/DivX/ASP), VC-1, Theora, VP8, WMV, MJPEG…: AVPlayer no los abre
        for other in ["mpeg2", "mpeg-2", "mp2v", "mp4v", "v_mpeg4/iso/asp", "v_mpeg4/iso/sp", "vc1", "vc-1", "wmv", "theora", "vp8", "vp08", "mjpeg", "divx", "xvid"] where c.contains(other) { return true }
        return false
    }

    /// ¿Códec de audio que AVPlayer no suena? (AAC, MP3, AC-3, E-AC-3, ALAC, FLAC en MP4 y PCM sí).
    public static func audioNeedsVlc(_ codec: String) -> Bool {
        let c = codec.lowercased()
        if c.hasPrefix("mp4a") || c.contains("aac") || c == "mp3" || c.contains("mpeg/l3") || c.hasPrefix("ac-3") || c.hasPrefix("ec-3") || c.hasPrefix("ac3") || c.hasPrefix("eac3") ||
            c.contains("e-ac-3") || c.contains("a_ac3") || c.contains("a_eac3") || c.contains("alac") || c.contains("pcm") { return false }
        for other in ["dts", "dca", "truehd", "mlp", "opus", "vorbis", "wma", "wmapro", "flac", "ape", "tta", "wavpack", "ra_", "cook", "amr", "mp2", "mpeg/l2", "ac-4"] where c.contains(other) { return true }
        return false
    }

    /// Qué reproductor abre este título según el ajuste y lo que se sabe de él.
    public static func choose(setting: EngineSetting, facts f: MediaFacts) -> PlaybackEngine {
        switch setting {
        case .vlc: return .vlc
        case .avplayer: return .avplayer
        case .auto: break
        }
        // Manifiestos que el relay convierte a HLS fMP4 (DASH, Smooth, HLS cifrado): AVPlayer, salvo que traigan un códec que no decodifica
        switch f.kind {
        case .hlsPlain, .hlsEncrypted, .dash, .smooth, .matroska:
            if f.videoCodecs.contains(where: { videoNeedsVlc($0, f) }) || f.audioCodecs.allSatisfy({ audioNeedsVlc($0) }) && !f.audioCodecs.isEmpty { return .vlc }
            return .avplayer
        case .other:
            if vlcOnlyExtensions.contains(f.fileExtension) { return .vlc }
            if f.videoCodecs.contains(where: { videoNeedsVlc($0, f) }) { return .vlc }
            if !f.audioCodecs.isEmpty, f.audioCodecs.allSatisfy({ audioNeedsVlc($0) }) { return .vlc }
            if avExtensions.contains(f.fileExtension) || f.fileExtension.isEmpty { return .avplayer }
            return .vlc                                          // extensión desconocida: VLC lo intenta todo
        }
    }

    /// Tras un fallo de AVPlayer: ¿se prueba con VLC? Solo en automático y si no se probó ya.
    public static func fallbackAfterFailure(setting: EngineSetting, current: PlaybackEngine) -> PlaybackEngine? {
        setting == .auto && current == .avplayer ? .vlc : nil
    }

    /// Extensión de una dirección sin la parte de consulta («…/peli.AVI?token=1» → «avi»).
    public static func fileExtension(of url: String) -> String {
        let path = url.components(separatedBy: "?").first?.components(separatedBy: "#").first ?? url
        let last = path.components(separatedBy: "/").last ?? ""
        guard let dot = last.lastIndex(of: "."), last.distance(from: dot, to: last.endIndex) <= 7 else { return "" }
        return String(last[last.index(after: dot)...]).lowercased()
    }
}

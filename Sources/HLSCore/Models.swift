import Foundation

// Port de Models.kt (Android). Mismos nombres de campo para poder comparar a mano.

/// Tipo de protección de un canal.
public enum DrmMode: String, Codable {
    case fairplay, clearkey, widevine, playready, none
}

/// Un canal (o sublista) de una lista IPTV.
public struct IptvChannel: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var url: String
    public var group: String?
    public var tvgId: String?
    public var tvgName: String?
    public var m3uLogo: String?
    public var epgLogo: String?
    public var catchup: String?
    public var catchupSource: String?
    public var catchupDays: String?
    public var userAgent: String?
    public var referrer: String?
    public var httpHeaders: [String: String]
    public var kodiProps: [String: String]
    public var clearKeys: [String: String]
    public var clearKeyJson: String?
    public var manifestType: String?
    public var licenseType: String?
    public var licenseUrl: String?
    public var drmMode: DrmMode
    public var fromIsmlList: Bool
    public var isPlaylistGroup: Bool
    public var nestedUrl: String?
    /// Campos propios del formato OTC (pistas preferidas, radio, direccion dinamica); nil si no es OTC.
    public var otc: OtcChannelOpts?

    public init(id: String, name: String, url: String, group: String? = nil,
                tvgId: String? = nil, tvgName: String? = nil, m3uLogo: String? = nil,
                epgLogo: String? = nil, catchup: String? = nil, catchupSource: String? = nil,
                catchupDays: String? = nil, userAgent: String? = nil, referrer: String? = nil,
                httpHeaders: [String: String] = [:], kodiProps: [String: String] = [:],
                clearKeys: [String: String] = [:], clearKeyJson: String? = nil,
                manifestType: String? = nil, licenseType: String? = nil, licenseUrl: String? = nil,
                drmMode: DrmMode = .none, fromIsmlList: Bool = false,
                isPlaylistGroup: Bool = false, nestedUrl: String? = nil, otc: OtcChannelOpts? = nil) {
        self.id = id; self.name = name; self.url = url; self.group = group
        self.tvgId = tvgId; self.tvgName = tvgName; self.m3uLogo = m3uLogo
        self.epgLogo = epgLogo; self.catchup = catchup; self.catchupSource = catchupSource
        self.catchupDays = catchupDays; self.userAgent = userAgent; self.referrer = referrer
        self.httpHeaders = httpHeaders; self.kodiProps = kodiProps
        self.clearKeys = clearKeys; self.clearKeyJson = clearKeyJson
        self.manifestType = manifestType; self.licenseType = licenseType
        self.licenseUrl = licenseUrl; self.drmMode = drmMode
        self.fromIsmlList = fromIsmlList; self.isPlaylistGroup = isPlaylistGroup
        self.nestedUrl = nestedUrl; self.otc = otc
    }

    /// Logo a mostrar: el de la lista M3U y, si falta, el de la guía.
    public var bestLogo: String? {
        if let l = m3uLogo, !l.isEmpty { return l }
        if let l = epgLogo, !l.isEmpty { return l }
        return nil
    }
}

/// Configuración de una lista guardada por el usuario.
public struct PlaylistConfig: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var url: String
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String, url: String, enabled: Bool = true) {
        self.id = id; self.name = name; self.url = url; self.enabled = enabled
    }
}

/// Resultado de leer una lista M3U.
public struct M3uParseResult {
    public var channels: [IptvChannel]
    public var epgUrl: String?
    public var vodLibraries: [String]
    public var meta: [String: String] = [:]     // datos del proveedor (listas OTC)
}

/// Campos de canal del formato OTC que no tienen equivalente en M3U.
public struct OtcChannelOpts: Codable, Equatable {
    public var number: Int?
    public var isRadio: Bool = false
    public var epgShiftSec: Int64?
    public var codec: [String] = []
    public var audioTrack: Int?
    public var videoTrack: String?                // numero (desde 1) o resolucion 1920x1080
    public var blAudio: [String] = []
    public var blVideo: [String] = []
    public var runtimeAttrUrl: String?
    public var seekPreview: String?
    public var drmData: String?
    public init() {}
}

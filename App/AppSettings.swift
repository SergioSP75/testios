import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Ajustes de reproducción (equivalen a los de Ajustes de Android). Se leen desde cualquier parte con `AppSettings.xxx`.
enum AppSettings {
    /// Pantalla completa sin marcos ni barras.
    static var fullscreen: Bool { UserDefaults.standard.object(forKey: "set.fullscreen") as? Bool ?? true }
    /// Rellenar toda la pantalla recortando los bordes (si no, se ve la imagen entera).
    static var fillScreen: Bool { UserDefaults.standard.bool(forKey: "set.fill") }
    /// Segundos de vídeo que se guardan por delante (0 = lo decide el sistema).
    static var bufferSeconds: Double { UserDefaults.standard.object(forKey: "set.buffer") as? Double ?? 20 }
    /// Segmentos que el relay baja por adelantado (0 = ninguno).
    static var prefetch: Int { UserDefaults.standard.object(forKey: "set.prefetch") as? Int ?? 3 }
    /// Altura máxima de imagen (0 = sin límite). También se puede fijar desde el PC para probar.
    static var maxHeight: Int { UserDefaults.standard.integer(forKey: "set.maxHeight") }
    /// Resolución mínima de las variantes que se dejan elegir: 0 = automática, -1 = la de la pantalla del dispositivo.
    static var minResolution: Int { UserDefaults.standard.object(forKey: "set.minRes") as? Int ?? -1 }
    /// Alto mínimo en píxeles según el ajuste (para -1: el ancho de la pantalla pasado a 16:9, p. ej. iPad 2360 px → 1327).
    static var minHeight: Int {
        let m = minResolution
        if m >= 0 { return m }
        #if canImport(UIKit)
        let b = UIScreen.main.nativeBounds
        return Int(max(b.width, b.height) * 9 / 16)
        #else
        return 0
        #endif
    }
    /// Alto de imagen que corresponde a esta pantalla (para enseñarlo en Ajustes).
    static var deviceVideoHeight: Int {
        #if canImport(UIKit)
        let b = UIScreen.main.nativeBounds
        return Int(max(b.width, b.height) * 9 / 16)
        #else
        return 0
        #endif
    }
    /// Idioma del dispositivo (dos letras), p. ej. «es».
    static var deviceLang: String { String((Locale.preferredLanguages.first ?? "es").prefix(2)).lowercased() }
    /// Idiomas de audio que se bajan por defecto: el del dispositivo y el inglés.
    static var dlAudioLangs: [String] {
        let s = UserDefaults.standard.string(forKey: "set.dlAudioLangs") ?? "\(deviceLang),en"
        return s.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
    /// Idiomas de subtítulos que se bajan por defecto: inglés.
    static var dlSubLangs: [String] {
        let s = UserDefaults.standard.string(forKey: "set.dlSubLangs") ?? "en"
        return s.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
    /// Qué hacer con un MKV (AVPlayer no abre ese contenedor): «local» = pasarlo a HLS en el propio dispositivo sin recodificar y,
    /// si no se puede (DTS, AV1…), pedir al servidor que lo recodifique; «server» = pedirlo al servidor; «none» = solo avisar.
    static var mkvMode: String { UserDefaults.standard.string(forKey: "set.mkvMode") ?? "local" }
    /// Pausar las descargas mientras algo se está reproduciendo (por defecto sí; con directos daba saltos).
    static var dlPauseWhilePlaying: Bool { UserDefaults.standard.object(forKey: "set.dlPausePlay") as? Bool ?? true }
    /// Descargas a la vez (de servidores distintos).
    static var dlParallel: Int { max(1, UserDefaults.standard.object(forKey: "set.dlParallel") as? Int ?? 3) }
    /// Trozos de un mismo vídeo que se bajan a la vez.
    static var dlConnections: Int { max(1, UserDefaults.standard.object(forKey: "set.dlConn") as? Int ?? 4) }
    /// Tope de la caché de imágenes en MB y días que se guarda una imagen (0 = sin límite de días).
    static var imageCacheMB: Int { UserDefaults.standard.object(forKey: "set.imgMB") as? Int ?? 300 }
    static var imageCacheDays: Int { UserDefaults.standard.object(forKey: "set.imgDays") as? Int ?? 14 }
    /// Subtítulos dibujados por la app (colores, tamaño y posición propios).
    static var ownSubtitles: Bool { UserDefaults.standard.object(forKey: "sub.own") as? Bool ?? true }
    /// Texto con la resolución y velocidad sobre la imagen.
    static var showQuality: Bool { UserDefaults.standard.object(forKey: "set.showQuality") as? Bool ?? true }
    /// Resolución siempre a la vista (si no, solo al tocar la pantalla).
    static var qualityAlways: Bool { UserDefaults.standard.object(forKey: "set.qualityAlways") as? Bool ?? true }
    /// Días de guía que se guardan hacia atrás (los que se pueden ver con catchup).
    static var epgDays: Int { min(7, max(1, UserDefaults.standard.object(forKey: "set.epgDays") as? Int ?? 3)) }
    /// Paneles de la vista de TV: lista de canales a la izquierda y guía a la derecha.
    static var showChannelPanel: Bool { UserDefaults.standard.object(forKey: "tv.showChannels") as? Bool ?? true }
    static var showEpgPanel: Bool { UserDefaults.standard.object(forKey: "tv.showEpg") as? Bool ?? true }
    /// El audio sigue sonando con la app en segundo plano.
    static var audioBackground: Bool { UserDefaults.standard.object(forKey: "set.audioBg") as? Bool ?? true }
}

/// Sección «Reproductor» de Ajustes.
struct PlayerSettingsSection: View {
    @AppStorage("set.fullscreen") private var fullscreen = true
    @AppStorage("set.fill") private var fill = false
    @AppStorage("set.buffer") private var buffer = 20.0
    @AppStorage("set.prefetch") private var prefetch = 3
    @AppStorage("set.showQuality") private var showQuality = true
    @AppStorage("set.qualityAlways") private var qualityAlways = true
    @AppStorage("set.audioBg") private var audioBg = true
    @AppStorage("set.epgDays") private var epgDays = 3
    @AppStorage("tv.showChannels") private var showChannels = true
    @AppStorage("tv.showEpg") private var showEpg = true
    @EnvironmentObject var themes: ThemeStore

    var body: some View {
        Section("Reproductor") {
            Toggle("Pantalla completa (sin marcos)", isOn: $fullscreen).themedRow()
            Toggle("Rellenar pantalla (recorta bordes)", isOn: $fill).themedRow()
            Toggle("Mostrar resolución y velocidad", isOn: $showQuality).themedRow()
            Toggle("Resolución siempre visible", isOn: $qualityAlways).themedRow()
            Toggle("Audio en segundo plano", isOn: $audioBg).themedRow()
            Toggle("Panel de canales (vista TV)", isOn: $showChannels).themedRow()
            Toggle("Panel de guía (vista TV)", isOn: $showEpg).themedRow()
            Stepper("Días de guía hacia atrás: \(epgDays)", value: $epgDays, in: 1...7).themedRow()
            Stepper("Colchón: \(Int(buffer)) s", value: $buffer, in: 0...90, step: 5).themedRow()
            Stepper("Segmentos adelantados: \(prefetch)", value: $prefetch, in: 0...8).themedRow()
            Text("Si el directo da microcortes, sube el colchón y los segmentos adelantados.").font(.caption).foregroundStyle(themes.theme.c(themes.theme.dim)).themedRow()
        }
    }
}

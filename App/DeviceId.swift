import Foundation
import UIKit

/// Versión de la app. La CI la sube sola en cada compilación (1.<nº de compilación>), como el versionName de Android.
enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
    static var versionText: String { "\(version) (\(build))" }
}

/// Identificador único de esta instalación, para saber qué aparato pide cada lista (equivale a DeviceId.kt de Android):
/// va en el User-Agent de las descargas de listas y se muestra en Ajustes → Acerca de.
///  · Se genera al azar la primera vez: no deriva de datos del aparato, solo identifica esta instalación.
///  · Se guarda en Application Support, fuera de las copias de seguridad. Reinstalar genera uno nuevo.
///  · Formato: 16 hex en mayúsculas en grupos de 4 → «A1B2-C3D4-E5F6-0718».
enum DeviceId {
    private static var cached: String?

    static var get: String {
        if let c = cached { return c }
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("device_id")
        if let t = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
           t.range(of: "^[0-9A-F]{4}(-[0-9A-F]{4}){3}$", options: .regularExpression) != nil { cached = t; return t }
        let hex = (0..<8).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
        let id = stride(from: 0, to: 16, by: 4).map { i -> String in
            let a = hex.index(hex.startIndex, offsetBy: i); return String(hex[a..<hex.index(a, offsetBy: 4)])
        }.joined(separator: "-")
        try? id.write(to: file, atomically: true, encoding: .utf8)
        var v = URLResourceValues(); v.isExcludedFromBackup = true; var f = file; try? f.setResourceValues(v)
        cached = id
        return id
    }

    /// User-Agent para descargar listas: navegador + app/versión + identificador (mismo formato que Android).
    static var playlistUserAgent: String {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 MediaKillerSP75/\(AppInfo.version) (id:\(get))"
    }
}

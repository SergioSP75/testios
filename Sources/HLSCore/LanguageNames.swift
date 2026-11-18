import Foundation

/// Nombres de idioma con significado para una persona («Español (España)») a partir del código de la pista («es-ES»),
/// en el idioma del aparato. Es la misma idea que Android: se traduce el código real, no se enseña el código interno.
public enum LanguageNames {
    /// Nombre de un código de idioma (BCP-47: «es», «es-ES», «pt-BR», «sr-Latn») escrito en el idioma `ui`; nil si no se reconoce.
    public static func display(_ tag: String, in ui: String) -> String? {
        let id = tag.replacingOccurrences(of: "_", with: "-")
        guard !id.isEmpty else { return nil }
        let s = Locale(identifier: ui.isEmpty ? "es" : ui).localizedString(forIdentifier: id)
        guard let name = s, !name.isEmpty, name.lowercased() != id.lowercased() else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Nombre legible de una pista: el suyo si ya lo es; si es un código interno («es-ES a7»), el idioma traducido.
    public static func readable(name: String, lang: String, ui: String) -> String {
        guard looksInternal(name) else { return name }
        let code = lang.isEmpty ? String(name.prefix { $0 != " " }) : lang
        return display(code, in: ui).map { $0 + suffix(name) } ?? name
    }

    /// ¿Parece un nombre interno («es-ES a7», «ca-ES SDH», «cs») y no un nombre pensado para personas?
    static func looksInternal(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,4})?( (SDH|CC|AD|[a-z][0-9]+))*$", options: .regularExpression) != nil
    }

    /// Texto que sobra tras el código en un nombre interno: «SDH» → «para sordos».
    static func suffix(_ name: String) -> String {
        let up = name.uppercased()
        if up.contains(" SDH") || up.contains(" CC") { return " · para sordos" }
        if up.hasSuffix(" AD") || up.contains(" AD ") { return " · audiodescripción" }
        return ""
    }
}

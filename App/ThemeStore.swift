import SwiftUI

/// Interfaz elegida (una de las 12 de Android). Se guarda y todas las pantallas la leen de aquí.
@MainActor
final class ThemeStore: ObservableObject {
    @Published var theme: AppTheme
    private let key = "uiTheme"

    init() { theme = AppTheme.byId(UserDefaults.standard.string(forKey: "uiTheme")) }

    func select(_ t: AppTheme) {
        theme = t
        UserDefaults.standard.set(t.id, forKey: key)
    }
}

/// Aspecto común de las pantallas: fondo de panel, acento y esquema claro/oscuro del tema.
/// Equivale a los `setBackgroundColor(th(...) { panel })` de la app Android.
struct ThemedScreen: ViewModifier {
    @EnvironmentObject var themes: ThemeStore
    func body(content: Content) -> some View {
        let t = themes.theme
        content
            .scrollContentBackground(.hidden)
            .background(t.c(t.panel).ignoresSafeArea())
            .tint(t.accentColor)
            .foregroundStyle(t.c(t.text))
            .preferredColorScheme(t.light ? .light : .dark)
    }
}

/// Fondo de cada fila de una lista (la «tarjeta» del tema).
struct ThemedRow: ViewModifier {
    @EnvironmentObject var themes: ThemeStore
    func body(content: Content) -> some View {
        content
            .listRowBackground(themes.theme.c(themes.theme.card))
            .listRowSeparatorTint(themes.theme.c(themes.theme.divider))
    }
}

extension View {
    func themedScreen() -> some View { modifier(ThemedScreen()) }
    func themedRow() -> some View { modifier(ThemedRow()) }
}

/// Configuración: elección de la interfaz (los 12 temas de Android, cada uno con sus colores).
struct AppearanceView: View {
    @EnvironmentObject var themes: ThemeStore
    var body: some View {
        List {
            Section("Interfaz") {
                ForEach(AppTheme.all) { t in
                    Button { themes.select(t) } label: {
                        HStack(spacing: 12) {
                            // Muestra de la paleta: panel, tarjeta y acento
                            HStack(spacing: 0) {
                                Rectangle().fill(t.c(t.panel))
                                Rectangle().fill(t.c(t.card))
                                Rectangle().fill(t.accentColor)
                            }
                            .frame(width: 54, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.c(t.border), lineWidth: 1))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.label).foregroundStyle(themes.theme.c(themes.theme.text))
                                Text(t.desc).font(.caption).foregroundStyle(themes.theme.c(themes.theme.dim))
                            }
                            Spacer()
                            if t.id == themes.theme.id { Image(systemName: "checkmark").foregroundStyle(themes.theme.accentColor) }
                        }
                    }
                    .themedRow()
                }
            }
        }
        .themedScreen()
        .navigationTitle("Apariencia")
    }
}

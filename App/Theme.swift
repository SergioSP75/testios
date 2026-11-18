// GENERADO desde UiTheme.kt de la app Android (mismos 12 temas y mismos colores). Colores en formato 0xAARRGGBB.
import SwiftUI

/// Cómo se dibujan los botones de cada interfaz (igual que BtnStyle de Android).
enum ButtonStyleKind { case text, glowDisc, plain, neonRing, disc, line }

struct AppTheme: Identifiable, Equatable {
    let id: String, label: String, desc: String, style: ButtonStyleKind
    var light = false, transparent = false
    var bg: UInt32 = 0xFF000000
    var panel: UInt32 = 0xFF0B0E1A
    var panelEpg: UInt32 = 0xFF0D0D1A
    var header: UInt32 = 0xFF111122
    var card: UInt32 = 0xFF161B2E
    var group: UInt32 = 0xFF161622
    var input: UInt32 = 0xFF131626
    var border: UInt32 = 0xFF223355
    var bar: UInt32 = 0xFF060910
    var status: UInt32 = 0xFF0D0D0D
    var divider: UInt32 = 0xFF222233
    var selRow: UInt32 = 0x331565C0
    var focusBg: UInt32 = 0x22FFFFFF
    var text: UInt32 = 0xFFFFFFFF
    var text2: UInt32 = 0xFFCCCCCC
    var text3: UInt32 = 0xFFAAAAAA
    var dim: UInt32 = 0xFF888888
    var tabOff: UInt32 = 0xFF555577
    var barLabel: UInt32 = 0xFF555566
    var icon: UInt32 = 0xFF8899AA
    var accent: UInt32? = nil
    var accent2: UInt32 = 0xFF42A5F5
    var ok: UInt32 = 0xFF22CC66
    var danger: UInt32 = 0xFFCC3333
    var fav: UInt32 = 0xFFFFCC00

    /// Acento del tema; sin acento propio (clásica) se usa el cian de siempre.
    var accentColor: Color { Color(argb: accent ?? 0xFF00E5FF) }
    func c(_ v: UInt32) -> Color { Color(argb: v) }

    static let all: [AppTheme] = [
        AppTheme(id: "default", label: "Clásica", desc: "La interfaz de siempre", style: .text, panel: 0xFF0E0E14, header: 0xFF161622, card: 0xFF111828, text: 0xFFDDDDDD),
        AppTheme(id: "transparente", label: "Transparente", desc: "Vídeo a pantalla completa y controles de cristal flotando encima", style: .disc, transparent: true, bg: 0xFF000000, panel: 0xFF101114, panelEpg: 0xFF101114, header: 0xFF1A1C20, card: 0xFF24272C, group: 0xFF16181B, input: 0xFF1A1C20, border: 0x66FFFFFF, bar: 0xFF0B0C0E, status: 0xFF0E0F11, divider: 0x33FFFFFF, selRow: 0x44FFFFFF, focusBg: 0x44FFFFFF, text: 0xFFFFFFFF, text2: 0xFFEAEAEA, text3: 0xFFD0D0D0, dim: 0xFFB4B4B4, tabOff: 0xFFBDBDBD, barLabel: 0xFFEDEDED, icon: 0xFFFFFFFF, accent: 0xFFFFFFFF, accent2: 0xFF7FD6FF, ok: 0xFF4CE08A, danger: 0xFFFF6B6B, fav: 0xFFFFD84A),
        AppTheme(id: "neon_cyan", label: "Neón cian", desc: "Botones redondos con aro luminoso cian sobre carbón", style: .glowDisc, bg: 0xFF050607, panel: 0xFF0C1013, panelEpg: 0xFF0C1013, header: 0xFF121A1F, card: 0xFF142026, group: 0xFF111A1F, input: 0xFF0F171B, border: 0xFF14606D, bar: 0xFF08090A, status: 0xFF0A0D0F, divider: 0xFF123038, selRow: 0x3318E5FF, focusBg: 0x2218E5FF, text: 0xFFE6FBFF, text2: 0xFFB5DCE4, text3: 0xFF8FB8C1, dim: 0xFF5E8A93, tabOff: 0xFF3E6870, barLabel: 0xFF5E8A93, icon: 0xFF18E5FF, accent: 0xFF18E5FF, accent2: 0xFF0FB5CC, ok: 0xFF38F28A, danger: 0xFFFF5468, fav: 0xFFFFD84A),
        AppTheme(id: "neon_pink", label: "Neón rosa", desc: "Trazo fino rosa y azul con aros discontinuos sobre índigo", style: .neonRing, bg: 0xFF070622, panel: 0xFF0E0C3A, panelEpg: 0xFF0E0C3A, header: 0xFF171458, card: 0xFF1C1966, group: 0xFF15124F, input: 0xFF120F47, border: 0xFF3F3AA8, bar: 0xFF090830, status: 0xFF0A0929, divider: 0xFF2A2680, selRow: 0x33FF4FD8, focusBg: 0x33FF4FD8, text: 0xFFF6EDFF, text2: 0xFFD9CCF5, text3: 0xFFB4A8E8, dim: 0xFF8C86D6, tabOff: 0xFF6660B8, barLabel: 0xFF8C86D6, icon: 0xFFFF4FD8, accent: 0xFFFF4FD8, accent2: 0xFF3FA0FF, ok: 0xFF4DF0A8, danger: 0xFFFF5C7A, fav: 0xFFFFE04D),
        AppTheme(id: "azul", label: "Azul vivo", desc: "Discos azules en degradado con icono blanco", style: .disc, bg: 0xFF000000, panel: 0xFF0A1230, panelEpg: 0xFF0A1230, header: 0xFF101C48, card: 0xFF14245C, group: 0xFF0F1A42, input: 0xFF0C1538, border: 0xFF2457C8, bar: 0xFF070D24, status: 0xFF101C48, divider: 0xFF1B2F78, selRow: 0x3329B6FF, focusBg: 0x3329B6FF, text: 0xFFF2F8FF, text2: 0xFFC4D8F5, text3: 0xFF9DB8E6, dim: 0xFF7894CC, tabOff: 0xFF4F6CB0, barLabel: 0xFF7894CC, icon: 0xFF29B6FF, accent: 0xFF29B6FF, accent2: 0xFF0B5BF0, ok: 0xFF3DE08A, danger: 0xFFFF5468),
        AppTheme(id: "turquesa", label: "Turquesa", desc: "Discos turquesa brillantes con borde metálico", style: .disc, bg: 0xFF000000, panel: 0xFF07242C, panelEpg: 0xFF07242C, header: 0xFF0C3340, card: 0xFF104355, group: 0xFF0A2C37, input: 0xFF08262F, border: 0xFF1C7C94, bar: 0xFF041A20, status: 0xFF0C3340, divider: 0xFF124A5B, selRow: 0x3325D0EE, focusBg: 0x3325D0EE, text: 0xFFEAFBFF, text2: 0xFFBEE6EF, text3: 0xFF94CBD8, dim: 0xFF6FA6B5, tabOff: 0xFF47798A, barLabel: 0xFF6FA6B5, icon: 0xFF25D0EE, accent: 0xFF25D0EE, accent2: 0xFF0AA9CC, ok: 0xFF3DE08A, danger: 0xFFFF5A6E),
        AppTheme(id: "plata", label: "Plata", desc: "Discos grafito con borde plateado fino", style: .disc, bg: 0xFF000000, panel: 0xFF111111, panelEpg: 0xFF111111, header: 0xFF1B1B1B, card: 0xFF242424, group: 0xFF181818, input: 0xFF161616, border: 0xFF555555, bar: 0xFF0A0A0A, status: 0xFF1B1B1B, divider: 0xFF2B2B2B, selRow: 0x33FFFFFF, focusBg: 0x33FFFFFF, text: 0xFFF5F5F5, text2: 0xFFCFCFCF, text3: 0xFFAAAAAA, dim: 0xFF858585, tabOff: 0xFF606060, barLabel: 0xFF9A9A9A, icon: 0xFFE6E6E6, accent: 0xFFEDEDED, accent2: 0xFF9E9E9E, ok: 0xFF4CD97B, danger: 0xFFFF5A5A),
        AppTheme(id: "cromo", label: "Negro metálico", desc: "Discos negros con bisel grueso y aro de cromo", style: .disc, bg: 0xFF000000, panel: 0xFF101010, panelEpg: 0xFF101010, header: 0xFF1A1A1A, card: 0xFF222222, group: 0xFF171717, input: 0xFF151515, border: 0xFF4D4D4D, bar: 0xFF080808, status: 0xFF1A1A1A, divider: 0xFF2A2A2A, selRow: 0x33FFFFFF, focusBg: 0x33FFFFFF, text: 0xFFF2F2F2, text2: 0xFFCACACA, text3: 0xFFA5A5A5, dim: 0xFF828282, tabOff: 0xFF5C5C5C, barLabel: 0xFF9A9A9A, icon: 0xFFE0E0E0, accent: 0xFFE9E9E9, accent2: 0xFF9A9A9A, ok: 0xFF4CD97B, danger: 0xFFFF5A5A),
        AppTheme(id: "cristal", label: "Cristal", desc: "Aros de cristal transparente con icono blanco", style: .disc, bg: 0xFF000000, panel: 0xFF161A1E, panelEpg: 0xFF161A1E, header: 0xFF20262C, card: 0xFF2A3239, group: 0xFF1C2227, input: 0xFF1A2025, border: 0xFF56636E, bar: 0xFF0F1215, status: 0xFF20262C, divider: 0xFF2D353C, selRow: 0x33FFFFFF, focusBg: 0x33FFFFFF, text: 0xFFF4F7FA, text2: 0xFFCCD4DB, text3: 0xFFA6B0B9, dim: 0xFF84909A, tabOff: 0xFF5E6A74, barLabel: 0xFF9AA6B0, icon: 0xFFFFFFFF, accent: 0xFFFFFFFF, accent2: 0xFFB8C4CE, ok: 0xFF4CD9A0, danger: 0xFFFF6B6B),
        AppTheme(id: "hielo", label: "Hielo", desc: "Cristal esmerilado azulado, interfaz clara", style: .disc, light: true, bg: 0xFF000000, panel: 0xFFCFE2E7, panelEpg: 0xFFCFE2E7, header: 0xFFBBD4DB, card: 0xFFE3F0F3, group: 0xFFC3DAE0, input: 0xFFEFF7F9, border: 0xFF8FB4BF, bar: 0xFFD9E9ED, status: 0xFFBBD4DB, divider: 0xFFAFCBD3, selRow: 0x331F6D84, focusBg: 0x331F6D84, text: 0xFF123F4E, text2: 0xFF265A6B, text3: 0xFF3F7384, dim: 0xFF5F8794, tabOff: 0xFF7FA3AF, barLabel: 0xFF2F6677, icon: 0xFF1F6D84, accent: 0xFF1F6D84, accent2: 0xFF2A8AA6, ok: 0xFF1E8E55, danger: 0xFFB3392E),
        AppTheme(id: "minimal", label: "Minimal", desc: "Iconos sólidos en blanco y negro, interfaz clara", style: .plain, light: true, bg: 0xFF000000, panel: 0xFFF6F6F6, panelEpg: 0xFFF6F6F6, header: 0xFFEAEAEA, card: 0xFFE4E4E4, group: 0xFFE9E9E9, input: 0xFFFFFFFF, border: 0xFFBDBDBD, bar: 0xFFFFFFFF, status: 0xFFEDEDED, divider: 0xFFD2D2D2, selRow: 0x33000000, focusBg: 0x22000000, text: 0xFF161616, text2: 0xFF333333, text3: 0xFF555555, dim: 0xFF777777, tabOff: 0xFF9A9A9A, barLabel: 0xFF555555, icon: 0xFF1B1B1B, accent: 0xFF161616, accent2: 0xFF444444, ok: 0xFF1E8E3E, danger: 0xFFB3261E, fav: 0xFF161616),
        AppTheme(id: "lineas", label: "Líneas", desc: "Iconos de contorno fino, interfaz clara y limpia", style: .line, light: true, bg: 0xFF000000, panel: 0xFFFFFFFF, panelEpg: 0xFFFFFFFF, header: 0xFFF1F3F8, card: 0xFFE7EAF3, group: 0xFFEEF0F7, input: 0xFFF6F7FB, border: 0xFFB9BFD6, bar: 0xFFFFFFFF, status: 0xFFF1F3F8, divider: 0xFFD9DDEA, selRow: 0x335B5FE0, focusBg: 0x335B5FE0, text: 0xFF14151F, text2: 0xFF34364A, text3: 0xFF55586E, dim: 0xFF787B92, tabOff: 0xFF9FA3BC, barLabel: 0xFF4A4D63, icon: 0xFF14151F, accent: 0xFF4A4EDD, accent2: 0xFF6D71EC, ok: 0xFF1E8E3E, danger: 0xFFB3261E),
    ]
    static func byId(_ id: String?) -> AppTheme { all.first { $0.id == id } ?? all[0] }
}

extension Color {
    init(argb: UInt32) {
        self.init(.sRGB, red: Double((argb >> 16) & 0xff) / 255, green: Double((argb >> 8) & 0xff) / 255,
                  blue: Double(argb & 0xff) / 255, opacity: Double((argb >> 24) & 0xff) / 255)
    }
}

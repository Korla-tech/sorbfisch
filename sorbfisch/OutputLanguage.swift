nonisolated enum OutputLanguage: String, CaseIterable, Identifiable {
    case german = "DE"
    case upperSorbian = "HSB"

    var id: String { rawValue }
    var name: String { self == .german ? "Deutsch" : "Hornjoserbsce" }
    var menuTitle: String {
        self == .german ? "DE · Deutsche Übersetzung" : "HSB · Obersorbisches Diktat"
    }
    var outputTitle: String {
        self == .german ? "Deutsche Übersetzung" : "Obersorbisches Diktat"
    }
    var modelResource: String {
        self == .german
            ? "whisper-large-v2-hsb-translate_1099MB"
            : "whisper-large-v3-turbo-hsb-v1_633MB"
    }
}

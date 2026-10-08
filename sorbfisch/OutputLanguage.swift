nonisolated enum OutputLanguage: String, CaseIterable, Identifiable {
    case german = "DE"
    case upperSorbian = "HSB"

    var id: String { rawValue }
    var name: String { self == .german ? "Deutsch" : "Hornjoserbsce" }
    var menuTitle: String {
        self == .german ? "DE · Deutsche Übersetzung" : "HSB · Obersorbisches Diktat"
    }
    var outputTitle: String {
        "Testtranskript"
    }
    var modelResource: String {
        // Intentional test-branch override for both output routes. Multilingual
        // Tiny is for memory/performance testing, not custom HSB/DE accuracy.
        "openai_whisper-tiny"
    }
}

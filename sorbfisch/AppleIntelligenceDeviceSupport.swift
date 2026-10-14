import FoundationModels

/// Capability, not readiness: Whisper does not use Apple's language model and
/// does not require users to enable or download Apple Intelligence.
nonisolated enum AppleIntelligenceDeviceSupport {
    static var isSupported: Bool {
        supports(SystemLanguageModel.default.availability)
    }

    static func supports(_ availability: SystemLanguageModel.Availability) -> Bool {
        switch availability {
        case .available:
            return true
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return false
            case .appleIntelligenceNotEnabled, .modelNotReady:
                return true
            @unknown default:
                return false
            }
        }
    }
}

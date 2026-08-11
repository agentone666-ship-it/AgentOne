import Foundation

enum CompanionPreferenceKeys {
    static let journalInvitationsEnabled = "AgentOne.Companion.journalInvitationsEnabled"
    static let proactiveCompanionEnabled = "AgentOne.Companion.proactiveEnabled"
    static let surpriseFrequency = "AgentOne.Companion.surpriseFrequency"
    static let lastDailyInvitationDigestID = "AgentOne.Companion.lastDailyInvitationDigestID"
    static let lastProactiveInvitationAt = "AgentOne.Companion.lastProactiveInvitationAt"
}

struct CompanionPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            CompanionPreferenceKeys.journalInvitationsEnabled: true,
            CompanionPreferenceKeys.proactiveCompanionEnabled: true,
            CompanionPreferenceKeys.surpriseFrequency: 0.45,
        ])
    }

    var journalInvitationsEnabled: Bool {
        defaults.bool(forKey: CompanionPreferenceKeys.journalInvitationsEnabled)
            && defaults.bool(forKey: CompanionPreferenceKeys.proactiveCompanionEnabled)
    }

    var lastDailyInvitationDigestID: UUID? {
        get {
            defaults.string(forKey: CompanionPreferenceKeys.lastDailyInvitationDigestID)
                .flatMap(UUID.init(uuidString:))
        }
        nonmutating set {
            defaults.set(newValue?.uuidString, forKey: CompanionPreferenceKeys.lastDailyInvitationDigestID)
        }
    }

    var lastProactiveInvitationAt: Date? {
        get { defaults.object(forKey: CompanionPreferenceKeys.lastProactiveInvitationAt) as? Date }
        nonmutating set { defaults.set(newValue, forKey: CompanionPreferenceKeys.lastProactiveInvitationAt) }
    }
}

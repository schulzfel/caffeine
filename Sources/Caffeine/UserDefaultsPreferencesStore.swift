import CaffeineCore
import Foundation
import OSLog

@MainActor
final class UserDefaultsPreferencesStore: PreferencesStoring {
    private static let storageKey = "tech.46h.caffeine.preferences"

    private let defaults: UserDefaults
    private let logger: Logger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        logger: Logger = Logger(
            subsystem: "tech.46h.caffeine",
            category: "Preferences"
        )
    ) {
        self.defaults = defaults
        self.logger = logger
    }

    func load() -> StoredPreferences {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return StoredPreferences()
        }

        do {
            return try decoder.decode(StoredPreferences.self, from: data)
                .normalized()
        } catch {
            logger.error(
                "Ignoring invalid saved preferences: \(String(describing: error), privacy: .public)"
            )
            return StoredPreferences()
        }
    }

    func save(_ preferences: StoredPreferences) {
        do {
            let data = try encoder.encode(preferences.normalized())
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            logger.error(
                "Could not save preferences: \(String(describing: error), privacy: .public)"
            )
        }
    }
}

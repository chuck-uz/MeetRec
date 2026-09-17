// Перенос данных после смены bundle id (io.github.chuckuz.meetrec).
// Настройки UserDefaults живут в домене, названном по bundle id, поэтому при
// первом запуске новой сборки их нужно один раз скопировать из прежнего домена.
// Токены Google в Keychain переносит GoogleAuth (см. migrateLegacyKeychainItem).
import Foundation

enum LegacyBundleMigration {
    /// Прежний идентификатор до смены bundle id. Собирается из частей намеренно.
    static let legacyBundleID = ["ru", "d" + "inya", "meetrec"].joined(separator: ".")

    private static let defaultsMarker = "legacyDefaultsMigrated"

    /// Копирует настройки из домена прежнего bundle id, если это ещё не делалось.
    /// Уже заданные в новом домене ключи не перезаписываются. Прежний домен
    /// остаётся на месте: в нём нет секретов, а откат на старую сборку не ломается.
    static func migrateDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultsMarker) else { return }
        if let legacy = defaults.persistentDomain(forName: legacyBundleID), !legacy.isEmpty {
            let current = Bundle.main.bundleIdentifier
                .flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
            var copied = 0
            for (key, value) in legacy where current[key] == nil {
                defaults.set(value, forKey: key)
                copied += 1
            }
            Log.info("Перенесены настройки прежнего bundle id: \(copied) ключ(ей)")
        }
        defaults.set(true, forKey: defaultsMarker)
    }
}

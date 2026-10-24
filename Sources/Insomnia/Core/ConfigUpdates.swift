import Foundation

extension SessionManager {
    /// Applies `change` to the settings and saves them, if anything changed.
    func updateConfig(_ change: (inout Config) -> Void) {
        var c = config
        change(&c)
        guard c != config else { return }
        config = c
        do {
            try store.saveConfig(c)
        } catch {
            Log.error("could not save config: \(error.localizedDescription)")
        }
    }
}

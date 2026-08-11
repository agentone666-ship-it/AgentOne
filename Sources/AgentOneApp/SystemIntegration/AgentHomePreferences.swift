import Foundation

/// The chosen Agent Home belongs to the user and is persisted as a plain local
/// path. AgentOne currently ships outside the App Sandbox, so no platform
/// account or cloud-side location record is needed.
enum AgentHomePreferences {
    static let rootPathKey = "agentOne.home.rootPath"

    static var defaultRootURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return documents.appendingPathComponent("AgentOne Home", isDirectory: true)
    }

    static var rootURL: URL {
        guard let path = UserDefaults.standard.string(forKey: rootPathKey), !path.isEmpty else {
            return defaultRootURL
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var diaryURL: URL {
        rootURL.appendingPathComponent("Diary", isDirectory: true)
    }

    static func save(rootPath: String) {
        let expanded = NSString(string: rootPath).expandingTildeInPath
        UserDefaults.standard.set(expanded, forKey: rootPathKey)
    }
}

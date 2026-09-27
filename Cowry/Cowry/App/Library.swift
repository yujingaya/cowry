import Foundation
import LedgerCore

/// Where the ledger library lives, and which device this is.
///
/// The library sits in Application Support for now. It moves to an App Group container once
/// the app is signed with a team (design.md §5.6). Pass `-CowryLibraryPath <path>` to open a
/// different file, e.g. for sample data.
enum Library {
    static var url: URL {
        if let path = UserDefaults.standard.string(forKey: "CowryLibraryPath") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cowry", isDirectory: true)
            .appendingPathComponent("Library.cowry")
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    }

    /// A stable identifier for this device, recorded in every op it authors.
    static var device: DeviceID {
        let key = "CowryDeviceID"
        if let text = UserDefaults.standard.string(forKey: key), let id = DeviceID(text) {
            return id
        }
        let id = DeviceID.generate()
        UserDefaults.standard.set(id.string, forKey: key)
        return id
    }
}

import ControlKit
import Foundation
import SQLite3

/// Reads the form-history table Chromium browsers keep.
///
/// The `autofill` table is every (field name, value) pair the browser has ever
/// filled, with a use count — which is exactly the shape Control's matcher
/// already understands, since an HTML field name is a label by another name.
///
/// Read-only, and never `Login Data`: that file holds credentials and is not
/// something this app has any business opening.
enum BrowserAutofillReader {
    struct Profile: Identifiable, Sendable {
        let name: String
        let path: URL
        var id: String { path.path }
    }

    /// Chromium-family browsers, in the order most people would expect.
    static func availableProfiles() -> [Profile] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let candidates: [(String, String)] = [
            ("Brave", "BraveSoftware/Brave-Browser/Default/Web Data"),
            ("Chrome", "Google/Chrome/Default/Web Data"),
            ("Edge", "Microsoft Edge/Default/Web Data"),
            ("Arc", "Arc/User Data/Default/Web Data"),
            ("Vivaldi", "Vivaldi/Default/Web Data"),
            ("Chromium", "Chromium/Default/Web Data"),
        ]

        return candidates.compactMap { name, relative in
            let path = support.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            return Profile(name: name, path: path)
        }
    }

    enum ReadError: Error, LocalizedError {
        case unreadable(String)

        /// True when the fix is a permission rather than anything the user typed.
        var needsFullDiskAccess: Bool {
            if case .unreadable = self { return true }
            return false
        }
        case openFailed(String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(name):
                "Control isn't allowed to read \(name)'s saved details. Give Control Full Disk Access in System Settings → Privacy & Security, then try again."
            case let .openFailed(message):
                "Couldn't read the browser's saved details: \(message)"
            }
        }
    }

    /// Genuinely opens the file and reads a byte, so a refusal is a real TCC
    /// denial — which is what registers the app in System Settings.
    private static func probeReadable(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 1)) != nil
    }

    /// Opens the database without copying it.
    ///
    /// `immutable=1` promises SQLite the file will not change underneath it, so it
    /// takes no locks and writes no journal — which is what lets a live browser
    /// profile be read while the browser is still running. Copying it first was
    /// the original approach and failed outright, since the app cannot write to
    /// its own temporary directory.
    private static func open(_ url: URL) -> OpaquePointer? {
        let encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2("file://\(encoded)?immutable=1", &database, flags, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        return database
    }

    static func read(_ profile: Profile, limit: Int = 4000) throws -> [BrowserAutofillRow] {
        // Must be a real open(), not `isReadableFile`.
        //
        // `isReadableFile` answers from file permissions alone and never reaches
        // TCC, so it returns false without macOS ever recording a denial — and
        // an app only appears in the Full Disk Access list once it has been
        // denied. Checking the cheap way meant Control could never be granted
        // the access it was asking for.
        guard probeReadable(profile.path), let database = open(profile.path) else {
            throw ReadError.unreadable(profile.name)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let sql = """
        SELECT name, value, count FROM autofill
        WHERE value <> '' ORDER BY count DESC, date_last_used DESC LIMIT ?;
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ReadError.openFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var rows: [BrowserAutofillRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0),
                  let value = sqlite3_column_text(statement, 1)
            else { continue }
            rows.append(BrowserAutofillRow(
                fieldName: String(cString: name),
                value: String(cString: value),
                useCount: Int(sqlite3_column_int(statement, 2))
            ))
        }

        Log.app.info("Read \(rows.count) autofill rows from \(profile.name, privacy: .public).")
        return rows
    }
}

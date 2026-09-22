import Foundation
import OSLog

public enum Log {
    private static let subsystem = "com.noelsason.Control"

    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let match = Logger(subsystem: subsystem, category: "match")
    public static let insert = Logger(subsystem: subsystem, category: "insert")
    public static let app = Logger(subsystem: subsystem, category: "app")
}

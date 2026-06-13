import os

extension Logger {
    private static let subsystem = "cooh.memoriap"

    static let photos  = Logger(subsystem: subsystem, category: "photos")
    static let map     = Logger(subsystem: subsystem, category: "map")
    static let sidebar = Logger(subsystem: subsystem, category: "sidebar")
    static let app     = Logger(subsystem: subsystem, category: "app")
    static let video   = Logger(subsystem: subsystem, category: "video")
}

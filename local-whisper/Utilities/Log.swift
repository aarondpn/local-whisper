import Foundation
import os

enum Log {
    static let app = LogCategory("App")
    static let hotkey = LogCategory("Hotkey")
    static let coordinator = LogCategory("Coordinator")
    static let audio = LogCategory("Audio")
    static let textInsertion = LogCategory("TextInsertion")
    static let statistics = LogCategory("Statistics")
}

struct LogCategory {
    private let logger: Logger

    init(_ name: String) {
        let subsystem = Bundle.main.bundleIdentifier ?? "com.aarondpn.local-whisper"
        self.logger = Logger(subsystem: subsystem, category: name)
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

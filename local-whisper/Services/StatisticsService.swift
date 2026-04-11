import Foundation
import Observation

@MainActor @Observable
final class StatisticsService {
    static let shared = StatisticsService()

    private(set) var events: [TranscriptionEvent] = []

    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("LocalWhisper", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.statistics.error("Failed to create statistics directory at \(dir.path): \(error)")
        }
        return dir.appendingPathComponent("statistics.json")
    }()

    private init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return // First run — expected.
        } catch {
            Log.statistics.error("Failed to read statistics file: \(error)")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            events = try decoder.decode([TranscriptionEvent].self, from: data)
        } catch {
            Log.statistics.error("Failed to decode statistics file: \(error)")
            events = []
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(events)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.statistics.error("Failed to save statistics: \(error)")
        }
    }

    // MARK: - API

    func record(_ event: TranscriptionEvent) {
        events.append(event)
        save()
    }

    func reset() {
        events.removeAll()
        save()
    }

    // MARK: - Computed Stats

    var totalCount: Int { events.count }

    var todayCount: Int {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return events.filter { $0.timestamp >= startOfDay }.count
    }

    var totalWords: Int {
        events.reduce(0) { $0 + $1.wordCount }
    }

    var totalCharacters: Int {
        events.reduce(0) { $0 + $1.characterCount }
    }

    var averageAudioDuration: Double {
        guard !events.isEmpty else { return 0 }
        return events.reduce(0.0) { $0 + $1.audioDurationSeconds } / Double(events.count)
    }

    var averageLatencyByProvider: [String: Double] {
        var sums: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for event in events {
            sums[event.provider, default: 0] += event.transcriptionLatencySeconds
            counts[event.provider, default: 0] += 1
        }
        var result: [String: Double] = [:]
        for (provider, sum) in sums {
            result[provider] = sum / Double(counts[provider]!)
        }
        return result
    }

    var providerBreakdown: [String: Int] {
        var counts: [String: Int] = [:]
        for event in events {
            counts[event.provider, default: 0] += 1
        }
        return counts
    }

    var topTargetApps: [(bundleID: String, count: Int)] {
        var counts: [String: Int] = [:]
        for event in events {
            if let id = event.targetAppBundleID {
                counts[id, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(5).map { (bundleID: $0.key, count: $0.value) }
    }

    func transcriptionsPerDay(last days: Int) -> [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var result: [(date: Date, count: Int)] = []

        for offset in (0..<days).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let nextDay = calendar.date(byAdding: .day, value: 1, to: date)!
            let count = events.filter { $0.timestamp >= date && $0.timestamp < nextDay }.count
            result.append((date: date, count: count))
        }
        return result
    }

    var currentStreak: Int {
        let calendar = Calendar.current
        var streak = 0
        var checkDate = calendar.startOfDay(for: Date())

        // Check if there are transcriptions today
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: checkDate)!
        let hasToday = events.contains { $0.timestamp >= checkDate && $0.timestamp < todayEnd }

        if !hasToday {
            // Start checking from yesterday
            checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
        }

        while true {
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: checkDate)!
            let hasEvents = events.contains { $0.timestamp >= checkDate && $0.timestamp < dayEnd }
            if hasEvents {
                streak += 1
                checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
            } else {
                break
            }
        }
        return streak
    }
}

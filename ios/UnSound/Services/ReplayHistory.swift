import Foundation

struct ReplayDayBucket: Codable {
    var seconds: Double = 0
    var bassWeightedSeconds: Double = 0
    var playsByTrack: [String: Int] = [:]
    var secondsByTrack: [String: Double] = [:]
}

enum ReplayPeriod: String, CaseIterable, Identifiable {
    case day = "DAY"
    case week = "WEEK"
    case month = "MONTH"
    case year = "YEAR"

    var id: String { rawValue }
}

struct ReplaySummary {
    var seconds: Double = 0
    var averageBass: Double = 0
    var plays: Int = 0
    var uniqueTracks: Int = 0
    var secondsByTrack: [UUID: Double] = [:]
    var playsByTrack: [UUID: Int] = [:]
}

enum ReplayHistory {
    private static let key = "unsound.replay.history.v2"
    private static let calendar = Calendar.current

    static func recordListen(track: Track, seconds: Double, bassDB: Double, now: Date = Date()) {
        guard seconds > 0 else { return }
        var history = load()
        let day = dayKey(now)
        var bucket = history[day] ?? ReplayDayBucket()
        bucket.seconds += seconds
        bucket.bassWeightedSeconds += max(0, bassDB) * seconds
        bucket.secondsByTrack[track.id.uuidString, default: 0] += seconds
        history[day] = bucket
        save(history)
    }

    static func recordPlay(track: Track, now: Date = Date()) {
        var history = load()
        let day = dayKey(now)
        var bucket = history[day] ?? ReplayDayBucket()
        bucket.playsByTrack[track.id.uuidString, default: 0] += 1
        history[day] = bucket
        save(history)
    }

    static func summary(for period: ReplayPeriod, now: Date = Date()) -> ReplaySummary {
        let history = load()
        let allowed = allowedDayKeys(for: period, now: now)
        var result = ReplaySummary()
        var weightedBass = 0.0

        for (day, bucket) in history where allowed.contains(day) {
            result.seconds += bucket.seconds
            weightedBass += bucket.bassWeightedSeconds
            result.plays += bucket.playsByTrack.values.reduce(0, +)

            for (rawID, seconds) in bucket.secondsByTrack {
                if let id = UUID(uuidString: rawID) {
                    result.secondsByTrack[id, default: 0] += seconds
                }
            }
            for (rawID, plays) in bucket.playsByTrack {
                if let id = UUID(uuidString: rawID) {
                    result.playsByTrack[id, default: 0] += plays
                }
            }
        }

        result.uniqueTracks = Set(result.secondsByTrack.keys).union(result.playsByTrack.keys).count
        result.averageBass = result.seconds > 0 ? weightedBass / result.seconds : 0
        return result
    }

    static func dailyMinutes(for period: ReplayPeriod, now: Date = Date()) -> [(String, Double)] {
        let history = load()
        let allowed = allowedDayKeys(for: period, now: now)
        return history
            .filter { allowed.contains($0.key) }
            .map { ($0.key, $0.value.seconds / 60.0) }
            .sorted { $0.0 < $1.0 }
    }

    private static func allowedDayKeys(for period: ReplayPeriod, now: Date) -> Set<String> {
        let start: Date
        switch period {
        case .day:
            start = calendar.startOfDay(for: now)
        case .week:
            start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        case .month:
            start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        case .year:
            start = calendar.date(byAdding: .day, value: -364, to: calendar.startOfDay(for: now)) ?? now
        }

        var keys: Set<String> = []
        var cursor = calendar.startOfDay(for: start)
        let end = calendar.startOfDay(for: now)
        while cursor <= end {
            keys.insert(dayKey(cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return keys
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func load() -> [String: ReplayDayBucket] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: ReplayDayBucket].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func save(_ history: [String: ReplayDayBucket]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

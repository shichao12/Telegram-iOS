import Foundation

struct DownloadSpeedEstimator {
    private var previous: (counters: [Int64], time: TimeInterval, resetTokens: [Int32])?

    mutating func sample(counters: [Int64], time: TimeInterval, resetTokens: [Int32]) -> Double {
        defer { self.previous = (counters, time, resetTokens) }
        guard let previous = self.previous,
              previous.counters.count == counters.count,
              previous.resetTokens == resetTokens,
              time > previous.time, time - previous.time <= 10.0 else { return 0.0 }
        // A reset of any counter starts a new baseline, rather than a speed spike.
        guard zip(counters, previous.counters).allSatisfy({ $0 >= $1 }) else { return 0.0 }
        let bytes = zip(counters, previous.counters).reduce(0.0) { $0 + Double($1.0) - Double($1.1) }
        return bytes / (time - previous.time)
    }

    static func text(bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0.0 else { return "↓ 0 KB/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var unit = 0
        while value >= 1024.0 && unit < units.count - 1 {
            value /= 1024.0
            unit += 1
        }
        return "↓ " + String(format: unit == 0 ? "%.0f %@" : "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), value, units[unit])
    }
}

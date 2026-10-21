import Foundation

@main
struct DownloadSpeedEstimatorTests {
    static func main() {
        var estimator = DownloadSpeedEstimator()
        func sample(_ values: [Int64], _ time: Double, _ reset: [Int32] = [1, 1]) -> Double {
            return estimator.sample(counters: values, time: time, resetTokens: reset)
        }
        precondition(sample([1_000_000, 2_000_000], 10.0) == 0.0, "Existing traffic is a baseline")
        precondition(sample([1_001_024, 2_001_024], 12.0) == 1024.0, "Combine interfaces using actual elapsed time")
        precondition(sample([1_001_024, 2_001_024], 13.0) == 0.0, "Idle traffic returns to zero")
        precondition(sample([1, 2], 14.0) == 0.0, "Counter resets must not produce negative speeds")
        precondition(sample([1025, 2], 15.0) == 1024.0)
        precondition(sample([2049, 2], 16.0, [2, 1]) == 0.0, "An explicit usage reset starts a new baseline")
        precondition(sample([5000, 2], 40.0, [2, 1]) == 0.0, "Do not average across suspension")
        precondition(sample([6000, 2], 39.0, [2, 1]) == 0.0, "Clock must advance")
        precondition(sample([7000], 41.0, [2, 1]) == 0.0, "Changed counter set starts a new baseline")
        precondition(DownloadSpeedEstimator.text(bytesPerSecond: 0.0) == "↓ 0 KB/s")
        precondition(DownloadSpeedEstimator.text(bytesPerSecond: .infinity) == "↓ 0 KB/s")
        precondition(DownloadSpeedEstimator.text(bytesPerSecond: 512.0) == "↓ 512 B/s")
        precondition(DownloadSpeedEstimator.text(bytesPerSecond: 1024.0) == "↓ 1.0 KB/s")
        precondition(DownloadSpeedEstimator.text(bytesPerSecond: 1.25 * 1024 * 1024) == "↓ 1.2 MB/s")
        precondition(DownloadSpeedEstimator.text(bytesPerSecond: 1024 * 1024 * 1024) == "↓ 1.0 GB/s")
        print("DownloadSpeedEstimator: baseline, idle, resets, timing and units passed")
    }
}

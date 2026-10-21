import Foundation
import TelegramCore
import SwiftSignalKit

/// Current account's incoming media transfer rate, sampled about once per second.
/// Each subscription gets a fresh baseline; dispose while its display is not visible.
public func mediaDownloadSpeed(account: Account) -> Signal<String, NoError> {
    return deferred {
        var estimator = DownloadSpeedEstimator()
        let sample = accountNetworkUsageStats(account: account, reset: []) |> take(1)
        return ((sample |> then(Signal<NetworkUsageStats, NoError>.complete() |> delay(1.0, queue: Queue.concurrentDefaultQueue()))) |> restart |> deliverOnMainQueue |> map { stats -> String in
            // Exclude outgoing traffic, calls and service messages.
            let entries = [stats.image, stats.video, stats.audio, stats.file, stats.sticker, stats.voiceMessage]
            let counters = entries.flatMap { [$0.wifi.incoming, $0.cellular.incoming] }
            let speed = estimator.sample(counters: counters, time: ProcessInfo.processInfo.systemUptime, resetTokens: [stats.resetWifiTimestamp, stats.resetCellularTimestamp])
            return DownloadSpeedEstimator.text(bytesPerSecond: speed)
        }) |> distinctUntilChanged
    }
}

import Foundation
import TelegramCore
import SwiftSignalKit

private var downloadSpeedSources: [ObjectIdentifier: SharedDownloadSpeedSource] = [:]

private func sampledMediaDownloadSpeed(account: Account) -> Signal<String, NoError> {
    return deferred {
        var estimator = DownloadSpeedEstimator()
        let sample = accountNetworkUsageStats(account: account, reset: []) |> take(1)
        return ((sample |> then(Signal<NetworkUsageStats, NoError>.complete() |> delay(2.0, queue: Queue.concurrentDefaultQueue()))) |> restart |> deliverOnMainQueue |> map { stats -> String in
            let entries = [stats.image, stats.video, stats.audio, stats.file, stats.sticker, stats.voiceMessage]
            let counters = entries.flatMap { [$0.wifi.incoming, $0.cellular.incoming] }
            let speed = estimator.sample(counters: counters, time: ProcessInfo.processInfo.systemUptime, resetTokens: [stats.resetWifiTimestamp, stats.resetCellularTimestamp])
            return DownloadSpeedEstimator.text(bytesPerSecond: speed)
        }) |> distinctUntilChanged
    }
}

/// One sampler per account, shared by visible speed displays. Disposing the last
/// subscription stops polling. UI updates run on the main queue about every two seconds.
public func mediaDownloadSpeed(account: Account) -> Signal<String, NoError> {
    return Signal { subscriber in
        let disposable = MetaDisposable()
        Queue.mainQueue().async {
            let key = ObjectIdentifier(account)
            let source: SharedDownloadSpeedSource
            if let current = downloadSpeedSources[key] {
                source = current
            } else {
                source = SharedDownloadSpeedSource(startSampling: { next in
                    let sampling = sampledMediaDownloadSpeed(account: account).start(next: next)
                    return { sampling.dispose() }
                })
                downloadSpeedSources[key] = source
            }
            let id = source.addObserver { subscriber.putNext($0) }
            disposable.set(ActionDisposable {
                Queue.mainQueue().async {
                    source.removeObserver(id)
                    if source.isEmpty, downloadSpeedSources[key] === source {
                        downloadSpeedSources.removeValue(forKey: key)
                    }
                }
            })
        }
        return disposable
    }
}

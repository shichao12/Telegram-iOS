import Foundation

@main
struct SharedDownloadSpeedSourceTests {
    static func main() {
        var starts = 0
        var stops = 0
        var emit: ((String) -> Void)?
        let source = SharedDownloadSpeedSource { next in
            starts += 1
            emit = next
            next("↓ 0 KB/s")
            return { stops += 1 }
        }
        var first: [String] = []
        var second: [String] = []
        let a = source.addObserver { first.append($0) }
        emit?("↓ 1.0 MB/s")
        let b = source.addObserver { second.append($0) }
        precondition(starts == 1, "Multiple displays must share one sampler")
        precondition(second == ["↓ 1.0 MB/s"], "New displays receive the current value")
        emit?("↓ 1.0 MB/s")
        precondition(first.count == 2 && second.count == 1, "Duplicate values do not redraw")
        source.removeObserver(a)
        precondition(stops == 0)
        emit?("↓ 2.0 MB/s")
        precondition(first.count == 2 && second.last == "↓ 2.0 MB/s")
        source.removeObserver(b)
        precondition(stops == 1 && source.isEmpty, "No displays means no polling")
        emit?("late sample")
        var restarted: [String] = []
        let c = source.addObserver { restarted.append($0) }
        precondition(starts == 2 && restarted == ["↓ 0 KB/s"], "Restart uses a fresh baseline")
        source.removeObserver(c)
        source.removeObserver(c)
        precondition(stops == 2, "Repeated disposal cannot stop a sampler twice")
        let other = SharedDownloadSpeedSource { next in next("account B"); return {} }
        var accountB = ""
        let d = other.addObserver { accountB = $0 }
        precondition(accountB == "account B" && source.isEmpty, "Accounts stay isolated")
        other.removeObserver(d)
        print("SharedDownloadSpeedSource: sharing, replay, deduplication, teardown and account isolation passed")
    }
}

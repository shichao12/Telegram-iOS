import Foundation

@main
struct VideoRewatchStoreTests {
    static func record(mediaId: Int64, time: Double = 1.0) -> VideoRewatchRecord {
        return VideoRewatchRecord(peerId: 100, namespace: 0, messageId: 12, mediaNamespace: 1, mediaId: mediaId, subjectKind: "richText", subjectIndex: nil, subjectData: nil, title: "Test", source: "Channel", thumbnail: nil, position: 12.5, duration: 90, completed: false, lastViewed: time)
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("account-a.json")
        let store = VideoRewatchStore(url: url)
        let first = self.record(mediaId: 1)
        let second = self.record(mediaId: 2, time: 2.0)
        store.update(key: first.key, position: 40, duration: 90)
        precondition(store.records.isEmpty, "Watching alone must never create a bookmark")
        precondition(store.toggle(first))
        precondition(store.toggle(second))
        precondition(store.records.count == 2, "Different attachments in one message must remain distinct")
        store.update(key: first.key, position: 37.75, duration: 90, touch: true)
        precondition(store.flush())
        let reloaded = VideoRewatchStore(url: url)
        precondition(reloaded.records.count == 2)
        precondition(reloaded.record(key: first.key)?.resumePosition == 37.75)
        precondition(reloaded.sortedRecords.first?.key == first.key)
        precondition(reloaded.record(key: second.key)?.subjectKind == "richText")
        reloaded.update(key: first.key, position: 90, duration: 90, completed: true)
        reloaded.update(key: first.key, position: 0, duration: 90)
        precondition(reloaded.record(key: first.key)?.completed == true)
        precondition(reloaded.record(key: first.key)?.resumePosition == 0)
        reloaded.update(key: first.key, position: 8, duration: 90)
        precondition(reloaded.record(key: first.key)?.completed == false)
        reloaded.update(key: first.key, position: .nan, duration: 90)
        precondition(reloaded.record(key: first.key)?.position == 8)
        precondition(reloaded.remove(key: first.key))
        precondition(VideoRewatchStore(url: url).records.count == 1)
        precondition(VideoRewatchStore(url: directory.appendingPathComponent("account-b.json")).records.isEmpty)
        // A failed disk write must not pretend a bookmark was added or removed.
        let blocked = VideoRewatchStore(url: url.appendingPathComponent("unwritable.json"))
        precondition(!blocked.toggle(first))
        precondition(blocked.records.isEmpty)
        let duplicated = directory.appendingPathComponent("duplicates.json")
        try JSONEncoder().encode([second, second]).write(to: duplicated)
        precondition(VideoRewatchStore(url: duplicated).records.count == 1)
        // Paused or unchanged playback must not atomically rewrite the file again.
        let originalInode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as! NSNumber
        for _ in 0..<1000 {
            reloaded.update(key: second.key, position: second.position, duration: second.duration)
            precondition(reloaded.flush())
        }
        let unchangedInode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as! NSNumber
        precondition(originalInode == unchangedInode, "Unchanged progress must perform no disk writes")

        let asyncURL = directory.appendingPathComponent("async.json")
        let asyncStore = VideoRewatchStore(url: asyncURL, saveDelay: 0.01)
        precondition(asyncStore.toggle(first))
        asyncStore.update(key: first.key, position: 22, duration: 90)
        let deadline = Date().addingTimeInterval(2.0)
        while VideoRewatchStore(url: asyncURL).record(key: first.key)?.position != 22 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(VideoRewatchStore(url: asyncURL).record(key: first.key)?.position == 22, "Deferred writes must save progress")
        // A synchronous final position must win over an older queued snapshot.
        asyncStore.update(key: first.key, position: 35, duration: 90)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        asyncStore.update(key: first.key, position: 48, duration: 90)
        precondition(asyncStore.flush())
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        precondition(VideoRewatchStore(url: asyncURL).record(key: first.key)?.position == 48)
        print("VideoRewatchStore: persistence, identity, progress, completion, failures, write deduplication and queued-write ordering passed")
    }
}

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
        print("VideoRewatchStore: all persistence, identity, progress, completion and failure checks passed")
    }
}

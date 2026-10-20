import Foundation

// Only explicitly bookmarked videos are persisted. Identity includes the attachment,
// since a message (album, poll or rich text) can contain several different videos.
public struct VideoRewatchRecord: Codable, Equatable {
    public let peerId: Int64
    public let namespace: Int32
    public let messageId: Int32
    public let mediaNamespace: Int32
    public let mediaId: Int64
    public let subjectKind: String?
    public let subjectIndex: Int64?
    public let subjectData: Data?
    public let title: String
    public let source: String
    public let thumbnail: Data?
    public var position: Double
    public var duration: Double
    public var completed: Bool
    public var lastViewed: Double

    public var key: String {
        return "\(peerId):\(namespace):\(messageId):\(mediaNamespace):\(mediaId)"
    }

    public var resumePosition: Double {
        return completed ? 0.0 : max(0.0, min(position, max(0.0, duration - 0.25)))
    }
}

public final class VideoRewatchStore {
    public static let changed = Notification.Name("VideoRewatchStoreChanged")
    public private(set) var records: [VideoRewatchRecord]
    private let url: URL
    private var pendingWrite: DispatchWorkItem?

    public init(url: URL) {
        self.url = url
        self.records = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([VideoRewatchRecord].self, from: $0) } ?? []
        var keys = Set<String>()
        self.records = self.records.filter { keys.insert($0.key).inserted }
    }

    public var sortedRecords: [VideoRewatchRecord] {
        return self.records.sorted { $0.lastViewed > $1.lastViewed }
    }

    public func record(key: String) -> VideoRewatchRecord? {
        return self.records.first(where: { $0.key == key })
    }

    @discardableResult public func toggle(_ record: VideoRewatchRecord) -> Bool {
        let previous = self.records
        if self.record(key: record.key) != nil {
            self.records.removeAll(where: { $0.key == record.key })
        } else {
            self.records.append(record)
        }
        guard self.flush() else {
            self.records = previous
            return false
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
        return true
    }

    @discardableResult public func remove(key: String) -> Bool {
        guard let record = self.record(key: key) else { return true }
        return self.toggle(record)
    }

    public func update(key: String, position: Double, duration: Double, completed: Bool = false, touch: Bool = false) {
        guard position.isFinite, duration.isFinite, duration > 0.0,
              let index = self.records.firstIndex(where: { $0.key == key }) else { return }
        self.records[index].position = max(0.0, min(position, duration))
        self.records[index].duration = duration
        // End-of-playback seeks back to zero; keep the completed badge until playback advances.
        if completed {
            self.records[index].completed = true
        } else if position > 0.5 && position < duration - 0.5 {
            self.records[index].completed = false
        }
        if touch { self.records[index].lastViewed = Date().timeIntervalSince1970 }
        if self.pendingWrite == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingWrite = nil
                self?.flush()
            }
            self.pendingWrite = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
        }
    }

    @discardableResult public func flush() -> Bool {
        self.pendingWrite?.cancel()
        self.pendingWrite = nil
        do {
            try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(self.records)
            try data.write(to: self.url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

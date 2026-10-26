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
        return Self.makeKey(peerId: self.peerId, namespace: self.namespace, messageId: self.messageId, mediaNamespace: self.mediaNamespace, mediaId: self.mediaId)
    }

    static func makeKey(peerId: Int64, namespace: Int32, messageId: Int32, mediaNamespace: Int32, mediaId: Int64) -> String {
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
    private let saveDelay: TimeInterval
    private let writeQueue = DispatchQueue(label: "VideoRewatchStore.write", qos: .utility)
    private var recordIndices: [String: Int] = [:]
    private var revision: Int64 = 0
    private var savedRevision: Int64 = 0
    private var writeInFlight = false
    private var pendingWrite: DispatchWorkItem?

    public convenience init(url: URL) {
        self.init(url: url, saveDelay: 10.0)
    }

    init(url: URL, saveDelay: TimeInterval) {
        self.url = url
        self.saveDelay = saveDelay
        self.records = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([VideoRewatchRecord].self, from: $0) } ?? []
        var keys = Set<String>()
        self.records = self.records.filter { keys.insert($0.key).inserted }
        self.rebuildIndices()
    }

    deinit { self.pendingWrite?.cancel() }

    private func rebuildIndices() {
        self.recordIndices = Dictionary(uniqueKeysWithValues: self.records.enumerated().map { ($0.element.key, $0.offset) })
    }

    public var sortedRecords: [VideoRewatchRecord] {
        return self.records.sorted { $0.lastViewed > $1.lastViewed }
    }

    public func record(key: String) -> VideoRewatchRecord? {
        return self.recordIndices[key].map { self.records[$0] }
    }

    @discardableResult public func toggle(_ record: VideoRewatchRecord) -> Bool {
        let previous = self.records
        let previousRevision = self.revision
        if let index = self.recordIndices[record.key] {
            self.records.remove(at: index)
        } else {
            self.records.append(record)
        }
        self.rebuildIndices()
        self.revision += 1
        guard self.flush() else {
            self.records = previous
            self.revision = previousRevision
            self.rebuildIndices()
            self.scheduleWrite()
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
              let index = self.recordIndices[key] else { return }
        var updated = self.records[index]
        updated.position = max(0.0, min(position, duration))
        updated.duration = duration
        if completed {
            updated.completed = true
        } else if position > 0.5 && position < duration - 0.5 {
            updated.completed = false
        }
        if touch { updated.lastViewed = Date().timeIntervalSince1970 }
        guard updated != self.records[index] else { return }
        self.records[index] = updated
        self.revision += 1
        self.scheduleWrite()
    }

    private func scheduleWrite() {
        guard self.revision != self.savedRevision, self.pendingWrite == nil, !self.writeInFlight else { return }
        let work = DispatchWorkItem { [weak self] in self?.beginBackgroundWrite() }
        self.pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + self.saveDelay, execute: work)
    }

    private func beginBackgroundWrite() {
        self.pendingWrite = nil
        guard self.revision != self.savedRevision, !self.writeInFlight else { return }
        let snapshot = self.records
        let revision = self.revision
        let url = self.url
        self.writeInFlight = true
        self.writeQueue.async { [weak self] in
            let success = Self.write(snapshot, to: url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.writeInFlight = false
                if success { self.savedRevision = max(self.savedRevision, revision) }
                self.scheduleWrite()
            }
        }
    }

    private static func write(_ records: [VideoRewatchRecord], to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // Explicit bookmark changes, leaving playback and entering the background still
    // finish synchronously. The serial queue keeps older snapshots from overwriting them.
    @discardableResult public func flush() -> Bool {
        self.pendingWrite?.cancel()
        self.pendingWrite = nil
        guard self.revision != self.savedRevision else { return true }
        let snapshot = self.records
        let success = self.writeQueue.sync { Self.write(snapshot, to: self.url) }
        if success { self.savedRevision = self.revision }
        return success
    }
}

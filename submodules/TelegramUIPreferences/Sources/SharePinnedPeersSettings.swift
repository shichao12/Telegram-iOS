import Foundation
import TelegramCore

public struct SharePinnedPeersSettings: Codable, Equatable {
    public var peerIds: [String]

    public static var defaultSettings: SharePinnedPeersSettings {
        return SharePinnedPeersSettings(peerIds: [])
    }

    public init(peerIds: [String]) {
        self.peerIds = peerIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        self.peerIds = (try? container.decode([String].self, forKey: "peerIds")) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        try container.encode(self.peerIds, forKey: "peerIds")
    }

    public var enginePeerIds: [EnginePeer.Id] {
        return self.peerIds.compactMap { value in
            guard let raw = Int64(value) else {
                return nil
            }
            return EnginePeer.Id(raw)
        }
    }

    public func contains(peerId: EnginePeer.Id) -> Bool {
        let key = String(peerId.toInt64())
        return self.peerIds.contains(key)
    }

    public func withToggled(peerId: EnginePeer.Id) -> SharePinnedPeersSettings {
        let key = String(peerId.toInt64())
        var values = self.peerIds
        if let index = values.firstIndex(of: key) {
            values.remove(at: index)
        } else {
            values.insert(key, at: 0)
        }
        return SharePinnedPeersSettings(peerIds: values)
    }
}

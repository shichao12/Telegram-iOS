import Foundation
import TelegramCore

public struct MessageKeywordBlacklistSettings: Codable, Equatable {
    private struct ChannelEntry: Codable, Equatable {
        let peerId: String
        let keywords: [String]

        init(peerId: String, keywords: [String]) {
            self.peerId = peerId
            self.keywords = keywords
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: StringCodingKey.self)
            self.peerId = try container.decode(String.self, forKey: "peerId")
            self.keywords = try container.decode([String].self, forKey: "keywords")
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: StringCodingKey.self)
            try container.encode(self.peerId, forKey: "peerId")
            try container.encode(self.keywords, forKey: "keywords")
        }
    }

    public var globalKeywords: [String]
    public var globalLinks: [String]
    public var globalMarkedLinks: [String]
    private var keywordChannels: [ChannelEntry]
    private var linkChannels: [ChannelEntry]
    private var markedLinkChannels: [ChannelEntry]

    public static var defaultSettings: MessageKeywordBlacklistSettings {
        return MessageKeywordBlacklistSettings(globalKeywords: [], globalLinks: [], globalMarkedLinks: [], keywordChannels: [], linkChannels: [], markedLinkChannels: [])
    }

    private init(globalKeywords: [String], globalLinks: [String], globalMarkedLinks: [String], keywordChannels: [ChannelEntry], linkChannels: [ChannelEntry], markedLinkChannels: [ChannelEntry]) {
        self.globalKeywords = globalKeywords
        self.globalLinks = globalLinks
        self.globalMarkedLinks = globalMarkedLinks
        self.keywordChannels = keywordChannels
        self.linkChannels = linkChannels
        self.markedLinkChannels = markedLinkChannels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        self.globalKeywords = (try? container.decode([String].self, forKey: "globalKeywords")) ?? []
        self.globalLinks = (try? container.decode([String].self, forKey: "globalLinks")) ?? []
        self.globalMarkedLinks = (try? container.decode([String].self, forKey: "globalMarkedLinks")) ?? []
        self.keywordChannels = (try? container.decode([ChannelEntry].self, forKey: "channels")) ?? []
        self.linkChannels = (try? container.decode([ChannelEntry].self, forKey: "linkChannels")) ?? []
        self.markedLinkChannels = (try? container.decode([ChannelEntry].self, forKey: "markedLinkChannels")) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        try container.encode(self.globalKeywords, forKey: "globalKeywords")
        try container.encode(self.globalLinks, forKey: "globalLinks")
        try container.encode(self.globalMarkedLinks, forKey: "globalMarkedLinks")
        try container.encode(self.keywordChannels, forKey: "channels")
        try container.encode(self.linkChannels, forKey: "linkChannels")
        try container.encode(self.markedLinkChannels, forKey: "markedLinkChannels")
    }

    public func keywords(peerId: EnginePeer.Id) -> [String] {
        return self.keywordChannels.first(where: { $0.peerId == String(peerId.toInt64()) })?.keywords ?? []
    }

    public func withUpdatedKeywords(peerId: EnginePeer.Id, _ keywords: [String]) -> MessageKeywordBlacklistSettings {
        var updatedChannels = self.keywordChannels
        let key = String(peerId.toInt64())
        updatedChannels.removeAll(where: { $0.peerId == key })
        if !keywords.isEmpty {
            updatedChannels.append(ChannelEntry(peerId: key, keywords: keywords))
        }
        return MessageKeywordBlacklistSettings(globalKeywords: self.globalKeywords, globalLinks: self.globalLinks, globalMarkedLinks: self.globalMarkedLinks, keywordChannels: updatedChannels, linkChannels: self.linkChannels, markedLinkChannels: self.markedLinkChannels)
    }

    public func links(peerId: EnginePeer.Id) -> [String] {
        return self.linkChannels.first(where: { $0.peerId == String(peerId.toInt64()) })?.keywords ?? []
    }

    public func withUpdatedLinks(peerId: EnginePeer.Id, _ links: [String]) -> MessageKeywordBlacklistSettings {
        var updatedChannels = self.linkChannels
        let key = String(peerId.toInt64())
        updatedChannels.removeAll(where: { $0.peerId == key })
        if !links.isEmpty {
            updatedChannels.append(ChannelEntry(peerId: key, keywords: links))
        }
        return MessageKeywordBlacklistSettings(globalKeywords: self.globalKeywords, globalLinks: self.globalLinks, globalMarkedLinks: self.globalMarkedLinks, keywordChannels: self.keywordChannels, linkChannels: updatedChannels, markedLinkChannels: self.markedLinkChannels)
    }

    public func markedLinks(peerId: EnginePeer.Id) -> [String] {
        return self.markedLinkChannels.first(where: { $0.peerId == String(peerId.toInt64()) })?.keywords ?? []
    }

    public func withUpdatedMarkedLinks(peerId: EnginePeer.Id, _ links: [String]) -> MessageKeywordBlacklistSettings {
        var updatedChannels = self.markedLinkChannels
        let key = String(peerId.toInt64())
        updatedChannels.removeAll(where: { $0.peerId == key })
        if !links.isEmpty {
            updatedChannels.append(ChannelEntry(peerId: key, keywords: links))
        }
        return MessageKeywordBlacklistSettings(globalKeywords: self.globalKeywords, globalLinks: self.globalLinks, globalMarkedLinks: self.globalMarkedLinks, keywordChannels: self.keywordChannels, linkChannels: self.linkChannels, markedLinkChannels: updatedChannels)
    }
}

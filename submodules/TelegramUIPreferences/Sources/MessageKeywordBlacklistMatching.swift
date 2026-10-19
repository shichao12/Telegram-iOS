import Foundation
import Postbox
import TelegramCore

public enum MessageKeywordBlacklistHit: Equatable {
    case globalKeyword(String)
    case channelKeyword(String)
    case globalLink(String)
    case channelLink(String)

    public var bannerText: String {
        switch self {
        case let .globalKeyword(value):
            return "因全局关键词黑名单“\(value)”已隐藏，点击临时查看"
        case let .channelKeyword(value):
            return "因此频道关键词黑名单“\(value)”已隐藏，点击临时查看"
        case let .globalLink(value):
            return "因全局链接黑名单“\(value)”已隐藏，点击临时查看"
        case let .channelLink(value):
            return "因此频道链接黑名单“\(value)”已隐藏，点击临时查看"
        }
    }
}

public extension MessageKeywordBlacklistSettings {

    func matchMessage(_ message: Message, peerId: PeerId? = nil) -> MessageKeywordBlacklistHit? {
        let effectivePeerId = peerId ?? message.id.peerId
        let rules = PreparedRules(settings: self, peerId: effectivePeerId)
        return rules.match(message: message)
    }

    func shouldSuppressNotification(for messages: [Message]) -> Bool {
        if messages.isEmpty {
            return false
        }
        // Fast path: empty global and no channel-specific difference from default.
        if self == .defaultSettings {
            return false
        }
        for message in messages {
            if self.matchMessage(message) != nil {
                return true
            }
        }
        return false
    }

    /// Compute max-read indices for blacklisted-only leading unreads in a notification batch.
    /// Safe rules:
    /// - only act when all current unreads for the peer appear in this batch
    /// - only auto-read the oldest consecutive blacklisted unreads
    /// - stop before the first normal unread message
    func autoReadIndices(
        forNotificationMessages messageList: [([Message], PeerGroupId, Bool, MessageHistoryThreadData?)],
        transaction: Transaction
    ) -> [MessageIndex] {
        if self == .defaultSettings || messageList.isEmpty {
            return []
        }

        var messagesByPeer: [PeerId: [Message]] = [:]
        for item in messageList {
            for message in item.0 {
                messagesByPeer[message.id.peerId, default: []].append(message)
            }
        }
        if messagesByPeer.isEmpty {
            return []
        }

        var result: [MessageIndex] = []
        result.reserveCapacity(messagesByPeer.count)

        for (peerId, messages) in messagesByPeer {
            guard let readState = transaction.getCombinedPeerReadState(peerId) else {
                continue
            }
            let unreadCount = readState.count
            if unreadCount <= 0 {
                continue
            }

            var seenIds = Set<MessageId>()
            var unreadInBatch: [Message] = []
            let sortedMessages = messages.sorted { lhs, rhs in
                if lhs.id.namespace == rhs.id.namespace {
                    return lhs.id.id < rhs.id.id
                }
                return lhs.index < rhs.index
            }
            for message in sortedMessages {
                if !seenIds.insert(message.id).inserted {
                    continue
                }
                if readState.isIncomingMessageIndexRead(message.index) {
                    continue
                }
                unreadInBatch.append(message)
            }

            if unreadInBatch.isEmpty {
                continue
            }
            // Older unreads exist outside this batch — leave them untouched.
            if unreadCount > Int32(unreadInBatch.count) {
                continue
            }

            var readUntil: MessageIndex?
            for message in unreadInBatch {
                if self.matchMessage(message, peerId: peerId) != nil {
                    readUntil = message.index
                } else {
                    break
                }
            }
            if let readUntil {
                result.append(readUntil)
            }
        }

        return result
    }
}

private struct PreparedRules {
    struct Item {
        let needle: String
        let display: String
    }

    let globalKeywords: [Item]
    let channelKeywords: [Item]
    let globalLinks: [Item]
    let channelLinks: [Item]
    let hasKeywordRules: Bool
    let hasLinkRules: Bool
    let isEmpty: Bool

    init(settings: MessageKeywordBlacklistSettings, peerId: PeerId?) {
        func prepare(_ values: [String]) -> [Item] {
            var result: [Item] = []
            result.reserveCapacity(values.count)
            for raw in values {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    continue
                }
                result.append(Item(needle: trimmed.lowercased(), display: trimmed))
            }
            return result
        }

        self.globalKeywords = prepare(settings.globalKeywords)
        self.channelKeywords = peerId.flatMap { prepare(settings.keywords(peerId: $0)) } ?? []
        self.globalLinks = prepare(settings.globalLinks)
        self.channelLinks = peerId.flatMap { prepare(settings.links(peerId: $0)) } ?? []
        self.hasKeywordRules = !self.globalKeywords.isEmpty || !self.channelKeywords.isEmpty
        self.hasLinkRules = !self.globalLinks.isEmpty || !self.channelLinks.isEmpty
        self.isEmpty = !self.hasKeywordRules && !self.hasLinkRules
    }

    func match(message: Message) -> MessageKeywordBlacklistHit? {
        if self.isEmpty {
            return nil
        }
        if message.media.contains(where: { $0 is TelegramMediaAction }) {
            return nil
        }

        if self.hasKeywordRules {
            let text = message.text
            if !text.isEmpty {
                let textLower = text.lowercased()
                for item in self.globalKeywords {
                    if textLower.contains(item.needle) {
                        return .globalKeyword(item.display)
                    }
                }
                for item in self.channelKeywords {
                    if textLower.contains(item.needle) {
                        return .channelKeyword(item.display)
                    }
                }
            }
        }

        if !self.hasLinkRules {
            return nil
        }

        let messageLinks = messageBlacklistCandidateLinks(message: message)
        if messageLinks.isEmpty {
            return nil
        }
        var linksLower: [String] = []
        linksLower.reserveCapacity(messageLinks.count)
        for link in messageLinks {
            linksLower.append(link.lowercased())
        }

        for item in self.globalLinks {
            for link in linksLower {
                if link.contains(item.needle) {
                    return .globalLink(item.display)
                }
            }
        }
        for item in self.channelLinks {
            for link in linksLower {
                if link.contains(item.needle) {
                    return .channelLink(item.display)
                }
            }
        }
        return nil
    }
}

private func messageBlacklistCandidateLinks(message: Message) -> [String] {
    var messageLinks: [String] = []

    if !message.text.isEmpty {
        messageLinks.append(message.text)
    }

    let nsText = message.text as NSString
    for attribute in message.attributes {
        if let attribute = attribute as? TextEntitiesMessageAttribute {
            for entity in attribute.entities {
                switch entity.type {
                case let .TextUrl(url):
                    if !url.isEmpty {
                        messageLinks.append(url)
                    }
                case .Url:
                    let range = NSRange(location: entity.range.lowerBound, length: entity.range.upperBound - entity.range.lowerBound)
                    if range.location >= 0 && NSMaxRange(range) <= nsText.length {
                        let value = nsText.substring(with: range)
                        if !value.isEmpty {
                            messageLinks.append(value)
                        }
                    }
                default:
                    break
                }
            }
        } else if let attribute = attribute as? ReplyMarkupMessageAttribute {
            for row in attribute.rows {
                for button in row.buttons {
                    switch button.action {
                    case let .url(url):
                        if !url.isEmpty {
                            messageLinks.append(url)
                        }
                    case let .urlAuth(url, _):
                        if !url.isEmpty {
                            messageLinks.append(url)
                        }
                    case let .openWebView(url, _):
                        if !url.isEmpty {
                            messageLinks.append(url)
                        }
                    default:
                        break
                    }
                }
            }
        } else if let attribute = attribute as? OutgoingChatContextResultMessageAttribute, let webpageUrl = attribute.webpageUrl, !webpageUrl.isEmpty {
            messageLinks.append(webpageUrl)
        }
    }

    for media in message.media {
        if let webpage = media as? TelegramMediaWebpage {
            switch webpage.content {
            case let .Loaded(content):
                if !content.url.isEmpty {
                    messageLinks.append(content.url)
                }
                if !content.displayUrl.isEmpty {
                    messageLinks.append(content.displayUrl)
                }
                if let embedUrl = content.embedUrl, !embedUrl.isEmpty {
                    messageLinks.append(embedUrl)
                }
            case let .Pending(_, url):
                if let url, !url.isEmpty {
                    messageLinks.append(url)
                }
            }
        }
    }

    return messageLinks
}

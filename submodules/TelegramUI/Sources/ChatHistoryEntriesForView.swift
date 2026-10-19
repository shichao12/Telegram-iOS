import Foundation
import UIKit
import Postbox
import TelegramCore
import TemporaryCachedPeerDataManager
import Emoji
import AccountContext
import TelegramPresentationData
import ChatHistoryEntry
import ChatMessageItemCommon
import TextFormat
import Markdown
import Display
import TelegramStringFormatting
import TelegramUIPreferences

struct ChatHistoryEntriesForViewState {
    private var messageStableIdToLocalId: [UInt32: Int64] = [:]
    private var blacklistCacheSettings: MessageKeywordBlacklistSettings?
    private var blacklistCachePeerId: PeerId?
    private var blacklistMatchCache: [UInt32: (stableVersion: UInt32, match: MessageBlacklistMatch?)] = [:]
    
    init() {
    }
    
    mutating func messageGroupStableId(messageStableId: UInt32, groupId: Int64, isLocal: Bool) -> Int64 {
        if isLocal {
            self.messageStableIdToLocalId[messageStableId] = groupId
            return groupId
        } else {
            if let value = self.messageStableIdToLocalId[messageStableId] {
                return value
            } else {
                return groupId
            }
        }
    }

    fileprivate mutating func cachedBlacklistMatch(message: Message, peerId: PeerId?, rules: PreparedMessageBlacklistRules, settings: MessageKeywordBlacklistSettings) -> MessageBlacklistMatch? {
        if self.blacklistCacheSettings != settings || self.blacklistCachePeerId != peerId {
            self.blacklistMatchCache.removeAll(keepingCapacity: true)
            self.blacklistCacheSettings = settings
            self.blacklistCachePeerId = peerId
        }
        if let cached = self.blacklistMatchCache[message.stableId], cached.stableVersion == message.stableVersion {
            return cached.match
        }
        if self.blacklistMatchCache.count > 4000 {
            self.blacklistMatchCache.removeAll(keepingCapacity: true)
        }
        let match: MessageBlacklistMatch?
        if let hit = settings.matchMessage(message, peerId: peerId) {
            switch hit {
            case let .globalKeyword(v): match = .globalKeyword(v)
            case let .channelKeyword(v): match = .channelKeyword(v)
            case let .globalLink(v): match = .globalLink(v)
            case let .channelLink(v): match = .channelLink(v)
            }
        } else {
            match = nil
        }
        self.blacklistMatchCache[message.stableId] = (message.stableVersion, match)
        return match
    }
}

private enum MessageBlacklistMatch {
    case globalKeyword(String)
    case channelKeyword(String)
    case globalLink(String)
    case channelLink(String)

    var bannerText: String {
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

private struct PreparedMessageBlacklistRules {
    struct Item {
        let needle: String
        let display: String
    }

    let globalKeywords: [Item]
    let channelKeywords: [Item]
    let globalLinks: [Item]
    let channelLinks: [Item]
    /// Lowercased needles used by bubble rendering.
    let markedLinks: [String]
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

        var marked: [String] = []
        marked.reserveCapacity(settings.globalMarkedLinks.count + 8)
        for raw in settings.globalMarkedLinks {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                marked.append(trimmed.lowercased())
            }
        }
        if let peerId {
            for raw in settings.markedLinks(peerId: peerId) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    marked.append(trimmed.lowercased())
                }
            }
        }
        self.markedLinks = marked
        self.hasKeywordRules = !self.globalKeywords.isEmpty || !self.channelKeywords.isEmpty
        self.hasLinkRules = !self.globalLinks.isEmpty || !self.channelLinks.isEmpty
        self.isEmpty = !self.hasKeywordRules && !self.hasLinkRules
    }

    func match(message: Message) -> MessageBlacklistMatch? {
        if self.isEmpty {
            return nil
        }
        if message.media.contains(where: { $0 is TelegramMediaAction }) {
            return nil
        }

        if self.hasKeywordRules {
            let text = message.text
            if !text.isEmpty {
                // Lowercase once; plain contains is much cheaper than diacritic-insensitive searches on every keyword.
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

func chatHistoryEntriesForView(
    currentState: ChatHistoryEntriesForViewState,
    context: AccountContext,
    location: ChatLocation,
    subject: ChatControllerSubject?,
    view: MessageHistoryView,
    includeUnreadEntry: Bool,
    includeEmptyEntry: Bool,
    includeChatInfoEntry: Bool,
    includeEmbeddedSavedChatInfo: Bool,
    reverse: Bool,
    groupMessages: Bool,
    reverseGroupedMessages: Bool,
    selectedMessages: Set<MessageId>?,
    presentationData: ChatPresentationData,
    historyAppearsCleared: Bool,
    skipViewOnceMedia: Bool,
    pendingUnpinnedAllMessages: Bool,
    pendingRemovedMessages: Set<MessageId>,
    associatedData: ChatMessageItemAssociatedData,
    updatingMedia: [MessageId: ChatUpdatingMessageMedia],
    customChannelDiscussionReadState: MessageId?,
    customThreadOutgoingReadState: MessageId?,
    cachedData: CachedPeerData?,
    adMessage: Message?,
    dynamicAdMessages: [Message],
    isMusicPlaylist: Bool,
    pinToTopStableId: EngineMessage.StableId?,
    messageKeywordBlacklistSettings: MessageKeywordBlacklistSettings,
    temporarilyRevealedBlacklistMessageIds: Set<MessageId>
) -> ([ChatHistoryEntry], ChatHistoryEntriesForViewState) {
    var currentState = currentState
    
    if historyAppearsCleared {
        return ([], currentState)
    }
    var entries: [ChatHistoryEntry] = []
    var adminRanks: [PeerId: CachedChannelAdminRank] = [:]
    var stickersEnabled = true
    var chatPeer: Peer?
    var cachedPeerDataPeers: [PeerId: Peer] = [:]
    if let peerId = location.peerId {
        for additionalEntry in view.additionalData {
            if case let .cacheEntry(id, data) = additionalEntry {
                if peerId.namespace == Namespaces.Peer.CloudChannel {
                    if id == cachedChannelAdminRanksEntryId(peerId: peerId), let data = data?.get(CachedChannelAdminRanks.self) {
                        adminRanks = data.ranks
                    }
                }
            } else if case let .peer(_, peer) = additionalEntry {
                chatPeer = peer
                if let channel = peer as? TelegramChannel, !channel.flags.contains(.isGigagroup) {
                    if let defaultBannedRights = channel.defaultBannedRights, defaultBannedRights.flags.contains(.banSendStickers) {
                        stickersEnabled = false
                    }
                }
            } else if case let .cachedPeerData(_, peerData) = additionalEntry {
                if let cachedGroupData = peerData as? CachedGroupData, let participants = cachedGroupData.participants {
                    for participant in participants.participants {
                        switch participant {
                        case let .member(_, _, _, rank):
                            adminRanks[participant.peerId] = .member(rank)
                        case let .creator(_, rank):
                            adminRanks[participant.peerId] = .creator(rank)
                        case let .admin(_, _, _, rank):
                            adminRanks[participant.peerId] = .admin(rank)
                        }
                    }
                }
            } else if case let .cachedPeerDataPeers(_, peers) = additionalEntry {
                cachedPeerDataPeers = peers
            }
        }
    }
    
    var joinMessage: Message?
    if (associatedData.subject?.isService ?? false) {
        
    } else {
        if let peer = chatPeer as? TelegramChannel, case .broadcast = peer.info, case .member = peer.participationStatus, !peer.flags.contains(.isCreator) {
            joinMessage = Message(
                stableId: UInt32.max - 1000,
                stableVersion: 0,
                id: MessageId(peerId: peer.id, namespace: Namespaces.Message.Local, id: 0),
                globallyUniqueId: nil,
                groupingKey: nil,
                groupInfo: nil,
                threadId: nil,
                timestamp: peer.creationDate,
                flags: [.Incoming],
                tags: [],
                globalTags: [],
                localTags: [],
                customTags: [],
                forwardInfo: nil,
                author: chatPeer,
                text: "",
                attributes: [],
                media: [TelegramMediaAction(action: .joinedChannel)],
                peers: SimpleDictionary<PeerId, Peer>(),
                associatedMessages: SimpleDictionary<MessageId, Message>(),
                associatedMessageIds: [],
                associatedMedia: [:],
                associatedThreadInfo: nil,
                associatedStories: [:]
            )
        }
    }
    
    var temporarilyRevealedGroupingKeys = Set<Int64>()
    for entry in view.entries {
        if temporarilyRevealedBlacklistMessageIds.contains(entry.message.id), let groupingKey = entry.message.groupingKey {
            temporarilyRevealedGroupingKeys.insert(groupingKey)
        }
    }

    let blacklistRules = PreparedMessageBlacklistRules(settings: messageKeywordBlacklistSettings, peerId: location.peerId)

    var hiddenGroupMatches: [Int64: (MessageId, MessageBlacklistMatch)] = [:]
    if !blacklistRules.isEmpty {
        for entry in view.entries {
            let message = entry.message
            guard let groupingKey = message.groupingKey, !temporarilyRevealedGroupingKeys.contains(groupingKey), hiddenGroupMatches[groupingKey] == nil else {
                continue
            }
            if !temporarilyRevealedBlacklistMessageIds.contains(message.id), let match = currentState.cachedBlacklistMatch(message: message, peerId: location.peerId, rules: blacklistRules, settings: messageKeywordBlacklistSettings) {
                hiddenGroupMatches[groupingKey] = (message.id, match)
            }
        }
    }

    var count = 0
    loop: for entry in view.entries {
        var message = entry.message.withAppliedEphemeralReplacementMessage()
        var isRead = entry.isRead
        var isBlacklistPlaceholder = false

        let blacklistMatch: MessageBlacklistMatch?
        if let groupingKey = message.groupingKey {
            if temporarilyRevealedGroupingKeys.contains(groupingKey) {
                blacklistMatch = nil
            } else if let groupMatch = hiddenGroupMatches[groupingKey] {
                if groupMatch.0 != message.id {
                    continue loop
                }
                blacklistMatch = groupMatch.1
            } else {
                blacklistMatch = nil
            }
        } else if !temporarilyRevealedBlacklistMessageIds.contains(message.id) {
            if blacklistRules.isEmpty {
                blacklistMatch = nil
            } else {
                blacklistMatch = currentState.cachedBlacklistMatch(message: message, peerId: location.peerId, rules: blacklistRules, settings: messageKeywordBlacklistSettings)
            }
        } else {
            blacklistMatch = nil
        }

        if let blacklistMatch {
            isBlacklistPlaceholder = true
            let bannerText = blacklistMatch.bannerText
            message = Message(
                stableId: message.stableId,
                stableVersion: message.stableVersion,
                id: message.id,
                globallyUniqueId: message.globallyUniqueId,
                groupingKey: nil,
                groupInfo: nil,
                threadId: message.threadId,
                timestamp: message.timestamp,
                flags: message.flags,
                tags: [],
                globalTags: [],
                localTags: [],
                customTags: [],
                forwardInfo: nil,
                author: nil,
                text: "",
                attributes: [],
                media: [TelegramMediaAction(action: .customText(text: bannerText, entities: [MessageTextEntity(range: 0 ..< (bannerText as NSString).length, type: .TextUrl(url: "tg-blacklist://reveal"))], additionalAttributes: nil))],
                peers: SimpleDictionary<PeerId, Peer>(),
                associatedMessages: SimpleDictionary<MessageId, Message>(),
                associatedMessageIds: [],
                associatedMedia: [:],
                associatedThreadInfo: nil,
                associatedStories: [:]
            )
        }
        
        var pinToTop = false
        if message.stableId == pinToTopStableId {
            pinToTop = true
        }
        
        if pendingRemovedMessages.contains(message.id) {
            continue
        }
        
        if case let .replyThread(replyThreadMessage) = location, replyThreadMessage.isForumPost {
            for media in message.media {
                if let action = media as? TelegramMediaAction {
                    if case .topicCreated = action.action {
                        continue loop
                    } else if case .groupCreated = action.action {
                        var chatPeer: Peer?
                        for entry in view.additionalData {
                            if case let .peer(_, peer) = entry {
                                chatPeer = peer
                            }
                        }
                        if let channel = chatPeer as? TelegramChannel, channel.isMonoForum {
                            continue loop
                        } else if let user = chatPeer as? TelegramUser, user.isForum {
                            continue loop
                        }
                    }
                }
            }
        } else if case .peer = location {
            for media in message.media {
                if let action = media as? TelegramMediaAction, case .groupCreated = action.action {
                    var chatPeer: Peer?
                    for entry in view.additionalData {
                        if case let .peer(_, peer) = entry {
                            chatPeer = peer
                        }
                    }
                    if let channel = chatPeer as? TelegramChannel, channel.isMonoForum {
                        continue loop
                    } else if let user = chatPeer as? TelegramChannel, user.isForum {
                        continue loop
                    }
                }
            }
        }
        
        count += 1
        
        if let customThreadOutgoingReadState = customThreadOutgoingReadState {
            isRead = customThreadOutgoingReadState >= message.id
        }
        
        if let customChannelDiscussionReadState = customChannelDiscussionReadState {
            attibuteLoop: for i in 0 ..< message.attributes.count {
                if let attribute = message.attributes[i] as? ReplyThreadMessageAttribute {
                    if let maxReadMessageId = attribute.maxReadMessageId {
                        if maxReadMessageId < customChannelDiscussionReadState.id {
                            var attributes = message.attributes
                            attributes[i] = ReplyThreadMessageAttribute(count: attribute.count, latestUsers: attribute.latestUsers, commentsPeerId: attribute.commentsPeerId, maxMessageId: attribute.maxMessageId, maxReadMessageId: customChannelDiscussionReadState.id)
                            message = message.withUpdatedAttributes(attributes)
                        }
                    }
                    break attibuteLoop
                }
            }
        }
        
        if skipViewOnceMedia, let minAutoremoveOrClearTimeout = message.minAutoremoveOrClearTimeout {
            if minAutoremoveOrClearTimeout <= 60 {
                continue loop
            }
        }
        
        var contentTypeHint: ChatMessageEntryContentType = isBlacklistPlaceholder ? .blacklistPlaceholder : .generic
        
        for media in message.media {
            if media is TelegramMediaDice {
                contentTypeHint = .animatedEmoji
            }
            if let action = media as? TelegramMediaAction {
                switch action.action {
                    case .channelMigratedFromGroup, .groupMigratedToChannel, .historyCleared:
                        continue loop
                    default:
                        break
                }
            }
        }
    
        var adminRank: CachedChannelAdminRank?
        if let author = message.author {
            adminRank = adminRanks[author.id]
        }
        
        if presentationData.largeEmoji, message.media.isEmpty {
            if messageIsEligibleForLargeCustomEmoji(EngineMessage(message)) {
                contentTypeHint = .animatedEmoji
            } else if stickersEnabled && message.text.count == 1, let _ = associatedData.animatedEmojiStickers[message.text.basicEmoji.0], (message.textEntitiesAttribute?.entities.isEmpty ?? true) {
                contentTypeHint = .animatedEmoji
            } else if messageIsEligibleForLargeEmoji(EngineMessage(message)) {
                contentTypeHint = .animatedEmoji
            }
        }

        let markedLinks: [String]
        if isBlacklistPlaceholder || blacklistRules.markedLinks.isEmpty {
            markedLinks = []
        } else {
            markedLinks = blacklistRules.markedLinks
        }
    
        if groupMessages || reverseGroupedMessages {
            if let messageGroupingKey = message.groupingKey {
                let selection: ChatHistoryMessageSelection
                if let selectedMessages = selectedMessages {
                    selection = .selectable(selected: selectedMessages.contains(message.id), num: nil)
                } else {
                    selection = .none
                }
                
                var isCentered = false
                if case let .messageOptions(_, _, info) = associatedData.subject, case let .link(link) = info {
                    isCentered = link.isCentered
                }
                
                let attributes = ChatMessageEntryAttributes(rank: adminRank, isContact: entry.attributes.authorIsContact, contentTypeHint: contentTypeHint, updatingMedia: isBlacklistPlaceholder ? nil : updatingMedia[message.id], isPlaying: message.index == associatedData.currentlyPlayingMessageId, isCentered: isCentered, authorStoryStats: message.author.flatMap { view.peerStoryStats[$0.id] }, displayContinueThreadFooter: false, pinToTop: pinToTop, markedLinks: markedLinks)
                
                let groupStableId = currentState.messageGroupStableId(messageStableId: message.stableId, groupId: messageGroupingKey, isLocal: Namespaces.Message.allLocal.contains(message.id.namespace))
                var found = false
                for i in 0 ..< entries.count {
                    if case let .MessageEntry(currentMessage, _, currentIsRead, currentLocation, currentSelection, currentAttributes) = entries[i], let currentGroupingKey = currentMessage.groupingKey, currentState.messageGroupStableId(messageStableId: currentMessage.stableId, groupId: currentGroupingKey, isLocal: Namespaces.Message.allLocal.contains(currentMessage.id.namespace)) == groupStableId {
                        found = true
                        
                        var currentMessages: [(Message, Bool, ChatHistoryMessageSelection, ChatMessageEntryAttributes, MessageHistoryEntryLocation?)] = []
                        
                        currentMessages.append((currentMessage, currentIsRead, currentSelection, currentAttributes, currentLocation))
                        if reverseGroupedMessages {
                            currentMessages.insert((message, isRead, selection, attributes, entry.location), at: 0)
                        } else {
                            currentMessages.append((message, isRead, selection, attributes, entry.location))
                        }
                        
                        entries[i] = .MessageGroupEntry(groupStableId, currentMessages, presentationData)
                    } else if case let .MessageGroupEntry(currentGroupStableId, currentMessages, _) = entries[i], currentGroupStableId == groupStableId {
                        found = true
                        
                        var currentMessages = currentMessages
                        if reverseGroupedMessages {
                            currentMessages.insert((message, isRead, selection, attributes, entry.location), at: 0)
                        } else {
                            currentMessages.append((message, isRead, selection, attributes, entry.location))
                        }
                        entries[i] = .MessageGroupEntry(currentGroupStableId, currentMessages, presentationData)
                    }
                }
                if !found {
                    entries.append(.MessageEntry(message, presentationData, isRead, entry.location, selection, attributes))
                }
            } else {
                let selection: ChatHistoryMessageSelection
                if let selectedMessages = selectedMessages {
                    selection = .selectable(selected: selectedMessages.contains(message.id), num: nil)
                } else {
                    selection = .none
                }
                
                var isCentered = false
                if case let .messageOptions(_, _, info) = associatedData.subject, case let .link(link) = info {
                    isCentered = link.isCentered
                }
                
                entries.append(.MessageEntry(message, presentationData, isRead, entry.location, selection, ChatMessageEntryAttributes(rank: adminRank, isContact: entry.attributes.authorIsContact, contentTypeHint: contentTypeHint, updatingMedia: isBlacklistPlaceholder ? nil : updatingMedia[message.id], isPlaying: message.index == associatedData.currentlyPlayingMessageId, isCentered: isCentered, authorStoryStats: message.author.flatMap { view.peerStoryStats[$0.id] }, displayContinueThreadFooter: false, pinToTop: pinToTop, markedLinks: markedLinks)))
            }
        } else {
            let selection: ChatHistoryMessageSelection
            if let selectedMessages = selectedMessages {
                selection = .selectable(selected: selectedMessages.contains(message.id), num: nil)
            } else {
                selection = .none
            }
            
            entries.append(.MessageEntry(message, presentationData, isRead, entry.location, selection, ChatMessageEntryAttributes(rank: adminRank, isContact: entry.attributes.authorIsContact, contentTypeHint: contentTypeHint, updatingMedia: isBlacklistPlaceholder ? nil : updatingMedia[message.id], isPlaying: message.index == associatedData.currentlyPlayingMessageId, isCentered: false, authorStoryStats: message.author.flatMap { view.peerStoryStats[$0.id] }, displayContinueThreadFooter: false, pinToTop: pinToTop, markedLinks: markedLinks)))
        }
    }
    
    if !groupMessages && reverseGroupedMessages {
        var flatEntries: [ChatHistoryEntry] = []
        
        for entry in entries {
            switch entry {
            case let .MessageGroupEntry(_, messages, presentationData):
                for (message, isRead, selection, attributes, location) in messages {
                    flatEntries.append(.MessageEntry(message, presentationData, isRead, location, selection, attributes))
                }
            default:
                flatEntries.append(entry)
            }
        }
        entries = flatEntries
    }
    
    var addBotForumHeader = false
    if location.threadId == nil, let user = chatPeer as? TelegramUser, let botInfo = user.botInfo, botInfo.flags.contains(.hasForum), botInfo.flags.contains(.forumManagedByUser), !entries.isEmpty, !view.holeEarlier, !view.isLoading {
        addBotForumHeader = true
        outer: for i in (0 ..< entries.count).reversed() {
            switch entries[i] {
            case let .MessageEntry(message, presentationData, isRead, location, selection, attributes):
                if message.threadId == nil {
                    continue outer
                }
                for media in message.media {
                    if let _ = media as? TelegramMediaAction {
                        continue outer
                    }
                }
                var attributes = attributes
                if let subject, case .pinnedMessages = subject {
                } else {
                    attributes.displayContinueThreadFooter = true
                }
                entries[i] = .MessageEntry(message, presentationData, isRead, location, selection, attributes)
                break outer
            default:
                break
            }
        }
    }
    
    let insertPendingProcessingMessage: ([Message], Int) -> Void = { messages, index in
        let serviceMessage = Message(
            stableId: UInt32.max - messages[0].stableId,
            stableVersion: 0,
            id: MessageId(peerId: messages[0].id.peerId, namespace: -1, id: messages[0].id.id),
            globallyUniqueId: nil,
            groupingKey: nil,
            groupInfo: nil,
            threadId: nil,
            timestamp: messages[0].timestamp,
            flags: [.Incoming],
            tags: [],
            globalTags: [],
            localTags: [],
            customTags: [],
            forwardInfo: nil,
            author: nil,
            text: "",
            attributes: [],
            media: [TelegramMediaAction(action: .customText(text: presentationData.strings.Chat_VideoProcessingServiceMessage(Int32(messages.count)), entities: [], additionalAttributes: nil))],
            peers: SimpleDictionary<PeerId, Peer>(),
            associatedMessages: SimpleDictionary<MessageId, Message>(),
            associatedMessageIds: [],
            associatedMedia: [:],
            associatedThreadInfo: nil,
            associatedStories: [:]
        )
        entries.insert(.MessageEntry(serviceMessage, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)), at: index)
    }
    
    for i in (0 ..< entries.count).reversed() {
        switch entries[i] {
        case let .MessageEntry(message, _, _, _, _, _):
            if message.id.namespace == Namespaces.Message.ScheduledCloud && message.pendingProcessingAttribute != nil {
                insertPendingProcessingMessage([message], i)
            }
        case let .MessageGroupEntry(_, messages, _):
            if !messages.isEmpty && messages[0].0.id.namespace == Namespaces.Message.ScheduledCloud {
                var videoCount = 0
                for message in messages {
                    if message.0.pendingProcessingAttribute != nil {
                        videoCount += 1
                    }
                }
                if videoCount != 0 {
                    insertPendingProcessingMessage(messages.map(\.0), i)
                }
            }
        default:
            break
        }
    }
    
    if let lowerTimestamp = view.entries.last?.message.timestamp, let upperTimestamp = view.entries.first?.message.timestamp {
        if let joinMessage {
            var insertAtPosition: Int?
            if joinMessage.timestamp >= lowerTimestamp && view.laterId == nil {
                insertAtPosition = entries.count
            } else if joinMessage.timestamp < lowerTimestamp && joinMessage.timestamp > upperTimestamp {
                for i in 0 ..< entries.count {
                    if let timestamp = entries[i].timestamp, timestamp > joinMessage.timestamp {
                        insertAtPosition = i
                        break
                    }
                }
            }
            if let insertAtPosition {
                entries.insert(.MessageEntry(joinMessage, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)), at: insertAtPosition)
            }
        }
    }
        
    if let maxReadIndex = view.maxReadIndex, includeUnreadEntry {
        var i = 0
        let unreadEntry: ChatHistoryEntry = .UnreadEntry(maxReadIndex, presentationData)
        for entry in entries {
            if case let .MessageGroupEntry(_, messages, _) = entry {
                if !messages.isEmpty && maxReadIndex >= messages[0].0.index {
                    i += 1
                    continue
                }
            }
            if entry > unreadEntry {
                if i != 0 {
                    entries.insert(unreadEntry, at: i)
                }
                break
            }
            i += 1
        }
    }
    
    var addedThreadHead = false
    if case let .replyThread(replyThreadMessage) = location, !replyThreadMessage.isForumPost, view.earlierId == nil, !view.holeEarlier, !view.isLoading, !isMusicPlaylist {
        loop: for entry in view.additionalData {
            switch entry {
            case let .message(id, messages) where id == replyThreadMessage.effectiveTopId:
                if !messages.isEmpty {
                    let selection: ChatHistoryMessageSelection = .none
                    
                    let topMessage = messages[0]
                    
                    var hasTopicCreated = false
                    inner: for media in topMessage.media {
                        if let action = media as? TelegramMediaAction {
                            switch action.action {
                                case .topicCreated:
                                    hasTopicCreated = true
                                    break inner
                                default:
                                    break
                            }
                        }
                    }
                    
                    var adminRank: CachedChannelAdminRank?
                    if let author = topMessage.author {
                        adminRank = adminRanks[author.id]
                    }
                    
                    var contentTypeHint: ChatMessageEntryContentType = .generic
                    if presentationData.largeEmoji, topMessage.media.isEmpty {
                        if messageIsEligibleForLargeCustomEmoji(EngineMessage(topMessage)) {
                            contentTypeHint = .animatedEmoji
                        } else if stickersEnabled && topMessage.text.count == 1, let _ = associatedData.animatedEmojiStickers[topMessage.text.basicEmoji.0] {
                            contentTypeHint = .animatedEmoji
                        } else if messageIsEligibleForLargeEmoji(EngineMessage(topMessage)) {
                            contentTypeHint = .animatedEmoji
                        }
                    }
                    
                    addedThreadHead = true
                    if messages.count > 1, let groupingKey = messages[0].groupingKey {
                        var groupMessages: [(Message, Bool, ChatHistoryMessageSelection, ChatMessageEntryAttributes, MessageHistoryEntryLocation?)] = []
                        for message in messages {
                            groupMessages.append((message, false, .none, ChatMessageEntryAttributes(rank: adminRank, isContact: false, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[message.id], isPlaying: false, isCentered: false, authorStoryStats: message.author.flatMap { view.peerStoryStats[$0.id] }, displayContinueThreadFooter: false, pinToTop: false), nil))
                        }
                        entries.insert(.MessageGroupEntry(groupingKey, groupMessages, presentationData), at: 0)
                    } else {
                        if !hasTopicCreated {
                            entries.insert(.MessageEntry(messages[0], presentationData, false, nil, selection, ChatMessageEntryAttributes(rank: adminRank, isContact: false, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[messages[0].id], isPlaying: false, isCentered: false, authorStoryStats: messages[0].author.flatMap { view.peerStoryStats[$0.id] }, displayContinueThreadFooter: false, pinToTop: false)), at: 0)
                        }
                    }
                    
                    if !replyThreadMessage.isForumPost {
                        let replyCount = view.entries.isEmpty ? 0 : 1
                        entries.insert(.ReplyCountEntry(messages[0].index, replyThreadMessage.isChannelPost, replyCount, presentationData), at: 1)
                    }
                }
                break loop
            default:
                break
            }
        }
    }
    
    if includeChatInfoEntry {
        if view.earlierId == nil, !view.isLoading {
            var chatPeer: Peer?
            var cachedPeerData: CachedPeerData?
            for entry in view.additionalData {
                if case let .cachedPeerData(_, data) = entry {
                    cachedPeerData = data
                } else if case let .peer(_, peer) = entry {
                    chatPeer = peer
                }
            }
            if case let .peer(peerId) = location, peerId.isReplies {
                entries.insert(.ChatInfoEntry(.botInfo(title: "", text: presentationData.strings.RepliesChat_DescriptionText, photo: nil, video: nil, peer: nil, managedByBot: nil), presentationData), at: 0)
            } else if case let .peer(peerId) = location, peerId.isVerificationCodes {
                entries.insert(.ChatInfoEntry(.botInfo(title: "", text: presentationData.strings.VerificationCodes_DescriptionText, photo: nil, video: nil, peer: nil, managedByBot: nil), presentationData), at: 0)
            } else if let cachedPeerData = cachedPeerData as? CachedUserData {
                if let botInfo = cachedPeerData.botInfo, !botInfo.description.isEmpty {
                    if location.threadId == nil {
                        if let subject, case .pinnedMessages = subject {
                        } else {
                            entries.insert(.ChatInfoEntry(.botInfo(title: presentationData.strings.Bot_DescriptionTitle, text: botInfo.description, photo: botInfo.photo, video: botInfo.video, peer: nil, managedByBot: nil), presentationData), at: 0)
                        }
                    }
                } else if let botManagerId = cachedPeerData.botManagerId, let managedByBot = cachedPeerDataPeers[botManagerId], let peer = chatPeer.flatMap(EnginePeer.init) {
                    entries.insert(.ChatInfoEntry(.botInfo(title: "", text: "", photo: nil, video: nil, peer: peer, managedByBot: EnginePeer(managedByBot)), presentationData), at: 0)
                } else if let peerStatusSettings = cachedPeerData.peerStatusSettings, peerStatusSettings.registrationDate != nil || peerStatusSettings.phoneCountry != nil {
                    if peerStatusSettings.flags.contains(.canAddContact) || peerStatusSettings.flags.contains(.canReport) || peerStatusSettings.flags.contains(.canBlock) {
                        
                        if let chatPeer, let photoChangeDate = peerStatusSettings.photoChangeDate, photoChangeDate > 0 {
                            let timeText = stringForIntervalSinceUpdateAction(strings: presentationData.strings, value: photoChangeDate)
                            let text = presentationData.strings.Chat_NonContactUser_UpdatedPhoto(timeText)
                            var entities: [MessageTextEntity] = []
                            for range in text.ranges {
                                entities.append(MessageTextEntity(range: range.range.lowerBound ..< range.range.upperBound, type: .Bold))
                            }
                            let message = Message(
                                stableId: UInt32.max - 1001,
                                stableVersion: 0,
                                id: MessageId(peerId: chatPeer.id, namespace: Namespaces.Message.Local, id: -1),
                                globallyUniqueId: nil,
                                groupingKey: nil,
                                groupInfo: nil,
                                threadId: nil,
                                timestamp: 2,
                                flags: [.Incoming],
                                tags: [],
                                globalTags: [],
                                localTags: [],
                                customTags: [],
                                forwardInfo: nil,
                                author: chatPeer,
                                text: "",
                                attributes: [],
                                media: [TelegramMediaAction(action: .customText(
                                    text: text.string,
                                    entities: entities,
                                    additionalAttributes: nil
                                ))],
                                peers: SimpleDictionary<PeerId, Peer>(),
                                associatedMessages: SimpleDictionary<MessageId, Message>(),
                                associatedMessageIds: [],
                                associatedMedia: [:],
                                associatedThreadInfo: nil,
                                associatedStories: [:]
                            )
                            entries.insert(.MessageEntry(message, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)), at: 0)
                        }
                        
                        if let chatPeer, let nameChangeDate = peerStatusSettings.nameChangeDate, nameChangeDate > 0 {
                            let timeText = stringForIntervalSinceUpdateAction(strings: presentationData.strings, value: nameChangeDate)
                            let text = presentationData.strings.Chat_NonContactUser_UpdatedName(timeText)
                            var entities: [MessageTextEntity] = []
                            for range in text.ranges {
                                entities.append(MessageTextEntity(range: range.range.lowerBound ..< range.range.upperBound, type: .Bold))
                            }
                            let message = Message(
                                stableId: UInt32.max - 1002,
                                stableVersion: 0,
                                id: MessageId(peerId: chatPeer.id, namespace: Namespaces.Message.Local, id: -2),
                                globallyUniqueId: nil,
                                groupingKey: nil,
                                groupInfo: nil,
                                threadId: nil,
                                timestamp: 1,
                                flags: [.Incoming],
                                tags: [],
                                globalTags: [],
                                localTags: [],
                                customTags: [],
                                forwardInfo: nil,
                                author: chatPeer,
                                text: "",
                                attributes: [],
                                media: [TelegramMediaAction(action: .customText(
                                    text: text.string,
                                    entities: entities,
                                    additionalAttributes: nil
                                ))],
                                peers: SimpleDictionary<PeerId, Peer>(),
                                associatedMessages: SimpleDictionary<MessageId, Message>(),
                                associatedMessageIds: [],
                                associatedMedia: [:],
                                associatedThreadInfo: nil,
                                associatedStories: [:]
                            )
                            entries.insert(.MessageEntry(message, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)), at: 0)
                        }

                        if let peer = chatPeer.flatMap(EnginePeer.init) {
                            entries.insert(.ChatInfoEntry(.userInfo(peer: peer, verification: cachedPeerData.verification, registrationDate: peerStatusSettings.registrationDate, phoneCountry: peerStatusSettings.phoneCountry, groupsInCommonCount: cachedPeerData.commonGroupCount), presentationData), at: 0)
                        }
                    }
                }
            } else {
                var isEmpty = true
                if entries.count <= 3 {
                    loop: for entry in view.entries {
                        var isEmptyMedia = false
                        var isPeerJoined = false
                        for media in entry.message.media {
                            if let action = media as? TelegramMediaAction {
                                switch action.action {
                                    case .groupCreated, .photoUpdated, .channelMigratedFromGroup, .groupMigratedToChannel:
                                        isEmptyMedia = true
                                    case .peerJoined:
                                        isPeerJoined = true
                                    default:
                                        break
                                }
                            }
                        }
                        var isCreator = false
                        if let peer = entry.message.peers[entry.message.id.peerId] as? TelegramGroup, case .creator = peer.role {
                            isCreator = true
                        } else if let peer = entry.message.peers[entry.message.id.peerId] as? TelegramChannel, case .group = peer.info, peer.flags.contains(.isCreator) {
                            isCreator = true
                        }
                        if isPeerJoined || (isEmptyMedia && isCreator) {
                        } else {
                            isEmpty = false
                            break loop
                        }
                    }
                } else {
                    isEmpty = false
                }
                if addedThreadHead {
                    isEmpty = false
                }
                if isEmpty {
                    entries.removeAll()
                }
            }
        }
        
        if !dynamicAdMessages.isEmpty {
            assert(entries.sorted() == entries)
            for message in dynamicAdMessages {
                entries.append(.MessageEntry(message, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)))
            }
            entries.sort()
        }

        if view.laterId == nil && !view.isLoading {
            if !entries.isEmpty, case let .MessageEntry(lastMessage, _, _, _, _, _) = entries[entries.count - 1], let message = adMessage {
                var nextAdMessageId: Int32 = 10000
                let updatedMessage = Message(
                    stableId: ChatHistoryListNodeImpl.fixedAdMessageStableId,
                    stableVersion: message.stableVersion,
                    id: MessageId(peerId: message.id.peerId, namespace: message.id.namespace, id: nextAdMessageId),
                    globallyUniqueId: nil,
                    groupingKey: nil,
                    groupInfo: nil,
                    threadId: nil,
                    timestamp: lastMessage.timestamp,
                    flags: message.flags,
                    tags: message.tags,
                    globalTags: message.globalTags,
                    localTags: message.localTags,
                    customTags: message.customTags,
                    forwardInfo: message.forwardInfo,
                    author: message.author,
                    text: /*"\(message.adAttribute!.opaqueId.hashValue)" + */message.text,
                    attributes: message.attributes,
                    media: message.media,
                    peers: message.peers,
                    associatedMessages: message.associatedMessages,
                    associatedMessageIds: message.associatedMessageIds,
                    associatedMedia: message.associatedMedia,
                    associatedThreadInfo: message.associatedThreadInfo,
                    associatedStories: message.associatedStories
                )
                nextAdMessageId += 1
                entries.append(.MessageEntry(updatedMessage, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)))
            }
        }
    }
    if addBotForumHeader {
        if let subject, case .pinnedMessages = subject {
        } else {
            entries.append(.ChatInfoEntry(.newThreadInfo, presentationData))
        }
    }
    if includeEmbeddedSavedChatInfo, let peerId = location.peerId {
        if !view.isLoading && view.laterId == nil {
            let string = presentationData.strings.Chat_SavedMessagesTabInfoText
            let formattedString = parseMarkdownIntoAttributedString(
                string,
                attributes: MarkdownAttributes(
                    body: MarkdownAttributeSet(font: Font.regular(15.0), textColor: .black),
                    bold: MarkdownAttributeSet(font: Font.regular(15.0), textColor: .black),
                    link: MarkdownAttributeSet(font: Font.regular(15.0), textColor: .white),
                    linkAttribute: { url in
                        return ("URL", url)
                    }
                )
            )
            var entities: [MessageTextEntity] = []
            formattedString.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: formattedString.length), options: [], using: { value, range, _ in
                if let value = value as? UIColor, value == .white {
                    entities.append(MessageTextEntity(range: range.lowerBound ..< range.upperBound, type: .Bold))
                }
            })
            formattedString.enumerateAttribute(NSAttributedString.Key(rawValue: "URL"), in: NSRange(location: 0, length: formattedString.length), options: [], using: { value, range, _ in
                if value != nil {
                    entities.append(MessageTextEntity(range: range.lowerBound ..< range.upperBound, type: .TextMention(peerId: context.account.peerId)))
                }
            })
            
            let message = Message(
                stableId: UInt32.max - 1001,
                stableVersion: 0,
                id: MessageId(peerId: peerId, namespace: Namespaces.Message.Local, id: 123),
                globallyUniqueId: nil,
                groupingKey: nil,
                groupInfo: nil,
                threadId: nil,
                timestamp: Int32.max - 1,
                flags: [.Incoming],
                tags: [],
                globalTags: [],
                localTags: [],
                customTags: [],
                forwardInfo: nil,
                author: nil,
                text: "",
                attributes: [],
                media: [TelegramMediaAction(action: .customText(text: formattedString.string, entities: entities, additionalAttributes: nil))],
                peers: SimpleDictionary<PeerId, Peer>(),
                associatedMessages: SimpleDictionary<MessageId, Message>(),
                associatedMessageIds: [],
                associatedMedia: [:],
                associatedThreadInfo: nil,
                associatedStories: [:]
            )
            entries.append(.MessageEntry(message, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)))
        }
    }
    
    if let subject = associatedData.subject, case let .customChatContents(customChatContents) = subject {
        var serviceHeaders: [String] = []
        switch customChatContents.kind {
        case let .quickReplyMessageInput(_, shortcutType):
            if case .generic = shortcutType {
                serviceHeaders = [
                    presentationData.strings.Chat_QuickReply_ServiceHeader1,
                    presentationData.strings.Chat_QuickReply_ServiceHeader2
                ]
            }
        case .welcomeMessages:
            serviceHeaders = [
                presentationData.strings.WelcomeMessages_ServiceHeader1,
                presentationData.strings.WelcomeMessages_ServiceHeader2
            ]
        case .businessLinkSetup, .hashTagSearch:
            break
        }

        if !serviceHeaders.isEmpty && !view.isLoading && view.laterId == nil && !view.entries.isEmpty {
            let peerId = view.entries[0].message.id.peerId
            for (i, string) in serviceHeaders.reversed().enumerated() {
                let formattedString = parseMarkdownIntoAttributedString(
                    string,
                    attributes: MarkdownAttributes(
                        body: MarkdownAttributeSet(font: Font.regular(15.0), textColor: .black),
                        bold: MarkdownAttributeSet(font: Font.regular(15.0), textColor: .black),
                        link: MarkdownAttributeSet(font: Font.regular(15.0), textColor: .white),
                        linkAttribute: { url in
                            return ("URL", url)
                        }
                    )
                )
                var entities: [MessageTextEntity] = []
                formattedString.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: formattedString.length), options: [], using: { value, range, _ in
                    if let value = value as? UIColor, value == .white {
                        entities.append(MessageTextEntity(range: range.lowerBound ..< range.upperBound, type: .Bold))
                    }
                })
                formattedString.enumerateAttribute(NSAttributedString.Key(rawValue: "URL"), in: NSRange(location: 0, length: formattedString.length), options: [], using: { value, range, _ in
                    if value != nil {
                        entities.append(MessageTextEntity(range: range.lowerBound ..< range.upperBound, type: .TextMention(peerId: context.account.peerId)))
                    }
                })
                
                let message = Message(
                    stableId: UInt32.max - 1001 - UInt32(i),
                    stableVersion: 0,
                    id: MessageId(peerId: peerId, namespace: Namespaces.Message.Local, id: Int32.max - 100 - Int32(i)),
                    globallyUniqueId: nil,
                    groupingKey: nil,
                    groupInfo: nil,
                    threadId: nil,
                    timestamp: -Int32(i),
                    flags: [.Incoming],
                    tags: [],
                    globalTags: [],
                    localTags: [],
                    customTags: [],
                    forwardInfo: nil,
                    author: nil,
                    text: "",
                    attributes: [],
                    media: [TelegramMediaAction(action: .customText(text: formattedString.string, entities: entities, additionalAttributes: nil))],
                    peers: SimpleDictionary<PeerId, Peer>(),
                    associatedMessages: SimpleDictionary<MessageId, Message>(),
                    associatedMessageIds: [],
                    associatedMedia: [:],
                    associatedThreadInfo: nil,
                    associatedStories: [:]
                )
                entries.insert(.MessageEntry(message, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil, displayContinueThreadFooter: false, pinToTop: false)), at: 0)
            }
        }
    }
    
    if isMusicPlaylist && entries.count == 1 {
        return ([], currentState)
    }
    
    if reverse {
        return (entries.reversed(), currentState)
    } else {
//        #if DEBUG
//        assert(entries.map(\.stableId) == entries.sorted().map(\.stableId))
//        #endif
        return (entries, currentState)
    }
}

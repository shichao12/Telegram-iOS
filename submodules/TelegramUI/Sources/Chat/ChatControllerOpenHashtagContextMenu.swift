import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AsyncDisplayKit
import Display
import ContextUI
import UndoUI
import AccountContext
import ChatMessageItemView
import ChatMessageItemCommon
import ChatControllerInteraction
import TelegramUIPreferences

private enum ChatHashtagBlacklistScope: Equatable {
    case global
    case channel
}

private func addChatHashtagBlacklistRule(context: AccountContext, peerId: EnginePeer.Id, hashtag: String, scope: ChatHashtagBlacklistScope) {
    let value = hashtag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
        return
    }
    let _ = context.engine.preferences.update(id: ApplicationSpecificPreferencesKeys.messageKeywordBlacklistSettings, { entry in
        var settings = entry?.get(MessageKeywordBlacklistSettings.self) ?? .defaultSettings
        var values = scope == .global ? settings.globalKeywords : settings.keywords(peerId: peerId)
        if !values.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            values.append(value)
            if scope == .global {
                settings.globalKeywords = values
            } else {
                settings = settings.withUpdatedKeywords(peerId: peerId, values)
            }
        }
        return EnginePreferencesEntry(settings)
    }).startStandalone()
}

extension ChatControllerImpl {
    func openHashtagContextMenu(hashtag: String, params: ChatControllerInteraction.LongTapParams) -> Void {
        guard let message = params.message, let contentNode = params.contentNode else {
            return
        }
        
        guard let messages = self.chatDisplayNode.historyNode.messageGroupInCurrentHistoryView(message.id) else {
            return
        }
            
        var updatedMessages = messages
        for i in 0 ..< updatedMessages.count {
            if updatedMessages[i].id == message.id {
                let message = updatedMessages.remove(at: i)
                updatedMessages.insert(message, at: 0)
                break
            }
        }
               
        let recognizer: TapLongTapOrDoubleTapGestureRecognizer? = params.gesture
        let gesture: ContextGesture? = nil
        
        let source: ContextContentSource = .extracted(ChatMessageLinkContextExtractedContentSource(chatNode: self.chatDisplayNode, contentNode: contentNode))
        
        var items: [ContextMenuItem] = []

        items.append(
            .action(ContextMenuActionItem(text: self.presentationData.strings.Chat_Context_Hashtag_Search, icon: { theme in return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Search"), color: theme.contextMenu.primaryColor) }, action: { [weak self] _, f in
                guard let self else {
                    return
                }
                f(.default)
                self.controllerInteraction?.openHashtag(nil, hashtag)
            }))
        )
        
        items.append(
            .action(ContextMenuActionItem(text: self.presentationData.strings.Chat_Context_Hashtag_Copy, icon: { theme in return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.contextMenu.primaryColor) }, action: { [weak self]  _, f in
                f(.default)

                guard let self else {
                    return
                }
                
                UIPasteboard.general.string = hashtag

                self.present(UndoOverlayController(presentationData: self.presentationData, content: .copy(text: presentationData.strings.Conversation_HashtagCopied), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
            }))
        )

        let scopeItems: [ContextMenuItem] = [
            .action(ContextMenuActionItem(text: "返回", icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.contextMenu.primaryColor)
            }, iconPosition: .left, action: { c, _ in
                c?.popItems()
            })),
            .separator,
            .action(ContextMenuActionItem(text: "全局", icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Restrict"), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] c, _ in
                guard let self else {
                    return
                }
                c?.dismiss(completion: {
                    addChatHashtagBlacklistRule(context: self.context, peerId: message.id.peerId, hashtag: hashtag, scope: .global)
                    self.present(UndoOverlayController(presentationData: self.presentationData, content: .succeed(text: "已加入全局关键词黑名单“\(hashtag)”", timeout: 3.0, customUndoText: nil), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                })
            })),
            .action(ContextMenuActionItem(text: "此频道", icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Restrict"), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] c, _ in
                guard let self else {
                    return
                }
                c?.dismiss(completion: {
                    addChatHashtagBlacklistRule(context: self.context, peerId: message.id.peerId, hashtag: hashtag, scope: .channel)
                    self.present(UndoOverlayController(presentationData: self.presentationData, content: .succeed(text: "已加入此频道关键词黑名单“\(hashtag)”", timeout: 3.0, customUndoText: nil), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                })
            }))
        ]
        items.append(.action(ContextMenuActionItem(text: "加入关键词黑名单", icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Restrict"), color: theme.contextMenu.primaryColor)
        }, action: { c, _ in
            c?.pushItems(items: .single(ContextController.Items(content: .list(scopeItems))))
        })))
         
        self.canReadHistory.set(false)
        
        let controller = makeContextController(presentationData: self.presentationData, source: source, items: .single(ContextController.Items(content: .list(items))), recognizer: recognizer, gesture: gesture, disableScreenshots: false)
        controller.dismissed = { [weak self] in
            self?.canReadHistory.set(true)
        }
        
        self.window?.presentInGlobalOverlay(controller)
    }
}

import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import AccountContext

fileprivate enum MessageBlacklistKind: Equatable {
    case keyword
    case hiddenLink
    case markedLink

    var valueName: String {
        switch self {
        case .keyword:
            return "关键词"
        case .hiddenLink:
            return "隐藏链接"
        case .markedLink:
            return "标记链接"
        }
    }
}

fileprivate enum MessageBlacklistScope: Equatable {
    case global
    case channel

    var title: String {
        switch self {
        case .global:
            return "全局"
        case .channel:
            return "此频道"
        }
    }
}

enum MessageBlacklistCategory {
    case globalKeyword
    case channelKeyword
    case globalLink
    case channelLink

    fileprivate var kind: MessageBlacklistKind {
        switch self {
        case .globalKeyword, .channelKeyword:
            return .keyword
        case .globalLink, .channelLink:
            return .hiddenLink
        }
    }

    fileprivate var scope: MessageBlacklistScope {
        switch self {
        case .globalKeyword, .globalLink:
            return .global
        case .channelKeyword, .channelLink:
            return .channel
        }
    }

    var isLink: Bool {
        switch self {
        case .globalLink, .channelLink:
            return true
        case .globalKeyword, .channelKeyword:
            return false
        }
    }
}

private func blacklistValues(settings: MessageKeywordBlacklistSettings, kind: MessageBlacklistKind, scope: MessageBlacklistScope, peerId: EnginePeer.Id) -> [String] {
    switch (kind, scope) {
    case (.keyword, .global):
        return settings.globalKeywords
    case (.keyword, .channel):
        return settings.keywords(peerId: peerId)
    case (.hiddenLink, .global):
        return settings.globalLinks
    case (.hiddenLink, .channel):
        return settings.links(peerId: peerId)
    case (.markedLink, .global):
        return settings.globalMarkedLinks
    case (.markedLink, .channel):
        return settings.markedLinks(peerId: peerId)
    }
}

private func withUpdatedBlacklistValues(settings: MessageKeywordBlacklistSettings, kind: MessageBlacklistKind, scope: MessageBlacklistScope, peerId: EnginePeer.Id, values: [String]) -> MessageKeywordBlacklistSettings {
    var updated = settings
    switch (kind, scope) {
    case (.keyword, .global):
        updated.globalKeywords = values
    case (.keyword, .channel):
        updated = updated.withUpdatedKeywords(peerId: peerId, values)
    case (.hiddenLink, .global):
        updated.globalLinks = values
    case (.hiddenLink, .channel):
        updated = updated.withUpdatedLinks(peerId: peerId, values)
    case (.markedLink, .global):
        updated.globalMarkedLinks = values
    case (.markedLink, .channel):
        updated = updated.withUpdatedMarkedLinks(peerId: peerId, values)
    }
    return updated
}

private func updateBlacklistValues(context: AccountContext, kind: MessageBlacklistKind, scope: MessageBlacklistScope, peerId: EnginePeer.Id, _ f: @escaping ([String]) -> [String], completion: @escaping () -> Void = {}) {
    let _ = (context.engine.preferences.update(id: ApplicationSpecificPreferencesKeys.messageKeywordBlacklistSettings, { entry in
        let current = entry?.get(MessageKeywordBlacklistSettings.self) ?? .defaultSettings
        let values = blacklistValues(settings: current, kind: kind, scope: scope, peerId: peerId)
        return EnginePreferencesEntry(withUpdatedBlacklistValues(settings: current, kind: kind, scope: scope, peerId: peerId, values: f(values)))
    })
    |> deliverOnMainQueue).startStandalone(completed: completion)
}

private final class MessageBlacklistCategoryArguments {
    let add: () -> Void
    let edit: (String) -> Void

    init(add: @escaping () -> Void, edit: @escaping (String) -> Void) {
        self.add = add
        self.edit = edit
    }
}

private enum MessageBlacklistCategoryEntry: ItemListNodeEntry {
    case add(String)
    case header(String)
    case empty(String)
    case value(Int32, String)

    var section: ItemListSectionId {
        switch self {
        case .add:
            return 0
        case .header, .empty, .value:
            return 1
        }
    }

    var stableId: Int32 {
        switch self {
        case .add:
            return 0
        case .header:
            return 1
        case .empty:
            return 2
        case let .value(index, _):
            return 1000 + index
        }
    }

    static func <(lhs: MessageBlacklistCategoryEntry, rhs: MessageBlacklistCategoryEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! MessageBlacklistCategoryArguments
        switch self {
        case let .add(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.add()
            })
        case let .header(title):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: title, sectionId: self.section)
        case let .empty(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .value(_, value):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: value,
                label: "编辑",
                labelStyle: .text,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments.edit(value)
                }
            )
        }
    }
}

private func messageBlacklistCategoryController(context: AccountContext, peerId: EnginePeer.Id, kind: MessageBlacklistKind, scope: MessageBlacklistScope, isRoot: Bool = true) -> ViewController {
    var controller: ItemListController?
    var openEditorImpl: ((String?) -> Void)?
    var dismissImpl: (() -> Void)?
    let arguments = MessageBlacklistCategoryArguments(add: {
        openEditorImpl?(nil)
    }, edit: { value in
        openEditorImpl?(value)
    })
    let settings = context.engine.data.subscribe(
        TelegramEngine.EngineData.Item.Configuration.ApplicationSpecificPreference(key: ApplicationSpecificPreferencesKeys.messageKeywordBlacklistSettings)
    )
    |> map { entry -> MessageKeywordBlacklistSettings in
        return entry?.get(MessageKeywordBlacklistSettings.self) ?? .defaultSettings
    }
    |> distinctUntilChanged

    let signal = combineLatest(context.sharedContext.presentationData, settings)
    |> deliverOnMainQueue
    |> map { presentationData, settings -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var presentationData = presentationData
        presentationData = presentationData.withUpdated(theme: presentationData.theme.withModalBlocksBackground())
        let values = blacklistValues(settings: settings, kind: kind, scope: scope, peerId: peerId)
        var entries: [MessageBlacklistCategoryEntry] = [
            .add("添加\(kind.valueName)"),
            .header("已添加的\(kind.valueName)")
        ]
        if values.isEmpty {
            entries.append(.empty("暂无\(kind.valueName)"))
        } else {
            entries.append(contentsOf: values.enumerated().map { index, value in
                return .value(Int32(index), value)
            })
        }
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("\(scope.title)\(kind.valueName)"),
            leftNavigationButton: isRoot ? ItemListNavigationButton(content: .icon(.close), style: .regular, enabled: true, action: {
                dismissImpl?()
            }) : nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let initialPresentationData = context.sharedContext.currentPresentationData.with { $0 }
    controller = ItemListController(
        presentationData: ItemListPresentationData(initialPresentationData),
        updatedPresentationData: context.sharedContext.presentationData |> map(ItemListPresentationData.init(_:)),
        state: signal,
        tabBarItem: nil
    )
    controller?.navigationPresentation = .modal
    openEditorImpl = { [weak controller] value in
        let editor = messageBlacklistValueEditorController(context: context, peerId: peerId, kind: kind, scope: scope, originalValue: value)
        (controller?.navigationController as? NavigationController)?.pushViewController(editor)
    }
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    return controller!
}

private final class MessageBlacklistLinkModeArguments {
    let open: (MessageBlacklistKind) -> Void

    init(open: @escaping (MessageBlacklistKind) -> Void) {
        self.open = open
    }
}

private enum MessageBlacklistLinkModeEntry: ItemListNodeEntry {
    case mode(Int32, String, String, MessageBlacklistKind)
    case info(String)

    var section: ItemListSectionId {
        switch self {
        case .mode:
            return 0
        case .info:
            return 1
        }
    }

    var stableId: Int32 {
        switch self {
        case let .mode(id, _, _, _):
            return id
        case .info:
            return 2
        }
    }

    static func <(lhs: MessageBlacklistLinkModeEntry, rhs: MessageBlacklistLinkModeEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! MessageBlacklistLinkModeArguments
        switch self {
        case let .mode(_, title, label, kind):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                label: label,
                labelStyle: .text,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments.open(kind)
                }
            )
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func messageBlacklistLinkModeController(context: AccountContext, peerId: EnginePeer.Id, scope: MessageBlacklistScope) -> ViewController {
    var controller: ItemListController?
    var openImpl: ((MessageBlacklistKind) -> Void)?
    var dismissImpl: (() -> Void)?
    let arguments = MessageBlacklistLinkModeArguments(open: { kind in
        openImpl?(kind)
    })
    let settings = context.engine.data.subscribe(
        TelegramEngine.EngineData.Item.Configuration.ApplicationSpecificPreference(key: ApplicationSpecificPreferencesKeys.messageKeywordBlacklistSettings)
    )
    |> map { entry -> MessageKeywordBlacklistSettings in
        return entry?.get(MessageKeywordBlacklistSettings.self) ?? .defaultSettings
    }
    |> distinctUntilChanged

    let signal = combineLatest(context.sharedContext.presentationData, settings)
    |> deliverOnMainQueue
    |> map { presentationData, settings -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var presentationData = presentationData
        presentationData = presentationData.withUpdated(theme: presentationData.theme.withModalBlocksBackground())
        let hiddenCount = blacklistValues(settings: settings, kind: .hiddenLink, scope: scope, peerId: peerId).count
        let markedCount = blacklistValues(settings: settings, kind: .markedLink, scope: scope, peerId: peerId).count
        let entries: [MessageBlacklistLinkModeEntry] = [
            .mode(0, "隐藏整条消息", hiddenCount == 0 ? "未设置" : "\(hiddenCount) 条", .hiddenLink),
            .mode(1, "只标记链接", markedCount == 0 ? "未设置" : "\(markedCount) 条", .markedLink),
            .info("隐藏规则会用提示横幅替代整条消息；标记规则只改变命中链接的颜色。")
        ]
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("\(scope.title)链接"),
            leftNavigationButton: ItemListNavigationButton(content: .icon(.close), style: .regular, enabled: true, action: {
                dismissImpl?()
            }),
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let initialPresentationData = context.sharedContext.currentPresentationData.with { $0 }
    controller = ItemListController(
        presentationData: ItemListPresentationData(initialPresentationData),
        updatedPresentationData: context.sharedContext.presentationData |> map(ItemListPresentationData.init(_:)),
        state: signal,
        tabBarItem: nil
    )
    controller?.navigationPresentation = .modal
    openImpl = { [weak controller] kind in
        let categoryController = messageBlacklistCategoryController(context: context, peerId: peerId, kind: kind, scope: scope, isRoot: false)
        (controller?.navigationController as? NavigationController)?.pushViewController(categoryController)
    }
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    return controller!
}


private func messageBlacklistKindForQuickAdd(category: MessageBlacklistCategory) -> (MessageBlacklistKind, MessageBlacklistScope) {
    if category.isLink {
        return (.hiddenLink, category.scope)
    } else {
        return (.keyword, category.scope)
    }
}

func clipboardBlacklistCandidate() -> String? {
    let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if value.isEmpty {
        return nil
    }
    return value
}

func quickAddMessageBlacklistValue(context: AccountContext, peerId: EnginePeer.Id, category: MessageBlacklistCategory, value: String, completion: @escaping (Bool, String) -> Void) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        completion(false, value)
        return
    }
    let (kind, scope) = messageBlacklistKindForQuickAdd(category: category)
    var added = false
    updateBlacklistValues(context: context, kind: kind, scope: scope, peerId: peerId, { values in
        if values.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return values
        }
        added = true
        var updated = values
        updated.insert(trimmed, at: 0)
        return updated
    }, completion: {
        completion(added, trimmed)
    })
}

func messageBlacklistSettingsController(context: AccountContext, peerId: EnginePeer.Id, category: MessageBlacklistCategory) -> ViewController {
    if category.isLink {
        return messageBlacklistLinkModeController(context: context, peerId: peerId, scope: category.scope)
    } else {
        return messageBlacklistCategoryController(context: context, peerId: peerId, kind: category.kind, scope: category.scope)
    }
}

private final class MessageBlacklistEditorArguments {
    let updateValue: (String) -> Void
    let delete: () -> Void

    init(updateValue: @escaping (String) -> Void, delete: @escaping () -> Void) {
        self.updateValue = updateValue
        self.delete = delete
    }
}

private enum MessageBlacklistEditorTag: ItemListItemTag {
    case value

    func isEqual(to other: ItemListItemTag) -> Bool {
        return other is MessageBlacklistEditorTag
    }
}

private struct MessageBlacklistEditorState: Equatable {
    var value: String
}

private enum MessageBlacklistEditorEntry: ItemListNodeEntry {
    case input(String, String)
    case info(String)
    case delete(String)

    var section: ItemListSectionId {
        switch self {
        case .input, .info:
            return 0
        case .delete:
            return 1
        }
    }

    var stableId: Int32 {
        switch self {
        case .input:
            return 0
        case .info:
            return 1
        case .delete:
            return 2
        }
    }

    static func <(lhs: MessageBlacklistEditorEntry, rhs: MessageBlacklistEditorEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! MessageBlacklistEditorArguments
        switch self {
        case let .input(value, placeholder):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(),
                text: value,
                placeholder: placeholder,
                type: .regular(capitalization: false, autocorrection: false),
                returnKeyType: .done,
                clearType: .onFocus,
                tag: MessageBlacklistEditorTag.value,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateValue(value)
                },
                action: {}
            )
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .delete(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.delete()
            })
        }
    }
}

private func messageBlacklistValueEditorController(context: AccountContext, peerId: EnginePeer.Id, kind: MessageBlacklistKind, scope: MessageBlacklistScope, originalValue: String?) -> ViewController {
    let initialState = MessageBlacklistEditorState(value: originalValue ?? "")
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let updateState: ((MessageBlacklistEditorState) -> MessageBlacklistEditorState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }
    var controller: ItemListController?
    var saveImpl: (() -> Void)?
    var deleteImpl: (() -> Void)?
    let arguments = MessageBlacklistEditorArguments(updateValue: { value in
        updateState { state in
            var state = state
            state.value = value
            return state
        }
    }, delete: {
        deleteImpl?()
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var presentationData = presentationData
        presentationData = presentationData.withUpdated(theme: presentationData.theme.withModalBlocksBackground())
        let trimmedValue = state.value.trimmingCharacters(in: .whitespacesAndNewlines)
        var entries: [MessageBlacklistEditorEntry] = [
            .input(state.value, kind.valueName),
            .info(kind == .keyword ? "消息正文包含该关键词时会被隐藏。" : (kind == .hiddenLink ? "消息正文或网页预览包含该链接时会被隐藏。" : "匹配到的链接会显示为橙红色，消息不会被隐藏。"))
        ]
        if originalValue != nil {
            entries.append(.delete("删除此\(kind.valueName)"))
        }
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("\(originalValue == nil ? "添加" : "编辑")\(kind.valueName)"),
            leftNavigationButton: nil,
            rightNavigationButton: ItemListNavigationButton(content: .icon(.done), style: .bold, enabled: !trimmedValue.isEmpty, action: {
                saveImpl?()
            }),
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            focusItemTag: originalValue == nil ? MessageBlacklistEditorTag.value : nil,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }

    let initialPresentationData = context.sharedContext.currentPresentationData.with { $0 }
    controller = ItemListController(
        presentationData: ItemListPresentationData(initialPresentationData),
        updatedPresentationData: context.sharedContext.presentationData |> map(ItemListPresentationData.init(_:)),
        state: signal,
        tabBarItem: nil
    )
    controller?.navigationPresentation = .modal
    saveImpl = { [weak controller] in
        let value = stateValue.with { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !value.isEmpty else {
            return
        }
        updateBlacklistValues(context: context, kind: kind, scope: scope, peerId: peerId, { values in
            var values = values
            if let originalValue {
                values.removeAll(where: { $0 == originalValue })
            }
            if !values.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                values.append(value)
            }
            return values
        }, completion: {
            let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
        })
    }
    deleteImpl = { [weak controller] in
        guard let originalValue else {
            return
        }
        updateBlacklistValues(context: context, kind: kind, scope: scope, peerId: peerId, { values in
            var values = values
            values.removeAll(where: { $0 == originalValue })
            return values
        }, completion: {
            let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
        })
    }
    return controller!
}

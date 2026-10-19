import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import ContextUI
import TelegramPresentationData
import AppBundle

final class BlacklistMenuRowItem: ContextMenuCustomItem {
    let title: String
    let iconName: String
    let category: MessageBlacklistCategory
    let open: (MessageBlacklistCategory) -> Void
    let paste: (MessageBlacklistCategory) -> Void

    init(title: String, iconName: String, category: MessageBlacklistCategory, open: @escaping (MessageBlacklistCategory) -> Void, paste: @escaping (MessageBlacklistCategory) -> Void) {
        self.title = title
        self.iconName = iconName
        self.category = category
        self.open = open
        self.paste = paste
    }

    func node(presentationData: PresentationData, getController: @escaping () -> ContextControllerProtocol?, actionSelected: @escaping (ContextMenuActionResult) -> Void) -> ContextMenuCustomNode {
        return BlacklistMenuRowItemNode(presentationData: presentationData, item: self, getController: getController, actionSelected: actionSelected)
    }
}

private final class BlacklistMenuRowItemNode: ASDisplayNode, ContextMenuCustomNode {
    private let item: BlacklistMenuRowItem
    private var presentationData: PresentationData
    private let getController: () -> ContextControllerProtocol?
    private let actionSelected: (ContextMenuActionResult) -> Void

    private let titleNode: ImmediateTextNode
    private let iconNode: ASImageNode
    private let buttonNode: HighlightTrackingButtonNode
    private let highlightedBackgroundNode: ASDisplayNode

    private var titleSize: CGSize = CGSize()
    private var performedAction = false
    private var suppressTap = false
    private var longPressTimer: SwiftSignalKit.Timer?
    private let hapticFeedback = HapticFeedback()

    // Parent highlight gesture steals touches; handle tap/long-press ourselves.
    func canBeHighlighted() -> Bool {
        return false
    }

    init(presentationData: PresentationData, item: BlacklistMenuRowItem, getController: @escaping () -> ContextControllerProtocol?, actionSelected: @escaping (ContextMenuActionResult) -> Void) {
        self.item = item
        self.presentationData = presentationData
        self.getController = getController
        self.actionSelected = actionSelected

        self.highlightedBackgroundNode = ASDisplayNode()
        self.highlightedBackgroundNode.isUserInteractionEnabled = false
        self.highlightedBackgroundNode.alpha = 0.0

        self.titleNode = ImmediateTextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.displaysAsynchronously = false
        self.titleNode.maximumNumberOfLines = 1

        self.iconNode = ASImageNode()
        self.iconNode.displaysAsynchronously = false
        self.iconNode.displayWithoutProcessing = true
        self.iconNode.isUserInteractionEnabled = false

        self.buttonNode = HighlightTrackingButtonNode()

        super.init()

        self.isUserInteractionEnabled = true
        self.addSubnode(self.highlightedBackgroundNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.iconNode)
        self.addSubnode(self.buttonNode)

        self.applyTheme(presentationData)

        self.buttonNode.highligthedChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            if highlighted {
                self.highlightedBackgroundNode.layer.removeAllAnimations()
                self.highlightedBackgroundNode.alpha = 1.0
                self.startLongPressTimer()
            } else {
                self.invalidateLongPressTimer()
                self.highlightedBackgroundNode.alpha = 0.0
                self.highlightedBackgroundNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2)
            }
        }
        self.buttonNode.addTarget(self, action: #selector(self.buttonPressed), forControlEvents: .touchUpInside)
    }

    deinit {
        self.invalidateLongPressTimer()
    }

    override func didLoad() {
        super.didLoad()
        self.view.isExclusiveTouch = true
        self.buttonNode.view.isExclusiveTouch = true
        self.buttonNode.isAccessibilityElement = true
        self.buttonNode.accessibilityLabel = self.item.title
        self.buttonNode.accessibilityHint = "长按可粘贴添加"
    }

    private func startLongPressTimer() {
        self.invalidateLongPressTimer()
        self.longPressTimer = SwiftSignalKit.Timer(timeout: 0.45, repeat: false, completion: { [weak self] in
            guard let self else {
                return
            }
            self.invalidateLongPressTimer()
            self.handleLongPressPaste()
        }, queue: Queue.mainQueue())
        self.longPressTimer?.start()
    }

    private func invalidateLongPressTimer() {
        self.longPressTimer?.invalidate()
        self.longPressTimer = nil
    }

    private func handleLongPressPaste() {
        guard !self.performedAction else {
            return
        }
        // Cancel in-flight touch so finger release does not also open settings.
        self.suppressTap = true
        self.buttonNode.touchesCancelled(nil, with: nil)
        self.highlightedBackgroundNode.alpha = 0.0
        self.hapticFeedback.impact()
        self.performPaste()
    }

    @objc private func buttonPressed() {
        if self.suppressTap {
            self.suppressTap = false
            return
        }
        self.invalidateLongPressTimer()
        self.performOpen()
    }

    private func performOpen() {
        guard !self.performedAction else {
            return
        }
        self.performedAction = true
        self.invalidateLongPressTimer()
        let open = self.item.open
        let category = self.item.category
        self.actionSelected(.default)
        Queue.mainQueue().after(0.15, {
            open(category)
        })
    }

    private func performPaste() {
        guard !self.performedAction else {
            return
        }
        self.performedAction = true
        self.invalidateLongPressTimer()
        let paste = self.item.paste
        let category = self.item.category
        self.actionSelected(.default)
        Queue.mainQueue().after(0.05, {
            paste(category)
        })
    }

    func updateLayout(constrainedWidth: CGFloat, constrainedHeight: CGFloat) -> (CGSize, (CGSize, ContainedViewLayoutTransition) -> Void) {
        let sideInset: CGFloat = 16.0
        let iconSideInset: CGFloat = 12.0
        let verticalInset: CGFloat = 12.0
        let standardIconWidth: CGFloat = 32.0

        let iconSize = self.iconNode.image?.size ?? CGSize(width: 24.0, height: 24.0)
        let rightIconInset: CGFloat = max(iconSize.width, standardIconWidth) + iconSideInset
        let titleMaxWidth = max(1.0, constrainedWidth - sideInset - rightIconInset)
        self.titleSize = self.titleNode.updateLayout(CGSize(width: titleMaxWidth, height: .greatestFiniteMagnitude))

        let height = max(44.0, verticalInset * 2.0 + max(self.titleSize.height, iconSize.height))
        let width = sideInset + self.titleSize.width + rightIconInset

        return (CGSize(width: width, height: height), { [weak self] size, transition in
            guard let self else {
                return
            }

            let iconSize = self.iconNode.image?.size ?? CGSize(width: 24.0, height: 24.0)
            let iconSlotWidth = max(iconSize.width, standardIconWidth)
            let iconLeft = size.width - iconSideInset - iconSlotWidth + floor((iconSlotWidth - iconSize.width) / 2.0)

            transition.updateFrame(node: self.highlightedBackgroundNode, frame: CGRect(origin: CGPoint(), size: size))
            transition.updateFrame(node: self.buttonNode, frame: CGRect(origin: CGPoint(), size: size))
            transition.updateFrameAdditive(node: self.titleNode, frame: CGRect(origin: CGPoint(x: sideInset, y: floor((size.height - self.titleSize.height) / 2.0)), size: self.titleSize))
            transition.updateFrameAdditive(node: self.iconNode, frame: CGRect(origin: CGPoint(x: iconLeft, y: floor((size.height - iconSize.height) / 2.0)), size: iconSize))
        })
    }

    private func applyTheme(_ presentationData: PresentationData) {
        let textFont = Font.regular(presentationData.listsFontSize.baseDisplaySize)
        self.titleNode.attributedText = NSAttributedString(string: self.item.title, font: textFont, textColor: presentationData.theme.contextMenu.primaryColor)
        self.iconNode.image = generateTintedImage(image: UIImage(bundleImageName: self.item.iconName), color: presentationData.theme.contextMenu.primaryColor)
        self.highlightedBackgroundNode.backgroundColor = presentationData.theme.contextMenu.itemHighlightedBackgroundColor
    }

    func updateTheme(presentationData: PresentationData) {
        self.presentationData = presentationData
        self.applyTheme(presentationData)
    }

    func updateIsHighlighted(isHighlighted: Bool) {
    }

    func performAction() {
        // Disabled parent highlight path.
    }
}

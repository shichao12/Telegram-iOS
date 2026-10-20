import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import Display
import TinyThumbnail

public enum VideoRewatch {
    private static var stores: [Int64: VideoRewatchStore] = [:]

    public static func store(context: AccountContext) -> VideoRewatchStore {
        let id = context.account.id.int64
        if let store = self.stores[id] { return store }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = VideoRewatchStore(url: directory.appendingPathComponent("VideoRewatch/\(id).json"))
        self.stores[id] = store
        return store
    }

    static func record(message: Message, file: TelegramMediaFile, subject: GalleryMediaSubject?, position: Double = 0.0, duration: Double = 0.0) -> VideoRewatchRecord {
        var kind: String?
        var index: Int64?
        var data: Data?
        switch subject {
        case let .paidMediaIndex(value): kind = "paid"; index = Int64(value)
        case .pollDescription: kind = "pollDescription"
        case let .pollOption(value): kind = "pollOption"; data = value
        case .pollSolution: kind = "pollSolution"
        case .instantPageMedia: kind = "instantPage"
        case .richTextMedia: kind = "richText"
        case nil: break
        }
        let title = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return VideoRewatchRecord(peerId: message.id.peerId.toInt64(), namespace: message.id.namespace, messageId: message.id.id, mediaNamespace: file.fileId.namespace, mediaId: file.fileId.id, subjectKind: kind, subjectIndex: index, subjectData: data, title: String((title.isEmpty ? (file.fileName ?? "视频") : title).prefix(160)), source: message.peers[message.id.peerId]?.debugDisplayTitle ?? "视频", thumbnail: file.immediateThumbnailData.flatMap { decodeTinyThumbnail(data: $0) }, position: position, duration: duration, completed: false, lastViewed: Date().timeIntervalSince1970)
    }

    public static func present(context: AccountContext, from presenter: ViewController, baseNavigationController: NavigationController?, onReturn: @escaping () -> Void = {}, onPictureInPicture: @escaping () -> Void = {}) {
        let list = VideoRewatchListController(context: context)
        let navigation = UINavigationController(rootViewController: list)
        navigation.overrideUserInterfaceStyle = context.sharedContext.currentPresentationData.with { $0.theme.overallDarkAppearance } ? .dark : .light
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 20.0
        }
        list.cancel = onReturn
        list.open = { [weak presenter] message, record in
            guard let presenter else { onReturn(); return }
            let gallery = GalleryController(context: context, source: .standaloneMessage(message, record.gallerySubject), streamSingleVideo: true, timecode: record.resumePosition, replaceRootController: { [weak presenter] controller, _ in
                presenter?.present(controller, in: .window(.root))
            }, baseNavigationController: baseNavigationController)
            gallery.rewatchReturnAction = onReturn
            gallery.rewatchPictureInPictureAction = onPictureInPicture
            gallery.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "返回刚才浏览", style: .plain, target: gallery, action: #selector(GalleryController.returnFromRewatch))
            presenter.present(gallery, in: .window(.root), with: GalleryControllerPresentationArguments(animated: true, transitionArguments: { _, _ in nil }))
        }
        presenter.present(navigation, animated: true, completion: nil)
        navigation.presentationController?.delegate = list
    }
}

extension VideoRewatchRecord {
    var gallerySubject: GalleryMediaSubject? {
        switch self.subjectKind {
        case "paid": return .paidMediaIndex(Int(self.subjectIndex ?? 0))
        case "pollDescription": return .pollDescription
        case "pollOption": return .pollOption(self.subjectData ?? Data())
        case "pollSolution": return .pollSolution
        case "instantPage": return .instantPageMedia(MediaId(namespace: self.mediaNamespace, id: self.mediaId))
        case "richText": return .richTextMedia(MediaId(namespace: self.mediaNamespace, id: self.mediaId))
        default: return nil
        }
    }
}

// Icon-only entrance above the chat input panel.
public final class VideoRewatchButton: UIButton {
    public var open: (() -> Void)?
    private var observer: NSObjectProtocol?
    private let store: VideoRewatchStore

    public init(context: AccountContext) {
        self.store = VideoRewatch.store(context: context)
        super.init(frame: .zero)
        self.setImage(UIImage(systemName: "star.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 21.0, weight: .medium)), for: .normal)
        self.tintColor = .white
        self.backgroundColor = UIColor(white: 0.12, alpha: 0.85)
        self.layer.cornerRadius = 22.0
        self.accessibilityLabel = "收藏回看"
        self.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
        self.observer = NotificationCenter.default.addObserver(forName: VideoRewatchStore.changed, object: self.store, queue: .main) { [weak self] _ in self?.refresh() }
        self.refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer = self.observer { NotificationCenter.default.removeObserver(observer) } }
    private func refresh() {
        self.isHidden = self.store.records.isEmpty
        self.accessibilityValue = "\(self.store.records.count) 个视频"
    }
    @objc private func pressed() { self.open?() }
}

private final class VideoRewatchListController: UITableViewController, UIAdaptivePresentationControllerDelegate {
    private let context: AccountContext
    private let store: VideoRewatchStore
    private var records: [VideoRewatchRecord] = []
    private let loadDisposable = MetaDisposable()
    private var loadingKey: String?
    private var finished = false
    var cancel: (() -> Void)?
    var open: ((Message, VideoRewatchRecord) -> Void)?

    init(context: AccountContext) {
        self.context = context
        self.store = VideoRewatch.store(context: context)
        super.init(style: .plain)
        self.title = "收藏回看"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.loadDisposable.dispose() }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.tableView.rowHeight = UITableView.automaticDimension
        self.tableView.estimatedRowHeight = 96.0
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(self.closePressed))
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "编辑", style: .plain, target: self, action: #selector(self.editPressed))
        self.refresh()
    }

    private func refresh() {
        self.records = self.store.sortedRecords
        self.tableView.reloadData()
        self.navigationItem.rightBarButtonItem?.isEnabled = !self.records.isEmpty
        if self.records.isEmpty {
            let label = UILabel()
            label.text = "还没有收藏的视频\n播放视频时点 ☆，就能在这里继续观看"
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            label.font = .preferredFont(forTextStyle: .body)
            self.tableView.backgroundView = label
        } else { self.tableView.backgroundView = nil }
    }

    @objc private func editPressed() {
        self.setEditing(!self.isEditing, animated: true)
        self.navigationItem.rightBarButtonItem?.title = self.isEditing ? "完成" : "编辑"
    }

    @objc private func closePressed() {
        self.loadDisposable.set(nil)
        self.dismiss(animated: true) { self.finish() }
    }
    private func finish() {
        guard !self.finished else { return }
        self.finished = true
        self.cancel?()
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { self.finish() }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return self.records.count }

    private func time(_ value: Double) -> String {
        let seconds = Int(max(0.0, value))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let record = self.records[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = record.title
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        let progress = record.completed ? "已看完 · 点击重看" : "看到 \(self.time(record.position)) · 共 \(self.time(record.duration))"
        cell.detailTextLabel?.text = record.source + "\n" + progress
        cell.detailTextLabel?.numberOfLines = 2
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
        if let data = record.thumbnail, let image = UIImage(data: data) {
            // Give thumbnail images a consistent canvas rather than their tiny source dimensions.
            cell.imageView?.image = UIGraphicsImageRenderer(size: CGSize(width: 72, height: 54)).image { _ in
                UIColor.secondarySystemBackground.setFill()
                UIRectFill(CGRect(x: 0, y: 0, width: 72, height: 54))
                let scale = max(72 / image.size.width, 54 / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: (72 - size.width) / 2, y: (54 - size.height) / 2, width: size.width, height: size.height))
            }
        } else { cell.imageView?.image = UIImage(systemName: "play.rectangle.fill") }
        cell.imageView?.layer.cornerRadius = 6.0
        cell.imageView?.clipsToBounds = true
        if self.loadingKey == record.key {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        } else { cell.accessoryType = .disclosureIndicator }
        cell.accessibilityLabel = record.title + ", " + record.source + ", " + progress
        return cell
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let record = self.records[indexPath.row]
            if self.store.remove(key: record.key) { self.refresh() }
            else { self.showError("无法保存更改，请稍后重试。") }
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard self.loadingKey == nil, !self.isEditing else { return }
        let record = self.records[indexPath.row]
        let id = MessageId(peerId: PeerId(record.peerId), namespace: record.namespace, id: record.messageId)
        self.loadingKey = record.key
        self.tableView.reloadData()
        self.loadDisposable.set((self.context.engine.messages.getMessagesLoadIfNecessary([id])
        |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self, !self.finished else { return }
            guard case let .result(messages) = result else { return }
            self.loadingKey = nil
            self.tableView.reloadData()
            guard let current = self.store.record(key: record.key) else { return }
            guard let message = messages.first,
                  let file = selectedMediaForMessage(message: message, mediaSubject: current.gallerySubject) as? TelegramMediaFile,
                  file.fileId.namespace == current.mediaNamespace, file.fileId.id == current.mediaId,
                  message.id.peerId.namespace != Namespaces.Peer.SecretChat,
                  !message.containsSecretMedia else {
                self.showError("此视频已不可用。你可以稍后重试，或从收藏中移除。")
                return
            }
            self.finished = true
            self.store.update(key: current.key, position: current.position, duration: current.duration, touch: true)
            let open = self.open
            self.dismiss(animated: true) { open?(message, current) }
        }, error: { [weak self] _ in
            self?.loadingKey = nil
            self?.tableView.reloadData()
            self?.showError("暂时无法加载视频，请检查网络后重试。")
        }))
    }

    private func showError(_ text: String) {
        let alert = UIAlertController(title: "收藏回看", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        self.present(alert, animated: true)
    }
}

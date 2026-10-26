import UIKit
import ComponentFlow

final class DownloadSpeedText {
    private(set) var text = "↓ 0 KB/s"
    private weak var label: UILabel?

    func attach(to label: UILabel) {
        self.label = label
        label.text = self.text
    }

    func update(_ text: String) {
        guard self.text != text else { return }
        self.text = text
        self.label?.text = text
    }
}

final class DownloadSpeedTitleComponent: Component {
    let title: String
    let speed: DownloadSpeedText
    let color: UIColor

    init(title: String, speed: DownloadSpeedText, color: UIColor) {
        self.title = title
        self.speed = speed
        self.color = color
    }

    static func ==(lhs: DownloadSpeedTitleComponent, rhs: DownloadSpeedTitleComponent) -> Bool {
        return lhs.title == rhs.title && lhs.speed === rhs.speed && lhs.color == rhs.color
    }

    final class View: UIView {
        let titleLabel = UILabel()
        let speedLabel = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.titleLabel.font = .systemFont(ofSize: 17.0, weight: .medium)
            self.speedLabel.font = .monospacedDigitSystemFont(ofSize: 11.0, weight: .regular)
            for label in [self.titleLabel, self.speedLabel] {
                label.textAlignment = .center
                label.isAccessibilityElement = false
                self.addSubview(label)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    func makeView() -> View { return View(frame: .zero) }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        view.titleLabel.text = self.title
        view.titleLabel.textColor = self.color
        self.speed.attach(to: view.speedLabel)
        view.speedLabel.textColor = self.color.withAlphaComponent(0.65)
        // Reserve the speed row's width so changing digits never move the button.
        let width = min(availableSize.width, max(90.0, view.titleLabel.sizeThatFits(availableSize).width))
        view.titleLabel.frame = CGRect(x: 0.0, y: 0.0, width: width, height: 20.0)
        view.speedLabel.frame = CGRect(x: 0.0, y: 21.0, width: width, height: 13.0)
        return CGSize(width: width, height: 34.0)
    }
}

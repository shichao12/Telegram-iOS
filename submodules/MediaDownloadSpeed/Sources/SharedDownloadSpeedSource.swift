import Foundation

// Main-queue confined. The last observer tears down the sampler and its cached value.
final class SharedDownloadSpeedSource {
    private let startSampling: (@escaping (String) -> Void) -> (() -> Void)
    private var stopSampling: (() -> Void)?
    private var observers: [UUID: (String) -> Void] = [:]
    private var latest: String?

    var isEmpty: Bool { return self.observers.isEmpty }

    init(startSampling: @escaping (@escaping (String) -> Void) -> (() -> Void)) {
        self.startSampling = startSampling
    }

    func addObserver(_ observer: @escaping (String) -> Void) -> UUID {
        let id = UUID()
        self.observers[id] = observer
        if let latest = self.latest { observer(latest) }
        if self.observers.count == 1 {
            self.stopSampling = self.startSampling { [weak self] text in
                guard let self, !self.observers.isEmpty, self.latest != text else { return }
                self.latest = text
                for observer in Array(self.observers.values) { observer(text) }
            }
        }
        return id
    }

    func removeObserver(_ id: UUID) {
        self.observers.removeValue(forKey: id)
        if self.observers.isEmpty {
            let stop = self.stopSampling
            self.stopSampling = nil
            self.latest = nil
            stop?()
        }
    }
}

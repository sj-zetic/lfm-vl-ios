import Foundation
import Network

/// Watches the active network path so the first-run download can warn before it
/// spends a gigabyte of someone's cellular allowance.
@MainActor
final class NetworkPathObserver: ObservableObject {
    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.sjk.lfmvision.networkpath")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive       // cellular or personal hotspot
            let constrained = path.isConstrained   // Low Data Mode
            Task { @MainActor [weak self] in
                self?.isExpensive = expensive
                self?.isConstrained = constrained
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

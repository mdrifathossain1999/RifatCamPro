import Foundation
import Network
import Combine
import os

// MARK: - DiscoveredDevice

struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let host: String
    let port: UInt16
    let isPasswordProtected: Bool

    init(id: String, name: String, host: String, port: UInt16, isPasswordProtected: Bool) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.isPasswordProtected = isPasswordProtected
    }

    init(endpoint: NWEndpoint, metadata: Data?) {
        let deviceName: String
        let deviceHost: String
        let devicePort: UInt16
        let deviceId: String

        switch endpoint {
        case .service(let name, _, let type, let domain):
            deviceName = name
            deviceId = "\(name).\(type)\(domain)"
            deviceHost = name
            devicePort = 0
        case .hostPort(let host, let port):
            let h: String
            switch host {
            case .ipv4(let addr):
                h = "\(addr)"
            case .ipv6(let addr):
                h = "\(addr)"
            case .name(let name, _):
                h = name
            @unknown default:
                h = "\(host)"
            }
            deviceName = h
            deviceHost = h
            devicePort = port.rawValue
            deviceId = "\(h):\(port.rawValue)"
        default:
            deviceName = "Unknown"
            deviceHost = ""
            devicePort = 0
            deviceId = UUID().uuidString
        }

        var passwordProtected = false
        if let metadata = metadata, !metadata.isEmpty {
            if let txtRecord = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any] {
                passwordProtected = (txtRecord["pw"] as? String) == "1"
            }
        }

        self.id = deviceId
        self.name = deviceName
        self.host = deviceHost
        self.port = devicePort
        self.isPasswordProtected = passwordProtected
    }
}

// MARK: - BonjourService

final class BonjourService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var isBrowsing: Bool = false
    @Published private(set) var lastError: Error?

    // MARK: - Combine Subjects

    let deviceFoundSubject = PassthroughSubject<DiscoveredDevice, Never>()
    let deviceLostSubject = PassthroughSubject<String, Never>()
    let deviceUpdatedSubject = PassthroughSubject<DiscoveredDevice, Never>()

    // MARK: - Private

    private let serviceType: String
    private let domain: String
    private let logger: os.Logger
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var parameters: NWParameters

    // MARK: - Init

    init(
        serviceType: String = "_rifatcam._tcp",
        domain: String = "local."
    ) {
        self.serviceType = serviceType
        self.domain = domain
        self.logger = Logger(subsystem: "com.rifatcam.pro", category: "BonjourService")

        let params = NWParameters()
        params.includePeerToPeer = true
        self.parameters = params
    }

    deinit {
        stop()
    }

    // MARK: - Start / Stop

    func start() {
        guard !isBrowsing else {
            logger.warning("Already browsing, ignoring start()")
            return
        }

        let browseDescriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: domain)
        let nwParameters = NWParameters()

        let nwBrowser = NWBrowser(for: browseDescriptor, using: nwParameters)

        nwBrowser.stateUpdateHandler = { [weak self] state in
            self?.handleStateUpdate(state)
        }

        nwBrowser.browseResultsChangedHandler = { [weak self] results, changes in
            self?.handleResultsChanged(results: results, changes: changes)
        }

        self.browser = nwBrowser
        self.isBrowsing = true

        let queue = DispatchQueue(label: "com.rifatcam.pro.browserservice", qos: .userInitiated)
        nwBrowser.start(queue: queue)

        logger.info("Bonjour browsing started for \(self.serviceType)")
    }

    func stop() {
        guard let browser = browser else { return }
        browser.cancel()
        self.browser = nil

        lock.lock()
        let removedDevices = devices.map { $0.id }
        devices.removeAll()
        lock.unlock()

        isBrowsing = false
        for deviceId in removedDevices {
            deviceLostSubject.send(deviceId)
        }

        logger.info("Bonjour browsing stopped")
    }

    // MARK: - State Handling

    private func handleStateUpdate(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            logger.info("Bonjour browser ready")
        case .failed(let error):
            logger.error("Bonjour browser failed: \(error.localizedDescription)")
            lastError = error
            isBrowsing = false
        case .cancelled:
            logger.info("Bonjour browser cancelled")
            isBrowsing = false
        case .waiting(let error):
            logger.warning("Bonjour browser waiting: \(error.localizedDescription)")
            lastError = error
        default:
            break
        }
    }

    // MARK: - Results Handling

    private func handleResultsChanged(results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                handleDeviceAdded(result)
            case .removed(let result):
                handleDeviceRemoved(result)
            case .identical:
                break
            case .changed(_, let new, _):
                handleDeviceUpdated(new)
            @unknown default:
                break
            }
        }
    }

    private func handleDeviceAdded(_ result: NWBrowser.Result) {
        let endpoint = result.endpoint
        var metadata: Data? = nil
        if let record = result.metadata { metadata = record.rawRepresentation }
        let device = DiscoveredDevice(endpoint: endpoint, metadata: metadata)

        lock.lock()

        if let existingIndex = devices.firstIndex(where: { $0.id == device.id }) {
            devices[existingIndex] = device
        } else {
            devices.append(device)
        }

        lock.unlock()

        deviceFoundSubject.send(device)
        logger.info("Device found: \(device.name) at \(device.host)")
    }

    private func handleDeviceRemoved(_ result: NWBrowser.Result) {
        let endpoint = result.endpoint
        let tempDevice = DiscoveredDevice(endpoint: endpoint, metadata: nil)

        lock.lock()

        if let index = devices.firstIndex(where: { $0.id == tempDevice.id }) {
            let removed = devices.remove(at: index)
            lock.unlock()
            deviceLostSubject.send(removed.id)
            logger.info("Device lost: \(removed.name)")
        } else {
            lock.unlock()
        }
    }

    private func handleDeviceUpdated(_ result: NWBrowser.Result) {
        let endpoint = result.endpoint
        var metadata: Data? = nil
        if let record = result.metadata { metadata = record.rawRepresentation }
        let device = DiscoveredDevice(endpoint: endpoint, metadata: metadata)

        lock.lock()

        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }

        lock.unlock()

        deviceUpdatedSubject.send(device)
        logger.info("Device updated: \(device.name)")
    }

    // MARK: - Resolve

    func resolveDevice(_ device: DiscoveredDevice, completion: @escaping @Sendable (NWConnection?) -> Void) {
        let endpoint: NWEndpoint
        if device.port > 0 {
            if let ipv4 = IPv4Address(device.host) {
                endpoint = .hostPort(host: .ipv4(ipv4), port: NWEndpoint.Port(rawValue: device.port)!)
            } else if let ipv6 = IPv6Address(device.host) {
                endpoint = .hostPort(host: .ipv6(ipv6), port: NWEndpoint.Port(rawValue: device.port)!)
            } else {
                endpoint = .hostPort(host: .name(device.host, nil), port: NWEndpoint.Port(rawValue: device.port)!)
            }
        } else {
            endpoint = .service(name: device.name, type: serviceType, domain: domain, interface: nil)
        }

        let params = NWParameters()
        params.includePeerToPeer = true

        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "com.rifatcam.pro.resolve.\(device.id)", qos: .userInitiated)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                completion(connection)
            case .failed(let error):
                self.logger.error("Connection to \(device.name) failed: \(error.localizedDescription)")
                connection.cancel()
                completion(nil)
            case .cancelled:
                completion(nil)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }
}

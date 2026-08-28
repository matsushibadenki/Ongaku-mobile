@preconcurrency import MultipeerConnectivity
import Combine
import Foundation
import UIKit

nonisolated struct DesktopPairingRequest: Identifiable, Equatable, Sendable {
    var id: UUID
    var deviceName: String
    var pairingCode: String
}

nonisolated enum DiscoveryRetryFeedback: Equatable, Sendable {
    case restarting
    case ready
}

final class DesktopSyncController: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var connectionState: DeviceSyncConnectionState = .disconnected
    @Published private(set) var localItems: [DeviceSyncItem] = []
    @Published private(set) var remoteItems: [DeviceSyncItem] = []
    @Published private(set) var transfers: [DeviceTransferState] = []
    @Published private(set) var discoveryRetryFeedback: DiscoveryRetryFeedback?
    @Published var pairingRequest: DesktopPairingRequest?

    var onLibraryChanged: (() -> Void)?
    let pairingCode = String(format: "%06d", Int.random(in: 0 ... 999_999))

    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session = MCSession(
        peer: peerID,
        securityIdentity: nil,
        encryptionPreference: .required
    )
    private lazy var advertiser = MCNearbyServiceAdvertiser(
        peer: peerID,
        discoveryInfo: ["code": pairingCode],
        serviceType: DeviceSyncService.serviceType
    )
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private var localURLs: [UUID: URL] = [:]
    private var localHashes: Set<String> = []
    private var pendingResources: [UUID: DeviceSyncResourceAnnouncement] = [:]
    private var invitationHandlers: [UUID: (Bool, MCSession?) -> Void] = [:]
    private var advertisingRetryWorkItem: DispatchWorkItem?
    private var discoveryFeedbackWorkItem: DispatchWorkItem?
    private var pairingTimeoutWorkItem: DispatchWorkItem?
    private var isStarted = false

    override init() {
        super.init()
        session.delegate = self
        advertiser.delegate = self
    }

    deinit {
        discoveryFeedbackWorkItem?.cancel()
        pairingTimeoutWorkItem?.cancel()
        advertiser.stopAdvertisingPeer()
        session.disconnect()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        connectionState = .searching
        beginAdvertising()
    }

    func stop() {
        isStarted = false
        advertisingRetryWorkItem?.cancel()
        advertisingRetryWorkItem = nil
        discoveryFeedbackWorkItem?.cancel()
        discoveryFeedbackWorkItem = nil
        discoveryRetryFeedback = nil
        pairingTimeoutWorkItem?.cancel()
        pairingTimeoutWorkItem = nil
        let handlers = lock.withLock { () -> [(Bool, MCSession?) -> Void] in
            let values = Array(invitationHandlers.values)
            invitationHandlers.removeAll()
            return values
        }
        handlers.forEach { $0(false, nil) }
        pairingRequest = nil
        advertiser.stopAdvertisingPeer()
        session.disconnect()
        connectionState = .disconnected
        remoteItems = []
    }

    func acceptPairing(_ request: DesktopPairingRequest) {
        pairingTimeoutWorkItem?.cancel()
        pairingTimeoutWorkItem = nil
        let handler = lock.withLock { invitationHandlers.removeValue(forKey: request.id) }
        pairingRequest = nil
        handler?(true, session)
    }

    func declinePairing(_ request: DesktopPairingRequest) {
        pairingTimeoutWorkItem?.cancel()
        pairingTimeoutWorkItem = nil
        let handler = lock.withLock { invitationHandlers.removeValue(forKey: request.id) }
        pairingRequest = nil
        handler?(false, nil)
        if isStarted { beginAdvertising() }
    }

    func disconnect() {
        session.disconnect()
        remoteItems = []
        connectionState = isStarted ? .searching : .disconnected
        if isStarted { beginAdvertising() }
    }

    func resumeDiscovery() {
        guard isStarted, session.connectedPeers.isEmpty else { return }
        beginAdvertising()
    }

    func retryDiscovery() {
        guard discoveryRetryFeedback != .restarting else { return }
        discoveryFeedbackWorkItem?.cancel()
        discoveryRetryFeedback = .restarting

        if isStarted {
            connectionState = .searching
            beginAdvertising()
        } else {
            start()
        }

        let readyWorkItem = DispatchWorkItem { [weak self] in
            guard let self, session.connectedPeers.isEmpty else { return }
            discoveryRetryFeedback = .ready
            let dismissWorkItem = DispatchWorkItem { [weak self] in
                self?.discoveryRetryFeedback = nil
                self?.discoveryFeedbackWorkItem = nil
            }
            discoveryFeedbackWorkItem = dismissWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: dismissWorkItem)
        }
        discoveryFeedbackWorkItem = readyWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: readyWorkItem)
    }

    func refreshLocalLibrary() async {
        let tracks = await LocalMediaManager.shared.scanLocalFiles()
        let built = await Task.detached(priority: .utility) {
            Self.makeSyncLibrary(from: tracks)
        }.value

        localItems = built.items
        lock.withLock {
            localURLs = built.urls
            localHashes = Set(built.items.map(\.sha256))
        }
        sendManifestIfConnected()
    }

    func uploadToMac(_ item: DeviceSyncItem) {
        sendLocalItem(item.id, direction: .phoneToMac)
    }

    func downloadFromMac(_ item: DeviceSyncItem) {
        send(.requestItem(item.id))
    }

    func hasLocalCopy(of item: DeviceSyncItem) -> Bool {
        lock.withLock { localHashes.contains(item.sha256) }
    }

    private func beginAdvertising() {
        advertisingRetryWorkItem?.cancel()
        if session.connectedPeers.isEmpty {
            connectionState = .searching
        }
        advertiser.stopAdvertisingPeer()
        advertiser.startAdvertisingPeer()
        scheduleAdvertisingRetry()
    }

    private func scheduleAdvertisingRetry() {
        advertisingRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  isStarted,
                  session.connectedPeers.isEmpty,
                  pairingRequest == nil else { return }
            advertiser.stopAdvertisingPeer()
            advertiser.startAdvertisingPeer()
            scheduleAdvertisingRetry()
        }
        advertisingRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    private func sendManifestIfConnected() {
        guard !session.connectedPeers.isEmpty else { return }
        send(.manifest(DeviceSyncManifest(
            deviceName: peerID.displayName,
            generatedAt: .now,
            items: localItems,
            storage: Self.deviceStorageInfo()
        )))
    }

    nonisolated private static func deviceStorageInfo() -> DeviceStorageInfo? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let values = try? documents.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]), let total = values.volumeTotalCapacity else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
            ?? 0
        return DeviceStorageInfo(totalBytes: Int64(total), availableBytes: available)
    }

    private func send(_ message: DeviceSyncMessage) {
        guard !session.connectedPeers.isEmpty else { return }
        do {
            try session.send(
                encoder.encode(message),
                toPeers: session.connectedPeers,
                with: .reliable
            )
        } catch {
            publishFailure(error.localizedDescription)
        }
    }

    private func sendLocalItem(_ id: UUID, direction: DeviceSyncDirection) {
        guard let item = localItems.first(where: { $0.id == id }),
              let url = lock.withLock({ localURLs[id] }),
              let peer = session.connectedPeers.first else { return }

        let transferID = UUID()
        updateTransfer(DeviceTransferState(
            id: transferID,
            item: item,
            direction: direction,
            phase: .preparing
        ))
        send(.resource(DeviceSyncResourceAnnouncement(
            transferID: transferID,
            direction: direction,
            item: item
        )))
        updateTransfer(id: transferID, phase: .transferring)
        session.sendResource(at: url, withName: transferID.uuidString, toPeer: peer) { [weak self] error in
            self?.updateTransfer(
                id: transferID,
                phase: error.map { .failed($0.localizedDescription) } ?? .completed
            )
        }
    }

    private func handle(_ message: DeviceSyncMessage) {
        switch message {
        case .manifest(let manifest):
            DispatchQueue.main.async { [weak self] in
                self?.remoteItems = manifest.items
            }
        case .requestItem(let id):
            sendLocalItem(id, direction: .phoneToMac)
        case .resource(let announcement):
            lock.withLock { pendingResources[announcement.transferID] = announcement }
            updateTransfer(DeviceTransferState(
                id: announcement.transferID,
                item: announcement.item,
                direction: announcement.direction,
                phase: .transferring
            ))
        case .error(let message):
            publishFailure(message)
        }
    }

    private func finishReceivedResource(name: String, temporaryURL: URL?, error: Error?) {
        guard let transferID = UUID(uuidString: name),
              let announcement = lock.withLock({ pendingResources.removeValue(forKey: transferID) }) else {
            return
        }
        if let error {
            updateTransfer(id: transferID, phase: .failed(error.localizedDescription))
            return
        }
        guard let temporaryURL else {
            updateTransfer(id: transferID, phase: .failed(L10n.tr("sync.error.missing_file")))
            return
        }

        updateTransfer(id: transferID, phase: .verifying)
        do {
            guard try DeviceSyncFileIntegrity.verified(temporaryURL, matches: announcement.item) else {
                throw CocoaError(.fileReadCorruptFile)
            }

            if !lock.withLock({ localHashes.contains(announcement.item.sha256) }) {
                let destination = try Self.uniqueLibraryDestination(for: announcement.item.fileName)
                try FileManager.default.copyItem(at: temporaryURL, to: destination)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Task {
                    await self.refreshLocalLibrary()
                    guard self.hasLocalCopy(of: announcement.item) else {
                        let message = L10n.tr(
                            "sync.error.unreadable_audio",
                            announcement.item.fileName
                        )
                        self.updateTransfer(id: transferID, phase: .failed(message))
                        self.send(.error(message))
                        return
                    }
                    self.updateTransfer(id: transferID, phase: .completed)
                    self.onLibraryChanged?()
                }
            }
        } catch {
            updateTransfer(id: transferID, phase: .failed(error.localizedDescription))
            send(.error(error.localizedDescription))
        }
    }

    private func updateTransfer(_ state: DeviceTransferState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let index = transfers.firstIndex(where: { $0.id == state.id }) {
                transfers[index] = state
            } else {
                transfers.insert(state, at: 0)
            }
        }
    }

    private func updateTransfer(id: UUID, phase: DeviceTransferState.Phase) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let index = transfers.firstIndex(where: { $0.id == id }) else { return }
            transfers[index].phase = phase
        }
    }

    private func publishFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = .failed(message)
        }
    }

    nonisolated private static func makeSyncLibrary(
        from tracks: [LocalTrackMetadata]
    ) -> (items: [DeviceSyncItem], urls: [UUID: URL]) {
        var items: [DeviceSyncItem] = []
        var urls: [UUID: URL] = [:]
        var hashes: Set<String> = []

        for track in tracks {
            do {
                let digest = try DeviceSyncFileIntegrity.sha256(of: track.url)
                guard hashes.insert(digest).inserted else { continue }
                let values = try track.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let item = DeviceSyncItem(
                    id: DeviceSyncFileIntegrity.stableID(forSHA256: digest),
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    fileName: track.url.lastPathComponent,
                    fileSize: Int64(values.fileSize ?? 0),
                    sha256: digest,
                    modifiedAt: values.contentModificationDate ?? .now
                )
                items.append(item)
                urls[item.id] = track.url
            } catch {
                continue
            }
        }

        items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return (items, urls)
    }

    nonisolated private static func uniqueLibraryDestination(for fileName: String) throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Ongaku", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeName = URL(fileURLWithPath: fileName).lastPathComponent
        let source = URL(fileURLWithPath: safeName)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = directory.appendingPathComponent(safeName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(nextName)
            counter += 1
        }
        return candidate
    }
}

extension DesktopSyncController: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let requestID = UUID()
        let receivedCode = context
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["pairingCode"]
            ?? pairingCode
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard pairingRequest == nil else {
                invitationHandler(false, nil)
                return
            }
            lock.withLock { self.invitationHandlers[requestID] = invitationHandler }
            advertisingRetryWorkItem?.cancel()
            advertisingRetryWorkItem = nil
            pairingRequest = DesktopPairingRequest(
                id: requestID,
                deviceName: peerID.displayName,
                pairingCode: receivedCode
            )
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, pairingRequest?.id == requestID else { return }
                let handler = lock.withLock {
                    self.invitationHandlers.removeValue(forKey: requestID)
                }
                pairingRequest = nil
                pairingTimeoutWorkItem = nil
                handler?(false, nil)
                if isStarted { beginAdvertising() }
            }
            pairingTimeoutWorkItem?.cancel()
            pairingTimeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        publishFailure(error.localizedDescription)
    }
}

extension DesktopSyncController: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = peerID.displayName
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch state {
            case .notConnected:
                connectionState = isStarted ? .searching : .disconnected
                remoteItems = []
                if isStarted { scheduleAdvertisingRetry() }
            case .connecting:
                connectionState = .connecting(name)
            case .connected:
                discoveryFeedbackWorkItem?.cancel()
                discoveryFeedbackWorkItem = nil
                discoveryRetryFeedback = nil
                advertisingRetryWorkItem?.cancel()
                advertisingRetryWorkItem = nil
                connectionState = .connected(name)
                sendManifestIfConnected()
            @unknown default:
                connectionState = .failed(L10n.tr("sync.error.unknown_state"))
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        do {
            handle(try decoder.decode(DeviceSyncMessage.self, from: data))
        } catch {
            publishFailure(error.localizedDescription)
        }
    }

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {
        finishReceivedResource(name: resourceName, temporaryURL: localURL, error: error)
    }

    func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}
}

nonisolated private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

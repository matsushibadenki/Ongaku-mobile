import SwiftUI
import UIKit

struct DesktopSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sync: DesktopSyncController

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                phoneLibrarySection
                macLibrarySection
                transferSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(L10n.tr("sync.title"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.tr("common.close")) { dismiss() }
                }
            }
            .task {
                await sync.refreshLocalLibrary()
                sync.start()
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    private var connectionSection: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: connectionIcon)
                    .font(.title2)
                    .foregroundStyle(connectionColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 6) {
                    Text(connectionTitle)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(connectionDetail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)

            if isConnected {
                Button(L10n.tr("sync.disconnect"), role: .destructive) {
                    sync.disconnect()
                }
            } else {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    sync.retryDiscovery()
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: L10n.tr("sync.retry.restarting")
                    )
                } label: {
                    HStack(spacing: 10) {
                        if sync.discoveryRetryFeedback == .restarting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(sync.discoveryRetryFeedback == .restarting
                            ? L10n.tr("sync.retry.restarting")
                            : L10n.tr("sync.retry"))
                    }
                }
                .disabled(sync.discoveryRetryFeedback == .restarting)

                if let feedback = sync.discoveryRetryFeedback {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: feedback == .restarting
                            ? "dot.radiowaves.left.and.right"
                            : "checkmark.circle.fill")
                            .foregroundStyle(feedback == .restarting ? Theme.accent : .green)
                        Text(feedback == .restarting
                            ? L10n.tr("sync.retry.searching")
                            : L10n.tr("sync.retry.ready"))
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        } header: {
            Text(L10n.tr("sync.connection"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("sync.pairing.code", sync.pairingCode))
                Text(L10n.tr("sync.network_help"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sync.discoveryRetryFeedback)
        .listRowBackground(Theme.secondaryBackground)
    }

    private var phoneLibrarySection: some View {
        Section(L10n.tr("sync.on_phone")) {
            if sync.localItems.isEmpty {
                Text(L10n.tr("sync.phone_empty"))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(sync.localItems) { item in
                    trackRow(item: item) {
                        Button {
                            sync.uploadToMac(item)
                        } label: {
                            Image(systemName: "arrow.up.to.line")
                        }
                        .accessibilityLabel(L10n.tr("sync.send_to_mac"))
                        .disabled(!isConnected)
                    }
                }
            }
        }
        .listRowBackground(Theme.secondaryBackground)
    }

    private var macLibrarySection: some View {
        Section(L10n.tr("sync.on_mac")) {
            if !isConnected {
                Text(L10n.tr("sync.mac_connect_first"))
                    .foregroundStyle(Theme.textSecondary)
            } else if sync.remoteItems.isEmpty {
                Text(L10n.tr("sync.mac_empty"))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(sync.remoteItems) { item in
                    trackRow(item: item) {
                        Button {
                            sync.downloadFromMac(item)
                        } label: {
                            Image(systemName: sync.hasLocalCopy(of: item)
                                ? "checkmark.circle.fill"
                                : "arrow.down.to.line")
                        }
                        .accessibilityLabel(L10n.tr("sync.download_from_mac"))
                        .disabled(sync.hasLocalCopy(of: item))
                    }
                }
            }
        }
        .listRowBackground(Theme.secondaryBackground)
    }

    @ViewBuilder
    private var transferSection: some View {
        if let transfer = sync.transfers.first {
            Section(L10n.tr("sync.latest_transfer")) {
                HStack(spacing: 12) {
                    if transfer.phase == .preparing
                        || transfer.phase == .transferring
                        || transfer.phase == .verifying {
                        ProgressView()
                    } else {
                        Image(systemName: transfer.phase == .completed
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle.fill")
                            .foregroundStyle(transfer.phase == .completed ? .green : .red)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(transfer.item.title)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(transferDescription(transfer.phase))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .listRowBackground(Theme.secondaryBackground)
        }
    }

    private func trackRow<Accessory: View>(
        item: DeviceSyncItem,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(trackDetail(item))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 4)
    }

    private var isConnected: Bool {
        if case .connected = sync.connectionState { return true }
        return false
    }

    private var connectionTitle: String {
        switch sync.connectionState {
        case .connected(let name): L10n.tr("sync.connected", name)
        case .connecting(let name): L10n.tr("sync.connecting", name)
        case .failed: L10n.tr("sync.failed")
        case .searching, .disconnected: L10n.tr("sync.ready")
        }
    }

    private var connectionDetail: String {
        switch sync.connectionState {
        case .connected: L10n.tr("sync.connected_detail")
        case .connecting: L10n.tr("sync.connecting_detail")
        case .failed(let message): message
        case .searching, .disconnected: L10n.tr("sync.ready_detail")
        }
    }

    private var connectionIcon: String {
        isConnected ? "iphone.and.arrow.forward" : "wifi"
    }

    private var connectionColor: Color {
        if case .failed = sync.connectionState { return .red }
        return isConnected ? .green : Theme.accent
    }

    private func trackDetail(_ item: DeviceSyncItem) -> String {
        let metadata = L10n.joinedMetadata([item.artist, item.album])
        return metadata.isEmpty
            ? ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)
            : metadata
    }

    private func transferDescription(_ phase: DeviceTransferState.Phase) -> String {
        switch phase {
        case .preparing: L10n.tr("sync.transfer.preparing")
        case .transferring: L10n.tr("sync.transfer.transferring")
        case .verifying: L10n.tr("sync.transfer.verifying")
        case .completed: L10n.tr("sync.transfer.completed")
        case .failed(let message): message
        }
    }
}

struct DesktopSyncView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            DesktopSyncView()
                .environmentObject(DesktopSyncController())
                .previewDevice("iPhone SE (3rd generation)")
                .previewDisplayName("iPhone SE")

            DesktopSyncView()
                .environmentObject(DesktopSyncController())
                .previewDevice("iPhone 16 Pro Max")
                .previewDisplayName("iPhone 16 Pro Max")
        }
    }
}

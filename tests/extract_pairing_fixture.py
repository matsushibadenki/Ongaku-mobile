"""Extract the shipping invitation ownership methods; no network or app state."""
from pathlib import Path
import re,sys
root=Path(__file__).resolve().parent.parent
source=(root/'audio/DesktopSyncController.swift').read_text()
app=(root/'audio/audioApp.swift').read_text()
def block(text,anchor):
    assert text.count(anchor)==1,anchor
    start=text.index(anchor);end=text.index('{',start)+1;depth=1
    while depth:
        depth+=(text[end]=='{')-(text[end]=='}');end+=1
    return text[start:end]
binding=block(app,'set: { isPresented in')
assert 'dismissPairingPresentation(request)' in binding
assert 'declinePairing(request)' not in binding
mobile=(root/'audio/DeviceSyncModels.swift').read_text()
desktop=(root.parent/'Ongaku-desktop/Sources/OngakuDesktop/DeviceSyncModels.swift').read_text()
for key in ['pairingDecisionTimeout','invitationTimeout','connectionAttemptTimeout']:
    expression=rf'static let {key}: TimeInterval = (\d+)'
    assert re.search(expression,mobile).group(1)==re.search(expression,desktop).group(1)
mac=(root.parent/'Ongaku-desktop/Sources/OngakuDesktop/PhoneSyncController.swift').read_text()
assert 'withContext: context, timeout: DeviceSyncService.invitationTimeout' in mac
assert '.now() + DeviceSyncService.connectionAttemptTimeout' in mac
parts=['import Foundation',block(source,'nonisolated struct DesktopPairingRequest:'),block(mobile,'nonisolated enum DeviceSyncService {'),'''
final class MCSession { var connectedPeers: [String] = [] }
enum DeviceSyncConnectionState: Equatable { case searching, connecting(String), failed(String) }
enum PlaybackDebugLogger { static func event(_ text: String) {} }
enum L10n { static func tr(_ key: String) -> String { key } }
final class ShippingPairing {
    let lock = NSLock()
    let session = MCSession()
    var pairingRequest: DesktopPairingRequest?
    var connectionState: DeviceSyncConnectionState = .searching
    var invitationHandlers: [UUID: (Bool, MCSession?) -> Void] = [:]
    var pairingTimeoutWorkItem: DispatchWorkItem?
    var advertisingRetryWorkItem: DispatchWorkItem?
    var isStarted = true
    var advertisements = 0
    func beginAdvertising() { advertisements += 1; connectionState = .searching }
''']
for anchor in ['    func dismissPairingPresentation(', '    func acceptPairing(', '    func declinePairing(',
               '    private func expirePairingRequest(', '    private func registerPairingInvitation(', '    func resumeDiscovery(']:
    parts.append(block(source,anchor).replace('private func','func',1))
parts.append('}')
Path(sys.argv[1]).write_text('\n'.join(parts))

import Foundation

@main struct PairingInvitationRegression {
    static func request(_ name: String = "Mac") -> DesktopPairingRequest {
        .init(id: UUID(), deviceName: name, pairingCode: "000000")
    }
    static func main() {
        doDismissThenAccept()
        doDismissThenDecline()
        doExpiryAndStaleActions()
        doOverlappingInvitations()
        doStoppedAdvertiser()
        precondition(DeviceSyncService.pairingDecisionTimeout < DeviceSyncService.invitationTimeout)
        precondition(DeviceSyncService.invitationTimeout < DeviceSyncService.connectionAttemptTimeout)
        print("PASS: iPhone decision, framework invitation and Mac UI deadlines have the same ordered policy")
    }
    static func doDismissThenAccept() {
        let model = ShippingPairing(), req = request()
        var answers: [Bool] = []
        model.registerPairingInvitation(req) { accepted, session in
            precondition(!accepted || session === model.session)
            answers.append(accepted)
        }
        model.dismissPairingPresentation(req) // SwiftUI is allowed to do this first.
        precondition(model.pairingRequest == nil && answers.isEmpty)
        model.resumeDiscovery()
        precondition(model.advertisements == 0)
        model.acceptPairing(req)
        precondition(answers == [true] && model.connectionState == .connecting("Mac"))
        model.acceptPairing(req); model.declinePairing(req); model.expirePairingRequest(req.id)
        model.resumeDiscovery()
        precondition(answers == [true] && model.advertisements == 0)
        print("PASS: presentation dismissal before Allow does not reject; acceptance resolves once and shows connecting")
    }
    static func doDismissThenDecline() {
        let model = ShippingPairing(), req = request()
        var answers: [Bool] = []
        model.registerPairingInvitation(req) { accepted, _ in answers.append(accepted) }
        model.dismissPairingPresentation(req)
        model.declinePairing(req); model.declinePairing(req); model.acceptPairing(req)
        precondition(answers == [false] && model.invitationHandlers.isEmpty)
        print("PASS: dismissal before explicit decline rejects exactly once")
    }
    static func doExpiryAndStaleActions() {
        let model = ShippingPairing(), first = request(), next = request("New Mac")
        var firstAnswers: [Bool] = [], nextAnswers: [Bool] = []
        model.registerPairingInvitation(first) { accepted, _ in firstAnswers.append(accepted) }
        model.dismissPairingPresentation(first)
        model.expirePairingRequest(first.id)
        precondition(firstAnswers == [false])
        precondition(model.connectionState == .failed("sync.error.pairing_expired"))
        model.registerPairingInvitation(next) { accepted, _ in nextAnswers.append(accepted) }
        let timeout = model.pairingTimeoutWorkItem
        model.acceptPairing(first); model.declinePairing(first); model.expirePairingRequest(first.id)
        model.dismissPairingPresentation(first)
        precondition(model.pairingRequest?.id == next.id && model.pairingTimeoutWorkItem === timeout)
        precondition(nextAnswers.isEmpty)
        model.acceptPairing(next)
        precondition(nextAnswers == [true])
        print("PASS: hidden/expired requests are rejected; late actions cannot consume or dismiss a newer invitation")
    }
    static func doOverlappingInvitations() {
        let model = ShippingPairing(), first = request(), second = request()
        var a: [Bool] = [], b: [Bool] = []
        model.registerPairingInvitation(first) { accepted, _ in a.append(accepted) }
        model.dismissPairingPresentation(first)
        model.registerPairingInvitation(second) { accepted, _ in b.append(accepted) }
        precondition(a.isEmpty && b == [false] && model.invitationHandlers.count == 1)
        model.acceptPairing(first)
        precondition(a == [true])
        print("PASS: a dismissed but unresolved invitation keeps its ownership against a duplicate invite")
    }
    static func doStoppedAdvertiser() {
        let model = ShippingPairing(), req = request()
        model.isStarted = false
        var answers: [Bool] = []
        model.registerPairingInvitation(req) { accepted, _ in answers.append(accepted) }
        precondition(answers == [false] && model.pairingRequest == nil && model.invitationHandlers.isEmpty)
        print("PASS: late invitations after advertising stops are rejected without presenting permission")
    }
}

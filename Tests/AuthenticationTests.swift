import Foundation

final class StubAuthenticator: DeviceAuthenticating {
    var completions: [(Bool, String?) -> Void] = []
    var cancels = 0
    func authenticate(completion: @escaping (Bool, String?) -> Void) { completions.append(completion) }
    func cancel() { cancels += 1 }
}

@main struct AuthenticationTests {
    static func main() {
        let device = StubAuthenticator()
        let gate = AuthenticationGate(authenticator: device)
        var unlockEvents = 0
        gate.onChange = { if gate.state == .unlocked { unlockEvents += 1 } }
        precondition(gate.state == .locked)
        gate.unlock(); gate.unlock()
        precondition(device.completions.count == 1 && gate.state == .authenticating)
        device.completions[0](false, "Cancelled")
        precondition(gate.state == .locked && unlockEvents == 0)
        gate.unlock(); gate.lock()
        device.completions[1](true, nil) // A success arriving after sleep/lock must be ignored.
        precondition(gate.state == .locked && unlockEvents == 0 && device.cancels == 1)
        gate.unlock()
        device.completions[1](true, nil) // An older prompt cannot unlock a newer prompt either.
        precondition(gate.state == .authenticating)
        device.completions[2](true, nil)
        precondition(gate.state == .unlocked && unlockEvents == 1)
        gate.unlock(); precondition(device.completions.count == 3)
        gate.lock(); precondition(gate.state == .locked)
        gate.unlock(); device.completions[3](false, "Authentication unavailable")
        precondition(gate.state == .locked && unlockEvents == 1)
        print("PASS: authentication denial, cancellation, success, relock and stale callback rejection.")
    }
}

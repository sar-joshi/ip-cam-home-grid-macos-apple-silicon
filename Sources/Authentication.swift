import Foundation
import LocalAuthentication

protocol DeviceAuthenticating: AnyObject {
    // Implementations deliver completion on the main thread.
    func authenticate(completion: @escaping (Bool, String?) -> Void)
    func cancel()
}

final class LocalDeviceAuthenticator: DeviceAuthenticating {
    private var context: LAContext?
    func authenticate(completion: @escaping (Bool, String?) -> Void) {
        context?.invalidate()
        let context = LAContext()
        self.context = context
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(false, error?.localizedDescription ?? "Set up a Mac login password or Touch ID to unlock HomeGrid.")
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "Unlock HomeGrid to view your security cameras.") { success, error in
            DispatchQueue.main.async { completion(success, error?.localizedDescription) }
        }
    }
    func cancel() { context?.invalidate(); context = nil }
}

final class AuthenticationGate {
    enum State: Equatable { case locked, authenticating, unlocked }
    private(set) var state: State = .locked
    private(set) var message = "Use Touch ID or your Mac login password to continue."
    private var generation = UUID()
    private let authenticator: DeviceAuthenticating
    var onChange: (() -> Void)?
    init(authenticator: DeviceAuthenticating) { self.authenticator = authenticator }

    func unlock() {
        guard state == .locked else { return }
        generation = UUID()
        let request = generation
        state = .authenticating; message = "Waiting for macOS authentication…"; onChange?()
        authenticator.authenticate { [weak self] success, error in
            guard let self, self.generation == request, self.state == .authenticating else { return }
            self.state = success ? .unlocked : .locked
            self.message = success ? "Unlocked" : error ?? "Authentication was cancelled. HomeGrid remains locked."
            self.onChange?()
        }
    }
    func lock() {
        generation = UUID() // Invalidate even a delayed successful callback from an older prompt.
        authenticator.cancel()
        state = .locked; message = "Use Touch ID or your Mac login password to continue."
        onChange?()
    }
}

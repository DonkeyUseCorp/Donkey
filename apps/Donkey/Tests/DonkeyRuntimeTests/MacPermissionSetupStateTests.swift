@testable import DonkeyRuntime
import Testing

@Suite
struct MacPermissionSetupStateTests {
    @Test
    func unresolvedPermissionStartsWithEnableAction() {
        let resolver = MacPermissionSetupStateResolver()

        let row = resolver.row(kind: .accessibility, status: .notDetermined)

        #expect(row.action == .enable)
        #expect(row.status == .notDetermined)
    }

    @Test
    func requestedUnresolvedPermissionCanRequestAgain() {
        let resolver = MacPermissionSetupStateResolver(requestedKinds: [.screenRecording])

        let row = resolver.row(kind: .screenRecording, status: .notDetermined)

        #expect(row.action == .enable)
    }

    @Test
    func deniedPermissionOpensSystemSettings() {
        let resolver = MacPermissionSetupStateResolver()

        let row = resolver.row(kind: .microphone, status: .denied)

        #expect(row.action == .openSystemSettings)
    }

    @Test
    func allCorePermissionsMustBeGrantedBeforeContinue() {
        let resolver = MacPermissionSetupStateResolver()

        #expect(resolver.allRequiredPermissionsGranted(statuses: [
            .accessibility: .granted,
            .screenRecording: .granted,
            .microphone: .granted
        ]))
        #expect(!resolver.allRequiredPermissionsGranted(statuses: [
            .accessibility: .granted,
            .screenRecording: .notDetermined,
            .microphone: .granted
        ]))
    }
}

import Testing
@testable import AtmoCore

@MainActor
struct AuthViewModelTests {

    @Test func normalizedHandleStripsLeadingAt() {
        let vm = AuthViewModel()
        vm.handle = "@alice.bsky.social"
        #expect(vm.normalizedHandle == "alice.bsky.social")
    }

    @Test func normalizedHandleAppendsDefaultDomainForBareNames() {
        let vm = AuthViewModel()
        vm.handle = "alice"
        #expect(vm.normalizedHandle == "alice.bsky.social")
    }

    @Test func normalizedHandleKeepsCustomDomains() {
        let vm = AuthViewModel()
        vm.handle = " alice.example.com "
        #expect(vm.normalizedHandle == "alice.example.com")
    }

    @Test func canSubmitRequiresHandleAndPassword() {
        let vm = AuthViewModel()
        #expect(!vm.canSubmit)
        vm.handle = "alice"
        #expect(!vm.canSubmit)
        vm.appPassword = "app-password"
        #expect(vm.canSubmit)
        vm.handle = "   "
        #expect(!vm.canSubmit)
    }

    @Test func twoFactorCodeMustBeSixDigits() {
        let vm = AuthViewModel()
        vm.twoFactorCode = "12345"
        #expect(!vm.canSubmitTwoFactor)
        vm.twoFactorCode = "123456"
        #expect(vm.canSubmitTwoFactor)
    }
}

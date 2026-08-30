import Testing
@testable import AtmoCore

/// Covers the composer's exit decision: nothing typed → close silently,
/// one contentful post → ask the user, a multi-post thread → auto-save.
@MainActor
struct ComposerExitPolicyTests {

    @Test func emptyComposerDiscardsSilently() {
        #expect(ComposerViewModel.exitDraftPolicy(forSlotTexts: [""]) == .discardSilently)
        #expect(ComposerViewModel.exitDraftPolicy(forSlotTexts: []) == .discardSilently)
    }

    @Test func whitespaceOnlyCountsAsEmpty() {
        #expect(ComposerViewModel.exitDraftPolicy(forSlotTexts: ["  \n\t "]) == .discardSilently)
        #expect(ComposerViewModel.exitDraftPolicy(forSlotTexts: [" ", "\n"]) == .discardSilently)
    }

    @Test func singleContentfulPostPrompts() {
        #expect(ComposerViewModel.exitDraftPolicy(forSlotTexts: ["hello world"]) == .promptToSave)
    }

    @Test func emptyExtraSlotsDoNotMakeAThread() {
        // The user tapped "Add to thread" but never typed in the new slot —
        // it's still a single post, so the user is asked.
        #expect(ComposerViewModel.exitDraftPolicy(forSlotTexts: ["hello", ""]) == .promptToSave)
    }

    @Test func multiPostThreadAutoSaves() {
        #expect(ComposerViewModel.exitDraftPolicy(forSlotTexts: ["one", "two"]) == .autoSave)
        #expect(ComposerViewModel.exitDraftPolicy(forSlotTexts: ["one", "", "three"]) == .autoSave)
    }
}

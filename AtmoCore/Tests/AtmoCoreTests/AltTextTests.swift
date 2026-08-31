import Foundation
import Testing
@testable import AtmoCore

/// Covers the alt-text mutator used by the composer's image analysis flow.
@MainActor
struct AltTextTests {

    @Test func updatesTheMatchingImage() {
        let slot = PostSlot()
        slot.addImage(data: Data([1]), fileName: "a.jpg")
        slot.addImage(data: Data([2]), fileName: "b.jpg")
        let target = slot.attachedImages[1].id

        slot.updateImageAltText(id: target, altText: "A red bicycle")

        #expect(slot.attachedImages[0].altText.isEmpty)
        #expect(slot.attachedImages[1].altText == "A red bicycle")
    }

    @Test func unknownIDIsANoOp() {
        let slot = PostSlot()
        slot.addImage(data: Data([1]), fileName: "a.jpg")

        slot.updateImageAltText(id: UUID(), altText: "ghost")

        #expect(slot.attachedImages[0].altText.isEmpty)
    }
}

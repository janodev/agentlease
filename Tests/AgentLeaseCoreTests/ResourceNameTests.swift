@testable import AgentLeaseCore
import Testing

@Suite("Resource identity")
struct ResourceNameTests {
    @Test("Valid resources sort by UTF-8 bytes and hash deterministically")
    func sortedIdentityAndDigest() throws {
        let resources = try ResourceSet(["z:last", "A:first", "a:middle"])

        #expect(resources.resources.map(\.value) == ["A:first", "a:middle", "z:last"])
        #expect(resources.environmentValue == "A:first,a:middle,z:last")
        #expect(
            try ResourceName("host:macos-ui").lockDigest
                == "20783c63eb23c1db3cc9419ca2cb4788ff18be1b6c94e7502f320c8041d95bac"
        )
    }

    @Test("Malformed and duplicate resources are rejected")
    func rejectsInvalidValues() throws {
        for value in ["", "-leading", "space here", "emoji:🔒", "comma,value"] {
            #expect(throws: ResourceValidationError.self) {
                _ = try ResourceName(value)
            }
        }
        #expect(throws: ResourceValidationError.duplicate("same")) {
            _ = try ResourceSet(["same", "same"])
        }
        #expect(throws: ResourceValidationError.emptySet) {
            _ = try ResourceSet([])
        }
        #expect(throws: ResourceValidationError.self) {
            _ = try ResourceName("a" + String(repeating: "b", count: 256))
        }
    }

    @Test("Resource count and environment representation are bounded")
    func collectionBounds() throws {
        #expect(throws: ResourceValidationError.tooMany(65)) {
            _ = try ResourceSet((0..<65).map { "resource:\($0)" })
        }

        let largeResources = (0..<17).map { index in
            "r\(index):" + String(repeating: "x", count: 250)
        }
        #expect(throws: ResourceValidationError.self) {
            _ = try ResourceSet(largeResources)
        }
    }
}

import Testing
@testable import Soroband

struct CoreBridgeTests {
    @Test func bridgeReturnsTheCoreVersionFromCargoToml() throws {
        #expect(Core.version == (try RepositoryFiles.coreWorkspaceVersion()))
    }

    @Test func menuBarShowsTheVersionFromTheCore() throws {
        #expect(MenuBar.text == "Soroband \(try RepositoryFiles.coreWorkspaceVersion())")
    }
}

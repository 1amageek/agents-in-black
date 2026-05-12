import AIBCore
import Foundation
import Testing

@Test(.timeLimit(.minutes(1)))
func deployProfileStoreCreatesDefaultProfilesWhenMissing() throws {
    let root = try makeTemporaryDirectory()
    let store = DefaultDeployProfileStore()

    let config = try store.load(workspaceRoot: root.path)

    #expect(config.activeProfileName == "salescore-ei-stg")
    #expect(config.profiles.map(\.name) == ["salescore-ei-stg", "enablement-intelligence", "vi-dev-b8a52"])
    #expect(config.profiles.first(where: { $0.name == "vi-dev-b8a52" })?.gcpProject == "vi-dev-b8a52")
    #expect(config.profiles.first(where: { $0.name == "salescore-ei-stg" })?.gcpProject == "salescore-ei-stg")
    #expect(config.profiles.first(where: { $0.name == "enablement-intelligence" })?.gcpProject == "enablement-intelligence")
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".aib/deploy-profiles.yaml").path))
}

@Test(.timeLimit(.minutes(1)))
func deployProfileStorePersistsActiveProfile() throws {
    let root = try makeTemporaryDirectory()
    let store = DefaultDeployProfileStore()
    _ = try store.load(workspaceRoot: root.path)

    try store.setActiveProfile(workspaceRoot: root.path, name: "enablement-intelligence")
    let config = try store.load(workspaceRoot: root.path)

    #expect(config.activeProfileName == "enablement-intelligence")
    #expect(config.activeProfile?.gcpProject == "enablement-intelligence")
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-deploy-profile-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

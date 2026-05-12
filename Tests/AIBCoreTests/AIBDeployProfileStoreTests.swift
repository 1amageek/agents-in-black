import AIBCore
import Foundation
import Testing

@Test(.timeLimit(.minutes(1)))
func deployProfileStoreCreatesDefaultProfilesWhenMissing() throws {
    let root = try makeTemporaryDirectory()
    let store = DefaultDeployProfileStore()

    let config = try store.load(workspaceRoot: root.path)

    #expect(config.activeProfileName == "stg")
    #expect(config.profiles.map(\.name) == ["dev", "stg", "prod"])
    #expect(config.profiles.first(where: { $0.name == "dev" })?.gcpProject == "vi-dev-b8a52")
    #expect(config.profiles.first(where: { $0.name == "stg" })?.gcpProject == "salescore-ei-stg")
    #expect(config.profiles.first(where: { $0.name == "prod" })?.gcpProject == "enablement-intelligence")
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".aib/deploy-profiles.yaml").path))
}

@Test(.timeLimit(.minutes(1)))
func deployProfileStorePersistsActiveProfile() throws {
    let root = try makeTemporaryDirectory()
    let store = DefaultDeployProfileStore()
    _ = try store.load(workspaceRoot: root.path)

    try store.setActiveProfile(workspaceRoot: root.path, name: "prod")
    let config = try store.load(workspaceRoot: root.path)

    #expect(config.activeProfileName == "prod")
    #expect(config.activeProfile?.gcpProject == "enablement-intelligence")
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-deploy-profile-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

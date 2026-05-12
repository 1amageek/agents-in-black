@testable import AIBCore
import Foundation
import Testing

@Suite("Dockerfile patch — runtime stage targeting")
struct DockerfilePatchTests {

    @Test("Multi-stage Dockerfile inserts runtime instructions after the final WORKDIR")
    func multiStageInsertsAfterFinalWorkdir() throws {
        let dockerfile = """
        FROM node:22-slim AS base
        RUN apt-get update

        FROM base AS deps
        WORKDIR /app
        COPY package.json ./
        RUN pnpm install

        FROM base AS runtime
        WORKDIR /app
        COPY --from=deps /app/node_modules ./node_modules/
        CMD ["node", "dist/index.js"]
        """

        let context = try makeBuildContext(dockerfile: dockerfile)
        defer { try? FileManager.default.removeItem(at: context.directory) }

        let patchedPath = try DefaultDeployExecutor.patchedDockerfilePath(
            dockerfilePath: context.dockerfilePath,
            buildContext: context.directory.path,
            topStageInstructions: [],
            runtimeStageInstructions: ["COPY .aib-connections.json ./"],
            appendedInstructions: []
        )
        let patched = try String(contentsOfFile: patchedPath, encoding: .utf8)
        let lines = patched.components(separatedBy: "\n")

        let workdirIndices = lines.enumerated().compactMap { index, line in
            line.trimmingCharacters(in: .whitespaces) == "WORKDIR /app" ? index : nil
        }
        let finalWorkdirIndex = try #require(workdirIndices.last)
        let copyIndex = try #require(lines.firstIndex(of: "COPY .aib-connections.json ./"))

        // The injected COPY must live in the runtime stage, on the line right
        // after the final WORKDIR. Any earlier placement means it would land
        // in `deps` (or worse, in `base`) and never reach the runtime image.
        #expect(copyIndex == finalWorkdirIndex + 1)

        // Sanity: the COPY appears below the *final* `FROM` directive.
        let lastFromIndex = try #require(lines.lastIndex { $0.hasPrefix("FROM ") })
        #expect(copyIndex > lastFromIndex)
    }

    @Test("Single-stage Dockerfile still places runtime instructions inside the only stage")
    func singleStagePlacesAfterWorkdir() throws {
        let dockerfile = """
        FROM node:22-slim
        WORKDIR /app
        COPY package.json ./
        RUN pnpm install
        CMD ["node", "dist/index.js"]
        """

        let context = try makeBuildContext(dockerfile: dockerfile)
        defer { try? FileManager.default.removeItem(at: context.directory) }

        let patchedPath = try DefaultDeployExecutor.patchedDockerfilePath(
            dockerfilePath: context.dockerfilePath,
            buildContext: context.directory.path,
            topStageInstructions: [],
            runtimeStageInstructions: ["COPY .aib-connections.json ./"],
            appendedInstructions: []
        )
        let lines = try String(contentsOfFile: patchedPath, encoding: .utf8)
            .components(separatedBy: "\n")

        let workdirIndex = try #require(lines.firstIndex(of: "WORKDIR /app"))
        let copyIndex = try #require(lines.firstIndex(of: "COPY .aib-connections.json ./"))
        #expect(copyIndex == workdirIndex + 1)
    }

    @Test("Final stage without WORKDIR falls back to inserting after the last FROM")
    func finalStageWithoutWorkdirFallsBack() throws {
        let dockerfile = """
        FROM node:22-slim AS base
        WORKDIR /app
        RUN apt-get update

        FROM base AS runtime
        COPY package.json ./
        CMD ["node", "dist/index.js"]
        """

        let context = try makeBuildContext(dockerfile: dockerfile)
        defer { try? FileManager.default.removeItem(at: context.directory) }

        let patchedPath = try DefaultDeployExecutor.patchedDockerfilePath(
            dockerfilePath: context.dockerfilePath,
            buildContext: context.directory.path,
            topStageInstructions: [],
            runtimeStageInstructions: ["COPY .aib-connections.json ./"],
            appendedInstructions: []
        )
        let lines = try String(contentsOfFile: patchedPath, encoding: .utf8)
            .components(separatedBy: "\n")

        let runtimeFromIndex = try #require(lines.firstIndex(of: "FROM base AS runtime"))
        let copyIndex = try #require(lines.firstIndex(of: "COPY .aib-connections.json ./"))
        // No WORKDIR in `runtime` stage — fall back to immediately after the final FROM.
        #expect(copyIndex == runtimeFromIndex + 1)

        // The early-stage WORKDIR must not pull the COPY back into `base`.
        let baseWorkdirIndex = try #require(lines.firstIndex(of: "WORKDIR /app"))
        #expect(copyIndex > baseWorkdirIndex)
    }

    @Test("Top-stage and runtime-stage instructions land in their respective stages")
    func topAndRuntimeRouteIndependently() throws {
        let dockerfile = """
        FROM node:22-slim AS base
        RUN apt-get update

        FROM base AS deps
        WORKDIR /app
        COPY package.json ./
        RUN pnpm install

        FROM base AS runtime
        WORKDIR /app
        COPY --from=deps /app/node_modules ./node_modules/
        CMD ["node", "dist/index.js"]
        """

        let context = try makeBuildContext(dockerfile: dockerfile)
        defer { try? FileManager.default.removeItem(at: context.directory) }

        let patchedPath = try DefaultDeployExecutor.patchedDockerfilePath(
            dockerfilePath: context.dockerfilePath,
            buildContext: context.directory.path,
            topStageInstructions: ["COPY .aib-build-auth/ /tmp/.aib-build-auth/"],
            runtimeStageInstructions: ["COPY .aib-connections.json ./"],
            preUserInstructions: [],
            preEntrypointInstructions: [],
            appendedInstructions: ["RUN rm -rf /tmp/.aib-build-auth"]
        )
        let lines = try String(contentsOfFile: patchedPath, encoding: .utf8)
            .components(separatedBy: "\n")

        let firstFromIndex = try #require(lines.firstIndex { $0.hasPrefix("FROM ") })
        let topInjectedIndex = try #require(lines.firstIndex(of: "COPY .aib-build-auth/ /tmp/.aib-build-auth/"))
        // Top-stage instruction sits immediately after the very first FROM.
        #expect(topInjectedIndex == firstFromIndex + 1)

        let runtimeFromIndex = try #require(lines.firstIndex(of: "FROM base AS runtime"))
        let runtimeInjectedIndex = try #require(lines.firstIndex(of: "COPY .aib-connections.json ./"))
        #expect(runtimeInjectedIndex > runtimeFromIndex)

        // Appended instruction lands at the bottom.
        let trailing = lines.reversed().first { !$0.isEmpty }
        #expect(trailing == "RUN rm -rf /tmp/.aib-build-auth")
    }

    @Test("Pre-user instructions run before an existing runtime USER")
    func preUserInstructionsRunBeforeExistingUser() throws {
        let dockerfile = """
        FROM node:22-slim AS base
        RUN apt-get update

        FROM base AS runtime
        WORKDIR /app
        COPY --from=base /usr/bin/env /usr/bin/env
        USER node
        CMD ["node", "dist/index.js"]
        """

        let context = try makeBuildContext(dockerfile: dockerfile)
        defer { try? FileManager.default.removeItem(at: context.directory) }

        let patchedPath = try DefaultDeployExecutor.patchedDockerfilePath(
            dockerfilePath: context.dockerfilePath,
            buildContext: context.directory.path,
            topStageInstructions: [],
            runtimeStageInstructions: [],
            preUserInstructions: ["RUN rm -rf /root/.ssh /tmp/.aib-build-auth || true"],
            preEntrypointInstructions: [],
            appendedInstructions: []
        )
        let lines = try String(contentsOfFile: patchedPath, encoding: .utf8)
            .components(separatedBy: "\n")

        let cleanupIndex = try #require(lines.firstIndex(of: "RUN rm -rf /root/.ssh /tmp/.aib-build-auth || true"))
        let userIndex = try #require(lines.firstIndex(of: "USER node"))
        #expect(cleanupIndex == userIndex - 1)
    }

    @Test("Node agent non-root instructions are inserted before CMD when no runtime USER exists")
    func nodeAgentNonRootInstructionsInsertBeforeCommand() throws {
        let dockerfile = """
        FROM node:22-slim AS base
        RUN apt-get update

        FROM base AS runtime
        WORKDIR /app
        COPY --from=base /usr/bin/env /usr/bin/env
        CMD ["node", "dist/index.js"]
        """

        let context = try makeBuildContext(dockerfile: dockerfile)
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let instructions = try DefaultDeployExecutor.nodeAgentNonRootRuntimeInstructions(
            dockerfilePath: context.dockerfilePath
        )

        let patchedPath = try DefaultDeployExecutor.patchedDockerfilePath(
            dockerfilePath: context.dockerfilePath,
            buildContext: context.directory.path,
            topStageInstructions: [],
            runtimeStageInstructions: [],
            preUserInstructions: [],
            preEntrypointInstructions: instructions,
            appendedInstructions: []
        )
        let lines = try String(contentsOfFile: patchedPath, encoding: .utf8)
            .components(separatedBy: "\n")

        let chownIndex = try #require(lines.firstIndex(of: "RUN chown -R node:node /app"))
        let homeIndex = try #require(lines.firstIndex(of: "ENV HOME=/home/node"))
        let userIndex = try #require(lines.firstIndex(of: "USER node"))
        let cmdIndex = try #require(lines.firstIndex(of: "CMD [\"node\", \"dist/index.js\"]"))
        #expect(chownIndex < homeIndex)
        #expect(homeIndex < userIndex)
        #expect(userIndex == cmdIndex - 1)
    }

    @Test("Node agent non-root instructions only add HOME when runtime already uses node")
    func nodeAgentNonRootInstructionsRespectExistingNodeUser() throws {
        let dockerfile = """
        FROM node:22-slim AS runtime
        WORKDIR /app
        COPY package.json ./
        USER node
        CMD ["node", "dist/index.js"]
        """

        let context = try makeBuildContext(dockerfile: dockerfile)
        defer { try? FileManager.default.removeItem(at: context.directory) }

        let instructions = try DefaultDeployExecutor.nodeAgentNonRootRuntimeInstructions(
            dockerfilePath: context.dockerfilePath
        )

        #expect(instructions == ["ENV HOME=/home/node"])
    }

    @Test("Node agent Codex runtime check runs before the runtime user")
    func nodeAgentCodexRuntimeCheckRunsBeforeRuntimeUser() throws {
        let dockerfile = """
        FROM node:22-slim AS runtime
        ARG CODEX_CLI_VERSION=0.130.0
        RUN npm install -g @openai/codex@${CODEX_CLI_VERSION}
        WORKDIR /app
        COPY package.json ./
        USER node
        CMD ["node", "dist/index.js"]
        """

        let context = try makeBuildContext(dockerfile: dockerfile)
        defer { try? FileManager.default.removeItem(at: context.directory) }

        let patchedPath = try DefaultDeployExecutor.patchedDockerfilePath(
            dockerfilePath: context.dockerfilePath,
            buildContext: context.directory.path,
            topStageInstructions: [],
            runtimeStageInstructions: [],
            preUserInstructions: [DefaultDeployExecutor.nodeAgentCodexRuntimeCheckInstruction],
            preEntrypointInstructions: try DefaultDeployExecutor.nodeAgentNonRootRuntimeInstructions(
                dockerfilePath: context.dockerfilePath
            ),
            appendedInstructions: []
        )
        let lines = try String(contentsOfFile: patchedPath, encoding: .utf8)
            .components(separatedBy: "\n")

        let checkIndex = try #require(lines.firstIndex(of: DefaultDeployExecutor.nodeAgentCodexRuntimeCheckInstruction))
        let userIndex = try #require(lines.firstIndex(of: "USER node"))
        let homeIndex = try #require(lines.firstIndex(of: "ENV HOME=/home/node"))
        #expect(checkIndex == userIndex - 1)
        #expect(homeIndex > userIndex)
        #expect(DefaultDeployExecutor.nodeAgentCodexRuntimeCheckInstruction.contains("Codex app-server smoke timed out"))
        #expect(DefaultDeployExecutor.nodeAgentCodexRuntimeCheckInstruction.contains(#""app-server", "--listen", "stdio://""#))
    }

    @Test("Idempotent: re-patching a file containing the same instructions is a no-op")
    func patchIsIdempotent() throws {
        let dockerfile = """
        FROM node:22-slim
        WORKDIR /app
        COPY .aib-connections.json ./
        CMD ["node", "dist/index.js"]
        """

        let context = try makeBuildContext(dockerfile: dockerfile)
        defer { try? FileManager.default.removeItem(at: context.directory) }

        let returnedPath = try DefaultDeployExecutor.patchedDockerfilePath(
            dockerfilePath: context.dockerfilePath,
            buildContext: context.directory.path,
            topStageInstructions: [],
            runtimeStageInstructions: ["COPY .aib-connections.json ./"],
            appendedInstructions: []
        )
        // Nothing was missing → original Dockerfile path is returned unchanged.
        #expect(returnedPath == context.dockerfilePath)
    }

    // MARK: - Helpers

    private struct BuildContext {
        let directory: URL
        let dockerfilePath: String
    }

    private func makeBuildContext(dockerfile: String) throws -> BuildContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DockerfilePatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dockerfileURL = directory.appendingPathComponent("Dockerfile")
        try dockerfile.write(to: dockerfileURL, atomically: true, encoding: .utf8)
        return BuildContext(directory: directory, dockerfilePath: dockerfileURL.path)
    }
}

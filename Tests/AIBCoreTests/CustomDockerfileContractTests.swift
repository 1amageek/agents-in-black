@testable import AIBCore
import AIBRuntimeCore
import AIBWorkspace
import Testing

@Test(.timeLimit(.minutes(1)))
func customDockerfileRejectsNPMForPNPMManagedService() {
    let dockerfile = AIBDeployArtifact(
        relativePath: "valuemap-mcp/Dockerfile.node",
        content: """
        FROM node:22-slim
        WORKDIR /app
        COPY package*.json ./
        RUN npm ci
        """,
        source: .custom
    )

    do {
        try AIBDeployService.validateCustomDockerfileContract(
            serviceID: "valuemap-mcp/main",
            packageManager: .pnpm,
            dockerfile: dockerfile,
            sourceDependencies: [],
            providerID: "gcp-cloudrun"
        )
        Issue.record("Expected pnpm-managed service to reject npm-based custom Dockerfile installs.")
    } catch let error as AIBDeployError {
        #expect(error.phase == "plan")
        #expect(error.message.contains("pnpm-managed"))
        #expect(error.message.contains("npm ci"))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test(.timeLimit(.minutes(1)))
func customDockerfileRejectsLaterStageInstallForPrivateGitDependencies() {
    let dockerfile = AIBDeployArtifact(
        relativePath: "valuemap-mcp/Dockerfile.node",
        content: """
        FROM node:22-slim AS deps
        RUN apt-get update && apt-get install -y --no-install-recommends git openssh-client
        RUN corepack enable
        WORKDIR /app
        COPY package.json pnpm-lock.yaml ./
        RUN pnpm install --frozen-lockfile

        FROM deps AS prod-deps
        RUN pnpm install --prod --frozen-lockfile
        """,
        source: .custom
    )
    let sourceDependencies = [
        AIBSourceDependencyFinding(
            sourceFile: "package.json",
            requirement: "github:salescore-inc/valuemap-api",
            host: "github.com",
            auth: .ssh
        ),
    ]

    do {
        try AIBDeployService.validateCustomDockerfileContract(
            serviceID: "valuemap-mcp/main",
            packageManager: .pnpm,
            dockerfile: dockerfile,
            sourceDependencies: sourceDependencies,
            providerID: "gcp-cloudrun"
        )
        Issue.record("Expected later-stage dependency installs to be rejected for private Git dependencies.")
    } catch let error as AIBDeployError {
        #expect(error.phase == "plan")
        #expect(error.message.contains("re-installs dependencies in a later stage"))
        #expect(error.message.contains("copy node_modules"))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test(.timeLimit(.minutes(1)))
func customDockerfileAcceptsSingleStageInstallAndPruneForPrivateGitDependencies() throws {
    let dockerfile = AIBDeployArtifact(
        relativePath: "valuemap-mcp/Dockerfile.node",
        content: """
        FROM node:22-slim AS deps
        RUN apt-get update && apt-get install -y --no-install-recommends git openssh-client
        RUN corepack enable
        WORKDIR /app
        COPY package.json pnpm-lock.yaml ./
        RUN pnpm install --frozen-lockfile

        FROM deps AS build
        COPY tsconfig.json ./
        COPY src ./src
        RUN pnpm run build

        FROM build AS prod-deps
        RUN pnpm prune --prod

        FROM node:22-slim AS runtime
        WORKDIR /app
        COPY --from=prod-deps /app/node_modules ./node_modules
        COPY --from=build /app/dist ./dist
        COPY package.json ./
        CMD ["node", "dist/index.js"]
        """,
        source: .custom
    )
    let sourceDependencies = [
        AIBSourceDependencyFinding(
            sourceFile: "package.json",
            requirement: "github:salescore-inc/valuemap-api",
            host: "github.com",
            auth: .ssh
        ),
    ]

    try AIBDeployService.validateCustomDockerfileContract(
        serviceID: "valuemap-mcp/main",
        packageManager: .pnpm,
        dockerfile: dockerfile,
        sourceDependencies: sourceDependencies,
        providerID: "gcp-cloudrun"
    )
}

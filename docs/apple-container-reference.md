# apple/container Swift API Reference

Apple's `container` is an OCI-compatible Linux container runtime for macOS.
Each container runs in its own lightweight VM using the Virtualization framework.
Written in Swift, optimized for Apple Silicon.

- Repository: https://github.com/apple/container
- API Docs: https://apple.github.io/container/documentation/
- Swift Package: `ContainerAPIClient` (product of `apple/container`)
- Latest Version: **0.10.0** (Feb 2026)
- swift-tools-version: 6.2
- Depends on: `apple/containerization` 0.26.3
- Requirements: Apple Silicon + macOS 15+ (macOS 26+ recommended for full features)
- Daemon: `container system start` must be running

## Architecture

Each container = 1 lightweight Linux VM (not shared VM).
Communication: CLI → `ContainerClient` library → XPC → `container-apiserver` → per-container `container-runtime-linux` helper.

Key properties:
- VM-level isolation per container (filesystem, network, process space)
- OCI-compatible images (pull/push from any registry)
- VirtioFS for host file sharing
- vmnet framework for networking
- XPC for IPC, Launchd for service management

## Swift Package Integration

```swift
// Package.swift
.package(url: "https://github.com/apple/container.git", from: "0.10.0"),

// Target dependency — the client library product
.product(name: "ContainerAPIClient", package: "container"),
```

`import ContainerAPIClient` to use the types below.

## Core Types

### ContainerConfiguration

Container setup. Passed to `ContainerClient.create()`.

```swift
struct ContainerConfiguration: Codable, Sendable {
    init(id: String, image: ImageDescription, process: ProcessConfiguration)

    var id: String                                  // Unique container identifier
    var image: ImageDescription                     // OCI image reference
    var initProcess: ProcessConfiguration           // Main process configuration
    var mounts: [Filesystem]                        // VirtioFS / block / tmpfs mounts
    var networks: [String]                          // Network names (default: ["default"])
    var resources: Resources                        // CPU, memory, storage
    var labels: [String: String]                    // Key/value labels
    var hostname: String?                           // Container hostname
    var rosetta: Bool                               // Enable x86-64 translation
    var dns: DNSConfiguration?                      // DNS settings
    var sysctls: [String: String]                   // Kernel parameters
    var platform: Platform                          // Target platform
    var runtimeHandler: String                      // Runtime name
}
```

#### ContainerConfiguration.Resources

```swift
struct Resources: Codable, Sendable {
    var cpus: Int              // CPU cores (default: 4)
    var memoryInBytes: UInt64  // Memory in bytes (default: 1 GiB)
    var storage: UInt64?       // Storage quota in bytes
}
```

### ProcessConfiguration

Executable process configuration inside a container.

```swift
struct ProcessConfiguration: Codable, Sendable {
    init(
        executable: String,
        arguments: [String],
        environment: [String],          // "KEY=VALUE" format
        workingDirectory: String,
        terminal: Bool,
        user: User,
        supplementalGroups: [UInt32],
        rlimits: [Rlimit]
    )

    var executable: String              // Path to binary inside container
    var arguments: [String]             // Arguments
    var environment: [String]           // ["PORT=8080", "NODE_ENV=production"]
    var workingDirectory: String        // CWD inside container
    var terminal: Bool                  // Attach PTY
    var user: User                      // Run as user
    var rlimits: [Rlimit]              // Resource limits
}
```

**Important**: `environment` is `[String]` not `[String: String]`. Each entry is `"KEY=VALUE"`.

### Filesystem

Host filesystem mounts attached to the container.

```swift
struct Filesystem: Codable, Sendable {
    var type: FSType            // .virtiofs, .block, .tmpfs
    var source: String          // Host path (for virtiofs/block)
    var destination: String     // Mount point inside container
    var options: MountOptions   // Mount options

    var isVirtiofs: Bool
    var isBlock: Bool
    var isTmpfs: Bool

    // Factory methods
    static func virtiofs(source: String, destination: String, options: MountOptions) -> Filesystem
    static func block(format: String, source: String, destination: String, options: MountOptions, cache: CacheMode, sync: SyncMode) -> Filesystem
    static func tmpfs(destination: String, options: MountOptions) -> Filesystem

    func clone(to: String) throws -> Filesystem
}
```

### ContainerClient (0.10.0 — reworked)

Generic client for all container operations. Holds a reusable XPC connection.
In 0.10.0, the old `ClientContainer` per-instance type was removed and replaced with this
stateless client where every method takes an `id` parameter.

```swift
struct ContainerClient: Sendable {
    init()  // Creates XPC connection to container-apiserver

    // Lifecycle
    func create(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions = .default,
        kernel: Kernel,
        initImage: String? = nil
    ) async throws

    func bootstrap(id: String, stdio: [FileHandle?]) async throws -> ClientProcess
    func stop(id: String, opts: ContainerStopOptions = .default) async throws
    func delete(id: String, force: Bool = false) async throws
    func kill(id: String, signal: Int32) async throws

    // Query
    func list(filters: ContainerListFilters = .all) async throws -> [ContainerSnapshot]
    func get(id: String) async throws -> ContainerSnapshot

    // Process management
    func createProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws -> ClientProcess

    // I/O
    func logs(id: String) async throws -> [FileHandle]
    func dial(id: String, port: UInt32) async throws -> FileHandle

    // Stats
    func stats(id: String) async throws -> ContainerStats
    func diskUsage(id: String) async throws -> UInt64

    // Export
    func export(id: String, archive: URL) async throws
}
```

**Key differences from pre-0.10.0:**
- `ContainerClient` is instantiated once and reused (holds XPC connection)
- `create()` returns `Void` (not a container handle) — use `get(id:)` to query state
- `bootstrap()` takes `stdio` parameter directly and returns `ClientProcess`
- All methods take `id: String` to identify the target container

### ContainerCreateOptions

```swift
struct ContainerCreateOptions: Codable, Sendable {
    init(autoRemove: Bool)
    let autoRemove: Bool
    static let `default`: ContainerCreateOptions
}
```

### ContainerStopOptions

```swift
struct ContainerStopOptions: Codable, Sendable {
    init(timeoutInSeconds: Int32, signal: Int32)
    let timeoutInSeconds: Int32
    let signal: Int32
    static let `default`: ContainerStopOptions
}
```

### ClientProcess (protocol)

A process running inside a container.

```swift
protocol ClientProcess: Sendable {
    var id: String { get }
    func start(_ stdio: [FileHandle?]) async throws
    func wait() async throws -> Int32       // Blocks until exit, returns exit code
    func kill(_ signal: Int32) async throws
    func resize(_ size: Terminal.Size) async throws
}
```

### RuntimeStatus

```swift
enum RuntimeStatus: String, CaseIterable, Codable, Sendable {
    case unknown
    case stopped
    case running
}
```

### ClientImage

OCI image management.

```swift
struct ClientImage: Sendable {
    let description: ImageDescription
    var reference: String
    var digest: String

    // Pull / Fetch
    static func pull(reference: String, platform: Platform?, scheme: RequestScheme, progressUpdate: ProgressUpdateHandler?) async throws -> ClientImage
    static func fetch(reference: String, platform: Platform?, scheme: RequestScheme, progressUpdate: ProgressUpdateHandler?) async throws -> ClientImage

    // Query
    static func get(reference: String) async throws -> ClientImage
    static func list() async throws -> [ClientImage]

    // Build artifacts
    func unpack(platform: Platform?, progressUpdate: ProgressUpdateHandler?) async throws
    func getCreateSnapshot(platform: Platform, progressUpdate: ProgressUpdateHandler?) async throws -> Filesystem

    // Registry operations
    func push(platform: Platform?, scheme: RequestScheme, progressUpdate: ProgressUpdateHandler?) async throws
    func tag(new: String) async throws -> ClientImage
    func save(out: String, platform: Platform?) async throws

    // Lifecycle
    static func delete(reference: String, garbageCollect: Bool) async throws
    static func load(from: String) async throws -> [ClientImage]
    static func pruneImages() async throws -> ([String], UInt64)
}
```

### ImageDescription

```swift
struct ImageDescription: Codable, Sendable
// Represents an OCI image reference that can be used with sandboxes or containers.
```

### ClientHealthCheck

```swift
struct ClientHealthCheck {
    static func ping(timeout: Duration?) async throws
}
```

Check if the `container-apiserver` daemon is running.

### ClientNetwork

```swift
struct ClientNetwork {
    static let defaultNetworkName: String

    static func create(configuration: NetworkConfiguration) async throws -> NetworkState
    static func get(id: String) async throws -> NetworkState
    static func list() async throws -> [NetworkState]
    static func delete(id: String) async throws
}
```

### SandboxClient

Lower-level interface for sandbox (VM) management. Used internally by `ContainerClient`.

```swift
struct SandboxClient: Codable, Sendable {
    init(id: String, runtime: String)

    func bootstrap() async throws
    func createProcess(_ id: String, config: ProcessConfiguration) async throws
    func startProcess(_ id: String, stdio: [FileHandle?]) async throws
    func stop(options: ContainerStopOptions) async throws
    func kill(_ id: String, signal: Int64) async throws
    func wait(_ id: String) async throws -> Int32
    func dial(_ port: UInt32) async throws -> FileHandle
    func state() async throws -> SandboxSnapshot
    func resize(_ id: String, size: Terminal.Size) async throws
}
```

### ContainerSnapshot

```swift
struct ContainerSnapshot: Codable, Sendable {
    let configuration: ContainerConfiguration
    let status: RuntimeStatus
    let networks: [Attachment]
}
```

## Container Lifecycle

### 1. Create and Run

```swift
import ContainerAPIClient

// 1. Create a reusable client (holds XPC connection)
let client = ContainerClient()

// 2. Ensure daemon is running
try await ClientHealthCheck.ping(timeout: .seconds(5))

// 3. Pull or fetch the image
let image = try await ClientImage.pull(
    reference: "docker.io/node:22-alpine",
    platform: nil,
    scheme: .https,
    progressUpdate: nil
)

// 4. Configure the process
let process = ProcessConfiguration(
    executable: "/usr/local/bin/node",
    arguments: ["server.js"],
    environment: [
        "PORT=8080",
        "NODE_ENV=production"
    ],
    workingDirectory: "/app",
    terminal: false,
    user: .root,
    supplementalGroups: [],
    rlimits: []
)

// 5. Configure the container
let containerID = "my-service"
var config = ContainerConfiguration(
    id: containerID,
    image: image.description,
    process: process
)
config.resources.cpus = 2
config.resources.memoryInBytes = 512 * 1024 * 1024  // 512 MiB

// 6. Add VirtioFS mount for source code
config.mounts = [
    .virtiofs(
        source: "/Users/dev/my-project/src",
        destination: "/app",
        options: []       // read-write by default
    )
]

// 7. Create the container (returns Void)
try await client.create(configuration: config, kernel: .default)

// 8. Bootstrap — starts the VM and init process, returns ClientProcess
let stdoutPipe = Pipe()
let stderrPipe = Pipe()
let initProcess = try await client.bootstrap(
    id: containerID,
    stdio: [nil, stdoutPipe.fileHandleForWriting, stderrPipe.fileHandleForWriting]
)

// 9. Wait for exit (blocking async)
let exitCode = try await initProcess.wait()
```

### 2. Capture Logs

```swift
// Get stdout/stderr log handles
let handles = try await client.logs(id: containerID)
// handles[0] = stdout, handles[1] = stderr

// Read asynchronously
for handle in handles {
    Task {
        let data = handle.availableData
        // Process log data...
    }
}
```

### 3. Execute Additional Process

```swift
let execConfig = ProcessConfiguration(
    executable: "/bin/sh",
    arguments: ["-c", "ls -la /app"],
    environment: ["PATH=/usr/local/bin:/usr/bin:/bin"],
    workingDirectory: "/app",
    terminal: false,
    user: .root,
    supplementalGroups: [],
    rlimits: []
)

let execProcess = try await client.createProcess(
    containerId: containerID,
    processId: "exec-ls",
    configuration: execConfig,
    stdio: [nil, nil, nil]
)
let code = try await execProcess.wait()
```

### 4. Port Forwarding (dial)

```swift
// Connect to container port 8080 from the host via vsock
let fileHandle = try await client.dial(id: containerID, port: 8080)
// fileHandle is a bidirectional socket to the container port
```

Note: For CLI usage, `--publish` / `-p` provides host-to-container port forwarding:
```bash
container run -d --rm -p 127.0.0.1:8080:8000 node:latest npx http-server -p 8000
```

### 5. Stop and Cleanup

```swift
// Graceful stop with timeout
try await client.stop(id: containerID)
// or with custom timeout and signal
try await client.stop(id: containerID, opts: ContainerStopOptions(timeoutInSeconds: 10, signal: 15))

// Delete container resources
try await client.delete(id: containerID)
// or force delete
try await client.delete(id: containerID, force: true)

// Or send a signal directly
try await client.kill(id: containerID, signal: SIGTERM)
```

### 6. Auto-Remove

```swift
// Container auto-removes when stopped
try await client.create(
    configuration: config,
    options: ContainerCreateOptions(autoRemove: true),
    kernel: .default
)
```

## VirtioFS Mounts

Share host directories with the container. Changes on the host are immediately visible inside the container and vice versa.

```swift
// Read-write mount (default)
let mount = Filesystem.virtiofs(
    source: "/Users/dev/project",      // Host path (absolute)
    destination: "/app",                // Container mount point
    options: []
)

// Read-only mount
let roMount = Filesystem.virtiofs(
    source: "/Users/dev/config",
    destination: "/etc/app-config",
    options: ["ro"]
)

// Tmpfs (in-memory, no host backing)
let tmpMount = Filesystem.tmpfs(
    destination: "/tmp",
    options: []
)

config.mounts = [mount, roMount, tmpMount]
```

CLI equivalent:
```bash
container run --volume /Users/dev/project:/app my-image
```

## Networking

### Port Publishing (CLI)

```bash
# Forward host 8080 → container 8000
container run -p 127.0.0.1:8080:8000 node:latest npx http-server -p 8000

# IPv6
container run -p '[::1]:8080:8000' node:latest npx http-server -p 8000
```

### Host Service Access from Container

```bash
# Create DNS domain for host access
sudo container system dns create host.container.internal --localhost 203.0.113.113

# Container can now access host services
container run --rm alpine/curl curl http://host.container.internal:8000
```

### Container-to-Container (macOS 26+)

Containers on the same network can communicate via their hostnames:
```bash
container run -d --name db --network default postgres:latest
container run --rm --network default alpine/curl curl http://db.test:5432
```

### API: dial()

```swift
// Connect to a port inside the container via vsock
let handle = try await client.dial(id: containerID, port: 8080)
// Returns a FileHandle for bidirectional TCP communication
```

## Image Management

### Pull

```swift
let image = try await ClientImage.pull(
    reference: "docker.io/python:3.12-alpine",
    platform: nil,          // Auto-detect
    scheme: .https,
    progressUpdate: nil
)
```

### Build (CLI)

```bash
container build -f Dockerfile -t my-app:latest .

# Multi-arch
container build --arch arm64 --arch amd64 -t my-app:latest .
```

### Query

```swift
// Get existing image
let image = try await ClientImage.get(reference: "my-app:latest")

// List all images
let images = try await ClientImage.list()

// Tag
let tagged = try await image.tag(new: "my-app:v2")
```

## Resource Configuration

### CLI

```bash
container run --cpus 8 --memory 32g my-image
```

### Swift API

```swift
var config = ContainerConfiguration(id: "my-svc", image: desc, process: proc)
config.resources.cpus = 4
config.resources.memoryInBytes = 2 * 1024 * 1024 * 1024  // 2 GiB
```

## Error Handling

All async methods throw `ContainerizationError`. Key error scenarios:
- Daemon not running: `ClientHealthCheck.ping()` fails
- Image not found: `ClientImage.get()` / `pull()` throws
- Container already exists: `client.create()` with duplicate ID throws
- Container not found: `client.get(id:)` throws `.notFound`
- Container not running: `bootstrap()`, `stop()` on wrong state throws

## CLI Quick Reference

```bash
# System
container system start              # Start daemon
container system stop               # Stop daemon
container system logs               # View system logs

# Images
container image pull <ref>          # Pull image
container image list                # List images
container build -t <tag> .          # Build from Dockerfile

# Containers
container run [opts] <image> [cmd]  # Create + run
container create [opts] <image>     # Create only
container start <name>              # Start created container
container stop <name>               # Graceful stop
container rm <name>                 # Remove
container list                      # List containers
container logs <name>               # View stdout/stderr
container inspect <name>            # JSON details
container stats                     # Resource usage

# Options
-d                                  # Detached mode
--rm                                # Auto-remove on stop
--name <name>                       # Container name
-p <host>:<container>               # Port publish
--volume <host>:<container>         # VirtioFS mount
--cpus <n>                          # CPU cores
--memory <size>                     # Memory limit
--network <name>                    # Network attachment
--ssh                               # Mount SSH agent
--init                              # Use init process
```

# apple/container Swift API Reference

Apple's `container` is an OCI-compatible Linux container runtime for macOS.
Each container runs in its own lightweight VM using the Virtualization framework.
Written in Swift, optimized for Apple Silicon.

- Repository: https://github.com/apple/container
- API Docs: https://apple.github.io/container/documentation/
- Swift Package: `ContainerClient` (product of `apple/container`)
- Requirements: Apple Silicon + macOS 26+
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

// Target dependency
.product(name: "ContainerClient", package: "container"),
```

## Core Types

### ContainerConfiguration

Container setup. Passed to `ClientContainer.create()`.

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

### ClientContainer

Represents a running or created container. Primary interface for container lifecycle.

```swift
struct ClientContainer: Codable, Sendable {
    let configuration: ContainerConfiguration
    var id: String
    let status: RuntimeStatus               // .unknown, .stopped, .running
    var initProcess: any ClientProcess
    let networks: [Attachment]
    var platform: Platform

    // Lifecycle
    static func create(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions,
        kernel: Kernel
    ) async throws -> ClientContainer

    func bootstrap() async throws -> any ClientProcess
    func stop(opts: ContainerStopOptions) async throws
    func delete() async throws
    func kill(_ signal: Int32) async throws

    // Process management
    func createProcess(id: String, configuration: ProcessConfiguration) async throws -> any ClientProcess

    // I/O
    func logs() async throws -> [FileHandle]
    func dial(_ port: UInt32) async throws -> FileHandle

    // Query
    static func get(id: String) async throws -> ClientContainer
    static func list() async throws -> [ClientContainer]
}
```

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

Lower-level interface for sandbox (VM) management. Used internally by `ClientContainer`.

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
import ContainerClient

// 1. Ensure daemon is running
try await ClientHealthCheck.ping(timeout: .seconds(5))

// 2. Pull or fetch the image
let image = try await ClientImage.pull(
    reference: "docker.io/node:22-alpine",
    platform: nil,
    scheme: .https,
    progressUpdate: nil
)

// 3. Configure the process
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

// 4. Configure the container
var config = ContainerConfiguration(
    id: "my-service",
    image: image.description,
    process: process
)
config.resources.cpus = 2
config.resources.memoryInBytes = 512 * 1024 * 1024  // 512 MiB

// 5. Add VirtioFS mount for source code
config.mounts = [
    .virtiofs(
        source: "/Users/dev/my-project/src",
        destination: "/app",
        options: []       // read-write by default
    )
]

// 6. Create the container
let container = try await ClientContainer.create(
    configuration: config,
    options: .default,
    kernel: .default
)

// 7. Bootstrap (start the VM init process)
let initProcess = try await container.bootstrap()

// 8. Start the process with stdio handles
try await initProcess.start([nil, nil, nil])  // stdin, stdout, stderr

// 9. Wait for exit (blocking)
let exitCode = try await initProcess.wait()
```

### 2. Capture Logs

```swift
// Get stdout/stderr log handles
let handles = try await container.logs()
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

let execProcess = try await container.createProcess(
    id: "exec-ls",
    configuration: execConfig
)
try await execProcess.start([nil, nil, nil])
let code = try await execProcess.wait()
```

### 4. Port Forwarding (dial)

```swift
// Connect to container port 8080 from the host
let fileHandle = try await container.dial(8080)
// fileHandle is a bidirectional socket to the container port
```

Note: For CLI usage, `--publish` / `-p` provides host-to-container port forwarding:
```bash
container run -d --rm -p 127.0.0.1:8080:8000 node:latest npx http-server -p 8000
```

### 5. Stop and Cleanup

```swift
// Graceful stop with timeout
try await container.stop(opts: .default)
// or with custom timeout and signal
try await container.stop(opts: ContainerStopOptions(timeoutInSeconds: 10, signal: 15))

// Delete container resources
try await container.delete()

// Or send a signal directly
try await container.kill(SIGTERM)
```

### 6. Auto-Remove

```swift
// Container auto-removes when stopped
let container = try await ClientContainer.create(
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
// Connect to a port inside the container
let handle = try await container.dial(8080)
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

All async methods throw errors. Key error scenarios:
- Daemon not running: `ClientHealthCheck.ping()` fails
- Image not found: `ClientImage.get()` / `pull()` throws
- Container already exists: `ClientContainer.create()` with duplicate ID throws
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

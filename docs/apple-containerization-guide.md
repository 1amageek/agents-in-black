# Apple Containerization Framework Guide

Apple の `Containerization` フレームワークは、Apple Silicon Mac 上で Linux コンテナを軽量仮想マシン（VM）内で実行するための Swift ライブラリおよび CLI ツールセットである。`Virtualization.framework` を活用し、コンテナごとに独立した VM を割り当てる「VM-per-container」モデルにより、強力なアイソレーションと高速な起動を実現する。

- リポジトリ: https://github.com/apple/containerization

## System Requirements

| 要件 | 内容 |
|---|---|
| Hardware | Apple Silicon Mac (arm64) |
| OS | macOS 26 以上 |
| Xcode | Xcode 26 以上 |
| Swift | Swift 6.2.3 以上 |
| Entitlement | `com.apple.security.virtualization` |
| Linux Kernel | 6.14.9 以上（プロジェクト同梱のカーネルあり） |

## Build from Source

### 1. 環境準備

```bash
# Xcode のアクティブ開発ディレクトリを設定
sudo xcode-select -s <PATH_TO_XCODE>

# Swiftly, Swift, Static Linux SDK をインストール
make cross-prep
```

`make cross-prep` は `vminitd/Makefile` 内の `cross-prep` ターゲットを実行し、Swiftly 経由で Swift をインストールし、Static Linux SDK をセットアップする。

### 2. ビルド

```bash
make all
```

`make all` は以下を実行する:
- `containerization` ターゲット: `cctl` CLI と `containerization-integration` バイナリをビルド
- `init` ターゲット: `vminitd` と `vmexec` バイナリからルートファイルシステム (`init.rootfs.tar.gz`) と OCI イメージ (`vminit:latest`) を生成

### 3. テスト（オプション）

```bash
# デフォルトカーネルを取得（インテグレーションテストに必要）
make fetch-default-kernel

# ユニットテスト + インテグレーションテスト
make test integration
```

### 4. Protocol Buffers 再生成（オプション）

```bash
make protos
```

### 5. カスタムカーネルのビルド（オプション）

`kernel` ディレクトリの手順に従う。Kata Containers の Pre-built カーネル（VIRTIO ドライバ組み込み済み）も使用可能。

### その他の開発コマンド

```bash
# API ドキュメント生成 → http://localhost:8000/containerization/documentation/
make docs
make serve-docs

# コードフォーマット
make fmt

# ライセンスヘッダー追加
make update-licenses
```

## Architecture Overview

### System Flow

```
Host (macOS)                          Guest (Linux VM)
┌──────────────────────┐              ┌──────────────────────┐
│ LinuxContainer /     │   vsock      │ vminitd (PID 1)      │
│ LinuxPod             │◄────────────►│   gRPC server        │
│                      │  port 1024   │   (SandboxContext)   │
│ VZVirtualMachine     │              │                      │
│ Manager              │   vsock      │ vmexec               │
│                      │◄────────────►│   (OCI runtime)      │
│ Virtualization       │  dynamic     │                      │
│ .framework           │  ports       │ Container Process    │
└──────────────────────┘              └──────────────────────┘
```

### Host-Side Components

| コンポーネント | 役割 |
|---|---|
| `LinuxContainer` | 単一コンテナの VM ライフサイクル管理 |
| `LinuxPod` | 複数コンテナを共有 VM 内で管理（experimental） |
| `ContainerManager` | コンテナ生成のファクトリ。ネットワーク・ストレージ設定 |
| `VZVirtualMachineManager` | `Virtualization.framework` の VM プロビジョニング |
| `LinuxProcess` | コンテナ内プロセスの I/O とライフサイクル管理 |

### Guest-Side Components

| コンポーネント | 役割 |
|---|---|
| `vminitd` | PID 1 として動作する init システム。vsock port 1024 で gRPC サーバーを公開 |
| `vmexec` | カスタム OCI ランタイム。namespace セットアップ、pivot_root、execve を実行 |

### Lifecycle Flow

1. **VM Creation** — `LinuxContainer.create()` → `VZVirtualMachineManager` が VM を構成・起動 → カーネルが `vminitd` を PID 1 として起動
2. **Environment Setup** — ホストが vsock 経由で `vminitd` に接続 → `/tmp`, `/dev/pts`, ルートファイルシステムのマウント、ネットワーク設定
3. **Process Creation** — 動的 vsock ポートを確保（stdin/stdout/stderr 用）→ `vminitd` に `createProcess` リクエスト送信
4. **Process Start** — `vminitd` が `vmexec` を fork/exec → namespace セットアップ、pivot_root、コンテナプロセス実行
5. **Execution** — I/O は vsock ポート経由でリレー。`ProcessSupervisor` が SIGCHLD を監視
6. **Cleanup** — プロセス終了 → `deleteProcess` → OCI バンドルと cgroup をクリーンアップ → VM 停止

## Communication (Host ↔ Guest)

3 つの通信パターンがある:

| パターン | vsock ポート | 用途 |
|---|---|---|
| Control Plane | 1024（固定） | gRPC 管理操作（createProcess, startProcess, waitProcess 等） |
| Data Plane (stdio) | 動的割り当て | stdin/stdout/stderr のリレー（プロセスごとに 3 ポート） |
| Unix Socket Relay | 動的割り当て | ホスト ↔ ゲスト間の Unix ソケット双方向リレー |

## CLI: `cctl`

`cctl` は Swift 製の CLI ツールで、コンテナの実行、イメージ管理、ルートファイルシステム管理を提供する。

### `cctl run` — コンテナ実行

```bash
cctl run -k <kernel_path> [options] [arguments...]
```

| フラグ | デフォルト | 説明 |
|---|---|---|
| `-k`, `--kernel <path>` | （必須） | カーネルバイナリのパス |
| `-i`, `--image <ref>` | `docker.io/library/alpine:3.16` | ベースイメージ |
| `--id <id>` | `cctl` | コンテナ ID |
| `-c`, `--cpus <count>` | `2` | CPU 数 |
| `-m`, `--memory <MB>` | `1024` | メモリ（MB） |
| `--fs-size <MB>` | `2048` | ファイルシステムサイズ（MB） |
| `--rosetta` | — | Rosetta x64 エミュレーション有効化 |
| `--mount <host:guest>` | — | ディレクトリマウント |
| `--ip <addr/subnet>` | — | IP アドレス |
| `--gateway <addr>` | — | ゲートウェイ |
| `--ns <addr...>` | — | ネームサーバー |
| `--oci-runtime <path>` | — | OCI ランタイムパス |
| `--cwd <path>` | `/` | ワーキングディレクトリ |
| `[arguments...]` | `/bin/sh` | エントリポイントの引数 |

例:

```bash
cctl run -k /path/to/vmlinux -i docker.io/library/ubuntu:24.04 --cpus 4 --memory 2048 /bin/bash
```

### `cctl images` — イメージ管理

```bash
# イメージ一覧
cctl images

# イメージ pull
cctl images pull <ref> [--platform <os/arch/variant>] [--unpack-path <path>] [--http]

# イメージ push
cctl images push <ref> [--platform <os/arch/variant>] [--http]

# イメージ削除
cctl images delete <ref>

# イメージ情報
cctl images get <ref>

# タグ付け
cctl images tag <old> <new>

# tar にエクスポート
cctl images save -o <output> <ref...> [--platform <os/arch/variant>]

# tar からインポート
cctl images load -i <input>
```

### `cctl login` — レジストリ認証

```bash
cctl login <server> [-u <username>] [--password-stdin] [--http]
```

| フラグ | 説明 |
|---|---|
| `<server>` | レジストリホスト名（例: `docker.io`, `ghcr.io`） |
| `-u`, `--username <name>` | ユーザー名 |
| `--password-stdin` | 標準入力からパスワードを読み取り |
| `--http` | HTTPS ではなく HTTP を使用 |

### `cctl rootfs` — ルートファイルシステム管理

```bash
cctl rootfs create --vminitd <path> --vmexec <path> <tarPath> \
  [--ext4 <path>] [--image <name>] [--label <key=value>] \
  [--add-file <src:dst>] [--oci-runtime <path>] [--platform <platform>]
```

## Swift API

### LinuxContainer — 単一コンテナ

1 つのコンテナにつき 1 つの専用 VM を割り当てる。強力なアイソレーションが必要なワークロード向け。

```swift
import Containerization

let container = try LinuxContainer("my-container", rootfs: rootfs, vmm: vmm) { config in
    // Process
    config.process.arguments = ["/bin/bash", "-c", "echo Hello"]
    config.process.terminal = true

    // Resources
    config.cpus = 2
    config.memoryInBytes = 512.mib()

    // Networking
    config.interfaces = [NATInterface()]

    // Mounts
    config.mounts.append(Mount(source: "/tmp/host", destination: "/mnt/host"))

    // DNS
    config.dns = DNS(nameservers: ["8.8.8.8"], searches: ["example.com"])
}

// Lifecycle
try await container.create()
try await container.start()

// Exec additional process
let proc = try await container.exec("exec-1") { config in
    config.arguments = ["/bin/sh", "-c", "hostname"]
    config.stdout = BufferWriter()
}
try await proc.start()
let status = try await proc.wait()
try await proc.delete()

// Wait and cleanup
let exitStatus = try await container.wait()
try await container.stop()
```

### LinuxPod — 複数コンテナ（Experimental）

複数のコンテナが 1 つの VM を共有する。リソース効率と内部通信の最適化が求められるケース向け。

```swift
import Containerization

let pod = try LinuxPod("my-pod", vmm: vmm) { config in
    // VM-level resources (shared)
    config.cpus = 4
    config.memoryInBytes = 1024.mib()

    // Networking (shared by all containers)
    config.interfaces = [NATInterface()]

    // PID namespace sharing (optional)
    config.shareProcessNamespace = true
}

// Add containers
try await pod.addContainer("web", rootfs: webRootfs) { config in
    config.process.arguments = ["/usr/sbin/nginx", "-g", "daemon off;"]
    config.cpus = 1
    config.memoryInBytes = 256.mib()
}

try await pod.addContainer("db", rootfs: dbRootfs) { config in
    config.process.arguments = ["/usr/bin/postgres"]
    config.cpus = 2
    config.memoryInBytes = 512.mib()
}

// Lifecycle
try await pod.create()
try await pod.startContainer("web")
try await pod.startContainer("db")

// Statistics
let stats = try await pod.statistics()

// Cleanup
try await pod.stopContainer("web")
try await pod.stopContainer("db")
try await pod.stop()
```

### LinuxContainer vs LinuxPod

| 項目 | LinuxContainer | LinuxPod |
|---|---|---|
| VM 割り当て | 1 コンテナ = 1 VM | 複数コンテナ = 1 VM |
| アイソレーション | 完全（VM レベル） | コンテナ間で VM リソース共有 |
| リソース制御 | VM 単位で CPU/メモリ設定 | VM レベル + コンテナごとの cgroup 制限 |
| ファイルシステム | `/run/container/{id}/rootfs` | コンテナごとに個別 rootfs |
| PID Namespace | 独立 | `shareProcessNamespace` で共有可能 |
| ネットワーク | 専用 | Pod 内で共有 |
| ステータス | Stable | Experimental |

## Networking

### NATInterface

NAT 経由で外部ネットワークにアクセスする。`Virtualization.framework` の `VZNATNetworkDeviceAttachment` を使用。

```swift
let nat = NATInterface()
// or with explicit configuration:
// nat.ipv4Address = CIDRv4(...)
// nat.ipv4Gateway = IPv4Address(...)
// nat.macAddress = ...
```

### VmnetNetwork.Interface

`vmnet` ベースのホストネットワーキング。コンテナごとに専用 IP を割り当て可能。ポートフォワーディング不要。

### Guest-Side Network Configuration (vminitd gRPC API)

| API | 説明 |
|---|---|
| `up(name:mtu:)` | インターフェースを UP に設定 |
| `down(name:)` | インターフェースを DOWN に設定 |
| `addressAdd(name:ipv4Address:)` | IPv4 アドレスを追加 |
| `routeAddDefault(name:ipv4Gateway:)` | デフォルトルートを追加 |
| `configureDNS(config:location:)` | DNS 設定（/etc/resolv.conf） |
| `configureHosts(config:location:)` | /etc/hosts 設定 |

### Port Forwarding (Unix Socket Relay)

Unix ソケットの双方向リレーにより実現:

- **Into Guest**: ホスト側 Unix ソケットをコンテナ内に公開
- **Out of Guest**: ゲスト側 Unix ソケットをホストに公開

`UnixSocketRelayManager` (ホスト) と `VsockProxy` (ゲスト) が協調動作する。

## Resource Management

### CPU

`config.cpus` で設定。cgroup v2 の `cpu.max` に反映される。

- `quota = cpus * 100,000`
- `period = 100,000`

### Memory

`config.memoryInBytes` で設定。cgroup v2 の `memory.max` に反映される。

```swift
config.cpus = 2
config.memoryInBytes = 512.mib()  // 512 MB
```

### Cgroup v2

`Cgroup2Manager` がゲスト内で `memory.max` と `cpu.max` を cgroup ファイルに書き込む。

## Filesystem (EXT4)

### EXT4.Formatter

tar アーカイブから EXT4 ファイルシステムイメージを生成する。

- ブロックサイズと最小ディスクサイズのカスタマイズが可能
- inode 2 をルートディレクトリに予約
- `/lost+found` ディレクトリを自動作成（`e2fsck` 互換）
- `filetype` と `extents` feature をサポート

### EXT4Unpacker

tar アーカイブを EXT4 ファイルシステムイメージに展開する。`cctl rootfs create --ext4 <path>` で使用される。

## Package Structure

フレームワークは複数の Swift パッケージで構成される:

| パッケージ | 役割 |
|---|---|
| `Containerization` | メイン API（LinuxContainer, LinuxProcess, VM 管理） |
| `ContainerizationOCI` | OCI イメージ仕様、レジストリクライアント、イメージストレージ |
| `ContainerizationEXT4` | EXT4 ファイルシステムの作成・展開 |
| `ContainerizationNetlink` | Linux Netlink ソケットによるネットワーク設定 |
| `ContainerizationOS` | 低レベル OS ユーティリティ（FD, terminal, syscall） |
| `ContainerizationIO` | I/O 抽象化・ストリーミングユーティリティ |
| `ContainerizationExtras` | 非同期プリミティブ、TLS 設定等の共通ユーティリティ |
| `ContainerizationArchive` | TAR アーカイブの読み書き |
| `ContainerizationError` | 共通エラー型 |
| `cctl` | CLI ツール |
| `containerization-integration` | インテグレーションテスト |

Guest コンポーネント（別パッケージ）:

| パッケージ | 役割 |
|---|---|
| `vminitd` | init システム（PID 1）+ gRPC サーバー |
| `vmexec` | OCI 準拠コンテナランタイム |

### 主な依存ライブラリ

- `swift-log` — ロギング
- `swift-argument-parser` — CLI パーサー
- `grpc-swift` — gRPC 通信
- `swift-protobuf` — Protocol Buffers

## ContainerManager

`ContainerManager` はコンテナ作成のファクトリで、`LinuxContainer` の生成を簡略化する。

```swift
import Containerization

// Initialize with kernel, initfs, and image store
let manager = ContainerManager(
    kernel: kernel,
    initfs: initfs,
    imageStore: imageStore,
    network: try VmnetNetwork(),  // optional
    rosetta: false,
    nestedVirtualization: false
)

// Create a container from an image reference
let container = try await manager.create(
    id: "my-app",
    image: "docker.io/library/ubuntu:24.04",
    rootfsSizeInBytes: 2048 * 1024 * 1024
) { config in
    config.process.arguments = ["/bin/bash"]
    config.cpus = 2
    config.memoryInBytes = 1024.mib()
}

// Run
try await container.create()
try await container.start()
let status = try await container.wait()
try await container.stop()

// Delete container (release network, remove rootfs)
try await manager.delete(id: "my-app")
```

`ContainerManager` は以下を自動処理する:
- イメージの取得・展開による rootfs 作成
- ネットワークインターフェースの割り当て（`VmnetNetwork` 設定時）
- ブートログの設定
- コンテナ削除時のリソース解放

## Container States

`LinuxContainer` は内部状態マシンで以下の状態を遷移する:

```
initialized → created → started → stopped
                  ↓         ↓
               errored   errored
```

| 状態 | 説明 |
|---|---|
| `initialized` | オブジェクト生成済み、リソース未割り当て |
| `created` | VM 起動中、rootfs マウント済み、環境設定済み |
| `started` | コンテナプロセス実行中 |
| `stopped` | コンテナ終了、リソース解放済み |
| `errored` | ライフサイクル中にエラー発生 |

## Virtualization.framework Integration

`VZVirtualMachineManager` が `Virtualization.framework` をラップし、以下を構成する:

- **Kernel**: `VZLinuxBootLoader` でカーネルをロード
- **Filesystem**: EXT4 ブロックデバイス (`VZVirtioBlockDeviceConfiguration`) or virtiofs (`VZVirtioFileSystemDeviceConfiguration`)
- **Network**: `VZVirtioNetworkDeviceConfiguration` + NAT or vmnet attachment
- **vsock**: `VZVirtioSocketDeviceConfiguration` でホスト ↔ ゲスト通信
- **Rosetta**: `VZLinuxRosettaDirectoryShare` で x86_64 バイナリ変換
- **Nested Virtualization**: `VZGenericPlatformConfiguration` 経由

## Reference

- [DeepWiki: apple/containerization](https://deepwiki.com/apple/containerization/)
- [GitHub: apple/containerization](https://github.com/apple/containerization)

# AgentsInBlack App v1 Specification

## Purpose

AgentsInBlack App is a macOS workspace operator UI for AgentsInBlack (AIB).

It is **not** a code editor. Code editing is delegated to CodingAgent and/or an external editor.
The app focuses on:

- workspace navigation (multi-repo)
- terminal-centric workflows
- emulator run/stop control
- selection-focused inspection (repo/service metadata)

## Primary User Flow

1. Open an AIB workspace.
2. Inspect repositories/files/services in the sidebar.
3. Work in repository-scoped terminal tabs.
4. Start/stop emulator from the toolbar.
5. Open selected repo/file in an external editor.
6. Inspect selected repo/service details in the inspector.

## Layout (v1)

The app uses `NavigationSplitView` with an inspector.

- Sidebar: workspace navigation (repos/files/services)
- Detail: split vertically (`VSplitView`)
  - top: terminal tabs (primary surface)
  - bottom: AIB runtime output/logs
- Inspector: details for the current selection (repo/service/file), not global workspace information

## Information Architecture

### Header / Toolbar (Workspace Scope)

Workspace-wide information is shown in the header/toolbar, not in the inspector.

Header/toolbar includes:
- workspace name
- workspace path (truncated)
- emulator state (`stopped`, `starting`, `running`, `stopping`, `error`)
- gateway port (when running)
- two action buttons only:
  - `Run` / `Stop` (toggles based on emulator state)
  - `Open Editor`

### Inspector (Selection Scope)

The inspector shows details about the currently selected item.

#### Repo selection
- repo name
- repo path
- repo status (`managed`, `discoverable`, `unresolved`, `ignored`)
- runtime / framework
- manifest path
- selected command
- namespace
- repo services summary

#### Service selection
- service id (`repo/service`)
- mount path
- run command
- watch mode
- cwd
- runtime state (if available)

#### File selection
- file path
- open/reveal actions (no viewer)

## Sidebar (Xcode-like, no built-in file viewer)

Sidebar sections:
- `Workspace` (repositories)
- `Files` (repo file tree)
- `Services` (namespaced services)

Selecting a file does **not** open an in-app viewer. The app remains editorless by design.

## Terminal Model (v1)

Terminal is the primary interaction surface.

- one terminal tab per repository (auto-created on first repo selection)
- tabs are switchable (Xcode-like mental model)
- each tab runs with repo root as working directory
- app may use a simplified command-runner terminal implementation in v1 (PTY host can be added later)

## Emulator Control

Toolbar run button toggles:
- `Run` -> starts `aib emulator start` for the selected workspace (or AIBCore equivalent)
- `Stop` -> stops the running emulator instance

State model:
- `stopped`
- `starting`
- `running`
- `stopping`
- `error`

## External Editor Integration

The app provides an `Open Editor` toolbar action:
- when a file is selected: open the selected file in the preferred editor
- when a repo is selected: open the repo root
- otherwise: open workspace root

Editor integration is app-managed (user preference / system default). The app does not embed an editor.

## Packaging / Architecture Boundaries

The AIB package structure should be simplified to:
- `AIBCore`
- `AIBCLI`

Everything else (UI, terminal host, app state, inspector models, view models) belongs to the App target.

### Intended roles

- `AIBCore`: workspace discovery, config models, sync, emulator control APIs, status/events
- `AIBCLI`: thin wrapper over `AIBCore`
- `AgentsInBlack App`: SwiftUI UI + terminal UX + editor launch + app-specific state

## v1 Scope

Included:
- workspace open
- sidebar navigation (repos/files/services)
- terminal tabs per repo
- toolbar with two buttons (`Run/Stop`, `Open Editor`)
- runtime output panel
- inspector for selected repo/service/file metadata

Excluded:
- code editing / file viewer
- git UI
- deploy UI
- AI chat panel separate from terminal
- full PTY terminal emulation (optional future enhancement)

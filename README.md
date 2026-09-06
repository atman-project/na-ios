# Na

**Na** (나, "I") — the core [Atman Project](https://github.com/atman-project) application.

Current status: a SQLite database that lives on your phone, mutated and queried by chatting.

Every table you create is a **sub-app** — a small schema (car fuel history, workouts, expenses, …) that you define and fill by talking to the assistant.
The current scope is deliberately minimal: a chat interface over the local database, which does not support syncing yet.
Sharing/joining sub-apps and live replication arrive when [crrdb](https://github.com/atman-project/crrdb) is integrated.

## Architecture

- **[crrdb-mcp](https://github.com/atman-project/crrdb-mcp) is embedded, not
  reimplemented.** The same Rust crate desktop agents run as an MCP server is
  linked here as a static library via UniFFI (`ffi` feature). No stdio, no
  server process: Swift calls the same eight `Server` tool methods
  (`get_schema`, `query`, `create_table`, `commit_records`, …) in-process.
- **Chat** drives the Anthropic Messages API (`claude-opus-5`) directly from
  the device with a manual tool-use loop. Tool schemas and the system-prompt
  instructions come from the library itself (`toolDefinitions()` /
  `instructions()`), so the contract has a single source of truth.
- The database file is `Documents/atman.sqlite`, visible in the Files app.
- When crrdb (conflict-free replication) lands inside crrdb-mcp, this app
  inherits it by bumping the submodule.

## Build

Requires Rust (with `aarch64-apple-ios*` targets) and
[xcodegen](https://github.com/yonaskolb/XcodeGen):

```bash
git submodule update --init
./build_crrdb_mcp.sh --sim-arm64   # or --arm64 for a real device
xcodegen generate
open Na.xcodeproj
```

Set your Anthropic API key in the app's Settings (stored in the Keychain).

## App icon

The icon glyph — "나" — is set in [Pretendard](https://github.com/orioncactus/pretendard) Black v1.3.9 (SIL Open Font License, © Kil Hyung-jin), rendered once into `Na/Assets.xcassets/AppIcon.appiconset/app_icon.png`.
No font files ship in the app, and the OFL makes the artwork reusable anywhere.

## Not yet

- crrdb integration (conflict-free replication across devices/friends)
- Sub-app sharing / joining with friends
- A data browser UI (inspect `atman.sqlite` via the Files app meanwhile)
- Streaming responses in chat
- Persisted conversation history (the data itself always persists in SQLite)

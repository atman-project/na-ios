# Na

An app that integrates all the components in the Atman tech stack.
For now, the app is over a user-owned local SQLite database: the user talks
("I filled up 43L for 68,000 won"), Claude extracts structured records via
tool calls, and the embedded crrdb-mcp library executes them on-device.
This is the realization of the **Teller** concept (`~/repos/teller/concept.md`,
Korean): the model understands, code computes — all arithmetic happens in SQL,
never in the model.

## Architecture rules

- **crrdb-mcp is embedded, never reimplemented.** The Rust crate at
  `submodules/crrdb-mcp` (branch `uniffi`, `ffi` feature) is the single source
  of truth for the tool contract: the eight tools, their schemas
  (`toolDefinitions()`), and the system-prompt instructions (`instructions()`).
  Do not duplicate any of its logic in Swift; tool-behavior changes go into the
  crrdb-mcp repo. A Swift replica was built once and deliberately deleted.
- No stdio, no MCP transport on device: Swift calls the same rmcp `Server`
  methods in-process through UniFFI-generated bindings.
- Chat drives one of two switchable backends (`llm.backend` in UserDefaults):
  the Anthropic Messages API (`claude-opus-5`) with a manual tool-use loop in
  `ChatViewModel` (max 25 iterations; content blocks round-tripped verbatim so
  thinking blocks survive), or on-device Qwen3.5-4B via MLX (`LocalLLM` +
  `mlx-swift-lm` `ChatSession`, which owns the local conversation state and
  runs the tool loop internally through a `toolDispatch` closure into
  crrdb-mcp). The local backend needs a real device with 8GB RAM (iPhone 15 Pro / 16 or newer); the
  simulator path shows an explanatory error. Both backends share the same
  system prompt (`AtmanTools.systemPrompt`); a separate hardened local prompt
  existed for Qwen3-4B but was deleted with the move to Qwen3.5 — re-add
  specific rules only when a real failure shows the need.
- The database is `Documents/atman.sqlite` (visible in the Files app).
  When crrdb replication lands inside crrdb-mcp, this app inherits it by
  bumping the submodule — `Crrdb` in Swift is the only seam.

## Scope (deliberate)

Chat + local database only. Deferred: sub-app share/join, data browser UI,
streaming responses, persisted chat history, crrdb replication.

Roadmap next (from the Teller concept, in order):
1. Echo-back approval before `commit_records` — gate in the Swift tool
   dispatch (`ChatViewModel.executeTool`), returning a "user declined" tool
   result on refusal.
2. Approval-pair collection (utterance → committed rows) from day one, as the
   labeling pipeline for future local-model distillation.

## Build

```bash
git submodule update --init
./build_crrdb_mcp.sh --sim-arm64   # or --arm64 for device; installs ONE slice
xcodegen generate                  # .xcodeproj is generated, never committed
```

The Rust lib slice must match the Xcode destination (same workflow as
beam-ios's build_atman.sh). Verify builds with:
`xcodebuild -project Na.xcodeproj -scheme Na -destination 'generic/platform=iOS Simulator' ARCHS=arm64 CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation -skipMacroValidation build`
(the skip flags are required by mlx-swift's build plugin and macros; Xcode 26+
also needs `xcodebuild -downloadComponent MetalToolchain` once).

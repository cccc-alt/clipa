# Clipa — Local-first Clipboard Manager for macOS

Clipa is a native macOS clipboard manager: everything you copy is captured
into a searchable, **SQLCipher-encrypted** local history and surfaced through
a floating, Spotlight-style panel (`⌃⌘V`). No account, no cloud, no telemetry —
data never leaves the machine.

## Features

- **Automatic capture** of text / JSON / YAML / Markdown / images / files,
  with duplicate merging (pausable, per-app ignore list)
- **Full-text search** over body + notes: Chinese substring matching via
  FTS5 trigram recall + an in-memory verification engine, plain-literal
  semantics, fully offline
- **Source-app badge**: every row shows the originating app's icon
  (bundle ID captured at copy time)
- **Private vault**: mark any entry private; body, notes and image bytes are
  AES-GCM-encrypted at the field level; unlock via Touch ID / password,
  auto-relock after 60 seconds; private entries never enter the search index
- **Whole-database encryption**: the history store is a SQLCipher database;
  the key lives in the device keychain and never leaves this Mac
- **Notes / aliases** searchable alongside content
- **Local control plane (MCP)**: AI tools (Claude, Codex, Cursor, …) can
  search / read / copy / write the history through a token+scope-gated
  **MCP server** (`clipa-mcp`, stdio) or the `clipa` CLI — with audit
  logging, rate limiting, and hard exclusion of private entries
- **Multi-workspace** with independent histories

## Security model

| Layer | Mechanism |
|---|---|
| Database at rest | SQLCipher (AES), per-workspace random key in the device keychain (`ThisDeviceOnly`) |
| Private entries | Field-level AES-GCM on top of the database encryption |
| Local API | Token + fine-grained scopes, audit log without content, 60 req/min per token |
| Private entries via API | Never returned — indistinguishable from a missing id |

The system `sqlite3` CLI cannot open the store (`file is not a database`);
the key never leaves the keychain. Moving the database file to another Mac
renders it unreadable by design — use the in-app export/import flow instead.

## Build

Requires macOS 14+ (arm64) and Xcode Command Line Tools. SQLCipher 4.6.1
amalgamation is vendored under `Vendor/SQLCipher` (BSD license) and compiled
in — no external SQLite dependency.

```bash
Scripts/build.sh          # produces .build/app/Clipa.app and dist/Clipa.dmg

.build/app/Clipa.app/Contents/MacOS/Clipa --selftest    # 396 assertions
Scripts/run_privacy_filter_tests.sh                     # privacy regression suite
```

## MCP setup

1. Menu bar icon → 本地接口 → 开启控制面 → 新建令牌…
2. Use the built-in "复制 Cursor 配置" / "复制 Codex 配置" buttons in the
   token dialog (the snippet embeds the token), or configure manually:

```json
{
  "mcpServers": {
    "clipa": {
      "command": "/Applications/Clipa.app/Contents/Helpers/clipa-mcp",
      "env": { "CLIPA_TOKEN": "<your token>" }
    }
  }
}
```

The MCP server exposes seven tools: `clipa_status`, `search_clips`,
`get_clip`, `copy_clip`, `put_clip`, `note_clip`, `delete_clip`.

## Layout

```text
Sources/Clipa/
  App/         Entry point, AppDelegate, control-plane server, CLI/MCP
  Clipboard/   Capture pipeline, pasteboard writer, sensitive detection
  Models/      Clip model, classifiers
  Database/    SQLCipher-backed store, migrations, FTS repository
  Search/      FTS recall, in-memory index, ranking, parity harness
  UI/          Floating panel (SwiftUI), rows, privacy interactions
  Settings/    Preferences, login-item self-healing
  Support/     Store coordination, crypto, tokens, audit
  Tests/       Self-test suite (396 assertions) and stress tooling
Vendor/SQLCipher/  Vendored SQLCipher amalgamation (BSD)
Scripts/           Build, icon generation, privacy test harness
docs/manual.zh.md  User manual (Chinese)
```

## License

BSD-2-Clause — see [LICENSE](LICENSE). The vendored SQLCipher amalgamation
keeps its own BSD license notice in `Vendor/SQLCipher/sqlite3.c`.

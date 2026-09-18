<p align="center">
  <img src="docs/logo/blacktea-logo.png" alt="blacktea" width="128" />
</p>

<h1 align="center">blacktea</h1>

<p align="center">
  <a href="README.md">English</a> |
  <a href="README.zh-TW.md">繁體中文</a>
</p>

<p align="center">
  <strong>An AI-controllable HTTP debugging proxy for macOS.</strong>
</p>

<p align="center">
  Intercept, inspect, and rewrite HTTP/HTTPS/WebSocket/GraphQL traffic in a native Swift app —<br>
  and let an MCP client create the mocking rules for you instead of clicking through dialogs.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="Platform" />
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--or--later-green" alt="License" /></a>
</p>

---

> [!NOTE]
> blacktea is a personal fork of an upstream AGPL-3.0 project. Most of what is
> described below is that project's work — see [COPYRIGHT.md](COPYRIGHT.md) for
> attribution. This build is renamed and re-iconed because the upstream licence
> does not extend to its name, logo, or product identity. It is not an official
> upstream release and carries no endorsement. Report issues here, not upstream.

## What this fork adds

Upstream ships a local MCP server with ten **read-only** tools. An AI client can
inspect traffic and list rules, but cannot act — creating a Map Local rule stays
a right-click-and-fill-a-dialog job.

blacktea adds three rule-mutating MCP tools, so an MCP client can set up mocking
end to end:

| Tool | What it does |
|------|--------------|
| `create_map_local_rule` | Serve a local file as the response for matching requests |
| `set_rule_enabled` | Enable or disable a rule by id |
| `delete_rule` | Remove a rule by id |

Ask your client to "mock `/v4/merchant/serviceProvider` with `{"centerId":"..."}`"
and it writes the file, creates the rule, and confirms it reached disk.

**Design notes:**

- **Off by default.** Write access is gated by `MCPWriteAccessPolicy`
  (`UserDefaults` key `mcpWriteToolsEnabled`). While disabled the tools are
  neither advertised in `tools/list` nor callable. A client that can create a
  Map Local rule can rewrite every response flowing through the proxy, so the
  capability is opt-in rather than implied by turning the MCP server on.
- **Same seam as the UI.** Every mutation routes through `RulePolicyGate`, the
  gate the rule-editing windows use, so per-category quotas and durable
  persistence behave identically whichever surface created the rule.
- **Durable-or-nothing.** A tool reports success only after the change reaches
  disk — never "saved" for something that vanishes on relaunch.
- **Validate before mutating.** The mapped file must exist, a regex pattern must
  compile, and `status_code` must fall in `100...599`. A rejected call leaves the
  rule set untouched.

Enable it:

```bash
defaults write com.amunx.rockxy.community mcpWriteToolsEnabled -bool true
```

Then turn on **Settings → MCP → Enable MCP Server** and restart the app.

## Features

Everything below comes from upstream.

### Traffic Capture

Inspect HTTP, HTTPS, WebSocket, and GraphQL traffic from any Mac app, CLI, or iOS
device. Browser DevTools end at the browser — this sees the rest of your stack.

`HTTP / HTTPS` · `WebSocket` · `GraphQL` · `iOS Device & Simulator` · `Filter by Process ID` · `Timing Waterfall`

### Rules

Map Local, Map Remote, Block/Allow lists, Modify Headers, Breakpoints, and
Network Conditions — the full rewrite toolkit, all scriptable through the
JavaScriptCore engine when a rule is not expressive enough.

`Map Local` · `Map Remote` · `Breakpoints` · `Modify Headers` · `Network Conditions` · `JS Scripting`

### Advanced Filter & Search

Narrow thousands of captured requests in seconds. Combine method, host, status,
header, body, and process filters — or run a full-text search across the session.

`Multi-Field Filters` · `Full-Text Search` · `Header / Body Match` · `Saved Filters`

### Developer Setup Hub

Copy-paste proxy snippets for Python, Node.js, Go, Rust, cURL, Docker, and
browsers, then click Run Test to confirm traffic is actually flowing.

### AI Assistant

Select captured requests and ask what happened, what failed, or what to verify
next. Analysis runs locally first; a configured Ollama or provider model runs
only after Review Data shows the exact bounded, redacted context.

## Quick Start

```bash
git clone https://github.com/popochess/blacktea.git
cd blacktea
cp Configuration/Developer.xcconfig.template Configuration/Developer.xcconfig
# set ROCKXY_TEAM_ID to your Apple Developer Team ID
open Rockxy.xcodeproj
```

Build and run in Xcode. The Welcome window guides you through root CA setup,
helper installation, and proxy activation.

**Requirements:** macOS 14.0+, Xcode 16+, Swift 5.9

> Bundle identifiers, the Xcode project filename, and `ROCKXY_*` build settings
> still carry the upstream name. They are live identifiers — renaming them would
> invalidate the installed root CA, the privileged helper registration, and every
> stored preference. Commands above are written to work as-is.

### iOS Simulator

The simulator shares the Mac's network stack, so it inherits the macOS system
proxy automatically. It keeps its own trust store, though, so install the root CA
into each simulator:

```bash
xcrun simctl keychain <udid> add-root-cert \
  ~/Library/Application\ Support/com.amunx.rockxy/Certificates/rootCA.pem
```

Then cold-launch the target app — a warm relaunch can reuse a cached failed TLS
session.

## Documentation

Upstream documentation lives in [`docs/`](docs/) and applies to this fork except
where noted above. Start with [`docs/development/building.mdx`](docs/development/building.mdx)
for the build, and [`docs/features/mcp.mdx`](docs/features/mcp.mdx) for MCP setup.

## License

AGPL-3.0-or-later, except identified third-party material. See
[LICENSE](LICENSE), [LICENSING.md](LICENSING.md), and
[COPYRIGHT.md](COPYRIGHT.md).

Copyright 2024–2026 Nguyen Huu Loc (Stephen) and Rockxy Contributors, plus
contributors to this fork. If you run a modified version of this software as a
network service, the AGPL requires you to offer its source to your users.

---

<p align="center">
  <sub>Built with Swift, SwiftNIO, SwiftUI, and AppKit.</sub>
</p>

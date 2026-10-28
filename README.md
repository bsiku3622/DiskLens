# DiskLens

A native macOS disk-usage analyzer. Point it at a folder and it maps what's
eating your space as an interactive **sunburst** chart — click a slice to drill
in, and move space hogs to the Trash from the side panel.

<img src="docs/screenshot.png" width="720" alt="DiskLens sunburst view">

## Features

- **Sunburst visualization** — folder hierarchy as concentric rings, each slice
  sized by its share of on-disk usage. Hover for details, click to drill in,
  click the center hole (or the breadcrumb) to go back up.
- **Accurate sizing** — on-disk allocated size, hidden files included (`.git`,
  caches, dotfiles), symlinks never followed. Scans stop at volume boundaries,
  so a snapshot remount like `/System/Volumes/Update/mnt1` isn't counted as a
  second copy of `/`; hardlinked files are counted once; and system volumes
  (Preboot, VM, Update) are reported at their real size instead of walked. The
  disk's actual usage is shown next to the scanned total.
- **Honest permission reporting** — unreadable folders are split into the ones
  Full Disk Access can unlock and the root-owned ones no permission will, and
  you can list exactly which were skipped.
- **Contents panel** — the focused folder's children, largest first, with
  proportion bars and percentages.
- **Move to Trash** — recoverable cleanup (never a hard delete), with a
  confirmation step. Also "Reveal in Finder".
- **Fast, cancellable scans** off the main thread, with live progress. Directories
  are listed in parallel with `getattrlistbulk(2)`, which returns a whole listing
  with sizes in one call. On a 2.7M-file disk this takes about 15 s, compared with
  96 s for the previous single-threaded FileManager walk. Counts match `du`, including
  `._` AppleDouble files, which FileManager leaves out of directory listings.
- **Korean / English** UI, light & dark mode.

## Build & run

Requires macOS 14+ and the Swift toolchain (Xcode command-line tools).

```bash
./build.sh          # release build → DiskLens.app
open DiskLens.app
```

`./build.sh debug` builds a debug configuration. The script assembles the
`.app` bundle and builds the icon (if `icons/appicon-1024.png` exists).

### Signing

`build.sh` signs with a local `DiskLens Self-Signed` identity when present, so
the app's designated requirement is stable across rebuilds and a granted **Full
Disk Access** persists. Without that identity it falls back to ad-hoc signing.
Create the identity once (self-signed code-signing cert named `DiskLens
Self-Signed` in your login keychain).

### Releasing / auto-update

The app checks GitHub Releases on launch and can download + swap itself in place.
To cut a release, bump `CFBundleShortVersionString` in `Info.plist`, then:

```bash
./release.sh "what changed"
```

This builds (signed), zips `DiskLens.app` as `DiskLens-mac.zip`, and publishes a
`v<version>` release via `gh`. Running locally keeps releases signed with the
same identity, so updates don't reset Full Disk Access.

You can also point it at a folder from the command line:

```bash
open -a DiskLens.app --args /path/to/folder
```

## Agent integration

DiskLens works with coding agents (Claude Code and Codex) in four ways. All of
them use the same scan engine as the app.

### AI sidebar

The sparkle button at the right end of the toolbar opens a chat with an agent
installed on the Mac. On the first press you pick **Claude Code** or **Codex**,
along with its model and reasoning level. The chat then opens with a request to
analyze the current scan already in the input box. Nothing runs until you press
Send. **Ask AI** on a row of the contents list fills in a question about that item
in the same way.

**Free up space with AI** on the start screen does everything in one step. You
pick an agent, DiskLens scans the whole disk, and the analysis is sent as soon
as the scan finishes. The sidebar shows the scan's progress in the meantime.

While the agent works, the sidebar shows:

- a status line with what it's doing and how long it has taken;
- its reasoning, live while it streams, then folded;
- each tool call as a step with a spinner, check or cross, its duration and its
  output;
- the time and tokens for each answer.

The model can be changed from the header between messages.

The sidebar runs the agent's own CLI (`claude -p` with stream-json, or
`codex exec --json`). It does **not** load your agent settings, because those may
skip permission checks. Instead it:

- connects only this app as an MCP server;
- gives the agent read-only shell access (an allow list for Claude Code, a
  read-only sandbox for Codex);
- passes your `storage-cleanup` skill in as instructions.

The agent can move items to the Trash when you ask it to, but it cannot delete
anything permanently. Items it trashes are removed from the chart. Its marks
appear as described under [Annotations in the app](#annotations-in-the-app).

The scan you're looking at is saved to
`~/Library/Application Support/DiskLens/current-scan.json` (items of 1 MB or
more). The MCP server's `current_scan` tool reads that file, so the agent
doesn't scan again.

### JSON export

```bash
DiskLens --export scan.json [--min-size 20M] [--max-depth N] /path/to/folder
DiskLens --export - ~/Library        # write to stdout
```

This writes a size-pruned tree. Items smaller than `--min-size` (default 20 MB)
are folded into each folder's `otherSize`/`otherCount`, so even a whole-disk
scan stays at a few thousand nodes.

When run from a terminal, the scan uses the terminal's permissions. To use the
app's own Full Disk Access grant, launch it through LaunchServices with an
absolute output path:

```bash
open -n -W -a DiskLens --args --export /tmp/scan.json /
```

### MCP server

```bash
claude mcp add --scope user disklens -- /Applications/DiskLens.app/Contents/MacOS/DiskLens --mcp
```

`DiskLens --mcp` speaks the Model Context Protocol over stdio and provides
these tools:

| Tool | What it does |
| --- | --- |
| `current_scan` | Return the app's latest scan, which is what the user is looking at |
| `scan` | Scan a folder (or `/`) and keep the result in memory |
| `list` | List a folder's children from the cached scan, largest first |
| `largest_files` | Find the largest files under a folder |
| `move_to_trash` | Move items to the Trash; only allowed inside home or `/Applications`, and never a top-level home folder |
| `annotate` | Mark items as `safe`, `review` or `keep` with a note, for the app to show |
| `open_app` | Open the app, optionally scanning a folder |

### Annotations in the app

Marks are stored in `~/Library/Application Support/DiskLens/annotations.json`.
`annotate` writes this file, and so can anything else that follows the same
format. The app checks it every two seconds. Marks written more than two minutes
before the app started are treated as stale and not shown. The rest appear in
three places:

- a banner that lists every mark and jumps to the item when clicked;
- a verdict badge with a note on rows in the contents list;
- a colored outline on the marked slice in the sunburst, with a faint trail on
  the folders that contain it.

```json
{
  "version": 1,
  "updatedAt": "2026-10-28T09:00:00Z",
  "source": "Claude",
  "items": [
    { "path": "/Users/me/Library/Caches/Google", "verdict": "safe",
      "note": "Chrome cache; regenerates.", "reclaimBytes": 5000000000 }
  ]
}
```

## Project layout

```
Sources/DiskLens/
  App/      Entry, DiskLensApp, AppDelegate, ContentView  — entry point & app shell
  Core/     Scanner, VolumeMap, FileNode, TrashService,
            UsageTree, CurrentScan, Annotations         — scan engine, export model, marks
  Headless/ HeadlessCommand, MCPServer                  — --export and --mcp modes
  Agents/   AgentDriver, AgentModels,
            ClaudeCodeDriver, CodexDriver               — running agent CLIs for the sidebar
  Model/    AppState, AnnotationCenter, AgentChat       — observable app state
  Views/    SunburstView, DetailPanel, ScanBar,
            MarksBanner, AgentSidebar                   — UI
  Design/   Theme, L10n                                 — colors, icons, strings
```

## License

© Jaewon Baek

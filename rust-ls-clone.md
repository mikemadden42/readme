# Rust ls clone

A lightweight `ls` replacement that also subsumes [sweep](https://github.com/mikemadden42/sweep) (group files by extension) and [tidyhome](https://github.com/mikemadden42/tidyhome) (move files into per-extension subdirs).

Working title — pick a real name when creating the repo.

## Goals

- Lightweight `ls` clone with the most common options
- Color output
- `sweep`-style organization (group by extension)
- `tidyhome`-style moving (sort into subdirs by extension)
- Linux + macOS only
- Single static binary on Linux (musl); self-contained on macOS

## Why Rust

- Strongest ecosystem fit: `eza`, `lsd`, `fd`, `ripgrep` are all Rust and worth reading
- Stable since 2015 — no churn-with-each-release problem
- True static binaries via `x86_64-unknown-linux-musl` / `aarch64-unknown-linux-musl`
- Ergonomic CLI/color/filesystem crates

## Crate shortlist

- `clap` — argument parsing (derive macros)
- `owo-colors` — terminal colors
- `walkdir` — recursive traversal
- `terminal_size` — terminal width for column layout
- `jiff` or `time` — timestamp formatting
- `nix` — Unix metadata (uid/gid → name, mode bits) on Linux/macOS

## Feature scope

### Default (`ls` mode)

- `-l` long listing (perms, owner, group, size, mtime)
- `-a` show hidden (`.` and `..` included)
- `-A` show hidden but skip `.` and `..`
- `-h` human-readable sizes
- `-r` reverse sort
- `-t` sort by mtime
- `-S` sort by size
- `-1` one entry per line
- `-R` recursive
- Color output (built-in palette; optionally honor `LS_COLORS` later)

### `sweep` subcommand

- `<bin> sweep [PATH]`
- Lists files grouped by extension, sorted alphabetically
- Read-only (no moves)

### `tidy` subcommand

- `<bin> tidy [SRC] [DEST]`
- Moves files into `DEST/<ext>/` subdirectories
- `--dry-run` flag (default to dry-run on first run? decide later)
- Skip directories; only move regular files

## Build & distribution

```toml
# Cargo.toml
[profile.release]
lto = "fat"
codegen-units = 1
panic = "abort"
strip = true
```

- Linux static: `cargo build --release --target x86_64-unknown-linux-musl`
- macOS: per-arch builds, optional `lipo` for universal
- GitHub Actions release workflow once basics work

## Open questions

- Project name
- LS_COLORS compatibility on day one, or define own palette and add later?
- One binary with subcommands (`<bin> ls|sweep|tidy`) or default to `ls` behavior with subcommands for the others? Latter feels closer to plain `ls` UX.

## Build order

1. Skeleton: `clap` parser, plain non-colored single-column output
2. `-l` long listing with perms/size/mtime
3. Color output
4. Sort flags (`-t`, `-S`, `-r`) and `-a`/`-A`
5. Multi-column layout (terminal-width aware)
6. `sweep` subcommand
7. `tidy` subcommand with `--dry-run`
8. musl static build + release workflow

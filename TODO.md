# Cheat Sheet Improvements TODO

## General
- [ ] Review all links for 404s or outdated content (many are from 2014-2016).

## File Specific Updates

### `ubuntu`
- [ ] Update version references from 14.04 (Trusty) to current LTS (24.04 Noble Numbat).
- [ ] Update Puppet setup scripts if they are still in use, or replace with Ansible/modern equivalent.

### `pip`
- [ ] Remove `pip search` (functionality is disabled on PyPI).
- [ ] Discourage `sudo pip install` in favor of `pip install --user` or virtual environments (`venv`).
- [ ] Update package list (e.g., `boto` is legacy, `boto3` is current).

### `youtube-dl`
- [ ] Add/suggest `yt-dlp` as the modern, more reliable fork of `youtube-dl`.

### `go`
- [ ] Add Go Modules (`go mod init`, `go mod tidy`) as it's the standard since Go 1.11+.
- [ ] Mention `go install` for tools (replacing `go get` for binaries).

### `python_http_server`
- [ ] Mark the Python 2 `SimpleHTTPServer` as legacy/obsolete.
- [ ] Add more modern options like `python3 -m http.server --directory`.

### `openssl`
- [ ] Add `-pbkdf2` flag to `enc` commands to align with modern OpenSSL defaults and security standards (avoiding warnings).

### `docker`
- [ ] (Done) Fix `--rm` syntax and add missing `sudo`.
- [ ] Add `docker compose` commands (the newer plugin version, not `docker-compose`).

### `zsh`
- [ ] Update links to modern Zsh resources and plugin managers (e.g., Oh My Zsh, Antidote, or Zinit).

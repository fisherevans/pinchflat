# Deps refresh and automated update flow

**Date:** 2026-10-22
**Type:** infra
**Version:** v2026.1022.0
**Author:** claude-code

## What changed

Every hex dependency moved to current within the existing major lines (plus ecto 3.14 so decimal
could reach 3.2), the Docker bases moved from bookworm/OTP 27.2.4 to trixie/OTP 27.3.4.16, and
`fork-mvp` gained the automation that keeps it current: a weekly upstream-sync PR, Dependabot,
lint/test on `fork-mvp`, and a weekly uncached `:dev` rebuild. `fork-mvp` became the default
branch the same day.

## Why

The nottingham-cloud#800 review found the deployed image carrying 41 hex advisories (cowlib,
plug, mint and phoenix among them, several HIGH) on a Debian base from April 2025. None of it was
visible: CI and the weekly rebuild only watched `master`, which is not what ships, and nothing
compared the fork to upstream.

## Context / alternatives

- **Elixir stays 1.18.4.** hexpm publishes newer OTP 27 patches (27.3.4.19) only with Elixir
  1.19+, and 1.19's type checker raises struct-update warnings that `EX_CHECK=1` turns into build
  failures. That is a code change of its own; the runtime base is plain Debian and is current.
- **Merge, not rebase, for upstream.** A rebase of 80+ fork commits would rewrite the release
  line; a merge into a throwaway branch keeps `fork-mvp` append-only and reviewable as a PR.
- **No auto-deploy.** The weekly rebuild publishes only `:dev`; a version tag is never rebuilt
  and the nottingham-cloud pin stays the gate. nottingham-cloud's freshness check flags a pin
  behind the newest release and open Dependabot PRs.
- **sobelow `Config.CSWH` ignored.** sobelow 0.16 flags upstream's deliberate
  `check_origin: false`; a self-hosted app is reached on arbitrary hosts.
- Remaining advisories: cowlib EEF-CVE-2026-43966 (no fixed release), and `tar` via the
  dev-only sqleton ERD tool (not in the image).

## Related

- fisherevans/nottingham-cloud#800, PR #42, tag v2026.1022.0
- `.github/workflows/upstream_sync.yml`, `.github/dependabot.yml`, `docker_release.yml`
- nottingham-cloud `systems/arr-stack.md` (pinchflat section)

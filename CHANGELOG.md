# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- Version infrastructure: `VERSION` file as canonical source of truth.
- Installer now displays version in completion summary and writes `installed_version` to `oh-my-claude.conf`.
- Statusline: version display (`v1.0.0`) in line one.
- Statusline: rate limit usage indicator (`RL:%`) with color-coded thresholds.
- Statusline: cost qualifier (`*`) when ULW active to signal subagent costs are excluded.
- Statusline: prompt cache hit ratio (`C:%`) from cache-eligible token breakdown.
- Statusline: API latency indicator (`API:%`) showing API wait time as percentage of wall clock.
- README: version badge linking to changelog.
- Git tag `v1.0.0` on initial release commit.

## [1.0.0] - 2026-04-06

Initial public release.

### Added

- Cognitive quality harness with hard stop gates to enforce thinking before acting.
- Intent classification state machine covering 5 intents and 6 domains.
- Multi-domain routing for coding, writing, research, operations, and mixed workloads.
- 23 specialist agents with permission boundaries enforced via disallowedTools.
- Session continuity across compaction via pre-compact snapshots and post-compact handoff.
- Merge-safe installer with automatic backup of existing configuration.
- OpenCode Compact output style for concise, structured responses.
- Custom statusline with context usage tracking.

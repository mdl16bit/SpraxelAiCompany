# Spraxel AI Company

Meta-framework for AI-driven gamedev: a set of Claude agents, skills, scripts,
and templates that get applied to individual game repos to automate code,
blog posts, demos, planning, and bug-fixing.

The full design lives in the approved plan at
`~/.claude/plans/i-want-to-build-jaunty-elephant.md`.

First target game: `infiltrators` (Godot 4.6.1, 2D stealth/heist).

## Layout

- `agents/` — Claude Code subagent definitions, symlinked into `~/.claude/agents/`
- `skills/` — Claude Code skills, symlinked into `~/.claude/skills/`
- `scripts/` — Python/bash utilities (WORK.md sync, new-game scaffolding, cost reports)
- `template/` — files copied into each game repo when applying the framework

## Phase 1 roles

- Producer (interactive) — turns dictation / messy notes into clean GH Issues
- PM — sorts, milestones, cuts releases
- Developer (worker) — implements one issue end-to-end
- Reviewer (worker) — Haiku-tier code review on PR open
- Concierge — single daily digest of pending approvals

Workers are ephemeral (born per task, no memory across runs). Crew agents are
persistent with memory files in the target game's `.factory/memory/`.

## State of the build

See the plan file for the phased rollout. Currently in **Phase 1 — Spine**.

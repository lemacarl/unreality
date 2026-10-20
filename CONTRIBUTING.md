# Contributing

## Workflow
- Branches: `feat/<issue#>-<slug>`, `fix/<issue#>-<slug>`, `chore/<slug>`, `spike/<slug>` (never merged).
- Commits: conventional commits (`feat:`, `fix:`, `docs:`, `chore:`, `test:`).
- PRs: title `<type>: <summary> (#<issue>)`, body has `Closes #<issue>`, how it was tested, open concerns. Squash-merged after CI is green and independent review approves. Never push to `main` directly.
- Docs and CHANGELOG are updated in the same PR as the change.
- No new dependency without an ADR. Never weaken tests or lint to pass CI.
- Public repo: no personal data, screenshots of your screen, or secrets in issues, PRs or logs.

## Local development
Dev builds must use a stable signing identity and bundle ID, or macOS drops Screen Recording/Camera/Accessibility grants on every rebuild. Secrets live in the Keychain only.

## Agents and models
| Role | Model | Effort | Used for |
|---|---|---|---|
| PM | Claude Sonnet 5.5 | Medium | Planning, issues, docs, merge decisions |
| Builder | Claude Opus 5.5 | Medium | Implementation, spike prototypes |
| Reviewer | Claude Opus 5.5 | High | Code, functional, privacy/security reviews (fresh context, never the PR's builder) |
| Researcher | Claude Sonnet 5.5 | Medium | Research for ADRs; gathers evidence, does not decide |

Definitions live in `.claude/agents/`.

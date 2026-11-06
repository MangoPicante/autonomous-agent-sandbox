# agent-sandbox

A small Python project wired to an autonomous coding loop on GitHub: label an issue
`agent-task`, and Claude Code implements it, an independent Claude session reviews it,
a fix job addresses findings, and GitHub auto-merges once tests and review are green.

## How it works

```
issue labelled agent-task
  └─> agent-implement.yml : Claude writes code + tests, commits; workflow pushes, opens PR, arms auto-merge
        └─> agent-pr.yml  : test job  ──> review job (separate Claude session, publishes "claude-review" status)
                                 └──> fix job (only if test or review failed; max 3 rounds, then "needs-human")
                                        └──> push ──> agent-pr.yml runs again
  └─> GitHub auto-merge when "test" and "claude-review" are both green (and, optionally, a human approves)
```

Claude never pushes, merges, or touches settings. Deterministic shell steps do the pushes;
GitHub branch protection does the merging. Full design rationale is in `PLAN.md`.

## Layout

| Path | Purpose |
| --- | --- |
| `CLAUDE.md` | Rules every agent run reads: build/test commands, PR conventions, review bar, hard "never" list |
| `PLAN.md` | Step-by-step setup and verification plan; what a human must do vs what an agent can do |
| `scripts/bootstrap.sh` | One command: secrets, variables, labels, merge settings, branch protection |
| `scripts/fix-round.sh` | Loop brake: counts `agent-round-N` labels, adds `needs-human` at the cap |
| `.github/workflows/agent-implement.yml` | Issue → PR |
| `.github/workflows/agent-pr.yml` | Test → review → fix loop on every PR |
| `.github/workflows/claude.yml` | Interactive `@claude` in comments (needs the official Claude GitHub App) |
| `.github/pull_request_template.md` | PR body shape the agent follows |
| `calc.py`, `test_calc.py` | The sample project the agent works on |

## Quick start

```bash
pip install pytest && pytest -q                      # local sanity check

export ANTHROPIC_API_KEY=sk-ant-...                  # from platform.claude.com
APP_ID=123456 APP_PRIVATE_KEY_FILE=./agent-app.pem \
INSTALL_CMD="pip install pytest" \
scripts/bootstrap.sh <owner>/agent-sandbox "pytest -q"   # add --require-human-approval to keep a person in the gate

gh issue create --title "Add subtract(a, b) to calc.py" \
  --body "Add a subtract function with a test. Follow the existing style."
gh issue edit 1 --add-label agent-task
gh run watch
```

## Labels (the state machine)

| Label | On | Meaning |
| --- | --- | --- |
| `agent-task` | issue | Start the loop |
| `agent` | PR | Owned by the loop; fix job may run |
| `agent-round-1..3` | PR | Fix rounds used |
| `needs-human` | issue or PR | Loop stopped; a person takes over. Remove it to let the agent try again |

## Configuration (repo variables, set by bootstrap)

| Variable | Default | Notes |
| --- | --- | --- |
| `TEST_CMD` | `pytest -q` | Must be the same command CI and the agent run |
| `INSTALL_CMD` | `pip install pytest` | |
| `LINT_CMD` | `true` | Set to your linter if you have one |
| `AGENT_MODEL` | `claude-sonnet-5-5` | Implementation and fixes |
| `REVIEW_MODEL` | `claude-opus-5-5` | Review; use the strongest model here |
| `MAX_FIX_ROUNDS` | `3` | |

Secrets: `ANTHROPIC_API_KEY`, `APP_ID`, `APP_PRIVATE_KEY`. Never commit the `.pem`; it is gitignored.

## Safety properties

- The implementation and fix agents can only read/edit files, run `git add`/`git commit`, and run the test command. No push, no merge, no `gh` write tools.
- The reviewer is a separate session on a different model; a missing or malformed verdict counts as "request changes".
- Agent PRs that touch `.github/`, `scripts/`, or `CLAUDE.md` are rejected before Claude runs.
- Fork PRs are skipped entirely. The fix loop is capped. Every job has a timeout and a turn cap.

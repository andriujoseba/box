# The `.box/` convention

`box` mints trust-less, creds-free, isolated VMs
(`box new/shell/snapshot/restore/exec/down/start/rm/status`), and **it does not
converge them** ([#214](https://github.com/heavy-duty/box/issues/214)): a mint
lands one thin seed and stops, so a fresh box has no coding agent on it. An
agent is one of the things the operator installs inside it afterwards — see the
[README's Quick start](../README.md#quick-start) for the four-step path. The
tool knows **nothing** about your project either. There is no `install` step
and no host-run setup script.

A project makes itself easy to stand up inside a box by shipping an optional
`.box/` folder. This folder is **agent-facing documentation** — read and acted
on by the coding agent you converged onto the box (the reasoning agent),
running inside it. It is not shell that the host executes.

> The folder was named `.claudebox/` before the 0.5.0 rename. Repos that still
> ship `.claudebox/` keep working — the agent is told to read either — but new
> projects should use `.box/`.

## What it is / what it is not

- **Optional.** No `.box/` is a perfectly valid state.
- **Agent-facing.** You are writing instructions to a reasoning agent, not a
  machine. Prose is fine; the agent adapts.
- **Not a host contract.** The host never parses, sources, or runs anything in
  here. There is no enforced schema and no required filenames.
- Old model: a host-executed `.devbox/setup.sh`. New model: a runbook the agent
  reads and decides how to act on.

## How it's consumed

A box the operator has converged with a coding agent gets a global
agent-context file alongside it —
`~/.claude/CLAUDE.md` for `claude`, `~/.codex/AGENTS.md` for `codex`,
`~/.grok/AGENTS.md` for `grok` — telling the agent it is inside a box and to
treat a repo's `.box/` folder as its bootstrap runbook. **box writes none of
those files and never did**: they are rendered by whatever converges the box
(#81). So the whole flow is (shown with `claude` and `rig`; another agent or
another converger follows the same shape):

```sh
box new --name work --size medium   # a blank box, nothing converged
box root work                       # root inside it, and converge it:
rig bootstrap claude-box --user dev # ...after installing rig — Quick start has the full line
box shell work                      # in as the tenant user, on a box that now has an agent
git clone <repo> && cd <repo>
claude                              # the agent reads .box/ and brings the project up
```

The first three lines are the mint-and-converge path abbreviated, and they are
the README's rather than this page's: [Quick start](../README.md#quick-start)
carries it whole, including the `curl … install.sh` line that puts `rig` on the
box in the first place. They are here because the last three do not run without
them.

The operator can also just say: *"set this project up per .box"*.

## Suggested contents (all optional)

Author everything here for a reasoning agent.

- **`.box/SETUP.md`** — the prose runbook. Prerequisites, how to install
  deps, how to start services, how to template the env, how to seed data, and
  how to smoke-test. Written as instructions to the agent.
- **Helper scripts** (e.g. `.box/dev-up.sh`) that the runbook tells the agent
  to run. The agent decides to run them; the host never does.
- **`.box/env.template`** — example env the runbook explains how to fill.
  Staging values the operator pastes in. **Never commit real secrets.**
- **`.box/compose.yml`** — optional services the runbook starts.

## Worked example

A minimal `.box/SETUP.md` for a Node + Postgres app:

```markdown
# Setup

This is a Node service backed by Postgres.

1. Install deps: `npm ci`
2. Start Postgres: `docker compose -f .box/compose.yml up -d`
3. Create the env file: copy `.box/env.template` to `.env` and ask the
   operator to fill in `DATABASE_URL` and `API_KEY` (staging values).
4. Run migrations: `npm run migrate`
5. Start the app: `npm run dev`
6. Smoke-test: `curl -sf localhost:3000/health` should return `{"ok":true}`.
```

That's it — the agent reads it top to bottom and adapts if reality differs.

## Guidance

- **Keep it declarative and resilient.** State intent and steps; let the agent
  adapt when the repo has drifted. Don't hard-code brittle assumptions.
- **Never put real credentials in `.box/`.** Templates and staging
  placeholders only. The operator pastes real values at runtime.
- **No `.box/` is fine.** The operator can stand the project up by hand,
  or let the agent infer the steps from the repo's `README` / `CLAUDE.md`.

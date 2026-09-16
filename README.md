# Roark

Run a [Roark](https://roark.ai) voice-agent simulation from CI and gate the pipeline on the result.

Your agent gets called by simulated customers, every call is scored against the metrics you configured, and the step fails when the run misses the success criteria on its run plan.

```yaml
- uses: roarkhq/simulation-action@v1
  with:
    api-token: ${{ secrets.ROARK_API_KEY }}
    plan-id: <your-plan-id>
```

## How the pass/fail decision is made

Roark decides, not this action. You configure **success criteria** on the run plan and the API returns a verdict, so the CLI, the dashboard and this action always agree on whether a run passed.

Criteria are pinned to each run when it starts, so editing a plan never rewrites the verdict of a run that already happened.

**Every check is judged on its own.** A check is one pass/fail metric: a yes/no metric, or a threshold on another metric the plan collects. Each must reach its own minimum pass rate across the run, and the run passes only when all of them do.

| Check | Passed | Rate | Minimum | |
|---|---|---|---|---|
| silence duration < 500ms | 4/10 | 40% | 40% | pass |
| word count < 1000 | 7/10 | 70% | 80% | **fail** |

The run **fails**. `word count` missed its own bar, and no amount of success elsewhere makes up for it.

That is the whole decision. There is no pooled average to clear: averaging would let a check at 0% hide behind checks at 100%, which is exactly the failure a gate exists to catch.

### Minimums

Every check carries **its own minimum**, expressed as the share of the run's simulations that have to pass it. A check that sets none is held to **80%**.

Read a minimum as a count, because that is what it comes to: on a 10-simulation run, `50%` means *5 of 10 simulations need to pass*, and `80%` means *8 of 10*. Counts round up, since a check clears its bar only when its rate is at or above it: 7 of 9 is 77.8%, which misses 80%.

There is no plan-wide bar on top of that. One number for a whole plan is either too strict for the loose checks or too loose for the strict ones, so each check says what it needs and nothing else affects pass or fail.

### Score is not the decision

The run also reports a **score**: the mean of the check rates. It is for dashboards and trend lines only.

Nothing is gated on it, and you should not gate on it either. A run can score 95 and fail (one non-negotiable check missed its bar) or score 40 and pass (every check cleared a deliberately low bar).

### Only your agent can turn the build red

A gate answers one question: **did this change make the agent worse?** Only a run that actually ran can answer it, so this action has three outcomes, not two.

| Outcome | When | Exit |
|---|---|---|
| **PASSED** | Every check cleared its own minimum. | 0 |
| **FAILED** | The run completed cleanly and a check fell short. | **1** |
| **SKIPPED** | The run never produced a judgeable result: a Roark outage, a model-provider error, simulations that died before they were graded, a check that produced no result. | 0, with a warning |

A check falling below its minimum is the **only** thing that fails your build. Our problems are never your problem: they are annotated loudly, reported as `verdict: SKIPPED` with a `skip-reason`, and then they get out of your way.

That is a deliberate trade. If our infrastructure can turn your pipeline red, the first thing your team learns is to re-run until green, and from then on nobody reads the gate at all, including on the run where the agent really did regress. A red build has to mean something.

Operational problems **poison** the verdict rather than sitting beside it. If half a run's simulations never completed, a check reported at 40% is not evidence of a regression, it is evidence we could not measure. So any operational failure makes the whole run `SKIPPED`, even when a check also fell short.

Two exceptions, both deliberate:

- **A plan with no checks still fails.** That is not our outage, it is a plan that can never gate anything, and skipping it would leave a green check next to a permanent no-op.
- **A rejected request still fails.** A bad token, an unknown `plan-id` or a config the API refuses is your side, and a gate that skips on a typo never gates again. Only errors that read as ours (5xx, rate limits, dead sockets) are skipped.

Set `fail-on-run-error: true` if you would rather block than proceed unmeasured.
## Usage

### Run a saved plan

Configure the criteria once in the Roark platform, then:

```yaml
name: Voice agent regression
on:
  push:
    branches: [main]

jobs:
  simulate:
    runs-on: ubuntu-latest
    steps:
      - uses: roarkhq/simulation-action@v1
        with:
          api-token: ${{ secrets.ROARK_API_KEY }}
          plan-id: <your-plan-id>
          variables: |
            orderNumber=12345
            customerName=John Doe
```

### Or keep the config in your repo

```yaml
# .roark/checkout-regression.yml
name: Checkout regression
direction: OUTBOUND
maxSimulationDurationSeconds: 300
agentEndpoints:
  - id: <your-agent-endpoint-id>
flows:
  - id: <your-flow-id>
    happyPath: true
    edgeCases: ALL
metrics:
  - slug: agent_containment
    # No minPassRate, so this check is held to the 80% default.
  - slug: latency
    minPassRate: 12    # this check only has to clear 12% of simulations
  - slug: leaked_pii
    minPassRate: 100   # ... while this one must pass every simulation
```

Only `minPassRate` is set here, because the bar is the only thing a plan gets to say about a
check. What counts as passing one simulation belongs to the metric itself: a "did the agent
leak PII?" check passes on FALSE because it carries a threshold of `EQUALS false`, stated once
in Roark rather than re-stated by every plan that uses it. The API rejects unrecognised keys,
so a stray flag here fails the run rather than being quietly ignored.

```yaml
      - uses: actions/checkout@v4
      - uses: roarkhq/simulation-action@v1
        with:
          api-token: ${{ secrets.ROARK_API_KEY }}
          config: .roark/checkout-regression.yml
```

This runs as a one-off: nothing is added to your saved plans.

Set `save-as-plan: true` to keep it instead. The plan id comes back as the `plan-id`
output, so a pipeline can create the plan on its first run and pass `plan-id` from
then on:

```yaml
      - uses: roarkhq/simulation-action@v1
        id: sim
        with:
          api-token: ${{ secrets.ROARK_API_KEY }}
          config: .roark/checkout-regression.yml
          save-as-plan: true
      - run: echo "Plan ${{ steps.sim.outputs.plan-id }}"
```

### Hold one branch to a higher bar

`min-pass-rate` holds every check to at least that minimum for this pipeline only, leaving
the shared plan alone. It is applied per check, on top of each check's own minimum (80%
where a check sets none), so a release branch can demand more than the plan without
touching it.

It can only tighten: it will not let through a run the plan's own criteria failed, because
overruling a minimum the plan's owner set is not something a pipeline gets to do.

```yaml
      - uses: roarkhq/simulation-action@v1
        with:
          api-token: ${{ secrets.ROARK_API_KEY }}
          plan-id: <your-plan-id>
          min-pass-rate: 99
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `api-token` | yes | | Roark API key. Pass it from a secret. |
| `plan-id` | one of | | Saved run plan to run. |
| `config` | one of | | Path to a YAML file describing the run. |
| `variables` | no | | Runtime variables, one `KEY=VALUE` per line. |
| `save-as-plan` | no | `false` | Keep the `config` as a named run plan instead of running it as a one-off. |
| `min-pass-rate` | no | | Hold every check to at least this minimum (0-100) for this pipeline. Tightens only. |
| `timeout-minutes` | no | `30` | How long to wait for the run. |
| `poll-interval-seconds` | no | `15` | How often to check for completion. |
| `fail-on-timeout` | no | `false` | `true` fails the build when the run overruns instead of warning. |
| `fail-on-run-error` | no | `false` | `true` fails the build when the run could not be judged (outage, dead simulations, a check that never ran) instead of skipping. |
| `cancel-on-exit` | no | `true` | Stop the Roark run when the workflow is cancelled or the wait times out. |
| `cli-version` | no | pinned | Version of `@roarkanalytics/cli` to run. |
| `api-base-url` | no | `https://api.roark.ai` | Override the API base URL. |

## Outputs

| Output | Description |
|---|---|
| `run-id` | The simulation run id. |
| `run-url` | Link to the run in the Roark platform. |
| `plan-id` | The run plan behind this run. With `save-as-plan`, the plan that was kept. |
| `score` | The run's quality score, 0-100. Reporting only: gate on `verdict`, never this. |
| `checks-passed` | How many checks cleared their own minimum. |
| `checks-total` | How many checks the run was judged on. |
| `verdict` | `PASSED`, `FAILED`, `SKIPPED`, or `TIMED_OUT`. |
| `skip-reason` | Why the run could not be judged. Set only alongside `SKIPPED`; empty on a run that was judged. |

## Simulations take minutes

Real calls take real time, so a gated run occupies a runner while it waits. Four ways to
keep that cheap and predictable:

- **Run it where it matters.** Gate `main` or your release branch rather than every push to every branch.
- **Our slowness already does not block your merge.** An overrun is a warning by default (`fail-on-timeout: false`), like every other problem on our side, while a genuine check failure still fails the build.
- **Cancel superseded runs.** A `concurrency` group stops an old push from holding a runner while a newer one is already testing the same branch. The action cancels the Roark run too, so the abandoned simulation stops placing calls you would otherwise be billed for.
- **Keep a job-level backstop.** `timeout-minutes` on the job is the last line of defence if the step itself wedges.

```yaml
jobs:
  simulate:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    concurrency:
      group: roark-sim-${{ github.ref }}
      cancel-in-progress: true
    steps:
      - uses: roarkhq/simulation-action@v1
        with:
          api-token: ${{ secrets.ROARK_API_KEY }}
          plan-id: <your-plan-id>
```

A single failed poll is not a failed build: the action absorbs up to five consecutive
read failures before giving up, so one network blip does not turn the gate red.

## Not using GitHub Actions?

The gate is in the CLI, so any CI can do the same thing:

```bash
npx @roarkanalytics/cli simulation run --plan-id <id>
```

## Getting an API key

Create one in the Roark platform under project settings. It needs permission to run simulations and read their results. Store it as an encrypted repository secret, never in the workflow file.

## License

Apache-2.0

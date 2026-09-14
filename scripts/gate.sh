#!/usr/bin/env bash
#
# Start a Roark simulation, wait for it, and turn its verdict into an exit code.
#
# The pass/fail decision itself is made by Roark, from the success criteria on the
# run plan, so every consumer (this action, the CLI, the dashboard) agrees on
# whether a run passed. This script only transports that verdict into CI.
#
# THREE outcomes, not two. A gate answers exactly one question — "did this change
# make the agent worse?" — and only a run that actually ran can answer it:
#
#   PASSED   every check cleared its own minimum.                        exit 0
#   FAILED   the run completed cleanly and a check fell short.           exit 1
#   SKIPPED  the run never produced a judgeable result: a Roark outage,  exit 0
#            a model-provider blip, sims that died mid-flight, a check
#            that never ran. Loud, but not merge-blocking.
#
# SKIPPED exists because a red build has to mean something. If our own
# infrastructure can turn a pipeline red, the first thing every team learns is to
# re-run until green, and from then on nobody reads the gate at all — including
# the run where the agent really did regress. So our problems are never your
# problem: we warn, we annotate, we do not block your merge. Set
# `fail-on-run-error: true` if you would rather hold the line.
#
# Operational failures POISON the verdict rather than sitting beside it: a check
# reported at 40% when half its simulations never ran is not evidence the agent
# regressed, it is evidence we could not measure. So any operational failure makes
# the whole run SKIPPED, even when a check also fell short.
#
set -euo pipefail

readonly PLAN_ID="${INPUT_PLAN_ID:-}"
readonly CONFIG="${INPUT_CONFIG:-}"
readonly SAVE_AS_PLAN="${INPUT_SAVE_AS_PLAN:-false}"
readonly VARIABLES="${INPUT_VARIABLES:-}"
readonly MIN_PASS_RATE="${INPUT_MIN_PASS_RATE:-}"
readonly TIMEOUT_MINUTES="${INPUT_TIMEOUT_MINUTES:-30}"
readonly POLL_INTERVAL="${INPUT_POLL_INTERVAL_SECONDS:-15}"
readonly FAIL_ON_TIMEOUT="${INPUT_FAIL_ON_TIMEOUT:-false}"
readonly FAIL_ON_RUN_ERROR="${INPUT_FAIL_ON_RUN_ERROR:-false}"
readonly CANCEL_ON_EXIT="${INPUT_CANCEL_ON_EXIT:-true}"
readonly PLATFORM_URL="${ROARK_PLATFORM_URL:-https://platform.roark.ai}"

# How many consecutive poll failures to absorb before giving up. A run takes
# minutes and a poll is one HTTPS call, so a single blip is overwhelmingly likely
# to be the network rather than a real problem. Failing the build on it would
# teach people the gate is flaky and to ignore it.
readonly MAX_POLL_FAILURES=5

# Terminal states. All four carry a verdict: a run that failed or was cancelled
# reports `passed: false` with a RUN_NOT_COMPLETED reason rather than no verdict at
# all, so the gate never has to infer an outcome from the status alone.
is_terminal() {
  case "$1" in
    COMPLETED | FAILED | CANCELLED | TIMED_OUT) return 0 ;;
    *) return 1 ;;
  esac
}

emit() { printf '%s\n' "$1" >>"${GITHUB_OUTPUT:-/dev/null}"; }
summary() { printf '%s\n' "$1" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"; }
die() {
  printf '::error::%s\n' "$1"
  exit 1
}

# Our problem, not yours: the run never produced a judgeable result, so there is no
# verdict to gate on. Reported loudly (annotation + step summary + `verdict=SKIPPED`,
# so a workflow can branch on it to notify or retry) and then exits 0.
#
# `fail-on-run-error: true` turns this back into a hard failure for teams that would
# rather block than proceed unmeasured.
skip() {
  local reason="$1"
  # `caller-summary` = the caller already wrote the step summary (the verdict path
  # has a score line and a failure list to put under the heading). Anything else
  # means this reason IS the whole report.
  local summary_owner="${2:-}"

  emit "skip-reason=${reason}"

  # The escape hatch reports FAILED, not SKIPPED. `verdict` is the gate's decision,
  # and a workflow branching on it must never read "skipped" from a step that went
  # red; the cause survives in `skip-reason` either way.
  if [[ "$FAIL_ON_RUN_ERROR" == 'true' ]]; then
    emit 'verdict=FAILED'
    if [[ "$summary_owner" != 'caller-summary' ]]; then
      summary '### Roark simulation could not be judged'
      summary ''
      summary "$reason"
    fi
    die "${reason} (failing because fail-on-run-error is true)"
  fi

  emit 'verdict=SKIPPED'
  if [[ "$summary_owner" != 'caller-summary' ]]; then
    summary '### Roark simulation skipped'
    summary ''
    summary "$reason"
    if [[ -n "${run_url:-}" ]]; then
      summary ''
      summary "[View run](${run_url})"
    fi
  fi
  printf '::warning::Roark could not judge this run, so the gate is not blocking your merge: %s\n' "$reason"
  # An `if`, not `[[ ... ]] && printf`: under `set -e` a false test as a bare
  # compound command aborts the function before `exit 0`, turning a skip into a
  # failed step, which is the one thing this path must never do.
  if [[ -n "${run_url:-}" ]]; then
    printf '%s\n' "$run_url"
  fi
  exit 0
}

# Whether a CLI error reads as "we were unreachable" rather than "your request was
# wrong". Deliberately a text match and deliberately NARROW: the CLI surfaces one
# non-zero exit for both, and the cost of guessing wrong in each direction is not
# symmetric. Calling a bad plan-id transient would skip forever and never tell you
# the id is wrong; calling an outage fatal is one red build. So anything that does
# not clearly look like 5xx or a dead socket stays fatal.
is_transient_error() {
  printf '%s' "$1" | grep -Eqi '(^|[^0-9])(429|50[0-4])([^0-9]|$)|internal server error|bad gateway|service unavailable|gateway timeout|too many requests|socket hang up|fetch failed|network error|ECONNRESET|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|EAI_AGAIN'
}

# ─── Validate inputs ─────────────────────────────────────────────────────────
if [[ -n "$PLAN_ID" && -n "$CONFIG" ]]; then
  die "Provide either 'plan-id' or 'config', not both."
fi
if [[ -z "$PLAN_ID" && -z "$CONFIG" ]]; then
  die "Provide 'plan-id' (a saved run plan) or 'config' (a YAML file describing the run)."
fi
if [[ -n "$CONFIG" && ! -f "$CONFIG" ]]; then
  die "Config file not found: ${CONFIG}"
fi
if [[ "$SAVE_AS_PLAN" == 'true' && -z "$CONFIG" ]]; then
  die "'save-as-plan' applies to 'config' only. A run started from 'plan-id' is already using a saved plan."
fi

# ─── Build the request body ──────────────────────────────────────────────────
# `variables` arrives as KEY=VALUE lines; the API wants an object. Sliced at the
# FIRST '=' so a value may carry both '=' and spaces ("customerName=John Doe") —
# splitting on whitespace silently dropped those. Blank lines and '#' comments are
# ignored; a line with no '=' is skipped rather than becoming a null value.
variables_json() {
  if [[ -z "$VARIABLES" ]]; then
    printf '{}'
    return
  fi
  printf '%s' "$VARIABLES" | jq -R -s -c '
    split("\n")
    | map(rtrimstr("\r"))
    | map(select(length > 0 and (startswith("#") | not) and (index("=") != null)))
    | map({ (.[:index("=")] | gsub("^\\s+|\\s+$"; "")): (.[index("=")+1:] | gsub("^\\s+|\\s+$"; "")) })
    | add // {}
  '
}

build_body() {
  local variables
  variables="$(variables_json)"

  if [[ -n "$PLAN_ID" ]]; then
    jq -n --arg planId "$PLAN_ID" --argjson variables "$variables" \
      '{ planId: $planId, variables: $variables }'
    return
  fi

  # Without `saveAsPlan` a YAML config runs as a one-off: the API still creates a
  # plan to carry it, but it stays hidden rather than cluttering the saved plans.
  # With it, the plan is kept and its id is reported, so a pipeline can bootstrap a
  # plan on its first run and pass `plan-id` from then on.
  python3 -c '
import json, sys, yaml
plan = yaml.safe_load(open(sys.argv[1])) or {}
print(json.dumps(plan))
' "$CONFIG" | jq --argjson variables "$variables" --argjson save "$SAVE_AS_PLAN" \
    '{ plan: ., variables: $variables, saveAsPlan: $save }'
}

# ─── Start the run ───────────────────────────────────────────────────────────
body="$(build_body)"
printf '::group::Starting simulation\n'
printf '%s\n' "$body" | jq .
printf '::endgroup::\n'

# A start that fails is usually YOUR side (a bad token, an unknown plan-id, a config
# the API rejects) and those must stay red — a gate that skips on a typo never gates
# again. Only an error that reads as ours is skipped.
if ! start_response="$(printf '%s' "$body" | roark simulation run --data @- 2>&1)"; then
  if is_transient_error "$start_response"; then
    skip "Roark could not start the simulation: ${start_response}"
  fi
  die "Failed to start the simulation: ${start_response}"
fi

run_id="$(printf '%s' "$start_response" | jq -r '.data.simulationRunPlanJobId // .simulationRunPlanJobId // empty')"
[[ -n "$run_id" ]] || die "Could not read a run id from the API response: ${start_response}"

plan_id="$(printf '%s' "$start_response" | jq -r '.data.simulationRunPlanId // .simulationRunPlanId // empty')"
run_url="${PLATFORM_URL}/simulations/runs/${run_id}"
emit "run-id=${run_id}"
emit "run-url=${run_url}"
emit "plan-id=${plan_id}"
printf '▶ Simulation started: %s\n' "$run_url"
if [[ "$SAVE_AS_PLAN" == 'true' && -n "$plan_id" ]]; then
  printf '  Saved as run plan %s. Pass it as plan-id to reuse this configuration.\n' "$plan_id"
fi

# ─── Stop the run if CI goes away ────────────────────────────────────────────
# A cancelled workflow leaves the simulation running: it keeps placing real calls
# for a result nobody will read, and the customer is billed for them. Cancel on the
# way out instead. Best-effort and never the reason the step fails, and idempotent
# server-side, so a run that finished a moment earlier is a no-op.
cancel_run() {
  [[ "$CANCEL_ON_EXIT" == 'true' ]] || return 0
  printf '::warning::Cancelled. Stopping Roark run %s.\n' "$run_id"
  # Called through `roark api` rather than a generated command on purpose: cancel has
  # no generated verb in every CLI version this action may run against, and the raw
  # route is stable and present in every version that can start a run at all.
  #
  # Best-effort, but NOT silent. This runs from a trap, so it must never be the reason
  # the step fails — every path below returns 0. But it used to discard the outcome
  # entirely (`>/dev/null 2>&1 || true`), which made a 500, a 404, a missing CLI and a
  # success all print the same "Stopping Roark run" line. A cancel that quietly failed
  # leaves the run placing real calls the customer is billed for, which is the one
  # thing cancel-on-exit exists to prevent, so the outcome is reported either way.
  #
  # `local` is declared separately from the assignment: `local out="$(cmd)"` would
  # take `local`'s own exit status and mask the command's. `|| status=$?` keeps
  # `set -e` from aborting the trap before the message below is printed.
  local cancel_output='' cancel_status=0
  cancel_output="$(roark api post "/v1/simulation/plan/job/${run_id}/cancel" 2>&1)" || cancel_status=$?
  if ((cancel_status == 0)); then
    printf '  Roark run %s stopped.\n' "$run_id"
    return 0
  fi
  printf '::error::Could not stop Roark run %s (exit %s). It may still be running, and you are billed for the calls it places. Stop it at %s. Response: %s\n' \
    "$run_id" "$cancel_status" "$run_url" "$(printf '%s' "$cancel_output" | tr '\n' ' ' | cut -c1-300)"
  return 0
}
trap 'cancel_run; exit 130' INT TERM

# ─── Wait for it ─────────────────────────────────────────────────────────────
deadline=$((SECONDS + TIMEOUT_MINUTES * 60))
status='PENDING'
poll_response=''
consecutive_failures=0

while :; do
  if poll_response="$(roark simulation plan job get "$run_id" 2>&1)"; then
    status="$(printf '%s' "$poll_response" | jq -r '.data.status // .status // empty')"
  else
    status=''
  fi

  if [[ -z "$status" ]]; then
    consecutive_failures=$((consecutive_failures + 1))
    if ((consecutive_failures >= MAX_POLL_FAILURES)); then
      # The run itself is probably still fine; we just cannot see it. That is
      # squarely our problem, and the run is left alone rather than cancelled so
      # its result is still there to read once we are reachable again.
      skip "Could not read run ${run_id} after ${MAX_POLL_FAILURES} consecutive attempts: ${poll_response}"
    fi
    printf '::warning::Could not read run %s (attempt %s of %s), retrying.\n' \
      "$run_id" "$consecutive_failures" "$MAX_POLL_FAILURES"
  else
    consecutive_failures=0
    is_terminal "$status" && break
    printf '  %s … waiting\n' "$status"
  fi

  if ((SECONDS >= deadline)); then
    cancel_run
    if [[ "$FAIL_ON_TIMEOUT" == 'true' ]]; then
      emit "verdict=TIMED_OUT"
      summary "### Roark simulation did not finish within ${TIMEOUT_MINUTES} minutes"
      summary ""
      summary "Last status: \`${status:-unknown}\` · [View run](${run_url})"
      die "Timed out after ${TIMEOUT_MINUTES} minutes waiting for run ${run_id} (last status: ${status:-unknown})."
    fi
    # Waiting longer than expected is our slowness, not your regression, so it takes
    # the same non-blocking path as any other unjudgeable run.
    skip "Roark simulation did not finish within ${TIMEOUT_MINUTES} minutes (last status: ${status:-unknown})."
  fi

  sleep "$POLL_INTERVAL"
done

# The run is finished: there is nothing left to cancel, and leaving the trap armed
# would fire it on the exit code we are about to set.
trap - INT TERM

# ─── Turn the verdict into an exit code ──────────────────────────────────────
# The API returns `verdict`: the run judged against the success criteria pinned on
# the plan when it started. Two numbers live on it and only ONE decides anything:
#
#   passed  — every check cleared its OWN minimum. This is the exit status.
#   score   — the mean of the check rates. REPORTING ONLY. A run can score 95 and
#             fail, or score 40 and pass, so nothing is gated on it.
verdict="$(printf '%s' "$poll_response" | jq -c '.data.verdict // .verdict // empty')"

if [[ -z "$verdict" || "$verdict" == 'null' ]]; then
  # NOT a skip, deliberately. Every other unjudgeable outcome is our fault and gets
  # out of your way; this one is a plan that cannot gate anything — it has no boolean
  # metric and no threshold on the metrics it does collect, so there was nothing to
  # judge and there never will be. Skipping it would leave a green check next to a
  # gate that is permanently a no-op, which is worse than red because nobody notices.
  die "This run produced no pass/fail verdict: the run plan has no check to judge. Add a threshold to one of its metrics, or attach a yes/no metric, then re-run. Run: ${run_url}"
fi

passed="$(printf '%s' "$verdict" | jq -r '.passed')"

# Split the run's failures into the two kinds that mean completely different things.
#
#   criteria      — METRIC_BELOW_MIN_PASS_RATE. The run measured your agent and your
#                   agent fell short. THE ONLY THING THAT TURNS THIS STEP RED.
#   operational   — everything else: the run did not complete (RUN_NOT_COMPLETED),
#                   sims dropped out before they were graded (INCOMPLETE_COVERAGE),
#                   or a check produced no result at all (METRIC_NOT_EVALUATED).
#                   Roark infrastructure, a model provider, a cloud region: ours.
#
# An unknown `type` counts as operational. A failure kind this version of the action
# has never heard of is one we added after it shipped, and inventing a red build out
# of a string we cannot read is not a judgement about your agent. It still prints.
operational_failures="$(printf '%s' "$verdict" | jq -c '[.failures[] | select(.type != "METRIC_BELOW_MIN_PASS_RATE")]')"
operational_count="$(printf '%s' "$operational_failures" | jq -r 'length')"
score="$(printf '%s' "$verdict" | jq -r 'if .score == null then empty else (.score * 10 | round) / 10 end')"
checks_total="$(printf '%s' "$verdict" | jq -r '.checks | length')"
checks_passed="$(printf '%s' "$verdict" | jq -r '[.checks[] | select(.passed)] | length')"

# One line per operational failure, in the same shape as render_failures below.
render_operational() {
  printf '%s' "$operational_failures" | jq -r '
    .[] |
    if   .type == "RUN_NOT_COMPLETED"    then "- The run did not complete (\(.status)), so there is no result to judge."
    elif .type == "INCOMPLETE_COVERAGE"  then "- Only \(.evaluatedCalls) of \(.expectedCalls) simulations were evaluated, so the run was judged on an incomplete set."
    elif .type == "METRIC_NOT_EVALUATED" then "- `\(.metricName // .metricDefinitionId)` produced no result on any simulation."
    else "- \(.type)" end
  '
}

# A pipeline-level override, applied on top of the server's verdict: the run plan
# stays the shared baseline while one branch holds itself to a higher bar.
#
# It tightens EACH CHECK's own minimum — max(check's bar, pipeline's bar) — rather
# than thresholding `score`. Gating on the score would let a check at 0% hide behind
# checks at 100%, which is exactly what per-check minimums exist to prevent.
#
# Tighten-only by construction: raising a bar can never rescue a check that already
# missed the lower one, so a run the plan failed stays failed. Loosening would mean
# overruling the minimums the plan's owner set, which is not a pipeline's call.
tightened=''
if [[ -n "$MIN_PASS_RATE" ]]; then
  tightened="$(printf '%s' "$verdict" | jq -c --argjson bar "$MIN_PASS_RATE" '
    [ .checks[]
      | select(.passed)
      | (( [.minPassRate, $bar] | max )) as $effective
      | select(.passRate == null or .passRate < $effective)
      | { metricName, metricDefinitionId, passRate, effective: $effective }
    ]')"
  if [[ "$(printf '%s' "$tightened" | jq -r 'length')" != '0' ]]; then
    passed='false'
  fi
fi

emit "score=${score}"
emit "checks-passed=${checks_passed}"
emit "checks-total=${checks_total}"

# One line per missed criterion, in the customer's terms. Every arm matches a
# `type` the API actually emits; an unknown type still prints rather than being
# silently dropped, so a new failure kind degrades to noisy instead of invisible.
render_failures() {
  printf '%s' "$verdict" | jq -r '
    .failures[] |
    if   .type == "RUN_NOT_COMPLETED"        then "- The run did not complete (\(.status)), so there is no result to judge."
    elif .type == "INCOMPLETE_COVERAGE"      then "- Only \(.evaluatedCalls) of \(.expectedCalls) simulations were evaluated, so the run was judged on an incomplete set."
    elif .type == "METRIC_NOT_EVALUATED"     then "- `\(.metricName // .metricDefinitionId)` produced no result on any simulation."
    elif .type == "METRIC_BELOW_MIN_PASS_RATE" then "- `\(.metricName // .metricDefinitionId)` passed \(.passRate)% of simulations, below \(if .inherited then "the default minimum" else "its own minimum" end) of \(.minPassRate)%."
    else "- \(.type)" end
  '
  # Failures the pipeline's own stricter bar introduced. Reported separately: the
  # plan was fine with these, this pipeline is not, and conflating the two sends
  # people to edit a plan that never failed.
  if [[ -n "$tightened" && "$(printf '%s' "$tightened" | jq -r 'length')" != '0' ]]; then
    printf '%s' "$tightened" | jq -r --argjson bar "$MIN_PASS_RATE" '
      .[] | "- `\(.metricName // .metricDefinitionId)` passed \(.passRate // "no")% of simulations, below this pipeline'"'"'s min-pass-rate of \($bar)%."
    '
  fi
}

# `score` is absent when nothing was evaluated, which is not the same as a score of
# zero: nothing was measured, rather than everything failing.
score_line() {
  if [[ -n "$score" ]]; then
    printf 'score %s%%, %s of %s checks cleared their minimums' \
      "$score" "$checks_passed" "$checks_total"
  else
    printf 'no score (nothing was evaluated), %s of %s checks cleared their minimums' \
      "$checks_passed" "$checks_total"
  fi
}

# Checked BEFORE pass/fail, and before the pipeline's own tightening above had any
# say: the run could not be measured properly, so it cannot testify about your agent
# in either direction. A check sitting below its bar on a run that half-collapsed is
# not a regression, and applying a stricter bar to numbers we do not trust would only
# invent a more confident wrong answer.
if ((operational_count > 0)); then
  summary '### Roark simulation skipped'
  summary ''
  summary 'The run did not produce a judgeable result, so there was nothing to gate on.'
  summary ''
  render_operational >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  summary ''
  summary "$(score_line)"
  summary ''
  summary "[View run](${run_url})"
  printf 'Roark could not judge this run: %s\n' "$(score_line)"
  render_operational
  skip 'The run did not produce a judgeable result, so there was nothing to gate on.' caller-summary
fi

if [[ "$passed" == 'true' ]]; then
  emit "verdict=PASSED"
  summary "### ✅ Roark simulation passed"
  summary ""
  summary "$(score_line)"
  summary ""
  summary "[View run](${run_url})"
  printf '✅ Passed: %s\n%s\n' "$(score_line)" "$run_url"
  exit 0
fi

emit "verdict=FAILED"
summary "### ❌ Roark simulation failed"
summary ""
summary "$(score_line)"
summary ""
render_failures >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
summary ""
summary "[View run](${run_url})"

printf '❌ Failed: %s\n' "$(score_line)"
render_failures
printf '%s\n' "$run_url"
exit 1

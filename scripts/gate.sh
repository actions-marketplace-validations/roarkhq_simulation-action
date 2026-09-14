#!/usr/bin/env bash
#
# Start a Roark simulation, wait for it, and turn its verdict into an exit code.
#
# The pass/fail decision itself is made by Roark, from the success criteria on the
# run plan, so every consumer (this action, the CLI, the dashboard) agrees on
# whether a run passed. This script only transports that verdict into CI.
#
set -euo pipefail

readonly PLAN_ID="${INPUT_PLAN_ID:-}"
readonly CONFIG="${INPUT_CONFIG:-}"
readonly SAVE_AS_PLAN="${INPUT_SAVE_AS_PLAN:-false}"
readonly VARIABLES="${INPUT_VARIABLES:-}"
readonly MIN_PASS_RATE="${INPUT_MIN_PASS_RATE:-}"
readonly TIMEOUT_MINUTES="${INPUT_TIMEOUT_MINUTES:-30}"
readonly POLL_INTERVAL="${INPUT_POLL_INTERVAL_SECONDS:-15}"
readonly FAIL_ON_TIMEOUT="${INPUT_FAIL_ON_TIMEOUT:-true}"
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

start_response="$(printf '%s' "$body" | roark simulation run --data @- 2>&1)" ||
  die "Failed to start the simulation: ${start_response}"

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
      die "Could not read run ${run_id} after ${MAX_POLL_FAILURES} consecutive attempts: ${poll_response}"
    fi
    printf '::warning::Could not read run %s (attempt %s of %s), retrying.\n' \
      "$run_id" "$consecutive_failures" "$MAX_POLL_FAILURES"
  else
    consecutive_failures=0
    is_terminal "$status" && break
    printf '  %s … waiting\n' "$status"
  fi

  if ((SECONDS >= deadline)); then
    emit "verdict=TIMED_OUT"
    summary "### ⏱ Roark simulation did not finish within ${TIMEOUT_MINUTES} minutes"
    summary ""
    summary "Last status: \`${status:-unknown}\` · [View run](${run_url})"
    cancel_run
    if [[ "$FAIL_ON_TIMEOUT" == 'true' ]]; then
      die "Timed out after ${TIMEOUT_MINUTES} minutes waiting for run ${run_id} (last status: ${status:-unknown})."
    fi
    # Deliberately not a failure: waiting longer than expected is our problem, and
    # blocking the merge on it would train people to ignore the gate. A real check
    # failure still fails, loudly.
    printf '::warning::Roark simulation timed out after %s minutes (last status: %s). Not failing because fail-on-timeout is false. %s\n' \
      "$TIMEOUT_MINUTES" "${status:-unknown}" "$run_url"
    exit 0
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
  # Never treat a missing verdict as a pass — that would make the gate a silent
  # no-op, which is worse than a red build because nobody notices. Success criteria
  # are mandatory on every plan, so a null verdict means the plan measures nothing
  # that produces a pass/fail: it has no boolean metric, and no threshold on any of
  # the metrics it does collect, so there was nothing to judge.
  die "This run produced no pass/fail verdict: the run plan has no check to judge. Add a threshold to one of its metrics, or attach a yes/no metric, then re-run. Run: ${run_url}"
fi

passed="$(printf '%s' "$verdict" | jq -r '.passed')"
score="$(printf '%s' "$verdict" | jq -r 'if .score == null then empty else (.score * 10 | round) / 10 end')"
checks_total="$(printf '%s' "$verdict" | jq -r '.checks | length')"
checks_passed="$(printf '%s' "$verdict" | jq -r '[.checks[] | select(.passed)] | length')"

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

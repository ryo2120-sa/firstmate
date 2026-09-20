#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml's runner-spend safeguards.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident. firstmate CI had no
# concurrency deduplication, so every superseded PR head kept its full job
# fan-out, and four jobs carried no timeout at all. These tests hold both
# safeguards: PR runs supersede within one PR while main pushes are never
# cancelled, and every CI job carries a finite hang tripwire.
#
# The workflow is parsed as YAML and its concurrency expressions are resolved
# against simulated pull_request and push contexts, so the assertions describe
# what GitHub would do, not how the file happens to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/ci.yml as YAML"

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>". Only the expression constructs
# this workflow uses are resolved: an `a || b` fallback, an `a && b` guard
# (GitHub Actions semantics: returns b when a is truthy, otherwise falls
# through to the next `||` alternative), and an `==` comparison.
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3 action=${4:-}
  # shellcheck disable=SC2016 # Ruby, not the shell, expands $ARGV/${{...}}.
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.run_id" => ARGV[3],
  "github.event.action" => ARGV[4],
}

value = lambda do |token|
  token = token.strip
  next token[1..-2] if token.start_with?("\x27") && token.end_with?("\x27")
  raise "unresolvable context reference: #{token}" unless context.key?(token)
  context.fetch(token)
end

# Evaluate one `||`-separated term, which may itself be an `a == b && c`
# guard. Returns the resolved string, or nil when the term is falsy (either
# an empty context value, or a guard whose condition did not hold).
evaluate_term = lambda do |term|
  term = term.strip
  if term.include?("&&")
    condition, consequent = term.split("&&", 2)
    condition = condition.strip
    next nil unless condition.include?("==")
    left, right = condition.split("==", 2)
    next nil unless value.call(left) == value.call(right)
    resolved = value.call(consequent)
    next resolved.empty? ? nil : resolved
  end
  resolved = value.call(term)
  resolved.empty? ? nil : resolved
end

evaluate = lambda do |expression|
  expression = expression.strip
  if expression.include?("==") && !expression.include?("&&")
    left, right = expression.split("==", 2)
    next value.call(left) == value.call(right) ? "true" : "false"
  end
  resolved = expression.split("||").map { |term| evaluate_term.call(term) }.find { |v| v }
  resolved.to_s
end

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { evaluate.call(Regexp.last_match(1)) }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$CI_WORKFLOW" "$event" "$pr_number" "$run_id" "$action"
}

job_timeout() {
  ruby -ryaml -e '
puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$1"
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_are_never_cancelled() {
  local first second
  first=$(resolve_concurrency push '' 900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "each main push must get its own concurrency group, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel an in-progress run, got $(cancel_of "$first")"
  pass "every main push keeps its own group and is never cancelled"
}

test_every_job_has_a_finite_timeout() {
  local reported
  reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  timeout = job["timeout-minutes"]
  next if timeout.is_a?(Integer) && timeout > 0
  puts "#{name}: #{timeout.inspect}"
end
' "$CI_WORKFLOW") || fail "could not read job timeouts from ci.yml"
  [ -z "$reported" ] || fail "these CI jobs have no finite hang tripwire:"$'\n'"$reported"
  pass "every ci.yml job carries a finite timeout"
}

# The four jobs the incident found unbounded, at the report's recommended caps.
test_previously_unbounded_jobs_keep_their_caps() {
  local job expected actual
  while read -r job expected; do
    [ -n "$job" ] || continue
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    [ "$actual" = "$expected" ] \
      || fail "$job timeout must stay $expected minutes, got $actual"
  done <<'CAPS'
lint 25
test-coverage 5
tests-timing-aggregate 5
invariants 5
CAPS
  pass "the incident's unbounded jobs keep their recommended caps"
}

# Cancellation makes an undersized cap costlier: a falsely tripped job now also
# discards a run nobody replaced. These bounds were measured, not guessed.
test_measured_lanes_keep_their_existing_bounds() {
  local job expected actual
  while read -r job expected; do
    [ -n "$job" ] || continue
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    [ "$actual" = "$expected" ] \
      || fail "$job timeout must stay $expected minutes, got $actual"
  done <<'CAPS'
tests-portable-parallel-1 10
tests-portable-parallel-2 10
tests-portable-serial 30
tests-herdr 75
macos-stock-bash 10
CAPS
  pass "the already-measured lane bounds are unchanged"
}

# A pull_request body edit (github.event.action == edited), such as the
# no-mistakes pipeline's own mid-run PR-body update, carries no new commit.
# It must never share the per-PR group that real head-change actions use for
# that same PR, so it can never cancel a genuine in-flight CI run validating
# that commit. Reproduces the September 20 self-cancel incident: eleven jobs
# had passed and two were still running when the pipeline's own body edit
# collided with the shared group and killed them with no verdict.
test_pr_body_edit_does_not_share_the_pr_group() {
  local opened edited
  opened=$(resolve_concurrency pull_request 108 900001 opened) || fail "could not resolve PR concurrency"
  edited=$(resolve_concurrency pull_request 108 900002 edited) || fail "could not resolve edited-action concurrency"
  [ "$(group_of "$opened")" != "$(group_of "$edited")" ] \
    || fail "a PR body edit must not share the PR's concurrency group ($(group_of "$opened"))"
  pass "a PR body edit gets its own concurrency group, isolated from the PR's group"
}

# Two body edits on the same PR must not collide with each other either,
# since each is keyed by its own unique run id.
test_two_pr_body_edits_do_not_collide() {
  local first second
  first=$(resolve_concurrency pull_request 108 900002 edited) || fail "could not resolve edited-action concurrency"
  second=$(resolve_concurrency pull_request 108 900003 edited) || fail "could not resolve edited-action concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "two distinct PR body edits must not share a concurrency group ($(group_of "$first"))"
  pass "distinct PR body edits get distinct concurrency groups"
}

# Genuine head changes (opened/synchronize/reopened) must still supersede
# each other within one PR even after the edited-action carve-out.
test_pr_pushes_still_supersede_after_edited_carve_out() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001 synchronize) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900004 synchronize) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two synchronize runs of one PR must still share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "synchronize runs must still cancel the in-progress run, got $(cancel_of "$first")"
  pass "genuine pushes still supersede within one PR after the edited-action carve-out"
}

test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_are_never_cancelled
test_every_job_has_a_finite_timeout
test_previously_unbounded_jobs_keep_their_caps
test_measured_lanes_keep_their_existing_bounds
test_pr_body_edit_does_not_share_the_pr_group
test_two_pr_body_edits_do_not_collide
test_pr_pushes_still_supersede_after_edited_carve_out

#!/usr/bin/env bash
# test-hooks.sh — TDD test suite for branch-autonomous hooks
# Runs in a real git repo; all tests share the same repo
#
# Usage: ./test-hooks.sh [test-name]
#   No arg  → run all tests
#   test-name → run only that test

set -uo pipefail  # NOT -e because ((x++)) returns 0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# ─── Global state ─────────────────────────────────────────────────────────────
TEST_REPO=""
ORIGIN_DIR=""
BRANCH_AUTONOMOUS_DIR="$HOME/.branch-autonomous"
passed=0; failed=0

# ─── Assert helpers ─────────────────────────────────────────────────────────────
assert_eq() {
  local exp="$1" act="$2" msg="$3"
  if [[ "$exp" == "$act" ]]; then
    echo -e "  ${GREEN}✓${NC} $msg"; passed=$((passed + 1))
  else
    echo -e "  ${RED}✗${NC} $msg"; echo -e "    Expected: '$exp'"; echo -e "    Actual:   '$act'"
    failed=$((failed + 1))
  fi
}

assert_contains() {
  local hay="$1" needle="$2" msg="$3"
  if echo "$hay" | grep -qF -- "$needle"; then
    echo -e "  ${GREEN}✓${NC} $msg"; passed=$((passed + 1))
  else
    echo -e "  ${RED}✗${NC} $msg"; failed=$((failed + 1))
  fi
}

assert_file_exists() {
  if [[ -f "$1" ]]; then
    echo -e "  ${GREEN}✓${NC} $1"; passed=$((passed + 1))
  else
    echo -e "  ${RED}✗${NC} $1 not found"; failed=$((failed + 1))
  fi
}

assert_json_field() {
  local f="$1" field="$2" exp="$3"
  local act
  act=$(jq -r ".$field" "$f" 2>/dev/null || echo "___ERR___")
  assert_eq "$exp" "$act" "JSON .$field"
}

assert_json_true() {
  local f="$1" field="$2" msg="$3"
  local act; act=$(jq -r ".$field" "$f" 2>/dev/null || echo "___ERR___")
  [[ "$act" == "true" ]] && { echo -e "  ${GREEN}✓${NC} $msg"; passed=$((passed + 1)); } \
    || { echo -e "  ${RED}✗${NC} $msg (got: '$act')"; failed=$((failed + 1)); }
}

assert_json_false() {
  local f="$1" field="$2" msg="$3"
  local act; act=$(jq -r ".$field" "$f" 2>/dev/null || echo "___ERR___")
  [[ "$act" == "false" ]] && { echo -e "  ${GREEN}✓${NC} $msg"; passed=$((passed + 1)); } \
    || { echo -e "  ${RED}✗${NC} $msg (got: '$act')"; failed=$((failed + 1)); }
}

# ─── Setup ───────────────────────────────────────────────────────────────────
setup() {
  TEST_REPO=$(mktemp -d /tmp/bta-test.XXXXXX)
  ORIGIN_DIR=$(mktemp -d /tmp/bta-origin.XXXXXX)

  echo "=== Setup: $TEST_REPO ==="
  mkdir -p "$BRANCH_AUTONOMOUS_DIR"

  cd "$TEST_REPO"
  git init -q && git config user.email test@test.local && git config user.name "Test"
  git branch -m master main

  echo "init" > README.md && git add README.md && git commit -q -m init

  git init -q --bare "$ORIGIN_DIR"
  git remote add origin "$ORIGIN_DIR"
  git push -q origin main

  git checkout -q -b feature/test
  echo "content" > feature.md && git add feature.md && git commit -q -m "feat: initial feature"
  git push -q origin feature/test

  echo "Repo ready."
}

teardown() {
  if [[ $failed -gt 0 ]]; then
    echo -e "\n${YELLOW}FAILED — repos left at: $TEST_REPO and $ORIGIN_DIR${NC}"
  else
    rm -rf "$TEST_REPO" "$ORIGIN_DIR"
    echo "Repos cleaned up."
  fi
}

report() {
  echo -e "\n================================\nResults: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}\n================================"
  [[ $failed -gt 0 ]] && exit 1 || exit 0
}

# ─── Tests ─────────────────────────────────────────────────────────────────────

t01_state_json_init() {
  echo; echo "=== t01: state.json initialization ==="
  cd "$TEST_REPO"

  local branch session_id now
  branch=$(git symbolic-ref --short HEAD)
  session_id="test-$(date +%s)"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  jq -n \
    --arg branch "$branch" \
    --arg session_id "$session_id" \
    --arg now "$now" \
    '{
      version: "3.0",
      session_id: $session_id,
      branch: $branch,
      branch_type: (if ($branch | startswith("feature")) then "feature"
                    elif ($branch | startswith("fix")) then "fix"
                    elif ($branch | startswith("hotfix")) then "hotfix"
                    else "other" end),
      test_passed: false,
      test_passed_at: null,
      test_failed_at: null,
      uncommitted_files: 0,
      uncommitted_lines: 0,
      last_commit_at: null,
      last_commit_message: null,
      milestone: false,
      milestone_reason: null,
      awaiting_squash_push: false,
      awaiting_merge_confirmation: false,
      commits_since_last_tag: 0,
      created_at: $now
    }' > "$BRANCH_AUTONOMOUS_DIR/state.json"

  assert_file_exists "$BRANCH_AUTONOMOUS_DIR/state.json"
  assert_json_field "$BRANCH_AUTONOMOUS_DIR/state.json" "branch" "feature/test"
  assert_json_field "$BRANCH_AUTONOMOUS_DIR/state.json" "branch_type" "feature"
  assert_json_field "$BRANCH_AUTONOMOUS_DIR/state.json" "milestone" "false"
  assert_json_field "$BRANCH_AUTONOMOUS_DIR/state.json" "awaiting_squash_push" "false"
}

t02_branch_type() {
  echo; echo "=== t02: branch type detection ==="

  local cases=(
    "feature/search:feature"
    "fix/auth-bug:fix"
    "hotfix/critical:hotfix"
    "main:other"
    "dev:other"
    "release/v1:other"
  )

  for tc in "${cases[@]}"; do
    local branch="${tc%%:*}"
    local expected="${tc##*:}"
    local detected
    detected=$(jq -nr --arg b "$branch" \
      'if ($b | startswith("feature")) then "feature"
       elif ($b | startswith("fix")) then "fix"
       elif ($b | startswith("hotfix")) then "hotfix"
       else "other" end')
    assert_eq "$expected" "$detected" "'$branch' → '$expected'"
  done
}

t03_milestone_detection() {
  echo; echo "=== t03: milestone detection ==="
  cd "$TEST_REPO"

  # Create 10 checkpoint commits
  for i in $(seq 1 10); do
    echo "change $i" >> feature.md
    git add feature.md && git commit -q -m "checkpoint: change $i"
  done

  # Test 1: no tags → handle gracefully
  local last_tag
  last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
  local count
  count=$(git rev-list --count HEAD ^"$last_tag" 2>/dev/null || echo "0")
  assert_eq "0" "$count" "No tags → commits_since_tag = 0"

  # Test 2: conventional commit detection
  local msg
  msg=$(git log -1 --format="%s")
  local conv
  if echo "$msg" | grep -qE "^(feat|fix|perf|ci):"; then conv="true"; else conv="false"; fi
  assert_eq "false" "$conv" "'$msg' is NOT conventional"

  # Test 3: add conventional commit (need a new file change since feature.md already committed)
  echo "newcontent" >> newfile.txt && git add newfile.txt
  git commit -q -m "feat: add search indexing"
  msg=$(git log -1 --format="%s")
  if echo "$msg" | grep -qE "^(feat|fix|perf|ci):"; then conv="true"; else conv="false"; fi
  assert_eq "true" "$conv" "'$msg' IS conventional"

  # Test 4: tag + count
  git tag -a v0.1.0 -m "test tag"
  last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
  assert_eq "v0.1.0" "$last_tag" "Tag: v0.1.0"
  count=$(git rev-list --count HEAD ^"$last_tag" 2>/dev/null || echo "0")
  assert_eq "0" "$count" "After tag: 0 commits since last tag"
}

t04_guard_bash_rules() {
  echo; echo "=== t04: guard-bash dangerous command rules ==="

  # Simulate guard_is_dangerous() from guard-bash.sh
  guard_dangerous() {
    local cmd="$1"
    local d="false"

    # Rule 1: File writes with > or >> (not to /dev/null)
    if echo "$cmd" | grep -qE '(\s>>|\s>)' && ! echo "$cmd" | grep -qE '>(2\s*)?\s*/dev/null'; then
      d="true"
    fi
    # Rule 2: git push to main/master
    if echo "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+[^;]*(main|master|refs/heads/main|refs/heads/master)'; then
      d="true"
    fi
    # Rule 3: bare --force or -f (no --force-with-lease)
    if echo "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+[^;]*--force($| )' && \
       ! echo "$cmd" | grep -qE 'force-with-lease'; then
      d="true"
    fi
    if echo "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+[^;]*'"-f($| )" && \
       ! echo "$cmd" | grep -qE 'force-with-lease'; then
      d="true"
    fi
    # Rule 4: git reset --hard (bare form only)
    if echo "$cmd" | grep -qE 'git[[:space:]]+reset[[:space:]]+--hard$'; then
      d="true"
    fi
    # Rule 5: git clean -x or -X
    if echo "$cmd" | grep -qE 'git[[:space:]]+clean[[:space:]]+-[fFxX]'; then
      d="true"
    fi
    # Rule 6: delete main/master
    if echo "$cmd" | grep -qE 'git[[:space:]]+branch[[:space:]]+-[Dd][[:space:]]+(main|master)'; then
      d="true"
    fi
    # Rule 7: merge onto main/master
    if echo "$cmd" | grep -qE 'git[[:space:]]+merge[[:space:]]+[^;]*(main|master)'; then
      d="true"
    fi
    # Rule 8: rebase onto main/master
    if echo "$cmd" | grep -qE 'git[[:space:]]+rebase[[:space:]]+[^;]*(main|master)'; then
      d="true"
    fi
    # Bug fix: refspec push to main/master
    if echo "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+[^;]*:[^;]*(main|master)'; then
      d="true"
    fi

    echo "$d"
  }

  # cmd|expected|description  (pipe delimiter avoids colon-conflict with git commands)
  local cases=(
    "echo hello > /tmp/x|true|file write with >"
    "echo hello >> /tmp/x|true|file write with >>"
    "cat file > /dev/null|false|redirect to /dev/null is allowed"
    "git push origin main|true|push to main"
    "git push origin master|true|push to master"
    "git push origin feature/test|false|push to feature branch"
    "git push --force|true|bare --force"
    "git push --force-with-lease|false|force-with-lease is allowed"
    "git push -f|true|push -f (dangerous without FWL)"
    "git push origin -f|true|push origin -f (dangerous)"
    "git reset --hard|true|reset --hard bare form"
    "git reset --hard HEAD~1|false|reset with arg is allowed"
    "git clean -x|true|clean -x"
    "git clean -X|true|clean -X"
    "git clean -fd|true|clean -fd (contains -f)"
    "git clean -fdx|true|clean -fdx (contains -f and -x)"
    "git branch -d main|true|delete main"
    "git branch -D master|true|delete master"
    "git branch -d feature/test|false|delete feature branch"
    "git merge main|true|merge onto main"
    "git merge master|true|merge onto master"
    "git merge feature/other|false|merge feature into current"
    "git rebase main|true|rebase onto main"
    "git rebase master|true|rebase onto master"
    "git rebase feature/other|false|rebase onto feature"
    "git push origin HEAD:master|true|refspec push HEAD:master"
    "git push origin HEAD:refs/heads/main|true|refspec push to refs/heads/main"
    "git push origin feature/test|false|normal push"
    "sed -i 's/foo/bar/' file|false|sed -i without redirect (safe in-place edit)"
    "cat file > output.txt|true|cat redirect to file"
    "git checkout main|false|checkout to main (not a write)"
  )

  for tc in "${cases[@]}"; do
    local cmd expected desc rest
    cmd="${tc%%|*}"
    rest="${tc#*|}"
    expected="${rest%%|*}"
    desc="${rest#*|}"
    local result
    result=$(guard_dangerous "$cmd")
    assert_eq "$expected" "$result" "'$cmd' → dangerous=$expected ($desc)"
  done
}

t05_squash_logic() {
  echo; echo "=== t05: pre-push squash logic ==="
  cd "$TEST_REPO"

  local commits
  commits=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "0")

  # should_squash: awaiting_squash_push=true AND commits >= 2
  should_squash() {
    [[ "$1" == "true" ]] && [[ "$2" -ge 2 ]] && echo "true" || echo "false"
  }

  assert_eq "true"  "$(should_squash true 11)"  "awaiting=true + 11 commits → squash"
  assert_eq "false" "$(should_squash false 11)" "awaiting=false → no squash"
  assert_eq "false" "$(should_squash true 1)"   "awaiting=true + 1 commit → no squash"
  assert_eq "false" "$(should_squash true 0)"   "0 commits → no squash"

  # Squash message generation — use tr instead of paste (macOS BSD incompatible with stdin pipe)
  local msgs
  msgs=$(git log --format="%s" origin/main..HEAD 2>/dev/null | tr '\n' '|' | sed 's/|$//')
  assert_contains "$msgs" "feat:" "Squash msg contains conventional commits"
}

t06_auto_commit_threshold() {
  echo; echo "=== t06: auto-commit threshold ==="
  cd "$TEST_REPO"

  for i in $(seq 1 6); do
    echo "x" > "untracked_$i.txt"
  done

  local count
  count=$(git status --porcelain | wc -l | tr -d ' ')
  local threshold=5
  local should_commit="false"
  [[ "$count" -ge "$threshold" ]] && should_commit="true"

  assert_eq "true" "$should_commit" "$count files >= threshold $threshold"
  assert_eq "6" "$count" "Untracked file count"

  # Clean up
  rm -f untracked_*.txt
}

t07_state_lifecycle() {
  echo; echo "=== t07: awaiting_squash_push state lifecycle ==="

  # Simulate the three states
  local s1="$BRANCH_AUTONOMOUS_DIR/state1.json"
  local s2="$BRANCH_AUTONOMOUS_DIR/state2.json"
  local s3="$BRANCH_AUTONOMOUS_DIR/state3.json"

  jq -n '{"milestone":true,"awaiting_squash_push":false,"awaiting_merge_confirmation":false}' > "$s1"
  assert_json_true  "$s1" "milestone"             "State 1: milestone=true (detected)"
  assert_json_false "$s1" "awaiting_squash_push"  "State 1: awaiting_squash_push=false"

  jq -n '{"milestone":false,"awaiting_squash_push":true,"awaiting_merge_confirmation":false}' > "$s2"
  assert_json_false "$s2" "milestone"             "State 2: milestone=false (user confirmed)"
  assert_json_true  "$s2" "awaiting_squash_push"   "State 2: awaiting_squash_push=true"

  jq -n '{"milestone":false,"awaiting_squash_push":false,"awaiting_merge_confirmation":true}' > "$s3"
  assert_json_false "$s3" "awaiting_squash_push"  "State 3: awaiting_squash_push=false (squashed)"
  assert_json_true  "$s3" "awaiting_merge_confirmation" "State 3: awaiting_merge_confirmation=true"

  rm -f "$s1" "$s2" "$s3"
}

t08_git_reset_soft() {
  echo; echo "=== t08: git reset --soft squash simulation ==="
  cd "$TEST_REPO"

  local pre_msg
  pre_msg=$(git log -1 --format="%s")

  # Simulate squash: reset --soft then recommit
  if git reset --soft origin/main 2>/dev/null; then
    local staged
    staged=$(git diff --cached --name-only | wc -l | tr -d ' ')
    if [[ "$staged" -gt 0 ]]; then
      echo -e "  ${GREEN}✓${NC} After reset --soft: $staged file(s) staged"; passed=$((passed + 1))
    else
      echo -e "  ${RED}✗${NC} Expected staged files after reset --soft"; failed=$((failed + 1))
    fi

    local sq_msg="squash(feature/test): $pre_msg"
    if git commit -q -m "$sq_msg"; then
      local new_msg
      new_msg=$(git log -1 --format="%s")
      assert_eq "$sq_msg" "$new_msg" "Squash commit message correct"
    fi
  fi
}

t09_test_detection() {
  echo; echo "=== t09: post-tool test PASS/FAIL detection ==="
  cd "$TEST_REPO"

  # Simulate post-tool output parsing
  detect_test() {
    local output="$1"
    if echo "$output" | grep -qE '(PASS|ok |✓|All tests passed|passed|100%)'; then
      echo "PASS"
    elif echo "$output" | grep -qE '(FAIL|FAILED|ERROR|✗|tests failed|0 passed)'; then
      echo "FAIL"
    else
      echo "UNKNOWN"
    fi
  }

  assert_eq "PASS" "$(detect_test "PASS  test_feature.py::test_search")"  "PASS line detected"
  assert_eq "PASS" "$(detect_test "ok  test_auth.py::test_login")"         "ok line detected"
  assert_eq "PASS" "$(detect_test "✓ All tests passed")"                  "✓ passed"
  assert_eq "PASS" "$(detect_test "Tests: 50 passed, 0 failed")"          "50 passed"
  assert_eq "FAIL" "$(detect_test "FAIL  test_payment.py::test_checkout")" "FAIL line detected"
  assert_eq "FAIL" "$(detect_test "ERROR: test threw exception")"         "ERROR detected"
  assert_eq "FAIL" "$(detect_test "FAILED (errors=1, failures=2)")"     "FAILED with counts"
  assert_eq "UNKNOWN" "$(detect_test "echo hello")"                     "Unknown output → UNKNOWN"
}

# ─── Test registry ─────────────────────────────────────────────────────────────
TESTS=(t01_state_json_init t02_branch_type t03_milestone_detection t04_guard_bash_rules t05_squash_logic t06_auto_commit_threshold t07_state_lifecycle t08_git_reset_soft t09_test_detection)

# ─── Main ─────────────────────────────────────────────────────────────────────
FILTER="${1:-}"
echo "========================================"
echo "Branch-Autonomous Hooks — TDD Test Suite"
echo "========================================"
echo "Running: ${FILTER:-all} tests"

setup

for t in "${TESTS[@]}"; do
  [[ -n "$FILTER" && "$t" != "$FILTER" ]] && continue
  echo; echo "──── $t ────"
  $t
done

trap teardown EXIT
report

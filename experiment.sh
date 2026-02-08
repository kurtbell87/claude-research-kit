#!/usr/bin/env bash
# experiment.sh -- Research Experiment Orchestrator for Claude Code
#
# Usage:
#   ./experiment.sh survey  <question>          # Survey prior work relevant to a research question
#   ./experiment.sh frame   <spec-file>         # Design experiment from hypothesis
#   ./experiment.sh run     <spec-file>         # Execute experiment (spec is locked)
#   ./experiment.sh read    <spec-file>         # Analyze results against pre-stated criteria
#   ./experiment.sh log     <spec-file>         # Commit results, update research log
#   ./experiment.sh cycle   <spec-file>         # Run frame -> run -> read -> log
#   ./experiment.sh full    <question> <spec>    # Run survey -> frame -> run -> read -> log
#   ./experiment.sh watch   [phase] [--resolve]  # Live-tail or summarize a phase log
#
# Configure via environment variables or edit the defaults below.

set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Configuration -- edit these to match your project
# ──────────────────────────────────────────────────────────────

# Directories
EXPERIMENTS_DIR="${EXPERIMENTS_DIR:-experiments}"     # Experiment spec files
RESULTS_DIR="${RESULTS_DIR:-results}"                 # Results output
SRC_DIR="${SRC_DIR:-src}"                             # Model / training code
DATA_DIR="${DATA_DIR:-data}"                          # Datasets
CONFIGS_DIR="${CONFIGS_DIR:-configs}"                 # Training configs
NOTEBOOKS_DIR="${NOTEBOOKS_DIR:-notebooks}"           # Analysis notebooks (optional)

PROMPT_DIR=".claude/prompts"
HOOK_DIR=".claude/hooks"

# Commands -- override these for your project
TRAIN_CMD="${TRAIN_CMD:-echo 'Set TRAIN_CMD for your project'}"
EVAL_CMD="${EVAL_CMD:-echo 'Set EVAL_CMD for your project'}"
TEST_CMD="${TEST_CMD:-echo 'Set TEST_CMD for your project'}"       # Unit tests for infra code

# Resource constraints
MAX_GPU_HOURS="${MAX_GPU_HOURS:-4}"
MAX_RUNS="${MAX_RUNS:-10}"

# Git / PR settings
EXP_AUTO_MERGE="${EXP_AUTO_MERGE:-false}"
EXP_DELETE_BRANCH="${EXP_DELETE_BRANCH:-false}"
EXP_BASE_BRANCH="${EXP_BASE_BRANCH:-main}"

# ──────────────────────────────────────────────────────────────
# Colors
# ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ──────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────

experiment_id_from_spec() {
  # Extract experiment ID from spec filename: experiments/exp-003-reward-shaping.md -> exp-003
  local spec="$1"
  local base
  base="$(basename "$spec" .md)"
  echo "$base"
}

results_dir_for_spec() {
  local spec="$1"
  local exp_id
  exp_id="$(experiment_id_from_spec "$spec")"
  echo "$RESULTS_DIR/$exp_id"
}

next_experiment_number() {
  local max=0
  for f in "$EXPERIMENTS_DIR"/exp-*.md; do
    [[ -f "$f" ]] || continue
    local num
    num=$(basename "$f" | sed -n 's/^exp-\([0-9]*\).*/\1/p')
    num=${num:-0}
    num=$((10#$num))  # Force base-10
    if (( num > max )); then
      max=$num
    fi
  done
  printf "%03d" $((max + 1))
}

lock_experiment_spec() {
  local spec="$1"
  if [[ -f "$spec" ]]; then
    chmod 444 "$spec"
    echo -e "   ${YELLOW}locked:${NC} $spec"
  fi
}

unlock_experiment_spec() {
  local spec="$1"
  if [[ -f "$spec" ]]; then
    chmod 644 "$spec"
    echo -e "   ${BLUE}unlocked:${NC} $spec"
  fi
}

lock_previous_results() {
  # Lock all existing result directories (prevent contamination)
  if [[ -d "$RESULTS_DIR" ]]; then
    find "$RESULTS_DIR" -type f -name "*.json" -exec chmod 444 {} \;
    find "$RESULTS_DIR" -type f -name "*.csv" -exec chmod 444 {} \;
    echo -e "   ${YELLOW}locked:${NC} previous results in $RESULTS_DIR"
  fi
}

unlock_all() {
  # Restore write permissions on everything
  if [[ -d "$RESULTS_DIR" ]]; then
    find "$RESULTS_DIR" -type f \( -name "*.json" -o -name "*.csv" \) -exec chmod 644 {} \; 2>/dev/null || true
    find "$RESULTS_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
  fi
  for f in "$EXPERIMENTS_DIR"/*.md; do
    [[ -f "$f" ]] && chmod 644 "$f" 2>/dev/null || true
  done
  echo -e "   ${BLUE}all files unlocked${NC}"
}

ensure_hooks_executable() {
  if [[ -f "$HOOK_DIR/pre-tool-use.sh" ]]; then
    chmod +x "$HOOK_DIR/pre-tool-use.sh"
  fi
}

list_experiment_specs() {
  find "$EXPERIMENTS_DIR" -maxdepth 1 -name "exp-*.md" -type f 2>/dev/null | sort || echo "none"
}

list_result_dirs() {
  find "$RESULTS_DIR" -maxdepth 1 -type d -name "exp-*" 2>/dev/null | sort || echo "none"
}

# ──────────────────────────────────────────────────────────────
# Phase Runners
# ──────────────────────────────────────────────────────────────

run_survey() {
  local question="${1:?Usage: experiment.sh survey <research-question-or-topic>}"

  echo ""
  echo -e "${CYAN}======================================================${NC}"
  echo -e "${CYAN}  SURVEY PHASE -- Prior Work & Codebase Review${NC}"
  echo -e "${CYAN}======================================================${NC}"
  echo -e "  Question: $question"
  echo ""

  export EXP_PHASE="survey"

  claude \
    --output-format stream-json \
    --append-system-prompt "$(cat "$PROMPT_DIR/survey.md")

## Context
- Research question / topic: $question
- Source directory: $SRC_DIR
- Existing experiments: $(list_experiment_specs | tr '\n' ', ')
- Existing results: $(list_result_dirs | tr '\n' ', ')
- Research log: RESEARCH_LOG.md
- Research questions: QUESTIONS.md
- Train command: $TRAIN_CMD
- Eval command: $EVAL_CMD

Start by reading RESEARCH_LOG.md and QUESTIONS.md, then survey the codebase and prior experiments." \
    --allowed-tools "Read,Bash,Glob,Grep,Write" \
    -p "Survey the current state of knowledge on: $question" \
    2>&1 | tee /tmp/exp-survey.log
}

run_frame() {
  local spec_file="${1:?Usage: experiment.sh frame <spec-file>}"

  # If spec_file doesn't exist yet, that's fine -- the agent will create it.
  # But the path should be in the experiments directory.
  if [[ "$(dirname "$spec_file")" != "$EXPERIMENTS_DIR" && "$(dirname "$spec_file")" != "." ]]; then
    echo -e "${YELLOW}Warning: Spec file not in $EXPERIMENTS_DIR/. Consider placing it there.${NC}"
  fi

  echo ""
  echo -e "${RED}======================================================${NC}"
  echo -e "${RED}  FRAME PHASE -- Hypothesis & Experiment Design${NC}"
  echo -e "${RED}======================================================${NC}"
  echo -e "  Spec:    $spec_file"
  echo -e "  Results: $RESULTS_DIR"
  echo ""

  # Ensure spec is writable for the design agent
  unlock_experiment_spec "$spec_file" 2>/dev/null || true

  export EXP_PHASE="frame"

  claude \
    --output-format stream-json \
    --append-system-prompt "$(cat "$PROMPT_DIR/frame.md")

## Context
- Experiment spec to write: $spec_file
- Source directory: $SRC_DIR
- Results directory: $RESULTS_DIR
- Existing experiments: $(list_experiment_specs | tr '\n' ', ')
- Existing results: $(list_result_dirs | tr '\n' ', ')
- Research log: RESEARCH_LOG.md
- Train command: $TRAIN_CMD
- Eval command: $EVAL_CMD
- Max GPU hours budget: $MAX_GPU_HOURS
- Max runs budget: $MAX_RUNS

Read the RESEARCH_LOG.md and any survey output first, then design the experiment." \
    --allowed-tools "Read,Write,Edit,Bash,Glob,Grep" \
    -p "Design the experiment and write the spec to $spec_file" \
    2>&1 | tee /tmp/exp-frame.log
}

run_run() {
  local spec_file="${1:?Usage: experiment.sh run <spec-file>}"

  if [[ ! -f "$spec_file" ]]; then
    echo -e "${RED}Error: Spec file not found: $spec_file${NC}" >&2
    exit 1
  fi

  local results_path
  results_path="$(results_dir_for_spec "$spec_file")"
  mkdir -p "$results_path"

  echo ""
  echo -e "${GREEN}======================================================${NC}"
  echo -e "${GREEN}  RUN PHASE -- Executing Experiment${NC}"
  echo -e "${GREEN}======================================================${NC}"
  echo -e "  Spec:    $spec_file ${YELLOW}(READ-ONLY)${NC}"
  echo -e "  Results: $results_path"
  echo -e "  Source:  $SRC_DIR"
  echo ""

  # OS-level enforcement: lock the spec and previous results
  lock_experiment_spec "$spec_file"
  lock_previous_results
  ensure_hooks_executable

  export EXP_PHASE="run"
  export EXP_SPEC_FILE="$spec_file"
  export EXP_RESULTS_DIR="$results_path"

  # Unlock on exit regardless of success/failure
  trap unlock_all EXIT

  # Freeze the spec into the results directory for reproducibility
  cp "$spec_file" "$results_path/spec.md"
  chmod 444 "$results_path/spec.md"

  claude \
    --output-format stream-json \
    --append-system-prompt "$(cat "$PROMPT_DIR/run.md")

## Context
- Experiment spec: $spec_file (READ-ONLY -- do not attempt to modify)
- Results output directory: $results_path
- Source directory: $SRC_DIR
- Config directory: $CONFIGS_DIR
- Data directory: $DATA_DIR
- Train command: $TRAIN_CMD
- Eval command: $EVAL_CMD
- Test command (unit tests): $TEST_CMD
- Max GPU hours: $MAX_GPU_HOURS
- Max runs: $MAX_RUNS

Read the experiment spec first. Implement and execute the experiment. Write ALL metrics to $results_path/metrics.json." \
    --allowed-tools "Read,Write,Edit,Bash,Glob,Grep" \
    -p "Read the experiment spec, implement, and execute. Write all metrics to $results_path/metrics.json" \
    2>&1 | tee /tmp/exp-run.log
}

run_read() {
  local spec_file="${1:?Usage: experiment.sh read <spec-file>}"

  if [[ ! -f "$spec_file" ]]; then
    echo -e "${RED}Error: Spec file not found: $spec_file${NC}" >&2
    exit 1
  fi

  local results_path
  results_path="$(results_dir_for_spec "$spec_file")"

  if [[ ! -d "$results_path" ]]; then
    echo -e "${RED}Error: Results directory not found: $results_path${NC}" >&2
    echo -e "${RED}Run 'experiment.sh run $spec_file' first.${NC}" >&2
    exit 1
  fi

  echo ""
  echo -e "${BLUE}======================================================${NC}"
  echo -e "${BLUE}  READ PHASE -- Analyzing Results${NC}"
  echo -e "${BLUE}======================================================${NC}"
  echo -e "  Spec:    $spec_file"
  echo -e "  Results: $results_path"
  echo ""

  export EXP_PHASE="read"
  export EXP_SPEC_FILE="$spec_file"
  export EXP_RESULTS_DIR="$results_path"

  # Lock metrics (can't change the numbers after the fact)
  if [[ -f "$results_path/metrics.json" ]]; then
    chmod 444 "$results_path/metrics.json"
    echo -e "   ${YELLOW}locked:${NC} $results_path/metrics.json"
  fi

  claude \
    --output-format stream-json \
    --append-system-prompt "$(cat "$PROMPT_DIR/read.md")

## Context
- Experiment spec: $spec_file
- Results directory: $results_path
- Metrics file: $results_path/metrics.json (READ-ONLY -- these are the ground truth numbers)
- Research log: RESEARCH_LOG.md
- Previous experiments: $(list_experiment_specs | tr '\n' ', ')
- Previous results: $(list_result_dirs | tr '\n' ', ')

Read the spec and metrics, then write your analysis to $results_path/analysis.md. Address EVERY metric in the spec." \
    --allowed-tools "Read,Write,Edit,Bash,Glob,Grep" \
    -p "Analyze the experiment results. Write analysis to $results_path/analysis.md" \
    2>&1 | tee /tmp/exp-read.log
}

run_log() {
  local spec_file="${1:?Usage: experiment.sh log <spec-file>}"
  local exp_id
  exp_id="$(experiment_id_from_spec "$spec_file")"
  local results_path
  results_path="$(results_dir_for_spec "$spec_file")"

  echo ""
  echo -e "${MAGENTA}======================================================${NC}"
  echo -e "${MAGENTA}  LOG PHASE -- Committing & Updating Research Log${NC}"
  echo -e "${MAGENTA}======================================================${NC}"
  echo ""

  # Ensure everything is unlocked for commit
  unlock_all 2>/dev/null || true

  # Create feature branch
  local branch="experiment/${exp_id}"
  git checkout -b "$branch" 2>/dev/null || git checkout "$branch"

  # Stage all changes
  git add -A
  git commit -m "experiment(${exp_id}): complete SURVEY-FRAME-RUN-READ cycle

Spec: ${spec_file}
Results: ${results_path}/
Analysis: ${results_path}/analysis.md"

  # Push and create PR
  git push -u origin "$branch"

  local pr_body
  pr_body="## Experiment: ${exp_id}

**Spec:** \`${spec_file}\`
**Results:** \`${results_path}/\`

### Phases completed
- [x] SURVEY — prior work reviewed
- [x] FRAME — hypothesis and experiment designed
- [x] RUN — experiment executed, metrics collected
- [x] READ — results analyzed against pre-stated criteria

### Key files
- \`${results_path}/spec.md\` — frozen experiment spec
- \`${results_path}/metrics.json\` — raw metrics
- \`${results_path}/analysis.md\` — analysis and conclusions

---
*Generated by claude-research-kit*"

  local pr_url
  pr_url=$(gh pr create \
    --base "$EXP_BASE_BRANCH" \
    --title "experiment(${exp_id}): results and analysis" \
    --body "$pr_body")

  echo -e "  ${GREEN}PR created:${NC} $pr_url"

  if [[ "$EXP_AUTO_MERGE" == "true" ]]; then
    echo -e "  ${YELLOW}Auto-merging...${NC}"
    gh pr merge "$pr_url" --merge
    echo -e "  ${GREEN}Merged.${NC}"
    git checkout "$EXP_BASE_BRANCH"
    git pull
    if [[ "$EXP_DELETE_BRANCH" == "true" ]]; then
      git branch -d "$branch" 2>/dev/null || true
      echo -e "  ${GREEN}Branch deleted.${NC}"
    fi
  fi

  echo ""
  echo -e "${GREEN}======================================================${NC}"
  echo -e "${GREEN}  Logged! PR: $pr_url${NC}"
  echo -e "${GREEN}======================================================${NC}"
}

run_cycle() {
  # frame -> run -> read -> log (no survey -- assumes you've already surveyed)
  local spec_file="${1:?Usage: experiment.sh cycle <spec-file>}"

  echo -e "${BOLD}Running experiment cycle: FRAME -> RUN -> READ -> LOG${NC}"
  echo ""

  run_frame "$spec_file"
  echo -e "\n${YELLOW}--- Frame complete. Running experiment... ---${NC}\n"

  run_run "$spec_file"
  echo -e "\n${YELLOW}--- Run complete. Analyzing results... ---${NC}\n"

  run_read "$spec_file"
  echo -e "\n${YELLOW}--- Analysis complete. Logging... ---${NC}\n"

  run_log "$spec_file"

  echo ""
  echo -e "${BOLD}${GREEN}Experiment cycle complete.${NC}"
}

run_full() {
  # survey -> frame -> run -> read -> log
  local question="${1:?Usage: experiment.sh full <question> <spec-file>}"
  local spec_file="${2:?Usage: experiment.sh full <question> <spec-file>}"

  echo -e "${BOLD}Running full research cycle: SURVEY -> FRAME -> RUN -> READ -> LOG${NC}"
  echo ""

  run_survey "$question"
  echo -e "\n${YELLOW}--- Survey complete. Designing experiment... ---${NC}\n"

  run_frame "$spec_file"
  echo -e "\n${YELLOW}--- Frame complete. Running experiment... ---${NC}\n"

  run_run "$spec_file"
  echo -e "\n${YELLOW}--- Run complete. Analyzing results... ---${NC}\n"

  run_read "$spec_file"
  echo -e "\n${YELLOW}--- Analysis complete. Logging... ---${NC}\n"

  run_log "$spec_file"

  echo ""
  echo -e "${BOLD}${GREEN}Full research cycle complete.${NC}"
}

# ──────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────

case "${1:-help}" in
  survey)   shift; run_survey "$@" ;;
  frame)    shift; run_frame "$@" ;;
  run)      shift; run_run "$@" ;;
  read)     shift; run_read "$@" ;;
  log)      shift; run_log "$@" ;;
  cycle)    shift; run_cycle "$@" ;;
  full)     shift; run_full "$@" ;;
  watch)    shift; python3 scripts/experiment-watch.py "$@" ;;
  help|*)
    echo "Usage: experiment.sh <phase> [args]"
    echo ""
    echo "Phases:"
    echo "  survey  <question>             Survey prior work for a research question"
    echo "  frame   <spec-file>            Design experiment (write spec)"
    echo "  run     <spec-file>            Execute experiment (spec is locked)"
    echo "  read    <spec-file>            Analyze results against spec"
    echo "  log     <spec-file>            Commit results, create PR"
    echo "  cycle   <spec-file>            Run frame -> run -> read -> log"
    echo "  full    <question> <spec-file> Run survey -> frame -> run -> read -> log"
    echo "  watch   [phase]                Live-tail a running phase (--resolve for summary)"
    echo ""
    echo "Environment:"
    echo "  SRC_DIR='src'                Source / model code directory"
    echo "  DATA_DIR='data'              Dataset directory"
    echo "  CONFIGS_DIR='configs'        Config directory"
    echo "  TRAIN_CMD='...'              Training command"
    echo "  EVAL_CMD='...'               Evaluation command"
    echo "  TEST_CMD='...'               Unit test command"
    echo "  MAX_GPU_HOURS='4'            Budget per experiment"
    echo "  MAX_RUNS='10'                Max training runs per experiment"
    echo "  EXP_AUTO_MERGE='false'       Auto-merge PR after creation"
    echo "  EXP_BASE_BRANCH='main'       Base branch for PRs"
    ;;
esac

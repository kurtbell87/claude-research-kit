#!/usr/bin/env bash
# experiment-aliases.sh -- Source this in your shell
#
#   source experiment-aliases.sh

EXP_SCRIPT="./experiment.sh"

alias exp-survey='bash $EXP_SCRIPT survey'
alias exp-frame='bash $EXP_SCRIPT frame'
alias exp-run='bash $EXP_SCRIPT run'
alias exp-read='bash $EXP_SCRIPT read'
alias exp-log='bash $EXP_SCRIPT log'
alias exp-cycle='bash $EXP_SCRIPT cycle'
alias exp-full='bash $EXP_SCRIPT full'

exp-status() {
  echo "Research Experiment Status"
  echo "========================="
  echo ""
  echo "Phase: ${EXP_PHASE:-not set}"
  echo ""
  echo "Experiment specs:"
  for f in experiments/exp-*.md; do
    [[ -f "$f" ]] || continue
    if [[ ! -w "$f" ]]; then
      echo "  LOCKED  $f"
    else
      echo "  open    $f"
    fi
  done
  echo ""
  echo "Result directories:"
  for d in results/exp-*/; do
    [[ -d "$d" ]] || continue
    local metrics="$d/metrics.json"
    local analysis="$d/analysis.md"
    local status="incomplete"
    [[ -f "$metrics" ]] && status="has metrics"
    [[ -f "$analysis" ]] && status="analyzed"
    echo "  $status  $d"
  done
  echo ""
  echo "Run 'exp-survey \"question\"' to start a new research cycle."
}

exp-unlock() {
  echo "Emergency unlock -- restoring write permissions..."
  find experiments/ -name "*.md" -exec chmod 644 {} \; 2>/dev/null || true
  find results/ -type f \( -name "*.json" -o -name "*.csv" \) -exec chmod 644 {} \; 2>/dev/null || true
  find results/ -type d -exec chmod 755 {} \; 2>/dev/null || true
  echo "Done."
}

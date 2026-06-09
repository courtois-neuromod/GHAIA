#!/bin/bash
#SBATCH --job-name=mariha-bk2-all
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --output=logs/bk2_all_%A_%a.out
#SBATCH --error=logs/bk2_all_%A_%a.err

# Bulk BK2 generation — one array task per (agent, cl_method, subject) combo.
# Each task loops through all sessions for its combo sequentially, so the total
# number of queued jobs equals the number of combos (not combos × sessions).
# Mirrors the hpc_run_all.sh self-submitting pattern.
#
# Usage (login node):
#   ./scripts/submit_bk2_all.sh                   # every combo found
#   ./scripts/submit_bk2_all.sh --agent ppo       # filter by agent
#   ./scripts/submit_bk2_all.sh --subject sub-01  # filter by subject
#   ./scripts/submit_bk2_all.sh --dry-run

set -euo pipefail

if [[ -z "${MARIHA_EXPERIMENT_DIR:-}" ]]; then
    MARIHA_ENV_FILE="${MARIHA_ENV_FILE:-$HOME/.config/mariha/hpc_env.sh}"
    [[ -f "$MARIHA_ENV_FILE" ]] && source "$MARIHA_ENV_FILE"
fi

# ---------------------------------------------------------------------------
# Worker mode — inside a SLURM array task
# ---------------------------------------------------------------------------
if [[ -n "${SLURM_ARRAY_TASK_ID:-}" ]]; then
    source "${MARIHA_ENV_FILE:-$HOME/.config/mariha/hpc_env.sh}"

    line=$(sed -n "${SLURM_ARRAY_TASK_ID}p" "$COMBO_LIST")
    read -r AGENT CL_METHOD SUBJECT RUN_PREFIX <<< "$line"

    SCENES_SUBJ="$MARIHA_DATA_ROOT/mario.scenes/$SUBJECT"
    mapfile -t SESSIONS < <(
        find "$SCENES_SUBJ" -name "*_desc-scenes_events.tsv" \
            | grep -oP 'ses-[0-9]+' \
            | sort -u
    )

    ARGS=(
        --subject "$SUBJECT"
        --agent "$AGENT"
        --run_prefix "$RUN_PREFIX"
        --experiment_dir "$MARIHA_EXPERIMENT_DIR"
    )
    [[ "$CL_METHOD" != "none" ]] && ARGS+=(--cl_method "$CL_METHOD")

    combo="$AGENT"; [[ "$CL_METHOD" != "none" ]] && combo="${AGENT}_${CL_METHOD}"
    echo "=== $combo | $SUBJECT | $RUN_PREFIX | ${#SESSIONS[@]} sessions ==="

    for SESSION in "${SESSIONS[@]}"; do
        echo "--- $SESSION ---"
        python "$MARIHA_REPO/scripts/generate_model_bk2.py" "${ARGS[@]}" --session "$SESSION"
    done
    exit 0
fi

# ---------------------------------------------------------------------------
# Submission mode — on the login node
# ---------------------------------------------------------------------------
FILTER_AGENT=""
FILTER_SUBJECT=""
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)   FILTER_AGENT="$2";   shift 2 ;;
        --subject) FILTER_SUBJECT="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true;        shift   ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

REPO="${MARIHA_REPO:?MARIHA_REPO not set — run setup_hpc.sh}"
CKPT_ROOT="${MARIHA_EXPERIMENT_DIR:?MARIHA_EXPERIMENT_DIR not set}/checkpoints"
DATA_ROOT="${MARIHA_DATA_ROOT:?MARIHA_DATA_ROOT not set}"

[[ -d "$CKPT_ROOT" ]] || { echo "ERROR: no checkpoints at $CKPT_ROOT" >&2; exit 1; }

mkdir -p "$REPO/logs"
COMBO_LIST="$(mktemp "$REPO/logs/bk2_combos_XXXX.txt")"

for rl_dir in "$CKPT_ROOT"/*/; do
    [[ -d "$rl_dir" ]] || continue
    run_label="$(basename "$rl_dir")"
    agent="${run_label%%_*}"
    cl_method="none"
    [[ "$run_label" == *_* ]] && cl_method="${run_label#*_}"
    [[ -n "$FILTER_AGENT" && "$agent" != "$FILTER_AGENT" ]] && continue

    for subj_dir in "$rl_dir"*/; do
        [[ -d "$subj_dir" ]] || continue
        subject="$(basename "$subj_dir")"
        [[ -n "$FILTER_SUBJECT" && "$subject" != "$FILTER_SUBJECT" ]] && continue

        # Discover run_prefix (newest checkpoint for this subject).
        run_prefix=""
        for d in $(ls -t "$subj_dir" 2>/dev/null); do
            p="${d%_task*}"
            if [[ "$p" != "$d" ]]; then run_prefix="$p"; break; fi
        done
        [[ -z "$run_prefix" ]] && { echo "WARNING: no run_prefix for $run_label/$subject — skipping" >&2; continue; }

        echo "$agent $cl_method $subject $run_prefix" >> "$COMBO_LIST"
    done
done

n=$(wc -l < "$COMBO_LIST")
if [[ "$n" -eq 0 ]]; then
    echo "No combos found." >&2; exit 1
fi

if $DRY_RUN; then
    echo "[dry-run] Would submit $n-task array. Combos:"
    cat "$COMBO_LIST"
    rm "$COMBO_LIST"
    exit 0
fi

SBATCH_ARGS=()
[[ -n "${MARIHA_SLURM_ACCOUNT:-}" ]] && SBATCH_ARGS+=(--account="$MARIHA_SLURM_ACCOUNT")

ARRAY_JOB_ID=$(sbatch --parsable "${SBATCH_ARGS[@]}" \
    --array="1-${n}" \
    --export="ALL,COMBO_LIST=$COMBO_LIST" \
    "$0")
echo "Submitted BK2 array ($n combos, job $ARRAY_JOB_ID)"

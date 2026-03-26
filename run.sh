#!/bin/bash
#SBATCH --job-name=autoresearch
#SBATCH --output=logs/slurm-%j.out
#SBATCH --error=logs/slurm-%j.out
#SBATCH --gres=gpu:1
#SBATCH --mem=64G
#SBATCH --time=00:20:00
#SBATCH --cpus-per-task=8

# -------------------------------------------------------
# AutoResearch training job
# Do NOT modify #SBATCH parameters without user approval.
# -------------------------------------------------------

set -e

cd "$(dirname "$0")"

# Activate environment (adjust if using venv or modules)
# conda activate myenv

# Disable network access on compute nodes
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_DATASETS_OFFLINE=1

uv run train.py "$@"

echo "=== JOB COMPLETED SUCCESSFULLY ==="

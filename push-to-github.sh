#!/usr/bin/env bash
# Run from inside this directory after `gh auth login` (or set up a remote manually).
set -euo pipefail

REPO_NAME="backstage-kind-demo"
GH_USER="simonjday"

git init
git add .
git commit -m "Initial commit: Backstage on kind demo (Apple Silicon)"
git branch -M main

# Requires GitHub CLI (`brew install gh`) authenticated as simonjday.
gh repo create "${GH_USER}/${REPO_NAME}" --public --source=. --remote=origin --push

echo "==> Pushed to https://github.com/${GH_USER}/${REPO_NAME}"

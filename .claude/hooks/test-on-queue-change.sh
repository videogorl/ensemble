#!/bin/bash
set -o pipefail

# Hook script: Runs EnsembleCore tests when queue-related files are modified

# Read the hook input from stdin
INPUT=$(cat)

# Extract the file path from the tool input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Match queue-related files:
# - QueueManager.swift
# - QueueItem.swift
# - QueueNavigationAction.swift
# - Any *Queue*Tests.swift files
if [[ "$FILE_PATH" =~ Queue.*\.swift$ ]]; then
  echo "Queue-related file modified: $FILE_PATH"
  echo "Running EnsembleCore tests..."
  echo ""

  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    cd "$CLAUDE_PROJECT_DIR" || exit 1
  fi

  TEST_OUTPUT=$(mktemp)
  swift test --package-path Packages/EnsembleCore >"$TEST_OUTPUT" 2>&1
  TEST_RESULT=$?

  tail -25 "$TEST_OUTPUT"
  rm -f "$TEST_OUTPUT"

  if [ $TEST_RESULT -eq 0 ]; then
    echo ""
    echo "All tests passed."
  else
    echo ""
    echo "Some tests failed. Review the output above."
  fi
  exit 0
fi

# No action for other files
exit 0

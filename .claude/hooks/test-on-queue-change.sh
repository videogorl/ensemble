#!/bin/bash

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

  swift test --package-path Packages/EnsembleCore 2>&1 | tail -25

  TEST_RESULT=$?
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

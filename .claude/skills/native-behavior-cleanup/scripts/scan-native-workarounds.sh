#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"

if ! command -v rg >/dev/null 2>&1; then
  echo "error: rg is required for this scan" >&2
  exit 127
fi

SEARCH_PATHS=()
for path in "Ensemble" "EnsembleSiriIntentsExtension" "Packages" "docs"; do
  if [[ -e "$ROOT/$path" ]]; then
    SEARCH_PATHS+=("$ROOT/$path")
  fi
done

if [[ ${#SEARCH_PATHS[@]} -eq 0 ]]; then
  SEARCH_PATHS=("$ROOT")
fi

run_scan() {
  local title="$1"
  local pattern="$2"

  printf '\n## %s\n' "$title"
  rg -n --hidden \
    --glob '!.git' \
    --glob '!**/.build/**' \
    --glob '!**/Build/**' \
    --glob '!**/DerivedData/**' \
    --glob '!**/*.xcuserstate' \
    -e "$pattern" \
    "${SEARCH_PATHS[@]}" || true
}

printf '# Native Behavior Workaround Scan\n'
printf 'Root: %s\n' "$ROOT"
printf 'Generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

run_scan "Safe Area And Keyboard Overrides" '\.ignoresSafeArea|safeAreaInset|safeAreaPadding|keyboardSafe|phoneSafe|containerSafeArea'
run_scan "UIKit And AppKit Bridges" 'UIViewRepresentable|NSViewRepresentable|UIViewControllerRepresentable|NSViewControllerRepresentable|UINavigationBarAppearance|NSToolbar|NSWindow|UIWindow|NSHostingView|UIHostingController'
run_scan "Hit Testing And Passthrough" 'hitTest|point\(inside|Passthrough|allowsHitTesting|contentShape'
run_scan "Drag And Drop Bridges" 'performDragOperation|draggingEntered|draggingUpdated|onDrag|onDrop|DropDelegate|NSDragging|UIDrag|UIDrop'
run_scan "Geometry And Preference Layout" 'GeometryReader|PreferenceKey|anchorPreference|overlayPreferenceValue|backgroundPreferenceValue|coordinateSpace'
run_scan "Async Layout Timing" 'DispatchQueue\.main\.async|asyncAfter|Task\.sleep|sleep\(nanoseconds|debounce|delay\('
run_scan "Custom Scroll And Offset Handling" 'ScrollViewReader|scrollTo\(|scrollPosition|contentOffset|DragGesture|onChanged|onEnded|scrollPhase|onScroll|UIScrollView|NSScrollView'
run_scan "Forced Infinite Frames" 'frame\([^\n]*(maxHeight:\s*\.infinity|maxWidth:\s*\.infinity)'
run_scan "Toolbar Titlebar Navigation Chrome" 'toolbarBackground|toolbarColorScheme|navigationBar|navigationTitle|titlebar|Titlebar|windowToolbar|WindowToolbar|toolbarRole'
run_scan "Suspicious Hardcoded Layout Constants" '\.(padding|offset|frame|safeAreaPadding)\([^\n]*[0-9]{2,}|let [A-Za-z0-9_]*(Padding|Offset|Height|Width|Inset|Spacing)[A-Za-z0-9_]*\s*[:=]\s*[0-9]{2,}'

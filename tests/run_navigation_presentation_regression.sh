#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
navigation_test_dir=$(mktemp -d /private/tmp/OngakuNavigation.XXXXXX)
swiftc -O -module-cache-path "$navigation_test_dir/module-cache" \
    audio/AppLibraryModels.swift audio/LibraryRoute.swift \
    audio/CoalescedViewUpdates.swift audio/AudioPlayerViewModel+Presentation.swift \
    tests/NavigationPresentationRegression.swift -o "$navigation_test_dir/navigation-regression"
"$navigation_test_dir/navigation-regression"

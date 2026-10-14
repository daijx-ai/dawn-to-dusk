#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
mkdir -p "$project_root/build/tests"
/usr/bin/swiftc -parse-as-library "$project_root/Sources/SingleInstance.swift" "$project_root/Tests/SingleInstanceTests.swift" -o "$project_root/build/tests/single-instance"
"$project_root/build/tests/single-instance"
/usr/bin/swiftc -parse-as-library "$project_root/Sources/Domain.swift" "$project_root/Sources/FeishuModels.swift" "$project_root/Sources/CaptureModels.swift" "$project_root/Sources/Store.swift" "$project_root/Tests/CoreTests.swift" -o "$project_root/build/tests/core"
/usr/bin/swiftc -parse-as-library "$project_root/Sources/Domain.swift" "$project_root/Sources/FeishuModels.swift" "$project_root/Sources/CaptureModels.swift" "$project_root/Sources/Store.swift" "$project_root/Tests/FeishuModelTests.swift" -o "$project_root/build/tests/feishu-model"
"$project_root/build/tests/feishu-model"
/usr/bin/swiftc -parse-as-library "$project_root/Sources/Domain.swift" "$project_root/Sources/FeishuModels.swift" "$project_root/Sources/FeishuReader.swift" "$project_root/Tests/FeishuReaderTests.swift" -o "$project_root/build/tests/feishu-reader"
"$project_root/build/tests/feishu-reader"
/usr/bin/swiftc -parse-as-library "$project_root/Sources/Domain.swift" "$project_root/Sources/FeishuModels.swift" "$project_root/Sources/CaptureModels.swift" "$project_root/Sources/Store.swift" "$project_root/Sources/FeishuReader.swift" "$project_root/Sources/FeishuSyncCoordinator.swift" "$project_root/Tests/FeishuSyncTests.swift" -o "$project_root/build/tests/feishu-sync"
"$project_root/build/tests/feishu-sync"
"$project_root/build/tests/core"
/usr/bin/swiftc -parse-as-library "$project_root/Sources/Domain.swift" "$project_root/Sources/FeishuModels.swift" "$project_root/Sources/CaptureModels.swift" "$project_root/Sources/CaptureBridge.swift" "$project_root/Tests/CaptureBridgeTests.swift" -o "$project_root/build/tests/capture-bridge"
"$project_root/build/tests/capture-bridge"
/usr/bin/python3 "$project_root/Tests/HermesCaptureTests.py"
/usr/bin/swiftc -parse-as-library "$project_root/Sources/Domain.swift" "$project_root/Sources/FeishuModels.swift" "$project_root/Sources/Appearance.swift" "$project_root/Sources/AgendaBackground.swift" "$project_root/Tests/BackgroundTests.swift" -o "$project_root/build/tests/background" -framework AppKit -framework SwiftUI
"$project_root/build/tests/background"
/usr/bin/swiftc -parse-as-library "$project_root/Sources/Domain.swift" "$project_root/Sources/FeishuModels.swift" "$project_root/Sources/Appearance.swift" "$project_root/Sources/AgendaBackground.swift" "$project_root/Tests/ScrollBoundaryTests.swift" -o "$project_root/build/tests/scroll-boundary" -framework AppKit -framework SwiftUI
"$project_root/build/tests/scroll-boundary"
/usr/bin/swiftc -parse-as-library "$project_root/Sources/Domain.swift" "$project_root/Sources/FeishuModels.swift" "$project_root/Sources/Appearance.swift" "$project_root/Tests/AppearanceTests.swift" -o "$project_root/build/tests/appearance" -framework AppKit -framework SwiftUI
"$project_root/build/tests/appearance"
/usr/bin/swiftc -parse-as-library -D INTEGRATION_TESTS "$project_root"/Sources/*.swift "$project_root/Tests/IntegrationTests.swift" -o "$project_root/build/tests/integration" -framework AppKit -framework SwiftUI -framework UserNotifications -framework ServiceManagement
"$project_root/build/tests/integration"

/usr/bin/swiftc -parse-as-library "$project_root/Sources/Domain.swift" "$project_root/Sources/FeishuModels.swift" "$project_root/Sources/Appearance.swift" "$project_root/Sources/TimeInput.swift" "$project_root/Tests/TimeInputTests.swift" -o "$project_root/build/tests/time-input" -framework AppKit -framework SwiftUI
"$project_root/build/tests/time-input"

/usr/bin/swiftc -parse-as-library "$project_root/Sources/Domain.swift" "$project_root/Sources/FeishuModels.swift" "$project_root/Sources/CaptureModels.swift" "$project_root/Sources/Store.swift" "$project_root/Sources/CaptureBridge.swift" "$project_root/Sources/AgendaQueries.swift" "$project_root/Tests/AgendaQueryTests.swift" -o "$project_root/build/tests/agenda-query"
"$project_root/build/tests/agenda-query"

/usr/bin/swiftc -parse-as-library "$project_root/Sources/Domain.swift" "$project_root/Sources/FeishuModels.swift" "$project_root/Sources/CaptureModels.swift" "$project_root/Sources/Store.swift" "$project_root/Tests/EditorNavigationTests.swift" -o "$project_root/build/tests/editor-navigation"
"$project_root/build/tests/editor-navigation"

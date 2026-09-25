import Foundation
import NextUpCore

// Assertion runner. `import Testing` and XCTest are not available without Xcode.
var failures = 0
var passes = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, file: String = #fileID, line: Int = #line) {
    if condition() {
        passes += 1
    } else {
        failures += 1
        print("FAIL \(name)  (\(file):\(line))")
    }
}

check("version is 0.1.0", NextUpVersion == "0.1.0")

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

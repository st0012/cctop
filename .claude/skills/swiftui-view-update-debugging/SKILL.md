---
name: swiftui-view-update-debugging
description: Use when a SwiftUI view is not updating after state changes, when colors or child views appear stale after a model change, or when NSHostingView rootView replacement doesn't propagate to child views. Symptoms include views showing old data despite confirmed state changes, child views ignoring parent updates, and theme or color changes not reflecting in rendered output.
---

# SwiftUI View Update Debugging

## Overview

SwiftUI's view diffing can silently skip re-evaluation of child view bodies even when the underlying data has changed. This skill provides a systematic approach to diagnose and fix stale views.

## When to Use

- View shows old data after confirmed state change
- `hostingView.rootView = NewView(...)` doesn't update children
- Theme/color changes don't propagate to nested views
- Dynamic computed properties (reading from a manager/singleton) return new values but views don't reflect them

## Diagnostic Steps

### 1. Confirm the data actually changed

Before debugging the view layer, verify the model is correct. **Use file-based logging** — `print()` and `NSLog()` are invisible when launching macOS apps from the CLI or when the app is a menubar-only agent.

```swift
// File-based debug logging (works in all macOS app contexts)
func debugLog(_ message: String) {
    let entry = "\(Date()) \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/debug.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(entry.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? entry.write(to: url, atomically: true, encoding: .utf8)
    }
}
```

Log at the point where data changes and at the point where the view reads it. If the data is correct but the view is stale, proceed to step 2.

### 2. Check SwiftUI's diffing decision

SwiftUI skips re-evaluating a child view's `body` if the child's struct inputs haven't changed. This is the most common root cause.

**Scenario:** Parent sets `hostingView.rootView = MyView(counts: counts)`. Child `StatusBar(counts: counts)` reads a computed property from a singleton (`StatusColors.working`). The singleton's value changed (e.g. theme switch), but `counts` didn't — so SwiftUI sees identical inputs and skips the child's body entirely.

```
Parent: rootView = MyView(counts: same)
  -> SwiftUI: "counts didn't change, skip child body"
  -> Child: never re-reads StatusColors.working
  -> Result: stale colors
```

### 3. Apply the right fix

| Root Cause | Fix |
|-----------|-----|
| Child reads external state not in its inputs | Pass a changing value (e.g. `themeId`) and add `.id(themeId)` to force recreation |
| `@State` destroyed by `.id()` changes | Extract state into `@StateObject` owned by a parent above the `.id()` boundary |
| `NSColor(name:)` dynamic colors cached | Use `.id()` to force re-resolution, or use explicit color values |
| `@Published` property changed but view doesn't update | Verify the view uses `@ObservedObject` or `@EnvironmentObject`, not a plain property |

### `.id()` Force-Recreation Pattern

When child views read external state (singletons, managers, environment) not passed through their struct inputs:

```swift
struct ParentView: View {
    let data: MyData
    var externalStateId: String = ""  // changes when external state changes

    var body: some View {
        HStack {
            ChildThatReadsExternalState(data: data)
            AnotherChild(data: data)
        }
        .id(externalStateId)  // forces ALL children to recreate
    }
}
```

**Tradeoff:** `.id()` destroys and recreates the entire subtree, including any `@State`. If you need `@State` to survive, extract it into an `@StateObject` owned by a view above the `.id()` boundary.

### State Extraction Pattern

```swift
// Before: @State destroyed when .id() changes
struct MyView: View {
    @State private var selection: Int? = nil  // lost on .id() change
    var body: some View { ... }
}

// After: state survives .id() changes
class MyController: ObservableObject {
    @Published var selection: Int? = nil
}

struct ParentView: View {
    @StateObject private var controller = MyController()  // owns state
    var body: some View {
        MyView(controller: controller)
            .id(themeId)  // safe — controller survives
    }
}
```

## Common Mistakes

- **Adding `needsDisplay = true` to NSHostingView** — does nothing; SwiftUI manages its own display cycle
- **Using `print()`/`NSLog()` for macOS menubar apps** — output goes nowhere when launched from CLI or Finder. Use file-based logging.
- **Adding `.id()` without checking for `@State`** — silently destroys state, causing UI to reset unexpectedly
- **Passing the changing value as a property but not using `.id()`** — SwiftUI may still skip child evaluation if the child doesn't use that property in its body

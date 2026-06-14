---
name: swiftui-debugging
description: Use when debugging SwiftUI issues in this macOS app — views not updating, layout problems, unnecessary re-renders, state ownership bugs, Preview crashes, or NSHostingView/NSPanel quirks. Covers both general SwiftUI debugging and macOS-specific patterns.
---

# SwiftUI Debugging

## Overview

Systematic approaches for debugging SwiftUI issues in macOS apps. Covers view updates, state ownership, performance, layout, and macOS-specific quirks with NSHostingView and NSPanel.

## Logging in macOS Apps

`print()` and `NSLog()` are invisible when launching macOS apps from CLI or Finder (menubar-only apps have no console). Always use file-based logging:

```swift
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

Remove all debug logging before committing. Use `grep -r "debugLog" --include="*.swift"` to verify.

## View Not Updating

### Symptom

View shows stale data after a confirmed state change. Common with `hostingView.rootView = NewView(...)` not propagating to children, or theme/color changes not reflecting.

### Root Cause: SwiftUI Diffing

SwiftUI skips re-evaluating a child view's `body` if the child's struct inputs haven't changed — even if the child reads from a singleton or computed property that did change.

```
Parent: rootView = MyView(counts: same)
  → SwiftUI: "counts didn't change, skip child body"
  → Child: never re-reads StatusColors.working
  → Result: stale colors
```

### Diagnosis

1. Log at the data source (model/manager) and at the view's body — confirm data changed but body wasn't called
2. Check if the view reads external state (singletons, managers) not passed through its struct inputs
3. Use `Self._printChanges()` at the top of `body` to see what SwiftUI thinks triggered (or didn't trigger) a re-evaluation

### Fixes

| Root Cause | Fix |
|-----------|-----|
| Child reads external state not in its inputs | Pass a changing value and add `.id(value)` to force recreation |
| `@State` destroyed by `.id()` changes | Extract into `@StateObject` owned by parent above the `.id()` boundary |
| `NSColor(name:)` dynamic colors cached | Use `.id()` to force re-resolution |
| `@Published` changed but view doesn't update | Verify view uses `@ObservedObject`, not a plain property |

#### `.id()` Force-Recreation

```swift
struct NotchStatusView: View {
    let counts: StatusCounts
    var themeId: String = ""  // changes when theme changes

    var body: some View {
        HStack { ... }
            .id(themeId)  // forces ALL children to recreate
    }
}
```

**Tradeoff:** `.id()` destroys the entire subtree including `@State`.

#### State Extraction (surviving `.id()`)

```swift
// Move @State into @StateObject owned above the .id() boundary
class OverlayController: ObservableObject {
    @Published var active: Overlay?
}

struct ParentView: View {
    @StateObject private var controller = OverlayController()  // survives
    var body: some View {
        ChildView(controller: controller)
            .id(themeId)  // safe — controller lives here
    }
}
```

## State Ownership Bugs

### `@State` vs `@StateObject` vs `@ObservedObject`

| Wrapper | Owned by | Lifetime | Use when |
|---------|----------|----------|----------|
| `@State` | The view | Dies with view identity (`.id()`) | Simple value types internal to one view |
| `@StateObject` | The view that creates it | Survives re-renders, dies with view | You create the object and own its lifetime |
| `@ObservedObject` | Someone else | You don't control it | Passed in from parent, not owned here |

### Common Bug: `@ObservedObject` with inline init

```swift
// BUG: creates new instance every re-render, losing state
struct MyView: View {
    @ObservedObject var model = MyModel()  // wrong — recreated each time
}

// FIX: use @StateObject for owned objects
struct MyView: View {
    @StateObject var model = MyModel()  // correct — created once
}
```

## Unnecessary Re-renders

### Diagnosis

Add `Self._printChanges()` at the top of `body` to see what SwiftUI thinks changed:

```swift
var body: some View {
    let _ = Self._printChanges()  // prints: "MyView: @self, _count changed."
    ...
}
```

### Common Causes

- **Struct not `Equatable`** — SwiftUI can't diff, re-renders every time. Add `Equatable` conformance.
- **Closure properties** — closures aren't equatable; every parent render creates a new closure. Move closures to methods or use `EquatableView`.
- **Overly broad `@Published`** — publishing a large object when only one field changed. Break into granular publishers or use `@Observable` (macOS 14+).

## Layout Debugging

### Visual debugging

```swift
// Highlight view bounds
.border(Color.red)
.background(Color.blue.opacity(0.2))

// Check what size SwiftUI gives a view
.overlay(GeometryReader { geo in
    Text("\(Int(geo.size.width))×\(Int(geo.size.height))")
        .font(.caption2).foregroundColor(.red)
})
```

### Common Layout Issues

- **View collapses to zero** — missing `.frame()` or parent doesn't propose a size. Check with `background(Color.red)`.
- **Text truncation** — `fixedSize()` lets text exceed proposed size, or use `lineLimit(nil)`.
- **GeometryReader takes all space** — it's greedy. Wrap in an explicit `.frame()` or use it only for reading, not sizing.

## Preview Debugging

### Preview crashes silently

- Check the diagnostic in Xcode's canvas (click the error icon)
- Previews run in a separate process — crashes in `init()` or computed properties won't show a stack trace
- Use mock data that avoids file system, network, or singleton access

### Preview works but app doesn't (or vice versa)

- Previews use a different bundle — `Bundle.main` returns different values
- Previews may not have the same entitlements (e.g., no Automation permission)
- `@AppStorage` reads from a different UserDefaults suite in previews

## macOS-Specific: NSHostingView and NSPanel

### NSHostingView `rootView` replacement

Setting `hostingView.rootView = NewView(...)` does NOT recreate the view tree — SwiftUI diffs the old and new struct. If inputs are identical, children skip body evaluation. This is the most common source of "view not updating" bugs in macOS apps using NSHostingView.

### NSPanel quirks

- `needsDisplay = true` on NSHostingView does nothing — SwiftUI manages its own display cycle
- `orderOut(nil)` hides but doesn't destroy the hosting view; state persists
- For clickable panels (e.g., notch pill), use `NSPanel` with `styleMask: [.nonactivatingPanel]` and override `canBecomeKey` to avoid stealing focus

### `@MainActor` cascade

Making a type `@MainActor` (e.g., to access `ThemeManager.shared`) cascades to everything that uses it. Plan for this — it often requires `@MainActor` on models, renderers, controllers, and test classes. Add it top-down rather than chasing compiler errors bottom-up.

## Quick Reference

| Problem | First step |
|---------|-----------|
| View shows stale data | `Self._printChanges()` — is body even called? |
| View never re-renders | Check property wrappers — `@ObservedObject` vs `@StateObject` |
| State resets unexpectedly | Look for `.id()` changes destroying `@State` |
| Can't see print output | Use file-based logging (`/tmp/debug.log`) |
| Layout wrong | `.border(Color.red)` on suspect views |
| Preview crashes | Check for singleton/file access in init |
| NSHostingView children stale | Inputs unchanged → use `.id()` to force recreation |
| `@MainActor` errors everywhere | Add top-down from the root type, not bottom-up |

# Application-table scrolling stability — 2026-10-26

## Reproduction and cause

The reported recording showed scroll-position jumps in the All Applications table. A native-window regression mounts the actual `AppTable` with 240 synthetic applications, scrolls to rows 30, 60, 120, 180 and 239, then returns through row 120 to row 0. Inventory, window dimensions and source results remain unchanged during these measurements.

On macOS 26 / Xcode 27.1, the original SwiftUI Table used automatic row heights with a default row height of 24 points. The measured document heights were:

```text
6303, 6479, 7073, 7667, 8261, 8833, 9273, 9273
```

Visiting more rows changed the document height by **2970 points**, despite unchanged data. This reproduces the estimate/measurement discrepancy that changes the scrollbar scale and scroll positions.

A separate experiment gave all four SwiftUI column cells an explicit 44-point height and set `defaultMinListRowHeight` to 44. Automatic row sizing remained enabled. The document heights still changed by **720 points**:

```text
10679, 10807, 10935, 11063, 11191, 11311, 11399, 11399
```

The final implementation owns an NSTableView through NSViewRepresentable, uses `rowSizeStyle = .custom`, `rowHeight = 44`, and disables `usesAutomaticRowHeights`. It uses public AppKit APIs without reaching into SwiftUI's private view hierarchy. SwiftUI retains application state and cell presentation. Reusable hosting cells do not report intrinsic sizes to the table. Updates reload only changed rows when identities are unchanged, preserving the viewport and selection; inventory/filter changes retain the visible application anchor when it survives.

## Verification

The final document heights for the same scrolling sequence were:

```text
11050, 11050, 11050, 11050, 11050, 11050, 11050, 11050
```

The regression also checks:

- A source-result change updates the available-version cell while preserving document height, viewport and selection.
- Filtering and externally changed selection retain the application's stable path identity.
- Native down-arrow navigation updates SwiftUI selection.
- The context menu changes from Ignore to Restore after acting on the selected synthetic application.
- Narrowing the window and revisiting the last row do not change the document height.

Full native suite: **174 tests passed**, comprising 156 core tests and 18 application tests. Final result bundle: `.local/table-jitter/DeliveryTests.xcresult`. Original and experimental failure logs are retained under `.local/table-jitter/`.

The final foreground app was also exercised through native UI control: selecting the second application with the mouse and pressing Down selected the third application and updated its inspector. Scrolling four pages down reached the bottom, and four pages up returned to the top without changing the selected application. Columns fit the existing window without a horizontal scrollbar. Read-only hosting cells pass mouse events to the native table; user selection explicitly establishes the table as first responder, while programmatic SwiftUI updates do not steal focus. These checks used the local application inventory; no screenshots or inventory details are committed.

```sh
xcodebuild -project Upovi.xcodeproj -scheme Upovi -destination 'platform=macOS' \
  -only-testing:UpoviTests/AppTableLayoutTests test
```

This validates native layout, selection and menu behavior with synthetic data on this Mac. It does not claim acceptance on every supported macOS version or reproduce the exact physical input events from the original recording.

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

An intermediate AppKit implementation disabled automatic row heights and stabilized this sequence at 11050 points. The owner subsequently requested a pure SwiftUI implementation, so that table bridge has been removed.

## Current pure SwiftUI implementation

`ApplicationTable` now composes horizontal and vertical ScrollViews, an independent header, and an eager VStack of 46-point rows. All rows participate in layout immediately, so the content extent does not depend on which rows have been visited. Header and rows share the same column widths; dragging a header boundary resizes its two adjacent columns within their minimum/maximum bounds. Narrow windows can scroll horizontally. The header stays above the vertical scrolling area.

The table, row and column-layout files contain no NSViewRepresentable, NSTableView or NSHostingView. SwiftUI manages selection, focus, arrow/Home/End/Page navigation, context menus, selection styling and accessibility labels. Inventory, filtering and update status retain the same store and stable application-path identities. System operations such as revealing an application in Finder and retrieving its icon remain separate existing services.

## Verification

The current pure SwiftUI document heights for the same 240-row scrolling sequence are:

```text
11048, 11048, 11048, 11048, 11048, 11048, 11048, 11048
```

The regression also checks:

- A source-result change preserves document height, viewport and selection.
- Filtering retains a selected application that remains in the filtered results.
- Narrowing the window and revisiting the last row do not change the document height.
- There is no NSTableView in the mounted application list.
- Column resizing fits the available width, preserves total width and honors both adjacent columns' limits.

Full native suite: **175 tests passed**, comprising 156 core tests and 19 application tests. Result bundle: `.local/pure-swiftui/FinalTests.xcresult`. The SwiftPM suite also passed all 175 tests. Original failure logs remain under `.local/table-jitter/`; current logs are under `.local/pure-swiftui/`.

The pure SwiftUI foreground app was exercised through UI control: clicking the second application and pressing Down selected the third application and updated its inspector. Its context menu exposed Reveal in Finder and Ignore. Dragging the first header boundary increased the application column from 227 to 247 points while reducing the adjacent version column from 110 to 90 points. Four pages down reached the bottom (scrollbar value 1), and four pages up returned to the top (value 0). These checks used the local application inventory; no screenshots or inventory details are committed.

```sh
xcodebuild -project Upovi.xcodeproj -scheme Upovi -destination 'platform=macOS' \
  -only-testing:UpoviTests/AppTableLayoutTests test
```

This validates native layout, selection and menu behavior with synthetic data on this Mac. It does not claim acceptance on every supported macOS version or reproduce the exact physical input events from the original recording.

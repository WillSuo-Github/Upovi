# Upovi grouped transfer layout — 2026-10-28

final result: passed

## Visual target and evidence

The user selected the second displayed design image, generated as `exec-4252089c-869e-41f4-9d79-9408e2ed01d9.png`. This change implements that design in the existing native SwiftUI app.

- Source: `.local/selected-grouped-layout-evidence-20261028/selected-reference.png`.
- Final implementation: `.local/selected-grouped-layout-evidence-20261028/implementation-light-final.jpg`.
- Combined full-view and focused-row comparison: `.local/selected-grouped-layout-evidence-20261028/comparison-overview.jpg`.
- Comparison presentation: `.local/selected-grouped-layout-evidence-20261028/comparison.html`.
- Responsive evidence: `.local/selected-grouped-layout-evidence-20261028/implementation-dark-compact-de.jpg`.
- Interaction evidence: `.local/selected-grouped-layout-evidence-20261028/stopped.jpg` and `idle.jpg`.
- Test log and structured results are in the same evidence directory.

The source is 1581 × 995 pixels. The native capture is 2480 × 1560 pixels at 2×, representing a 1240 × 780 point window. Both show five downloading applications plus an idle Rectangle row. The comparison page renders both at the same aspect ratio and equal CSS width. For readable detail comparison, both images are rendered at 1240 × 780 CSS pixels and the same 940 × 100 first-row region is displayed. No raster screenshot content was redrawn or regenerated for comparison.

## Findings and repairs

1. [P2, resolved] The initial native transfer column was displaced by the extra menu column, and the name/rate/metadata hierarchy was too small. The menu now overlays its reserved trailing action position. Typography, icon spacing, page margins, and row rhythm were recalibrated against the selected image. The final combined comparison shows the intended aligned transfer clusters and grouped surface.
2. [P2, resolved] Rectangle initially showed a generic file icon in the isolated fixture. The fixture now reads the existing isolated Rectangle bundle icon without launching or modifying that bundle. The final capture shows the authentic application icon.
3. [P2, resolved] The German compact header truncated its title and total-rate label. The title can scale modestly, rate labels can wrap to two lines, and the redundant active-download count was removed from the subtitle. The summary footprint remains 80 points. The final dark German capture shows the complete title, rate label, rate, progress and stop control.
4. [P2, resolved] Stopping a batch could label it as fully successful. A partially completed batch now uses the existing localized ended-state title and a neutral overall track. Native interaction acceptance confirmed the stopped title and a zero live rate.

No unresolved P0/P1/P2 visual or interaction finding remains within this scope.

## Required fidelity surfaces

- Fonts and typography: native SF system fonts; 32-point page heading, 16-point application names and row rates, 20-point aggregate rate, and 12-point secondary copy. Monospaced digits stabilize changing numeric values. Full-view and focused-row comparisons were reviewed; German header text was repaired and recaptured.
- Spacing and layout rhythm: one pale page surface, an 80-point horizontal summary, and one shared rounded application group. Rows measure 86 points across idle, downloading, verification, authorization, installation, completion, failure and cancellation states at content widths of 680 and 920 points. Expanded release notes deliberately add height only when explicitly opened.
- Colors and tokens: pale gray page, white grouped surfaces, quiet separators and the existing blue progress tint. Dark appearance uses adaptive dark page/surface colors. Stopped work uses a neutral tone and verified completion can use the existing success tone.
- Image quality and assets: actual NSWorkspace application icons and SF Symbols are retained. No generated substitute icons or rasterized UI controls were added to the app. The source mock's brand styling and OS chrome are not used as executable application assets.
- Copy and content: real source labels, valid increasing version examples and existing localization keys are retained. Mock manufacturer names and invalid generated downgrade examples were not copied into product logic. Progress percentages continue to represent the complete update workflow, including verification/installation, rather than the mock's download-only values.

## Validation and intentional differences

- Local Xcode validation: 177 core tests and 27 application tests passed, with zero failures.
- Live isolated UI checks: five concurrent transfer samples, exact sum of row rates, stop, finished-summary dismissal, and idle list.
- Dark responsive check: German at the compact 1000-point window width; all header controls remain visible and the aggregate label wraps. The pre-existing long German sidebar history label still truncates with its native sidebar width; this is outside the redesigned content area.
- Accessibility: localized rate labels, readable secondary text, native controls, full-text help, stable geometry, consistent rounded percentages and existing Reduce Motion behavior are preserved. This is not a full VoiceOver audit.
- Existing safety behavior is retained: starting another installation is disabled during an active batch. More menus and release-note controls remain available, unlike the simplified visual mock. The sidebar continues to respect the user's macOS accent color.
- The fixture is offline and synthetic. No real package was downloaded or installed, and the daily installed Upovi was not replaced. Cross-version and Intel runtime coverage were not added by these local checks.

## Implementation checklist

- [x] Recreate the selected grouped layout in native SwiftUI.
- [x] Keep per-row throughput and aggregate throughput visible while downloading.
- [x] Replace row action space without inserting a progress footer.
- [x] Preserve menus, release notes, search and installation controls.
- [x] Compare the selected reference and the final native capture at normalized display sizes.
- [x] Repair layout/copy/asset issues and recapture after fixes.
- [x] Pass local tests and clean up test windows, preview processes and isolated app copies.

Build `202610280002` remains allocated to this unreleased update. Validation was completed before commit and push. No release publication or replacement of the daily app was performed.

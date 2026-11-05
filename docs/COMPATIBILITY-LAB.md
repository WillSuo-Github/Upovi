# Compatibility validation

Upovi does not currently have evidence for 5,000 successful upgrades. A source catalog, a parsed download descriptor, a verified current package, an actual upgrade, and a first-launch acceptance are separate claims.

The initial lab uses the existing Apple silicon Mac only. It does not enable background installations, purchase cloud resources, replace daily-use applications, execute Homebrew recipes, or launch downloaded applications. Every installation batch follows an explicit developer command. PKG installers, system extensions, vendor installers and first-launch tests require a separately identified disposable VM; the host harness refuses PKG archives.

## Current checkpoint

The owner paused the 5,000-app campaign to publish the validated fixes in build 202611060001. The current local ledger records 747 unique main application IDs with complete source selection, verified payload, isolated installation, post-install recheck and restoration. First launch, licensed features, privileged components and other host configurations are not established. Blocked-case totals include unavailable historical inputs, byte budgets and network failures; they are not counts of defective applications.

## Evidence levels

| Level | Evidence | Does not establish |
| --- | --- | --- |
| Inventory | Public Homebrew catalog, input hash and capture time; annual Homebrew installs rank research work | Popularity across all Mac users, exact installed identity, an available download |
| Metadata route | Actual `CaskMetadata` parser produces an HTTPS checksum descriptor for a platform | Download availability, signature, architecture compatibility, installation success |
| Payload | Download matches independent cask SHA256; actual main bundle identity, Apple-anchored Developer ID, native Mach-O and Gatekeeper pass | Old-to-new upgrade, first launch, helper or license migration |
| Upgrade and restore | Authentic signed old bundle; actual `UpdateChecker` selection; production `UpdateInstaller` preparation, installation and restoration; signed installed target and post-install source recheck | First launch, privileged operations, other OS/CPU combinations |
| Runtime acceptance | Disposable-VM launch, vendor-specific behavior and cleanup, where separately recorded | Other untested configurations |

Count verified applications by actual signed main bundle ID. Repeated versions, archives, CPU slices, helper bundles and reruns do not create additional applications. A failure never becomes a pass because metadata exists. The latest attempt per case token, host OS, architecture and explicitly selected release channel remains visible; earlier attempts remain in their case directories. Failed test-input checks are not evidence of an application defect.

The initial audit evaluates macOS 14, 15, 26 and 27 descriptor selection for both CPU names. This is parser coverage, **not execution on eight platforms**. A variation may inherit a base URL even when its bytes do not support that CPU. Actual payload/upgrade records identify the real host; the initial host is arm64 macOS 27.2.

## Reproduce locally

Run from the repository root. Private artifacts, checkpoints and logs stay under `.local`; publication uses an allowlisted evidence export.

```sh
python3 script/compatibility/lab.py --root .local/compatibility-lab collect
python3 script/compatibility/lab.py --root .local/compatibility-lab build
python3 script/compatibility/lab.py --root .local/compatibility-lab audit
python3 script/compatibility/lab.py --root .local/compatibility-lab inspect --limit 20 --budget-mb 2048 --max-package-mb 100
python3 script/compatibility/lab.py --root .local/compatibility-lab run --manifest script/compatibility/first-cohort.json --limit 12 --resume
python3 script/compatibility/lab.py --root .local/compatibility-lab report
python3 script/compatibility/lab.py --root .local/compatibility-lab export --output docs/evidence/compatibility-lab.json
```

`collect` retains existing snapshots to support reproducibility. Use a new root for fresh input, or explicitly supply `--catalog` and `--popularity` snapshots. Input provenance distinguishes caller-supplied snapshots from downloads. Popularity uses the public Homebrew cask-install 365-day aggregate, without uploading the local installed inventory.

`inspect` prioritizes direct-app casks without declared quit IDs. `--token` can select a particular cask. It has an explicit cumulative byte budget, package cap, batch cap and 20 GiB minimum free-space check. Oversized transfers reserve their entire package cap; packages are never declared incompatible just because the budget is exhausted. The initial selection uses arm64/macOS 27 metadata and refuses other host architectures. It performs no bundle replacement.

`run` accepts 1–50 cases per explicit batch. A case declares its expected old identity/version and official old archive URL. Old archive SHA256 is checked where independently published; otherwise an observed hash is only provenance, and the old Apple-anchored signature or exact reviewed legacy migration is required. The current target, download and integrity proof must come from production source selection, not a fabricated manifest candidate. The current full cask snapshot feeds the real catalog resolver; explicitly reviewed casks still fetch their live individual metadata. Optional `--proxy-port` uses an existing loopback HTTP proxy, without embedding credentials or changing system network settings.

The old archive cap defaults to 300 MiB. New archives use the production transport's 2 GB cap; cases run serially within each invocation and remove temporary apps/cache after recording evidence. Failed recovery artifacts remain for inspection. Product preparation may create its own private temporary workspace and cleans it through its existing discard/failure paths. No test app is launched, including through App Translocation.

`--resume` reuses only full passes from the previous seven days with identical old identity/version/URL/checksum, catalog hash and probe binary hash. It does not upgrade a prior metadata-only check or a failure into a pass. Fresh binaries or catalog inputs cause a real rerun. Do not replace a running probe binary; rebuild between batches. Interrupted case directories remain visible; use a fresh directory for retries and inspect/detach any residual mount before deleting recovery evidence.

`build` links the actual debug `UpoviCore` implementation, records source hashes and a binary hash, and leaves the production app unchanged. Runtime `UpoviLog` output goes to each private case's `Logs` directory. Raw errors/paths stay private. The export allowlists fixed evidence fields and excludes raw error messages, local paths and log content.

## Campaign findings and remaining work

See [the first evidence snapshot](evidence/compatibility-lab-20261105.json) and the local run's `report.md` / `report.json`. The full JSON also contains the popularity-ranked research queue. The initial cohort is intentionally small enough to prove the complete pipeline before spending hundreds of gigabytes on downloads.

The now-paused 2026-11-05 campaign used five explicitly launched serial campaign workers, plus bounded source-repair retries and read-only payload inspections, with resumable manifests and immutable probes. The local `report.json` is the current private ledger; the public evidence file is a dated checkpoint, not a live counter. API/research feeds, completed batches and inspected payloads never increment the verified-upgrade count.

Official GitHub release metadata and 793 static upstream Sparkle feed leads now supply authentic old archive inputs. The source recipes are read inside the exact Homebrew ZIP snapshot; Ruby and community shell recipes are never executed. Of those feeds, 786 were downloaded and the production `AppcastReader` found 292 distinct old/new enclosure pairs before deduplication against existing cases. These are unverified inputs. Feeds with no distinct older verifiable enclosure remain held.

Three additional official Homebrew source snapshots (before 2026-10-01, 2026-07-01 and 2025-11-01) provide historical recipe URLs and independent SHA256 values. A bounded literal parser supports explicit Apple silicon declarations and a small known set of version substitutions; unsupported Ruby is held and never executed. It found 1,671 candidate pairs and 1,543 older alternatives. Deduplication and archive/installer constraints produced 901 additional cases in explicit manifests. None of these metadata inputs count as successful upgrades. Snapshot commit IDs, archive hashes and per-recipe hashes stay in the private provenance ledger.

GitHub API throttling can now recover an exact stable release and GitHub-provided SHA256 from the official expanded-assets page. Digests are bound to the same repository, confirmed tag, individual asset row and exact filename; ambiguity or missing proof remains manual, and API failure diagnostics stay visible. A real Rectangle 2.0.3 → 2.0.4 acceptance injected API 429 and made other metadata sources unavailable, then passed verified installation, post-install check, restoration and cleanup via that public route. It adds no new unique app because Rectangle was already counted. [The fault-test evidence](evidence/github-public-assets-rate-limit-20261105.json) records the scope.

The catalog snapshot contains 7,811 records. Excluding disabled/versioned entries and non-app or undeclared installer records produces 3,598 app/package candidates, including 3,338 direct-app candidates. 3,168 have arm64/macOS 27 checksum descriptors; 2,563 candidates have no declared exact quit identifier. These are **candidate records**, not 3,598 verified unique applications. Missing quit IDs do not mean all 2,563 apps are unsupported: existing reviewed exceptions and embedded official feeds can already cover some. Quit identifiers can name helpers; duplicate identifiers remain flagged.

The first real batch exposed a NetNewsWire gap: its current appcast did not offer the selected new release, the generic GitHub parser rejected the `mac-` tag, and the cask had no quit ID. The official new archive passed SHA256, Developer ID (`M8L2WTLA8W`), native executable and Gatekeeper inspection. An explicitly reviewed main-bundle mapping supplies the normal checksum-backed Homebrew route without broadening GitHub tag parsing or weakening installation requirements. CC Switch and kitty mappings were also reviewed against their actual signed payload, official cask references and real upgrade/restore tests.

Mac Catalyst binaries use a separate Mach-O platform and iOS-family deployment numbering. Compatibility validation now uses exact Apple SDK deployment mappings instead of rejecting that platform or comparing its target directly with macOS. Unknown mappings, iOS/device/simulator binaries and unsupported platforms remain rejected. A real FlowDown 5.2.3 → 5.2.4 upgrade, recheck and restore passed after this fix. [The deployment map](evidence/mac-catalyst-deployment-map-20261105.json) and [upgrade evidence](evidence/flowdown-mac-catalyst-upgrade-20261105.json) preserve the scope.

Electron GitHub sources now select an explicitly published host-architecture manifest before a common manifest. This fixes vendors that publish Intel-only `latest-mac.yml` alongside `latest-mac-arm64.yml` or `latest-arm64-mac.yml`. Equal-priority alternatives, foreign tags and unknown channels remain manual; staged rollout and required manifest-signature restrictions remain intact. Real Joplin and Eigent upgrades selected their ARM archives and passed post-install checks and restoration. [The acceptance evidence](evidence/electron-architecture-upgrades-20261105.json) does not claim first-launch behavior.

The generic Homebrew resolver now recognizes exact identifiers in declared per-user preferences, caches, saved state, containers and application-script paths, together with an exact main application filename. It rejects globs, nested paths, arbitrary library folders and ambiguous casks. Path references remain separate from declared quit identifiers and never enter the ID-only index or installer trust rules. Real GitUp, MeetingBar and SwitchHosts upgrades passed through this route; Rancher and other restricted Electron channels remained manual. [Positive and negative acceptance evidence](evidence/cask-identity-path-upgrades-20261105.json) records both outcomes.

DB Browser for SQLite demonstrates why payload verification is insufficient. Its 3.13.1 signed Info.plist has an empty `CFBundleExecutable`; macOS resolves its executable from the original application filename. The identical copied bytes pass strict signature checks with that filename, but cannot be recognized as signed after staging as `Prepared.app`. Its source mapping proposal was withheld, not promoted to the product catalog. Fixing this requires basename-preserving preparation, rename transactions, backups and restore, with privileged-helper validation considered as well. Never edit its signed plist or re-sign its code. [The negative evidence](evidence/sqlite-bundle-name-compatibility-20261105.json) records the reproduction; the older official v3.13.0 archive also incorrectly reports 3.13.99 internally. The blocker remains in `script/compatibility/known-blockers.json` for explicit retesting.

To reach 5,000 real validated apps:

1. Work down the popularity queue, validate actual current bundles and research missing identity mappings. Generate review proposals from evidence; never import remote identities automatically into the signed product catalog.
2. Add independent developer sources for apps absent from Homebrew, preserving official provenance, stable channels, developer identity, packaging and integrity rules. Candidate duplication across catalogs must be resolved using real bundles before counting them.
3. Capture authentic old releases, execute version-pair upgrades and retain failures as actionable work. Promote a route only at the level actually tested. Maintain expiring results per release/OS/CPU instead of a permanent unsupported “works forever” flag.
4. Use the existing disposable macOS VM for privileged packages and launch-dependent flows after freshly verifying its disposable marker. Intel metadata and universal Mach-O inspection cannot replace Intel runtime acceptance; no Intel acceptance is claimed with the current resources.
5. Keep checks and catalog maintenance read-only. Do not schedule unattended installation tests on the user's host or add unattended product updates.

The 5,000 target is a coverage program, not a number to obtain by relabeling the inventory. Remaining work includes thousands of old-version pairs, actual source reachability, native/runtime coverage, first launch, privileged paths, paid/registered applications, vendor-specific migration, and ongoing rechecks. The campaign does not claim those have been completed. In particular, bundle replacement acceptance does not establish first-launch or licensed-feature behavior.

## Public source references

- [Homebrew JSON API](https://formulae.brew.sh/docs/api/) supplies the independent inventory and aggregate popularity.
- [Floodtide coverage](https://bhopstudio.com/floodtide/coverage), checked 2026-11-05, describes 4,837 bundles: 3,316 Homebrew-derived and 1,521 exclusive to its signed catalog. Its coverage description is not evidence that every listed app underwent an old-to-new install/restore test. This lab does not copy its app list or equate its own metadata rows with that published verification claim.

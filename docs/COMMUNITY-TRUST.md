# Community report trust policy

P2P discovers claims, not verified installations. A valid node signature and matching self-reported Team ID do not establish an official release. No version gap, number of identities or report signature can turn a peer record into an update source.

## Update authority

`UpdateAssessment` is shared by the native store and notification scheduler. Only non-community candidates from a source result for the exact local application, with status updates or partial and a version/build newer than the installed application, qualify as source updates. Partial results may retain successful candidates from one adapter while another failed. Current, failed, unsupported, missing and wrong-application results cannot confirm a report.

The available-updates list, sidebar count, footer, menu-bar count and new check-history counts use source updates. Notification planning independently applies the same policy even if a community candidate were accidentally inserted into a source result. Peer records never enter notification content or persisted deduplication keys. Matching peers do not add a second update or second notification.

## Descriptive confidence

| Label | Condition | Authority |
| --- | --- | --- |
| Unverified community report | No matching source candidate; at most one known publisher key | None |
| Multiple nodes report, unverified | Identical version/build with two or more distinct publisher keys | None; keys can belong to one attacker |
| Source matches | A current independently checked source candidate matches the report version and any claimed build | Source result supplies the update; the peer still cannot install or notify |

Only unexpired, parseable, higher community versions are shown, with the protocol's prerelease rules retained. Identical version/build reports are grouped; duplicate, empty and missing publisher IDs cannot inflate the distinct-key count. Expired reports do not contribute. There is no reputation or independent-person verification.

Version matching uses the existing numeric/prerelease comparator (for example v2.0 and 2.0.0 match). If a peer claims a build, the source must provide the same nonempty build string. A source supplying only a version cannot authenticate a claimed build 999. A build-only appcast cannot authenticate a marketing-version claim. Matching is derived, never persisted as a peer-owned trusted flag; source removal, check failure or scope expiry cannot leave an old confirmation sticky.

## Source boundaries

Sources are fetched through existing developer-appcast, mapped/configured GitHub and Homebrew adapters, never a URL supplied by a peer. Homebrew is a catalog, not a developer signature. A user-configured feed/repository is trusted by that user's choice, not automatically established as developer-owned. The UI says source matches rather than developer-authenticated. Source compromise or a mistaken custom source remains outside this community-claim safeguard. Download integrity, matching developer identity, nested code signatures and installation confirmation remain separate requirements.

The P2P page and all-app details retain community reports for investigation. **Check update sources** uses the normal source-check operation. An absent official/configured source leaves the report unverified; no majority-vote fallback is used. A publisher reporting 999.0 can remain visible as an unverified lead, but cannot increase the update count or produce an update notification.

## Validation

Ten targeted regression tests include a cryptographically valid invented 999.0 claim, 100 publisher identities, wrong/missing build evidence, duplicate/expired identities, source removal/failure, incorrect application identity and notification deduplication. The native synthetic UI acceptance exercises count 0 → 1 → 0 while fake 999.0 remains unverified. It uses an isolated preferences file and synthetic entry point with actual store/core/views; no public networking or notification submission is performed by that fixture.

The ongoing 24-hour run is pinned to the previous 0.3.1 product binary. Its result cannot validate these new policy/UI changes. Do not replace that running signed bundle to test this change.

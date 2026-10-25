# Global P2P participation, 0.4.1

The native app has one **Enable P2P network** switch in Settings → P2P. The per-application column, selection workflow and separate sharing switch are removed. Enabling means discovery **and** public version sharing across all scanned applications; disabling cancels synchronization, clears local community displays, stops publication/serving and closes the UDP transport. Already cached public reports remain subject to their existing expiry.

Fresh installations default on. The boolean is persisted before startup enables public networking; unreadable/corrupt settings or failed initialization remain off. Previously stored global choices are preserved. Earlier app-specific consent and separate flags migrate to off, because their selected scope did not authorize expanding an existing user's public inventory. The user may then enable the new global scope explicitly. The old flags and selection list are removed from the settings file.

The Settings description identifies the public fields: bundle ID, version, build, channel and self-reported Team ID. Peers see IP addresses. Paths, usernames, device names, app display names and binaries are excluded. The user explicitly chose combined discovery/sharing for this change.

Internally, a deterministic full inventory is deduplicated by the protocol's identity/channel/developer topic, choosing the newest comparable installed copy. Bounded batches rotate over the entire inventory; apps after the first twenty are not omitted. Progress advances after each completed application. Other batches' reports and verified publisher keys are retained subject to their existing expiry and cache limits. Ignoring update notifications does not exclude an app from this global scope.

Stop/start transitions are serialized and invalidate old generations. Stop closes the transport before waiting for canceled synchronization to finish. Keychain access runs off the main actor, so it cannot block the settings UI. The wire format, signature validation, replay protection and source-only update/notification/installation authority remain unchanged.

## Validation

The regression suite includes fresh default-on initialization, preservation of explicit global choices, conservative legacy migration, invalid preference types, complete multi-batch coverage, identity/channel separation, newest-copy selection, cancellation of pending UDP work, port release, suspended-client rejection, explicit resume and invalidation of an in-progress preparation. Existing protocol and false-claim regressions remain required.

Native UI and distribution evidence is recorded separately after the signed candidate is built. A unit test for defaults is not a public-network or real-community acceptance claim. The earlier 0.4.0 source-only observation ended after about 22 minutes when the observed PID disappeared; it cannot validate this version or count as a 24-hour pass.

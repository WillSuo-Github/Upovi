# Upovi public discovery protocol v2

## Consent and identity

Public mode has new preference keys, `publicDiscoveryEnabledV2` and `publicSharingEnabledV2`. Both default to false. Private v1 settings are not interpreted as public-sharing consent. The publisher's Ed25519 private key is stored in Keychain account `public-dht-v2`; the v1 `dht-v1` identity and read keys are not advertised.

The application no longer asks users to exchange invitations or contacts. The legacy encrypted v1 protocol remains available to explicit CLI callers and is documented separately in `P2P-PRIVATE-V1.md`.

## Application topic

```text
parts = ["app.upovi.public-version.v2", bundleID, channel, teamID-or-integer-zero]
info_hash = SHA1(bencode(parts))
```

`parts` is a bencoded list. A missing Team ID is integer zero; an empty Team ID is an empty byte string. Channels are `developer` or `app-store`. The topic is stable across versions but different for other bundle IDs, channels, or Team IDs. SHA-1 is used only for DHT routing, as required by BEP 5, not report authentication.

Topic hashes are predictable: they do not hide application identity or provide access control.

## Standard DHT discovery

The client bootstraps with `find_node`, then iteratively sends `get_peers` using `info_hash`. Routing candidates are ordered by XOR distance. Lookup uses at most five concurrent requests and twelve rounds, caches a bounded routing set, and resets that set after total response failure.

A sharing process obtains write tokens from `get_peers` and sends `announce_peer` to up to eight responding candidates. `implied_port=1` registers the UDP source port observed by the storage node. DHT requests, announcements, and incoming peer queries use one bound native IPv4 socket.

Membership consists of ordinary compact IP/port endpoints, not signing public keys. Returned endpoints are untrusted. Invalid, local/private, multicast, zero-port, and benchmarking-range contacts are filtered outside explicit isolated-test mode. IPv6 contacts are not implemented.

The client samples up to twelve endpoints per topic, four at a time. Sampling is shuffled to avoid permanent low-IP bias. This is a bounded sample, not an exhaustive list of all sharers.

## Rotating public publisher index

BEP 5 membership returns only endpoints, which may not be reachable behind NAT. Upovi additionally discovers public signing keys through BEP 44 rendezvous slots. This permits a new reader to obtain a publisher's independently signed cached record without an inbound connection to that publisher.

For each application topic, the client reads four shards in the current and previous one-hour epochs:

```text
epoch = floor(unixSeconds / 3600)
shard = SHA256(publisherPublicKey)[0] mod 4
slotSeed = SHA256(bencode(["app.upovi.public-rendezvous.v2", info_hash, epoch, shard]))
slotKey = Ed25519.PrivateKey(rawSeed: slotSeed)
slotSalt = UTF8("upovi-index-v2")
slotTarget = SHA1(slotKey.publicKey || slotSalt)
slotValue = bencoded list of at most sixteen 32-byte publisher public keys
```

The slot seed and signing key are intentionally **public coordination material**. Their signature is only BEP 44 wire compatibility; it supplies no publisher authenticity or authorization. This is not an embedded private authority key and must never be reused to sign a publisher observation.

A publisher reads its assigned slot, merges its own key with a bounded sample of existing keys, and performs a BEP 44 compare-and-swap against each storage candidate's observed sequence, retrying up to three times on contention. Readers reject duplicate or wrong-shard pointers and out-of-epoch sequences. Slot sequence high-water marks are not trusted across slots, and each hour uses different keys.

Anyone can crowd or overwrite these open slots, including with future-sequence poison that storage nodes may retain. Rotation, sharding, sequence bounds, independent replicas, and CAS reduce ordinary collisions and bound some stale interference; they do not provide Sybil resistance or prevent sustained denial of discovery. Treat missing, poisoned, or crowded slots as incomplete discovery, never evidence of no update.

The reader unions all structurally valid slot replicas returned by the bounded lookup, rather than selecting only the highest-sequence replica. This can retain honest pointers when another replica omits them; it cannot help if every reachable replica is poisoned. The reader samples up to eight keys, reserving four positions for previously validated publishers when available and four for new index pointers. Unused positions are filled from either pool. It independently fetches their BEP 44 observations at `SHA1(publisherKey || info_hash)`, and verifies actual publisher signatures and application identity. An index pointer, even with a valid public slot signature, is never displayed as a validated publisher or update. Direct endpoint requests are always sampled, including when valid DHT reports exist, so one index publisher cannot suppress fresher direct observations. DHT and direct publisher counts are reported separately and may overlap.

## Native peer queries

Peers exchange bencoded KRPC envelopes with a fresh eight-byte transaction ID and response-source matching. Public version records are served through two namespaced methods on the same UDP socket:

```text
upovi_hello:  { id: 20-byte-client-id, topic: 20-byte-info-hash }
response:    { id: 20-byte-node-id, token: 16-byte-cookie }

upovi_report: { id: 20-byte-client-id, topic: 20-byte-info-hash, token: cookie }
response:    { id: node-id, k: 32-byte-publisher-key, seq: integer, sig: 64-byte-signature, v: JSON-byte-string }
```

The server only answers topics selected for active public sharing. The cookie is a truncated HMAC-SHA256 over the source IP, source port, topic, and minute bucket, using a random server secret. Current/previous minute cookies are accepted. This limits report amplification by requiring a round trip to the claimed source endpoint. It does not authenticate a person.

Incoming request and response envelopes are capped at 1400 bytes. Packet parsing, nesting, outstanding requests, and inbound request budgets are bounded. The socket limits incoming queries per source IP and globally; these limits do not apply to responses to the client's own routing queries.

## Signed public observations

`v` contains JSON with `bundleID`, `version`, `build`, `channel`, optional `teamID`, `observedAt`, and `expiresAt`. Foundation JSONEncoder's reference-date representation is used for dates. No file paths, usernames, app display names, devices, download addresses, or binaries are included.

The public report is not encrypted. Its BEP 44 salt is the application topic:

```text
salt = info_hash
seq = max(unixMilliseconds, previousPersistedSequence + 1)
sig = Ed25519.sign(bencode("salt") || bencode(salt)
                 || bencode("seq") || bencode(seq)
                 || bencode("v") || bencode(v))
```

`v` is a byte string whose bencoded length is at most 1000 bytes. A subscriber rejects a sequence more than five minutes ahead of its local clock and verifies the node signature, expected topic, report field lengths, bundle ID, channel, Team ID, timestamps, and expiry. Version comparison rejects unparseable values and does not recommend prerelease versions over a stable installation.

A valid signature proves possession of the publisher's node key, not that the application developer released the version or that the publisher really installed it. One publisher can create multiple identities. Community reports remain advisory and have no installation URL or automatic execution path. They do not enter update counts, the available-updates list or notification/deduplication batches. The native client groups identical version/build claims, counts distinct publisher keys for descriptive labels only, and annotates exact matches against independently fetched source candidates. A claimed build must be present and identical in the source; build-only appcasts cannot confirm a marketing version. Source matching grants the report no update authority. See [COMMUNITY-TRUST.md](COMMUNITY-TRUST.md).

## Caching and operation

Public reports are additionally published as BEP 44 mutable records at `SHA1(publisherKey || info_hash)`. Automatically learned signing public keys are cached locally by application topic, bounded to sixteen candidates per topic. Verified history keys receive a reserved part of the eight-key sample even when open slots are crowded. Remembered publishers are also attempted if both rendezvous lookups fail; failed discovery is not itself evidence that the signed storage lookup will fail.

A compact endpoint alone cannot reveal a publisher signing key. The public rendezvous index supplies untrusted key pointers, allowing first-time readers to retrieve independently signed DHT records even when direct peer connections are blocked. Inbound reachability is unnecessary for this path, but outbound UDP and available DHT/index records are still required.

While the native app runs with discovery enabled, it attempts synchronization on launch, when discovery is enabled, manually, and every ten minutes. Observations expire at most 24 hours after creation; DHT nodes may evict unrefreshed records much earlier (roughly two hours). Expired observations are rejected even if a node still serves them.

Turning sharing off clears active report service. Turning the network off also cancels the synchronization task. A write or response already sent cannot be recalled, and topic registrations/cached copies may persist until remote eviction.

### Durable replay protection

The native app atomically stores public publisher/topic high-water marks, payload digests, and outbound publication sequences in `~/Library/Application Support/Upovi/community-history-v2.json`. No private key, installed path, or readable version inventory is stored in this file. It is local operational state, not publisher reputation. The diagnostic CLI is isolated in memory by default; `--state-file <path>` enables durable state. Use a separate state file for each concurrently running process; the file store is single-writer.

Only reports that pass signature, topic, application, timestamp, and expiry checks can advance the accepted sequence. Both DHT and direct responses use the same history. A lower sequence is rejected across process restarts. An equal sequence is accepted only with an identical signed payload; conflicting content is rejected. A malformed or far-future report cannot raise the durable floor. The report payload is validated before selecting the newest DHT replica, so a newer invalid payload cannot mask a valid older replica.

Receiving marks are retained for thirty days after the last sequence advance and bounded to 2048 publisher/topic entries. The oldest mark is evicted at capacity. Protection does not extend to forgotten entries, cleared local state, reinstalled machines, or a fresh publisher identity. Re-reading an identical signed record does not extend retention. Expiry is checked independently on every read; a remembered public key does not make an expired report usable. Corrupt history or persistence errors fail closed and surface as a failed check rather than silently resetting the floor.

Outbound sequence allocation persists before publication. Minor clock rollback still produces an increasing sequence; a rollback exceeding the five-minute sequence tolerance stops publication until the clock recovers. Outbound marks are bounded to 2048 entries and never silently evicted. Disabling sharing or changing selected applications cancels the current synchronization; a stopped generation cannot finish preparing a new report service. Network packets already sent cannot be recalled.

These checks protect ordering and improve discovery continuity. They do not validate installation claims, establish independent humans, or solve malicious index writers and Sybil identities.

## Reachability and scope

- Automatic discovery uses standard BEP 5 membership plus an open, untrusted, rotating BEP 44 publisher index. There is no Upovi central service, user invite, private read secret, or shared publisher-signing identity. Public index slot keys provide no trust.
- This version has no coordinated NAT punching, UPnP/NAT-PMP mapping, or relay fallback. The DHT record path avoids inbound NAT requirements; direct endpoint reachability is measured separately.
- Advertisements may be stale, unreachable, or malicious. An empty swarm or a failed response is not evidence of an up-to-date application.
- The first version bounds selection to twenty bundle IDs and IPv4 routing. Routing membership and record availability are best-effort.
- Old private v1 records stay encrypted and are not published through this protocol.

References: [BEP 5](https://www.bittorrent.org/beps/bep_0005.html), [BEP 43](https://www.bittorrent.org/beps/bep_0043.html), [BEP 44](https://www.bittorrent.org/beps/bep_0044.html), [BEP 55](https://www.bittorrent.org/beps/bep_0055.html).

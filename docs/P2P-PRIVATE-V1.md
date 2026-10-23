# Upovi P2P protocol v1

## Roles

A publisher controls an Ed25519 private key and a random 256-bit read key. A subscriber imports the publisher's public key and read key through `upovi://peer?v=1&key=<base64>&read=<base64>`.
The app keeps both publisher credentials and imported invitations in local Keychain entries. The diagnostic CLI uses explicit private test files.

There is no central application inventory, room server, or binary distribution. Existing BitTorrent DHT storage nodes cache signed, encrypted application observations.
Peer-to-peer exchange here means publishing to and retrieving from that distributed network, not maintaining a direct session between two Upovi processes.

## Addressing

For an application bundle identifier and distribution channel:

```text
salt = HMAC-SHA256(readKey, UTF8("upovi/v1/<channel>/<bundleID>"))
target = SHA1(ed25519PublicKey || salt)
```

SHA-1 is used only for the DHT-mandated routing address, not as an authenticity mechanism.
Channels are `developer` or `app-store`. Subscribing only queries locally selected application identities; there is no public inventory listing endpoint.

## Record

The JSON payload contains `bundleID`, `version`, `build`, `channel`, optional `teamID`, `observedAt`, and `expiresAt`.
Dates use the Foundation JSONEncoder reference-date representation. `expiresAt` is at most 24 hours after `observedAt`; observations over five minutes in the future are rejected.

```text
aad = UTF8("upovi-record-v1") || ed25519PublicKey || salt
v = AES-GCM(readKey, randomNonce, jsonPayload, aad).combined
seq = max(currentUnixMilliseconds, previousVerifiedSequence + 1)
signature = Ed25519.sign(bencode("salt") || bencode(salt)
                       || bencode("seq") || bencode(seq)
                       || bencode("v") || bencode(v))
```

`v` is always a byte string, and its bencoded representation must be at most 1000 bytes. The sequence is a non-negative signed 64-bit integer.
The subscriber verifies the expected key, routing target, signature, AES-GCM tag, bundle ID, channel, timestamps, and field sizes.
The client retains an in-memory sequence high-water mark to reject older returned records during that process lifetime; this is not a persistent anti-rollback guarantee across restarts.

## Network behavior

KRPC requests use UDP, a fresh transaction ID, `ro=1` read-only-node behavior, and a bounded response deadline.
Bootstrap uses `find_node`, because bootstrap routers may not implement BEP 44 `get`.
Lookup iteratively issues `get` to up to five candidates at a time, compares XOR distances, and caps work at twelve rounds.
The implementation caches a bounded candidate set in memory and clears it after total response failure so subsequent attempts can bootstrap again.
Only compact IPv4 contacts are currently used; private and local addresses supplied by network contacts are rejected outside explicit isolated-test mode.

The client verifies signatures over canonical BEP 44 bytes. It tolerates unordered dictionaries in real-world KRPC response envelopes but rejects duplicate keys and malformed/truncated values.
Record data is a byte string, so envelope ordering does not change the signed value.

Publication obtains write tokens through lookup and sends `put` to at most eight closest responding storage candidates. The UI counts actual successful responses, not assumed publication.
A returned storage acknowledgement does not guarantee long-term availability or independent replication.

## Boundaries

- The first version is invitation-based; it has no global publisher discovery index.
- No TCP sessions, NAT hole-punching, UPnP mappings, relayed binaries, or automated application replacement are implemented.
- The network may refuse storage or return no record. The UI reports this rather than inventing a peer observation.
- A publisher can lie about its installed version, Team ID, or distribution channel. Publisher signatures are not developer signatures or installation attestation.
- Invitations cannot be remotely revoked. Do not interpret removing a local contact as revoking that contact's prior access.
- Records may disappear before their application-level expiry. The app must remain running and connected to republish periodically.

References: [BEP 5](https://www.bittorrent.org/beps/bep_0005.html), [BEP 43 read-only nodes](https://www.bittorrent.org/beps/bep_0043.html), [BEP 44](https://www.bittorrent.org/beps/bep_0044.html).

# Two-Mac public discovery acceptance

Status: prepared, not yet executed on two physical Macs. A one-Mac public DHT run is separate evidence.

## Setup

Use this source revision on two physical Macs with Xcode command-line tools. Connect Mac A to a home network and Mac B to a mobile hotspot or another independent network. Do not connect the Macs through a VPN or the same LAN. Record OS version, CPU architecture, source revision, network type, and time manually. The CLI procedure below publishes only synthetic metadata. Testing native lifecycle behavior with real applications is a separate opt-in sharing decision; never enable it implicitly for this test.

Build on each Mac from the project root:

```sh
swift build --product UpoviPeer
mkdir -p .local/cross-network
```

Both sides use the same synthetic bundle ID and Team ID below. This is a test topic, not an invitation or access secret. Use a new synthetic bundle suffix for each run if stale reports would confuse the result. Do not transfer identities, state files, publisher keys, or bootstrap addresses between Macs.

## Publish on Mac A

```sh
.build/debug/UpoviPeer identity --output .local/cross-network/publisher.json
.build/debug/UpoviPeer share-public \
  --identity .local/cross-network/publisher.json \
  --state-file .local/cross-network/publisher-state.json \
  --bundle app.upovi.synthetic.cross-network.acceptance1 \
  --team SYNTHETIC --version 2.5.0 --duration 600
```

Record the printed publisher ID and three acknowledgement counts. Identity creation refuses to overwrite an existing file; reuse the identity for restart cases. Keep its JSON and `.invite` files private. Acknowledgements alone do not pass discovery.

## Read on Mac B

Use a fresh reader state file for the first run; omit `--state-file` for a completely stateless diagnostic reader:

```sh
.build/debug/UpoviPeer discover \
  --bundle app.upovi.synthetic.cross-network.acceptance1 \
  --team SYNTHETIC --version 1.0 --require-report \
  --state-file .local/cross-network/reader-state.json \
  --evidence-file .local/cross-network/first-read.json
```

Pass requires the report version and publisher ID in the JSON to match Mac A. `dhtPublishers` and `directPublishers` describe separately verified paths; the same publisher can count in both. `directPublishers=0` does not invalidate a successful DHT-record path, but must not be reported as NAT traversal success. An empty result is incomplete discovery, not an up-to-date application.

## Recovery cases

| Case | Procedure | Required observation |
| --- | --- | --- |
| Offline publisher / first-time reader | Stop Mac A's process; run Mac B without any state file shortly afterward | Reader still discovers the publisher through public index and cached signed DHT records, if those records remain available |
| Publisher restart | Relaunch Mac A with the same identity/state, version 2.6.0; repeat Mac B read | Newer version found; record cannot reuse an older sequence |
| Reader restart | Quit reader and repeat using the same reader state | Valid current report accepted; isolated replay regression separately proves rejection of an older signed report |
| Network change | Move Mac B between two networks; repeat read | A new process reconnects and reports the actual result; no false current status |
| Sleep / wake | Sleep/wake the native app on each Mac, then run manual discovery | App remains responsive and discovery can recover; CLI success alone does not accept native lifecycle behavior |
| Reverse roles | Publish independently on Mac B and discover from Mac A | Matching new publisher and report without exchanging keys |
| Restricted UDP | Test on a network known to block UDP | Check fails visibly; no claim that all networks are supported |

Observe at least 24 hours of the native application's ten-minute synchronization before claiming sustained background reliability. Record failures as well as successes. Do not keep a test publisher alive merely to improve a reported success rate.

Evidence JSON contains synthetic reports, public short publisher IDs, timestamps, and path counts. It omits private identity material and endpoint IPs. Attach only the intended evidence files when reporting results; never upload the entire `.local` directory. The development app remains ad-hoc signed and unnotarized.

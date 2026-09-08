# Safe Run beta failure-mode matrix

| Test | Failure point | Detection | Mitigation | Residual risk |
| --- | --- | --- | --- | --- |
| F-W01 | Crash between sequence allocation and outbox write | Recovery state/sequence audit | One atomic Watch state v2 write | Device storage can still fail; UI must show storage error |
| F-W02 | WatchConnectivity unreachable | Reachability + growing outbox | Persist first; retry after activation/reconnect | No direct Watch-to-cloud path |
| F-P01 | iPhone killed with active lease | Expired `leased_until` | Reclaim after lease expiry | Upload delayed by lease duration |
| F-P02 | SQLite corruption | `PRAGMA quick_check` failure | Fail closed; no Watch ACK/uploader; preserve DB | Manual support recovery may be required |
| F-B01 | Scheduler delivered repeatedly | Session edge state + transaction | `healthy → stale` once; stable incident state | Scheduler and push remain best effort |
| F-B02 | Ingest races stale monitor | Transaction rereads session edge | Valid terminal state, recovery resolves warning | Temporary warning may already have reached APNs |
| F-N01 | Duplicate Watch/backend request | Packet/event/attempt IDs | Durable tombstones and idempotent writes | APNs does not promise exactly-once display |
| F-R01 | TTL is delayed or subcollections remain | Privacy sweep and expiry audit | Per-collection `expire_at` plus daily sweep | Firebase TTL is asynchronous |

P0 is never dropped or reordered by debug chaos. Tests may delay it or make the transport unreachable to prove durable recovery.

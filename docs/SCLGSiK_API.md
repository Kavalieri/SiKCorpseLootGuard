# SCLGSiK product API

`SCLGSiK.API` is the public product API for SiK Corpse Loot Guard.
`SCLG.API` is not an alias. Load the shared module with
`require "SCLGSiK_API"`.

The current product has no custom SiK UI surface and declares no
`SiKUIFramework` dependency. It keeps vanilla presentation directly. If a real
custom surface is introduced later, that UI may consume `SiK.UI`; it must not
move diagnostic authority into the framework or turn `SCLGSiK.API` into a UI
namespace.

Corpse Loot Guard is diagnostic-only. This API cannot create, delete, move,
restore, or repair corpse/player items, and it never exposes live item, corpse,
player, cache, or Java references.

Most fallible calls return `value` on success or `nil, errorCode` on failure.
`Capabilities.has` returns `true` on success or `false, errorCode`. Event
subscriptions return a disposable token or `nil, errorCode`.

## Capability discovery

`SCLGSiK.API.Capabilities.describe()` returns a copied descriptor similar to:

```lua
{
    api = "SCLGSiK.API",
    apiVersion = "1.0.0-dev1",
    productVersion = "<runtime product version>",
    diagnosticOnly = true,
    capabilities = {
        { name = "Diagnostics", version = "1.0.0" },
        { name = "Events", version = "1.0.0" },
        { name = "Snapshot", version = "1.0.0" },
    },
}
```

`Capabilities.has(name[, minimumVersion])` reports
`capability_unavailable` or `capability_version_too_old` where applicable.
No recovery, mutation, or repair capability exists or is planned by this API
contract.

## `Snapshot`

`Snapshot.normalize(snapshot)` returns a bounded, portable diagnostic copy.
It keeps documented scalar player fields and the `worn`, `attached`,
`inventory`, and `itemVisualTypes` collections; every collection is limited to
256 entries, text is limited to 512 bytes, and the result carries `truncated`
when a limit was applied. Invalid input returns `nil, "snapshot_required"`.

`Snapshot.fingerprint(snapshot)` normalizes first and returns a deterministic,
non-cryptographic comparison fingerprint. It is useful for deduplication and
audit comparison only; it is neither an authority token nor a recovery key.

## `Events`

`Events.subscribe(eventId, handler)` observes one product-owned diagnostic
event. The supported IDs are:

- `snapshot-captured`
- `audit-completed`
- `case-opened`

It returns a token with `token:dispose()`. `Events.unsubscribe(token)` is the
equivalent explicit disposal function. Invalid IDs, handlers, or tokens return
`unknown_event`, `handler_required`, or `invalid_subscription`.

Only the product-owned `SCLGSiK.emitDiagnosticEvent` emits these events; it is
intentionally outside `SCLGSiK.API` so consumers cannot impersonate the
diagnostic producer. Payloads are copied and listener failures are isolated.

## `Diagnostics`

`Diagnostics.session()` returns a plain descriptor containing the product ID,
product/API versions, whether this process is authoritative, and
`diagnosticOnly = true`.

`Diagnostics.copyPayload(payload)` creates a portable bounded copy for an
observer boundary. It rejects non-table input with `payload_required` and never
returns product caches or Java objects.

## Lifecycle and scope

The module is shared, but authoritative capture/audit behavior remains owned by
the product process. Calling an API reader on a client does not simulate
server-only data or create authority.

Every event token must be disposed when its owning integration closes. Do not
retain snapshot copies as a substitute for the product's own bounded
diagnostic records.

New public entries must add reusable diagnostic value: validation, bounded
projection, stable errors, cleanup, observability, or product authority
context. A thin rename of a vanilla function does not belong in this API.

# Admin dashboard

The dashboard manages a **self-hosted** Buzz relay. It is served by the relay on
`https://buzz-admin.<domain>` and calls the relay's admin API
(`/api/admin/v1`, relay 0.3.0).

It cannot manage the hosted service at `buzz.xyz` or a
`*.communities.buzz.xyz` workspace. Those deployments do not expose this API.

## What you can do

| Resource | Create | Read | Update | Delete |
|---|---|---|---|---|
| Staff (operators, moderators) | Yes | Yes | Change role | Yes |
| Bans | Yes | Yes | No | Lift |
| Timeouts | Yes | Yes | Change duration | End |
| Reports | Filed by members | Yes | Resolve, reopen, cancel | No API |
| Feedback | Filed by members | Yes | Status | Archive instead |
| Messages (events) | Sent by members | By id | No | Yes |
| Members | `buzzctl onboard` | Search, profile | `buzzctl` | `buzzctl offboard` |
| Communities | No API | Yes | No API | `buzz-admin communities` |

The relay's admin API has no endpoint for roster changes or community
provisioning from this console, so those stay in the CLI.

## Signing in

Access passes two independent checks:

1. **IAP.** Your Google identity must be in `iap_members`.
2. **NIP-98.** Your Nostr key must be staff. The dashboard signs each request
   through a NIP-07 browser extension such as nos2x or Alby.

The dashboard never sees a private key and refuses an `nsec` if one is pasted.

## Roles

Operators can do everything above. Moderators can do everything except manage
staff. Keys listed in `config/<env>.yaml` are locked in the dashboard, so change
them in git and run `buzzctl deploy`.

## Deployment

`buzzctl deploy` mounts `helm/buzz-gke/files/admin-dashboard` from a ConfigMap
and points `BUZZ_ADMIN_WEB_DIR` at it. The relay image stays the exact upstream
artifact. A pod annotation hashes the files, so a dashboard change rolls the
relay pods.

To go back to the console built into the relay image:

```yaml
# config/<env>.yaml
adminDashboard:
  enabled: false
```

## Things to know

- A reason on a report action is **public**. The relay posts it in the channel
  and sends it to the affected person.
- A ban or delete can return "accepted". The relay finishes it in the background.
- The console has its own Service so IAP never applies to the relay's WebSocket
  backend.

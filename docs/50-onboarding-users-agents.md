# Onboarding people and agents

Access is membership. A Nostr pubkey is either on the relay roster or it is not;
there is no IdP behind it. See
[the security model](20-security-model.md#start-here-buzz-has-no-sso) for what
that means for joiner/mover/leaver process.

## Adding a person

Ask them for their **public** key — their Buzz client shows it on their profile,
as an `npub1...` string.

```sh
buzzctl onboard user prod --npub npub1abc...
```

Then tell them the relay URL, which `buzzctl` prints.

`--role admin` grants moderation rights. The workspace owner is set in
`config/<env>.yaml`, not by adding a member.

### Never accept an nsec

An `nsec1...` is a **private** key. Anything holding it *is* that account.
`buzzctl` refuses one outright with an explanation, so a paste error fails
loudly rather than putting someone's identity in your shell history.

If a user does send you their nsec, treat it as compromised: have them generate
a new key and onboard the new pubkey.

### If they have no key yet

They generate it in their Buzz client. If they need one out-of-band:

```sh
buzzctl keygen
```

**They** run this, on their own machine. Hand them the command, not the output.

## Removing a person

```sh
buzzctl offboard prod --npub npub1abc...
```

Two things to understand:

- **It is not instant.** Removal takes effect on that connection's next
  authorised event. For urgent revocation, also
  `kubectl -n buzz rollout restart deploy/buzz` to drop live sockets.
- **Their messages stay.** The event log is append-only and signed; removing
  history would break the audit chain that makes it worth having. This is
  usually what compliance wants, but confirm it against your retention policy
  rather than discovering it later.

**Put this in the leaver checklist.** Disabling someone's Google account does
not touch their Buzz access. Nothing else will do it.

## Adding an agent

Agents are members with keypairs, subject to the same membership checks and to
their own rate-limit class. The platform holds an agent's key, because an agent
is a process we run:

```sh
buzzctl onboard agent prod --name deploy-bot
```

This mints a keypair, stores it in a dedicated Secret Manager secret
(`buzz-prod-agent-deploy-bot`), adds the pubkey to the roster, and prints the
public half and the secret's name. The private key is never printed.

### Giving the agent its key

The agent reads `BUZZ_PRIVATE_KEY`. Grant its workload `secretAccessor` on
**that one secret** — not the project:

```sh
gcloud secrets add-iam-policy-binding buzz-prod-agent-deploy-bot \
  --member="serviceAccount:<agent-gsa>" \
  --role="roles/secretmanager.secretAccessor" \
  --project <project>
```

Then inject it the way the relay gets its own credentials — an ExternalSecret
into the agent's namespace — rather than baking it into an image or a config
file.

The relay's own service account has no Secret Manager access at all. An agent
should be no more privileged than the relay.

### Rate-limit classes

Agents have their own budgets, so a misbehaving agent cannot consume a person's:

| Class | Setting in `config/<env>.yaml` |
|---|---|
| Human | `humanMessagesPerMin`, `humanApiCallsPerMin`, `humanWsEventsPerSec` |
| Agent, standard | `agentStandardMessagesPerMin`, `agentStandardApiCallsPerMin` |
| Agent, elevated | `agentElevatedMessagesPerMin` |
| Agent, platform | `agentPlatformMessagesPerMin` |

Changing them means editing `config/<env>.yaml` and redeploying — they are
rendered into the relay's environment, and the change is reviewable in git.

## Removing an agent

```sh
buzzctl offboard prod --npub <agent pubkey>
gcloud secrets delete buzz-prod-agent-deploy-bot --project <project>
```

Remove the roster entry first. Deleting the secret while the agent still has a
valid session leaves it authenticated until its next authorised event.

## Operators

Operators get moderation rights on the admin console. Two independent gates,
both of which must pass:

1. **IAP** — their Google identity must be in `iap_members`
   (`terraform/environments/<env>/terraform.tfvars`), then `infra apply`.
2. **NIP-98** — their Nostr pubkey must be in `operators`
   (`config/<env>.yaml`), then `buzzctl deploy`.

IAP is the layer that *is* tied to corporate identity, so revoking someone's
Google account does remove their console access even though it does not remove
their relay membership.

The owner is always an operator. `render_values.py` includes them in
`RELAY_OPERATOR_PUBKEYS` automatically, because that variable overrides the
owner fallback entirely — setting a single operator without it would lock the
owner out of their own console.

## Auditing the roster

```sh
buzzctl members prod
```

Reads the live membership table through `buzz-admin` in a relay pod. Worth
diffing against your HR system periodically; nothing does that automatically,
and the gap between the two is exactly the offboarding risk.

---
spike: 001
name: wp07-provider-topology-decision
type: comparison
validates: "Primary-source provider evidence and current nullalis routing can select a scalable per-agent email path without mutating production infrastructure."
verdict: PARTIAL
related: []
tags: [email, provisioning, inbound-webhook, mailgun, architecture]
---

# WP-07 — Per-Agent Email Provisioning Decision

## Verdict

Use a **Mailgun EU inbound catch-all webhook** on `agents.chatzaki.com` for the scalable path. After authenticating the HTTPS request, resolve Mailgun's reported SMTP envelope recipient through an operator-owned agent-address registry, then route the message to the bound agent. Use one verified sending domain and operator-held SMTP credentials for outbound mail; derive each `From` address from the same registry.

Do not create one hosted mailbox per agent as the target architecture. A single manually provisioned IMAP/SMTP mailbox may be used for one pilot agent because the current `EmailChannel` can drive it without an engine change. That is a time-boxed operational fallback, not the WP-22 design.

The verdict is `PARTIAL`, rather than `VALIDATED`, because the approved spike scope excluded provider accounts, DNS changes, webhook deployment, and live mail delivery.

## Scope boundary

This spike performed document research, repository recon, and architecture comparison only. It did not:

- create or modify DNS records;
- create a Mailgun, Postmark, SES, Fastmail, or Stalwart resource;
- deploy a webhook or send/receive mail;
- change runtime code or configuration;
- collect a user mailbox password.

The mailbox is the agent's operator-provisioned identity. It is deliberately separate from a user's personal mailbox connection (path A/Composio).

## Current-engine recon

The roadmap's mailbox-granularity claim is directionally correct but incomplete:

- `EmailConfig` already has an `account_id`, IMAP/SMTP connection data, one username/password, one `from_address`, polling cadence, and sender allowlist (`src/config_types.zig:844`).
- `EmailChannel` performs verified-TLS IMAP polling and SMTP sending (`src/channels/email.zig:511`).
- Inbound parsing currently returns sender, subject, body, and message ID only. It does not preserve `To`, `Delivered-To`, `X-Original-To`, or an SMTP envelope recipient (`src/channels/email.zig:728`, `src/channels/email.zig:970`).
- The polling loop routes every message through the configured mailbox `account_id`, not a parsed recipient (`src/channel_loop.zig:1335`, `src/channel_loop.zig:1358`).
- Polling sources are deduplicated by IMAP host, port, and username, so multiple account configs cannot safely fan out one catch-all inbox: the later poller is suppressed (`src/channel_adapters.zig:38`, `src/channel_manager.zig:287`).
- The generic email connect descriptor collects IMAP/SMTP passwords (`src/channel_control.zig:144`), while tenant settings explicitly classify `channels` as operator-owned (`src/user_settings.zig:260`). Recon found no path that turns those stored connect values into a newly instantiated/reloaded `EmailChannel`. Credential storage is therefore not runtime provisioning.
- The production Dockerfile already compiles the email channel (`Dockerfile:35`). The roadmap statement that production compiles only CLI and Telegram is stale; activation, not compilation, is the missing production surface.

Git archaeology confirms the intended progression: `a00a640c` made email bidirectional over IMAP/SMTP, `d43d8dba` wired polling and intentionally deduplicated shared inboxes, and `0952f922` introduced account-scoped routing. Catch-all fan-out was never completed.

## Provider comparison

| Option | Inbound identity | Outbound fit | Provisioning and scale | Security / residency | Decision |
|---|---|---|---|---|---|
| Mailgun EU | Direct webhook includes the SMTP `recipient`; routes/forwards support wildcard domains | SMTP LOGIN with STARTTLS/implicit TLS fits the current sender | One domain and catch-all route avoid N mailboxes and N pollers | HMAC-SHA256 webhook signatures, replay inputs, optional client certificate; EU endpoints and MX | **Selected** |
| Postmark | Catch-all inbound domain; JSON contains `OriginalRecipient` | SMTP LOGIN + STARTTLS fits | Simple one-stream webhook; lower entry price than Mailgun's full inbound tier | Inbound setup documents HTTP Basic auth; storage is in the US with SCC/DPA | Runner-up |
| Amazon SES | Receipt rules can match a domain/catch-all | SMTP fits | Low unit cost, but inbound requires S3/SNS/Lambda/IAM composition; SNS content has a 150 KB ceiling | Strong AWS controls; region availability constraints | Rejected for V1 complexity |
| Fastmail + JMAP/IMAP | Real mailbox/catch-all domain | Existing IMAP/SMTP works immediately | User creation is administrator-driven; JMAP is a mailbox protocol, not an agent provisioning system | App passwords/API tokens; hosted mailbox privacy posture | Pilot fallback only |
| Stalwart | Real self-hosted mailbox, catch-all RCPT, JMAP/IMAP | Full SMTP stack | CLI/API-key administration can automate accounts | Keeps data controlled, but adds stateful mail operations, abuse handling, reputation, upgrades, and AGPL/enterprise decisions | Defer until self-hosting is a product requirement |

Primary sources:

- Mailgun: [receive by HTTP](https://documentation.mailgun.com/docs/mailgun/user-manual/receive-forward-store/receive-http), [route filters](https://documentation.mailgun.com/docs/mailgun/user-manual/receive-forward-store/route-filters), [forwards](https://documentation.mailgun.com/docs/mailgun/user-manual/receive-forward-store/forwards), [webhook signatures](https://documentation.mailgun.com/docs/mailgun/user-manual/webhooks/securing-webhooks), [SMTP](https://documentation.mailgun.com/docs/mailgun/user-manual/sending-messages/send-smtp), [EU region separation](https://help.mailgun.com/hc/en-us/articles/360007512013-Can-I-transfer-my-domain-to-another-region-US-to-EU-EU-to-US), and [pricing](https://www.mailgun.com/pricing/).
- Postmark: [inbound domain forwarding](https://postmarkapp.com/developer/user-guide/inbound/inbound-domain-forwarding), [inbound payload](https://postmarkapp.com/developer/webhooks/inbound-webhook), [inbound authentication](https://postmarkapp.com/developer/user-guide/inbound/configure-an-inbound-server), [SMTP](https://postmarkapp.com/developer/user-guide/send-email-with-smtp), [pricing](https://postmarkapp.com/pricing/), and [GDPR/storage](https://postmarkapp.com/support/article/1218-gdpr-faq).
- Amazon SES: [receiving concepts](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-concepts.html), [SNS action and size limit](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-action-sns.html), [Lambda action](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-action-lambda.html), [SMTP](https://docs.aws.amazon.com/ses/latest/dg/smtp-connect.html), and [pricing](https://aws.amazon.com/ses/pricing/).
- Fastmail/JMAP: [developer protocols and tokens](https://www.fastmail.com/dev/), [app passwords](https://www.fastmail.help/hc/en-us/articles/360058752854), [IMAP/SMTP endpoints](https://www.fastmail.help/hc/en-us/articles/1500000278342), [user administration](https://www.fastmail.help/hc/en-us/articles/360058752594), and [catch-all domains](https://www.fastmail.help/hc/en-us/articles/1500000280261-Setting-up-your-domain-MX-only).
- Stalwart: [Docker/protocol surface](https://stalw.art/docs/install/platform/docker/), [Kubernetes operations](https://stalw.art/docs/cluster/orchestration/kubernetes/), [catch-all RCPT behavior](https://stalw.art/docs/mta/inbound/rcpt), [account creation](https://stalw.art/docs/management/cli/create/), [API keys](https://stalw.art/docs/auth/authentication/api-key/), and [licensing](https://github.com/stalwartlabs/stalwart).

Pricing was checked on 2026-07-14 and is not an architectural guarantee. Recheck it before procurement.

## Topology and trust decision

```text
sender -> Mailgun EU MX for agents.chatzaki.com
       -> signed HTTPS webhook with SMTP envelope recipient
       -> bounded verification + durable dedupe
       -> operator-owned address registry
       -> tenant / user / agent binding
       -> normal nullalis inbound event and session routing

agent -> registry-derived From identity
      -> operator-held Mailgun SMTP credential
      -> recipient
```

The webhook request must authenticate before its `recipient` field becomes routing authority. RFC message headers are content and can be spoofed. A `To`/`Delivered-To` parser remains useful for the IMAP pilot and diagnostics, but it must not supersede the provider-reported envelope recipient of an authenticated HTTPS request.

Unknown, inactive, ambiguous, multi-agent, or malformed recipients fail closed. They must never fall back to a default agent. Address reuse needs a tombstone delay so delayed mail cannot cross identities.

Inbound email is untrusted model input, not delegated authority. It must not grant tool permissions or bypass the existing sender policy. The current empty `allow_from` list rejects all senders; WP-22 must choose and expose the agent-mailbox sender policy explicitly rather than silently opening it.

## Investigation trail

1. Read WP-07, roadmap 12.3, the current email channel, config, polling manager, routing loop, control plane, and related git history.
2. Tested the roadmap assumption that multi-account config could represent a catch-all inbox. Source-key deduplication and fixed-account routing disproved it.
3. Compared provider-owned envelope recipient delivery, sender compatibility, provisioning shape, verification, residency, and operational burden using official documentation.
4. Selected Mailgun EU catch-all webhooks for scale and retained mailbox-per-agent only as a zero-engine-change pilot fallback.
5. Expanded WP-22's required scope to include activation/reconciliation and control-plane honesty, because stored email secrets do not currently activate a channel.

## What remains unvalidated

- Mailgun account/domain approval and the exact EU plan available at procurement time.
- DNS ownership and MX cutover behavior for `agents.chatzaki.com`.
- Signature verification against a real Mailgun request.
- Retry/deduplication behavior under real redelivery.
- End-to-end inbound routing and outbound delivery/reputation.
- Provider limits for large MIME bodies and attachments under the chosen plan.

Those are WP-22 pre-production gates, not reasons to keep provider selection open.

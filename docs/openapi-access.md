# OpenAPI Connector — Operator Guide

nullalis can give the agent **governed access to any REST API** that ships an
OpenAPI 3.x specification. The operator registers each spec under
`api_specs`; the agent then discovers and calls its operations through a
single `openapi` tool. Specs are **never ingested from agent input** — the
agent only picks an operator-declared spec by its `id`.

Source: `src/openapi/` (parser + request builder), `src/tools/openapi.zig`
(the tool), `src/config_types.zig` `ApiSpecConfig` (config shape).

## Why one tool, not one tool per endpoint

The connector exposes **exactly one** `openapi` tool with an `operation`
argument. It does not generate a tool per API endpoint — that would flood
the model's tool catalog. Discovery happens through the tool's `list` and
`describe` modes instead.

## Config schema

`api_specs` is an object-of-objects keyed by the spec `id` (an array form
with an explicit `id` field is also accepted):

```json
{
  "api_specs": {
    "petstore": {
      "spec_url": "https://petstore3.swagger.io/api/v3/openapi.json",
      "base_url": "https://petstore3.swagger.io/api/v3",
      "auth_ref": "PETSTORE_API_KEY",
      "mode": "read_only"
    },
    "internal-billing": {
      "spec_path": "/etc/nullalis/specs/billing.json",
      "auth_ref": "BILLING_BEARER_TOKEN",
      "mode": "read_write"
    }
  }
}
```

Per-spec keys:

| Key         | Required | Meaning |
|-------------|----------|---------|
| `id`        | yes (object key) | Stable id the agent uses as the `spec` argument. |
| `spec_url`  | one of   | HTTPS URL to fetch the spec JSON from. |
| `spec_path` | one of   | Local filesystem path to a spec JSON file. |
| `base_url`  | no       | Base URL override. When empty, the spec's first `servers[].url` is used. |
| `auth_ref`  | no       | Name of the **environment variable** holding the static credential. Empty → the API needs no auth. |
| `mode`      | no       | `read_only` (default) or `read_write`. See **Access modes**. |

Exactly one of `spec_url` / `spec_path` must be set. An entry that sets
neither or both is **skipped with a warning** at config load — one bad spec
never aborts startup. The tool is registered only when at least one
`api_specs` entry is present.

## The `openapi` tool

| `operation` | Arguments | Result |
|-------------|-----------|--------|
| `list`      | — | Every registered spec id, its `mode`, and its operations (`operation_id`, `method`, `path`, `summary`, `read_only`). The discovery surface. |
| `describe`  | `spec`, `operation_id` | One operation's parameters (name, location, required, type) and request-body property shape. |
| `invoke`    | `spec`, `operation_id`, optional `path_params`, `query`, `body` | Resolves the operation, builds the request, applies auth, enforces the gates, executes the HTTP call, returns the response body + status. |

`path_params` and `query` are objects keyed by parameter name; `body` is an
object that is serialized to JSON. Spec-declared **header** parameters are
supplied via the `query` object too — the builder routes them by the
parameter's declared location.

### Lazy spec loading

A spec is fetched and parsed on the **first** `describe` / `invoke` that
touches its `id`, then cached for the life of the process. A spec that
fails to fetch or parse is recorded once and surfaced as a clean tool error
on every subsequent call — it is **not** retried in a loop. Fix the config
and restart to reload.

## Authentication

`auth_ref` names an **environment variable** that holds the static
credential. The connector resolves it at invoke time and injects it
according to the operation's effective `securityScheme`:

| Scheme (OpenAPI)             | Injection |
|------------------------------|-----------|
| `apiKey`, `in: header`       | `<name>: <credential>` request header |
| `apiKey`, `in: query`        | `?<name>=<credential>` appended to the URL |
| `apiKey`, `in: cookie`       | `Cookie: <name>=<credential>` header |
| `http`, `scheme: bearer`     | `Authorization: Bearer <credential>` |
| `http`, `scheme: basic`      | `Authorization: Basic base64(<credential>)` |
| `oauth2` / `openIdConnect`   | **Not supported in V1** — `invoke` returns a clear error. |

The credential **never** appears in the tool's arguments, output, logs, or
the model's context. Credential buffers are zeroed before they are freed.

> **V1 scope.** Credentials are read directly from environment variables.
> Full secret-vault integration (resolving `auth_ref` through the
> `secrets` subsystem) is a deferred follow-up — see
> `docs/deferred-register.md` (row D47).

## Access modes

`mode` is a **hard gate that sits above the approval engine**:

- **`read_only`** (default) — the agent may call GET / HEAD / OPTIONS
  operations. Every write operation (POST / PUT / PATCH / DELETE) is
  **refused outright**, regardless of the agent's autonomy level. No
  `confirm_once` prompt can override this.
- **`read_write`** — write operations are permitted, subject to the normal
  approval flow.

### Approval flow

Each `invoke` is classified at runtime: GET / HEAD / OPTIONS → a `read_only`
tool-metadata, everything else → `mutating`. This feeds the same approval
path that MCP and other dynamic tools use:

- **read** operations auto-run.
- **write** operations require `confirm_once` in supervised autonomy.
- In `full` autonomy, writes auto-run (still subject to the `read_only`
  mode hard gate above).

## Security properties

- **No agent-supplied specs.** The agent can only reference operator-declared
  `api_specs` ids; it cannot point the connector at an arbitrary URL.
- **HTTPS only.** Both spec fetch and `invoke` require `https://`.
- **SSRF-safe egress.** Every request resolves DNS once and pins the TCP
  connection to the validated global IP (`net_security`), exactly like the
  `http_request` tool — local / private addresses are blocked.
- **Bounded payloads.** A fetched spec is capped at 4 MiB; an `invoke`
  response is capped at 256 KiB before it is returned to the model.

## Worked example

```jsonc
// 1. Register a spec (config)
{ "api_specs": { "petstore": {
    "spec_url": "https://petstore3.swagger.io/api/v3/openapi.json",
    "mode": "read_only"
} } }
```

```jsonc
// 2. Agent discovers operations
{ "operation": "list" }
// → { "specs": [ { "id": "petstore", "mode": "read_only",
//      "operations": [ { "operation_id": "getPetById", "method": "GET",
//                        "path": "/pet/{petId}", "read_only": true }, ... ] } ] }
```

```jsonc
// 3. Agent inspects one operation
{ "operation": "describe", "spec": "petstore", "operation_id": "getPetById" }
```

```jsonc
// 4. Agent calls it
{ "operation": "invoke", "spec": "petstore", "operation_id": "getPetById",
  "path_params": { "petId": 1 } }
// → Status 200 + the pet JSON. A write op here would be refused: the
//   spec is registered read_only.
```

## End-to-end verification

A live E2E against a public spec is not run automatically (CI is offline /
hermetic). To verify manually against the Swagger Petstore:

1. Add the `petstore` `api_specs` entry above to your config.
2. Start nullalis and ask the agent to run `openapi` with
   `{"operation":"list"}` — confirm `petstore` and its operations appear.
3. Ask it to `invoke` `getPetById` with `path_params {"petId": 1}` — confirm
   a `Status: 200` response.
4. Ask it to `invoke` a write operation (e.g. `addPet`) — confirm it is
   **refused** with a `read_only` error while the spec stays `read_only`.
5. Flip the entry to `"mode": "read_write"`, restart, and confirm the write
   path now reaches the approval flow instead of the hard gate.

The connector's unit tests (`src/tools/openapi.zig`) cover lazy
load/cache, `list`/`describe` output, auth-header construction per scheme,
read/write classification, and the `read_only`-mode hard gate.

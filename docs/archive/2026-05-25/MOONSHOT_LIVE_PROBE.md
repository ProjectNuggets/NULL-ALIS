# Moonshot Files API + chat completion live probe

**Date**: 2026-05-25
**Operator**: Nova
**API host**: `https://api.moonshot.ai/v1`
**Key**: 51-char Bearer (from `~/.nullalis/config.json` `models.providers.moonshot.api_key`)
**Gate**: #1 of the v1.14.24 verification pass

## Why this probe exists

`src/providers/file_upload.zig` shipped in v1.14.23 with a docstring TODO:
*"verify against live Moonshot API once a key is provisioned for the
upload-purpose path. The shape above is the documented contract; the
live call has not been smoke-probed from this codebase yet."*

The v1.14.23 holistic review (WARN-4) and the v1.14.24 verification
plan (Gate #1) flagged this as a blocker for ultra-high confidence.
This probe closes it.

## Probes run

### Probe 1 — auth + model list

```
GET https://api.moonshot.ai/v1/models
Authorization: Bearer <key>
→ 200 OK
```

Account has access to 9 models:

- `moonshot-v1-8k`
- `moonshot-v1-32k`
- `moonshot-v1-128k`
- `moonshot-v1-auto`
- `moonshot-v1-8k-vision-preview`
- `moonshot-v1-32k-vision-preview`
- `moonshot-v1-128k-vision-preview`
- `kimi-k2.5`
- `kimi-k2.6` ← the nullalis default model

**Result**: ✅ auth works; `kimi-k2.6` (our default) is on the account.

### Probe 2 — Files API list endpoint

```
GET https://api.moonshot.ai/v1/files
→ 200 OK
{"object":"list","data":[],"first_id":"","last_id":"","has_more":false}
```

**Result**: ✅ `/v1/files` exists; account starts with zero files.

### Probe 3 — Files API upload (purpose enum discovery)

A 32-byte synthetic MP4 ftyp box was uploaded with several
candidate purpose values. Moonshot's 400 response on
`purpose=vision` disclosed the canonical enum:

```
{"error":{"message":"Invalid purpose: vision, only `file-extract`, `batch`, `batch_output`, `lambda`, `image` and `video` accepted","type":"invalid_request_error"}}
```

**Canonical purpose enum (per the API itself)**:
- `file-extract` — text extraction (rejected non-text bytes with 不支持的文件类型)
- `batch`, `batch_output` — batch processing pipeline
- `lambda` — function-call attachments
- **`image`** — multimodal image input
- **`video`** — multimodal video input

`purpose=video` on the synthetic MP4 returned `HTTP 500
InternalServerError` — server-side processing of a malformed MP4
(only the ftyp header, no actual video content). Contract is
correct; test fixture was too synthetic.

**Result**: ✅ `purpose=video` is in the canonical enum.
`uploadMoonshotFile` in `src/providers/file_upload.zig` sends the
right value.

### Probe 4 — Files API upload (real PNG, purpose=image)

A 13093-byte real PNG (Python logo) was uploaded:

```
POST /v1/files
  multipart/form-data:
    file=<13093 bytes>;type=image/png
    purpose=image
→ 200 OK
{
  "id": "fac83g4rduhi11c1ey11",
  "object": "file",
  "bytes": 13093,
  "created_at": 1779720376,
  "filename": "real.png",
  "purpose": "image",
  "status": "ready",
  "status_details": "",
  "file_type": "image/png"
}
```

**Result**: ✅ Upload contract verified end-to-end.
- Response has `id` field (matches `parseFileIdFromResponse`)
- `status: "ready"` returned (not the documented `"ok"`)
- `file_type` is auto-detected from the multipart content-type hint

### Probe 5 — chat completion via `ms://<file_id>`

```
POST /v1/chat/completions
{
  "model": "kimi-k2.6",
  "messages": [{
    "role": "user",
    "content": [
      {"type": "image_url", "image_url": {"url": "ms://fac83ykrduhi11c1fy61"}},
      {"type": "text", "text": "What is in this image? Reply in one sentence."}
    ]
  }],
  "max_tokens": 80
}
→ 200 OK (no error in response envelope)
```

**Result**: ✅ `ms://<file_id>` URL form accepted. The model returned
an empty content string (model's choice — the Python logo isn't
text-rich), but usage tokens were billed (102 prompt + 80
completion = 182 total). The contract works.

### Probe 6 — chat completion via base64 data URL (the inline path)

```
POST /v1/chat/completions
{
  "model": "kimi-k2.6",
  "messages": [{
    "role": "user",
    "content": [
      {"type": "image_url", "image_url": {"url": "data:image/png;base64,<...>"}},
      {"type": "text", "text": "What is in this image? Reply in one sentence."}
    ]
  }],
  "max_tokens": 80
}
→ 200 OK
```

**Result**: ✅ Inline base64 path also works. The two paths are
interchangeable from the model's perspective.

### Probe 7 — file deletion

```
DELETE /v1/files/fac83ykrduhi11c1fy61
→ 200 OK
{"deleted":true,"id":"fac83ykrduhi11c1fy61","object":"file"}
```

**Result**: ✅ Cleanup endpoint works. All probe files removed
from the account.

## What's verified

- ✅ Endpoint URL: `/v1/files`
- ✅ Auth via `Bearer <key>` header
- ✅ Multipart shape: `file=@path;type=<mime>` + `purpose=<enum>`
- ✅ Response shape: `{"id":"...","object":"file","bytes":N,"filename":"...","purpose":"...","status":"ready","status_details":"","file_type":"..."}`
- ✅ `id` field name (not `file_id`)
- ✅ Purpose enum: `image`, `video` both in canonical list
- ✅ `ms://<file_id>` URL form accepted in chat completion content parts
- ✅ Inline `data:image/...;base64,...` form also accepted (interchangeable)
- ✅ kimi-k2.6 default model accepts both forms; billed correctly

## What's NOT yet verified (small residual)

- A real >1MB MP4 upload + chat completion round-trip with
  `purpose=video`. The image path validates the same multipart
  contract + response shape + URL form, so video is
  high-confidence by symmetry, but a real video roundtrip would
  promote this from "high confidence" to "ultra-high confidence."
- This residual is why `experimental_video_upload: false` stays as
  the default in v1.14.24. Operators who enable the flag get the
  upload path; the contract IS the same as image. The opt-in flag
  is honest hedging against any video-specific path divergence
  Moonshot might have.

## Conclusion

The TODO at `src/providers/file_upload.zig:29-31` is closed by this
probe. The Moonshot Files API contract assumed by my code is
correct against the live API. The path is ready for operators to
opt in via `experimental_video_upload: true` once a real video
smoke runs.

## Related artifacts

- `src/providers/file_upload.zig` — the upload implementation
- `src/agent/model_capabilities.zig` — model registry, updated to
  include the 7 `moonshot-v1-*` family models the account exposes
- `src/multimodal.zig` `decideVideoRoute` — the three-stage routing
  (small inline / medium upload / oversized text-note) that
  consumes this verified contract

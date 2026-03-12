#!/usr/bin/env python3
"""
Validate strict Telegram ingress behavior against live gateway routes.

Flow:
1. Upsert a mapped channel identity binding for the target user.
2. Send a mapped Telegram webhook fixture (should be accepted).
3. Send an unmapped Telegram webhook fixture (should strict-reject when strict mode is active).
"""

from __future__ import annotations

import argparse
import datetime
import json
import urllib.error
import urllib.parse
import urllib.request


def http_json_request(
    *,
    method: str,
    url: str,
    timeout_secs: int,
    headers: dict[str, str] | None = None,
    body_obj: dict | None = None,
) -> dict:
    body_bytes = None
    merged_headers: dict[str, str] = {}
    if headers:
        merged_headers.update(headers)
    if body_obj is not None:
        body_bytes = json.dumps(body_obj).encode("utf-8")
        merged_headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url=url, method=method, data=body_bytes, headers=merged_headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout_secs) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            parsed = None
            try:
                parsed = json.loads(raw) if raw else None
            except Exception:
                parsed = None
            return {
                "ok": 200 <= resp.getcode() < 300,
                "status_code": resp.getcode(),
                "body": raw,
                "json": parsed,
            }
    except urllib.error.HTTPError as err:
        raw = ""
        try:
            raw = err.read().decode("utf-8", errors="replace")
        except Exception:
            raw = ""
        parsed = None
        try:
            parsed = json.loads(raw) if raw else None
        except Exception:
            parsed = None
        return {
            "ok": False,
            "status_code": err.code,
            "body": raw,
            "json": parsed,
            "error": "http_error",
        }
    except Exception as err:
        return {
            "ok": False,
            "status_code": None,
            "body": "",
            "json": None,
            "error": f"{err.__class__.__name__}:{err}",
        }


def build_telegram_update(
    *,
    update_id: int,
    principal: str,
    principal_fallback_id: int,
    scope_id: int,
    text: str,
) -> dict:
    from_obj = {"id": principal_fallback_id, "is_bot": False}
    if principal and not principal.isdigit():
        # Telegram webhook principal identity resolution prefers username when present.
        from_obj["username"] = principal
    elif principal.isdigit():
        from_obj["id"] = int(principal)
    return {
        "update_id": update_id,
        "message": {
            "message_id": update_id,
            "date": int(datetime.datetime.now(datetime.timezone.utc).timestamp()),
            "text": text,
            "chat": {"id": scope_id, "type": "private"},
            "from": from_obj,
        },
    }


def is_strict_reject(resp: dict) -> bool:
    if resp.get("status_code") != 403:
        return False
    parsed = resp.get("json")
    if isinstance(parsed, dict):
        code = parsed.get("code")
        error_value = parsed.get("error")
        if code == "strict_identity_reject":
            return True
        if error_value == "strict_identity_reject":
            return True
    body = resp.get("body") or ""
    return "strict_identity_reject" in body


def main() -> int:
    parser = argparse.ArgumentParser(description="Telegram strict-ingress canary for nullalis gateway")
    parser.add_argument("--gateway-base", default="http://127.0.0.1:3000")
    parser.add_argument("--internal-token", required=True, help="X-Internal-Token for user binding API")
    parser.add_argument("--telegram-secret-token", required=True, help="X-Telegram-Bot-Api-Secret-Token for webhook calls")
    parser.add_argument("--user-id", required=True)
    parser.add_argument("--account-id", default="default")
    parser.add_argument("--mapped-principal", required=True, help="Principal identity value (username or numeric id)")
    parser.add_argument("--mapped-scope", required=True, help="Scope identity value (telegram chat id)")
    parser.add_argument("--unmapped-principal", required=True, help="Unmapped principal identity value")
    parser.add_argument("--unmapped-scope", required=True, help="Unmapped scope identity value (telegram chat id)")
    parser.add_argument("--mapped-from-id", type=int, default=910001, help="Fallback sender id used when mapped principal is username")
    parser.add_argument("--unmapped-from-id", type=int, default=910002, help="Fallback sender id used when unmapped principal is username")
    parser.add_argument("--timeout-secs", type=int, default=30)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    user_id_enc = urllib.parse.quote(args.user_id, safe="")
    binding_url = f"{args.gateway_base}/api/v1/users/{user_id_enc}/channels/telegram/bindings"
    webhook_url = f"{args.gateway_base}/webhook/telegram?user_id={user_id_enc}"

    mapped_principal_key = f"telegram:principal:{args.mapped_principal}"
    mapped_scope_key = f"telegram:scope:{args.mapped_scope}"

    binding_resp = http_json_request(
        method="POST",
        url=binding_url,
        timeout_secs=args.timeout_secs,
        headers={
            "X-Internal-Token": args.internal_token,
        },
        body_obj={
            "account_id": args.account_id,
            "principal_key": mapped_principal_key,
            "scope_key": mapped_scope_key,
            "peer_kind": "direct",
            "peer_id": str(args.mapped_scope),
            "metadata_json": "{}",
        },
    )

    mapped_update = build_telegram_update(
        update_id=900000001,
        principal=args.mapped_principal,
        principal_fallback_id=args.mapped_from_id,
        scope_id=int(args.mapped_scope),
        text="strict canary mapped",
    )
    mapped_resp = http_json_request(
        method="POST",
        url=webhook_url,
        timeout_secs=args.timeout_secs,
        headers={
            "Content-Type": "application/json",
            "X-Telegram-Bot-Api-Secret-Token": args.telegram_secret_token,
        },
        body_obj=mapped_update,
    )

    unmapped_update = build_telegram_update(
        update_id=900000002,
        principal=args.unmapped_principal,
        principal_fallback_id=args.unmapped_from_id,
        scope_id=int(args.unmapped_scope),
        text="strict canary unmapped",
    )
    unmapped_resp = http_json_request(
        method="POST",
        url=webhook_url,
        timeout_secs=args.timeout_secs,
        headers={
            "Content-Type": "application/json",
            "X-Telegram-Bot-Api-Secret-Token": args.telegram_secret_token,
        },
        body_obj=unmapped_update,
    )

    summary = {
        "run_started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "gateway_base": args.gateway_base,
        "user_id": args.user_id,
        "account_id": args.account_id,
        "binding_upsert": binding_resp,
        "mapped": {
            "principal": args.mapped_principal,
            "scope": args.mapped_scope,
            "response": mapped_resp,
            "accepted": bool(mapped_resp.get("status_code") and 200 <= mapped_resp["status_code"] < 300),
        },
        "unmapped": {
            "principal": args.unmapped_principal,
            "scope": args.unmapped_scope,
            "response": unmapped_resp,
            "strict_reject_detected": is_strict_reject(unmapped_resp),
        },
    }

    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(
            f"[telegram-strict-canary] binding_status={binding_resp.get('status_code')} "
            f"mapped_status={mapped_resp.get('status_code')} "
            f"unmapped_status={unmapped_resp.get('status_code')} "
            f"strict_reject={summary['unmapped']['strict_reject_detected']}"
        )

    if not binding_resp.get("ok"):
        return 2
    if not summary["mapped"]["accepted"]:
        return 3
    if not summary["unmapped"]["strict_reject_detected"]:
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

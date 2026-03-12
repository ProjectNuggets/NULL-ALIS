#!/usr/bin/env python3
"""
Validate Slack strict-ingress behavior against live gateway routes.

Flow:
1. Upsert a mapped channel identity binding for the target user.
2. Send a mapped Slack webhook fixture (should be accepted).
3. Send an unmapped Slack webhook fixture (should strict-reject when strict path is wired).
4. Capture diagnostics strict_rejected delta for observability evidence.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import hmac
import json
import time
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
        body_bytes = json.dumps(body_obj, separators=(",", ":"), sort_keys=True).encode("utf-8")
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


def extract_strict_rejected_metric(diag_resp: dict) -> int | None:
    parsed = diag_resp.get("json")
    if not isinstance(parsed, dict):
        return None
    identity = parsed.get("identity_mapping")
    if not isinstance(identity, dict):
        return None
    value = identity.get("strict_rejected")
    if isinstance(value, int):
        return value
    return None


def is_strict_reject(resp: dict) -> bool:
    if resp.get("status_code") != 403:
        return False
    parsed = resp.get("json")
    if isinstance(parsed, dict):
        code = parsed.get("code")
        error_value = parsed.get("error")
        if code == "strict_identity_reject" or error_value == "strict_identity_reject":
            return True
    body = resp.get("body") or ""
    return "strict_identity_reject" in body


def build_slack_event(*, sender: str, channel: str, text: str, event_id: str, now_s: int) -> dict:
    return {
        "token": "unused",
        "team_id": "T_STAGE2A",
        "api_app_id": "A_STAGE2A",
        "type": "event_callback",
        "event_id": event_id,
        "event_time": now_s,
        "event": {
            "type": "message",
            "user": sender,
            "text": text,
            "channel": channel,
            "channel_type": "im",
            "event_ts": str(now_s),
            "ts": str(now_s),
        },
    }


def sign_slack_body(*, signing_secret: str, timestamp_s: int, body_json: dict) -> tuple[str, str]:
    body_raw = json.dumps(body_json, separators=(",", ":"), sort_keys=True)
    base = f"v0:{timestamp_s}:{body_raw}"
    digest = hmac.new(signing_secret.encode("utf-8"), base.encode("utf-8"), hashlib.sha256).hexdigest()
    return body_raw, f"v0={digest}"


def post_signed_slack(
    *,
    url: str,
    timeout_secs: int,
    signing_secret: str,
    payload: dict,
) -> dict:
    now_s = int(time.time())
    body_raw, signature = sign_slack_body(signing_secret=signing_secret, timestamp_s=now_s, body_json=payload)
    req = urllib.request.Request(
        url=url,
        method="POST",
        data=body_raw.encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "X-Slack-Request-Timestamp": str(now_s),
            "X-Slack-Signature": signature,
        },
    )
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
                "signature": signature,
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
            "signature": signature,
        }
    except Exception as err:
        return {
            "ok": False,
            "status_code": None,
            "body": "",
            "json": None,
            "error": f"{err.__class__.__name__}:{err}",
            "signature": signature,
        }


def main() -> int:
    parser = argparse.ArgumentParser(description="Slack strict-ingress canary for nullalis gateway")
    parser.add_argument("--gateway-base", default="http://127.0.0.1:3000")
    parser.add_argument("--internal-token", required=True, help="X-Internal-Token for user binding API/diagnostics")
    parser.add_argument("--signing-secret", required=True, help="Slack signing secret configured in gateway config")
    parser.add_argument("--user-id", required=True)
    parser.add_argument("--account-id", default="stage2a")
    parser.add_argument("--webhook-path", default="/slack/events")
    parser.add_argument("--mapped-principal", default="U_STAGE2A_MAPPED")
    parser.add_argument("--mapped-scope", default="D_STAGE2A_MAPPED")
    parser.add_argument("--unmapped-principal", default="U_STAGE2A_UNMAPPED")
    parser.add_argument("--unmapped-scope", default="D_STAGE2A_UNMAPPED")
    parser.add_argument("--timeout-secs", type=int, default=30)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    user_id_enc = urllib.parse.quote(args.user_id, safe="")
    binding_url = f"{args.gateway_base}/api/v1/users/{user_id_enc}/channels/slack/bindings"
    diagnostics_url = f"{args.gateway_base}/internal/diagnostics?user_id={user_id_enc}"
    webhook_url = f"{args.gateway_base}{args.webhook_path}"

    mapped_principal_key = f"slack:principal:{args.mapped_principal}"
    mapped_scope_key = f"slack:scope:{args.mapped_scope}"

    binding_resp = http_json_request(
        method="POST",
        url=binding_url,
        timeout_secs=args.timeout_secs,
        headers={"X-Internal-Token": args.internal_token},
        body_obj={
            "account_id": args.account_id,
            "principal_key": mapped_principal_key,
            "scope_key": mapped_scope_key,
            "peer_kind": "direct",
            "peer_id": args.mapped_scope,
        },
    )

    diag_before = http_json_request(
        method="GET",
        url=diagnostics_url,
        timeout_secs=args.timeout_secs,
        headers={"X-Internal-Token": args.internal_token},
    )
    strict_before = extract_strict_rejected_metric(diag_before)

    now_s = int(time.time())
    mapped_payload = build_slack_event(
        sender=args.mapped_principal,
        channel=args.mapped_scope,
        text="stage2a mapped",
        event_id=f"EvStage2aMapped{now_s}",
        now_s=now_s,
    )
    mapped_resp = post_signed_slack(
        url=webhook_url,
        timeout_secs=args.timeout_secs,
        signing_secret=args.signing_secret,
        payload=mapped_payload,
    )

    unmapped_payload = build_slack_event(
        sender=args.unmapped_principal,
        channel=args.unmapped_scope,
        text="stage2a unmapped",
        event_id=f"EvStage2aUnmapped{now_s}",
        now_s=now_s + 1,
    )
    unmapped_resp = post_signed_slack(
        url=webhook_url,
        timeout_secs=args.timeout_secs,
        signing_secret=args.signing_secret,
        payload=unmapped_payload,
    )

    diag_after = http_json_request(
        method="GET",
        url=diagnostics_url,
        timeout_secs=args.timeout_secs,
        headers={"X-Internal-Token": args.internal_token},
    )
    strict_after = extract_strict_rejected_metric(diag_after)
    strict_delta = None
    if strict_before is not None and strict_after is not None:
        strict_delta = strict_after - strict_before
    strict_reject_detected = is_strict_reject(unmapped_resp)

    summary = {
        "run_started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "gateway_base": args.gateway_base,
        "user_id": args.user_id,
        "account_id": args.account_id,
        "webhook_path": args.webhook_path,
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
            "strict_reject_detected": strict_reject_detected,
        },
        "strict_observability": {
            "strict_rejected_before": strict_before,
            "strict_rejected_after": strict_after,
            "strict_rejected_delta": strict_delta,
            "strict_identity_reject_observed": strict_reject_detected,
        },
    }

    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(
            f"[slack-strict-canary] binding_status={binding_resp.get('status_code')} "
            f"mapped_status={mapped_resp.get('status_code')} "
            f"unmapped_status={unmapped_resp.get('status_code')} "
            f"strict_reject={summary['unmapped']['strict_reject_detected']} "
            f"strict_delta={strict_delta}"
        )

    if not binding_resp.get("ok"):
        return 2
    if not summary["mapped"]["accepted"]:
        return 3
    if not strict_reject_detected:
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

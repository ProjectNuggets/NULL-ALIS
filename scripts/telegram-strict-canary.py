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
import ctypes
import ctypes.util
import datetime
import json
import pathlib
import re
import subprocess
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


def normalize_secret_token(value: str) -> str:
    token = value.strip()
    if len(token) >= 2 and token[0] == token[-1] and token[0] in {"'", '"'}:
        token = token[1:-1].strip()
    return token


def validate_schema_name(schema: str) -> bool:
    return bool(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", schema))


def resolve_telegram_secret_from_postgres(*, config_path: str, user_id: str, timeout_secs: int) -> str:
    config = json.loads(pathlib.Path(config_path).read_text(encoding="utf-8"))
    state_cfg = config.get("state", {})
    postgres_cfg = state_cfg.get("postgres", {})
    connection_string = str(postgres_cfg.get("connection_string") or "").strip()
    schema = str(postgres_cfg.get("schema") or "public").strip()
    if state_cfg.get("backend") != "postgres":
        raise RuntimeError("config backend is not postgres; cannot auto-resolve telegram secret")
    if not connection_string:
        raise RuntimeError("postgres connection_string missing in config")
    if not validate_schema_name(schema):
        raise RuntimeError(f"invalid postgres schema name in config: {schema!r}")
    try:
        user_id_int = int(user_id)
    except ValueError as err:
        raise RuntimeError(f"user_id must be numeric for postgres lookup: {user_id!r}") from err

    query = (
        f"SELECT COALESCE(telegram->>'webhook_secret_token','') "
        f"FROM {schema}.channel_state WHERE user_id = {user_id_int} LIMIT 1;"
    )
    token = resolve_secret_via_psql(connection_string=connection_string, query=query, timeout_secs=timeout_secs)
    if not token:
        token = resolve_secret_via_libpq(connection_string=connection_string, query=query)
    if not token:
        raise RuntimeError("telegram webhook_secret_token not found for user")
    return token


def resolve_secret_via_psql(*, connection_string: str, query: str, timeout_secs: int) -> str:
    try:
        proc = subprocess.run(
            ["psql", connection_string, "-At", "-c", query],
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_secs,
        )
    except FileNotFoundError:
        return ""
    if proc.returncode != 0:
        return ""
    output = (proc.stdout or "").strip()
    if not output:
        return ""
    return normalize_secret_token(output.splitlines()[0])


def resolve_secret_via_libpq(*, connection_string: str, query: str) -> str:
    lib_candidates = []
    discovered = ctypes.util.find_library("pq")
    if discovered:
        lib_candidates.append(discovered)
    lib_candidates.extend(
        [
            "/opt/homebrew/opt/libpq/lib/libpq.dylib",
            "/usr/local/opt/libpq/lib/libpq.dylib",
            "/opt/homebrew/lib/libpq.dylib",
            "/usr/local/lib/libpq.dylib",
        ]
    )
    libpq = None
    for lib_path in lib_candidates:
        try:
            libpq = ctypes.CDLL(lib_path)
            break
        except OSError:
            continue
    if libpq is None:
        return ""

    libpq.PQconnectdb.argtypes = [ctypes.c_char_p]
    libpq.PQconnectdb.restype = ctypes.c_void_p
    libpq.PQstatus.argtypes = [ctypes.c_void_p]
    libpq.PQstatus.restype = ctypes.c_int
    libpq.PQexec.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    libpq.PQexec.restype = ctypes.c_void_p
    libpq.PQresultStatus.argtypes = [ctypes.c_void_p]
    libpq.PQresultStatus.restype = ctypes.c_int
    libpq.PQntuples.argtypes = [ctypes.c_void_p]
    libpq.PQntuples.restype = ctypes.c_int
    libpq.PQgetvalue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
    libpq.PQgetvalue.restype = ctypes.c_char_p
    libpq.PQclear.argtypes = [ctypes.c_void_p]
    libpq.PQfinish.argtypes = [ctypes.c_void_p]

    connection = libpq.PQconnectdb(connection_string.encode("utf-8"))
    if not connection:
        return ""
    try:
        # CONNECTION_OK=0, PGRES_TUPLES_OK=2
        if libpq.PQstatus(connection) != 0:
            return ""
        result = libpq.PQexec(connection, query.encode("utf-8"))
        if not result:
            return ""
        try:
            if libpq.PQresultStatus(result) != 2:
                return ""
            if libpq.PQntuples(result) <= 0:
                return ""
            value = libpq.PQgetvalue(result, 0, 0)
            if not value:
                return ""
            return normalize_secret_token(value.decode("utf-8"))
        finally:
            libpq.PQclear(result)
    finally:
        libpq.PQfinish(connection)


def build_telegram_update(
    *,
    update_id: int,
    principal: str,
    principal_fallback_id: int,
    scope_id: int,
    chat_type: str,
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
            "chat": {"id": scope_id, "type": chat_type},
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


def main() -> int:
    parser = argparse.ArgumentParser(description="Telegram strict-ingress canary for nullalis gateway")
    parser.add_argument("--gateway-base", default="http://127.0.0.1:3000")
    parser.add_argument("--internal-token", required=True, help="X-Internal-Token for user binding API")
    parser.add_argument("--telegram-secret-token", help="X-Telegram-Bot-Api-Secret-Token for webhook calls")
    parser.add_argument(
        "--config-path",
        default=str(pathlib.Path.home() / ".nullalis" / "config.json"),
        help="Config path used for postgres secret auto-resolution when --telegram-secret-token is omitted",
    )
    parser.add_argument("--user-id", required=True)
    parser.add_argument("--account-id", default="default")
    parser.add_argument("--mapped-principal", required=True, help="Principal identity value (username or numeric id)")
    parser.add_argument("--mapped-scope", required=True, help="Scope identity value (telegram chat id)")
    parser.add_argument("--unmapped-principal", required=True, help="Unmapped principal identity value")
    parser.add_argument("--unmapped-scope", required=True, help="Unmapped scope identity value (telegram chat id)")
    parser.add_argument(
        "--unmapped-chat-type",
        choices=["group", "supergroup", "channel", "private"],
        default="group",
        help="Telegram chat type for unmapped fixture; default group avoids direct auto-binding path",
    )
    parser.add_argument("--mapped-from-id", type=int, default=910001, help="Fallback sender id used when mapped principal is username")
    parser.add_argument("--unmapped-from-id", type=int, default=910002, help="Fallback sender id used when unmapped principal is username")
    parser.add_argument("--timeout-secs", type=int, default=30)
    parser.add_argument(
        "--update-id-base",
        type=int,
        default=0,
        help="Optional Telegram update_id base. 0 means auto-generate from current epoch milliseconds.",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    user_id_enc = urllib.parse.quote(args.user_id, safe="")
    binding_url = f"{args.gateway_base}/api/v1/users/{user_id_enc}/channels/telegram/bindings"
    webhook_url = f"{args.gateway_base}/webhook/telegram?user_id={user_id_enc}"
    diagnostics_url = f"{args.gateway_base}/internal/diagnostics?user_id={user_id_enc}"

    telegram_secret_token = args.telegram_secret_token
    if telegram_secret_token:
        telegram_secret_token = normalize_secret_token(telegram_secret_token)
    else:
        telegram_secret_token = resolve_telegram_secret_from_postgres(
            config_path=args.config_path,
            user_id=args.user_id,
            timeout_secs=args.timeout_secs,
        )

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
        },
    )

    diag_before = http_json_request(
        method="GET",
        url=diagnostics_url,
        timeout_secs=args.timeout_secs,
        headers={"X-Internal-Token": args.internal_token},
    )
    strict_before = extract_strict_rejected_metric(diag_before)

    update_id_base = args.update_id_base if args.update_id_base > 0 else int(time.time() * 1000)

    mapped_update = build_telegram_update(
        update_id=update_id_base + 1,
        principal=args.mapped_principal,
        principal_fallback_id=args.mapped_from_id,
        scope_id=int(args.mapped_scope),
        chat_type="private",
        text="strict canary mapped",
    )
    mapped_resp = http_json_request(
        method="POST",
        url=webhook_url,
        timeout_secs=args.timeout_secs,
        headers={
            "Content-Type": "application/json",
            "X-Telegram-Bot-Api-Secret-Token": telegram_secret_token,
        },
        body_obj=mapped_update,
    )

    unmapped_update = build_telegram_update(
        update_id=update_id_base + 2,
        principal=args.unmapped_principal,
        principal_fallback_id=args.unmapped_from_id,
        scope_id=int(args.unmapped_scope),
        chat_type=args.unmapped_chat_type,
        text="strict canary unmapped",
    )
    unmapped_resp = http_json_request(
        method="POST",
        url=webhook_url,
        timeout_secs=args.timeout_secs,
        headers={
            "Content-Type": "application/json",
            "X-Telegram-Bot-Api-Secret-Token": telegram_secret_token,
        },
        body_obj=unmapped_update,
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
    strict_signal_observed = is_strict_reject(unmapped_resp) or (strict_delta is not None and strict_delta > 0)

    summary = {
        "run_started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "gateway_base": args.gateway_base,
        "user_id": args.user_id,
        "account_id": args.account_id,
        "secret_source": "cli_arg" if args.telegram_secret_token else "postgres_auto",
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
            "chat_type": args.unmapped_chat_type,
            "response": unmapped_resp,
            "strict_reject_detected": is_strict_reject(unmapped_resp),
        },
        "strict_observability": {
            "strict_rejected_before": strict_before,
            "strict_rejected_after": strict_after,
            "strict_rejected_delta": strict_delta,
            "strict_identity_reject_observed": strict_signal_observed,
        },
    }

    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(
            f"[telegram-strict-canary] binding_status={binding_resp.get('status_code')} "
            f"mapped_status={mapped_resp.get('status_code')} "
            f"unmapped_status={unmapped_resp.get('status_code')} "
            f"strict_reject={summary['unmapped']['strict_reject_detected']} "
            f"strict_observed={strict_signal_observed}"
        )

    if not binding_resp.get("ok"):
        return 2
    if not summary["mapped"]["accepted"]:
        return 3
    if not strict_signal_observed:
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

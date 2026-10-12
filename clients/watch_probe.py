#!/usr/bin/env python3
"""One-shot secret-free watch probe; prints a decision and never launches an AI.

The agent acknowledges only the captured watch cursor AFTER authenticated sync
and processing succeed. Network failures are errors, never an empty work queue.
"""
import argparse
import http.client
import json
import math
from pathlib import Path
import re
import socket
import ssl
import time
from urllib import error, parse, request

from signal_probe import decision
from transport import ClientError, checkpoint_lock, endpoint, load_state, save_state

MAX_BODY = 2048
COUNTS = ("tasks", "auths", "alerts", "messages")
FIELDS = {"workspaceId", "cursor", *COUNTS}
MEMBER_COUNTS = (*COUNTS, "announcements")
MEMBER_FIELDS = {"workspaceId", "memberId", "cursor", *MEMBER_COUNTS, "revisions"}
MEMBER_PATTERN = re.compile(r"[a-z][a-z0-9_-]{0,47}\Z")
ID_PATTERN = re.compile(r"[A-Za-z0-9_-]{32}\Z")
STATE_KIND = "collab-watch-v1"
MEMBER_STATE_KIND = "collab-member-watch-v1"


class WatchError(ClientError):
    def __init__(self, category, message, state_preserved=True):
        super().__init__(message)
        self.category = category
        self.state_preserved = state_preserved


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def validated_origin(raw, allow_loopback=False):
    if not isinstance(raw, str) or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in raw):
        raise WatchError("config", "Origin contains whitespace or control characters")
    try:
        checked = endpoint(raw, allow_loopback)
        url = parse.urlsplit(checked)
        # Normalize equivalent origins so local scope checks are unambiguous.
        host = url.hostname.lower().encode("idna").decode("ascii")
        if ":" in host:
            host = "[" + host + "]"
        port = url.port
        if port is not None and not 1 <= port <= 65535:
            raise ValueError("Invalid port")
        if "%" in host or "\\" in host:
            raise ValueError("Invalid hostname")
        default_port = 443 if url.scheme == "https" else 80
        return f"{url.scheme}://{host}" + (f":{port}" if port and port != default_port else "")
    except (ClientError, UnicodeError, ValueError) as exc:
        raise WatchError("config", "Provide a valid HTTPS origin; loopback HTTP is test-only") from exc


def validated_id(value, label):
    if not isinstance(value, str) or not ID_PATTERN.fullmatch(value):
        raise WatchError("protocol" if label == "cursor" else "config", f"Invalid {label}")
    return value


def validated_member_id(value):
    if not isinstance(value, str) or not MEMBER_PATTERN.fullmatch(value):
        raise WatchError("config", "Member ID must match [a-z][a-z0-9_-]{0,47}")
    return value


def validated_revisions(value, category="protocol"):
    if not isinstance(value, dict) or set(value) != set(MEMBER_COUNTS):
        raise WatchError(category, "Member revisions must contain exactly the five collection types")
    if any(not isinstance(value[key], str) or not ID_PATTERN.fullmatch(value[key]) for key in MEMBER_COUNTS):
        raise WatchError(category, "Member revisions must be 32-character URL-safe opaque values")
    return value


def _unique_object(pairs):
    output = {}
    for key, value in pairs:
        if key in output:
            raise ValueError("Duplicate JSON field")
        output[key] = value
    return output


def validate_payload(body, workspace_id, member_id=None):
    try:
        value = json.loads(body.decode("utf-8"), object_pairs_hook=_unique_object,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Non-finite JSON value")))
    except (UnicodeError, ValueError) as exc:
        raise WatchError("protocol", "Watch response is not valid bounded JSON") from exc
    fields = FIELDS if member_id is None else MEMBER_FIELDS
    counts = COUNTS if member_id is None else MEMBER_COUNTS
    if not isinstance(value, dict) or set(value) != fields:
        message = ("Watch response must contain only workspaceId, cursor and four counts" if member_id is None
                   else "Member watch response must contain only workspaceId, memberId, cursor, five counts and revisions")
        raise WatchError("protocol", message)
    if value["workspaceId"] != workspace_id:
        raise WatchError("protocol", "Watch response belongs to another workspace")
    if member_id is not None:
        if value["memberId"] != member_id:
            raise WatchError("protocol", "Watch response belongs to another member")
        validated_revisions(value["revisions"])
    validated_id(value["cursor"], "cursor")
    if any(type(value[k]) is not int or not 0 <= value[k] <= 2**63 - 1 for k in counts):
        raise WatchError("protocol", "Watch counts must be nonnegative integers")
    return value


def _remaining_read(response, limit, remaining):
    # urllib exposes no public whole-request deadline. Bound each available
    # socket read by the remaining budget and check elapsed time between reads.
    # DNS resolution and CONNECT/TLS stages can still exceed a wall-clock budget.
    try:
        response.fp.raw._sock.settimeout(remaining)
    except (AttributeError, OSError):
        pass
    reader = getattr(response, "read1", response.read)
    return reader(limit)


def fetch_watch(base, workspace_id, timeout=10.0, *, member_id=None):
    """Exactly one HTTP attempt; uses environment proxy settings and verified TLS."""
    if not isinstance(timeout, (int, float)) or isinstance(timeout, bool) or not math.isfinite(timeout) or not 0 < timeout <= 60:
        raise WatchError("config", "Timeout must be greater than zero and at most 60 seconds")
    query = {"workspace": workspace_id}
    if member_id is not None:
        query["memberId"] = validated_member_id(member_id)
    url = base + "/v1/watch?" + parse.urlencode(query)
    req = request.Request(url, headers={"Accept": "application/json", "Accept-Encoding": "identity",
                                        "Cache-Control": "no-cache", "User-Agent": "CollabDesk-WatchProbe/1"})
    # ProxyHandler() deliberately honors HTTP(S)_PROXY / NO_PROXY. Do not bypass
    # the host's network policy or read any platform credential files.
    opener = request.build_opener(request.ProxyHandler(), NoRedirect(),
                                  request.HTTPSHandler(context=ssl.create_default_context()))
    started = time.monotonic()
    try:
        with opener.open(req, timeout=timeout) as response:
            if response.status != 200:
                raise WatchError("http", f"Watch returned HTTP {response.status}; checkpoint unchanged")
            if response.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
                raise WatchError("protocol", "Watch returned a non-JSON content type")
            if response.headers.get("Content-Encoding", "identity").lower() != "identity":
                raise WatchError("protocol", "Compressed watch response rejected")
            length = response.headers.get("Content-Length")
            if length is not None:
                if not length.isdecimal() or int(length) > MAX_BODY:
                    raise WatchError("protocol", "Watch response exceeds the 2048-byte limit")
            chunks, total = [], 0
            while True:
                remaining = timeout - (time.monotonic() - started)
                if remaining <= 0:
                    raise WatchError("timeout", "Watch request exceeded its elapsed read budget")
                chunk = _remaining_read(response, min(512, MAX_BODY + 1 - total), remaining)
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > MAX_BODY:
                    raise WatchError("protocol", "Watch response exceeds the 2048-byte limit")
            if length is not None and total != int(length):
                raise WatchError("protocol", "Watch response was truncated")
            return validate_payload(b"".join(chunks), workspace_id, member_id)
    except error.HTTPError as exc:
        exc.close()
        if 300 <= exc.code < 400:
            raise WatchError("redirect", "Watch redirect rejected; verify the configured origin") from exc
        raise WatchError("http", f"Watch returned HTTP {exc.code}; no automatic retry") from exc
    except (socket.timeout, TimeoutError) as exc:
        raise WatchError("timeout", "Watch connection or read timed out; no automatic retry") from exc
    except ssl.SSLError as exc:
        raise WatchError("tls", "Watch TLS verification or handshake failed") from exc
    except error.URLError as exc:
        reason = exc.reason
        category = "timeout" if isinstance(reason, (socket.timeout, TimeoutError)) else "tls" if isinstance(reason, ssl.SSLError) else "network"
        raise WatchError(category, "Watch network/proxy connection failed; checkpoint unchanged") from exc
    except (OSError, http.client.HTTPException) as exc:
        raise WatchError("network", "Watch network/proxy connection closed; checkpoint unchanged") from exc


def validate_state(state, base, workspace_id, member_id=None):
    if not state:
        return
    kind = STATE_KIND if member_id is None else MEMBER_STATE_KIND
    if (state.get("kind") != kind or state.get("baseURL") != base or state.get("workspaceId") != workspace_id
            or state.get("memberId") != member_id):
        message = ("Use a separate watch state file for each origin and workspace" if member_id is None
                   else "Use a separate watch state file for each origin, workspace and member scope")
        raise WatchError("state", message)
    for key in ("requested", "acknowledged"):
        value = state.get(key)
        if value is not None and (not isinstance(value, str) or not ID_PATTERN.fullmatch(value)):
            raise WatchError("state", "Invalid saved watch cursor; preserve the state for inspection")
    requested_at = state.get("requestedAt", 0)
    if type(requested_at) not in (int, float) or not math.isfinite(requested_at):
        raise WatchError("state", "Invalid saved watch request time")
    if member_id is not None:
        # Every captured or acknowledged cursor is inseparable from the exact
        # revision snapshot that triggered it. Partial checkpoints are errors,
        # never a reason to silently recapture/reset an outstanding wake.
        if "requestedAt" not in state:
            raise WatchError("state", "Member checkpoint is missing its captured request time")
        for cursor_key, revisions_key in (("requested", "requestedRevisions"),
                                          ("acknowledged", "acknowledgedRevisions")):
            if cursor_key not in state or revisions_key not in state:
                raise WatchError("state", "Member checkpoint is missing a cursor revision snapshot")
            if state[cursor_key] is None:
                if state[revisions_key] is not None:
                    raise WatchError("state", "Member checkpoint has revisions without their cursor")
            else:
                validated_revisions(state[revisions_key], "state")


def probe(base_url, workspace_id, path, *, ack=None, dry_run=False, allow_loopback=False,
          timeout=10.0, cooldown=600, now=None, member_id=None):
    base = validated_origin(base_url, allow_loopback)
    validated_id(workspace_id, "workspace")
    if member_id is not None:
        validated_member_id(member_id)
    if type(cooldown) not in (int, float) or not math.isfinite(cooldown) or not 0 <= cooldown <= 86400:
        raise WatchError("config", "Cooldown must be between 0 and 86400 seconds")
    path = Path(path).expanduser()
    try:
        with checkpoint_lock(path):
            old = load_state(path)
            validate_state(old, base, workspace_id, member_id)
            if ack is not None:
                validated_id(ack, "cursor")
                if old.get("requested") != ack:
                    raise WatchError("state", "Captured cursor is not the currently requested wake; stale ack rejected")
                new = {**old, "acknowledged": ack, "requested": None}
                result = {"ok": True, "wake": False, "reason": "acknowledged", "cursor": ack}
                if member_id is not None:
                    # The caller supplies ONLY its captured cursor after its
                    # authenticated processing succeeds. Ack stays local and
                    # commits the saved capture, not any later poll's revisions.
                    new.update(acknowledgedRevisions=dict(old["requestedRevisions"]), requestedRevisions=None)
                    result["changeTypes"] = []
            else:
                payload = (fetch_watch(base, workspace_id, timeout) if member_id is None
                           else fetch_watch(base, workspace_id, timeout, member_id=member_id))
                if member_id is not None:
                    for cursor_key, revisions_key in (("requested", "requestedRevisions"),
                                                      ("acknowledged", "acknowledgedRevisions")):
                        if old.get(cursor_key) == payload["cursor"] and old.get(revisions_key) != payload["revisions"]:
                            raise WatchError("protocol", "Member cursor conflicts with its saved revision snapshot")
                current_time = time.time() if now is None else now
                if member_id is not None and (type(current_time) not in (int, float) or not math.isfinite(current_time)):
                    raise WatchError("config", "Member watch request time must be finite")
                new, result = decision(old, payload["cursor"], current_time, cooldown)
                if result.get("wake"):
                    initial = not old if member_id is None else old.get("acknowledgedRevisions") is None
                    result["reason"] = "initial-sync" if initial else "changed"
                if member_id is not None:
                    acknowledged = old.get("acknowledgedRevisions")
                    result["changeTypes"] = [key for key in MEMBER_COUNTS
                                             if acknowledged is None or acknowledged[key] != payload["revisions"][key]]
                    new.setdefault("acknowledged", None)
                    new.setdefault("acknowledgedRevisions", None)
                    if result.get("wake"):
                        new["requestedRevisions"] = dict(payload["revisions"])
                # revision is the captured public watch cursor, NOT a Bearer
                # incremental cursor for /v1/updates.
                result.pop("revision", None)
                result = {"ok": True, **result, "cursor": payload["cursor"],
                          "counts": {key: payload[key] for key in (COUNTS if member_id is None else MEMBER_COUNTS)}}
            new.update(kind=STATE_KIND if member_id is None else MEMBER_STATE_KIND, baseURL=base, workspaceId=workspace_id)
            if member_id is not None:
                new["memberId"] = member_id
                result["memberId"] = member_id
            if not dry_run:
                save_state(path, new)
            return {**result, "workspaceId": workspace_id, "dryRun": dry_run}
    except WatchError:
        raise
    except ClientError as exc:
        raise WatchError("state", str(exc)) from exc
    except OSError as exc:
        raise WatchError("state", "Watch state read/write failed; inspect the private checkpoint before acknowledging", state_preserved=None) from exc


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--state", default="~/platform/watch.json")
    parser.add_argument("--member-id", help="Member ID for secret-free member-scoped watch; use a separate checkpoint per member")
    parser.add_argument("--ack", help="Captured watch cursor to acknowledge AFTER successful authenticated processing; no network request")
    parser.add_argument("--timeout", type=float, default=10.0, help="Socket timeout and best-effort read budget in seconds; default 10")
    parser.add_argument("--cooldown", type=float, default=600, help="Suppress repeated agent wakes while awaiting acknowledgement; default 600 seconds")
    parser.add_argument("--dry-run", action="store_true", help="Fetch and print a decision without writing the checkpoint")
    parser.add_argument("--allow-loopback", action="store_true", help="Permit local HTTP fixtures only")
    args = parser.parse_args(argv)
    try:
        print(json.dumps(probe(args.base_url, args.workspace, args.state, ack=args.ack, dry_run=args.dry_run,
                               allow_loopback=args.allow_loopback, timeout=args.timeout, cooldown=args.cooldown,
                               member_id=args.member_id),
                         ensure_ascii=False, separators=(",", ":")))
        return 0
    except WatchError as exc:
        print(json.dumps({"ok": False, "wake": False, "statePreserved": exc.state_preserved,
                          "error": {"category": exc.category, "message": str(exc)}}, ensure_ascii=False, separators=(",", ":")))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

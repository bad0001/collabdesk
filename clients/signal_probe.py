#!/usr/bin/env python3
"""Optional secret-free hook probe; disabled on the server by default.

Outputs a wake decision, not an agent launch. The hook host must wire its own
wake contract. A successful agent sync explicitly acknowledges the CAPTURED
revision, never a newly-fetched one. Until then retry after the cooldown.
"""
import argparse
import json
from pathlib import Path
import re
import time
from transport import ClientError, checkpoint_lock, endpoint, get_json, load_state, save_state


def decision(state, revision, now, cooldown=600):
    if state.get("acknowledged") == revision:
        return {**state}, {"wake": False, "reason": "unchanged"}
    elapsed = now - state.get("requestedAt", -cooldown)
    if state.get("requested") and 0 <= elapsed < cooldown:
        return {**state}, {"wake": False, "reason": "awaiting-agent"}
    return {**state, "requested": revision, "requestedAt": now}, {"wake": True, "revision": revision}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--state", default="~/platform/signal.json")
    parser.add_argument("--ack", help="Captured revision to acknowledge AFTER successful authenticated sync/processing")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--allow-loopback", action="store_true")
    args = parser.parse_args()
    try:
        base = endpoint(args.base_url, args.allow_loopback)
        path = Path(args.state).expanduser()
        with checkpoint_lock(path):
            old = load_state(path)
            if old and old.get("baseURL") != base:
                raise ClientError("Use a separate signal file per origin")
            if args.ack:
                if not re.fullmatch(r"[A-Za-z0-9_-]{32}", args.ack):
                    raise ClientError("Invalid signal revision")
                # An older invocation must not overwrite a newer acknowledgement.
                if old.get("requested") != args.ack:
                    raise ClientError("Revision is not the currently requested wake")
                new, result = {**old, "acknowledged": args.ack, "requested": None}, {"ok": True, "acknowledged": True}
            else:
                status, response, _ = get_json(base, "/v1/update-signal")  # No token or secret lookup.
                if status != 200 or not isinstance(response, dict) or not re.fullmatch(r"[A-Za-z0-9_-]{32}", str(response.get("revision", ""))):
                    raise ClientError(f"Signal unavailable (HTTP {status}); do not interpret this as no work")
                new, result = decision(old, response["revision"], time.time())
            new["baseURL"] = base
            if not args.dry_run:
                save_state(path, new)
            print(json.dumps({**result, "dryRun": args.dry_run}))
    except (ClientError, OSError) as error:
        print(json.dumps({"wake": False, "error": str(error) if isinstance(error, ClientError) else "Signal state write failed"}))
        raise SystemExit(2)


if __name__ == "__main__":
    main()

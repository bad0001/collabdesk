#!/usr/bin/env python3
"""Authenticated, one-shot incremental pull. Secrets come from the agent's vault environment.

This only caches facts; a saved cursor does NOT mean a task was read/completed.
Run outside the secret-free hook. Nothing here launches an agent or a cron job.
"""
import argparse
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import urlencode
from transport import ClientError, checkpoint_lock, endpoint, get_json, load_state, save_state

COLLECTIONS = {"tasks", "events", "members", "announcements", "messages", "alerts", "alertEvents", "memberEvents",
               "authorizations", "authorizationEvents", "libraries", "records", "recordEvents", "rules", "userRequests", "userRequestEvents", "codeRequests"}


def apply_response(old, response, base, expected_member=None, expected_workspace=None):
    if not isinstance(response, dict) or response.get("syncVersion") != 1 or response.get("schemaVersion") != 2:
        raise ClientError("Unsupported response version; checkpoint unchanged")
    member = response.get("memberId")
    if not isinstance(member, str) or not member:
        raise ClientError("Missing member identity")
    workspace = response.get("workspaceId")
    if not isinstance(workspace, str) or not workspace:
        raise ClientError("Missing workspace identity; checkpoint unchanged")
    if (expected_member is not None and member != expected_member) or (expected_workspace is not None and workspace != expected_workspace):
        raise ClientError("Verified identity or workspace changed; checkpoint unchanged")
    if old and (old.get("baseURL") != base or old.get("memberId") != member):
        raise ClientError("Checkpoint belongs to a different origin/member; use a separate file")
    if old and "workspaceId" in old:
        if not isinstance(old["workspaceId"], str) or not old["workspaceId"]:
            raise ClientError("Invalid checkpoint workspace identity; preserve it and inspect locally")
        if old["workspaceId"] != workspace:
            raise ClientError("Checkpoint belongs to a different workspace; preserve it and use a separate file")
    cursor = response.get("new_cursor")
    if not isinstance(cursor, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43}", cursor):
        raise ClientError("Missing or invalid cursor")
    if type(response.get("reset")) is not bool or not isinstance(response.get("items"), list):
        raise ClientError("Invalid incremental envelope")
    if not response["reset"] and (not old or "workspaceId" not in old):
        raise ClientError("A new or legacy checkpoint requires a full reset; checkpoint unchanged")
    if not isinstance(old.get("entities", {}), dict):
        raise ClientError("Invalid checkpoint entities; checkpoint unchanged")
    entities = {} if response["reset"] else dict(old.get("entities", {}))
    for item in response["items"]:
        if not isinstance(item, dict) or item.get("collection") not in COLLECTIONS or not isinstance(item.get("id"), str):
            raise ClientError("Invalid change item")
        key = item["collection"] + ":" + item["id"]
        if item.get("op") == "delete":
            entities.pop(key, None)
        elif item.get("op") == "upsert" and isinstance(item.get("value"), dict):
            entities[key] = item["value"]
        else:
            raise ClientError("Unknown change operation")
    return {"baseURL": base, "memberId": member, "workspaceId": workspace, "cursor": cursor, "entities": entities}


def preserve_legacy_checkpoint(path):
    """Keep the exact pre-identity cache privately, without replacing any backup.

    A full snapshot may no longer expose every historical entity in this old
    cache. Preserving it prevents an upgrade from silently discarding that
    record. Neither this backup nor the new cursor acknowledges task processing.
    Caller holds the checkpoint lock and has already validated the full reset.
    """
    original = path.read_bytes()
    backup = path.with_name(path.name + ".pre-workspace-v1")
    if backup.exists():
        if backup.is_symlink() or backup.read_bytes() != original:
            raise ClientError("Legacy checkpoint backup conflict; preserve it and use a separate state file")
        return
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".collab-legacy-")
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(original)
            stream.flush(); os.fsync(stream.fileno())
        # link is atomic and refuses to overwrite an existing archive.
        os.link(temporary, backup)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        Path(temporary).unlink(missing_ok=True)


def pull(base, token, path, dry_run=False, heartbeat=False, expected_member=None, expected_workspace=None):
    with checkpoint_lock(path):
        old = load_state(path)
        if old and old.get("baseURL") != base:
            raise ClientError("Use a separate checkpoint for each origin")
        legacy = bool(old) and "workspaceId" not in old
        # Old cursors have no database identity: perform one full sync rather
        # than merging a delta into an unbound cache (including in dry-run).
        query = {"cursor": old["cursor"]} if old.get("cursor") and not legacy else {}
        if heartbeat and not dry_run:
            query["heartbeat"] = "1"
        status, response, _ = get_json(base, "/v1/updates?" + urlencode(query), token)
        if status == 410:
            query.pop("cursor", None)
            status, response, _ = get_json(base, "/v1/updates?" + urlencode(query), token)
        if status != 200:
            raise ClientError(f"HTTP {status}; checkpoint unchanged")
        new = apply_response(old, response, base, expected_member, expected_workspace)
        if not dry_run:
            if legacy:
                preserve_legacy_checkpoint(path)
            save_state(path, new)
        # Log counts only, not credentials, cursor, identities or private bodies.
        return {"ok": True, "reset": response["reset"], "changes": len(response["items"]),
                "cachedEntities": len(new["entities"]), "saved": not dry_run,
                "checkpointMigrated": legacy and not dry_run}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--state", default="~/platform/workspace.json")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--heartbeat", action="store_true", help="Record a real authenticated agent visit; not hook liveness")
    parser.add_argument("--allow-loopback", action="store_true")
    args = parser.parse_args()
    try:
        base = endpoint(args.base_url, args.allow_loopback)
        token = os.environ.get("COLLAB_TOKEN", "")
        if not token:
            raise ClientError("Inject COLLAB_TOKEN from the vault in the authenticated agent context")
        print(json.dumps(pull(base, token, Path(args.state).expanduser(), args.dry_run, args.heartbeat)))
    except (ClientError, OSError) as error:
        print(json.dumps({"ok": False, "error": str(error) if isinstance(error, ClientError) else "Local checkpoint write failed"}))
        raise SystemExit(2)


if __name__ == "__main__":
    main()

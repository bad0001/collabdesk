"""One-shot REST helpers; no model runtime, credential storage or scheduler."""
from contextlib import contextmanager
from email.utils import parsedate_to_datetime
import fcntl
import http.client
import json
import os
from pathlib import Path
import random
import tempfile
import time
from urllib.parse import urlsplit


class ClientError(Exception):
    pass


def endpoint(raw, allow_loopback=False):
    url = urlsplit(raw)
    if url.username or url.password or url.query or url.fragment or url.path not in {"", "/"} or not url.hostname:
        raise ClientError("Provide an origin URL only; no credentials, path or query")
    local = url.scheme == "http" and url.hostname in {"127.0.0.1", "localhost", "::1"} and allow_loopback
    if url.scheme != "https" and not local:
        raise ClientError("Use HTTPS; loopback HTTP requires --allow-loopback")
    try:
        _ = url.port
    except ValueError as error:
        raise ClientError("Invalid port") from error
    return raw.rstrip("/")


def get_json(base_url, path, token=None, headers=None):
    url = urlsplit(base_url)
    hs = {"Accept": "application/json", **(headers or {})}
    if token:
        if any(c in token for c in "\r\n") or len(token) > 256:
            raise ClientError("Invalid credential format")
        hs["Authorization"] = "Bearer " + token
    # http.client never follows redirects; credentials stay on this origin.
    for attempt in range(3):
        connection = (http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection)(url.hostname, url.port, timeout=15)
        delay = 2 ** attempt + random.random()
        try:
            connection.request("GET", path, headers=hs)
            response = connection.getresponse()
            status = response.status
            body = response.read(16 * 1024 * 1024 + 1)
            if len(body) > 16 * 1024 * 1024:
                raise ClientError("Response too large; checkpoint unchanged")
            if status == 429 or status >= 500:
                retry = response.getheader("Retry-After", "")
                retry_seconds = 0.0
                if retry.isdecimal():
                    retry_seconds = float(retry)
                elif retry:
                    try:
                        retry_seconds = max(0, parsedate_to_datetime(retry).timestamp() - time.time())
                    except (ValueError, TypeError, OverflowError):
                        pass
                if retry_seconds > 60:
                    raise ClientError(f"HTTP {status}; server asks for a later retry, checkpoint unchanged")
                delay = max(delay, retry_seconds)
                if attempt == 2:
                    raise ClientError(f"HTTP {status}; retry later, checkpoint unchanged")
            else:
                if 300 <= status < 400 and status != 304:
                    raise ClientError("Redirect rejected; check the configured origin")
                try:
                    value = json.loads(body) if body else None
                except (ValueError, UnicodeError) as error:
                    raise ClientError("Expected JSON; checkpoint unchanged") from error
                return status, value, dict(response.getheaders())
        except (OSError, http.client.HTTPException) as error:
            if attempt == 2:
                raise ClientError("Network request failed; checkpoint unchanged") from error
        finally:
            connection.close()
        time.sleep(delay)


def load_state(path):
    try:
        value = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    except (ValueError, OSError) as error:
        raise ClientError("Checkpoint unreadable; preserve it and inspect locally") from error
    if not isinstance(value, dict):
        raise ClientError("Invalid checkpoint")
    return value


def save_state(path, value):
    """Cursor AND entities commit in the same private atomic file."""
    path = Path(path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".collab-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream, ensure_ascii=False, separators=(",", ":"))
            stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        Path(temporary).unlink(missing_ok=True)


@contextmanager
def checkpoint_lock(path):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(str(path) + ".lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        # Parallel invocations wait here; each then reloads the newest cursor.
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)

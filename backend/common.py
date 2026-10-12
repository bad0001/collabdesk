"""Shared API validation; actor identities and timestamps are never client inputs."""
from datetime import datetime, timezone
from urllib.parse import urlsplit


class APIError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def field(data, key, default="", limit=4000, required=False):
    value = data.get(key, default)
    if not isinstance(value, str) or len(value) > limit or (required and not value.strip()):
        raise APIError(422, f"字段 {key} 格式或长度有误")
    return value.strip()


def choice(data, key, options, default):
    value = field(data, key, default, 80)
    if value not in options:
        raise APIError(422, f"字段 {key} 选项有误")
    return value


def link(data, key):
    value = field(data, key, limit=2000)
    if value:
        try:
            parsed = urlsplit(value)
            valid = parsed.scheme in {"https", "http"} and parsed.hostname and not parsed.username and not parsed.password
        except ValueError:
            valid = False
        if not valid:
            raise APIError(422, f"字段 {key} 请填写 HTTP(S) 链接")
    return value


def parse_time(value):
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timezone required")
    return parsed.astimezone(timezone.utc)


def timestamp(date):
    return date.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def seconds_since(stamp, earlier):
    return max(0, (parse_time(stamp) - parse_time(earlier)).total_seconds())

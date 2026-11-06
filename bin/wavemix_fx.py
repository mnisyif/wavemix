"""Manifest-driven microphone effect chain for Wavemix."""
from __future__ import annotations

import re

WAVEMIX_VERSION = "1.1.0"

_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")


def parse_version(text: str) -> tuple[int, int, int] | None:
  value = str(text or "").strip()
  if not _VERSION_RE.match(value):
    return None
  return tuple(int(part) for part in value.split("."))


def version_at_least(current: str, minimum: str) -> bool:
  cur = parse_version(current)
  want = parse_version(minimum)
  if cur is None or want is None:
    return False
  return cur >= want

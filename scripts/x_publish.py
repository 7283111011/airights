#!/usr/bin/env python3
"""
x_publish.py
─────────────
Publishes new AI Alerts entries to X (Twitter) as @AIRightsUK.

Used by scripts/ai-watch-scan.py after it has confirmed genuinely new entries.

Behaviour:
  - Reads the @mention dictionary from scripts/x_mention_dict.json.
  - For each new entry: builds a 280-char-or-less tweet, resolves @mentions
    from the dictionary, and posts via the X API v2.
  - Idempotency: tracks posted entry titles in scripts/x_posted.json so the
    same entry is never posted twice (even if the scanner re-runs).
  - Dry-run mode: set X_DRY_RUN=1 to print formatted tweets without posting.
  - Failure-tolerant: an X API failure does not abort the scanner run.

Required environment variables (set as GitHub Actions secrets):
  X_CONSUMER_KEY                 (consumer key)
  X_CONSUMER_KEY_SECRET              (consumer secret)
  X_ACCESS_TOKEN
  X_ACCESS_TOKEN_SECRET

Optional:
  X_DRY_RUN=1               Skip the actual POST; log what would be sent.

Free-tier X API allows ~17 tweets/day and 500/month. The AI Alerts cadence
sits comfortably under that.
"""

import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# requests + requests-oauthlib are added to the workflow's pip install line.
try:
    import requests
    from requests_oauthlib import OAuth1
except ImportError:
    requests = None  # handled at runtime; allows local import without deps installed

# ──────────────────────────────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).resolve().parent
DICT_PATH = SCRIPT_DIR / "x_mention_dict.json"
POSTED_LOG_PATH = SCRIPT_DIR / "x_posted.json"

X_POST_URL = "https://api.x.com/2/tweets"
TWEET_CHAR_LIMIT = 280

# Header marker for posts so they're recognisable as scanner-generated
TWEET_PREFIX = "🔎 NEW AI ALERT"


# ──────────────────────────────────────────────────────────────────────
# Public entry point
# ──────────────────────────────────────────────────────────────────────

def publish_entries(new_entries, ai_alerts_url="https://airights.org.uk/ai-alerts.html"):
    """
    Publish a list of new AI Alerts entries to X.

    Args:
        new_entries: list of dicts as returned by Gemini in the scanner
            (keys: title, buyer, supplier, body, sector, sources, ...).
        ai_alerts_url: URL appended to each tweet pointing back to the register.

    Returns:
        dict with keys: posted (int), skipped (int), failed (int), tweet_ids (list).
    """
    result = {"posted": 0, "skipped": 0, "failed": 0, "tweet_ids": []}

    if not new_entries:
        print("[x_publish] No new entries to publish.")
        return result

    dry_run = os.environ.get("X_DRY_RUN") in ("1", "true", "yes")
    mention_dict = load_mention_dict()
    posted_log = load_posted_log()

    creds = None
    if not dry_run:
        creds = load_credentials()
        if creds is None:
            print("[x_publish] X credentials missing. Skipping X publishing for this run.")
            return result

    for entry in new_entries:
        title = entry.get("title", "").strip()
        if not title:
            continue

        # Idempotency: skip if we've already posted this title
        if title in posted_log["titles"]:
            print(f"[x_publish] SKIP (already posted): {title}")
            result["skipped"] += 1
            continue

        mentions = resolve_mentions(entry, mention_dict)
        tweet = format_tweet(entry, mentions, ai_alerts_url)

        print(f"[x_publish] {'DRY-RUN' if dry_run else 'POST'} ({len(tweet)} chars):")
        print(f"    {tweet}")

        if dry_run:
            result["posted"] += 1
            continue

        tweet_id = post_tweet(tweet, creds)
        if tweet_id:
            result["posted"] += 1
            result["tweet_ids"].append(tweet_id)
            posted_log["titles"].append(title)
            posted_log["log"].append({
                "title": title,
                "tweet_id": tweet_id,
                "posted_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            })
            save_posted_log(posted_log)
            # X free tier: simple inter-post pacing
            time.sleep(2)
        else:
            result["failed"] += 1

    print(f"[x_publish] Summary: {result}")
    return result


# ──────────────────────────────────────────────────────────────────────
# Tweet formatting
# ──────────────────────────────────────────────────────────────────────

def format_tweet(entry, mentions, ai_alerts_url):
    """
    Build a tweet that fits within 280 chars. Hard cap, never overflows.

    Layout (priority order, trimmed from middle if needed):
      🔎 NEW AI ALERT
      [Buyer] · [Supplier]
      [Body, truncated]
      [Value line if any]
      [Mentions]
      [URL]
    """
    buyer = entry.get("buyer", "").strip()
    supplier = entry.get("supplier", "").strip()
    body = entry.get("body", "").strip()
    facts = entry.get("facts", [])

    # Value
    value_str = ""
    for f in facts:
        if f.get("label", "").lower().startswith("contract value") or \
           f.get("label", "").lower() == "value":
            v = f.get("value", "").strip()
            if v and v.lower() not in ("not disclosed", "undisclosed", "n/a"):
                value_str = f"Value: {v}"
                break

    # Build candidate tweet
    header = TWEET_PREFIX
    org_line = " · ".join(x for x in [buyer, supplier] if x)
    mention_line = " ".join(mentions) if mentions else ""

    # Compute fixed-length parts first
    fixed_parts = []
    if header:
        fixed_parts.append(header)
    if org_line:
        fixed_parts.append(org_line)
    if value_str:
        fixed_parts.append(value_str)
    if mention_line:
        fixed_parts.append(mention_line)
    fixed_parts.append(ai_alerts_url)

    fixed_text = "\n\n".join(fixed_parts)
    fixed_len = len(fixed_text)

    # First sentence of body (often most informative)
    first_sentence = re.split(r"(?<=[.!?])\s", body, maxsplit=1)[0] if body else ""

    # Reserve space for body between org_line and value_str
    available = TWEET_CHAR_LIMIT - fixed_len - len("\n\n")  # for the body separator
    body_to_use = ""
    if first_sentence and available > 30:
        if len(first_sentence) <= available:
            body_to_use = first_sentence
        else:
            body_to_use = first_sentence[:available - 1].rsplit(" ", 1)[0] + "…"

    # Reassemble in proper order
    out_parts = [header]
    if org_line:
        out_parts.append(org_line)
    if body_to_use:
        out_parts.append(body_to_use)
    if value_str:
        out_parts.append(value_str)
    if mention_line:
        out_parts.append(mention_line)
    out_parts.append(ai_alerts_url)

    tweet = "\n\n".join(out_parts)

    # Hard safety: enforce 280 char ceiling
    if len(tweet) > TWEET_CHAR_LIMIT:
        # Drop body line if still over
        out_parts = [p for p in out_parts if p != body_to_use]
        tweet = "\n\n".join(out_parts)
    if len(tweet) > TWEET_CHAR_LIMIT:
        # Last-resort: trim mentions
        out_parts = [p for p in out_parts if p != mention_line]
        tweet = "\n\n".join(out_parts)
    if len(tweet) > TWEET_CHAR_LIMIT:
        tweet = tweet[:TWEET_CHAR_LIMIT - 1] + "…"

    return tweet


# ──────────────────────────────────────────────────────────────────────
# @mention resolution
# ──────────────────────────────────────────────────────────────────────

def resolve_mentions(entry, mention_dict):
    """
    Return a deduplicated list of @handles matching anything in the entry
    that appears in the dictionary.

    Search fields: title, buyer, supplier, body, body_text of facts.
    Matching is case-insensitive substring; longer dict keys win to avoid
    matching e.g. 'NHS' inside 'NHS Supply Chain' twice.
    """
    text_blob = " ".join([
        entry.get("title", ""),
        entry.get("buyer", ""),
        entry.get("supplier", ""),
        entry.get("body", ""),
        " ".join(f.get("value", "") for f in entry.get("facts", [])),
    ]).lower()

    handles_seen = set()
    matches = []

    # Flatten all dictionary keys, sorted longest-first
    pairs = []
    for category in ("buyers", "regulators", "suppliers"):
        for key, handle in mention_dict.get(category, {}).items():
            if not key or not handle:
                continue
            pairs.append((key, handle))
    pairs.sort(key=lambda kv: len(kv[0]), reverse=True)

    consumed_spans = []  # avoid double-matching overlapping keys

    for key, handle in pairs:
        kl = key.lower()
        idx = text_blob.find(kl)
        if idx == -1:
            continue
        span = (idx, idx + len(kl))
        # Skip if overlaps with an already-consumed span (longer match wins)
        if any(span[0] < cs[1] and span[1] > cs[0] for cs in consumed_spans):
            continue
        consumed_spans.append(span)
        if handle.lower() in handles_seen:
            continue
        handles_seen.add(handle.lower())
        matches.append(handle)

    return matches


# ──────────────────────────────────────────────────────────────────────
# X API posting (OAuth 1.0a User Context)
# ──────────────────────────────────────────────────────────────────────

def load_credentials():
    """Load X API credentials from environment. Return None if any missing."""
    keys = ("X_CONSUMER_KEY", "X_CONSUMER_KEY_SECRET", "X_ACCESS_TOKEN", "X_ACCESS_TOKEN_SECRET")
    creds = {k: os.environ.get(k, "").strip() for k in keys}
    if not all(creds.values()):
        missing = [k for k, v in creds.items() if not v]
        print(f"[x_publish] Missing X credentials: {missing}")
        return None
    return creds


def post_tweet(text, creds):
    """
    POST text to X. Returns tweet ID on success, None on failure.

    OAuth 1.0a User Context required for posting under @AIRightsUK.
    """
    if requests is None:
        print("[x_publish] requests / requests_oauthlib not installed. Skipping post.")
        return None

    auth = OAuth1(
        creds["X_CONSUMER_KEY"],
        creds["X_CONSUMER_KEY_SECRET"],
        creds["X_ACCESS_TOKEN"],
        creds["X_ACCESS_TOKEN_SECRET"],
    )
    payload = {"text": text}

    try:
        r = requests.post(X_POST_URL, auth=auth, json=payload, timeout=20)
    except Exception as e:
        print(f"[x_publish] Network error posting tweet: {e}")
        return None

    if r.status_code in (200, 201):
        try:
            data = r.json()
            tweet_id = data.get("data", {}).get("id")
            print(f"[x_publish] Posted tweet id={tweet_id}")
            return tweet_id
        except Exception:
            print(f"[x_publish] Posted but could not parse response: {r.text[:200]}")
            return "unknown"
    else:
        print(f"[x_publish] X API error {r.status_code}: {r.text[:400]}")
        return None


# ──────────────────────────────────────────────────────────────────────
# State files
# ──────────────────────────────────────────────────────────────────────

def load_mention_dict():
    if not DICT_PATH.exists():
        print(f"[x_publish] Mention dictionary not found at {DICT_PATH}")
        return {}
    with open(DICT_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def load_posted_log():
    if POSTED_LOG_PATH.exists():
        try:
            with open(POSTED_LOG_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
                # backwards-compat: ensure both keys exist
                data.setdefault("titles", [])
                data.setdefault("log", [])
                return data
        except Exception:
            pass
    return {"titles": [], "log": []}


def save_posted_log(data):
    with open(POSTED_LOG_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


# ──────────────────────────────────────────────────────────────────────
# CLI entry point (manual dry-run testing)
# ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    # Allows: X_DRY_RUN=1 python scripts/x_publish.py
    # Reads a JSON list of entries from stdin and dry-runs the tweets.
    if not sys.stdin.isatty():
        try:
            entries = json.load(sys.stdin)
        except Exception as e:
            print(f"Failed to parse stdin JSON: {e}")
            sys.exit(1)
    else:
        # Self-test with a fake entry
        entries = [{
            "title": "Sample: NHS England partnership with Palantir",
            "buyer": "NHS England",
            "supplier": "Palantir Technologies",
            "body": "NHS England and Palantir have entered a five-year agreement for the Federated Data Platform, an integration layer linking trust-level data sources. The agreement is reported to be worth up to £330 million.",
            "facts": [{"label": "Contract value", "value": "Up to £330m"}],
            "sector": "health",
        }]

    os.environ.setdefault("X_DRY_RUN", "1")
    publish_entries(entries)

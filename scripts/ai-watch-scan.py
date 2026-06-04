#!/usr/bin/env python3
"""
AI Watch daily scanner — Gemini 2.5 Flash (free tier) + Google Search grounding.
Scans for new UK public-sector AI procurement, inserts entries into ai-watch.html.
"""

import json
import re
import os
import sys
import time
from datetime import datetime, timezone

from google import genai
from google.genai.types import Tool, GenerateContentConfig, GoogleSearch

# ---------------------------------------------------------------------------
# 1. Read current page and extract existing entry titles
# ---------------------------------------------------------------------------

HTML_PATH = "ai-alerts.html"

if not os.path.exists(HTML_PATH):
    print(f"ERROR: {HTML_PATH} not found in repo root.")
    sys.exit(1)

html = open(HTML_PATH, encoding="utf-8").read()

existing_titles = re.findall(r'<h2 class="entry-h">(.+?)</h2>', html)
existing_titles_lower = [t.lower().strip() for t in existing_titles]
entry_count = len(existing_titles)

print(f"Found {entry_count} existing entries:")
for t in existing_titles:
    print(f"  - {t}")

# ---------------------------------------------------------------------------
# 2. Build the prompt
# ---------------------------------------------------------------------------

EXISTING_LIST = "\n".join(f"  {i+1}. {t}" for i, t in enumerate(existing_titles))
TODAY = datetime.now(timezone.utc).strftime("%-d %B %Y")

PROMPT = f"""You are a researcher for FAIR (Foundation for Artificial Intelligence Rights).

Your task: search for NEW UK public-sector AI contracts, partnerships, MoUs, pilots,
or procurement agreements that are NOT already on the AI Watch register.

## Entries already on the register (do NOT duplicate these):
{EXISTING_LIST}

## What counts as a new entry:
- A UK public body (NHS, government department, police force, council, court service,
  regulator, or arms-length body) has entered into a contract, MoU, partnership, or
  pilot involving artificial intelligence or machine learning.
- There is at least one published, linkable source (Contracts Finder, GOV.UK,
  Hansard, parliamentary written answer, departmental press release, or credible
  news outlet like PublicTechnology, The Register, Computer Weekly, or BBC).
- It is NOT already in the list above. Check carefully — some entries have long titles.
- It is NOT merely a private-sector AI deal, a think-tank report, or a policy
  announcement without a specific procurement or agreement.
- It must be a REAL agreement you found in search results with a REAL source URL.

## Search strategy:
Please search broadly for recent UK public-sector AI procurement. Include searches like:
- UK government AI contract 2026
- UK public sector AI procurement 2026
- NHS AI contract 2026
- UK police AI technology 2026
- UK council AI procurement 2026
- UK ministry AI pilot 2026
- Contracts Finder artificial intelligence
- GOV.UK artificial intelligence partnership
- UK government AI announcement {TODAY}

## Response format:
Respond with ONLY a JSON object. No markdown fences, no preamble, no explanation.

{{
  "new_entries": [
    {{
      "title": "Short descriptive title",
      "date_string": "The date the CONTRACT was signed or the announcement was originally made by the UK public body itself. NOT the publication date of any secondary news article or roundup. Format: e.g. March 2026 or 15 April 2026. If you only see a roundup or commentary article, use the date of the underlying announcement, not the article's date.",
      "sector": "health|justice|policing|welfare|government|immigration|tax|safety|education|defence|local",
      "status": "live|pilot|mou|review",
      "status_label": "e.g. Live or Pilot or MoU - voluntary",
      "buyer": "Name of the UK public body",
      "supplier": "Name of the supplier or system",
      "body": "2-4 factual sentences. No opinion. Use 'not disclosed' where values are unknown. Use 'contested' where disputed. No adjectives like controversial or landmark.",
      "facts": [
        {{"label": "Contract value", "value": "£X or Not disclosed"}},
        {{"label": "Term", "value": "X years"}},
        {{"label": "Scope", "value": "description"}}
      ],
      "sources": [
        {{"label": "Source name, date", "url": "https://full-real-url-you-found"}},
        {{"label": "Source name", "url": "https://full-real-url-you-found"}}
      ]
    }}
  ],
  "updates_to_existing": [
    {{
      "existing_title": "Title of the existing entry this updates",
      "summary": "Brief description of what changed",
      "source_url": "https://..."
    }}
  ],
  "scan_summary": "One sentence summary of what you found or did not find."
}}

If you find NO new entries, return exactly:
{{"new_entries": [], "updates_to_existing": [], "scan_summary": "No new entries found."}}

CRITICAL RULES:
- NEVER fabricate an entry. Every entry MUST come from a real source you found in search.
- NEVER include a source URL unless you actually found it in search results.
- NEVER editorialize. No "significant", "controversial", "landmark". Just facts.
- If uncertain, OMIT the entry. The register's credibility depends on accuracy.
- Only UK public sector. Not private companies buying AI for themselves.
- Every entry needs at least one real, working source URL from your search results.
"""

# ---------------------------------------------------------------------------
# 3. Call Gemini API with Google Search grounding
# ---------------------------------------------------------------------------

api_key = os.environ.get("GEMINI_API_KEY")
if not api_key:
    print("ERROR: GEMINI_API_KEY not set.")
    sys.exit(1)

client = genai.Client(api_key=api_key)
google_search_tool = Tool(google_search=GoogleSearch())

print("\nCalling Gemini 2.5 Flash with Google Search grounding...")

# Retry with exponential backoff on transient errors (503, 429, network blips).
# Free-tier Gemini routinely returns 503 UNAVAILABLE during demand spikes.
MAX_ATTEMPTS = 4
BACKOFF_SECS = [10, 30, 90]  # waits between attempts 1->2, 2->3, 3->4

response = None
last_error = None

for attempt in range(1, MAX_ATTEMPTS + 1):
    try:
        response = client.models.generate_content(
            model="gemini-2.5-flash",
            contents=PROMPT,
            config=GenerateContentConfig(
                tools=[google_search_tool],
                response_modalities=["TEXT"],
                temperature=1.0,  # recommended for grounding
            ),
        )
        break  # success
    except Exception as e:
        last_error = e
        msg = str(e)
        # Identify transient errors worth retrying
        transient = any(code in msg for code in ("503", "429", "UNAVAILABLE",
                                                  "RESOURCE_EXHAUSTED",
                                                  "DEADLINE_EXCEEDED",
                                                  "INTERNAL"))
        print(f"Gemini API error (attempt {attempt}/{MAX_ATTEMPTS}): {e}")
        if not transient:
            print("Error is not transient. Aborting without retry.")
            break
        if attempt < MAX_ATTEMPTS:
            wait = BACKOFF_SECS[attempt - 1]
            print(f"Transient error. Waiting {wait}s before retry...")
            time.sleep(wait)

if response is None:
    # All retries exhausted. Exit cleanly so the workflow does not flag a
    # transient upstream issue as a failed run. Tomorrow's scheduled run will
    # try again from a fresh state.
    print("\nGemini API unreachable after retries. Exiting cleanly so the "
          "workflow is not marked failed. Last error: " + str(last_error))
    try:
        with open("/tmp/ai-watch-commit-msg.txt", "w") as f:
            f.write("AI Watch: scan skipped (Gemini API unavailable)")
    except Exception:
        pass
    sys.exit(0)

# Extract text from response
final_text = ""
if response.candidates and response.candidates[0].content:
    for part in response.candidates[0].content.parts:
        if hasattr(part, "text") and part.text:
            final_text += part.text

print(f"\nRaw response length: {len(final_text)} chars")

if not final_text.strip():
    print("Empty response from Gemini. Exiting.")
    sys.exit(0)

# ---------------------------------------------------------------------------
# 4. Parse the JSON response
# ---------------------------------------------------------------------------

# Strip markdown fences if present
cleaned = final_text.strip()
cleaned = re.sub(r"^```json\s*", "", cleaned)
cleaned = re.sub(r"\s*```$", "", cleaned)

try:
    result = json.loads(cleaned)
except json.JSONDecodeError as e:
    print(f"Failed to parse JSON: {e}")
    print(f"Response was:\n{final_text[:2000]}")
    open("/tmp/ai-watch-commit-msg.txt", "w").write(
        "AI Watch: scan ran, no parseable results"
    )
    sys.exit(0)

new_entries = result.get("new_entries", [])
updates = result.get("updates_to_existing", [])
summary = result.get("scan_summary", "")

print(f"\nScan summary: {summary}")
print(f"New entries found: {len(new_entries)}")
print(f"Updates to existing: {len(updates)}")

if updates:
    print("\n--- Updates to existing entries (logged, not auto-applied) ---")
    for u in updates:
        print(f"  - {u.get('existing_title')}: {u.get('summary')}")
        print(f"    Source: {u.get('source_url')}")

if not new_entries:
    print("\nNo new entries to add. Exiting.")
    open("/tmp/ai-watch-commit-msg.txt", "w").write(
        "AI Watch: scan ran, no new entries"
    )
    sys.exit(0)

# ---------------------------------------------------------------------------
# 5. Filter out duplicates and entries without sources
# ---------------------------------------------------------------------------

genuinely_new = []
for entry in new_entries:
    title = entry.get("title", "")
    if title.lower().strip() in existing_titles_lower:
        print(f"  Skipping duplicate: {title}")
        continue
    if not entry.get("sources"):
        print(f"  Skipping (no sources): {title}")
        continue
    # Check all sources have URLs
    valid_sources = [s for s in entry["sources"] if s.get("url", "").startswith("http")]
    if not valid_sources:
        print(f"  Skipping (no valid URLs): {title}")
        continue
    entry["sources"] = valid_sources
    genuinely_new.append(entry)

if not genuinely_new:
    print("\nAll entries were duplicates or invalid. Exiting.")
    open("/tmp/ai-watch-commit-msg.txt", "w").write(
        "AI Watch: scan ran, no genuinely new entries"
    )
    sys.exit(0)

print(f"\nAdding {len(genuinely_new)} new entries:")
for e in genuinely_new:
    print(f"  + {e['title']}")

# ---------------------------------------------------------------------------
# 6. Generate HTML for each new entry
# ---------------------------------------------------------------------------

SECTOR_MAP = {
    "health": ("s-health", "Health"),
    "justice": ("s-justice", "Justice"),
    "policing": ("s-policing", "Policing"),
    "welfare": ("s-welfare", "Welfare"),
    "government": ("s-government", "Cross-Govt"),
    "immigration": ("s-immigration", "Immigration"),
    "tax": ("s-tax", "Tax"),
    "safety": ("s-safety", "AI Safety"),
    "education": ("s-government", "Education"),
    "defence": ("s-government", "Defence"),
    "local": ("s-government", "Local Govt"),
}

STATUS_MAP = {
    "live": "live",
    "pilot": "pilot",
    "mou": "mou",
    "review": "review",
}


def html_escape(text):
    """Basic HTML escaping plus smart quotes and pound signs."""
    text = str(text)
    text = text.replace("&", "&amp;")
    text = text.replace("<", "&lt;")
    text = text.replace(">", "&gt;")
    text = text.replace("£", "&pound;")
    text = text.replace("\u2019", "&rsquo;")  # '
    text = text.replace("'", "&rsquo;")
    text = text.replace("\u201c", "&ldquo;")  # "
    text = text.replace("\u201d", "&rdquo;")  # "
    return text


# ---------------------------------------------------------------------------
# Date parsing for chronological sort
# ---------------------------------------------------------------------------

_MONTHS = {
    "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
    "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
    "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
    "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
}
_SEASONS = {"spring": 3, "summer": 6, "autumn": 9, "fall": 9, "winter": 12}
_P_DAY_MONTH_YEAR = re.compile(
    r"\b(\d{1,2})\s+(january|february|march|april|may|june|july|august|"
    r"september|october|november|december|jan|feb|mar|apr|jun|jul|aug|"
    r"sep|sept|oct|nov|dec)\s+(\d{4})\b", re.IGNORECASE)
_P_MONTH_DAY_YEAR = re.compile(
    r"\b(january|february|march|april|may|june|july|august|september|"
    r"october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|"
    r"oct|nov|dec)\s+(\d{1,2}),?\s+(\d{4})\b", re.IGNORECASE)
_P_MONTH_YEAR = re.compile(
    r"\b(january|february|march|april|may|june|july|august|september|"
    r"october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|"
    r"oct|nov|dec)\s+(\d{4})\b", re.IGNORECASE)
_P_SEASON = re.compile(
    r"\b(spring|summer|autumn|fall|winter)\s+(20\d{2})\b", re.IGNORECASE)
_P_YEAR = re.compile(r"\b(20\d{2})\b")


def parse_date_to_iso(text):
    """Return the earliest (year, month, day) found, or None."""
    if not text:
        return None
    found = []
    for m in _P_DAY_MONTH_YEAR.finditer(text):
        found.append((int(m.group(3)), _MONTHS[m.group(2).lower()], int(m.group(1))))
    for m in _P_MONTH_DAY_YEAR.finditer(text):
        found.append((int(m.group(3)), _MONTHS[m.group(1).lower()], int(m.group(2))))
    if not found:
        for m in _P_MONTH_YEAR.finditer(text):
            found.append((int(m.group(2)), _MONTHS[m.group(1).lower()], 1))
    if not found:
        for m in _P_SEASON.finditer(text):
            found.append((int(m.group(2)), _SEASONS[m.group(1).lower()], 1))
    if not found:
        for m in _P_YEAR.finditer(text):
            found.append((int(m.group(1)), 1, 1))
    if not found:
        return None
    y, m, d = min(found)
    return f"{y:04d}-{m:02d}-{d:02d}"


def build_entry_html(entry):
    sector_key = entry.get("sector", "government")
    sector_css, sector_label = SECTOR_MAP.get(
        sector_key, ("s-government", "Cross-Govt")
    )
    data_sector = (
        sector_key
        if sector_key
        in ("health", "justice", "policing", "welfare", "government",
            "immigration", "tax", "safety")
        else "government"
    )

    status_class = STATUS_MAP.get(entry.get("status", "live"), "live")
    status_label = html_escape(
        entry.get("status_label", entry.get("status", "Live").title())
    )

    date_string = entry.get("date_string", "")
    iso_date = parse_date_to_iso(date_string)
    today_iso = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    if iso_date is None:
        # Fallback to today (scanner found it today)
        iso_date = today_iso
    # Guard against hallucinated future dates. If Gemini returns a date
    # later than today (commonly because it used a roundup article's
    # publication date instead of the original announcement date),
    # cap to today so the entry sorts correctly and doesn't claim to
    # come from the future.
    if iso_date > today_iso:
        print(f"  WARN: capping future date {iso_date} -> {today_iso} for entry: {entry.get('title','?')}")
        iso_date = today_iso
        # Also blank the displayed date_string if it was a clear hallucination,
        # so the front-end doesn't show a future date in the visible label.
        if date_string and parse_date_to_iso(date_string) and parse_date_to_iso(date_string) > today_iso:
            date_string = "Date pending review"

    facts_html = ""
    for fact in entry.get("facts", []):
        facts_html += (
            f'        <div class="entry-fact">'
            f'<dt>{html_escape(fact["label"])}</dt>'
            f'<dd>{html_escape(fact["value"])}</dd>'
            f"</div>\n"
        )

    sources_html = ""
    for src in entry.get("sources", []):
        sources_html += (
            f'        <a href="{src["url"]}" target="_blank" rel="noopener">'
            f'{html_escape(src["label"])}</a>\n'
        )

    return f"""
    <article class="entry" data-sector="{data_sector}" data-date="{iso_date}">
      <div class="entry-top">
        <span class="entry-date">{html_escape(date_string or "2026")}</span>
        <span class="entry-sector {sector_css}">{html_escape(sector_label)}</span>
        <span class="entry-status {status_class}">{status_label}</span>
      </div>
      <div class="entry-buyer">{html_escape(entry.get("buyer", ""))}</div>
      <h2 class="entry-h">{html_escape(entry.get("title", ""))}</h2>
      <div class="entry-supplier">{html_escape(entry.get("supplier", ""))}</div>
      <p class="entry-body">{html_escape(entry.get("body", ""))}</p>
      <dl class="entry-facts">
{facts_html.rstrip()}
      </dl>
      <div class="entry-sources">
        Sources
{sources_html.rstrip()}
      </div>
    </article>
"""


def resort_entries_section(html_doc):
    """Re-sort every entry inside the entries section by data-date descending."""
    sec_re = re.compile(
        r'(<section class="entries" id="entries">)(.*?)(</section>)', re.DOTALL)
    sm = sec_re.search(html_doc)
    if not sm:
        return html_doc
    body = sm.group(2)
    art_re = re.compile(r'(<article class="entry"[^>]*>.*?</article>)', re.DOTALL)
    arts = art_re.findall(body)
    if len(arts) < 2:
        return html_doc
    date_attr_re = re.compile(r'data-date="([^"]*)"')
    keyed = []
    for art in arts:
        m = date_attr_re.search(art)
        key = m.group(1) if m else "1900-01-01"
        keyed.append((key, art))
    keyed.sort(key=lambda x: x[0], reverse=True)
    new_body = "\n\n    " + "\n\n    ".join(a for _, a in keyed) + "\n\n  "
    return html_doc[:sm.start(2)] + new_body + html_doc[sm.end(2):]


new_html_blocks = "\n".join(build_entry_html(e) for e in genuinely_new)

# ---------------------------------------------------------------------------
# 7. Insert into ai-watch.html
# ---------------------------------------------------------------------------

INSERT_MARKER = '<section class="entries" id="entries">'
if INSERT_MARKER not in html:
    print("ERROR: Could not find insertion marker in HTML.")
    sys.exit(1)

html = html.replace(
    INSERT_MARKER,
    INSERT_MARKER + "\n" + new_html_blocks,
    1,
)

# Re-sort the entries section chronologically (newest first) by data-date.
# Every entry must carry a data-date attribute (existing entries are
# backfilled by sort_aiwatch.py; new entries are stamped in build_entry_html).
html = resort_entries_section(html)

# Update entry count
new_count = entry_count + len(genuinely_new)
html = re.sub(
    r"Entries:\s*\d+",
    f"Entries: {new_count}",
    html,
    count=1,
)

# Update last-updated date
html = re.sub(
    r"Last updated:\s*[^&·]+",
    f"Last updated: {TODAY} ",
    html,
    count=1,
)

with open(HTML_PATH, "w", encoding="utf-8") as f:
    f.write(html)

print(f"\nUpdated {HTML_PATH}: {new_count} entries (was {entry_count})")

# ---------------------------------------------------------------------------
# 7b. Publish each new entry to X (@AIRightsUK)
# ---------------------------------------------------------------------------
# Defensive: if x_publish fails or credentials are missing, we log and
# continue so the website update is never blocked by a social issue.
try:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import x_publish
    print("\n--- X publishing ---")
    x_result = x_publish.publish_entries(genuinely_new)
    print(f"X publishing result: {x_result}")
except Exception as e:
    print(f"X publishing failed (continuing): {e}")

# ---------------------------------------------------------------------------
# 8. Write commit message
# ---------------------------------------------------------------------------

titles = ", ".join(e["title"] for e in genuinely_new)
commit_msg = f"AI Watch: add {len(genuinely_new)} new entry/entries \u2014 {titles}"
if len(commit_msg) > 150:
    commit_msg = commit_msg[:147] + "..."

with open("/tmp/ai-watch-commit-msg.txt", "w") as f:
    f.write(commit_msg)

print(f"Commit message: {commit_msg}")
print("Done.")

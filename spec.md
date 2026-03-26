# OLJAlerts — Project Specification

> Keyword-based job alert system for OnlineJobs.ph — built with n8n and PostgreSQL. Subscribe via Telegram bot, get notified instantly when a matching job is posted.

---

## Table of Contents

1. [Overview](#overview)
2. [Goals](#goals)
3. [Architecture](#architecture)
4. [Database Schema](#database-schema)
5. [Workflows](#workflows)
    - [Workflow 0 — OnlineJobs.ph Job Sync](#workflow-0--onlinejobsph-job-sync)
    - [Workflow 1 — Subscription Manager](#workflow-1--subscription-manager)
    - [Workflow 2 — Job Alert Notifier](#workflow-2--job-alert-notifier)
6. [Telegram Bot Commands](#telegram-bot-commands)
7. [Notification Format](#notification-format)
8. [Tech Stack](#tech-stack)
9. [Environment Variables](#environment-variables)
10. [Constraints & Limitations](#constraints--limitations)
11. [Future Improvements](#future-improvements)

---

## Overview

OLJAlerts is an automated job alert system that syncs job postings from OnlineJobs.ph into a PostgreSQL database and notifies Telegram users when a new posting matches their subscribed keywords.

Users interact entirely through a Telegram bot. They subscribe to keywords (e.g. `n8n`, `virtual assistant`, `react`), and whenever a matching job is inserted into the database, they receive an instant Telegram message.

---

## Goals

- Allow users to subscribe to one or more job keywords via Telegram
- Detect new job postings inserted into PostgreSQL in near real-time
- Match new postings against all active keyword subscriptions
- Deliver formatted job alert messages to matched subscribers via Telegram bot
- Allow users to manage (add/remove/list) their subscriptions at any time

---

## Architecture

```
┌────────────────────────────────────────────────────┐
│                        PostgreSQL                  │
│  ┌─────────────────────┐  ┌─────────────────────┐  │
│  │  job_postings       │  │  user_subscriptions │  │
│  │  - job_id (PK)      │  │  - chat_id          │  │
│  │  - job_title        │  │  - keyword          │  │
│  │  - job_description  │  │                     │  │
│  │  - ...              │  │                     │  │
│  └─────────────────────┘  └─────────────────────┘  │
│                            │                       │
└────────────────────────────┼───────────────────────┘
                             │
           ┌─────────────────┼─────────────────┐
           │                 │                 │
           ▼                 ▼                 ▼
     ┌──────────┐      ┌──────────┐      ┌──────────┐
     │Workflow 0│      │Workflow 1│      │Workflow 2│
     │Job Sync  │      │Sub Mgr   │      │Alert Not.│
     │          │      │Keywordsub │      │Polling   │
     │Scheduled │      │Telegram  │      │Trigger   │
     │Trigger   │      │Trigger   │      │by Processed│
    └────┬─────┘      └────┬─────┘      └────┬─────┘
         │                 │                 │
         ▼                 ▼                 ▼
   OnlineJobs.ph        Telegram User      Telegram API
   (HTTP Scrape)        (Commands)      (Notifications)
```

**Design Philosophy**: Fully decoupled modular architecture where each workflow operates independently through PostgreSQL as the central data bus.

**Workflow Independence:**

- **Workflow 0 — OnlineJobs.ph Job Sync**: Scheduled trigger (every 5-10 min). Scrapes new job postings from OnlineJobs.ph using HTTP GET requests, parses HTML with CSS selectors, and batch inserts into `job_postings` table. Implements intelligent stop conditions (batch limit or consecutive 404s) and retry logic. **No dependency on other workflows.**

- **Workflow 1 — Subscription Manager**: Handles `/keywordsub` command from Telegram users. Deletes existing keywords for user, then inserts new keywords (comma-separated, max 3). Reads and writes to `user_subscriptions`. **No dependency on other workflows.**

- **Workflow 2 — Job Alert Notifier**: Triggered every 20 seconds via schedule. Selects one unprocessed job posting, matches keywords against title and description, finds subscribers, sends HTML-formatted Telegram notifications, and marks job as processed. **No dependency on Workflow 0.**

**Key Decoupling Points:**

1. **PostgreSQL as Event Bus**: Workflow 2 reacts to database INSERT events, not Workflow 0 directly. This means Workflow 0 can be stopped/modified without affecting Workflow 2.
2. **Independent Triggers**: Each workflow has its own trigger mechanism (schedule, telegram trigger, postgres trigger).
3. **No Direct Workflow Communication**: Workflows communicate only through the database, never through n8n-to-n8n webhooks.
4. **Isolated Failure**: If one workflow fails, others continue operating normally.

---

## Database Schema

### `job_postings` (synced from OnlineJobs.ph via Workflow 0)

```sql
CREATE TABLE job_postings (
  id               SERIAL PRIMARY KEY,
  job_id           BIGINT NOT NULL UNIQUE,  -- OnlineJobs.ph job ID
  job_title        TEXT,                     -- Job title
  job_description  TEXT,                     -- Full job description
  job_skills       TEXT,                     -- Required skills (comma-separated)
  type_of_work     TEXT,                     -- Full-time, Part-time, Contract, etc.
  compensation     TEXT,                     -- Salary/rate information
  hours_per_week   TEXT,                     -- Expected hours per week
  job_date         DATE,                     -- Date job was posted
  is_processed     BOOLEAN DEFAULT FALSE,    -- Flag for alert processing
  created_at       TIMESTAMPTZ DEFAULT NOW()
);
```

| Column | Type | Notes |
|---|---|---|
| `id` | SERIAL | Primary key (internal DB ID) |
| `job_id` | BIGINT | OnlineJobs.ph job ID (unique) |
| `job_title` | TEXT | Job title |
| `job_description` | TEXT | Full job description |
| `job_skills` | TEXT | Required skills |
| `type_of_work` | TEXT | Full-time, Part-time, etc. |
| `compensation` | TEXT | Salary/rate info |
| `hours_per_week` | TEXT | Expected hours |
| `job_date` | DATE | Posting date |
| `is_processed` | BOOLEAN | Flag indicating if job has been processed by alert workflow |
| `created_at` | TIMESTAMPTZ | Row insert timestamp |

### `sync_errors` (optional, for logging failed scrapes)

```sql
CREATE TABLE sync_errors (
  id          SERIAL PRIMARY KEY,
  job_id      BIGINT NOT NULL,
  error_code  TEXT,
  error_message TEXT,
  retry_count INTEGER DEFAULT 0,
  failed_at   TIMESTAMPTZ DEFAULT NOW()
);
```

| Column | Type | Notes |
|---|---|---|
| `id` | SERIAL | Primary key |
| `job_id` | BIGINT | OnlineJobs.ph job ID that failed |
| `error_code` | TEXT | HTTP status code or error type |
| `error_message` | TEXT | Detailed error message |
| `retry_count` | INTEGER | Number of retries attempted |
| `failed_at` | TIMESTAMPTZ | When the error occurred |

### `user_subscriptions` (new table)

```sql
CREATE TABLE user_subscriptions (
  id          SERIAL PRIMARY KEY,
  chat_id     BIGINT NOT NULL,
  keyword     TEXT NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(chat_id, keyword)
);
```

| Column | Type | Notes |
|---|---|---|
| `id` | SERIAL | Primary key |
| `chat_id` | BIGINT | Telegram chat ID of the subscriber |
| `keyword` | TEXT | Subscribed keyword (stored lowercase) |
| `created_at` | TIMESTAMPTZ | Subscription timestamp |

---

## Workflows

### Workflow 0 — OnlineJobs.ph Job Sync

**Trigger**: Schedule Trigger (every 2 minutes)

**Purpose**: Incrementally scrape new job postings from OnlineJobs.ph and batch insert into `job_postings` table.

| Step | Node | Description |
|---|---|---|
| 1 | Schedule Trigger | Runs every 2 minutes |
| 2 | Postgres | `SELECT job_id FROM job_postings ORDER BY job_id DESC LIMIT 1` (get last processed ID) |
| 3 | Code | Generate next 5 job IDs (last_id + 1 through last_id + 5) |
| 4 | Split In Batches | Loop through the 5 job IDs |
| 4a | Set | Store `job_id` from current iteration |
| 4b | HTTP Request | GET `https://www.onlinejobs.ph/jobseekers/job/{{ $json.jobId }}` |
| 4c | HTML Extract | Parse using CSS selectors (see Field Extraction below) |
| 4d | IF | Check if job has valid data (non-empty description, type_of_work, compensation, job_date) |
| 4e-false | Skip | Continue to next job ID if validation fails |
| 4e-true | Set | Map extracted fields to database column names |
| 4f-true | Postgres | `INSERT INTO job_postings (...) VALUES (...)` with `ON CONFLICT (job_id) DO NOTHING` |
| 4g | Wait | 0.05 second delay between iterations |
| 5 | Loop Back | Continue until all 5 job IDs processed |
| 6 | Stop | End workflow |

**Field Extraction (CSS Selectors):**

| Field | CSS Selector |
|---|---|
| `job_title` | `h1` |
| `job_description` | `.job-description` |
| `job_skills` | `.card-worker-topskill` |
| `type_of_work` | `h3:contains("TYPE OF WORK") + p` |
| `compensation` | `h3:contains("WAGE / SALARY") + p` |
| `hours_per_week` | `h3:contains("HOURS PER WEEK") + p` |
| `job_date` | `h3:contains("DATE UPDATED") + p` |

**Validation Logic:**

A job is only inserted to the database if ALL of the following fields are non-empty:
- `job_description`
- `type_of_work`
- `compensation`
- `job_date`

This ensures only complete, high-quality job postings are stored.

**Implementation Details:**

- **Fixed batch size**: 5 jobs per workflow execution
- **Schedule**: Every 2 minutes
- **No retry logic**: If a job ID returns 404 or errors, the workflow continues to the next ID
- **No consecutive 404 tracking**: The workflow simply processes the next 5 IDs regardless of status
- **ON CONFLICT**: Uses PostgreSQL's upsert to prevent duplicate job_id entries
- **Small delay**: 0.05 second wait between HTTP requests to avoid rate limiting

**Rate Limiting Considerations:**

- HTTP requests occur every 0.05 seconds within a batch
- Total of 5 HTTP requests per 2-minute cycle
- This conservative approach should avoid triggering anti-bot measures
- If rate-limit errors occur, increase the schedule interval or add longer delays

---

### Workflow 1 — Subscription Manager

**Trigger**: Telegram Trigger node (on incoming message)

| Step | Node | Description |
|---|---|---|
| 1 | Telegram Trigger | Receives all incoming bot messages |
| 2 | IF | Check if message contains `/keywordsub` |
| 3 | IF | Validate keyword count (max 3 keywords allowed) |
| 4 | Set | Extract keywords from command (comma-separated) |
| 5 | Postgres | DELETE all existing keywords for this chat_id |
| 6 | Split Out | Split keyword array into individual items |
| 7 | Split In Batches | Loop through each keyword |
| 8 | Set | Prepare payload with chat_id and keyword |
| 9 | Postgres | INSERT keyword into user_subscriptions |
| 10 | Loop Back | Continue until all keywords inserted |
| 11 | Set | Format success message with all subscribed keywords |
| 12 | Telegram | Send confirmation message to user |

**Command Format:**

- `/keywordsub keyword1, keyword2, keyword3`
- Keywords are comma-separated
- Maximum 3 keywords per command
- Whitespace around keywords is trimmed automatically
- This command REPLACES all existing keywords for the user (not additive)

**Implementation Details:**

- **Replace-all behavior**: The workflow deletes all existing keywords for the chat_id before adding new ones
- **Keyword validation**: Only processes messages containing `/keywordsub` command
- **Count limit**: Maximum 3 keywords per submission (enforced by workflow validation)
- **Duplicate prevention**: Database has UNIQUE constraint on (chat_id, keyword) combination
- **Feedback**: User receives confirmation listing all their newly subscribed keywords

**Error Handling:**

- If more than 3 keywords provided, the workflow stops processing
- Invalid or malformed commands are silently ignored (no error response)
- Database insertion errors (violations) are handled by PostgreSQL constraints

---

### Workflow 2 — Job Alert Notifier

**Architecture**: Split into Main Workflow (job processing) and Subworkflow (notification delivery)

**Main Workflow Trigger**: Schedule Trigger (every 20 seconds)

**Subworkflow Trigger**: Execute Workflow Trigger (called from Main Workflow)

#### Main Workflow Steps

| Step | Node | Description |
|---|---|---|
| 1 | Schedule Trigger | Runs every 20 seconds |
| 2 | Postgres | SELECT 1 unprocessed job post (WHERE is_processed = false) |
| 3 | IF | Check if unprocessed job exists |
| 4 | Postgres | SELECT DISTINCT keywords from user_subscriptions |
| 5 | Code | Match keywords against job title and description using word-boundary regex |
| 6 | Code | Transform matched keywords to array |
| 7 | IF | Check if any keywords matched |
| 8 | Set | Prepare payload with matched keywords and job data |
| 9 | Execute Workflow | Call "Workflow 2 - Job Alert Notifier subworkflow" |
| 10 | Set | Prepare payload for marking job as processed |
| 11 | Postgres | Update job post is_processed = true |
| 12 | Stop | End workflow (no match case) |

#### Subworkflow Steps

| Step | Node | Description |
|---|---|---|
| 1 | Execute Workflow Trigger | Receives data from Main Workflow |
| 2 | Postgres | SELECT chat_ids for matched keywords |
| 3 | Remove Duplicates | Deduplicate chat_ids (one message per user) |
| 4 | Split In Batches | Loop through each subscriber |
| 5 | Set | Prepare payload for marking job as processed |
| 6 | Postgres | Update job post is_processed = true |
| 7 | Telegram | Send HTML-formatted alert to subscriber |
| 8 | Wait | 0.25 second delay between messages |
| 9 | Loop Back | Continue until all subscribers notified |
| 10 | Stop | End subworkflow |

**Key Benefits of Split Architecture:**
- **Better logging**: Subworkflow only saves successful executions, making it easier to track notification delivery
- **Error isolation**: Notification failures don't affect job processing logic
- **Reusability**: Subworkflow can be called from other workflows if needed

**Keyword Matching Algorithm:**

```javascript
// 1. Get job data (title and description)
const jobData = $('Select 1 unprocessed job post').first().json;

const description = (jobData.job_description || "").toLowerCase();
const title = (jobData.job_title || "").toLowerCase();
const fullText = title + " " + description;

// 2. Get all keywords from database
const allKeywords = $input.all().map(item => item.json.keyword);

// 3. Filter: Keep ONLY keywords found in the text using word-boundary matching
const matchedKeywords = allKeywords.filter(kw => {
  // Escape special regex characters to prevent syntax errors
  const escapedKw = kw.toLowerCase().replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // Use word boundary matching for precise matches
  const regex = new RegExp(`\\b${escapedKw}\\b`, 'i');
  return regex.test(fullText);
});

// 4. Return the filtered list
return matchedKeywords.map(kw => ({ json: { keyword: kw } }));
```

**Matching Behavior:**
- **Word-boundary matching**: Uses `\b` regex metacharacter to match whole words only
- **Case-insensitive**: Uses the `'i'` flag for case-insensitive matching
- **Special character escaping**: Properly escapes regex metacharacters in keywords (e.g., `c++`, `.net`)
- **Examples**:
  - 'ai' matches "AI specialist" ✓
  - 'ai' does NOT match "PAID" ✗
  - 'ai' does NOT match "TRAINING" ✗
  - 'react' matches "React developer" ✓
  - 'react' does NOT match "proactive" ✗

**Processing Logic:**

- **Polling approach**: Main workflow checks for unprocessed jobs every 20 seconds
- **One job at a time**: Main workflow processes only 1 unprocessed job per execution
- **Always marks processed**: Even if no keywords match, job is marked as `is_processed = true` to prevent re-processing
- **Duplicate prevention**: Subworkflow uses `Remove Duplicates` node to ensure each user receives only one notification per job
- **HTML formatting**: Subworkflow sends Telegram messages using HTML parse_mode for rich formatting with emojis
- **Execution tracking**: Subworkflow only saves successful executions, providing cleaner logs for notification delivery

**Notification Format:**

```html
<b>🔔 New Job Match!</b>

<b>{job_title}</b>

📝 <b>Description:</b>
{job_description.substring(0, 120)}...

💼 <b>Type:</b> {type_of_work}
💰 <b>Pay:</b> {compensation}
⏰ <b>Hours:</b> {hours_per_week}

👉 <a href="https://www.onlinejobs.ph/jobseekers/job/{job_id}">Apply here!</a>
```

**Implementation Details:**

- **Rate limiting**: 0.05 second delay between Telegram messages to avoid API limits
- **Description truncation**: First 120 characters of job description shown
- **Interactive link**: "Apply here!" is a clickable link to the job posting
- **HTML tags**: Uses `<b>` for bold and `<a>` for links
- **User-friendly**: Structured format with emojis for easy scanning

---

## Telegram Bot Commands

| Command | Description | Example |
|---|---|---|
| `/keywordsub <keywords>` | Replace all subscriptions with new keywords (comma-separated, max 3) | `/keywordsub n8n, react, remote` |

**Usage Notes:**
- Keywords are comma-separated in a single command
- Maximum 3 keywords allowed per submission
- This command REPLACES all existing keywords (not additive)
- Whitespace around keywords is automatically trimmed
- Duplicate keywords in the same command are handled gracefully |

---

## Notification Format

```html
<b>🔔 New Job Match!</b>

<b>{job_title}</b>

📝 <b>Description:</b>
{job_description.substring(0, 120)}...

💼 <b>Type:</b> {type_of_work}
💰 <b>Pay:</b> {compensation}
⏰ <b>Hours:</b> {hours_per_week}

👉 <a href="https://www.onlinejobs.ph/jobseekers/job/{job_id}">Apply here!</a>
```

**Implementation Details:**

- Uses Telegram HTML parse_mode for formatting
- **Bold text**: Job title and field labels
- **Emojis**: 🔔, 📝, 💼, 💰, ⏰, 👉 for visual hierarchy
- **Description**: First 120 characters with ellipsis (...)
- **Interactive link**: "Apply here!" is clickable and opens job posting
- **Structured layout**: Key job details clearly separated for quick scanning
- **Fields pulled from `job_postings`**: job_title, job_description, type_of_work, compensation, hours_per_week, job_id

**Example:**

```html
<b>🔔 New Job Match!</b>

<b>Senior n8n Automation Developer</b>

📝 <b>Description:</b>
Looking for an experienced n8n developer to build automation workflows...

💼 <b>Type:</b> Full-time
💰 <b>Pay:</b> PHP 50,000 - 80,000 / month
⏰ <b>Hours:</b> 40 hours/week

👉 <a href="https://www.onlinejobs.ph/jobseekers/job/123456">Apply here!</a>
```

---

## Tech Stack

| Layer | Tool |
|---|---|
| Automation / workflows | n8n (self-hosted) |
| Database | PostgreSQL |
| Messaging | Telegram Bot API |
| Job data source | OnlineJobs.ph (scraping via HTTP Request + HTML parsing) |
| HTML parsing | n8n HTML Extract (CSS Selectors) |

---

## Environment Variables

### Sync Workflow Configuration (Workflow 0)

| Variable | Description | Value |
|---|---|---|
| `SYNC_SCHEDULE_MINUTES` | How often to run the job sync | `2` |
| `SYNC_BATCH_SIZE` | Max jobs to fetch per execution | `5` |
| `HTTP_REQUEST_DELAY_SECONDS` | Delay between HTTP requests | `0.05` |

### Subscription Manager Configuration (Workflow 1)

| Variable | Description | Value |
|---|---|---|
| `MAX_KEYWORDS_PER_COMMAND` | Maximum keywords allowed in /keywordsub | `3` |

### Alert Notifier Configuration (Workflow 2)

| Variable | Description | Value |
|---|---|---|
| `POLL_INTERVAL_SECONDS` | How often to check for unprocessed jobs | `20` |
| `TELEGRAM_MESSAGE_DELAY_SECONDS` | Delay between Telegram messages | `0.05` |
| `JOB_DESCRIPTION_TRUNCATE_CHARS` | Number of characters to show in alert | `120` |

### Required Credentials

| Variable | Description |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Bot token from @BotFather |
| `DATABASE_URL` | PostgreSQL connection string: `postgresql://job_alert_client:password@localhost:5432/oljalerts` |
| `N8N_WEBHOOK_URL` | Base URL for n8n webhook endpoints (if self-hosted) |

---

## Constraints & Limitations

### Scraping & Data Sync (Workflow 0)
- **Rate limiting risk** — Scraping every 2 minutes with 5 requests per batch may trigger anti-bot measures. Monitor for 429 errors and adjust schedule or delay if needed.
- **CSS selector fragility** — HTML structure changes on OnlineJobs.ph will break field extraction. Needs maintenance when job pages change.
- **No sequential ID tracking** — The workflow simply processes next 5 job IDs regardless of gaps or 404s. This may skip valid jobs if there are large gaps.
- **No retry logic** — If a job ID returns 404 or errors, the workflow continues to the next ID without retrying.
- **No company name extraction** — Currently not extracting employer name. Can be added if needed.
- **Failed jobs are skipped** — Jobs that fail validation (missing required fields) are silently skipped and not logged.

### Subscription Manager (Workflow 1)
- **Replace-all behavior** — The `/keywordsub` command deletes all existing keywords before adding new ones. Users cannot add/remove individual keywords.
- **No unsubscribe command** — Users must use `/keywordsub` with their desired keywords to replace their subscription.
- **No subscriptions list command** — Users cannot view their current subscriptions via the bot.
- **No keyword validation** — Keywords are not validated for relevance or appropriateness.
- **Single command** — Only `/keywordsub` is implemented. No `/start`, `/help`, or other bot commands.

### Alert Notifier (Workflow 2 + Subworkflow)
- **One job per execution** — Only processes 1 unprocessed job per 20-second cycle. May not keep up with high-volume job postings.
- **Polling vs triggers** — Uses polling approach (every 20 seconds) instead of PostgreSQL triggers. May introduce slight delay in notifications.
- **No deduplication across runs** — The `is_processed` flag prevents re-processing, but if a job is skipped (validation failure), it may be re-attempted.
- **Telegram rate limit** — Telegram allows ~30 messages/second per bot. Current 0.25 second delay is well within limits.
- **No feedback loop** — Users cannot provide feedback on job relevance (like/dislike) to improve matching.
- **Workflow complexity** — Split architecture adds complexity but improves logging and error isolation.

---

## Future Improvements

### Sync Workflow (Workflow 0)
- **Company name extraction** — Add `company` field to track employer names
- **Dynamic job listing page scraping** — Instead of incremental ID fetching, scrape the job listings page for a more robust discovery mechanism
- **Incremental deduplication check** — Use HTTP HEAD requests before full GET to avoid downloading duplicate content
- **Scrape job listings for efficiency** — Fetch multiple jobs in one request from a listings page instead of individual job pages
- **RSS feed monitoring** — If OnlineJobs.ph provides RSS feeds, use instead of scraping
- **Retry logic** — Add retry mechanism for failed HTTP requests with exponential backoff
- **Sequential gap handling** — Implement logic to track and handle large gaps in job IDs
- **Error logging** — Add `sync_errors` table to log failed job IDs for manual review

### Subscription Manager (Workflow 1)
- **Add/remove individual keywords** — Implement `/addkeyword` and `/removekeyword` commands for granular control
- **List subscriptions command** — Add `/listkeywords` command to show current subscriptions
- **Help/start command** — Implement `/start` and `/help` commands with usage instructions
- **Keyword categories / tags** — Let users subscribe to predefined categories instead of free-text keywords
- **Keyword suggestions** — Suggest popular keywords based on existing job postings
- **Subscription validation** — Validate keywords for relevance and appropriateness
- **Unsubscribe all** — Add command to remove all subscriptions at once

### Alert Notifier (Workflow 2)
- **PostgreSQL triggers** — Replace polling with database triggers for real-time notifications
- **Batch processing** — Process multiple unprocessed jobs per execution to handle high volume
- **Alert frequency control** — Daily digest mode vs. instant alerts (user preference)
- **Keyword importance scoring** — Prioritize notifications based on keyword match quality
- **User feedback** — Allow users to like/dislike jobs to improve matching relevance
- **Notification throttling** — Prevent spam by limiting notifications per user per day
- **Richer formatting** — Include more job details like skills, requirements, etc.
- **Apply button** — Add inline button in Telegram to open job application directly

### General
- **Admin dashboard** — Simple n8n or web UI to view subscriber stats and recent alerts
- **OLJAlerts web landing page** — Public page explaining the bot with a `/keywordsub` deep link
- **Analytics** — Track popular keywords, job posting trends, user engagement
- **Multi-user support** — Support multiple Telegram users with different subscriptions
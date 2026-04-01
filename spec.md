# OLJAlerts — Project Specification

> Keyword-based job alert system for OnlineJobs.ph — built with n8n and PostgreSQL. Subscribe via Telegram bot, get notified instantly when a matching job is posted.

---

## Table of Contents

1. [Overview](#overview)
2. [Goals](#goals)
3. [Architecture](#architecture)
4. [Database Schema](#database-schema)
5. [Workflows](#workflows)
    - [Workflow 0 — OnlineJobs.ph Job Sync (New Jobs)](#workflow-0--onlinejobsph-job-sync-new-jobs)
    - [Workflow 0 — OnlineJobs.ph Job Sync (Recently Updated)](#workflow-0--onlinejobsph-job-sync-recently-updated)
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

OLJAlerts is an automated job alert system that syncs job postings from OnlineJobs.ph into a PostgreSQL database and notifies Telegram users when a new posting matches their subscribed keywords. The system uses two separate workflows to capture both new job postings and recently updated jobs with old job_ids.

Users interact entirely through a Telegram bot. They subscribe to keywords (e.g. `n8n`, `virtual assistant`, `react`), and whenever a matching job is inserted into the database, they receive an instant Telegram message.

---

## Goals

- Allow users to subscribe to one or more job keywords via Telegram
- Detect new job postings inserted into PostgreSQL in near real-time
- Match new postings against all active keyword subscriptions
- Deliver formatted job alert messages to matched subscribers via Telegram bot
- Allow users to manage (subscribe/unsubscribe) their subscriptions at any time
- Provide admin-only stats and management commands
- Auto-clean subscriptions for users who block the bot

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
      │(New)     │      │Switch    │      │Polling   │
      │Scheduled │      │Router    │      │Trigger   │
      │8 min     │      │Telegram  │      │by Processed│
     └────┬─────┘      └────┬─────┘      └────┬─────┘
          │                 │                 │
          ▼                 ▼                 ▼
    OnlineJobs.ph        Telegram User      Telegram API
    (HTTP Scrape)        (Commands)      (Notifications)

      ┌──────────┐                               ┌──────────┐
      │Workflow 0│                               │Supabase  │
      │Job Sync  │                               │(Logging) │
      │(Updated) │                               │          │
      │Scheduled │                               │          │
      │15 min    │                               │          │
     └────┬─────┘                               └──────────┘
          │                                          ▲
          ▼                                          │
    OnlineJobs.ph                    Workflow 1 logs all messages
    (Job Search Page)
```

**Design Philosophy**: Fully decoupled modular architecture where each workflow operates independently through PostgreSQL as the central data bus.

**Workflow Independence:**

- **Workflow 0 — OnlineJobs.ph Job Sync (New Jobs)**: Scheduled trigger (every 8 minutes). Scrapes new job postings from OnlineJobs.ph using incremental ID-based fetching (last job_id + 1 through + 5), parses HTML with CSS selectors, and inserts into `job_postings` table. No retry logic on 404s. **No dependency on other workflows.**

- **Workflow 0 — OnlineJobs.ph Job Sync (Recently Updated)**: Scheduled trigger (every 15 minutes). Scrapes recently updated jobs from OnlineJobs.ph job search page, removes duplicates against existing job_ids in database, parses HTML with CSS selectors, and inserts/updates into `job_postings` table. **No dependency on other workflows.**

- **Workflow 1 — Subscription Manager**: Handles multiple commands from Telegram users via a Switch router. Supports `/keywordsub` (subscribe), `/unsub` (unsubscribe), `/stats` (admin stats), `/admin` (admin keyword management), and help fallback. Logs all messages to Supabase. **No dependency on other workflows.**

- **Workflow 2 — Job Alert Notifier**: Triggered every 20 seconds via schedule. Selects one unprocessed job posting, matches keywords against title and description using word-boundary regex, finds subscribers, sends HTML-formatted Telegram notifications via subworkflow, and marks job as processed. **No dependency on Workflow 0.**

**Key Decoupling Points:**

1. **PostgreSQL as Event Bus**: Workflow 2 reacts to database INSERT events, not Workflow 0 directly. This means Workflow 0 can be stopped/modified without affecting Workflow 2.
2. **Independent Triggers**: Each workflow has its own trigger mechanism (schedule, telegram trigger).
3. **No Direct Workflow Communication**: Workflows communicate only through the database, never through n8n-to-n8n webhooks.
4. **Isolated Failure**: If one workflow fails, others continue operating normally.

---

## Database Schema

### `job_postings` (synced from OnlineJobs.ph via Workflow 0)

```sql
CREATE TABLE job_postings (
  id               SERIAL PRIMARY KEY,
  job_id           BIGINT NOT NULL UNIQUE,
  job_title        TEXT,
  job_description  TEXT,
  job_skills       TEXT,
  type_of_work     TEXT,
  compensation     TEXT,
  hours_per_week   TEXT,
  job_date         DATE,
  is_processed     BOOLEAN DEFAULT FALSE,
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

### `user_subscriptions` (managed via Workflow 1)

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

### Indexes

```sql
CREATE INDEX idx_job_postings_job_id ON job_postings(job_id);
CREATE INDEX idx_job_postings_created_at ON job_postings(created_at DESC);
CREATE INDEX idx_job_postings_is_processed ON job_postings(is_processed);
CREATE INDEX idx_user_subscriptions_chat_id_keyword ON user_subscriptions(chat_id, keyword);
```

---

## Workflows

### Workflow 0 — OnlineJobs.ph Job Sync (New Jobs)

**Trigger**: Schedule Trigger (every 8 minutes)

**Purpose**: Incrementally scrape new job postings from OnlineJobs.ph and batch insert into `job_postings` table.

| Step | Node | Description |
|---|---|---|
| 1 | Schedule Trigger | Runs every 8 minutes |
| 2 | GET last processed job_id | `SELECT job_id FROM job_postings ORDER BY job_id DESC LIMIT 1` |
| 3 | Generate next 5 job_ids | Code node generates next 5 job IDs (last_id + 1 through last_id + 5) |
| 4 | Loop Over Items | Split In Batches to loop through the 5 job IDs |
| 4a | Config | Store `jobId` from current iteration via Set node |
| 4b | GET HTML | GET `https://www.onlinejobs.ph/jobseekers/job/{{ $json.jobId }}` (onError: continueErrorOutput) |
| 4c | Extract Fields | Parse using CSS selectors (see Field Extraction below) |
| 4d | Has valid job_id | IF node — checks if job has valid data (non-empty description, type_of_work, compensation, job_date) |
| 4e-false | Loop Over Items | Continue to next job ID if validation fails or HTTP error |
| 4e-true | Edit Fields | Map extracted fields to database column names |
| 4f-true | Insert rows in a table | INSERT into job_postings (onError: continueRegularOutput) |
| 4g | Wait | 10 second delay between iterations |
| 5 | Loop Back | Continue until all 5 job IDs processed |

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
- **Schedule**: Every 8 minutes
- **No retry logic**: If a job ID returns 404 or errors, the workflow continues to the next ID (error output loops back)
- **ON CONFLICT**: Uses PostgreSQL's upsert behavior to prevent duplicate job_id entries
- **Delay**: 10 second wait between HTTP requests to avoid rate limiting

---

### Workflow 0 — OnlineJobs.ph Job Sync (Recently Updated)

**Trigger**: Schedule Trigger (every 15 minutes)

**Purpose**: Scrape recently updated jobs from OnlineJobs.ph job search page and insert/update into `job_postings` table. This workflow captures jobs with old job_ids that have been updated by job posters, which the incremental new job sync would miss.

| Step | Node | Description |
|---|---|---|
| 1 | Schedule Trigger | Runs every 15 minutes |
| 2 | GET most recently updated job posts | GET `https://www.onlinejobs.ph/jobseekers/jobsearch?jobkeyword=&skill_tags=&gig=on&partTime=on&fullTime=on` (onError: continueErrorOutput) |
| 3 | Code in JavaScript | Extract job IDs from HTML using regex `/\/jobseekers\/job\/(\d+)/g`, deduplicate |
| 4 | Remove Duplicates + Execute a SQL query | Parallel: Remove Duplicate job IDs from results + `SELECT job_id FROM job_postings` |
| 5 | Merge | `joinMode: keepNonMatches` on `job_id` — filters out jobs already in database |
| 6 | Loop Over Items | Split In Batches to loop through remaining job IDs |
| 6a | Config | Store `jobId` from current iteration via Set node |
| 6b | GET HTML | GET `https://www.onlinejobs.ph/jobseekers/job/{{ $json.jobId }}` (onError: continueErrorOutput) |
| 6c | Extract Fields | Parse using CSS selectors (same as new job sync) |
| 6d | Has valid job_id | IF node — checks if job has valid data |
| 6e-false | Loop Over Items | Continue to next job ID if validation fails or HTTP error |
| 6e-true | Edit Fields | Map extracted fields to database column names |
| 6f-true | Insert rows in a table | INSERT into job_postings |
| 6g | Wait | 20 second delay between iterations |
| 7 | Loop Back | Continue until all job IDs processed |

**Field Extraction (CSS Selectors):**

Same as new job sync workflow:

| Field | CSS Selector |
|---|---|
| `job_title` | `h1` |
| `job_description` | `.job-description` |
| `job_skills` | `.card-worker-topskill` |
| `type_of_work` | `h3:contains("TYPE OF WORK") + p` |
| `compensation` | `h3:contains("WAGE / SALARY") + p` |
| `hours_per_week` | `h3:contains("HOURS PER WEEK") + p` |
| `job_date` | `h3:contains("DATE UPDATED") + p` |

**Duplicate Detection Logic:**

The workflow uses a Merge node with `joinMode: keepNonMatches` to compare job IDs from the search results against existing job_ids in the database. The Code node extracts job IDs from HTML using regex, deduplicates them, then the Merge node filters out any already in the database so only new jobs are processed.

**Implementation Details:**

- **Variable batch size**: Fetches all jobs from the job search page (number varies based on search results)
- **Schedule**: Every 15 minutes
- **ON CONFLICT**: Uses PostgreSQL's upsert to handle existing job_ids
- **Delay**: 20 second wait between HTTP requests to avoid rate limiting

**Why This Workflow is Needed:**

OnlineJobs.ph job posters can update job postings without changing the job_id. These updated jobs appear in the job search results but would not be captured by the incremental new job sync (which only processes sequential job_ids). This workflow ensures that recently updated jobs with old job_ids are synced and subscribers receive notifications for these updates.

---

### Workflow 1 — Subscription Manager

**Trigger**: Telegram Trigger node (on incoming message)

**Architecture**: Uses a Switch router to dispatch messages to different handlers based on command type. All incoming messages are logged to Supabase.

| Route | Command | Auth | Handler |
|---|---|---|---|
| `stats` | `/stats` | Admin only (username: `johnlloyddev`) | Show system stats |
| `admin` | `/admin` | Admin only (username: `johnlloyddev`) | Set keywords without limit |
| `keywordsub` | `/keywordsub` | Any user | Subscribe to keywords (max 3) |
| `unsub` | `/unsub` | Any user | Unsubscribe all keywords |
| Fallback | Any other message | Any user | Show help text |

#### Global Logging (all messages)

All incoming Telegram messages are logged to Supabase (`olj-alerts` table) with:
- `first_name`, `last_name`, `username`
- `keywords` (full message text)
- `execution_id`
- `chat_id`

#### Route: `/stats` (Admin Only)

| Step | Node | Description |
|---|---|---|
| 1 | Switch | Routes `/stats` messages |
| 2 | If admin1 | Validates `username == johnlloyddev` |
| 3 | count_job_postings | SQL: `SELECT COUNT(*) AS count_job_postings FROM job_postings; SELECT COUNT(DISTINCT(chat_id)) AS count_user_subscriptions FROM user_subscriptions;` |
| 4 | Aggregate | Aggregates all SQL results into single item |
| 5 | Send a text message4 | Sends stats message: `📊 Stats \| 🧾 Jobs: {count} • 👥 Subs: {count}` (HTML parse mode) |

#### Route: `/admin` (Admin Only)

| Step | Node | Description |
|---|---|---|
| 1 | Switch | Routes `/admin` messages |
| 2 | If admin | Validates `username == johnlloyddev` |
| 3 | Extract keywords2 | Extracts keywords from message (no 3-keyword limit) |
| 4 | Split Out + Delete table or rows | Splits keywords into items, deletes existing subscriptions for chat_id |
| 5 | Loop Over Items | Loops through keywords, inserts each into `user_subscriptions` |
| 6 | Set Payload | Formats confirmation message |
| 7 | Send a text message | Sends confirmation to user |

#### Route: `/keywordsub` (Any User)

| Step | Node | Description |
|---|---|---|
| 1 | Switch | Routes `/keywordsub` messages |
| 2 | If keywordsub | Checks message contains `keywordsub` |
| 3 | If keywordsub <= 3 | Validates keyword count (max 3 keywords allowed) |
| 3-false | Send a text message3 | Sends "Too many keywords" message |
| 4 | Extract keywords | Extracts comma-separated keywords from message |
| 5 | Split Out + Delete table or rows | Splits keywords into items, deletes existing subscriptions for chat_id |
| 6 | Loop Over Items | Loops through keywords, inserts each into `user_subscriptions` |
| 7 | Set Payload | Formats: `✅ Subscription Updated\n\nYour new keywords:\n• keyword1\n• keyword2\n• keyword3` |
| 8 | Send a text message | Sends confirmation to user |

**Command Format:**

- `/keywordsub keyword1, keyword2, keyword3`
- Keywords are comma-separated
- Maximum 3 keywords per command
- Whitespace around keywords is trimmed automatically
- This command REPLACES all existing keywords for the user (not additive)

#### Route: `/unsub` (Any User)

| Step | Node | Description |
|---|---|---|
| 1 | Switch | Routes `/unsub` messages |
| 2 | If unsub | Checks message contains `/unsub` |
| 3 | Delete table or rows1 | DELETE all keywords for this chat_id from `user_subscriptions` |
| 4 | Set Payload1 | Formats: `✅ Unsubscribed` |
| 5 | Send a text message1 | Sends confirmation to user |

#### Route: Fallback (Help)

| Step | Node | Description |
|---|---|---|
| 1 | Switch | Falls through to default output |
| 2 | Set Payload2 | Formats: `🪧 Help is here, here's an example command:\n\n/keywordsub virtual assistant, accountant, crm` |
| 3 | Send a text message2 | Sends help message to user |

**Implementation Details:**

- **Replace-all behavior**: The `/keywordsub` workflow deletes all existing keywords for the chat_id before adding new ones
- **Admin bypass**: Admin users (`johnlloyddev`) can use `/admin` to set keywords without the 3-keyword limit
- **Duplicate prevention**: Database has UNIQUE constraint on (chat_id, keyword) combination
- **Feedback**: User receives confirmation listing all their newly subscribed keywords
- **Logging**: Every message logged to Supabase for analytics

**Error Handling:**

- If more than 3 keywords provided via `/keywordsub`, user receives "Too many keywords" message
- Invalid or unrecognized commands trigger the help fallback
- Admin commands are silently ignored for non-admin users (Switch passes to fallback)

---

### Workflow 2 — Job Alert Notifier

**Architecture**: Split into Main Workflow (job processing + keyword matching) and Subworkflow (notification delivery with error handling)

**Main Workflow Trigger**: Schedule Trigger (every 20 seconds)

**Subworkflow Trigger**: Execute Workflow Trigger (called from Main Workflow)

#### Main Workflow Steps

| Step | Node | Description |
|---|---|---|
| 1 | Schedule Trigger | Runs every 20 seconds |
| 2 | Select 1 unprocessed job post | SELECT 1 unprocessed job post (WHERE is_processed = false, ORDER BY job_id, LIMIT 1) |
| 3 | Has unprocessed job post | IF — checks if job post exists (id exists AND id >= 0) |
| 4 | Execute a SQL query | `SELECT DISTINCT keyword FROM user_subscriptions` |
| 5 | Match keywords | Code node — matches keywords against job title and description using word-boundary regex |
| 6 | Transform to a list | Code node — transforms matched keywords into single array item |
| 7 | If | Check if any keywords matched (matched_keywords[0] not empty) |
| 8-true | Set required variables | Prepare payload with matched_keywords, job data |
| 9-true | Call subworkflow | Execute "Workflow 2 - Job Alert Notifier subworkflow" |
| 10-true | Set payload | Set id and is_processed = true for marking processed |
| 11-true | Update rows in a table | Mark job as processed |
| 8-false | Set payload1 | Set id and is_processed = true |
| 9-false | Update rows in a table1 | Mark job as processed (no match case) |

**Disabled nodes**: Webhook trigger and Re-trigger HTTP request nodes exist but are disabled.

#### Subworkflow Steps

| Step | Node | Description |
|---|---|---|
| 1 | When Executed by Another Workflow | Receives data from Main Workflow |
| 2 | Execute a SQL query1 | `SELECT chat_id, keyword FROM user_subscriptions WHERE keyword = ANY(string_to_array($1, '\|')::text[])` using matched keywords |
| 3 | Remove Duplicates | Deduplicate chat_ids (one message per user) |
| 4 | Loop Over Items | Loop through each subscriber |
| 5-true | Set payload | Set id and is_processed = true (runs once) |
| 6-true | Update rows in a table | Mark job as processed |
| 5-loop | Send a text message | Send HTML-formatted alert to subscriber (onError: continueErrorOutput) |
| 5-loop-error | If blocked | Check if error contains "bot was blocked by the user" |
| 5-loop-error-true | Delete table or rows | DELETE all subscriptions for the blocked chat_id |
| 5-loop-error-false | Stop and Error | Stop with error message |
| 5-loop-success | Wait | 0.25 second delay between messages |
| 6 | Loop Back | Continue until all subscribers notified |

**Key Benefits of Split Architecture:**
- **Better logging**: Subworkflow only saves successful executions, making it easier to track notification delivery
- **Error isolation**: Notification failures don't affect job processing logic
- **Blocked user cleanup**: Subworkflow automatically detects when a user has blocked the bot and removes their subscriptions

**Keyword Matching Algorithm:**

```javascript
const jobData = $('Select 1 unprocessed job post').first().json;

const description = (jobData.job_description || "").toLowerCase();
const title = (jobData.job_title || "").toLowerCase();
const fullText = title + " " + description;

const allKeywords = $input.all().map(item => item.json.keyword);

const matchedKeywords = allKeywords.filter(kw => {
  const escapedKw = kw.toLowerCase().replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const regex = new RegExp(`\\b${escapedKw}\\b`, 'i');
  return regex.test(fullText);
});

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

**Blocked User Auto-Cleanup:**

When a Telegram message fails to send, the subworkflow checks if the error contains "bot was blocked by the user". If so, it automatically deletes all subscriptions for that chat_id from `user_subscriptions`, keeping the database clean of stale subscriptions.

**Processing Logic:**

- **Polling approach**: Main workflow checks for unprocessed jobs every 20 seconds
- **One job at a time**: Main workflow processes only 1 unprocessed job per execution
- **Always marks processed**: Even if no keywords match, job is marked as `is_processed = true` to prevent re-processing
- **Duplicate prevention**: Subworkflow uses `Remove Duplicates` node to ensure each user receives only one notification per job
- **HTML sanitization**: Notification messages sanitize special characters in job fields to prevent HTML parsing errors

---

## Telegram Bot Commands

| Command | Auth | Description | Example |
|---|---|---|---|
| `/keywordsub <keywords>` | Any user | Replace all subscriptions with new keywords (comma-separated, max 3) | `/keywordsub n8n, react, remote` |
| `/unsub` | Any user | Unsubscribe from all keywords | `/unsub` |
| `/stats` | Admin only | Show system stats (job count, subscriber count) | `/stats` |
| `/admin <keywords>` | Admin only | Set keywords without the 3-keyword limit | `/admin keyword1, keyword2, keyword3, keyword4` |
| Any other message | Any user | Shows help text with example command | `hello` |

**Usage Notes:**
- Keywords are comma-separated in a single command
- Maximum 3 keywords allowed per `/keywordsub` submission (exceeding shows "Too many keywords" error)
- `/keywordsub` REPLACES all existing keywords (not additive)
- `/unsub` removes all subscriptions and sends confirmation
- `/stats` and `/admin` are restricted to admin users (verified by Telegram username)
- Whitespace around keywords is automatically trimmed
- Unrecognized commands/messages show help text with example

---

## Notification Format

```html
<b>🔔 New Job Match!</b>

<b>{job_title (sanitized)}</b>

📝 <b>Description:</b>
{job_description.substring(0, 120) (sanitized)}...

💼 <b>Type:</b> {type_of_work (HTML entity encoded)}
💰 <b>Pay:</b> {compensation (sanitized)}
⏰ <b>Hours:</b> {hours_per_week}

👉 <a href="https://www.onlinejobs.ph/jobseekers/job/{job_id}">
Apply here!
</a>
```

**HTML Sanitization:**

The subworkflow sanitizes job fields to prevent HTML parsing errors in Telegram:
- **job_title, job_description, compensation**: Strips `&`, `<`, `>`, `"` characters
- **type_of_work**: Encodes as proper HTML entities (`&amp;`, `&lt;`, `&gt;`, `&quot;`)
- **hours_per_week**: Used as-is (no sanitization)

**Implementation Details:**

- Uses Telegram HTML parse_mode for formatting
- **Bold text**: Job title and field labels
- **Emojis**: 🔔, 📝, 💼, 💰, ⏰, 👉 for visual hierarchy
- **Description**: First 120 characters with ellipsis (...)
- **Interactive link**: "Apply here!" is clickable and opens job posting
- **Structured layout**: Key job details clearly separated for quick scanning

---

## Tech Stack

| Layer | Tool |
|---|---|
| Automation / workflows | n8n (self-hosted) |
| Database | PostgreSQL |
| Messaging | Telegram Bot API |
| Job data source | OnlineJobs.ph (scraping via HTTP Request + HTML parsing) |
| HTML parsing | n8n HTML Extract (CSS Selectors) |
| Logging / analytics | Supabase |

---

## Environment Variables

### Sync Workflow Configuration (Workflow 0 - New Jobs)

| Variable | Description | Value |
|---|---|---|
| `SYNC_SCHEDULE_MINUTES` | How often to run the new job sync | `8` |
| `SYNC_BATCH_SIZE` | Max jobs to fetch per execution | `5` |
| `HTTP_REQUEST_DELAY_SECONDS` | Delay between HTTP requests | `10` |

### Sync Workflow Configuration (Workflow 0 - Recently Updated)

| Variable | Description | Value |
|---|---|---|
| `SYNC_UPDATED_SCHEDULE_MINUTES` | How often to run the recently updated job sync | `15` |
| `HTTP_REQUEST_DELAY_SECONDS` | Delay between HTTP requests | `20` |

### Subscription Manager Configuration (Workflow 1)

| Variable | Description | Value |
|---|---|---|
| `MAX_KEYWORDS_PER_COMMAND` | Maximum keywords allowed in /keywordsub | `3` |
| `ADMIN_USERNAME` | Telegram username allowed to use admin commands | `johnlloyddev` |

### Alert Notifier Configuration (Workflow 2)

| Variable | Description | Value |
|---|---|---|
| `POLL_INTERVAL_SECONDS` | How often to check for unprocessed jobs | `20` |
| `TELEGRAM_MESSAGE_DELAY_SECONDS` | Delay between Telegram messages | `0.25` |
| `JOB_DESCRIPTION_TRUNCATE_CHARS` | Number of characters to show in alert | `120` |

### Required Credentials

| Variable | Description |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Bot token from @BotFather |
| `DATABASE_URL` | PostgreSQL connection string: `postgresql://job_alert_client:password@localhost:5432/oljalerts` |
| `SUPABASE_API_KEY` | Supabase API key for logging (used in Workflow 1) |
| `N8N_WEBHOOK_URL` | Base URL for n8n webhook endpoints (if self-hosted) |

---

## Constraints & Limitations

### Scraping & Data Sync (Workflow 0 - New Jobs)
- **Rate limiting risk** — Scraping every 8 minutes with 5 requests per batch. Monitor for 429 errors and adjust schedule or delay if needed.
- **CSS selector fragility** — HTML structure changes on OnlineJobs.ph will break field extraction. Needs maintenance when job pages change.
- **No sequential ID tracking** — The workflow simply processes next 5 job IDs regardless of gaps or 404s. This may skip valid jobs if there are large gaps.
- **No retry logic** — If a job ID returns 404 or errors, the workflow continues to the next ID without retrying.
- **No company name extraction** — Currently not extracting employer name. Can be added if needed.
- **Failed jobs are skipped** — Jobs that fail validation (missing required fields) are silently skipped and not logged.

### Scraping & Data Sync (Workflow 0 - Recently Updated)
- **Rate limiting risk** — Scraping every 15 minutes with variable request count. Monitor for 429 errors.
- **CSS selector fragility** — HTML structure changes on OnlineJobs.ph (both job search page and individual job pages) will break field extraction.
- **Variable batch size** — The number of jobs processed depends on the job search page results, which can vary significantly.
- **No retry logic** — If a job ID returns 404 or errors, the workflow continues to the next ID without retrying.
- **Potential for missed updates** — Only captures recently updated jobs that appear on the job search page. Older updates may not be visible in search results.

### Subscription Manager (Workflow 1)
- **Replace-all behavior** — The `/keywordsub` command deletes all existing keywords before adding new ones. Users cannot add/remove individual keywords.
- **No subscriptions list command** — Users cannot view their current subscriptions via the bot.
- **Admin hardcoded** — Admin username (`johnlloyddev`) is hardcoded in the workflow, not configurable via environment variable.
- **Supabase dependency** — Logging requires Supabase connection. If Supabase is unavailable, messages are still processed but logging fails.

### Alert Notifier (Workflow 2 + Subworkflow)
- **One job per execution** — Only processes 1 unprocessed job per 20-second cycle. May not keep up with high-volume job postings.
- **Polling vs triggers** — Uses polling approach (every 20 seconds) instead of PostgreSQL triggers. May introduce slight delay in notifications.
- **Telegram rate limit** — Telegram allows ~30 messages/second per bot. Current 0.25 second delay is well within limits.
- **Blocked user auto-cleanup** — Only detects blocks when a notification is attempted. Users who block without any matching jobs won't be cleaned up.
- **Disabled re-trigger** — The webhook-based re-trigger mechanism exists but is disabled.

---

## Future Improvements

### Sync Workflow (Workflow 0 - New Jobs)
- **Company name extraction** — Add `company` field to track employer names
- **Dynamic job listing page scraping** — Instead of incremental ID fetching, scrape the job listings page
- **Retry logic** — Add retry mechanism for failed HTTP requests with exponential backoff
- **Sequential gap handling** — Implement logic to track and handle large gaps in job IDs
- **Error logging** — Add `sync_errors` table to log failed job IDs for manual review

### Sync Workflow (Workflow 0 - Recently Updated)
- **Company name extraction** — Add `company` field to track employer names
- **Enhanced duplicate detection** — Track job content hashes to detect updates even when job_date hasn't changed
- **Optimized job search queries** — Add filters to job search URL (e.g., date range, location) to reduce processing
- **Retry logic** — Add retry mechanism for failed HTTP requests with exponential backoff
- **Error logging** — Add `sync_errors` table to log failed job IDs for manual review

### Subscription Manager (Workflow 1)
- **Add/remove individual keywords** — Implement `/addkeyword` and `/removekeyword` commands for granular control
- **List subscriptions command** — Add `/listkeywords` command to show current subscriptions
- **Configurable admin** — Move admin username to environment variable instead of hardcoding
- **Keyword categories / tags** — Let users subscribe to predefined categories instead of free-text keywords
- **Keyword suggestions** — Suggest popular keywords based on existing job postings
- **Supabase dashboard** — Build analytics dashboard from logged messages

### Alert Notifier (Workflow 2)
- **PostgreSQL triggers** — Replace polling with database triggers for real-time notifications
- **Batch processing** — Process multiple unprocessed jobs per execution to handle high volume
- **Alert frequency control** — Daily digest mode vs. instant alerts (user preference)
- **User feedback** — Allow users to like/dislike jobs to improve matching relevance
- **Notification throttling** — Prevent spam by limiting notifications per user per day
- **Enable re-trigger** — Enable the webhook-based re-trigger for faster processing

### General
- **Admin dashboard** — Simple n8n or web UI to view subscriber stats and recent alerts
- **OLJAlerts web landing page** — Public page explaining the bot with a `/keywordsub` deep link
- **Analytics** — Track popular keywords, job posting trends, user engagement from Supabase logs
- **Multi-admin support** — Support multiple admin users with configurable permissions

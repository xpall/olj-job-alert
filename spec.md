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
   - [Workflow 1 — Subscription Manager (TODO)](#workflow-1--subscription-manager-todo)
   - [Workflow 2 — Job Alert Notifier (TODO)](#workflow-2--job-alert-notifier-todo)
6. [Telegram Bot Commands (TODO)](#telegram-bot-commands-todo)
7. [Notification Format (TODO)](#notification-format-todo)
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
    │          │      │   (TODO) │      │   (TODO) │
    │Scheduled │      │Telegram  │      │Triggered │
    │Trigger   │      │Trigger   │      │by INSERT │
    └────┬─────┘      └────┬─────┘      └────┬─────┘
         │                 │                 │
         ▼                 ▼                 ▼
   OnlineJobs.ph        Telegram User      Telegram API
   (HTTP Scrape)        (Commands)      (Notifications)
```

**Design Philosophy**: Fully decoupled modular architecture where each workflow operates independently through PostgreSQL as the central data bus.

**Workflow Independence:**

- **Workflow 0 — OnlineJobs.ph Job Sync**: Scheduled trigger (every 5-10 min). Scrapes new job postings from OnlineJobs.ph using HTTP GET requests, parses HTML with CSS selectors, and batch inserts into `job_postings` table. Implements intelligent stop conditions (batch limit or consecutive 404s) and retry logic. **No dependency on other workflows.**

- **Workflow 1 — Subscription Manager (TODO)**: Handles `/subscribe`, `/unsubscribe`, and `/subscriptions` commands from Telegram users. Reads and writes to `user_subscriptions`. **No dependency on other workflows.**

- **Workflow 2 — Job Alert Notifier (TODO)**: Triggered when a new row is inserted into `job_postings` (via Postgres trigger or polling). Queries matching subscribers and sends Telegram notifications. **Only depends on PostgreSQL triggers, not on Workflow 0.**

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

**Trigger**: Schedule Trigger (every `SYNC_SCHEDULE_MINUTES` minutes, default: 5-10)

**Purpose**: Incrementally scrape new job postings from OnlineJobs.ph and batch insert into `job_postings` table.

| Step | Node | Description |
|---|---|---|
| 1 | Schedule Trigger | Runs every N minutes (configurable) |
| 2 | Postgres | `SELECT job_id FROM job_postings ORDER BY job_id DESC LIMIT 1` (get last processed ID) |
| 3 | Code | Initialize variables: `last_id` = result, `batch_size` = `SYNC_BATCH_SIZE`, `consecutive_404s` = 0, `counter` = 0, `failed_jobs` = [] |
| 4 | Loop | While `counter < batch_size` AND `consecutive_404s < MAX_CONSECUTIVE_404S` |
| 4a | HTTP Request | GET `https://www.onlinejobs.ph/jobseekers/job/{{ $json.last_id + 1 }}` |
| 4b | Switch | Route by status code: 200, 404, or error |
| 4c-200 | HTML Extract | Parse using CSS selectors (see Field Extraction below) |
| 4d-200 | Postgres | `INSERT INTO job_postings (...) VALUES (...)` with `ON CONFLICT (job_id) DO NOTHING` |
| 4e-200 | Code | `counter++`, `last_id++`, `consecutive_404s = 0` |
| 4c-404 | Code | `consecutive_404s++`, `last_id++` |
| 4c-error | Code | Retry logic (up to `MAX_RETRIES_PER_JOB` times), if still fail: log to `failed_jobs`, `last_id++` |
| 5 | IF | Check if `failed_jobs.length > 0` |
| 6 | Postgres (optional) | Log failed job IDs to a `sync_errors` table for manual review |
| 7 | Stop | End workflow |

**Field Extraction (CSS Selectors):**

| Field | CSS Selector |
|---|---|
| `job_title` | `h1.job-title` (adjust based on actual HTML) |
| `job_description` | `.job-description` |
| `job_skills` | `.job-skills` (comma-separated text) |
| `type_of_work` | `.type-of-work` |
| `compensation` | `.compensation` |
| `hours_per_week` | `.hours-per-week` |
| `job_date` | `.job-date` (parse to DATE format) |

**Retry Logic for Failed Requests:**

For each failed HTTP request (non-200, non-404):
- Retry up to `MAX_RETRIES_PER_JOB` times (default: 3)
- Use exponential backoff: 1s, 2s, 4s delays between retries
- If all retries fail: increment `last_id`, log job_id to `failed_jobs`, continue
- This ensures the sync continues even with intermittent network issues

**Stop Conditions:**

The workflow stops when **either** condition is met:
1. Batch size reached: `counter >= SYNC_BATCH_SIZE` (default: 10-20 jobs)
2. Consecutive 404s threshold: `consecutive_404s >= MAX_CONSECUTIVE_404S` (default: 5)

This handles sequential IDs with gaps — if we hit 5 consecutive 404s, we've likely reached the end of available job postings.

**Rate Limiting Considerations:**

- HTTP timeout: `HTTP_TIMEOUT_MS` (default: 10 seconds)
- Small batch size (10-20) prevents overwhelming the server
- Exponential backoff on retries respects the server
- If you see rate-limit errors, increase `SYNC_SCHEDULE_MINUTES` or decrease `SYNC_BATCH_SIZE`

---

### Workflow 1 — Subscription Manager (TODO)

**Trigger**: Telegram Trigger node (on incoming message)

| Step | Node | Description |
|---|---|---|
| 1 | Telegram Trigger | Receives all incoming bot messages |
| 2 | Switch | Routes by command: `/subscribe`, `/unsubscribe`, `/subscriptions` |
| 3a | Code | Parses keyword from `/subscribe <keyword>`, sanitizes input |
| 4a | Postgres | `INSERT INTO user_subscriptions` with `ON CONFLICT DO NOTHING` |
| 5a | Telegram | Replies: `✅ Subscribed to "<keyword>"` |
| 3b | Code | Parses keyword from `/unsubscribe <keyword>` |
| 4b | Postgres | `DELETE FROM user_subscriptions WHERE chat_id = ? AND keyword = ?` |
| 5b | Telegram | Replies: `❌ Unsubscribed from "<keyword>"` |
| 3c | Postgres | `SELECT keyword FROM user_subscriptions WHERE chat_id = ?` |
| 4c | Telegram | Replies with formatted list of active subscriptions |

---

### Workflow 2 — Job Alert Notifier (TODO)

**Trigger**: Postgres Trigger node on `INSERT` to `job_postings`
*(Fallback: Schedule Trigger every 1–2 minutes, querying rows where `created_at > NOW() - INTERVAL '2 minutes'`)*

| Step | Node | Description |
|---|---|---|
| 1 | Postgres Trigger | Fires on new row inserted into `job_postings` |
| 2 | Postgres | Query `user_subscriptions` using `ILIKE` match against job_title + job_description |
| 3 | IF | Stops execution if no subscribers matched |
| 4 | Split In Batches | Iterates one subscriber at a time |
| 5 | Telegram | Sends formatted alert to each `chat_id` |

**Keyword match query:**

```sql
SELECT DISTINCT chat_id
FROM user_subscriptions
WHERE '{{ $json.job_title }} {{ $json.job_description }}'
  ILIKE '%' || keyword || '%';
```

---

## Telegram Bot Commands (TODO)

| Command | Description | Example |
|---|---|---|
| `/subscribe <keyword>` | Subscribe to a keyword | `/subscribe n8n` |
| `/unsubscribe <keyword>` | Remove a keyword subscription | `/unsubscribe n8n` |
| `/subscriptions` | List all active subscriptions | `/subscriptions` |
| `/start` | Welcome message with usage instructions | `/start` |

---

## Notification Format (TODO)

```
🔔 New job match for "n8n"

Senior n8n Automation Developer
Acme Remote Co.

Apply here → https://www.onlinejobs.ph/jobseekers/job/123456
```

Fields pulled from `job_postings`: `job_title`, `compensation` (optional). The URL is constructed from `job_id`: `https://www.onlinejobs.ph/jobseekers/job/{job_id}`

**Enhanced format option:**
```
🔔 New job match for "n8n"

📌 Senior n8n Automation Developer
💰 PHP 50,000 - 80,000 / month
⏱️ Full-time, 40 hours/week

📝 Senior n8n Automation Developer needed for remote position...
[truncated description]

Apply here → https://www.onlinejobs.ph/jobseekers/job/123456
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

| Variable | Description | Default |
|---|---|---|
| `SYNC_SCHEDULE_MINUTES` | How often to run the job sync (minutes) | `5` |
| `SYNC_BATCH_SIZE` | Max jobs to fetch per execution | `20` |
| `MAX_CONSECUTIVE_404S` | Stop after this many consecutive 404s | `5` |
| `MAX_RETRIES_PER_JOB` | Retry failed requests this many times | `3` |
| `HTTP_TIMEOUT_MS` | HTTP request timeout in milliseconds | `10000` |

### Alert Workflow Configuration (Workflows 1 & 2)

| Variable | Description |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Bot token from @BotFather |
| `DATABASE_URL` | PostgreSQL connection string |
| `N8N_WEBHOOK_URL` | Base URL for n8n webhook endpoints (if self-hosted) |

---

## Constraints & Limitations

### Scraping & Data Sync (Workflow 0)
- **Rate limiting risk** — Scraping every 5-10 minutes may trigger anti-bot measures. Monitor for 429 errors and adjust `SYNC_SCHEDULE_MINUTES` if needed.
- **CSS selector fragility** — HTML structure changes on OnlineJobs.ph will break field extraction. Needs maintenance when job pages change.
- **Sequential IDs with gaps** — Job IDs are sequential but may skip numbers (deleted jobs, drafts). The workflow handles this via `MAX_CONSECUTIVE_404S` threshold.
- **No company name extraction** — Currently not extracting employer name. Can be added if needed.
- **Failed jobs are skipped** — After 3 retries, failed jobs are skipped and not retried. Check `sync_errors` table for review.

### Alert System (Workflows 1 & 2)
- **Keyword matching is simple substring search** — no fuzzy matching or synonyms. A subscription to `react` will also match `react native` and `proactive`.
- **No deduplication across runs** — if using polling fallback, the query window must be carefully managed to avoid duplicate alerts.
- **Telegram rate limit** — Telegram allows ~30 messages/second per bot. Use `Split In Batches` with a small delay for large subscriber counts.
- **User input sanitization** — keywords containing SQL wildcard characters (`%`, `_`) must be escaped before storage to prevent unintended broad matches.
- **Single keyword per subscription row** — users subscribing to multiple keywords create one row each. This is intentional for easy management.

---

## Future Improvements

### Sync Workflow (Workflow 0)
- **Company name extraction** — Add `company` field to track employer names
- **Dynamic job listing page scraping** — Instead of incremental ID fetching, scrape the job listings page for a more robust discovery mechanism
- **Incremental deduplication check** — Use HTTP HEAD requests before full GET to avoid downloading duplicate content
- **Scrape job listings for efficiency** — Fetch multiple jobs in one request from a listings page instead of individual job pages
- **RSS feed monitoring** — If OnlineJobs.ph provides RSS feeds, use instead of scraping
- **Verify CSS selectors** — **TODO**: Inspect actual OnlineJobs.ph job page HTML and update CSS selectors accordingly

### Alert System (Workflows 1 & 2)
- **Multi-keyword subscriptions** — allow comma-separated keywords in a single `/subscribe` command
- **Keyword categories / tags** — let users subscribe to predefined categories instead of free-text keywords
- **Alert frequency control** — daily digest mode vs. instant alerts
- **Duplicate prevention flag** — `notified` boolean on `job_postings` to guarantee at-most-once delivery
- **Admin dashboard** — simple n8n or web UI to view subscriber stats and recent alerts
- **OLJAlerts web landing page** — public page explaining the bot with a `/start` deep link
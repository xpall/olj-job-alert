# OLJAlerts 🚨

Automated job alerts for OnlineJobs.ph — get notified on Telegram when jobs matching your keywords are posted.

**Perfect for:** Job hunters who want instant notifications without constantly checking job boards.

**Get Started:** https://t.me/OLJAlertBot

---

## What It Does

1. **Scrapes** OnlineJobs.ph every 2 minutes for new job postings
2. **Stores** jobs in a database
3. **Lets you** subscribe to keywords via Telegram bot (https://t.me/OLJAlertBot)
4. **Sends** you a Telegram message when a matching job is posted

---

## What You Need

- **Linux server** (self-hosted)
- **n8n** (automation tool)
- **PostgreSQL** (database)
- **Telegram Bot Token** (from @BotFather)
- **Basic tech skills** (you got this!)

---

## How It Works

```
OnlineJobs.ph → n8n → PostgreSQL → n8n → Telegram → You
   (new jobs)    (scrape)   (store)    (match)   (alert)
```

Think of it as a pipeline:
- **Stage 1:** Scrapes job listings automatically
- **Stage 2:** Stores everything in a database
- **Stage 3:** Matches jobs against your keywords
- **Stage 4:** Sends you alerts on Telegram

---

## Project Status

**✅ Complete:**
- Job Sync (Workflow 0) — Scrapes and stores job postings every 2 minutes
- Subscription Manager (Workflow 1) — Let you manage keywords via Telegram
- Alert Notifier (Workflow 2 + Subworkflow) — Sends notifications when jobs match

---

## Quick Setup (High Level)

1. **Set up the stack:**
   - Install n8n on your Linux server
   - Set up PostgreSQL database
   - Create a Telegram bot via @BotFather

2. **Create the database:**
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

    CREATE TABLE user_subscriptions (
      id          SERIAL PRIMARY KEY,
      chat_id     BIGINT NOT NULL,
      keyword     TEXT NOT NULL,
      created_at  TIMESTAMPTZ DEFAULT NOW(),
      UNIQUE(chat_id, keyword)
    );

    CREATE INDEX idx_job_postings_is_processed ON job_postings(is_processed);
    ```

3. **Build Workflow 0 in n8n:**
   - Create a schedule trigger (every 5-10 minutes)
   - Add HTTP Request nodes to fetch jobs
   - Use HTML Extract to parse job details
   - Insert into PostgreSQL database

4. **Test it:**
   - Run the workflow
   - Check the database for job postings
   - Verify it's scraping correctly

---

## Next Steps

All three workflows are complete and ready to use:

1. **Workflow 0** automatically scrapes job postings from OnlineJobs.ph every 2 minutes
2. **Workflow 1** lets you subscribe to keywords via Telegram using `/keywordsub keyword1, keyword2, keyword3`
3. **Workflow 2** automatically notifies you when a job matching your keywords is posted (uses word-boundary regex matching for precise keyword matching, avoiding false positives like 'ai' matching 'PAID')

**Start using the bot:** https://t.me/OLJAlertBot

Simply start all three workflows in n8n, open the Telegram bot, and subscribe to your keywords to start receiving job alerts!

See `spec.md` for detailed technical specifications and implementation details.

---

## Notes

- **Rate limiting:** Current settings scrape 5 jobs every 2 minutes with 0.05s delays between requests
- **Telegram commands:** Use `/keywordsub keyword1, keyword2, keyword3` to set your subscriptions (max 3 keywords)
- **Modular design:** Each workflow operates independently through PostgreSQL as the data bus
- **Replace-all behavior:** The `/keywordsub` command replaces all existing keywords, not additive
- **HTML formatting:** Notifications use HTML formatting with emojis for better readability
- **Job validation:** Only complete job postings (with description, type, compensation, date) are stored
- **Word-boundary matching:** Keywords now match whole words only (e.g., 'ai' matches 'AI specialist' but not 'PAID', 'TRAIN', 'MAINTAIN')

---

**Questions?** Check `spec.md` for the full technical details.

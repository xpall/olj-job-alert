# OLJAlerts 🚨

Automated job alerts for OnlineJobs.ph — get notified on Telegram when jobs matching your keywords are posted.

**Perfect for:** Job hunters who want instant notifications without constantly checking job boards.

---

## What It Does

1. **Scrapes** OnlineJobs.ph every 5-10 minutes for new job postings
2. **Stores** jobs in a database
3. **Lets you** subscribe to keywords (like "n8n", "react", "remote")
4. **Sends** you a Telegram message when a matching job is posted

---

## What You Need

- **Linux server** (self-hosted)
- **n8n** (automation tool)
- **PostgreSQL** (database)
- **Telegram Bot Token** (from @BotFather)
- **Basic tech skills** (you said you're experienced, so you got this!)

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

**✅ Ready to Build:**
- Job Sync (Workflow 0) — Scrapes and stores job postings

**🔧 Coming Soon:**
- Subscription Manager (Workflow 1) — Let you manage keywords via Telegram
- Alert Notifier (Workflow 2) — Sends notifications when jobs match

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
     created_at       TIMESTAMPTZ DEFAULT NOW()
   );
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

Once Workflow 0 is working, you'll build:
- Workflow 1: Telegram bot to subscribe to keywords
- Workflow 2: Automatic alerts when jobs match your keywords

See `spec.md` for detailed technical specifications.

---

## Notes

- **Rate limiting:** Don't scrape too fast (default: 5-10 minutes)
- **CSS selectors:** You'll need to inspect OnlineJobs.ph HTML to get the right selectors
- **Modular design:** Each workflow is independent — build one at a time

---

**Questions?** Check `spec.md` for the full technical details.

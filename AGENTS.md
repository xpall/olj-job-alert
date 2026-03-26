# AGENTS.md

This guide provides conventions and best practices for agentic coding working on the OLJAlerts project.

---

## Project Overview

OLJAlerts is an automated job alert system built with n8n workflows, PostgreSQL, and Telegram Bot. The system scrapes OnlineJobs.ph for job postings and notifies users when jobs match their subscribed keywords.

**Tech Stack:**
- Automation: n8n (self-hosted)
- Database: PostgreSQL
- Messaging: Telegram Bot API
- Data Source: OnlineJobs.ph (HTTP scraping)

---

## Build/Lint/Test Commands

**Note:** This is a workflow-based n8n project. No traditional build/lint/test commands exist.

**Database Setup:**
```bash
# Run database setup script
psql -U postgres -f database/database_setup.sql

# Verify tables and ownership
psql -U postgres -d oljalerts -c "\dt"
psql -U postgres -d oljalerts -c "\du"
```

**Workflow Testing:**
- Test workflows manually via n8n UI: Execute individual workflows
- Verify data flow: Check PostgreSQL tables after workflow execution
- Monitor logs: Use n8n execution history for debugging

**Single Workflow Test:**
- Open n8n UI → Select workflow → Click "Execute Workflow" button
- Monitor execution in real-time using n8n's execution viewer
- Check PostgreSQL for expected data changes

**Validation:**
```sql
-- Check job postings count
SELECT COUNT(*) FROM job_postings;

-- Check unprocessed jobs
SELECT COUNT(*) FROM job_postings WHERE is_processed = false;

-- Check user subscriptions
SELECT * FROM user_subscriptions ORDER BY created_at DESC LIMIT 10;
```

---

## Code Style Guidelines

### n8n Workflow Conventions

**Workflow Naming:**
- Format: `Workflow {N} - {Descriptive Name}.json`
- Use descriptive names indicating workflow purpose
- Example: `Workflow 0 - OnlineJobs.ph Job Sync.json`

**Node Naming:**
- Use clear, descriptive names (e.g., "Schedule Trigger", "GET HTML", "Extract Fields")
- Follow action-verb pattern for active nodes (e.g., "Execute Workflow", "Remove Duplicates")
- PostgreSQL nodes: Include operation type in name (e.g., "INSERT job_postings", "SELECT unprocessed jobs")

**Node Positioning:**
- Arrange nodes in logical left-to-right flow
- Keep related nodes aligned horizontally
- Group related operations visually (e.g., database operations together)

### JavaScript Code (n8n Code Nodes)

**Formatting:**
- Use double quotes for strings
- Use 2-space indentation (n8n default)
- Add comments explaining complex logic
- Use template literals for string interpolation

**Variable Access Pattern:**
```javascript
// Access data from previous nodes
const jobData = $('Node Name').first().json;

// Access all input items
const allItems = $input.all().map(item => item.json.field);

// Return transformed data
return [{ json: { field: value } }];
```

**Error Handling:**
```javascript
// Always provide default values to prevent null/undefined errors
const field = (data.field || "").toLowerCase();

// Use try-catch for operations that may fail
try {
  const result = processItem(item);
  return result;
} catch (error) {
  console.error('Error processing item:', error);
  return null; // Skip failed items
}
```

**Common Patterns:**
```javascript
// Array transformation
return items.map(item => ({ json: { transformed: item.value } }));

// Filtering
const filtered = items.filter(item => item.value > threshold);
return filtered.map(item => ({ json: item }));

// Data extraction with defaults
const description = (data.job_description || "").toLowerCase();
const title = (data.job_title || "").toLowerCase();
```

### CSS Selectors (HTML Extraction)

**Selector Format:**
- Use lowercase selector names (e.g., `jobTitle`, `jobDescription`)
- Use snake_case for database field names (e.g., `job_title`, `job_description`)
- Use kebab-case for CSS classes (e.g., `.job-description`, `.card-worker-topskill`)

**Common Patterns:**
```javascript
// Simple class selector
.job-description

// Combinators for related elements
h3:contains("TYPE OF WORK") + p

// Multiple selector fallbacks
h1, .title, .job-title
```

### PostgreSQL Conventions

**Naming:**
- Tables: `snake_case` (e.g., `job_postings`, `user_subscriptions`)
- Columns: `snake_case` (e.g., `job_id`, `created_at`)
- Indexes: `idx_{table}_{column}` (e.g., `idx_job_postings_job_id`)
- Constraints: Named explicitly for clarity

**Table Structure:**
```sql
CREATE TABLE table_name (
  id               SERIAL PRIMARY KEY,
  foreign_key_id   BIGINT NOT NULL,
  text_field       TEXT,
  boolean_field    BOOLEAN DEFAULT FALSE,
  date_field       DATE,
  timestamp_field  TIMESTAMPTZ DEFAULT NOW(),
  created_at       TIMESTAMPTZ DEFAULT NOW()
);
```

**SQL Query Style:**
- Use UPPERCASE for SQL keywords
- Use lowercase for table/column names
- Add comments for complex queries
- Use prepared statements in n8n PostgreSQL nodes

**Upsert Pattern:**
```sql
INSERT INTO table_name (id, field1, field2)
VALUES ($1, $2, $3)
ON CONFLICT (id) DO UPDATE SET
  field1 = EXCLUDED.field1,
  field2 = EXCLUDED.field2
```

### HTTP Request Conventions

**Request Naming:**
- Include HTTP method and action: `GET job posts`, `POST subscription`
- Use descriptive names indicating resource and operation

**Error Handling:**
- Set `onError: continueErrorOutput` to continue workflow on errors
- Use IF nodes to validate responses before processing
- Add Wait nodes between requests for rate limiting (0.05-0.25 seconds)

### Telegram Bot Conventions

**Message Formatting:**
- Use HTML parse_mode for rich formatting
- Include emojis for visual hierarchy: 🔔 📝 💼 💰 ⏰ 👉
- Use `<b>` for bold text
- Use `<a>` for links with descriptive text
- Truncate long text (e.g., first 120 characters of description)

**Message Structure:**
```html
<b>🔔 New Job Match!</b>

<b>{job_title}</b>

📝 <b>Description:</b>
{truncated_description}

💼 <b>Type:</b> {type_of_work}
💰 <b>Pay:</b> {compensation}

👉 <a href="{job_url}">Apply here!</a>
```

---

## Architecture Principles

### Decoupled Workflows
- Each workflow operates independently through PostgreSQL as data bus
- No direct workflow-to-workflow communication
- Workflows communicate only through database INSERT/SELECT operations
- Enable/disable workflows without affecting others

### Error Isolation
- Use `continueErrorOutput` on HTTP Request nodes to prevent workflow failure
- Validate data before processing with IF nodes
- Log errors for debugging without stopping entire workflow

### Rate Limiting
- HTTP requests: Add 0.05-0.25 second Wait nodes between requests
- Telegram messages: Add 0.25 second Wait nodes between messages
- Monitor for 429 errors and adjust delays if needed

### Data Validation
- Validate all required fields before database INSERT
- Use IF nodes to check for non-empty values
- Skip invalid data silently or log for manual review

---

## Testing Guidelines

### Workflow Testing
1. **Manual Testing:** Execute workflows via n8n UI
2. **Data Verification:** Check PostgreSQL tables after execution
3. **Log Review:** Monitor n8n execution history for errors
4. **End-to-End:** Test full pipeline (scrape → store → match → notify)

### Common Tests
- Verify new jobs appear in `job_postings` table
- Check Telegram notifications are sent for matching jobs
- Confirm `is_processed` flag is set correctly
- Validate keyword matching is case-insensitive and word-boundary
- Test duplicate job_id handling (ON CONFLICT)

### Debugging Tips
- Use n8n execution viewer to trace data flow
- Check PostgreSQL logs for query errors
- Monitor job sync execution frequency
- Verify Telegram webhook is configured correctly

---

## File Organization

```
/
├── database/
│   └── database_setup.sql    # PostgreSQL schema and setup
├── n8n/
│   ├── Workflow 0 - OnlineJobs.ph Job Sync.json
│   ├── Workflow 0 - OnlineJobs.ph Job Sync recently-updated.json
│   ├── Workflow 1 - Subscription Manager.json
│   ├── Workflow 2 - Job Alert Notifier.json
│   └── Workflow 2 - Job Alert Notifier subworkflow.json
├── README.md                 # User-facing documentation
├── spec.md                   # Technical specification
└── AGENTS.md                 # This file - agentic coding guide
```

---

## Modifying Workflows

**Before Modifying:**
1. Export current workflow as backup
2. Read spec.md for workflow details
3. Understand data flow and dependencies
4. Test in development environment first

**After Modifying:**
1. Test workflow execution manually
2. Verify database changes are correct
3. Check for performance impact (rate limiting, query speed)
4. Update spec.md if workflow behavior changes
5. Update README.md if user-facing changes

---

## Common Patterns to Avoid

❌ **Direct workflow communication** - Use PostgreSQL instead
❌ **Skipping rate limiting** - Always add Wait nodes between HTTP requests
❌ **Ignoring errors** - Use `continueErrorOutput` and validate responses
❌ **Hardcoding values** - Use n8n environment variables or credential management
❌ **Updating docs without testing** - Always test before updating documentation

---

## When in Doubt

1. Check `spec.md` for workflow details and architecture
2. Review existing workflows for similar patterns
3. Test changes in isolated environment
4. Update documentation to reflect changes
5. Ask for clarification if requirements are unclear

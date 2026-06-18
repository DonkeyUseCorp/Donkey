# Web Automation

id: web-automation
description: Drive a real browser in the cloud to do multi-step web tasks — navigate, log in, fill forms, click through, and extract data — when reading and local capture can't.
tags: web, browser, automate, agent, login, form, extract
keywords: log in, sign in, fill form, checkout, book, apply, download from site, navigate, click through, scrape, extract from website, multi-step
tools: web.automate

`web.automate` runs an agentic browser task on the hosted Browser Use service and
returns its result. It is the heaviest, slowest, and only paid web tool — reach
for it last.

## When to use it (and when not)
- Use it only when the task truly needs to *act* across pages: log in, fill and
  submit a form, click through a multi-step flow, or extract data from a site
  that `web.fetch` can't read and `web_snapshot` can't render.
- Do NOT use it to read an article or look something up — that's `web.fetch`. Do
  NOT use it to save a page as PDF/PNG — that's `web_snapshot`. Those are free.

## Cost and consent
- Each run spends the user's credits (billed by browser steps). Before starting a
  task that logs in, submits, pays, or changes anything on the user's accounts,
  confirm with the user — say what it will do and that it uses a real browser.
- Reading/extraction tasks that only look at public pages can run once confirmed
  the hosted browser is the right tool.

## How to call it
- `web.automate` with `task` = the full goal in plain language ("Go to example.com,
  log in as the user, and download the latest invoice as a PDF"). Put the starting
  site in `task` or in `startUrl`.
- For structured results, pass `schema` (a JSON Schema string); the result then
  comes back as JSON matching it. Otherwise the result is the agent's text output.
- It runs to completion before returning (seconds to a few minutes); the result
  text reports the status, the output, and a recording link when available.

## Verify
- Read the returned status and output: a run that "did not fully succeed" did not
  achieve the goal — report that plainly rather than assuming success. For an
  extraction, check the returned data actually contains the requested fields.

## Limitations
- It cannot reuse the user's local browser logins; the agent logs in within the
  hosted browser, so credentials/2FA flows are the user's call to approve.

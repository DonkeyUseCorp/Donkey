# Mail

id: mail
description: Operate Apple Mail through AppleScript first — read inbox state, search, and compose — with the GUI as fallback and explicit confirmation before anything is sent.
tags: mail, email, compose, inbox, local-app
keywords: email, mail, inbox, unread, compose, send, reply, message, attachment, recipient
apps: Mail, com.apple.mail
tools: shell_exec, app_skill

Mail is fully scriptable. Prefer one-line `osascript` through shell_exec over driving the GUI; click only for content AppleScript cannot reach (rendered message bodies, complex search UI).

## Read state
- Unread count: `osascript -e 'tell app "Mail" to get unread count of inbox'`.
- Recent subjects: `osascript -e 'tell app "Mail" to get subject of messages 1 thru 5 of inbox'`.
- Sender of the newest message: `osascript -e 'tell app "Mail" to get sender of message 1 of inbox'`.
- A message's plain-text body: `osascript -e 'tell app "Mail" to get content of message 1 of inbox'` (long output is truncated; read specific messages, not whole mailboxes). Search the body for confirmation/tracking numbers with `grep` on the output.

## Find messages
- By subject: `osascript -e 'tell app "Mail" to get subject of (messages 1 thru 20 of inbox whose subject contains "receipt")'`. Always bound the range (`messages 1 thru 20`) — whose-queries over a whole mailbox are slow.
- Unread only: `… whose read status is false`.
- The newest match is the lowest index; act on `message N of inbox` by the index you found.

## Attachments
- List a message's attachments: `osascript -e 'tell app "Mail" to get name of mail attachments of message 1 of inbox'`.
- Save one to Downloads (two steps in one line — the target file must name the attachment):
  `osascript -e 'tell app "Mail" to save (mail attachment 1 of message 1 of inbox) in POSIX file ((POSIX path of (path to downloads folder)) & "report.pdf")'`
- After saving, verify with `ls -t ~/Downloads | head -3`, then hand the file to shell/Preview steps (`open -a Preview …`, `mv … ~/Documents/Receipts/`).

## Compose
- Create a visible draft (safe, reversible — nothing is sent):
  `osascript -e 'tell app "Mail" to make new outgoing message with properties {subject:"Subject", content:"Body", visible:true}'`.
- Add a recipient to the draft:
  `osascript -e 'tell app "Mail" to tell outgoing message 1 to make new to recipient with properties {address:"someone@example.com"}'`.
- Composing and leaving the draft open for the user to review is the default finish for "write an email" requests.

## Sending is external and irreversible
- Never send without the user's explicit confirmation of recipient and content in THIS task. Ask first (user.clarify), then `osascript -e 'tell app "Mail" to send outgoing message 1'`.
- The same applies to replies and forwards.

## Verify
- After composing, confirm the draft exists: `osascript -e 'tell app "Mail" to get subject of outgoing messages'`.
- After sending, the outgoing message disappears from `outgoing messages`.

## GUI fallback
- Search UI, message threading, and rendered HTML need the GUI: focus Mail, use ax.observe, and drive the search field (Cmd+Option+F focuses search).

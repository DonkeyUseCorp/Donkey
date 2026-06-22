# iMessage

id: imessage
description: Send iMessages through AppleScript only after explicit user confirmation; read conversations through the GUI, never the private database.
tags: messages, imessage, chat, local-app
keywords: message, imessage, text, sms, chat, send, conversation, reply
apps: Messages, com.apple.MobileSMS
tools: shell_exec, app_skill

Messages can send through AppleScript, but sending a message is external and irreversible — it lands on someone else's phone. Reading is mostly a GUI job.

## Sending requires confirmation
- Before sending ANYTHING, confirm the exact recipient and the exact text with the user in this task (user.clarify), unless they already dictated both precisely.
- Send to a phone/email over iMessage:
  `osascript -e 'tell app "Messages" to send "On my way!" to participant "+15551234567" of (1st account whose service type is iMessage)'`.
- Send into an existing named chat: get chats first (`osascript -e 'tell app "Messages" to get name of every chat'`), then `send "text" to chat "Name"`.

## Reading conversations
- AppleScript exposes very little message history. Read conversations through the GUI: focus Messages, ax.observe (the conversation list and transcript are accessible), scroll with mouse.scroll to load older messages.
- Never read `~/Library/Messages/chat.db` directly — it is privacy-sensitive, needs Full Disk Access, and is not a supported path.

## Verify
- After sending, the GUI transcript shows the sent bubble: re-observe and confirm the text appears before completing.

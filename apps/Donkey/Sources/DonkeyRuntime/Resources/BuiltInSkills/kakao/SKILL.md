# KakaoTalk

id: kakao
description: Read and send KakaoTalk chats through the GUI — there is no API or AppleScript. Find a person by search, read the transcript with content.harvest, and confirm before sending anything.
tags: messages, kakao, kakaotalk, chat, local-app
keywords: kakao, kakaotalk, message, chat, dm, conversation, read, reply, send, korean
apps: KakaoTalk, com.kakao.KakaoTalkMac
tools: app_skill

KakaoTalk has no API and is not scriptable, so drive it through the window with `ax.observe`, `ax.click`, `content.harvest`, and `mouse.scroll`. Reading is an Accessibility + vision job; sending is external and irreversible — it lands on someone else's phone.

## Open the person's chat
- `ax.observe` the main window. The chat list and the search field are Accessibility-readable even though the message bubbles are not.
- Find a person by typing their name into the search field, then `ax.click` the result row to open the chat. A chat opens scrolled to the newest message at the bottom.
- Each chat opens in its OWN separate window, titled with the person's name. The contact list stays in a different window, so from here on you must tell the tools which window you mean.
- Names may be Korean; use the exact text the search returns rather than transliterating.

## Read the conversation
- Read the chat window by name: `content.harvest window="<person's name>" direction=up`. The `window=` is essential — it resolves the conversation window, not the contact list; without it harvest reads the list's row previews instead of the transcript. If it reports no window titled that, the chat isn't open yet; open it from the list first.
- KakaoTalk's bubbles are not in the Accessibility tree, so harvest reads them through vision on its own — you do not need a separate `vision.capture` or scroll loop. It gathers the visible text, scrolls up, and repeats in one call.
- Ask for a bit more than you need — for "the last 10 messages" pass maxItems around 20 — then take the most recent from the result. With direction=up the result is most-recent first.
- The gathered lines mix sender names, timestamps, and bubble text together. Read them in order and pick out the actual messages and who sent them.
- Older messages load lazily: KakaoTalk shows only the most recent bubbles, with earlier ones behind a "View Previous Chats" button. If the harvest returns fewer messages than requested, `ax.click` "View Previous Chats" (or scroll up) to load more, then harvest again — repeat until you have the count or the conversation runs out. Save whatever exists when it does.

## Save to a file
- Write the collected messages to the conversation's working folder with `files.write` (e.g. one message per line with the sender), then confirm the file exists before completing.

## Sending requires confirmation
- Before sending anything, confirm the exact recipient and the exact text with the user (`user.clarify`), unless they already dictated both precisely.
- Send by opening the person's chat, typing into the message field, and pressing return.

## Verify
- After reading, confirm you have the requested count of messages before completing.
- After sending, re-observe the transcript and confirm the sent bubble appears.

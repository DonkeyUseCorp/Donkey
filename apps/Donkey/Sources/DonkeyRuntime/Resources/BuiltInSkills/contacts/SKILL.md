# Contacts

id: contacts
description: Look up people in Apple Contacts through AppleScript — emails, phones, addresses, birthdays — feeding the result into mail, notes, events, or Maps.
tags: contacts, people, address-book, local-app
keywords: contact, person, email address, phone number, birthday, address, company
apps: Contacts, com.apple.AddressBook
tools: shell_exec, app_skill

Contacts is fully scriptable and read-mostly. Reading contact data is one `osascript` line; editing contacts is rare — ask before changing anything.

## Find a person
- By name: `osascript -e 'tell app "Contacts" to get name of (people whose name contains "Alex")'` — disambiguate with the user when several match.
- By company: `osascript -e 'tell app "Contacts" to get name of (people whose organization contains "Acme")'`.

## Read their details
- Email: `osascript -e 'tell app "Contacts" to get value of email 1 of (person 1 whose name contains "Alex")'`.
- Phone: `osascript -e 'tell app "Contacts" to get value of phone 1 of (person 1 whose name contains "Alex")'`.
- Address (one formatted string): `osascript -e 'tell app "Contacts" to get formatted address of address 1 of (person 1 whose name contains "Alex")'`.
- Birthday: `osascript -e 'tell app "Contacts" to get birth date of (person 1 whose name contains "Alex")'`.
- A person may have several emails/phones (`email 2`, `every email`); pick the labeled one the task implies when it matters.

## Feed the result onward
- Draft an email to them: pass the address to the Mail skill's outgoing-message flow.
- Open their address in Maps: `open "maps://?q=ADDRESS"` (URL-encode spaces as %20 or quote the whole URL).
- Save to a note / copy to clipboard: Notes skill or `pbcopy`.

## Verify
- Echo the exact value read (the address, number, email) into the next step's input and confirm the downstream effect — a contact lookup alone is not task completion.

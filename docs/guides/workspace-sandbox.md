# Workspace Sandbox

Every task runs inside its own folder. Each tool the agent spawns — a shell
command, a bundled converter, ffmpeg — runs through a kernel sandbox whose job is
to bound where it can WRITE: inside the task folder, and nowhere else unless the
user approved it. Donkey runs whatever commands the model composes, so this
boundary can't rest on the model behaving: a mistyped path, a path built from a
web page, or a tool gone wrong is stopped by the operating system.

**The one rule:** a command runs without a consent prompt only when everything it
changes lives inside the folder Donkey created. The moment a write reaches a file
the user owns, the user approves it first — and the kernel is there to enforce
that a command can't quietly escape the folder regardless.

## How it works

```text
a tool the model runs (shell command, bundled converter, ffmpeg)
      |
      v
launched through the macOS sandbox, scoped to the task folder
      |
      v
write   → task folder        (+ the user's home, once a prompt approved the command)
read    → open  (bundled-tool pipelines: only system libraries + declared inputs)
network → open
```

A tool is launched through the macOS sandbox (`sandbox-exec`) under a profile
built fresh for the task. The runtime builds and applies that profile
automatically for every task that owns a folder, so confinement holds by
construction.

The kernel decides what a tool *can* touch; consent decides what it's *allowed*
to do. They are separate layers: the kernel bounds the filesystem writes, and
consent (see the harness guide) governs the rest — touching the user's own files,
driving another app, changing a system setting, reaching out over the network.

## What a tool may touch

| Access | Allowed | Denied |
|---|---|---|
| Write | the task folder; the user's home once a consent prompt approved the command | `/System`, `/usr`, other users — and the user's files until a prompt approves the write |
| Read | open, so the agent can inspect a file the user pointed it at | — (a bundled-tool pipeline stays limited to system libraries + its declared inputs) |
| Network | open | — |

Reads are open because the agent reading a file is already treated as free — the
risk it's guarding against is *changing* things, and a read changes nothing. The
network stays open so a task can call APIs and fetch data; the tools that could
exfiltrate (a downloader, an interpreter) are gated by consent like any other
out-of-folder effect.

A bundled-tool pipeline (the caption, shorts, PDF, and media-cut orchestrators) is
the one exception to open reads: it processes one named input, so its profile
limits reads to the system and that declared input. A hostile input file then
can't steer its converter into reading the rest of the disk.

## Two surfaces

The jail is for the **untrusted** surface — the arbitrary tools the model
assembles and runs. Donkey's own in-process writers, like the file-writing tool
and the HTML-to-image renderer, run inside the app itself; the kernel sandbox
confines child processes and the app runs outside it, so those writers keep their
own destination logic. That split is deliberate: first-party code you author and
review needs no jail, while a command the model just composed gets one.

## Consent and the folder boundary

A line whose every command is a bounded file operation (`mv`, `cp`, `mkdir`,
`rm`, `chmod`) runs without a prompt **only when every path it names resolves
inside the task folder** — the agent managing the files it created shouldn't have
to ask. A clean-up chain like `mv "<folder>/a" "<folder>/done/a" && rm
"<folder>/tmp"` qualifies because each link stays in the folder.

The moment an operand leaves the folder — a `~` path, an absolute path elsewhere,
a `..` that climbs out, or a `$VAR` we can't resolve and so can't trust — the
command goes through the normal consent prompt, because it would change a file
the user owns. When the user approves, the kernel widens for that command to let
the approved write land. Any resolution ambiguity errs toward asking, never away.

Consent also gates what a filesystem boundary can't contain at all: an interpreter
or a downloader (its effect is the code it runs or the bytes it fetches), driving
another app, changing a setting, elevated privileges.

The agent does not overwrite an existing user file unless the user explicitly
asked. By default it writes a new copy or alternate version and leaves the
original alone.

## Limits

- **The jail bounds writes, not code.** A confined tool can still use the network
  and read freely; isolating genuinely untrusted *code* is a heavier tier this
  does not provide.
- **Scratch space is writable.** The per-user temporary directory and the user
  cache dirs are writable, because many tools need them to run; they hold no user
  documents and are cleared by the system.
- **Approval widens, it doesn't disappear.** An approved command writes within the
  user's home, so the kernel still blocks `/System`, `/usr`, and other users even
  for a command the user okayed.

## Where it lives

The runtime's command layer builds the sandbox profile and launches every
task-work tool through it; the per-task workspace record supplies the folder and
the declared inputs the profile is built from.

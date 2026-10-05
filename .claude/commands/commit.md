---
description: Commit staged/modified changes with a detailed message and push, no AI co-author attribution
---

# Commit and Push

This repo is a collection of independent container images, one per top-level
directory (`rqlite/`, `soju/`, `dynsnap/`, `spotsnap/`, `ytmsnap/`), each with a
`Dockerfile`, a POSIX `sh` `entrypoint.sh`, and sometimes an `nginx.conf`.

## Steps

1. Run `git status` and `git diff` (and `git diff --staged` if anything is already staged) to see all changes.
2. Lint and build-check only the image directories that were actually touched, before staging anything.
   No linters are installed locally, so run them through Docker:
   - Any `*.sh` changed: `docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable <dir>/<file>.sh`
     (scripts are `#!/bin/sh` on busybox ash — keep them POSIX, no bashisms).
   - Any `Dockerfile` changed: `docker run --rm -i hadolint/hadolint hadolint --ignore DL3018 - < <dir>/Dockerfile`
     (DL3018 "pin apk versions" is ignored on purpose: images track `alpine:edge`).
   - Any file in an image dir changed (Dockerfile, entrypoint, nginx.conf, …): `docker build -t <dir>-check <dir>/`
     must succeed. Then remove the test image with `docker rmi <dir>-check`.
   - Any `nginx.conf` changed: after the build, validate it inside the image, e.g.
     `docker run --rm --entrypoint nginx <dir>-check -t -c /script/nginx.conf`
     (skip if the config needs `envsubst` rendering first, like `rqlite/`; the build + a short run is enough there).
   - If a check reports an error, fix it and re-run before continuing. Warnings that would only apply to
     pinned/versioned base images can be left alone.
3. Never stage secrets or local state: `*.json` and `*.db` are gitignored on purpose (real backup configs,
   databases) — don't force-add them (`git add -f`). Commit `*.example` files instead. Also don't commit
   `.claude/settings.local.json`.
4. If nothing is staged, stage all relevant modified/new files with `git add`.
5. Write a **detailed** commit message:
   - Subject line: concise summary of the change (imperative mood, e.g. "Add", "Fix", "Switch").
     Name the image when the change is scoped to one, e.g. "Add soju bouncer image with gamja and nginx".
   - Body: explain _what_ changed and _why_, as bullet points if there are multiple distinct changes.
   - Base the message only on the actual diff — do not include conversational back-and-forth, dead ends, or trial-and-error from the session.
6. Create the commit using a HEREDOC so formatting is preserved, e.g.:
   ```bash
   git commit -m "$(cat <<'EOF'
   Short summary of the change

   - Detail one
   - Detail two
   - Why this change was made
   EOF
   )"
   ```
7. **Do not** add any AI attribution — no `🤖 Generated with Claude Code` line, no `Co-Authored-By: Claude` trailer, no mention of Claude/AI anywhere in the message.
8. Push the commit to the current branch's remote (`git push`, or `git push -u origin <branch>` if it has no upstream yet).
9. Confirm success by showing `git log -1` and `git status` after pushing.

## Rules

- Never include Claude/AI co-authorship or attribution in the commit message.
- Always push after committing — don't stop at just the local commit.
- If the push fails (e.g. diverged branch), report the error and ask before force-pushing or rebasing.
- Never force-add gitignored files (`*.json`, `*.db`) — they may hold credentials or live data.

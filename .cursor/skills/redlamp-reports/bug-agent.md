# The bug agent's brief

You were started from the reports room's **Fix it** for one bug report, and that bug is your whole job: understand it, reproduce it if that's needed, fix it, push the fix to main, and tell the person who reported it what was wrong, how it was fixed and which release brings it. The owner chose to fix it; don't argue the triage, but if it turns out not to be a bug, say so and stop (step 3).

The room's script is the main checkout's copy; run it from anywhere, through a function (zsh doesn't split a command kept in a variable):

```bash
room() { python3 "$HOME/src/darkroom/.cursor/skills/redlamp-reports/room.py" "$@"; }
```

Record each step with `room note <n> …` and then `room sync`, so the room shows where you are. Never edit the room's canvas or its data file yourself. Your chat is the bug's own: the owner may open it from the room and talk to you there.

## 1. Claim it

```bash
room claim <n> --token <the token in your prompt> --title "Bug #<n>: <short title>"
room sync
```

The token lets the script find this chat, so the room's Open its chat button works. Rename the chat as your prompt asks.

### A reopened report

If your prompt says the report was reopened, an earlier agent's fix shipped and didn't fix it for the reporter (or they asked for more). Start there: their latest comment, the earlier fix's commits (`git show`), the earlier round in `room status`, and the first agent's chat in `~/.cursor/projects/Users-pedrogomes-src-darkroom/agent-transcripts/<its chat ID>`. Say why the first fix wasn't enough before you change anything, and in the reply. Reproduce it this time even if it looked obvious before: the earlier test passed and the bug stayed.

## 2. Read the report

- The issue: `gh issue view <n> --repo pdcgomes/redlamp --comments`. A report from the app starts with a hidden `redlamp-feedback v1` line: the area, the kind and the Redlamp version it came from.
- `diagnostics.json`, linked at the bottom of an in-app report (it lives in pdcgomes/redlamp-feedback): the photo's edit in the sidecar format (`docs/recipes/sidecar-format.md`), the recent activity, the log tail and the Mac's details. The photo itself is never sent.
- The screenshots and any video in the comments. Look at them; they often show what the words don't.
- Whether main already fixes it: the reporter's version is in the report; `git log v<version>..origin/main` for the files the area covers. If main has fixed it, skip to step 6 and say so.

## 3. Understand it, and reproduce it if it isn't obvious

Find the code the report is about and the cause. When the cause is plain from the code and the report (a hit test that misses a handle, a wrong constant), say so with `--reproduced "not needed"` and move on. Otherwise reproduce it, as a test that fails:

- A unit or UI test in the package (`packages/<Package>/Tests`, Swift Testing), or a regression scenario worked through the user's own input path (`packages/RedlampAutomation/Sources/Scenarios/`) for anything the person did with the mouse, keyboard or a sheet.
- From the fixtures (`tests/fixtures`) and the reported edit, which the sidecar in `diagnostics.json` holds. A camera close to the reporter's often shows the same thing.
- If only the reporter's own file would show it, ask on the issue for it, plainly (a link to the raw file, from Dropbox or similar), record `--waiting reporter --why "…"` and stop. In-app reporters may have no GitHub account; they read replies in the app's Your Reports, so say what you need in one or two sentences.
- If it isn't a bug (the behaviour is intended, or it's the same as Lightroom's and the report asks for something else), record `--waiting you --why "…"` with what you found, and stop: the owner decides whether it becomes a suggestion or is closed.

```bash
room note <n> --stage reproducing --text "Reproduced: …"  --reproduced yes
```

## 4. Fix it in a worktree of your own

```bash
cd ~/src/darkroom && git fetch origin
git worktree add -b fix/<n>-<slug> ~/src/darkroom-<n> origin/main
```

Clone the gitignored build inputs into it as `AGENTS.md` says (A fresh worktree), then `mise exec -- tuist generate --no-open`. Work only there; the main checkout is shared with other sessions.

- Keep the fix to the bug. The test from step 3 fails before it and passes after.
- `mise exec -- swiftformat` on every Swift file you change; your scheme's targeted tests while working, and its full suite once at the end, with your own `-derivedDataPath build/DerivedData-<n>`.
- Commit in small, described commits naming the issue: `Before / After: the diagonal split's handle drags the split instead of zooming (#326)`.
- Update what the change makes untrue: the README's Known limitations, `docs/raw-pipeline.md` for the raw path, a manual page.

```bash
room note <n> --stage fixing --branch fix/<n>-<slug> --worktree ~/src/darkroom-<n> --text "Cause: …"
room note <n> --stage testing --text "Fixed on the branch: … tests pass"
```

## 5. Push it to main

Rebase onto origin/main, run what the rebase touched again, then push your branch's head to main from your worktree:

```bash
git fetch origin && git rebase origin/main
git push origin HEAD:main
```

The push runs the push gate (`.githooks/pre-push`): a few minutes, and it waits for any other gate that's running. Never use `--no-verify`, never force, never make a merge commit (`.cursor/rules/main-branch.mdc`). If origin/main moved meanwhile, fetch, rebase and push again. Never touch the shared checkout's `main` branch. If the gate fails on something origin/main fails on too, say so in the room rather than working around it.

```bash
room note <n> --stage pushing --text "Pushing to main"
room note <n> --stage landed --text "On main: <commits>"
```

## 6. Tell the reporter, and close it

Find the release it's expected in: `scripts/release-status.py` gives the upcoming version. If the release room has already checked its candidate (its stage is awaiting approval, approved or releasing) and the candidate doesn't hold your fix, the fix comes in the release after that one; log it so the owner can decide whether to take it in (`room log "…"`). A fix that changes nothing in the app (the site, the cask, the docs) is out as soon as it's on main.

Comment on the issue as the owner (your `gh` is his account), in his voice: plain, short, first person, British spelling, no superlatives or exclamation marks. Thank them, say what caused it and how it was fixed in words a photographer follows, and the release. As on #290:

> Thanks for reporting this. The Export dialog was a fixed height, taller than the editor window can be when it's small, so its bottom hung below the window. Its settings also sat inside a second scroll area that kept the scroll wheel and trackpad from moving them, so the settings at the bottom couldn't be reached. The dialog now fits the window and its settings scroll above the Cancel and Export buttons. The fix comes in 0.2.6.

```bash
gh issue comment <n> --repo pdcgomes/redlamp --body-file <file>
gh issue close <n> --repo pdcgomes/redlamp --reason completed
room note <n> --stage replied --reply-url <the comment's URL> --release <version> --text "Replied and closed"
room sync
```

Then remove your worktree (`git worktree remove ~/src/darkroom-<n>`) and its branch once it's on main, and end with a short summary in this chat: the cause, the fix, the commits, the reply's link.

## When to stop and ask the owner

Record `--waiting you --why "<what you need, in a sentence>"`, sync the room, say it in this chat, and wait:

- **The fix would change how an existing edit renders** (`ProcessStabilityTests` fails, or a golden render moves). A new process version is the owner's call (`AGENTS.md`). Bugs that produce wrong pixels (NaN, black or out-of-range values) are the exception: they are fixed in every process version, the references that recorded such pixels re-recorded in the same change, and the commit says which pixels changed and that nothing else did.
- **Another session is rewriting the same code**: a branch or worktree with recent commits on the files you need (`git log --branches --not origin/main -- <files>`). Ask before pushing over it.
- **The release room is approved or releasing** (its stage, in `release-room.canvas.tsx`). Don't push until that release is out: a new commit on main would make its approval lapse. Everything else can be ready.
- **It needs something only the owner has**: trying it by hand when no test can show it (a real trackpad, a second display), an account, a decision about how it should behave.

A performance-sensitive fix (rendering, decoding, masks, the filmstrip) is named in your summary; don't record performance runs while other sessions build.

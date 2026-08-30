---
name: git-guard
description: Git workflow guard for RIVR project. Run before every commit and push to enforce branching, secrets scanning, and best practices.
---

# Git Guard — RIVR Project

**Run this skill before every commit and before every push.**

## When Starting New Work

1. NEVER work directly on `development` or `main`. Always branch from `development`:
   ```bash
   git checkout development && git pull origin development
   git checkout -b feature/<short-description>   # new features
   git checkout -b bugfix/<short-description>    # bug fixes
   git checkout -b chore/<short-description>     # config, deps, docs, refactors
   git checkout -b hotfix/<short-description>    # urgent production fixes (branch from main instead)
   ```
2. If already on `development` with uncommitted changes, stash and branch:
   ```bash
   git stash
   git checkout -b feature/<name>
   git stash pop
   ```

## Before Every Commit — Pre-Commit Checklist

### Step 1: Secrets Scan (MANDATORY — never skip)

Check what is staged:
```bash
git diff --cached --name-only
```

**BLOCK the commit if ANY of these files appear:**
- `config.dart` — Mapbox token, NWM API URLs, vector tileset IDs
- `firebase_options.dart` — Firebase project keys
- `google-services.json` — Android Firebase config
- `GoogleService-Info.plist` — iOS Firebase config
- `Secrets.xcconfig` — iOS secrets
- `functions/.env` — Cloud Functions environment variables (NWM API key)
- `key.properties` — Android signing keystore credentials
- Any `.env`, `.env.*`, `*.pem`, `*.key` file

If a suspicious file is staged, inspect it before doing anything else:
```bash
git diff --cached <filename>
```

Search for hardcoded secrets in staged changes:
```bash
git diff --cached -S "sk_" --name-only
git diff --cached -S "pk_" --name-only
git diff --cached -S "password" --name-only
git diff --cached -S "secret" --name-only
git diff --cached -S "token" --name-only
```

### Step 2: Gitignore Check

Verify `.gitignore` contains all of these:
```
lib/core/config.dart
lib/firebase_options.dart
android/app/google-services.json
ios/Runner/GoogleService-Info.plist
ios/Flutter/Secrets.xcconfig
functions/.env
android/key.properties
```

### Step 3: Commit Quality
- Stage specific files by name — NEVER use `git add .` or `git add -A`
- Commit message in imperative mood, concise: what changed and why
- One logical change per commit

## Before Every Push — Pre-Push Checklist

### Step 1: Run Flutter Analyze
```bash
flutter analyze
```
**BLOCK the push if there are any errors.** Fix them first.

### Step 2: Review All Unpushed Commits
```bash
git log origin/development..HEAD --oneline
```
Read every commit message — confirm nothing looks wrong.

### Step 3: Scan Changed Files for Secrets
```bash
git diff origin/development..HEAD --name-only
```
**BLOCK if any of the following appear:**
- `config.dart`, `firebase_options.dart`, `google-services.json`
- `GoogleService-Info.plist`, `Secrets.xcconfig`, `functions/.env`, `key.properties`

### Step 4: Deep Secret Search
```bash
git diff origin/development..HEAD -S "password" --name-only
git diff origin/development..HEAD -S "secret" --name-only
git diff origin/development..HEAD -S "token" --name-only
git diff origin/development..HEAD -S "sk_" --name-only
git diff origin/development..HEAD -S "pk_" --name-only
```
Inspect any matches — confirm they are code references (variable names, string literals in comments), not real credentials.

### Step 5: Confirm Branch and Push
- Pushing a feature/bugfix/chore branch — always use `-u` on first push:
  ```bash
  git push -u origin feature/<name>
  ```
- **NEVER push directly to `development` or `main`**
- **NEVER force push to `development` or `main`**

## Merging to Development

**Always `--no-ff`.** Jerson's call, 2026-08-30.

A plain `git merge` fast-forwards when nothing else has landed on
`development`, which is the normal case for short-lived branches. The branch
then leaves NO trace in `git log` — the commits look exactly like commits made
directly on `development`, and the rule against committing there becomes
unauditable. It came up because a commit HAD gone straight to `development`
that day and `git log` could not distinguish it from the seven that had not;
only the reflog could, and the reflog is local and expires.

`--no-ff` records the branch name and the merge point permanently.

```bash
git checkout development
git pull origin development
git merge --no-ff feature/<name>
git push origin development
git branch -d feature/<name>
git push origin --delete feature/<name>
```

To check later that work went through a branch:
```bash
git log --merges --oneline development   # every merge, with its branch name
```

## Releasing to Main

Only when `development` is stable and fully tested:
```bash
git checkout main
git pull origin main
git merge development
git push origin main
```
After merging: bump the version/build number in `pubspec.yaml` and add a release entry to `app_releases.md`.

### CRITICAL: Restore Gitignored Files After Merge

Merging `development` into `main` (or switching branches) **deletes gitignored files from disk** if they were previously tracked on the target branch and then removed via `git rm --cached`. After every merge to `main`, verify these files still exist on disk:

```bash
test -f lib/firebase_options.dart          || echo "MISSING: firebase_options.dart"
test -f android/app/google-services.json   || echo "MISSING: google-services.json"
test -f ios/Runner/GoogleService-Info.plist || echo "MISSING: GoogleService-Info.plist"
test -f lib/services/0_config/shared/config.dart || echo "MISSING: config.dart"
```

**If any are missing, restore from git history:**
```bash
git log --all --oneline -- <path>           # find the last commit that had the file
git show <commit>:<path> > <path>           # restore it to disk
```

The app will not compile without these files. Never skip this check.

## Emergency: Secret Was Committed

**If NOT pushed yet:**
```bash
git reset --soft HEAD~1
# remove the secret from the file
# verify the file is in .gitignore
# re-stage only the safe files and re-commit
```

**If already PUSHED:**
1. Immediately rotate the credential — Mapbox token, Firebase key, NWM API key, etc.
2. `git rm --cached <file>` — add to `.gitignore` if not already there
3. Commit and push the fix
4. The old credential remains in git history — rotation is the only real protection
5. For NWM API key: update `functions/.env` and redeploy Cloud Functions (`firebase deploy --only functions`)
6. IMPORTANT: After `git rm --cached`, the file is deleted from disk on the next checkout/merge — restore it immediately from the previous commit:
   ```bash
   git show HEAD~1:path/to/file > path/to/file
   ```

## Output

After running all checks, output a summary:
```
GIT GUARD REPORT
- Branch:         feature/my-feature ✓  (WARNING if on development or main)
- Secrets scan:   PASS / FAIL
- Flutter analyze: PASS / FAIL
- Gitignore:      PASS / FAIL
- Ready to:       commit / push / BLOCKED
```

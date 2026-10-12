# Paper Reading Groups — GitHub Pages + Supabase

This version separates the public website source code from private group data. GitHub Pages hosts the HTML/CSS/JavaScript; Supabase provides login, PostgreSQL, row-level access control, and private PDF/backup storage.

## Features in this version

- **Paper Library:** title, author, DOI, source link, topic, year, deadline, and private PDF upload.
- **Reading Progress:** each signed-in member tracks their own paper status.
- **Dashboard:** paper counts, personal reading progress, and upcoming deadlines.
- **Backup / Restore:** admin can download a JSON backup or save one to private Supabase Storage. A GitHub Actions workflow also creates a scheduled private backup daily and retains the newest 14 scheduled bundles. Browser JSON downloads contain database records and embedded PDF bytes (up to 20 MB of PDF data). Private and scheduled backups store PDFs as separate private Storage objects and use the manifest to restore them, so the total size is limited by your project storage quota and the 50 MB per-object cap.
- **Research Notes & Discussion:** private notes, group-shared notes, and group discussion comments.
- **Admin / Groups:** create groups, assign registered accounts, and manage admin/member roles.
- **Telegram deadline reminders:** GitHub Actions reads deadlines from Supabase; secrets remain in GitHub Actions settings.
- **Legacy export:** `migration/legacy-export.html` decrypts the old encrypted `vault.json` locally in the browser and downloads a JSON export. It makes no network requests.

## 1. Create and configure Supabase

1. Create a Supabase project.
2. Open **SQL Editor** and run `supabase/migrations/20261013000000_initial_schema.sql`.
3. In Supabase **Authentication → URL Configuration**, add your GitHub Pages URL to the allowed Site URL / Redirect URLs, e.g. `https://YOUR-USER.github.io/YOUR-REPO/`.
4. In the project settings/API Connect dialog, copy the **Project URL** and **publishable key**. Do not use a secret/service-role key in the website.
5. Edit `config.js` and replace the placeholder URL and key.
6. Deploy this repository to GitHub Pages (Settings → Pages → deploy from your chosen branch/root).

The SQL migration creates the schema, RLS policies, profile-on-signup trigger, and two private buckets:

- `papers-private` — private PDFs; object paths start with the group UUID.
- `backups-private` — private JSON backup bundles visible only to admins.

**Do not skip the SQL migration or weaken the RLS policies to make a query work.** The browser is public code; RLS and Storage policies are the security boundary.

## 2. Create the first Admin

1. Open the deployed site and create an account using the sign-up form.
2. Confirm the email first if email confirmation is enabled.
3. In Supabase **SQL Editor**, run this command with the exact email used to register:

```sql
update public.profiles
set role = 'admin'
where email = 'your-admin-email@example.com';
```

4. Log out and log in again. The account should show the Admin tab.
5. Create groups, then ask members to sign up and assign their accounts to groups.

A newly registered account is a `member`. A user cannot promote themselves through the browser because the profile role is guarded by a database trigger and RLS policy.

## 3. Move old data from the encrypted app

The uploaded legacy ZIP contained `data/vault.json` and group/student metadata, but **did not contain any `papers/*.bin` PDF objects**. The new deployment intentionally does not include the encrypted vault, because a public repository should not hold private team data even when encrypted.

1. Keep the original ZIP in a private location until migration is complete.
2. Extract the original ZIP locally.
3. Open `migration/legacy-export.html` in a browser. Choose the old `data/vault.json` file and enter the existing legacy passcode.
4. The tool decrypts locally and downloads `legacy-paper-groups-export.json`; it does not upload the data anywhere.
5. Sign in as Admin on the new website → **Admin & Backup/Restore** → select the export JSON → **Validate & Restore Selected File**.
6. Legacy group names, available paper title/link/deadline metadata, and old student names are imported. The old student names are kept as **legacy names** until you link them to newly registered accounts. The legacy file references cannot restore missing PDF binary files; upload those PDFs again from your own originals.
7. Verify all groups and papers, and create a new backup before retiring the original copy.

Never commit `vault.json`, `legacy-paper-groups-export.json`, member information, research notes, private PDFs, or backup files to a public GitHub repository.

If you plan to reuse the old local repository, do not simply overlay these files and push: the old vault or PDF binaries may remain in the working tree. The `.gitignore` rules do not untrack files that Git already tracks. Remove any tracked legacy private files from the current version (for example, `git rm -f data/vault.json papers/*.bin`, adjusting paths to match your repository), then commit the removals. If the repository has already been public, those files may still exist in prior Git history. Rotate the legacy passcode; revoke any token that may ever have been committed; and consider cleaning/replacing the Git history or moving to a fresh repository.

## 4. Backup / Restore behavior

A downloadable self-contained JSON backup includes the application tables and embedded PDF bytes; the browser limits its total PDF data to 20 MB. Private Storage backups store each PDF as a separate object and the manifest records the object paths, so the total size is limited by your Supabase Storage quota and the 50 MB per-object cap. For larger projects or stricter recovery needs, use the Supabase CLI/database dump process and back up Storage objects separately.

Restore is intentionally a **merge/upsert**, not a destructive point-in-time replacement: it updates/inserts records in the chosen bundle but does not delete records absent from that bundle. Before restoring a backup or importing legacy data, the app automatically creates a private checkpoint backup of the current tables and referenced PDFs; if that backup fails, the restore/import stops. Restore is intended for the same Supabase project, where the referenced Auth user IDs still exist, and should still be tested in a non-production project when possible.

Supabase database backups do not include Storage file bytes, so PDFs need their own backup. Check your Supabase plan for managed database-backup availability, and keep an independent copy of critical data. See the [Supabase backup guide](https://supabase.com/docs/guides/platform/backups).

## 5. Automatic backups and Telegram deadline reminders

The `Scheduled private backup` GitHub Actions workflow runs daily at 09:15 Myanmar time. It backs up all application tables and referenced PDFs to the private `backups-private` bucket, creates a `backup_runs` record, and retains the newest 14 scheduled backup bundles. Configure `SUPABASE_URL` and the recommended `SUPABASE_SECRET_KEY` repository secrets below. A backup will fail if a single PDF or the manifest exceeds the Storage per-object limit, or the project runs out of Storage quota. Monitor the GitHub Actions run history for failure alerts.

The `Deadline reminders` workflow runs daily at 09:00 Myanmar time. In GitHub → **Settings → Secrets and variables → Actions**, add these **repository secrets**:

- `SUPABASE_URL` — project URL.
- `SUPABASE_SECRET_KEY` — recommended current Supabase secret API key for scheduled server-side jobs. Store only in GitHub Actions Secrets; never put it in `config.js` or frontend files.
- `SUPABASE_SERVICE_ROLE_KEY` — optional fallback if your project still uses the legacy service-role JWT. If both key secrets are configured, the current `SUPABASE_SECRET_KEY` is used.
- `TELEGRAM_BOT_TOKEN` — Telegram bot token.
- `TELEGRAM_CHAT_ID` — target chat ID.

Optionally add the repository variable `SITE_URL` to override the website URL shown in reminders. Add repository variable `DRY_RUN` with value `1` to print reminder messages without sending them to Telegram; remove or clear it to resume sending. The reminder workflow can also be run from the Actions tab. The backup workflow can be run manually from the Actions tab too. See the current [Supabase API-key guidance](https://supabase.com/docs/guides/getting-started/api-keys) for secret-key handling.

## Security checklist

- Keep `config.js` limited to the project URL and the publishable key.
- Never expose a Supabase secret/service-role key in HTML, JavaScript, public GitHub, screenshots, or exported files.
- Leave RLS enabled on every app table and keep both Storage buckets private.
- Review policies after schema changes; a publishable key is public by design.
- Use strong account passwords and enable email confirmation in Supabase Auth. This starter UI includes password reset but not an MFA enrollment/challenge flow; do not enforce MFA until that UI has been added and tested.
- Share papers only where copyright and licence conditions permit.
- Test group separation with two normal accounts before inviting real members.

Useful official references: [Securing data](https://supabase.com/docs/guides/database/secure-data), [API keys](https://supabase.com/docs/guides/getting-started/api-keys), [Storage access control](https://supabase.com/docs/guides/storage/security/access-control), [Scheduled Edge Functions / jobs](https://supabase.com/docs/guides/functions/schedule-functions).

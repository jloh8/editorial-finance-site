# Editorial Pipeline v1

The review loop for the editorial finance site. Jia is the editor; Rumi (the main
agent) is the writer. No backend server — the single-file frontend talks directly
to Supabase, and an automated worker (a scheduled hook, set up separately) does
the rewriting.

## How the loop works

1. **Draft lands in the queue.** A new article row in `editorial_articles` with
   status `in_review`, plus its first row in `editorial_versions`. The admin
   "Review queue" tab lists every article with its status pill and version label.
2. **Editor reviews.** Jia signs in on the Review queue tab with a magic link
   (prefilled `jiajingloh@gmail.com`). She can Preview any draft, or:
   - **Approve & publish** → article status becomes `published`; the reader view
     immediately renders the current version.
   - **Revise article** → she writes notes in the textarea and submits. This
     inserts a `pending` row in `editorial_revision_requests` and flips the
     article to `revising`. The card shows "Revision in progress" and the queue
     auto-refreshes every 20 seconds while a revision is in flight.
3. **Worker rewrites.** A hook polls `editorial_revision_requests` for
   `status = 'pending'`. For each one it reads the article's current version
   HTML + the notes, rewrites the full article HTML, and calls the
   `editorial_complete_revision` RPC with the new HTML.
4. **Back to review.** The RPC inserts a new `editorial_versions` row
   (`version_number = max + 1`), points `current_version_id` at it, marks the
   request `done`, and returns the article to `in_review`. The queue card now
   reads "Draft v2" and Jia re-reviews. Loop until approved.
5. **Unclear notes.** If the worker can't act on the notes, it calls the RPC
   with null/empty HTML: the request is marked `failed` and the article goes
   back to `in_review` so Jia can clarify and resubmit.

## Tables + RLS

All in the **CoursideMeetup** Supabase project
(`https://cghvnuvuermiehvygwyw.supabase.co`). Schema: `schema.sql`.

| Table | Purpose |
|---|---|
| `editorial_articles` | One row per article: slug, title, dek, status (`draft`/`in_review`/`revising`/`needs_revision`/`published`), `current_version_id` |
| `editorial_versions` | Immutable HTML snapshots per article (`article_id`, `version_number`, `html`, `created_by`). Unique on `(article_id, version_number)` |
| `editorial_revision_requests` | Editor → worker handoff: `article_id`, `notes`, status (`pending`/`done`/`failed`) |

**RLS** (enabled on all three):
- `anon` can `SELECT` everything — reads are public by design; the reader UI
  only ever renders `published` articles.
- `authenticated` users whose JWT email is `jiajingloh@gmail.com` get full
  `INSERT`/`UPDATE`/`DELETE` (magic-link sign-in supplies the JWT).
- `editorial_complete_revision(p_request_id uuid, p_html text)` is
  `SECURITY DEFINER` with `EXECUTE` granted to `anon`, so the worker needs no
  service key. It validates the request is `pending` and the article is
  `revising` before writing; worst-case abuse is flipping a non-public draft's
  status.

## Worker contract (for the hook)

- Poll: `select * from editorial_revision_requests where status = 'pending'
  order by created_at` (as anon — reads are public).
- For each request: fetch the article row + its `current_version_id` HTML from
  `editorial_versions`.
- Rewrite the **complete** article HTML: keep the same section structure
  (`hero` without the status pill, `figures`, `article` chapters, chart,
  caveats, `sources`). The app renders the version HTML verbatim and adds the
  status pill itself. Preserve every citation; never invent facts or a brand.
- Apply: `select editorial_complete_revision('<request_id>', '<new_html>')`
  via the anon client (`sb.rpc('editorial_complete_revision', …)`).
- If the notes are unclear or unactionable: call it with `p_html = null`.
- Never use the `service_role` key. Concurrency: if two workers race, the
  second RPC call fails validation (`request_not_pending`) — safe to retry.

## Cutover checklist (main agent)

- [ ] Run `schema.sql` in the Supabase dashboard SQL editor (idempotent;
      safe to re-run).
- [ ] Paste the Supabase **anon public** key into `index.html`
      (`SUPABASE_ANON_KEY`; dashboard → Project Settings → API). Never the
      service_role key.
- [ ] Supabase dashboard → Authentication → URL Configuration: add
      `https://jloh8.github.io/editorial-finance-site/` to Redirect URLs
      (magic-link sign-in needs it).
- [ ] Merge `pipeline` → `main` and push. GitHub Pages rebuilds from `main`;
      verify the live URL loads, the reader shows the placeholder
      ("In review — not yet published"), and magic-link sign-in works.
- [ ] Set up the revision-worker hook (separate task — not in this repo).

## Files on branch `pipeline`

- `index.html` — Supabase-driven reader + admin queue (replaces the
  localStorage prototype).
- `schema.sql` — tables, RLS, RPC, and the Detroit v1 seed.
- `PIPELINE.md` — this file.

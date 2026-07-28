# Benefactor application agent instructions

## Customer, outreach, and autosave invariants

- Treat authenticated identity, organization/customer ownership, lead/contact records, notes, outreach state, autosave, API/WebSocket delivery, and audit history as one coherent contract.
- Derive user, organization, account, campaign, and actor identity from verified authentication and server-side membership. Never trust client-supplied ownership fields without authorization checks.
- Preserve autosave ordering, idempotency, revisions, reconnect/replay behavior, and visible conflict state. Never use timestamps alone to choose a winner or silently overwrite another user's durable change.
- Outreach state must preserve consent, suppression/unsubscribe, bounce/complaint, duplicate-send prevention, campaign eligibility, provider idempotency keys, and rate/concurrency limits. A merge must never re-enable a suppressed address or resend an already recorded delivery.
- Never place credentials, private contact data, email content, customer strategy, enrichment results, or proprietary business data in logs, telemetry, URLs, screenshots, fixtures, prompts, or public artifacts.
- Keep API models, persistence schema, interfaces, sync behavior, client/UI state, and automation contracts synchronized. Destructive data changes require explicit review and recovery planning.
- Run formatting, linting/type checks, unit/integration tests, authorization/isolation tests, autosave/reconnect/concurrency tests, outreach idempotency/suppression tests, and affected browser/E2E flows before pushing.

## Instruction discovery

Resolve `$PWD`, walk upward through every parent directory to the filesystem root, read every readable lowercase `agents.md` on that ancestor chain, and apply them root-to-leaf. Do not search sibling directories. Deduplicate resolved paths/inodes, avoid symlink cycles, and report unreadable files.

## Synchronize with the remote

Before editing, inspect `git status`, the current branch, configured remotes, and the default branch. Run `git fetch --all --prune` and create the feature branch from the latest remote default branch, not a stale local copy. Fetch again before pushing and incorporate upstream changes according to repository policy.

- avoid git rebase in favor of git merge.
- Never discard remote commits, force-push, rewrite shared history, bypass review, or bypass required CI.

## Resolve Git conflicts semantically

Resolve conflicts by understanding and combining both sides' intent. Do not mechanically choose `ours`, `theirs`, current, or incoming changes. Produce the conceptually correct result while preserving authenticated ownership, customer isolation, autosave revisions/idempotency, outreach consent and suppression, duplicate-send prevention, rate limits, privacy, schema/API/client alignment, tests, documentation, configuration, and user behavior. Rebuild generated clients, schemas, fixtures, or lockfiles from merged canonical source rather than selecting one side's output. An ancestry-only bookkeeping merge is acceptable only when content is already integrated or intentionally obsolete and that fact is independently compared, documented, and verified; it must never replace reconciliation of live competing changes. If intentions are incompatible, make the smallest explicit design decision and document it in the pull request.

After resolving:

1. Reread every affected file from the top, not only conflict hunks.
2. Run all relevant application, authorization, autosave, outreach suppression/idempotency, database, and browser tests.
3. Search the entire worktree for unresolved conflict markers:

   ```sh
   grep -RInE '^(<<<<<<<|=======|>>>>>>>)' --exclude-dir=.git .
   ```

4. If any marker, duplicate send path, lost revision, suppression regression, privacy leak, or suspicious partial resolution remains, repeat semantic resolution from the top and rerun validation.

A conflict is resolved only when customer, autosave, and outreach behavior is conceptually coherent and verified, not merely when Git accepts the files.
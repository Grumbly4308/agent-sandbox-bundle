# Phase B — the first run on a real host

This directory is an archive. It holds the plan for the first run of
version 2 against Podman, the tick-box cards that were followed, the
filled-in results, and the logs, exactly as they were on 2026-10-10. The
current summary of what is proven is [docs/08-verification.md](../../08-verification.md);
read that first.

| File | What it is |
|---|---|
| [plan.md](plan.md) | The test plan: what to set up, what to run, what a good result looks like, every `verify` check by name, and what was unproven before the run. Written before the run; its status columns say "not run here". |
| [test-card.md](test-card.md) | The same plan as a tick-box card, with the install and onboarding steps spelled out. |
| [test-card-subscriptions.md](test-card-subscriptions.md) | Section F of the card (the keyring, Claude and Codex subscription logins) written out step by step for the host it was run on. |
| [results.md](results.md) | The filled-in table, every failure with its fix, what was noticed and left alone, what was closed without a check, and what is still to prove. |
| [logs/](logs/) | One log per step, named by its step; a `-N` suffix is a re-run after a fix. |

The scripts the plan refers to are still where they were: `tests/phase-b/`.

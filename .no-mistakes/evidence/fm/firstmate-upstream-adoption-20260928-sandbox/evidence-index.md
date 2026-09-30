# Test-phase evidence

Candidate: `c3df8736c5225ff8c827e1ba6156f8c5cb78da25`.
Pinned parent: `eb219c80f6bba1e89ffe77ec51c517abbab76a1c`.
Installed-base ancestry: `5821c237e1990aa343971928e183fc3db1b1d314`.
Both required ancestries were verified with `git merge-base --is-ancestor`.
No tracked source or test changes were made.

## Results and limits

Host-side startup, same-session reentry through a real paused sweep, identity-override refusal, task-lease continuity, watcher lifecycle, event capture, and incomplete-startup recovery passed through the real CLI.
`host-sandbox-identity.log` shows matching identities with host `systemd` PID 1 and native sandbox `codex` PID 1.
`native-cross-namespace-report.log` shows an actual host worker reported as unknown in the native sandbox, followed by that same generation's completed report.
The native sandbox was invoked through `codex sandbox`; this is not evidence from the Codex App's own restricted tool transport.
Its default filesystem was read-only even for the worktree, so cross-context mutations were not exercised there.
The watcher, claim-preservation, and incomplete-startup adversarial checks used actual running processes with deliberately changed persisted namespace fields; they prove rejection of those inputs, not actual App cross-context contention.

The final-head `fm-spawn` worker lifecycle smoke remains untested.
Installed `tasks-axi` is 0.2.5 and `quota-axi` is 0.1.29; this candidate requires at least 0.2.6 and 0.1.51 respectively.
Make the approved task-private exact versions available to the phase and provide the already-authorized worker smoke environment within the current worktree boundary to rerun it.
No tools, credentials, trust entries, launch permissions, or global configuration were changed.
The reported earlier smoke at `71cefb84` was not rerun and is not counted as evidence for this head.
Other primary harnesses are absent from PATH; their selected portable regressions are not live harness proof.
Main-home preservation records and historical operational files were not read or published by this phase.
The CLI compatibility delta has no rendered UI requiring screenshots.

## First attempts and corrections

`product-results.json` and `product-transcript.log` describe the initial attempts, not the final event verdict.
The event driver initially supplied an illegal newline-bearing argument and a state directory created with the ambient permissive umask.
Correcting the argument and making this disposable state directory private produced the passing `event-transcript.log` and `captured-event.result`.
The initial native sandbox guard could not create the shared test helper's temporary files on its read-only filesystem, including after TMPDIR was moved inside the worktree.
The subsequent read-only library probe required no writes and passed in both actual namespaces.
`live-sweep-reentry.log` stopped on a test assertion that matched explanatory STARTUP TRUNCATED prose in a complete successful digest.
The corrected failure-banner assertion passed on another live run; see `live-sweep-reentry-retry.log` and its complete digest.
Every first-attempt evidence file is retained.

The initial startup regression reported a 4-second takeover refusal while independent product checks were running.
The original assertion requires less than 4 seconds and was not changed.
Controlled serial runs used the same corrected behavioral fixture against a pinned-parent source snapshot and the candidate.
Both passed, including the instrumented lock traces: parent 1.359 seconds, candidate 2.014 seconds, with 28 versus 43 traced ps calls.
The candidate adds ancestry work; the trace supports execution overhead rather than waiting for the 10-second sweep to end.
The entire targeted startup script then passed serially in `startup-serial.log`.
The failed timing log remains in `fm-startup-network.log`.

## Targeted executable checks

- `bash tests/fm-codex-session-identity-live-e2e.test.sh`, twice from native host tool calls.
- `bash tests/fm-codex-session-lock.test.sh`.
- `bash tests/fm-startup-network.test.sh`, initial and controlled serial runs.
- `test_lock_takeover_stays_read_only_while_a_sweep_holds_the_lease`, isolated against pinned parent and candidate, with and without lock tracing.
- `bash tests/fm-procevent.test.sh --namespace-only`.
- Watcher selectors: `test_watch_restart_preserves_unproven_namespace`, `test_stale_watch_clear_requires_owner_proof`, `test_stale_watch_clear_serializes_publication_and_removal`, `test_lock_single_winner_under_concurrency`, `test_lock_does_not_steal_live_lock`, `test_lock_steals_dead_pid_lock`.
- Ancestry selectors: version-named session recognition, namespace PID 1, same-session refresh under the claim lock, waiting confirmation refusing a replacement owner, both sidecar rollback paths, and verified reclaim.
- Nudge selectors: owned-lock silence, namespace PID 1 without identity, clear/compact reemission, and rejection of previous-owner completion.

The nudge namespace selector capability-skipped because standalone unprivileged `unshare` was denied.
The temporary footer-only selector runners retained the existing assertions and were removed during cleanup.
Portable fixture tests are not labeled live vendor evidence.
No full repository suite, linter, formatter, static analyzer, pipeline control, push, PR, CI, merge, or live-home activation was performed.

## Accepted deferrals

These decisions remain unchanged and are not new test findings:

| ID | Deferred behavior |
| --- | --- |
| review-03 | Task metadata may be removed after incomplete teardown. |
| review-05 | Repeated hold answers can resolve the wrong hold occurrence. |
| review-06 | Inbox acknowledgement reporting depends on announcement state. |
| review-07 | Inbox reservation recovery can republish an acknowledged note. |
| review-08 | Inherited task-delivery source-text assertions remain. |
| review-09 | Inherited trace-context source-only assertions remain. |
| review-10 | Inherited verifier test pin differs from the workflow pin. |
| review-12 | Merge-check supersession groups by name across producers. |
| review-14 | Extension invocation cleanup lacks namespace-qualified ownership proof. |
| review-15 | Away-daemon reconciliation lacks conservative namespace handling. |

Their exact descriptions and decisions are retained by the outer run; no private operational records were copied into this public evidence directory.

## Cleanup

One deferred worker left by the initially failed regression was stopped by its exact process identity before cleanup.
No remaining processes referenced the test homes.
All disposable homes, source snapshots, temporary fixture data and selector runners were removed.
See `cleanup.log`; evidence files remain in this directory.

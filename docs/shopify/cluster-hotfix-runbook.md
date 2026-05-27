# Cluster hotfix runbook

Use this runbook only when a server-touching TigerBeetle fork fix must ship on the current upstream release instead of piggy-backing on the next upstream release.

Normally, server-touching changes ship with the next upstream `X.Y.Z` release as `X.Y.Z-shopify1`. This runbook covers the emergency exception: shipping server code in a same-`X.Y.Z` fork bump, such as `0.17.0-shopify2`.

## Defaults

- Use full stop/start. Do not use rolling restart for cluster hotfixes.
- Rollback means switching to the shadow cluster, not downgrading the hotfixed main cluster in place.
- This runbook assumes the shadow cluster is healthy and can be caught up using the source-of-record replay strategy described in [ShopifyFRS/fintech-foundations#1138][replay-rfc]. If not, stop and define a separate rollback plan before proceeding.

Because `Release.value` does not change, TigerBeetle will not coordinate this as a normal multiversion upgrade.

## Approval

Get explicit approval from the TigerBeetle fork maintainer and the Ledger Service owner/on-call. Record the approval in the release PR or incident notes.

## Create release PR

Make the necessary change and run the `shopify-release` script as usual to open a release pull request, adding the `skip-versioning-check` to the commit message with a note about why the hotfix is required.

## Before release

- Confirm the hotfix must ship on the current upstream release instead of piggy-backing on the next upstream release, for example because we do not want to take the upstream patch's other changes yet.
- Confirm (ideally on staging) that the change is safe for existing data files and does not modify the storage/datafile format.
- Confirm the PR uses `skip-versioning-check` and explains why.
- Confirm CI passes.
- Confirm the shadow cluster is healthy and available as the rollback target.
- Recommended: test the stop/start procedure in staging.
- Record the previous artifact, hotfix artifact, and binary/package hashes.

## Release

Merge the PR to publish the `X.Y.Z-shopify<N+1>` release to Cloudsmith. The release notes should call out that this is a cluster hotfix.

## Production rollout

1. Set mainteance mode and pause or drain Ledger traffic if required.
2. Stop the main TigerBeetle cluster.
3. Stop the shadow TigerBeetle cluster.
4. Install the hotfix artifact on every main-cluster replica.
5. Keep the shadow cluster on the previous known-good artifact.
6. Verify the artifact/hash on every replica in both clusters.
7. Start the main cluster.
8. Start the shadow cluster.
9. Verify main-cluster health.
10. Resume traffic to the main cluster.

Keep the shadow cluster on the previous known-good artifact until the hotfix is accepted as safe.

## Verification

- Main replicas are running the hotfix artifact.
- Shadow replicas are running the previous known-good artifact.
- The main cluster is healthy.
- Ledger Service errors and latency are normal.
- There are no TigerBeetle panic or restart loops.
- A safe canary or read check succeeds.

## Rollback

Rollback means switching to the shadow cluster, not downgrading the hotfixed main cluster in place.

If the hotfixed main cluster has issues:

1. Set maintenance mode and pause or drain Ledger traffic.
2. Stop or isolate the main cluster.
3. Use the replay strategy to catch the shadow cluster up from the source of record.
4. Verify the shadow cluster is healthy.
5. Switch Ledger Service traffic to the shadow cluster.

Do not upgrade the shadow cluster to the hotfix artifact until the hotfix is accepted as safe.

## Follow-up

- Document the rollout and outcome in the release PR or incident notes.
- Decide whether to roll forward, wait for the next upstream-piggyback release, or abandon the hotfix.

[replay-rfc]: https://github.com/ShopifyFRS/fintech-foundations/issues/1138

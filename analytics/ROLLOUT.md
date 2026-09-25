# Production rollout and acceptance

## Current evidence

The local implementation counts each episode during its first 24 hours, 7 days, and 30 days after release, plus recorded lifetime. The UI has no daily aggregate view. Synthetic tests cover full and partial delivery, overlapping ranges, probes, HEAD and bot exclusions, IPv6 identity, transaction rollback, import replay, publication-window boundaries, missing history, and YouTube episode mapping. These tests do not prove production routing or real platform totals.

Production acceptance remains open. Do not describe the system as deployed or the historical audio totals as known until the checks below pass.

## Rollout sequence

1. Publish and review the site branch, including its workflow changes. The GitHub credential must have permission to write workflow files. Merge the site implementation before deploying infra with `bitflip_site_ref: main`.
2. Set the documented `vault_metrics_*` values in the encrypted infra vault. Keep plaintext credentials out of Git, screenshots, and PR descriptions.
3. Run `Deploy Audio Worker` with `deploy_audio=false`. Verify the event bucket is private, has the two-day lifecycle rule, and is readable/deletable by the metrics credential.
4. On the podcast tailnet, run the infra playbook. Verify the image builds, SQLite volume is writable by UID 10001, and the collector successfully loads all published episodes and polls R2.
5. Verify authenticated access at `https://metrics.komodo-gecko.ts.net`, rejection without dashboard credentials, HTTPS through Tailscale Serve, and no public Funnel exposure. Verify the Dashy link and preservation of all existing Dashy sections.
6. Exercise the Worker against a separate test audio object with known size and duration before enabling production routing. Check full GET, prefix and suffix ranges, overlapping ranges, 416 responses, HEAD, conditional 304, cancellation, and bot requests. Reconcile the resulting qualified counts with the known requests; make sure validation traffic is absent from published episode totals.
7. Deploy the Worker with `deploy_audio=true`. Verify every RSS enclosure and website play/download URL still returns the expected object, content type, length, and byte-range response. Confirm new events reach the private bucket and disappear only after import. Confirm source audio objects are never deleted.
8. Confirm one real episode count against retained request evidence, then confirm duplicate and bot exclusions. Record the production collection start and any known outages. A first event timestamp alone does not prove continuous coverage.
9. Authorize YouTube Analytics with read-only scope and reconcile at least one video's views and watch minutes against the channel export for identical dates. Import a Spotify per-episode export and reconcile its declared metric and date range. Keep public YouTube view snapshots separate from authorized Analytics reports.
10. Take a SQLite backup, restore it into a separate directory, and confirm episode totals and import markers survive. Verify the collector health failure path when R2 polling stops and recovery after it resumes.

## Measurement limits requiring operator review

The download method is documented in README.md and is not IAB certified. The current one-minute threshold uses episode average bitrate. Unknown audio headers use complete-file counting. The user-agent bot filter is a basic exclusion list; comprehensive maintained network exclusions and anomaly review have not been established. Review those against IAB v2.2 before making any compliance claim.

Historical audio counts require retained request evidence. Operation totals and public platform views cannot reconstruct qualified downloads. Import chronological history before starting live collection when possible. Overlapping historical datasets after identifier retention has expired cannot be reliably deduplicated and must not be merged as if they were complete, independent totals.

## Access currently needed

- GitHub credential with workflow write permission for the site branch.
- Reachability of `infra-svcs.komodo-gecko.ts.net` from the deployment machine.
- Ansible vault unlock and the new metrics credentials.
- YouTube channel OAuth authorization, Spotify exports, and any retained historical request logs for source reconciliation.

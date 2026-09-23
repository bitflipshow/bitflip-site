# BitFlip podcast analytics

This service keeps podcast download counts in SQLite on `infra-svcs` and serves a private dashboard through the `metrics` Tailscale node. The audio Worker writes short-lived request events into a **private** R2 bucket. The service polls that bucket every five minutes, counts qualified downloads, and deletes each processed event. No public ingest endpoint is needed.

## Metrics

- **RSS audio downloads:** Counts an episode once for each IP address and user agent pair in a rolling 24-hour window, after enough unique bytes are served to cover its measured ID3 header and approximately one minute of audio. Reassembled range requests count once. HEAD, two-byte probes, common bots, and watchOS duplicates are excluded. The dashboard shows first-24-hour, first-7-day, first-30-day, and recorded lifetime counts for each episode, plus an episode comparison chart for the first 30 days. Windows start at the publication timestamp in the RSS metadata; date-only publications use midnight UTC. Completed windows retain their totals. Unavailable history is shown as a dash; partially observed windows and windows still collecting are labeled. Spotify and YouTube columns show imported lifetime totals.
- **YouTube:** Authorized channel reports provide daily video views and watch minutes. These remain separate from audio downloads.
- **Spotify:** A creator-exported CSV provides plays or streams. These remain separate from audio downloads. Spotify's public Web API does not provide creator analytics.

This implementation is **not IAB certified**. It follows selected [IAB v2.2 measurement rules](https://iabtechlab.com/wp-content/uploads/2024/02/PodcastMeasurement_v2.2_final.pdf), but its one-minute threshold uses average episode bitrate, and its bot filter needs ongoing review. The count represents file delivery, not a confirmed listen. A disconnect after bytes leave the Worker may still be counted if the bytes already meet the threshold.

## Deployment

Production Compose and Tailscale Serve configuration live in `bitflipshow/bitflip-infra`, under `services/infra-svcs/09-metrics`. Its Ansible playbook checks out this repository and builds the Docker image. The metrics node is private at `https://metrics.komodo-gecko.ts.net`; Tailscale Funnel is disabled. Dashy receives a managed link from the same playbook.

Before deploying:

1. Merge the site and infra changes. Worker deployment is manual (`Deploy Audio Worker` in GitHub Actions), so merging does not switch the audio route. Confirm the audio Worker route can supersede the current R2 custom domain on `audio.bitflip.show` in a staging zone. Keep the enclosure URL unchanged.
2. In the infra Ansible vault, set `vault_metrics_admin_password`, `vault_metrics_hash_secret`, `vault_metrics_r2_account_id`, `vault_metrics_r2_access_key_id`, and `vault_metrics_r2_secret_access_key`. Give the R2 key list/read/delete access **only** to `bitflip-analytics-events`. Add optional `vault_metrics_youtube_client_id`, `vault_metrics_youtube_client_secret`, and `vault_metrics_youtube_refresh_token` for YouTube history.
3. Before starting the metrics service, run `Deploy Audio Worker` with `deploy_audio=false` to provision the private event bucket without switching audio routing. The manual site Worker deployment also creates the private `bitflip-analytics-events` bucket and its two-day expiration rule. Confirm `r2.dev` and custom domains remain disabled on that bucket. Confirm the deployment token has R2 bucket management permission.
4. Run the infra Ansible playbook from a machine on the `komodo-gecko` tailnet. Verify `/health`, the authenticated dashboard, R2 poll logs, and Dashy link. The current local machine may not resolve that tailnet host.
5. Run the `Deploy Audio Worker` workflow with `deploy_audio=true` after the metrics service is healthy. Check live HEAD, full GET, short range, suffix range, invalid range, and site/RSS playback on a non-production test episode before switching production traffic. Confirm the R2 event bucket fills briefly and drains within five minutes.

The local `analytics/compose.yaml` is for development only. Copy `.env.example` to `.env`, set local values, and run `docker compose -f analytics/compose.yaml up --build`. The production service uses infra repo Compose and has no published port.

## Historical data

- YouTube sync queries from the earliest episode date, with pagination. The first successful sync backfills available daily views and watch minutes for matching video IDs.
- Spotify for Creators exports CSV on the web. Import each exported chart with explicit column names; example:

  ```sh
  docker compose exec metrics python -m app import-spotify /data/spotify.csv plays Date Plays Episode
  ```

  `Episode` is optional; omit it for a show-level export. Episode values must be numeric BitFlip episode numbers. Imports upsert by platform, metric, day, and episode; rerunning the same export is safe. Show-level rows are stored for reference but are not displayed in the per-episode dashboard. Exports with a different shape must first be converted to these columns. Store CSV outside the public site and delete it after verification.
- R2 Data Access Logs and Cloudflare request logs are useful only if they were previously enabled and retained. R2 does not retroactively create logs. R2 bucket operation totals cannot reconstruct episode-level, deduplicated downloads. Do not add estimated historical requests to qualified download totals.
- If you have retained per-request logs with method, response status, actual byte range served, IP, user agent, filename, full file size, and timestamp, convert them to Worker-format JSONL and run `python -m app import-events /data/history.jsonl`. Sort by `timestamp` ascending. The import is idempotent for identical event records. Native R2 access logs lack the actual byte range, so they cannot alone support this qualified backfill.

## Operations and recovery

- `/health` checks SQLite, episode metadata, and R2 poll freshness. It returns HTTP 503 after 15 minutes without a successful poll. `/api/summary` returns per-episode dashboard data after HTTP Basic authentication. Put the site behind Tailscale Serve HTTPS; never expose its local HTTP listener directly to the Internet.
- Raw event objects expire after two days even if the poller fails. Successfully imported objects are deleted immediately. SQLite stores hashed IP and user-agent identity for at most 48 hours; request sessions expire after 48 hours. Aggregate download timestamps and per-episode counts persist until manually removed. The dashboard marks the start of available audio coverage and labels lifetime as recorded lifetime.
- Back up the SQLite database with `sqlite3 /opt/appdata/apps/metrics/data/analytics.sqlite3 '.backup /path/to/backup.sqlite3'` from the host. Restore with the service stopped. Keep the hash secret stable across restarts or rolling deduplication will reset.
- Inspect container logs for `R2 poll failed`, `Manifest sync failed`, or `YouTube sync failed`. If the event bucket grows beyond five minutes of traffic, check R2 credentials, manifest availability, and network access from `infra-svcs` to Cloudflare. If the bucket reaches the two-day expiration, unprocessed events are permanently lost.
- Source metric differences are expected. YouTube views, Spotify plays, and RSS downloads have different definitions and can include the same listener. Do not sum them into an audience total.

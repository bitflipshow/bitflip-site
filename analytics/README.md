# BitFlip podcast analytics

This service keeps podcast download counts in SQLite on `infra-svcs` and serves a private dashboard through the `metrics` Tailscale node. The audio Worker writes short-lived request events into a **private** R2 bucket. The service polls that bucket every five minutes, counts qualified downloads, and deletes each processed event. No public ingest endpoint is needed.

## Metrics

- **RSS audio downloads:** Counts an episode once for each normalized IP address and user agent pair in a rolling 24-hour window, after enough unique bytes are served to cover its measured ID3 header and approximately one minute of audio. IPv4 addresses are canonicalized; IPv4-mapped IPv6 addresses use their IPv4 form, and other IPv6 addresses are truncated to /64 before hashing. Reassembled range requests count once. HEAD, two-byte probes, common bots, and watchOS duplicates are excluded. The dashboard shows first-24-hour, first-7-day, first-30-day, and recorded lifetime counts for each episode, plus an episode comparison chart for the first 30 days. Windows start at the episode's first counted download on or after its release day (date-only publications use midnight in `RELEASE_TZ`, default `America/New_York`), so no publish time is needed. Episodes released before collection began fall back to the release day and are labeled partial or unavailable. Events whose file size differs from the manifest stay in R2 and are retried after the next manifest sync; malformed events are moved to `rejected/` so they cannot block collection. Completed windows retain their totals. Unavailable history is shown as a dash; partially observed windows and windows still collecting are labeled. Spotify and YouTube columns show imported lifetime totals.
- **YouTube:** Public lifetime view snapshots refresh daily without credentials using pinned yt-dlp. Each count has a last-checked timestamp; failures retain previous counts, and changed video IDs invalidate old snapshots. The refresh runs separately so it cannot delay audio event ingestion. Public counts cannot reconstruct historical release windows. Authorized channel reports provide daily video views and watch minutes. These remain separate from audio downloads.
- **Spotify:** A creator-exported CSV provides plays or streams. These remain separate from audio downloads. Spotify's public Web API does not provide creator analytics.

This implementation is **not IAB certified**. It follows selected [IAB v2.2 measurement rules](https://iabtechlab.com/wp-content/uploads/2024/02/PodcastMeasurement_v2.2_final.pdf), but its one-minute threshold uses average episode bitrate, and its bot filter needs ongoing review. The count represents file delivery, not a confirmed listen. A disconnect after bytes leave the Worker may still be counted if the bytes already meet the threshold.

## Browsing the catalogue

The home page automatically shows the latest 10 episodes by publication date. This is a display limit only: every episode keeps collecting downloads and its history is retained.

`/episodes` is the searchable archive, with 25 episodes per page and comparison charts for first 24 hours, first 7 days, first 30 days, or recorded lifetime. `/episodes/<number>` is a permanent per-episode page with all four milestone charts and separate platform totals. There are no daily aggregate views.

The JSON endpoints mirror these views: `/api/summary` returns the latest 10, `/api/episodes?page=2&q=title` returns a bounded archive page, and `/api/episodes/<number>` returns one episode. Responses include total matches, offset, and page size. Historical totals use grouped queries and episode/time indexes rather than issuing a separate query for each metric of every episode.

## Deployment

Production Compose and Tailscale Serve configuration live in `bitflipshow/bitflip-infra`, under `services/infra-svcs/09-metrics`. Its Ansible playbook checks out this repository and builds the Docker image. The metrics node is private at `https://metrics.komodo-gecko.ts.net`; Tailscale Funnel is disabled. Dashy receives a managed link from the same playbook.

Before deploying:

1. Merge the site and infra changes. Worker deployment is manual (`Deploy Audio Worker` in GitHub Actions), so merging does not switch the audio route. Confirm the audio Worker route can supersede the current R2 custom domain on `audio.bitflip.show` in a staging zone. Keep the enclosure URL unchanged.
2. In the infra Ansible vault, set `vault_metrics_hash_secret`, `vault_metrics_r2_account_id`, `vault_metrics_r2_access_key_id`, and `vault_metrics_r2_secret_access_key`. Give the R2 key list/read/delete access **only** to `bitflip-analytics-events`. Add optional `vault_metrics_youtube_client_id`, `vault_metrics_youtube_client_secret`, and `vault_metrics_youtube_refresh_token` for YouTube history.
3. Before starting the metrics service, run `Deploy Audio Worker` with `deploy_audio=false` to provision the private event bucket without switching audio routing. The manual site Worker deployment also creates the private `bitflip-analytics-events` bucket and sets its lifecycle rules from `worker/analytics-lifecycle.json` (raw events expire after 14 days, rejected events after 30). The workflow fails if a custom domain is attached to the bucket. Confirm `r2.dev` and custom domains remain disabled on that bucket. Confirm the deployment token has R2 bucket management permission.
4. Run the infra Ansible playbook from a machine on the `komodo-gecko` tailnet. Verify `/health`, the tailnet dashboard, R2 poll logs, and Dashy link. The current local machine may not resolve that tailnet host.
5. Run the `Deploy Audio Worker` workflow with `deploy_audio=true` after the metrics service is healthy. Check live HEAD, full GET, short range, suffix range, invalid range, and site/RSS playback on a non-production test episode before switching production traffic. Confirm the R2 event bucket fills briefly and drains within five minutes.

The local `analytics/compose.yaml` is for development only. Copy `.env.example` to `.env`, set local values, and run `docker compose -f analytics/compose.yaml up --build`. The production service uses infra repo Compose and has no published port.

## Credential provisioning

The manual `Deploy Audio Worker` workflow supports `bootstrap_credentials=true` with the infra repository's Actions secrets public key and key ID. It uses `CF_METRICS_BOOTSTRAP_TOKEN` to provision the bucket and create the `bitflip-metrics-events` account token, scoped only to objects in the event bucket. It generates the hash secret, then exports only a GitHub-sealed credential bundle. It refuses to issue a second token with the same name; recover the previous encrypted artifact rather than rerunning token creation.

The sealed payload is written to the infra repository's temporary `METRICS_BOOTSTRAP_JSON` secret through the GitHub API. Running its `Deploy infra-svcs` workflow with `configure_metrics_only=true` verifies R2 list/write/read/delete, confirms access to the audio bucket is denied, and exports the updated Ansible-encrypted vault. This mode does not deploy services. Commit the encrypted artifact as `group_vars/secrets.yaml`, then remove the temporary transfer secret. The workflow preserves existing vault entries and refuses to rotate an existing metrics value implicitly.

After rollout, revoke the temporary Cloudflare bootstrap token and remove its GitHub secret. Future provisioning requires a suitably authorized token. The metrics runtime only uses the restricted R2 key stored in the vault.

## Historical data

- YouTube sync queries from the earliest episode date, with a filter for the episode video IDs, stable day/video sorting, and pagination. Requests use the read-only `https://www.googleapis.com/auth/yt-analytics.readonly` OAuth scope. The first successful sync backfills available daily views and watch minutes for matching video IDs.
- Spotify for Creators exports CSV on the web. Import each exported chart with explicit column names; example:

  ```sh
  docker compose exec metrics python -m app import-spotify /data/spotify.csv plays Date Plays Episode
  ```

  `Episode` is optional; omit it for a show-level export. Episode values must be numeric BitFlip episode numbers. Imports upsert by platform, metric, day, and episode; rerunning the same export is safe. Show-level rows are stored for reference but are not displayed in the per-episode dashboard. Exports with a different shape must first be converted to these columns. Store CSV outside the public site and delete it after verification.
- R2 Data Access Logs and Cloudflare request logs are useful only if they were previously enabled and retained. R2 does not retroactively create logs. R2 bucket operation totals cannot reconstruct episode-level, deduplicated downloads. Do not add estimated historical requests to qualified download totals.
- If you have retained per-request logs with method, response status, actual byte range served, IP, user agent, filename, full file size, and timestamp, convert them to Worker-format JSONL and run `python -m app import-events /data/history.jsonl`. Sort by `timestamp` ascending. The import is idempotent for identical event records. While an import runs, it pauses the live service's identity cleanup (via a heartbeat in `sync_state`) so historical sessions and dedupe state survive until the import finishes. Native R2 access logs lack the actual byte range, so they cannot alone support this qualified backfill.

## Operations and recovery

- The server listens on `BIND_HOST` (default `0.0.0.0`); production sets `127.0.0.1` so only Tailscale Serve can reach it.
- `/health` checks SQLite, episode metadata, and R2 poll freshness. It returns HTTP 503 after 15 minutes without a successful poll. `/api/summary` returns per-episode dashboard data without an app login; access is restricted by the tailnet. Tailscale Serve provides HTTPS and tailnet access control. Funnel must remain disabled and the production container must have no published port.
- Raw event objects expire after 14 days even if the poller fails. Successfully imported objects are deleted immediately; malformed objects move to `rejected/` and expire after 30 days. Processed-event markers for live R2 events are pruned after 30 days; the coverage start is kept in `settings`. SQLite stores hashed IP and user-agent identity for at most 48 hours; request sessions expire after 48 hours. Aggregate download timestamps and per-episode counts persist until manually removed. The dashboard marks the start of available audio coverage and labels lifetime as recorded lifetime.
- Back up the SQLite database with `sqlite3 /opt/appdata/apps/metrics/data/analytics.sqlite3 '.backup /path/to/backup.sqlite3'` from the host. Restore with the service stopped. Keep the hash secret stable across restarts or rolling deduplication will reset.
- Inspect container logs for `R2 poll failed`, `Manifest sync failed`, or `YouTube sync failed`. If the event bucket grows beyond five minutes of traffic, check R2 credentials, manifest availability, and network access from `infra-svcs` to Cloudflare. If the bucket reaches the 14-day expiration, unprocessed events are permanently lost. Set `ALERT_WEBHOOK_URL` (a Discord-compatible webhook) to get one message when R2 polling has failed for 30 minutes and one when it recovers. This cannot report a stopped container.
- Source metric differences are expected. YouTube views, Spotify plays, and RSS downloads have different definitions and can include the same listener. Do not sum them into an audience total.

### Public YouTube counts

Run `python -m app sync-youtube-public` for an immediate refresh. The background loop checks every six hours and refreshes snapshots older than 24 hours. Failed pages retry at the next check, with existing snapshots retained and dated. Each failing video is logged; the sync is only marked failed when every due video fails, so one private or deleted video does not hide the health of the rest. If YouTube blocks the server or changes its page format, inspect `Public YouTube sync failed` and update the pinned extractor as needed (Dependabot opens weekly pip update PRs for `analytics/requirements.txt`). This public-page integration has no availability guarantee.

For a snapshot collected elsewhere, `python -m app import-youtube-public /data/snapshots.json` accepts a JSON array of `video_id`, integer `views`, and Unix `observed_at` in seconds, no later than now. Any invalid row rejects the whole file. Only videos in the manifest are accepted; older snapshots cannot overwrite newer ones. Public totals are never added to daily Analytics reports or audio downloads. Spotify has no public counts in this integration; its columns remain unavailable without a creator export.

### Dashboard layout

The overview uses compact metric summaries scoped to the episodes currently shown, one comparison chart, and a dense episode table. Audio downloads and public YouTube views share a chart with independent source toggles and a common scale; selecting a single source rescales it. The table keeps source definitions separate and never sums them into a cross-platform audience total. First-24h, 7d, and 30d controls apply to audio; public YouTube release-window history remains unavailable. Source definitions are expandable, and snapshot freshness is visible below the table. Mobile navigation stays inline and wide tables scroll within their panel.

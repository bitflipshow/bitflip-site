"""Server-rendered episode views; all chart values come from recorded metrics."""
import html
from datetime import datetime, timezone
from urllib.parse import urlencode

LABELS = {'24h': 'First 24 hours', '7d': 'First 7 days', '30d': 'First 30 days', 'lifetime': 'Recorded lifetime'}


def download_value(episode, key, coverage):
    status = episode['window_status'].get(key, 'recorded')
    if coverage is None or status == 'unavailable':
        return None, 'Unavailable'
    return episode[key], status


def value_text(value, status):
    if value is None:
        return '—'
    suffix = f' <small>{html.escape(status)}</small>' if status in ('partial history', 'collecting') else ''
    return f'{value:,}' + suffix


def chart(items):
    """Accessible horizontal comparisons with a bounded number of rows per page."""
    peak = max([item[1] or 0 for item in items] + [1])
    rows = []
    for label, value, status, url in items:
        label = html.escape(label)
        if url:
            label = f'<a href="{url}">{label}</a>'
        width = (value or 0) / peak * 100
        rows.append(f'<li><span class="chart-label">{label}</span>'
                    f'<span class="track" aria-hidden="true"><span style="width:{width:.2f}%"></span></span>'
                    f'<span class="chart-value">{value_text(value, status)}</span></li>')
    return '<ol class="chart">' + ''.join(rows) + '</ol>'


def dashboard(data, mode='recent', metric='lifetime'):
    episodes = data['episodes'][:10] if mode == 'recent' else data['episodes']
    coverage = data['coverage_start']
    query = data.get('query', '')
    title = 'Latest 10 episodes' if mode == 'recent' else 'Episode archive'
    if mode == 'episode':
        title = f'#{episodes[0]["number"]} {episodes[0]["title"]}'
    subtitle = ('A rolling view of the latest releases. Older episodes remain in the archive.' if mode == 'recent'
                else 'Every episode stays available here. Search by title or episode number.' if mode == 'archive'
                else f'Released {episodes[0]["published"][:10]} · Milestones are measured from release, not from today.')
    coverage_text = ('Recording since ' + datetime.fromtimestamp(coverage, timezone.utc).strftime('%d %b %Y, %H:%M UTC')
                     if coverage is not None else 'Waiting for the first audio delivery event')
    search = ''
    if mode == 'archive':
        search = f'''<form action="/episodes" class="search"><label for="q">Find an episode</label>
<input id="q" name="q" value="{html.escape(query, quote=True)}" placeholder="Title or #number" maxlength="200">
<input type="hidden" name="metric" value="{metric}"><button>Search</button><a href="/episodes">Clear</a></form>'''
    count = data.get('total', len(episodes))
    offset = data.get('offset', 0)
    range_text = f'Showing {offset + 1}–{offset + len(episodes)} of {count} episodes' if episodes else 'No episodes found'
    links = []
    if mode != 'episode':
        base = '/episodes' if mode == 'archive' else '/'
        for key, label in LABELS.items():
            params = {'metric': key}
            if query:
                params['q'] = query
            if mode == 'archive':
                params['page'] = offset // 25 + 1
            current = ' aria-current="true"' if key == metric else ''
            links.append(f'<a href="{html.escape(base + "?" + urlencode(params), quote=True)}"{current}>{label}</a>')
        items = [(f'#{e["number"]} {e["title"]}', *download_value(e, metric, coverage), f'/episodes/{e["number"]}') for e in episodes]
        chart_title = LABELS[metric] + ' downloads'
    else:
        items = [(label, *download_value(episodes[0], key, coverage), None) for key, label in LABELS.items()]
        chart_title = 'Download milestones'
    graph = chart(items) if episodes else '<p>No matching episodes. Try another title or number.</p>'
    public_chart = chart([(f'#{e["number"]} {e["title"]}', e.get('youtube_public_views'), '', f'/episodes/{e["number"]}') for e in episodes]) if episodes else ''
    rows = []
    for e in episodes:
        downloads = ''.join(f'<td>{value_text(*download_value(e, key, coverage))}</td>' for key in LABELS)
        external = ''.join(f'<td>{e[key]:,.0f}</td>' if key in e else '<td>—</td>'
                           for key in ('spotify_plays', 'spotify_streams', 'youtube_views', 'youtube_watch_minutes'))
        public = e.get('youtube_public_views')
        if public is not None:
            checked = datetime.fromtimestamp(e['youtube_public_observed_at'], timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
            external += f'<td>{public:,}<small>Public lifetime · {checked}</small></td>'
        else:
            external += '<td>—<small>Public count unavailable</small></td>'
        rows.append(f'<tr data-episode="{e["number"]}"><th scope="row"><a href="/episodes/{e["number"]}">'
                    f'#{e["number"]} {html.escape(e["title"])}</a><small>{e["published"][:10]}</small></th>{downloads}{external}</tr>')
    table = ('''<div class="scroll"><table><caption>Per-episode metrics</caption><thead><tr><th>Episode</th>
<th>First 24h</th><th>First 7d</th><th>First 30d</th><th>Recorded lifetime</th><th>Spotify plays</th>
<th>Spotify streams</th><th>YouTube reported views</th><th>YouTube watch minutes</th><th>YouTube public views</th></tr></thead><tbody>'''
             + ''.join(rows) + '</tbody></table></div>') if episodes else ''
    pagination = ''
    if mode == 'archive':
        page = offset // 25 + 1
        def page_link(number, label):
            url = '/episodes?' + urlencode({'page': number, 'q': query, 'metric': metric})
            return f'<a href="{html.escape(url, quote=True)}">{label}</a>'
        previous = page_link(page - 1, '← Newer episodes') if page > 1 else '<span></span>'
        following = page_link(page + 1, 'Older episodes →') if offset + len(episodes) < count else '<span></span>'
        pagination = f'<nav class="pagination" aria-label="Archive pages">{previous}<span>Page {page} of {max(1, (count + 24) // 25)}</span>{following}</nav>'
    recent_current = ' aria-current="page"' if mode == 'recent' else ''
    archive_current = ' aria-current="page"' if mode == 'archive' else ''
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)} · BitFlip metrics</title><style>
*{{box-sizing:border-box}}body{{font:16px/1.5 system-ui;margin:0;background:#10171d;color:#e9f2f5}}main,header{{max-width:1360px;margin:auto;padding:24px}}
a{{color:#8fe2c6;text-underline-offset:3px}}a:focus-visible,button:focus-visible,input:focus-visible{{outline:3px solid #8fe2c6;outline-offset:4px}}
header{{display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #38505c;gap:24px;flex-wrap:wrap}}header strong{{font-size:24px}}nav{{display:flex;gap:20px;flex-wrap:wrap}}
[aria-current]{{color:#fff;font-weight:700}}h1{{font-size:clamp(26px,4vw,38px);line-height:1.2;margin:16px 0}}h2{{font-size:20px}}p,small,.meta{{color:#afc4cd}}small{{display:block;font-size:12px}}
.panel{{background:#1d2d36;border:1px solid #38505c;border-radius:12px;padding:22px;margin:24px 0}}.search{{display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin:28px 0}}
input,button{{font:inherit;border-radius:6px;padding:10px 14px;border:1px solid #52717d}}input{{background:#10171d;color:#fff;min-width:250px}}button{{background:#8fe2c6;color:#10171d;cursor:pointer}}
.tabs{{display:flex;gap:16px;flex-wrap:wrap;margin:16px 0 24px}}.chart{{list-style:none;padding:0;margin:0}}.chart li{{display:grid;grid-template-columns:minmax(160px,2fr) minmax(100px,3fr) minmax(100px,1fr);align-items:center;gap:20px;margin:18px 0}}
.chart-label{{font-size:14px}}.chart-value{{text-align:right;font-variant-numeric:tabular-nums}}.track{{display:block;background:#12212a;height:18px;border-radius:3px;overflow:hidden}}.track span{{display:block;height:100%;background:#69d5b0}}
.scroll{{overflow-x:auto}}table{{border-collapse:collapse;width:100%;font-size:14px}}caption{{text-align:left;font-size:20px;font-weight:700;padding:16px 0}}th,td{{padding:14px 12px;border-bottom:1px solid #38505c;text-align:right;vertical-align:top;font-variant-numeric:tabular-nums}}th:first-child{{text-align:left;min-width:250px}}tbody th{{font-weight:500}}thead th{{color:#afc4cd;min-width:95px}}
.pagination{{justify-content:space-between;margin:28px 0}}footer{{margin-top:32px;border-top:1px solid #38505c;padding-top:16px;font-size:13px}}
@media(max-width:650px){{main,header{{padding:18px}}.panel{{padding:16px}}.chart li{{grid-template-columns:minmax(0,1fr) 100px;gap:8px}}.chart-label{{grid-column:1/-1}}input{{min-width:0;width:100%}}}}
</style></head><body><header><strong>BitFlip metrics</strong><nav aria-label="Main"><a href="/"{recent_current}>Latest 10</a><a href="/episodes"{archive_current}>All episodes</a></nav></header><main>
<h1>{html.escape(title)}</h1><p>{html.escape(subtitle)}</p><p class="meta">{html.escape(coverage_text)} · {range_text}</p>{search}
<section class="panel" aria-label="Download chart"><h2>{chart_title}</h2><nav class="tabs" aria-label="Chart metric">{''.join(links)}</nav>{graph}</section><section class="panel" aria-label="YouTube chart"><h2>YouTube public lifetime views</h2>{public_chart}</section>{table}{pagination}
<section class="panel"><h2>Platform data</h2><p>Public YouTube lifetime views refresh daily; each value shows its last successful check. Old snapshots remain visible if a refresh fails. Public counts cannot reconstruct first-24h, 7d, or 30d views.</p><p>YouTube reported views and watch minutes require channel authorization. Spotify plays and streams require a Spotify for Creators CSV export. A dash means unavailable, not zero.</p></section>
<footer><p>First 24h, 7d, and 30d run from each episode’s release in UTC. Recorded lifetime includes only collected history. A dash means unavailable data; partial history marks a missing beginning; collecting marks an open release window.</p>
<p>Spotify and YouTube reports contain totals for imported dates. Public YouTube views are separate lifetime snapshots. They are never added to audio downloads. Older episodes continue collecting after leaving the latest 10.</p></footer>
</main></body></html>'''

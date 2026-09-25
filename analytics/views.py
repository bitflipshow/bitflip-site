"""Compact, episode-first analytics views with distinct platform definitions."""
import html
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode

LABELS = {'24h': 'First 24h', '7d': 'First 7d', '30d': 'First 30d', 'lifetime': 'Lifetime'}
CSS = Path(__file__).with_name('dashboard.css').read_text()
JS = """document.querySelectorAll('[data-source]').forEach(button => {
 button.addEventListener('click', () => {
  const source = button.dataset.source;
  document.querySelector('.comparison').dataset.active = source;
  document.querySelectorAll('[data-source]').forEach(b => b.setAttribute('aria-pressed', String(b === button)));
  const bars = [...document.querySelectorAll('.bar')];
  const visible = bars.filter(b => source === 'all' || b.dataset.kind === source);
  const peak = Math.max(1, ...visible.map(b => Number(b.dataset.value || 0)));
  bars.forEach(b => b.style.height = (Number(b.dataset.value || 0) / peak * 100) + '%');
  const axis = document.querySelector('.axis-max');
  if (axis) axis.textContent = peak.toLocaleString();
 });
});"""


def esc(value):
    return html.escape(str(value), quote=True)


def stamp(value, time=False):
    return datetime.fromtimestamp(value, timezone.utc).strftime('%d %b %Y' + (' · %H:%M UTC' if time else ''))


def download_value(episode, key, coverage):
    status = episode['window_status'].get(key, 'recorded')
    if coverage is None or status == 'unavailable':
        return None, 'Unavailable'
    return episode[key], status


def value_text(value, status=''):
    if value is None:
        return '<span class="unavailable" title="Data unavailable">—</span>'
    flag = '<sup title="' + esc(status) + '">*</sup>' if status in ('partial history', 'collecting') else ''
    return f'<span title="{esc(status)}">{value:,.0f}{flag}</span>'


def duration(episode):
    seconds = episode.get('duration_seconds', 0)
    return f'{seconds // 60}m {seconds % 60:02d}s' if seconds else ''


def comparison(episodes, metric, coverage, mode):
    groups = []
    if mode == 'episode':
        episode = episodes[0]
        for key, label in LABELS.items():
            groups.append((label, None, *download_value(episode, key, coverage),
                           episode.get('youtube_public_views') if key == 'lifetime' else None))
    else:
        for e in reversed(episodes):
            groups.append((f'#{e["number"]}', f'/episodes/{e["number"]}', *download_value(e, metric, coverage),
                           e.get('youtube_public_views') if metric == 'lifetime' else None))
    peak = max([v or 0 for g in groups for v in (g[2], g[4])] + [1])
    columns = []
    for label, url, audio, status, youtube in groups:
        bars = []
        for kind, name, value in [('audio', 'Audio downloads', audio), ('youtube', 'YouTube views', youtube)]:
            note = status if kind == 'audio' else 'public lifetime' if youtube is not None else 'unavailable for this window'
            desc = f'{label} · {name}: {value if value is not None else "unavailable"} · {note}'
            height = (value or 0) / peak * 100
            bars.append(f'<span class="bar-slot" data-kind="{kind}"><span class="bar {kind}" data-kind="{kind}" '
                        f'data-value="{value if value is not None else ""}" style="height:{height:.3f}%" '
                        f'title="{esc(desc)}"><span class="bar-number">{value_text(value)}</span></span></span>')
        label_html = f'<a href="{url}">{esc(label)}</a>' if url else esc(label)
        columns.append(f'<div class="chart-column"><div class="pair">{"".join(bars)}</div><div class="x-label">{label_html}</div></div>')
    return f'<div class="plot"><div class="axis"><span class="axis-max">{peak:,}</span><span>0</span></div><div class="chart-grid" style="min-width:{max(240, len(groups)*28)}px">{"".join(columns)}</div></div>' if groups else '<div class="empty">No matching episodes. Try another title or number.</div>'


def dashboard(data, mode='recent', metric='lifetime'):
    episodes = data['episodes'][:10] if mode == 'recent' else data['episodes']
    coverage, query = data['coverage_start'], data.get('query', '')
    detail = mode == 'episode'
    total, offset = data.get('total', len(episodes)), data.get('offset', 0)
    title = episodes[0]['title'] if detail else 'Episode performance' if mode == 'recent' else 'Episode archive'
    scope = f'Episode {episodes[0]["number"]:02d}' if detail else 'Latest 10' if mode == 'recent' else 'All episodes'
    subtitle = (f'Published {episodes[0]["published"][:10]} · {duration(episodes[0])}' if detail
                else 'Downloads and views across your episodes.')
    coverage_text = f'Audio recording since {stamp(coverage)}' if coverage else 'Audio collection awaiting first event'
    observed = [e['youtube_public_observed_at'] for e in episodes if e.get('youtube_public_observed_at')]
    checked = f'YouTube checked {stamp(min(observed), True)}' if observed else 'YouTube awaiting public counts'
    audio_values = [download_value(e, 'lifetime', coverage)[0] for e in episodes]
    public_values = [e.get('youtube_public_views') for e in episodes]
    spotify_values = [e.get('spotify_plays') for e in episodes]
    def aggregate(values):
        return sum(v for v in values if v is not None) if any(v is not None for v in values) else None
    scope_note = 'This episode' if detail else f'{len(episodes)} episodes shown'
    cards = ''.join(f'<div class="stat"><span class="stat-label">{label}</span><strong class="{color}">{value_text(value)}</strong><span class="stat-note">{note}</span></div>' for label,value,color,note in [
        ('Audio downloads', aggregate(audio_values), 'audio-text', 'Recorded lifetime · ' + scope_note.lower()),
        ('YouTube views', aggregate(public_values), 'youtube-text', f'Public lifetime · {sum(v is not None for v in public_values)}/{len(episodes)} available'),
        ('Spotify plays', aggregate(spotify_values), '', 'Creator export needed' if aggregate(spotify_values) is None else 'Imported dates · ' + scope_note.lower()),
        ('Release windows' if detail else 'Episodes in view', None if detail else len(episodes), '', 'Measured since release' if detail else f'{total} matching episodes' if query else f'{total} episodes in catalogue')])
    if detail:
        cards = cards.replace('<span class="stat-label">Release windows</span><strong class=""><span class="unavailable" title="Data unavailable">—</span></strong>', '<span class="stat-label">Release windows</span><strong class="windows-label">24h / 7d / 30d</strong>')
    links = []
    if not detail:
        for key, label in LABELS.items():
            params = {'metric': key}
            if mode == 'archive':
                params.update(page=offset // 25 + 1, q=query)
            url = ('/episodes' if mode == 'archive' else '/') + '?' + urlencode(params)
            current = ' aria-current="true"' if key == metric else ''
            links.append(f'<a href="{esc(url)}"{current}>{label}</a>')
    rows = []
    for e in episodes:
        cells = ''.join(f'<td class="numeric">{value_text(*download_value(e,key,coverage))}</td>' for key in LABELS)
        yt = e.get('youtube_public_views')
        yt_hint = stamp(e['youtube_public_observed_at'], True) if yt is not None else 'Unavailable'
        rows.append(f'<tr data-episode="{e["number"]}"><td class="episode-number">{e["number"]:02d}</td>'
                    f'<th scope="row"><a href="/episodes/{e["number"]}">{esc(e["title"])}</a>'
                    f'<span class="episode-meta">{esc(e["published"][:10])}<span>{duration(e)}</span></span></th>{cells}'
                    f'<td class="numeric youtube-text" title="Public lifetime · {esc(yt_hint)}">{value_text(yt)}</td>'
                    f'<td class="numeric">{value_text(e.get("spotify_plays"))}</td></tr>')
    table = '<div class="table-scroll"><table><thead><tr><th class="number-heading">#</th><th class="episode-heading">Episode</th><th>First 24h</th><th>First 7d</th><th>First 30d</th><th>Audio lifetime</th><th>YouTube views</th><th>Spotify plays</th></tr></thead><tbody>' + ''.join(rows) + '</tbody></table></div>' if rows else '<p class="empty">No episodes found</p>'
    search = f'<form class="search" action="/episodes"><label class="sr-only" for="q">Find an episode</label><input id="q" name="q" placeholder="Search title or #number" value="{esc(query)}" maxlength="200"><input type="hidden" name="metric" value="{metric}"><button>Search</button></form>'
    pagination = ''
    if mode == 'archive':
        page = offset // 25 + 1
        def page_link(n, label):
            return f'<a href="{esc("/episodes?" + urlencode(dict(page=n,q=query,metric=metric)))}">{label}</a>'
        pagination = f'<nav class="pagination" aria-label="Archive pages"><span>{offset+1 if episodes else 0}–{offset+len(episodes)} of {total}</span><div>{page_link(page-1,"Previous") if page>1 else ""}<span>Page {page} of {max(1,(total+24)//25)}</span>{page_link(page+1,"Next") if offset+len(episodes)<total else ""}</div></nav>'
    chart_note = 'Audio downloads and YouTube views share a scale; each keeps its own definition.' if metric == 'lifetime' or detail else 'YouTube release-window history is unavailable. This window shows audio downloads only.'
    chart_title = 'Download milestones' if detail else 'Compare episodes'
    subtitle_table = 'Episode breakdown' if detail else 'Latest releases' if mode == 'recent' else 'All releases'
    active_recent = ' aria-current="page"' if mode == 'recent' else ''
    active_archive = ' aria-current="page"' if mode != 'recent' else ''
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(title)} · BitFlip metrics</title><style>{CSS}</style></head><body>
<a class="skip" href="#main">Skip to metrics</a><aside class="sidebar"><a class="brand" href="/"><span class="brand-name">bitflip<span class="brand-dot">.</span></span><span class="brand-sub">PODCAST ANALYTICS</span></a>
<div class="nav-label">WORKSPACE</div><nav aria-label="Main"><a href="/"{active_recent}>Overview<span>10</span></a><a href="/episodes"{active_archive}>Episodes<span>All</span></a></nav>
<div class="nav-label links-label">QUICK LINKS</div><nav><a href="https://bitflip.show" target="_blank" rel="noreferrer">Podcast website</a><a href="#data-notes">About these metrics</a></nav><div class="sidebar-bottom"><span>Private workspace</span><small>BitFlip tailnet</small></div></aside>
<div class="workspace"><header class="topbar"><div class="breadcrumb">BitFlip <span>/</span> Metrics <span>/</span> <strong>{esc(scope)}</strong></div><span class="private-badge">TAILNET ONLY</span></header><main id="main">
<div class="page-heading"><div><h1>{esc(title)}</h1><p>{esc(subtitle)}</p></div><span class="scope-badge">{esc(scope)}</span></div>
<section class="stats" aria-label="Metrics for episodes shown">{cards}</section>
<section class="comparison" data-active="all" aria-label="Episode comparison"><div class="panel-heading"><h2>{chart_title}</h2><div class="chart-controls"><div class="source-switch" aria-label="Chart sources"><button data-source="all" aria-pressed="true">Both</button><button data-source="audio" aria-pressed="false">Audio</button><button data-source="youtube" aria-pressed="false">YouTube</button></div><nav class="window-switch" aria-label="Release window">{''.join(links)}</nav></div></div>
<div class="chart-caption"><div class="legend"><span class="audio-text">Audio downloads</span><span class="youtube-text">YouTube views</span></div><span>{'Since release' if detail else LABELS[metric] + ' · by episode'}</span></div>{comparison(episodes,metric,coverage,mode)}<p class="chart-note">{chart_note}</p></section>
<section class="episodes-panel"><div class="panel-heading"><div class="table-title"><h2>{subtitle_table}</h2><span class="count-badge">{len(episodes)}</span></div>{search if not detail else '<a class="archive-link" href="/episodes">Back to all episodes</a>'}</div>{table}{pagination}<div class="table-footnote"><span>* Partial history or still collecting. Hover a value for its status.</span><span>— Unavailable</span></div></section>
<div class="freshness"><span>{esc(coverage_text)}</span><span>{esc(checked)}</span></div><details id="data-notes"><summary>Data sources &amp; definitions</summary><div><p>Audio windows start at each episode’s release: first 24 hours, 7 days, and 30 days. Audio lifetime covers recorded history only. Asterisks flag partial history or an open window. A dash means missing data, not zero.</p><p>YouTube values are public lifetime snapshots, refreshed daily. They cannot reconstruct historical release windows. Old snapshots stay visible if a refresh fails; the timestamp above is the oldest snapshot in this view. Spotify plays require a creator CSV export.</p><p>Audio downloads, YouTube views, and Spotify plays have different definitions. They are displayed together but never added into a combined audience total. Every episode retains its history after leaving the latest 10.</p></div></details>
</main><footer>BitFlip metrics <span>Self-hosted. Episode focused.</span></footer></div><script>{JS}</script></body></html>'''

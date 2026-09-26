"""Compact, episode-first analytics views with distinct platform definitions."""
import html
import math
import statistics
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode

LABELS = {'24h': 'First 24h', '7d': 'First 7d', '30d': 'First 30d', 'lifetime': 'Lifetime'}
SHORT = {'24h': '24h', '7d': '7d', '30d': '30d', 'lifetime': 'All'}
WINDOWS = ('24h', '7d', '30d')
SORTS = ('24h', '7d', '30d', 'lifetime', 'youtube', 'spotify')
MARKS = {'collecting': '*', 'partial history': '†'}
STALE_AUDIO = 900
CSS = Path(__file__).with_name('dashboard.css').read_text()
JS = """const plot = document.querySelector('.plot');
function nice(peak) {
 peak = Math.max(peak, 1);
 const raw = peak / 4, mag = 10 ** Math.floor(Math.log10(raw));
 const step = Math.max(1, [1, 2, 5, 10].map(m => m * mag).find(s => s >= raw));
 return [Math.ceil(peak / step) * step, step];
}
function render(source) {
 const bars = [...plot.querySelectorAll('.bar')];
 const visible = bars.filter(b => source === 'all' || b.dataset.kind === source);
 const [top, step] = nice(Math.max(0, ...visible.map(b => Number(b.dataset.value || 0))));
 bars.forEach(b => b.style.height = (Number(b.dataset.value || 0) / top * 100) + '%');
 const ticks = [];
 for (let v = 0; v <= top; v += step) ticks.push(v);
 plot.querySelector('.axis').innerHTML = ticks.map(v => `<span style="bottom:${v / top * 100}%">${v.toLocaleString()}</span>`).join('');
 plot.querySelector('.gridlines').innerHTML = ticks.slice(1).map(v => `<span style="bottom:${v / top * 100}%"></span>`).join('');
 const line = plot.querySelector('.median-line'), median = plot.dataset['median' + source[0].toUpperCase() + source.slice(1)];
 if (line) {
  line.hidden = !median;
  if (median) {
   line.style.bottom = (median / top * 100) + '%';
   line.querySelector('span').textContent = 'Median ' + Number(median).toLocaleString();
  }
 }
}
document.querySelectorAll('[data-source]').forEach(button => {
 button.addEventListener('click', () => {
  document.querySelector('.comparison').dataset.active = button.dataset.source;
  document.querySelectorAll('[data-source]').forEach(b => b.setAttribute('aria-pressed', String(b === button)));
  render(button.dataset.source);
 });
});"""


def esc(value):
    return html.escape(str(value), quote=True)


def stamp(value, time=False):
    return datetime.fromtimestamp(value, timezone.utc).strftime('%d %b %Y' + (' · %H:%M UTC' if time else ''))


def ago(value, now):
    seconds = max(0, now - value)
    if seconds < 60:
        return 'just now'
    for unit, size in (('d', 86400), ('h', 3600), ('m', 60)):
        if seconds >= size:
            return f'{seconds // size:.0f}{unit} ago'


def download_value(episode, key, coverage):
    status = episode['window_status'].get(key, 'recorded')
    if coverage is None or status == 'unavailable':
        return None, 'Unavailable'
    return episode[key], status


def source_value(episode, key, coverage):
    if key == 'youtube':
        return episode.get('youtube_public_views')
    if key == 'spotify':
        return episode.get('spotify_plays')
    return download_value(episode, key, coverage)[0]


def sort_episodes(episodes, key, coverage):
    """Highest first; missing values sink to the bottom and ties keep release order."""
    return sorted(episodes, key=lambda e: -(v if (v := source_value(e, key, coverage)) is not None else -1))


def settled(episodes, key, coverage):
    """Values whose window has closed, so young episodes do not drag medians down."""
    values = []
    for e in episodes:
        value = source_value(e, key, coverage)
        if value is not None and (key in ('youtube', 'spotify') or download_value(e, key, coverage)[1] not in MARKS):
            values.append(value)
    return values


def medians(episodes, coverage):
    return {key: (statistics.median(values), len(values)) if (values := settled(episodes, key, coverage)) else (None, 0)
            for key in (*WINDOWS, 'lifetime', 'youtube')}


def nice(peak):
    peak = max(peak, 1)
    raw = peak / 4
    magnitude = 10 ** math.floor(math.log10(raw))
    step = max(1, next(m * magnitude for m in (1, 2, 5, 10) if m * magnitude >= raw))
    return math.ceil(peak / step) * step, step


def value_text(value, status=''):
    if value is None:
        return '<span class="unavailable" title="Data unavailable">—</span>'
    mark = MARKS.get(status)
    flag = f'<sup class="mark">{mark}</sup>' if mark else ''
    return f'<span title="{esc(status)}">{value:,.0f}{flag}</span>'


def label(key, long=None):
    return f'<span class="long">{long or LABELS[key]}</span><span class="short">{SHORT[key]}</span>'


def duration(episode):
    minutes = round(episode.get('duration_seconds', 0) / 60)
    hours, minutes = divmod(minutes, 60)
    return (f'{hours}h {minutes:02d}m' if hours else f'{minutes}m') if episode.get('duration_seconds') else ''


def comparison(episodes, metric, coverage, mode, benchmarks, source):
    groups = []
    if mode == 'episode':
        episode = episodes[0]
        for key in WINDOWS:
            value, status = download_value(episode, key, coverage)
            groups.append((LABELS[key], None, [('audio', 'This episode', value, status),
                                               ('median', 'Median episode', benchmarks[key][0], 'median')]))
    else:
        # The chart stays chronological even when the table is sorted by a metric.
        for e in sorted(episodes, key=lambda e: (e['published'], e['number'])):
            value, status = download_value(e, metric, coverage)
            bars = [('audio', 'Audio downloads', value, status)]
            if metric == 'lifetime':
                bars.append(('youtube', 'YouTube views', e.get('youtube_public_views'), 'public lifetime'))
            groups.append((f'#{e["number"]}', f'/episodes/{e["number"]}', bars))
    if not groups:
        return '<div class="empty">No matching episodes. Try another title or number.</div>'
    top, step = nice(max([v or 0 for _, _, bars in groups for kind, _, v, _ in bars if source in ('all', kind)] + [0]))
    ticks = range(0, top + 1, step)
    columns, labels = [], []
    for name, url, bars in groups:
        slots = []
        for kind, title, value, status in bars:
            desc = f'{name} · {title}: {f"{value:,.0f}" if value is not None else "unavailable"} · {status}'
            pending = ' pending' if status in MARKS else ''
            slots.append(f'<span class="bar-slot" data-kind="{kind}"><span class="bar {kind}{pending}" data-kind="{kind}" '
                         f'data-value="{value if value is not None else ""}" style="height:{(value or 0) / top * 100:.3f}%" '
                         f'title="{esc(desc)}"><span class="bar-number">{value_text(value)}</span></span></span>')
        columns.append(f'<div class="chart-column"><div class="pair">{"".join(slots)}</div></div>')
        labels.append(f'<div class="x-label">{f"<a href=\"{url}\">{esc(name)}</a>" if url else esc(name)}</div>')
    axis = ''.join(f'<span style="bottom:{v / top * 100:.3f}%">{v:,}</span>' for v in ticks)
    grid = ''.join(f'<span style="bottom:{v / top * 100:.3f}%"></span>' for v in ticks[1:])
    median_attrs, median_line = '', ''
    if mode != 'episode':
        kinds = ('audio', 'youtube') if metric == 'lifetime' else ('audio',)
        keys = {'audio': metric, 'youtube': 'youtube'}
        median_attrs = ''.join(f' data-median-{kind}="{benchmarks[keys[kind]][0]}"' for kind in kinds
                               if benchmarks[keys[kind]][0] is not None)
        current = benchmarks[keys[source]][0] if source in keys else None
        median_line = (f'<div class="median-line" style="bottom:{(current or 0) / top * 100:.3f}%"'
                       f'{"" if current is not None else " hidden"}><span>Median {current or 0:,.0f}</span></div>')
    width = f'min-width:{max(240, len(groups) * 28)}px'
    return (f'<div class="plot"{median_attrs}><div class="axis">{axis}</div><div class="chart-scroll">'
            f'<div class="bars-area" style="{width}"><div class="gridlines">{grid}</div>{median_line}{"".join(columns)}</div>'
            f'<div class="x-labels" style="{width}">{"".join(labels)}</div></div></div>')


def dashboard(data, mode='recent', metric='lifetime', sort='', now=None):
    now = now if now is not None else time.time()
    episodes = data['episodes'][:10] if mode == 'recent' else data['episodes']
    coverage, query = data['coverage_start'], data.get('query', '')
    detail = mode == 'episode'
    total, offset = data.get('total', len(episodes)), data.get('offset', 0)
    benchmarks = data.get('medians') or medians(episodes, coverage)
    title = episodes[0]['title'] if detail else 'Episode performance' if mode == 'recent' else 'Episode archive'
    scope = f'Episode {episodes[0]["number"]:02d}' if detail else 'Latest 10' if mode == 'recent' else 'All episodes'
    subtitle = (f'Published {episodes[0]["published"][:10]} · {duration(episodes[0])}' if detail
                else 'Downloads and views for the latest releases.' if mode == 'recent'
                else 'Every episode, searchable and sortable.')
    has_spotify = any(e.get('spotify_plays') is not None for e in episodes)
    public_values = [e.get('youtube_public_views') for e in episodes]

    # Freshness sits in the top bar so stale numbers are obvious before they are read.
    polled = data.get('synced', {}).get('r2')
    audio_title = f'Audio recording since {stamp(coverage)}' if coverage else 'Audio collection awaiting first event'
    if polled is None:
        audio_chip = ('warn', 'Audio not synced yet')
    else:
        audio_chip = ('warn' if now - polled > STALE_AUDIO else 'ok', f'Audio synced {ago(polled, now)}')
    observed = [e['youtube_public_observed_at'] for e in episodes if e.get('youtube_public_observed_at')]
    youtube_chip = (('', f'YouTube {ago(min(observed), now)}'), f'Oldest YouTube snapshot in view: {stamp(min(observed), True)}') \
        if observed else (('', 'YouTube awaiting counts'), 'No public YouTube snapshot yet')
    chips = (f'<span class="chip {audio_chip[0]}" title="{esc(audio_title)}">{esc(audio_chip[1])}</span>'
             f'<span class="chip" title="{esc(youtube_chip[1])}">{esc(youtube_chip[0][1])}</span>')

    def aggregate(values):
        return sum(v for v in values if v is not None) if any(v is not None for v in values) else None

    cards = []
    if detail:
        episode = episodes[0]
        cards.append(('Audio downloads', value_text(episode['lifetime'] if coverage else None), 'audio-text',
                      'Recorded lifetime'))
        for key in WINDOWS:
            value, status = download_value(episode, key, coverage)
            median, _ = benchmarks[key]
            if value is None:
                note = 'Before audio coverage'
            elif status in MARKS:
                note = ('Still collecting' if status == 'collecting' else 'Partial history') + \
                       (f' · median {median:,.0f}' if median is not None else '')
            elif median and round((value - median) / median * 100) == 0:
                note = f'In line with median {median:,.0f}'
            elif median:
                change = (value - median) / median * 100
                note = f'<span class="{"up" if change >= 0 else "down"}">{"▲" if change >= 0 else "▼"} {abs(change):.0f}%</span> vs median {median:,.0f}'
            else:
                note = 'No completed episodes to compare'
            cards.append((LABELS[key], value_text(value, status), '', note))
        yt = episode.get('youtube_public_views')
        cards.append(('YouTube views', value_text(yt), 'youtube-text',
                      f'Public lifetime · checked {ago(episode["youtube_public_observed_at"], now)}' if yt is not None else 'No public snapshot'))
    else:
        window = metric if metric != 'lifetime' else '7d'
        median, count = benchmarks[window]
        best = max(((v, e) for e in episodes if (v := source_value(e, window, coverage)) is not None
                    and download_value(e, window, coverage)[1] not in MARKS), default=None, key=lambda pair: pair[0])
        cards += [
            ('Audio downloads', value_text(aggregate([download_value(e, 'lifetime', coverage)[0] for e in episodes])),
             'audio-text', f'Recorded lifetime · {len(episodes)} episodes'),
            ('YouTube views', value_text(aggregate(public_values)), 'youtube-text',
             f'Public lifetime · {sum(v is not None for v in public_values)}/{len(episodes)} available'),
            (f'Median {LABELS[window].lower()}', value_text(median), '',
             f'{count} completed windows' if count else 'No completed windows yet'),
            (f'Best {LABELS[window].lower()}', value_text(best[0] if best else None), '',
             f'<a href="/episodes/{best[1]["number"]}">#{best[1]["number"]} · {esc(best[1]["title"])}</a>' if best else 'No completed windows yet'),
        ]
    if has_spotify:
        cards.append(('Spotify plays', value_text(aggregate([e.get('spotify_plays') for e in episodes])), '',
                      'Imported creator export'))
    cards_html = ''.join(f'<div class="stat"><span class="stat-label">{label_}</span><strong class="{color}">{value_html}</strong>'
                         f'<span class="stat-note">{note}</span></div>' for label_, value_html, color, note in cards)

    base = '/episodes' if mode == 'archive' else '/'
    page = offset // 25 + 1

    def link(**changes):
        params = {'q': query, 'metric': metric, 'sort': sort, 'page': page if mode == 'archive' else 1, **changes}
        defaults = {'q': '', 'metric': 'lifetime', 'sort': '', 'page': 1}
        params = {k: v for k, v in params.items() if v != defaults[k]}
        return esc(base + ('?' + urlencode(params) if params else ''))

    window_links = '' if detail else ''.join(
        f'<a href="{link(metric=key)}"{" aria-current=\"true\"" if key == metric else ""}>{label(key)}</a>' for key in LABELS)

    def heading(key, text, short):
        active = ' active-col' if key == metric else ''
        current = ' aria-sort="descending"' if sort == key else ''
        return (f'<th class="{active.strip()}"{current}><a href="{link(sort=key, page=1)}" title="Sort by {esc(text)}">'
                f'<span class="long">{text}</span><span class="short">{short}</span>{" ▾" if sort == key else ""}</a></th>')

    columns = [('24h', 'First 24h', '24h'), ('7d', 'First 7d', '7d'), ('30d', 'First 30d', '30d'),
               ('lifetime', 'Audio lifetime', 'Audio'), ('youtube', 'YouTube views', 'YouTube')]
    if has_spotify:
        columns.append(('spotify', 'Spotify plays', 'Spotify'))
    newest = f'<a href="{link(sort="", page=1)}" title="Sort by release">'
    head = (f'<th class="number-heading">{newest}#</a></th>'
            f'<th class="episode-heading"{" aria-sort=\"descending\"" if not sort else ""}>{newest}Episode</a></th>'
            + ''.join(heading(*column) for column in columns))
    rows = []
    for e in episodes:
        cells = ''.join(f'<td class="numeric{" active-col" if key == metric else ""}">{value_text(*download_value(e, key, coverage))}</td>'
                        for key in LABELS)
        yt = e.get('youtube_public_views')
        yt_hint = stamp(e['youtube_public_observed_at'], True) if yt is not None else 'Unavailable'
        spotify = f'<td class="numeric">{value_text(e.get("spotify_plays"))}</td>' if has_spotify else ''
        rows.append(f'<tr data-episode="{e["number"]}"><td class="episode-number">{e["number"]:02d}</td>'
                    f'<th scope="row"><a href="/episodes/{e["number"]}">{esc(e["title"])}</a>'
                    f'<span class="episode-meta"><span class="meta-number">#{e["number"]:02d}</span>{esc(e["published"][:10])}'
                    f'<span>{duration(e)}</span></span></th>{cells}'
                    f'<td class="numeric" title="Public lifetime · {esc(yt_hint)}">{value_text(yt)}</td>{spotify}</tr>')
    table = (f'<div class="table-scroll"><table><thead><tr>{head}</tr></thead><tbody>{"".join(rows)}</tbody></table></div>'
             if rows else '<p class="empty">No episodes found</p>')
    search = (f'<form class="search" action="/episodes"><label class="sr-only" for="q">Find an episode</label>'
              f'<input id="q" name="q" placeholder="Search title or #number" value="{esc(query)}" maxlength="200">'
              f'<input type="hidden" name="metric" value="{esc(metric)}">'
              + (f'<input type="hidden" name="sort" value="{esc(sort)}">' if sort else '') + '<button>Search</button></form>')
    pagination = ''
    if mode == 'archive':
        previous = f'<a href="{link(page=page - 1)}">Previous</a>' if page > 1 else ''
        following = f'<a href="{link(page=page + 1)}">Next</a>' if offset + len(episodes) < total else ''
        pagination = (f'<nav class="pagination" aria-label="Archive pages"><span>{offset + 1 if episodes else 0}–{offset + len(episodes)} of {total}</span>'
                      f'<div>{previous}<span>Page {page} of {max(1, (total + 24) // 25)}</span>{following}</div></nav>')

    # Charts show one source by default: public YouTube lifetime views dwarf audio downloads on a shared scale.
    source = 'all' if detail else 'audio'
    pending = any(download_value(e, key, coverage)[1] in MARKS for e in episodes
                  for key in (WINDOWS if detail else (metric,)))
    if detail:
        legend = '<span class="audio-text">This episode</span><span class="median-text">Median episode</span>'
        switch = ''
        note = f'Median of episodes whose window has closed ({", ".join(f"{LABELS[k].lower()}: {benchmarks[k][1]}" for k in WINDOWS)} episodes).'
    elif metric == 'lifetime':
        legend = '<span class="audio-text">Audio downloads</span><span class="youtube-text">YouTube views</span>'
        switch = ('<div class="source-switch" aria-label="Chart sources">' + ''.join(
            f'<button data-source="{key}" aria-pressed="{str(key == source).lower()}">{name}</button>'
            for key, name in (('audio', 'Audio'), ('youtube', 'YouTube'), ('all', 'Both'))) + '</div>')
        note = 'Audio downloads and YouTube views have different definitions; each source is scaled on its own. With one source shown, the dashed line marks its median.'
    else:
        legend = '<span class="audio-text">Audio downloads</span>'
        switch = ''
        note = 'YouTube release-window history is unavailable, so this window shows audio downloads only. Dashed line: median of completed windows.'
    if pending:
        legend += '<span class="pending-key">Still collecting / partial</span>'
    chart_title = 'Download milestones' if detail else 'Compare episodes'
    table_title = 'Latest releases' if mode == 'recent' else 'All releases'
    active_recent = ' aria-current="page"' if mode == 'recent' else ''
    active_archive = ' aria-current="page"' if mode != 'recent' else ''
    action = '<a class="archive-link" href="/episodes">Back to all episodes</a>' if detail else ''
    episodes_panel = '' if detail else (
        f'<section class="episodes-panel"><div class="panel-heading"><div class="table-title"><h2>{table_title}</h2>'
        f'<span class="count-badge">{len(episodes)}</span></div>{search}</div>{table}{pagination}'
        f'<div class="table-footnote"><span><sup class="mark">*</sup> Still collecting · <sup class="mark">†</sup> Partial history · — Unavailable</span>'
        f'<span>Select a column heading to sort</span></div></section>')
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(title)} · BitFlip metrics</title><style>{CSS}</style></head><body>
<a class="skip" href="#main">Skip to metrics</a><aside class="sidebar"><a class="brand" href="/"><img class="podcast-logo" src="/podcast-logo.png" alt="BitFlip podcast logo" width="28" height="41"><span class="brand-copy"><span class="brand-name">BitFlip</span><span class="brand-sub">ANALYTICS</span></span></a>
<div class="nav-label">WORKSPACE</div><nav aria-label="Main"><a href="/"{active_recent}>Overview<span>10</span></a><a href="/episodes"{active_archive}>Episodes<span>All</span></a></nav>
<div class="nav-label links-label">QUICK LINKS</div><nav><a href="https://bitflip.show" target="_blank" rel="noreferrer">Podcast website</a><a href="#data-notes">About these metrics</a></nav></aside>
<div class="workspace"><header class="topbar"><div class="breadcrumb">BitFlip <span>/</span> Metrics <span>/</span> <strong>{esc(scope)}</strong></div><div class="status">{chips}<span class="private-badge">TAILNET ONLY</span></div></header><main id="main">
<div class="page-heading"><div><h1>{esc(title)}</h1><p>{esc(subtitle)}</p></div>{action}</div>
<section class="stats" aria-label="Metrics for episodes shown">{cards_html}</section>
<section class="comparison" data-active="{source}" aria-label="Episode comparison"><div class="panel-heading"><h2>{chart_title}</h2><div class="chart-controls">{switch}<nav class="window-switch" aria-label="Release window">{window_links}</nav></div></div>
<div class="chart-caption"><div class="legend">{legend}</div><span>{'Since release' if detail else LABELS[metric] + ' · by episode'}</span></div>{comparison(episodes, metric, coverage, mode, benchmarks, source)}<p class="chart-note">{note}</p></section>
{episodes_panel}<details id="data-notes"><summary>Data sources &amp; definitions</summary><div><p>{esc(audio_title)}. Audio windows start at each episode’s first download on or after its release day: first 24 hours, 7 days, and 30 days. Audio lifetime covers recorded history only. An asterisk marks a window still collecting; a dagger marks a window that began before audio recording. A dash means missing data, not zero. Medians and bests only use windows that have closed.</p><p>YouTube values are public lifetime snapshots, refreshed daily. They cannot reconstruct historical release windows. Old snapshots stay visible if a refresh fails; the top bar shows the oldest snapshot in this view. Spotify plays appear once a creator CSV export is imported.</p><p>Audio downloads, YouTube views, and Spotify plays have different definitions. They are displayed together but never added into a combined audience total. Every episode retains its history after leaving the latest 10.</p></div></details>
</main></div><script>{JS}</script></body></html>'''

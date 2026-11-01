// lib.js - the pure parts of the extension (no gi:// imports), shared with
// the node tests in ../tests. Mirrors tray/so_tray/model.py.

const round = v => Math.round(v);
const gb = mb => (mb / 1024).toFixed(1);

export function parseJsonLine(line) {
    if (!line)
        return null;
    try {
        const v = JSON.parse(line);
        return v && typeof v === 'object' ? v : null;
    } catch {
        return null;
    }
}

// The short text next to the panel icon: "12% 54°".
export function panelLabel(sample) {
    if (!sample)
        return '';
    const cpu = sample.cpu ?? {};
    const temp = sample.temperature ?? {};
    let s = cpu.percent === null || cpu.percent === undefined ? '–' : `${round(cpu.percent)}%`;
    if (temp.cpu !== null && temp.cpu !== undefined)
        s += ` ${round(temp.cpu)}°`;
    return s;
}

export function readoutLines(sample) {
    if (!sample)
        return ['Reading the system…'];
    const cpu = sample.cpu ?? {}, mem = sample.memory ?? {};
    const temp = sample.temperature ?? {}, power = sample.power ?? {};
    const lines = [];
    const parts = [`CPU ${cpu.percent === null || cpu.percent === undefined ? '–' : `${round(cpu.percent)}%`}`];
    if (cpu.mhz)
        parts.push(`${(cpu.mhz / 1000).toFixed(1)} GHz`);
    if (temp.cpu !== null && temp.cpu !== undefined)
        parts.push(`${round(temp.cpu)}°C`);
    if (cpu.load1 !== null && cpu.load1 !== undefined)
        parts.push(`load ${cpu.load1.toFixed(2)}`);
    lines.push(parts.join(' · '));
    if (mem.total_mb) {
        let m = `Memory ${gb(mem.used_mb ?? 0)} / ${gb(mem.total_mb)} GB`;
        if (mem.percent !== null && mem.percent !== undefined)
            m += ` (${round(mem.percent)}%)`;
        if (mem.swap_total_mb)
            m += ` · ${mem.zram ? 'zram' : 'swap'} ${gb(mem.swap_used_mb ?? 0)} GB used`;
        lines.push(m);
    }
    const other = [];
    if (temp.gpu !== null && temp.gpu !== undefined)
        other.push(`GPU ${round(temp.gpu)}°C`);
    if (temp.nvme !== null && temp.nvme !== undefined)
        other.push(`NVMe ${round(temp.nvme)}°C`);
    if (other.length)
        lines.push(other.join(' · '));
    let p = `Power profile ${power.profile ?? 'unknown'}`;
    if (power.owner)
        p += ` (${power.owner})`;
    const bat = (power.batteries ?? []).find(b => b.percent !== null && b.percent !== undefined);
    if (bat)
        p += ` · battery ${bat.percent}%${bat.status ? ` ${bat.status.toLowerCase()}` : ''}`;
    else if (power.ac !== null && power.ac !== undefined)
        p += power.ac ? ' · on AC' : ' · on battery';
    lines.push(p);
    return lines;
}

// [{name, label, checked, enabled, tip}] for the switches.
export function featureEntries(info) {
    const caps = new Set(info?.capabilities ?? []);
    const add = (tip, more) => tip ? `${tip}; ${more}` : more;
    return (info?.features ?? []).map(f => {
        let label = f.title;
        let tip = f.summary ?? '';
        let enabled = true;
        if (f.kind === 'opt-in')
            label += ' (optional)';
        if (f.applied === null || f.applied === undefined)
            tip = add(tip, 'state unknown: this system-optimize does not report it');
        if (f.kind === 'opt-in' && !caps.has('enable') && !f.applied) {
            enabled = false;
            tip = add(tip, 'needs a newer system-optimize');
        }
        if (f.applied && !caps.has('revert-step'))
            tip = add(tip, 'to turn it off, use Undo last run');
        return {name: f.name, label, checked: Boolean(f.applied), enabled, tip};
    });
}

export function actionsAvailable(info) {
    const caps = new Set(info?.capabilities ?? []);
    const found = Boolean(info?.found);
    return {
        applyAll: found,
        preview: found,
        undo: found && caps.has('undo'),
        profiles: caps.has('profile') ? info.profiles ?? [] : [],
        benchmark: caps.has('benchmark'),
        status: found,
    };
}

// A notification for a {ok, code, output} result from the backend.
export function resultMessage(res) {
    if (!res)
        return {title: 'system-optimize', body: 'No answer from the backend', error: true};
    if (res.ok)
        return {title: 'system-optimize', body: 'Done. Undo restores the previous settings.', error: false};
    if (res.code === 126 || res.code === 127)
        return {title: 'system-optimize', body: 'Not changed: authorisation was cancelled or refused.', error: true};
    const tail = (res.output ?? '').split('\n').filter(Boolean).slice(-3).join('\n');
    return {title: `system-optimize failed (exit ${res.code})`, body: tail || 'see the run log', error: true};
}

// Steps grouped by category, in the order the backend lists them:
// [{key, title, entries, on, total, unknown}]. Mirrors so_tray.model.categories.
export function categories(info) {
    const entries = new Map(featureEntries(info).map(e => [e.name, e]));
    const groups = new Map();
    for (const f of info?.features ?? []) {
        const key = f.category ?? 'other';
        if (!groups.has(key))
            groups.set(key, {key, title: f.category_title ?? 'Other', entries: [], on: 0, total: 0, unknown: false});
        const g = groups.get(key);
        g.entries.push(entries.get(f.name));
        g.total += 1;
        if (f.applied === null || f.applied === undefined)
            g.unknown = true;
        else if (f.applied)
            g.on += 1;
    }
    return [...groups.values()];
}

export function categoryCount(g) {
    if (g.unknown)
        return `${g.total} step${g.total === 1 ? '' : 's'}`;
    return `${g.on}/${g.total} on`;
}

// THEME from the tray's KEY=value config text: 'system' | 'light' | 'dark'.
export function themeFromConfig(text) {
    let theme = 'system';
    for (const raw of (text ?? '').split('\n')) {
        const line = raw.trim();
        if (!line || line.startsWith('#') || !line.includes('='))
            continue;
        const [k, ...rest] = line.split('=');
        const v = rest.join('=').trim().replace(/^["']|["']$/g, '');
        if (k.trim() === 'THEME' && ['system', 'light', 'dark'].includes(v))
            theme = v;
    }
    return theme;
}

// The resource pages of the dashboard, in the order of its tiles.
export const RESOURCES = [
    ['cpu', 'CPU load'],
    ['memory', 'Memory'],
    ['cpu_temp', 'CPU temperature'],
    ['disk', 'Disk I/O'],
];

// Which resource page a readout line opens, or null.
export function readoutResource(line) {
    if (/^CPU /.test(line ?? ''))
        return 'cpu';
    if (/^Memory /.test(line ?? ''))
        return 'memory';
    return null;
}

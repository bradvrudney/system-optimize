// node --test gnome-extension/tests
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {
    parseJsonLine, panelLabel, readoutLines, featureEntries, actionsAvailable,
    resultMessage, categories, categoryCount, themeFromConfig,
} from '../system-optimize@bradvrudney.github.io/lib.js';

const sample = {
    cpu: {percent: 12.4, mhz: 3650, load1: 2.4},
    memory: {percent: 31, total_mb: 65536, used_mb: 20480, swap_total_mb: 16384, swap_used_mb: 512, zram: true},
    temperature: {cpu: 54.6, gpu: 48, nvme: 41},
    power: {profile: 'balanced', owner: 'tuned-ppd', ac: true, batteries: [{percent: 77, status: 'Charging'}]},
};

const info = {
    found: true,
    capabilities: ['undo', 'enable', 'profile', 'benchmark'],
    profiles: ['dev', 'gaming'],
    features: [
        {name: 'sysctl', title: 'Kernel tunables', kind: 'default', applied: true, category: 'memory', category_title: 'Memory'},
        {name: 'zram', title: 'zram swap', kind: 'default', applied: false, category: 'memory', category_title: 'Memory'},
        {name: 'tuned', title: 'tuned', kind: 'opt-in', applied: false, category: 'power', category_title: 'Power and CPU'},
    ],
};

test('parseJsonLine', () => {
    assert.deepEqual(parseJsonLine('{"a":1}'), {a: 1});
    assert.equal(parseJsonLine('not json'), null);
    assert.equal(parseJsonLine('3'), null);
    assert.equal(parseJsonLine(''), null);
});

test('panelLabel', () => {
    assert.equal(panelLabel(sample), '12% 55°');
    assert.equal(panelLabel({cpu: {percent: null}, temperature: {}}), '–');
    assert.equal(panelLabel(null), '');
});

test('readoutLines', () => {
    const lines = readoutLines(sample);
    assert.match(lines[0], /^CPU 12% · 3\.6 GHz · 55°C · load 2\.40$/);
    assert.match(lines[1], /Memory 20\.0 \/ 64\.0 GB \(31%\) · zram 0\.5 GB used/);
    assert.equal(lines[2], 'GPU 48°C · NVMe 41°C');
    assert.equal(lines[3], 'Power profile balanced (tuned-ppd) · battery 77% charging');
    assert.deepEqual(readoutLines(null), ['Reading the system…']);
});

test('featureEntries marks optional steps and missing capabilities', () => {
    const e = featureEntries(info);
    assert.equal(e[2].label, 'tuned (optional)');
    assert.equal(e[2].enabled, true);
    const old = featureEntries({...info, capabilities: []});
    assert.equal(old[2].enabled, false);
    assert.match(old[0].tip, /Undo last run/);
    const unknown = featureEntries({features: [{name: 'x', title: 'X', applied: null}]});
    assert.match(unknown[0].tip, /state unknown/);
});

test('actionsAvailable', () => {
    assert.deepEqual(actionsAvailable(info), {
        applyAll: true, preview: true, undo: true, profiles: ['dev', 'gaming'], benchmark: true, status: true,
    });
    assert.equal(actionsAvailable({found: false}).applyAll, false);
});

test('resultMessage', () => {
    assert.equal(resultMessage({ok: true}).error, false);
    assert.match(resultMessage({ok: false, code: 126}).body, /authorisation/);
    const r = resultMessage({ok: false, code: 3, output: 'a\nb\nc\nd\n'});
    assert.equal(r.body, 'b\nc\nd');
    assert.equal(resultMessage(null).error, true);
});

test('categories and counts', () => {
    const g = categories(info);
    assert.deepEqual(g.map(x => x.key), ['memory', 'power']);
    assert.equal(categoryCount(g[0]), '1/2 on');
    assert.equal(categoryCount(g[1]), '0/1 on');
    const u = categories({features: [{name: 'x', title: 'X', applied: null}]});
    assert.equal(u[0].key, 'other');
    assert.equal(categoryCount(u[0]), '1 step');
});

test('themeFromConfig', () => {
    assert.equal(themeFromConfig(''), 'system');
    assert.equal(themeFromConfig('# x\nTHEME=dark\n'), 'dark');
    assert.equal(themeFromConfig("THEME='light'\nEXPANDED=memory"), 'light');
    assert.equal(themeFromConfig('THEME=purple'), 'system');
    assert.equal(themeFromConfig(null), 'system');
});

test('readout lines open resource pages', async () => {
    const {readoutResource, RESOURCES} = await import('../system-optimize@bradvrudney.github.io/lib.js');
    const lines = readoutLines(sample);
    assert.equal(readoutResource(lines[0]), 'cpu');
    assert.equal(readoutResource(lines[1]), 'memory');
    assert.equal(readoutResource(lines[3]), null);
    assert.equal(readoutResource(undefined), null);
    assert.deepEqual(RESOURCES.map(r => r[0]), ['cpu', 'memory', 'cpu_temp', 'disk']);
});

// app.js: the page. It holds the two tables and the settings, asks the server to
// check them and to run, follows a run, and draws the results. It does no
// optimisation and no placement: every position it draws comes from the server.

'use strict';

// --- Helpers ---

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value === null || value === undefined || value === false) continue;
    if (key === 'class') node.className = value;
    else if (key === 'text') node.textContent = value;
    else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child.nodeType ? child : document.createTextNode(String(child)));
  }
  return node;
}

function svgEl(tag, attrs = {}, ...children) {
  const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  for (const child of children.flat()) if (child) node.append(child);
  return node;
}

const numberFormats = {};
function nf(value, digits = 0) {
  if (value === null || value === undefined || Number.isNaN(Number(value))) return '–';
  numberFormats[digits] = numberFormats[digits] || new Intl.NumberFormat('en', { maximumFractionDigits: digits });
  return numberFormats[digits].format(value);
}
const pct = (fraction, digits = 1) => (fraction === null || fraction === undefined) ? '–' : nf(fraction * 100, digits) + '%';

async function api(path, body) {
  const options = body === undefined ? {} : {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  };
  const response = await fetch(path, options);
  let data = null;
  try { data = await response.json(); } catch (e) { /* no body */ }
  if (!response.ok) throw new Error((data && data.error) || `The request failed (${response.status}).`);
  return data;
}

function debounce(fn, ms) {
  let timer = null;
  return (...args) => { clearTimeout(timer); timer = setTimeout(() => fn(...args), ms); };
}

function download(filename, text, type) {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const link = el('a', { href: url, download: filename });
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// --- State ---

const STORAGE_KEY = 'stock-cutting-application';
const state = {
  defaults: null,
  items: { columns: [], rows: [] },
  sheets: { columns: [], rows: [] },
  settings: null,
  selectedGroups: null,        // labels chosen to run; null means every group with items
  runName: '',
  validation: null,
  marks: new Map(),            // "table:row:column" -> message
  jobId: null,
  poll: null,
  result: null,
  resultJobId: null,
  resultName: '',
  resultState: '',
  activeGroup: 0,
};

function loadStored() {
  try { return JSON.parse(localStorage.getItem(STORAGE_KEY)) || null; } catch (e) { return null; }
}
const persist = debounce(() => {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({
      items: state.items, sheets: state.sheets, settings: state.settings,
      selectedGroups: state.selectedGroups, runName: state.runName,
    }));
  } catch (e) { /* storage unavailable: the page still works */ }
}, 300);

function deepMerge(base, extra) {
  if (extra === null || typeof extra !== 'object' || Array.isArray(extra)) return extra === undefined ? base : extra;
  const out = Array.isArray(base) ? base.slice() : { ...base };
  for (const [key, value] of Object.entries(extra)) {
    out[key] = (base && typeof base[key] === 'object' && base[key] !== null && !Array.isArray(base[key]))
      ? deepMerge(base[key], value) : value;
  }
  return out;
}

// --- Tabs ---

function showTab(name) {
  for (const section of $$('.tab')) section.hidden = section.id !== 'tab-' + name;
  for (const button of $$('#tabs button')) button.classList.toggle('active', button.dataset.tab === name);
  if (name === 'run') { updateRunSummary(); refreshHistory(); }
  window.scrollTo(0, 0);
}

// --- Table columns ---

const COLUMN_LABELS = {
  item_id: 'Item ID', value: 'Value', width: 'Width (mm)', height: 'Height (mm)', thickness: 'Thickness (mm)',
  material: 'Material', finish: 'Finish', can_rotate: 'Can rotate', sheet_id: 'Sheet ID', quantity: 'Quantity in stock',
};

function demandPeriod(column) {
  const prefix = state.defaults.demand_prefix;
  if (!column.startsWith(prefix)) return null;
  const n = Number(column.slice(prefix.length));
  return Number.isInteger(n) ? n : null;
}
function columnLabel(column) {
  const period = demandPeriod(column);
  return period === null ? (COLUMN_LABELS[column] || column) : `Demand, period ${period}`;
}
function demandColumns() { return state.items.columns.filter(c => demandPeriod(c) !== null); }

function blankRow(kind) {
  const row = {};
  for (const column of state[kind].columns) row[column] = '';
  if (kind === 'items') row.can_rotate = 'yes';
  return row;
}

function normaliseRotation(text) {
  const t = String(text || '').trim().toLowerCase();
  if (['yes', 'y', 'true', '1'].includes(t)) return 'yes';
  if (['no', 'n', 'false', '0'].includes(t)) return 'no';
  return String(text || '').trim();
}

// --- The data tables ---

function renderTable(kind) {
  const table = $('#' + kind + '-table');
  const data = state[kind];
  table.replaceChildren();

  table.append(el('thead', {}, el('tr', {},
    el('th', { text: '#' }),
    data.columns.map(c => el('th', {}, columnLabel(c), el('small', { text: c }))),
    el('th', {}),
  )));

  const body = el('tbody');
  data.rows.forEach((row, r) => {
    const tr = el('tr', {}, el('td', { class: 'rownum', text: String(r + 1) }));
    data.columns.forEach((column, c) => {
      let input;
      if (column === 'can_rotate') {
        input = el('select', {}, ['', 'yes', 'no'].map(v => el('option', { value: v, text: v })));
        input.value = row[column] ?? '';
      } else {
        input = el('input', { type: 'text', value: row[column] ?? '', inputmode: (column === 'material' || column === 'finish' || column.endsWith('_id')) ? 'text' : 'decimal' });
        input.value = row[column] ?? '';
      }
      input.dataset.row = r;
      input.dataset.col = c;
      input.setAttribute('aria-label', `${columnLabel(column)}, row ${r + 1}`);
      input.addEventListener('input', () => { row[column] = input.value; changed(); });
      input.addEventListener('change', () => { row[column] = input.value; changed(); });
      input.addEventListener('paste', event => pasteInto(kind, r, c, event));
      input.addEventListener('keydown', event => moveWithKeys(kind, event, r, c));
      tr.append(el('td', { 'data-cell': `${kind}:${r + 1}:${column}` }, input));
    });
    tr.append(el('td', {}, el('button', { class: 'remove', title: 'Remove this row', 'aria-label': `Remove row ${r + 1}`, text: '×',
      onclick: () => { data.rows.splice(r, 1); renderTable(kind); changed(); } })));
    body.append(tr);
  });
  table.append(body);
  applyMarks();
}

function moveWithKeys(kind, event, r, c) {
  if (event.key !== 'Enter' && event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
  if (event.target.tagName === 'SELECT' && event.key !== 'Enter') return;
  const target = event.key === 'ArrowUp' ? r - 1 : r + 1;
  const next = $(`#${kind}-table [data-row="${target}"][data-col="${c}"]`);
  if (next) { event.preventDefault(); next.focus(); if (next.select) next.select(); }
}

// Pasting cells copied from a spreadsheet fills the table from the active cell
function pasteInto(kind, r, c, event) {
  const text = event.clipboardData ? event.clipboardData.getData('text') : '';
  if (!text.includes('\t') && !text.includes('\n')) return;
  event.preventDefault();
  const data = state[kind];
  const lines = text.replace(/\r/g, '').replace(/\n+$/, '').split('\n').map(line => line.split('\t'));
  lines.forEach((cells, i) => {
    while (data.rows.length <= r + i) data.rows.push(blankRow(kind));
    cells.forEach((value, j) => {
      const column = data.columns[c + j];
      if (column === undefined) return;
      data.rows[r + i][column] = column === 'can_rotate' ? normaliseRotation(value) : value.trim();
    });
  });
  renderTable(kind);
  changed();
}

function changed() {
  persist();
  scheduleValidation();
  updateRunSummary();
}

function setPeriods(count) {
  const current = demandColumns().length;
  if (count < 1 || count === current) return;
  if (count < current) {
    const dropped = demandColumns().slice(count);
    const filled = state.items.rows.some(row => dropped.some(c => String(row[c] ?? '').trim() !== ''));
    if (filled && !confirm('The periods you are removing have demand filled in. Remove them?')) return;
    state.items.columns = state.items.columns.filter(c => !dropped.includes(c));
    for (const row of state.items.rows) for (const c of dropped) delete row[c];
  } else {
    for (let p = current + 1; p <= count; p++) {
      const column = state.defaults.demand_prefix + p;
      state.items.columns.push(column);
      for (const row of state.items.rows) row[column] = '';
    }
  }
  $('#periods-count').textContent = String(count);
  renderTable('items');
  changed();
}

function resetColumns(kind) {
  const base = state.defaults[kind === 'items' ? 'item_columns' : 'sheet_columns'];
  state[kind].columns = kind === 'items'
    ? base.concat([state.defaults.demand_prefix + '1'])
    : base.slice();
}

async function loadCsv(kind, file) {
  const message = $('#' + kind + '-message');
  try {
    const text = await file.text();
    const table = await api('/api/parse_csv', { kind, text });
    state[kind].columns = table.columns;
    state[kind].rows = table.rows;
    if (kind === 'items') for (const row of table.rows) row.can_rotate = normaliseRotation(row.can_rotate);
    renderTable(kind);
    if (kind === 'items') $('#periods-count').textContent = String(demandColumns().length);
    message.textContent = `Loaded ${table.rows.length} rows from ${file.name}.` +
      (table.ignored.length ? ` Columns not used: ${table.ignored.join(', ')}.` : '');
    changed();
  } catch (error) {
    message.textContent = `Could not read ${file.name}: ${error.message}`;
  }
}

function setupTableControls(kind) {
  const file = $('#' + kind + '-file');
  $('#' + kind + '-upload').addEventListener('click', () => file.click());
  file.addEventListener('change', () => { if (file.files[0]) loadCsv(kind, file.files[0]); file.value = ''; });
  $('#' + kind + '-add').addEventListener('click', () => {
    state[kind].rows.push(blankRow(kind));
    renderTable(kind);
    changed();
    const last = state[kind].rows.length - 1;
    const first = $(`#${kind}-table [data-row="${last}"][data-col="0"]`);
    if (first) first.focus();
  });
  $('#' + kind + '-clear').addEventListener('click', () => {
    if (state[kind].rows.length && !confirm('Remove every row of this table?')) return;
    state[kind].rows = [];
    $('#' + kind + '-message').textContent = '';
    renderTable(kind);
    changed();
  });
  const panel = $('#panel-' + kind);
  panel.addEventListener('dragover', event => { event.preventDefault(); panel.classList.add('drag'); });
  panel.addEventListener('dragleave', () => panel.classList.remove('drag'));
  panel.addEventListener('drop', event => {
    event.preventDefault();
    panel.classList.remove('drag');
    if (event.dataTransfer.files[0]) loadCsv(kind, event.dataTransfer.files[0]);
  });
}

// --- Checking the data ---

const scheduleValidation = debounce(validateNow, 500);
let validationToken = 0;

async function validateNow() {
  const token = ++validationToken;
  if (!state.items.rows.length && !state.sheets.rows.length) {
    state.validation = null;
    state.marks.clear();
    applyMarks();
    renderCheck();
    return;
  }
  try {
    const result = await api('/api/validate', { items: state.items.rows, sheets: state.sheets.rows });
    if (token !== validationToken) return;
    state.validation = result;
    state.marks.clear();
    for (const problem of result.problems) {
      if (problem.row > 0 && problem.column) state.marks.set(`${problem.table}:${problem.row}:${problem.column}`, problem.message);
    }
  } catch (error) {
    if (token !== validationToken) return;
    state.validation = { problems: [{ table: '', row: 0, column: '', message: error.message }], warnings: [], groups: [], periods: 1 };
  }
  applyMarks();
  renderCheck();
  renderRollWidths();
  applySettingsState();
  updateRunSummary();
}

function applyMarks() {
  for (const cell of $$('td[data-cell]')) {
    const message = state.marks.get(cell.dataset.cell);
    cell.classList.toggle('bad', Boolean(message));
    if (message) cell.title = message; else cell.removeAttribute('title');
  }
}

function groupSelected(group) {
  if (state.selectedGroups === null) return group.items > 0;
  return state.selectedGroups.includes(group.label);
}

function groupNote(group) {
  if (group.items === 0) return 'No items: not used.';
  if (group.sheet_types === 0 || group.sheets === 0) return 'No sheets in stock: only the infinite sheet option can run.';
  return '';
}

function renderCheck() {
  const box = $('#check-result');
  box.replaceChildren();
  const v = state.validation;
  if (!v) { box.append(el('span', { class: 'muted', text: 'Add items and sheets to check them.' })); return; }

  if (v.problems.length) {
    box.append(el('p', { class: 'status-bad', text: `${v.problems.length} problem${v.problems.length === 1 ? '' : 's'} to fix before running.` }));
    const list = el('ul', { class: 'problem-list' });
    for (const p of v.problems.slice(0, 60)) {
      list.append(el('li', { class: 'bad', text: (p.table ? `${p.table[0].toUpperCase()}${p.table.slice(1)}${p.row ? ', row ' + p.row : ''}: ` : '') + p.message }));
    }
    if (v.problems.length > 60) list.append(el('li', { class: 'bad', text: `…and ${v.problems.length - 60} more.` }));
    box.append(list);
    return;
  }

  box.append(el('p', { class: 'status-ok', text: `The data is valid. ${v.periods === 1 ? 'Demand is for one period (a year).' : `Demand is split into ${v.periods} periods.`}` }));
  if (v.warnings.length) {
    const list = el('ul', { class: 'problem-list' });
    for (const w of v.warnings) list.append(el('li', { class: 'warn', text: w.message }));
    box.append(list);
  }

  const table = el('table', { class: 'grid' }, el('thead', {}, el('tr', {},
    ['Run', 'Group (material / finish / thickness)', 'Items', 'Sheet types', 'Sheets in stock', 'Note'].map(h => el('th', { text: h })))));
  const body = el('tbody');
  for (const group of v.groups) {
    const box_ = el('input', { type: 'checkbox', 'aria-label': `Run ${group.label}` });
    box_.checked = groupSelected(group);
    box_.disabled = group.items === 0;
    box_.addEventListener('change', () => {
      const current = new Set(v.groups.filter(groupSelected).map(g => g.label));
      box_.checked ? current.add(group.label) : current.delete(group.label);
      state.selectedGroups = Array.from(current);
      persist();
      renderRollWidths();
      updateRunSummary();
    });
    body.append(el('tr', {}, el('td', {}, box_), el('td', { text: group.label }),
      el('td', { class: 'num', text: nf(group.items) }), el('td', { class: 'num', text: nf(group.sheet_types) }),
      el('td', { class: 'num', text: nf(group.sheets) }), el('td', { class: 'muted', text: groupNote(group) })));
  }
  table.append(body);
  box.append(el('p', { class: 'note', text: 'Each group is solved separately. Items are only cut from sheets of the same group.' }), table);
}

// --- Settings ---

function getPath(object, path) { return path.split('.').reduce((o, k) => (o === null || o === undefined) ? undefined : o[k], object); }
function setPath(object, path, value) {
  const keys = path.split('.');
  const last = keys.pop();
  const target = keys.reduce((o, k) => (o[k] = o[k] ?? {}), object);
  target[last] = value;
}

function bindSettings() {
  for (const input of $$('[data-setting]')) {
    const path = input.dataset.setting;
    const scale = Number(input.dataset.scale || 1);
    const value = getPath(state.settings, path);
    if (input.type === 'checkbox') input.checked = Boolean(value);
    else if (input.type === 'radio') input.checked = input.value === value;
    else input.value = (value === null || value === undefined) ? '' : String(Math.round(value * scale * 1e6) / 1e6);

    input.addEventListener('change', () => {
      if (input.type === 'checkbox') setPath(state.settings, path, input.checked);
      else if (input.type === 'radio') { if (input.checked) setPath(state.settings, path, input.value); }
      else if (input.value.trim() === '') setPath(state.settings, path, null);
      else setPath(state.settings, path, Number(input.value) / scale);
      applySettingsState();
      if (path.startsWith('roll.')) renderRollWidths();
      persist();
      updateRunSummary();
    });
  }
  applySettingsState();
}

function applySettingsState() {
  const s = state.settings;
  const stock = $('[data-setting="modes.stock"]');
  const minMonth = $('[data-setting="modes.min_month"]');
  minMonth.disabled = !s.modes.stock;
  if (!s.modes.stock && s.modes.min_month) { s.modes.min_month = false; minMonth.checked = false; }
  $('#panel-roll').hidden = !s.modes.infinite;
  const rollTall = Number(s.roll.shelf_height) - Number(s.roll.top) - Number(s.roll.bottom);
  $('#roll-sizes').textContent = rollTall > 0
    ? `Shelves can be up to ${nf(rollTall, 2)} mm tall after the top and bottom margins, and each is ${nf(Number(s.roll.left) + Number(s.roll.right), 2)} mm narrower than the roll after the left and right margins.`
    : 'The top and bottom margins leave no room for a shelf. Raise the tallest shelf or lower the margins.';
  const periods = state.validation ? state.validation.periods : 1;
  $('#row-periods-per-year').hidden = periods <= 1;
  $('#holding-note').textContent = periods <= 1
    ? 'The holding cost of items is a yearly figure. Demand is for one period, a year, so items left over at the end are charged that rate.'
    : 'The holding cost of items is a yearly figure. Items in stock at the end of a period are charged that rate divided by the number of periods in a year, and so are items left at the end of the last period (one extra period).';
  void stock;
}

function renderRollWidths() {
  const table = $('#roll-widths');
  table.replaceChildren();
  const groups = state.validation ? state.validation.groups.filter(g => g.items > 0 && groupSelected(g)) : [];
  if (!groups.length) { table.append(el('tbody', {}, el('tr', {}, el('td', { class: 'muted', text: 'Check the data first to see the groups.' })))); return; }
  table.append(el('thead', {}, el('tr', {}, el('th', { text: 'Group' }), el('th', { text: 'Roll width (mm)' }),
    el('th', { text: 'Widest shelf, after the left and right margins (mm)' }))));
  const body = el('tbody');
  const sideMargins = Number(state.settings.roll.left) + Number(state.settings.roll.right);
  for (const group of groups) {
    const widths = state.settings.roll.widths;
    if (widths[group.label] === undefined && group.widest_sheet > 0) widths[group.label] = group.widest_sheet;
    const input = el('input', { type: 'number', min: '1', step: 'any', 'aria-label': `Roll width for ${group.label}` });
    const usable = el('td', { class: 'num' });
    const showUsable = () => { usable.textContent = widths[group.label] ? nf(Number(widths[group.label]) - sideMargins, 2) : '–'; };
    input.value = widths[group.label] ?? '';
    input.addEventListener('change', () => {
      widths[group.label] = input.value.trim() === '' ? null : Number(input.value);
      showUsable();
      persist();
      updateRunSummary();
    });
    showUsable();
    body.append(el('tr', {}, el('td', { text: group.label }), el('td', { class: 'editable-cell' }, input), usable));
  }
  table.append(body);
}

// What the server is sent as the settings of a run
function settingsForRun() {
  const settings = JSON.parse(JSON.stringify(state.settings));
  for (const key of ['sheet_valuation', 'sheet_valuations', 'sheet_holding_rate']) delete settings[key];
  const v = state.validation;
  settings.groups = v ? v.groups.filter(g => g.items > 0 && groupSelected(g)).map(g => g.label) : [];
  if (!settings.modes.stock) settings.modes.min_month = false;
  return settings;
}

// --- Running ---

function runBlocker() {
  const v = state.validation;
  if (!v) return 'Add items and sheets first.';
  if (v.problems.length) return 'Fix the problems in the data first.';
  const s = state.settings;
  if (!s.modes.stock && !s.modes.infinite) return 'Choose what to run in Settings.';
  const chosen = v.groups.filter(g => g.items > 0 && groupSelected(g));
  if (!chosen.length) return 'Choose at least one group to run.';
  if (s.modes.infinite) {
    const missing = chosen.filter(g => !(Number(s.roll.widths[g.label]) > 0)).map(g => g.label);
    if (missing.length) return 'Give a roll width in Settings for: ' + missing.join(', ') + '.';
  }
  return '';
}

function updateRunSummary() {
  const blocker = runBlocker();
  const summary = $('#run-summary');
  const running = state.poll !== null;
  $('#run-start').disabled = Boolean(blocker) || running;
  summary.replaceChildren();
  if (blocker) { summary.textContent = blocker; return; }
  const v = state.validation;
  const chosen = v.groups.filter(g => g.items > 0 && groupSelected(g));
  const s = state.settings;
  const parts = [];
  if (s.modes.stock) parts.push('a cutting plan from the sheet stock' + (s.modes.min_month ? ' and months of cover' : ''));
  if (s.modes.infinite) parts.push('the infinite sheet roll length');
  summary.textContent = `Ready to run ${parts.join(' and ')} for ${chosen.length} group${chosen.length === 1 ? '' : 's'}: ${chosen.map(g => g.label).join('; ')}.`;
}

function formatDuration(seconds) {
  seconds = Math.max(0, Math.round(seconds));
  const h = Math.floor(seconds / 3600), m = Math.floor((seconds % 3600) / 60), s = seconds % 60;
  return h ? `${h} h ${m} min ${s} s` : m ? `${m} min ${s} s` : `${s} s`;
}

function renderProgress(info) {
  const status = info.status || {};
  $('#panel-progress').hidden = false;
  const rows = [
    ['Run', info.name],
    ['State', stateText(info.state)],
    ['Doing now', status.stage || ''],
    ['Group', status.groups ? `${status.group || 0} of ${status.groups}` : ''],
    ['Time taken', status.started ? formatDuration((status.finished || Date.now() / 1000) - status.started) : ''],
  ];
  if (status.error) rows.push(['Error', status.error]);
  const table = $('#progress-table');
  table.replaceChildren(el('tbody', {}, rows.map(([k, v]) => el('tr', {}, el('th', { text: k }), el('td', { text: v })))));
  const done = info.state === 'done' ? 1 : (status.groups ? Math.max(0, (status.group || 1) - 1) / status.groups : 0);
  $('#progress-bar').style.width = `${Math.round(done * 100)}%`;
  const log = $('#run-log');
  const atEnd = log.scrollTop + log.clientHeight >= log.scrollHeight - 30;
  log.textContent = info.log || '';
  if (atEnd) log.scrollTop = log.scrollHeight;
}

function stateText(value) {
  return ({ running: 'Running', done: 'Finished', error: 'Stopped by an error', cancelled: 'Cancelled',
            interrupted: 'Interrupted', starting: 'Starting' })[value] || value;
}

async function startRun() {
  $('#run-error').textContent = '';
  try {
    const { id } = await api('/api/jobs', { name: $('#run-name').value, items: state.items.rows, sheets: state.sheets.rows, settings: settingsForRun() });
    follow(id);
  } catch (error) {
    $('#run-error').textContent = error.message;
  }
}

function follow(id) {
  stopPolling();
  state.jobId = id;
  $('#run-cancel').hidden = false;
  $('#panel-progress').hidden = false;
  state.poll = setInterval(() => pollRun(id), 1500);
  updateRunSummary();
  pollRun(id);
}

function stopPolling() {
  if (state.poll !== null) clearInterval(state.poll);
  state.poll = null;
  $('#run-cancel').hidden = true;
  updateRunSummary();
}

async function pollRun(id) {
  try {
    const info = await api('/api/jobs/' + id);
    if (id !== state.jobId) return;
    renderProgress(info);
    if (info.state !== 'running' && info.state !== 'starting') {
      stopPolling();
      refreshHistory();
      await openResults(id, info.name, info.state);
      if (info.state === 'done') showTab('results');
    }
  } catch (error) {
    $('#run-error').textContent = error.message;
  }
}

async function cancelRun() {
  if (!state.jobId || !confirm('Stop this run? Results of groups already finished are kept.')) return;
  try { await api(`/api/jobs/${state.jobId}/cancel`, {}); } catch (error) { $('#run-error').textContent = error.message; }
}

async function refreshHistory() {
  const table = $('#history-table');
  let jobs = [];
  try { jobs = await api('/api/jobs'); } catch (e) { return; }
  table.replaceChildren(el('thead', {}, el('tr', {}, ['Name', 'Started', 'State', ''].map(h => el('th', { text: h })))));
  const body = el('tbody');
  if (!jobs.length) body.append(el('tr', {}, el('td', { colspan: 4, class: 'muted', text: 'No runs yet.' })));
  for (const job of jobs) {
    body.append(el('tr', {}, el('td', { text: job.name }),
      el('td', { text: new Date(job.created * 1000).toLocaleString() }),
      el('td', { text: stateText(job.state) }),
      el('td', {},
        el('button', { text: 'Results', onclick: async () => { await openResults(job.id, job.name, job.state); showTab('results'); } }), ' ',
        el('button', { text: 'Load data and settings', onclick: () => reloadInput(job.id) }), ' ',
        job.state === 'running' ? el('button', { text: 'Follow', onclick: () => follow(job.id) }) : null)));
  }
  table.append(body);
}

async function reloadInput(id) {
  if ((state.items.rows.length || state.sheets.rows.length) && !confirm('Replace the data and settings on the page with those of this run?')) return;
  try {
    const input = await api(`/api/jobs/${id}/input`);
    const items = await api('/api/parse_csv', { kind: 'items', text: rowsToCsv(input.items, itemColumnsOf(input.items)) });
    const sheets = await api('/api/parse_csv', { kind: 'sheets', text: rowsToCsv(input.sheets, state.defaults.sheet_columns) });
    state.items.columns = items.columns; state.items.rows = items.rows;
    for (const row of state.items.rows) row.can_rotate = normaliseRotation(row.can_rotate);
    state.sheets.columns = sheets.columns; state.sheets.rows = sheets.rows;
    state.settings = deepMerge(state.defaults.settings, input.settings);
    state.selectedGroups = input.settings.groups || null;
    $('#periods-count').textContent = String(demandColumns().length);
    renderTable('items'); renderTable('sheets');
    bindSettingsValues();
    changed();
    showTab('data');
  } catch (error) {
    $('#run-error').textContent = error.message;
  }
}

function itemColumnsOf(rows) {
  const periods = new Set();
  for (const row of rows) for (const key of Object.keys(row)) if (key.startsWith(state.defaults.demand_prefix)) periods.add(key);
  return state.defaults.item_columns.concat(Array.from(periods).sort((a, b) => demandPeriodOf(a) - demandPeriodOf(b)));
}
function demandPeriodOf(column) { return Number(column.slice(state.defaults.demand_prefix.length)); }

function bindSettingsValues() {
  for (const input of $$('[data-setting]')) {
    const value = getPath(state.settings, input.dataset.setting);
    const scale = Number(input.dataset.scale || 1);
    if (input.type === 'checkbox') input.checked = Boolean(value);
    else if (input.type === 'radio') input.checked = input.value === value;
    else input.value = (value === null || value === undefined) ? '' : String(Math.round(value * scale * 1e6) / 1e6);
  }
  applySettingsState();
}

// --- CSV text ---

function csvCell(value) {
  const text = value === null || value === undefined ? '' : String(value);
  return /[",\n\r]/.test(text) ? '"' + text.replace(/"/g, '""') + '"' : text;
}
function rowsToCsv(rows, columns) {
  return [columns.join(',')].concat(rows.map(row => columns.map(c => csvCell(row[c])).join(','))).join('\n') + '\n';
}

// --- Results ---

async function openResults(id, name, runState) {
  try {
    state.result = await api(`/api/jobs/${id}/result`);
  } catch (error) {
    state.result = null;
  }
  state.resultJobId = id;
  state.resultName = name;
  state.resultState = runState;
  state.activeGroup = 0;
  renderResults();
}

function resultGroups() {
  const r = state.result;
  if (!r) return [];
  return (r.stock || []).map(g => ({ ...g, tab: 'Sheets: ' + g.label }))
    .concat((r.roll || []).map(g => ({ ...g, tab: 'Roll: ' + g.label })));
}

function renderResults() {
  const r = state.result;
  $('#results-empty').hidden = Boolean(r);
  $('#results-body').hidden = !r;
  if (!r) return;
  $('#results-title').textContent = 'Results: ' + state.resultName;
  const periodsText = r.n_periods === 1 ? 'one period (a year)' : `${r.n_periods} periods`;
  $('#results-state').textContent = `${stateText(state.resultState)}. Demand in ${periodsText}.`;

  const warnings = $('#results-warnings');
  warnings.replaceChildren();
  if ((r.warnings || []).length) {
    const list = el('ul', { class: 'problem-list' });
    for (const w of r.warnings) list.append(el('li', { class: 'warn', text: w.message }));
    warnings.append(el('div', { class: 'panel-body' }, list));
  }

  const groups = resultGroups();
  const tabs = $('#group-tabs');
  tabs.replaceChildren(...groups.map((g, i) => el('button', {
    class: i === state.activeGroup ? 'active' : '', text: g.tab, onclick: () => { state.activeGroup = i; renderResults(); },
  })));
  const holder = $('#group-result');
  holder.replaceChildren();
  if (!groups.length) { holder.append(el('div', { class: 'panel' }, el('div', { class: 'panel-body muted', text: 'No group has finished yet.' }))); return; }
  const group = groups[Math.min(state.activeGroup, groups.length - 1)];
  holder.append(group.kind === 'roll' ? renderRollGroup(group) : renderStockGroup(group));
}

function panel(title, ...content) {
  return el('div', { class: 'panel' }, el('h2', { text: title }), ...content);
}
function kvTable(rows) {
  return el('table', { class: 'grid kv' }, el('tbody', {}, rows.filter(Boolean).map(([k, v]) => el('tr', {}, el('th', { text: k }), el('td', { text: v })))));
}
function dataTable(headers, rows, numericFrom = 1) {
  return el('div', { class: 'table-wrap' }, el('table', { class: 'grid' },
    el('thead', {}, el('tr', {}, headers.map((h, i) => el('th', { class: i >= numericFrom ? 'num' : '', text: h })))),
    el('tbody', {}, rows.map(row => el('tr', {}, row.map((cell, i) => el('td', { class: i >= numericFrom ? 'num' : '', text: cell })))))));
}

// A note for the page when the integer programme stopped at its time limit
function limitNote(g) {
  const solver = g.solver;
  if (!solver || !solver.ip_status || solver.ip_status === 'OPTIMAL') return null;
  return el('p', { class: 'status-warn', text: 'The solver reached its time limit. This is the best plan it found, which may not be the best possible.' });
}

const itemsWorth = (units, value) => `${nf(units, 2)} items, worth ${nf(value, 2)}`;

function renderStockGroup(g) {
  const holder = el('div');
  if (g.status !== 'ok') {
    holder.append(panel(g.label, el('div', { class: 'panel-body' }, kvTable([['Status', g.message || g.status]]))));
    if (g.items) holder.append(panel('Items', itemsTable(g)));
    return holder;
  }
  const s = g.summary;
  holder.append(panel('Summary: ' + g.label, el('div', { class: 'panel-body' }, limitNote(g), kvTable([
    ['Demand', itemsWorth(s.demand_units, s.demand_value)],
    ['Made from the sheets', itemsWorth(s.from_sheets_units, s.from_sheets_value)],
    ['Bought in', itemsWorth(s.bought_units, s.bought_value)],
    ['Left over after meeting demand', itemsWorth(s.left_over_units, s.left_over_value)],
    ['Sheets used', `${nf(s.sheets_used)} of ${nf(s.sheets_in_stock)} in stock`],
    ['Sheets left over', nf(s.sheets_left)],
    ['Waste on the sheets used', pct(s.waste_fraction)],
  ]))));

  holder.append(panel('Sheets', dataTable(['Sheet', 'Width (mm)', 'Height (mm)', 'In stock', 'Used', 'Left over', 'Note'],
    g.sheets.map(x => [x.sheet_id, nf(x.width, 2), nf(x.height, 2), nf(x.quantity), nf(x.used || 0), nf(x.quantity - (x.used || 0)),
      x.usable === false ? 'no item fits on this sheet' : '']), 1)));
  holder.append(panel('Items', itemsTable(g)));

  if (g.periods > 1) {
    const rows = g.periods_cut.map((p, i) => [`Period ${i + 1}`, nf(p.demand_units), nf(p.sheets_used), nf(p.bought_units, 2),
      nf(p.in_stock_units, 2), pct(p.waste_fraction)]);
    holder.append(panel('Each period', dataTable(['Period', 'Items demanded', 'Sheets used', 'Items bought in', 'Items in stock at the end', 'Waste'], rows)));
  }

  if (g.min_month) holder.append(renderMinMonth(g));
  holder.append(renderPatterns('Patterns used', g.patterns, g, false));
  return holder;
}

function itemsTable(g) {
  const headers = ['Item', 'Size (mm)', 'Rotate', 'Value each', 'Demand', 'Made from sheets', 'Bought in', 'Value bought', 'Left over', 'Value left over', 'Note'];
  const rows = g.items.map(it => [it.item_id, `${nf(it.width, 2)} × ${nf(it.height, 2)}`, it.can_rotate ? 'yes' : 'no', nf(it.value, 2),
    nf(it.demand), nf(it.from_sheets, 2), nf(it.bought, 2), nf(it.bought * it.value, 2), nf(it.left_over, 2), nf(it.left_over * it.value, 2),
    it.fits === false ? 'does not fit any sheet' : '']);
  return dataTable(headers, rows, 3);
}

function renderMinMonth(g) {
  const m = g.min_month;
  if (m.status !== 'ok') return panel('Months of cover', el('div', { class: 'panel-body muted', text: 'No plan was found.' }));
  const rows = g.items.map(it => {
    const months = m.runways[it.item_id];
    return [it.item_id, nf(it.annual_demand), months === null || months === undefined ? 'no demand' : nf(months)];
  });
  const box = panel('Months of cover',
    el('div', { class: 'panel-body' }, el('p', { class: 'note', text: `With the sheets used for profit alone, the stock covers each item's demand for this many whole months before it must be bought in. The plan below uses ${nf(m.sheets_cut)} of ${nf(m.sheets_available)} sheets, with ${pct(m.waste_fraction)} waste.` })),
    dataTable(['Item', 'Yearly demand', 'Months covered'], rows));
  box.append(renderPatterns('Patterns of the months-of-cover plan', m.patterns, g, false, true));
  return box;
}

function renderRollGroup(g) {
  const holder = el('div');
  if (g.status !== 'ok') {
    holder.append(panel(g.label, el('div', { class: 'panel-body' }, kvTable([['Status', g.message || g.status]]))));
    return holder;
  }
  const w = g.waste || {};
  holder.append(panel('Summary: ' + g.label,
    el('div', { class: 'toolbar' }, el('button', { class: 'primary', text: 'View the roll', onclick: () => openRoll(g) }),
      el('span', { class: 'muted', text: 'Opens a window you can scroll along the roll, with the shelves stacked as they are cut.' })),
    el('div', { class: 'panel-body' }, kvTable([
    ['Roll length needed', `${nf(g.roll_length / 1000, 2)} m (${nf(g.roll_length, 1)} mm) on a roll ${nf(g.roll_width, 1)} mm wide`],
    ['Shelves cut', `${nf(g.shelves_cut)} shelves of ${nf(g.shelves.length)} kinds`],
    ['Waste on the roll used', pct(w.waste_fraction)],
    ['Left over after meeting demand', itemsWorth(w.overproduced_units, w.overproduced_value)],
    ['Gap between items and shelves', `${nf(g.clearance.gap, 2)} mm`],
    ['Margins (left, right, top, bottom)', `${nf(g.clearance.left, 2)}, ${nf(g.clearance.right, 2)}, ${nf(g.clearance.top, 2)}, ${nf(g.clearance.bottom, 2)} mm`],
    ['Tallest shelf, before the top and bottom margins', `${nf(g.shelf_height_limit, 0)} mm`],
    g.left_out.length ? ['Left out (too wide for the roll)', g.left_out.join(', ')] : null,
  ]))));
  holder.append(panel('Items', dataTable(['Item', 'Size (mm)', 'Rotate', 'Demand', 'Made from the roll', 'Left over'],
    g.items.map(it => [it.item_id, `${nf(it.width, 2)} × ${nf(it.height, 2)}`, it.can_rotate ? 'yes' : 'no', nf(it.demand), nf(it.cut), nf(it.left_over)]), 3)));
  holder.append(renderPatterns('Shelves', g.shelves, g, true));
  return holder;
}

// --- Patterns ---

function itemColors(g) {
  const ids = g.items.map(i => i.item_id);
  const colors = new Map();
  ids.forEach((id, i) => colors.set(id, `hsl(${Math.round((i * 137.508) % 360)}, 42%, 80%)`));
  return colors;
}

function niceStep(raw) {
  const power = Math.pow(10, Math.floor(Math.log10(raw)));
  const unit = raw / power;
  return (unit < 1.5 ? 1 : unit < 3.5 ? 2 : unit < 7.5 ? 5 : 10) * power;
}

// Draws one layout. Positions are in mm with the origin at the bottom-left, so
// y is turned over for the screen.
function drawLayout(layout, colors, margins) {
  const W = layout.width, H = layout.height;
  const pad = Math.max(W, H) * 0.012;
  const svg = svgEl('svg', { viewBox: `${-pad} ${-pad} ${W + 2 * pad} ${H + 2 * pad}`, role: 'img', preserveAspectRatio: 'xMidYMid meet' });
  svg.append(svgEl('rect', { class: 'sheet', x: 0, y: 0, width: W, height: H }));

  const step = niceStep(Math.max(W, H) / 10);
  for (let x = step; x < W; x += step) svg.append(svgEl('line', { class: 'grid-line', x1: x, y1: 0, x2: x, y2: H }));
  for (let y = step; y < H; y += step) svg.append(svgEl('line', { class: 'grid-line', x1: 0, y1: H - y, x2: W, y2: H - y }));

  if (margins && (margins.left || margins.right || margins.top || margins.bottom)) {
    svg.append(svgEl('rect', { class: 'margin', x: margins.left, y: margins.top,
      width: Math.max(0, W - margins.left - margins.right), height: Math.max(0, H - margins.top - margins.bottom) }));
  }
  for (const gap of layout.gaps) {
    svg.append(svgEl('rect', { class: 'gap', x: gap.x, y: H - gap.y - gap.h, width: gap.w, height: gap.h }));
  }
  const minFont = Math.max(W, H) * 0.012;
  for (const item of layout.items) {
    const title = svgEl('title');
    title.textContent = `${item.item_id}${item.rotated ? ' (rotated)' : ''}: ${nf(item.w, 2)} × ${nf(item.h, 2)} at (${nf(item.x, 2)}, ${nf(item.y, 2)})`;
    svg.append(svgEl('rect', { class: 'item', x: item.x, y: H - item.y - item.h, width: item.w, height: item.h,
      fill: colors.get(item.item_id) || '#ddd' }, title));
    const label = item.item_id + (item.rotated ? ' ↻' : '');
    const font = Math.min(item.h * 0.5, item.w / (label.length * 0.62 + 0.4));
    if (font >= minFont) {
      const text = svgEl('text', { x: item.x + item.w / 2, y: H - item.y - item.h / 2, 'font-size': font });
      text.textContent = label;
      svg.append(text);
    }
  }
  return svg;
}

function marginsOf(roll) {
  const c = state.result && state.result.settings ? state.result.settings : {};
  const e = (roll ? c.roll : c.clearance) || {};
  const above = roll ? Number(e.gap) || 0 : Number(e.top) || 0;
  const below = roll ? Number(e.gap) || 0 : Number(e.bottom) || 0;
  return { left: Number(e.left) || 0, right: Number(e.right) || 0, top: above, bottom: below };
}

function countsText(counts) {
  return Object.entries(counts).map(([id, n]) => `${id} ×${n}`).join(', ');
}

function renderPatterns(title, patterns, g, roll, nested = false) {
  const colors = itemColors(g);
  const margins = marginsOf(roll);
  const sorted = patterns.slice().sort((a, b) => roll
    ? b.shelf_height - a.shelf_height
    : String(a.sheet_id).localeCompare(String(b.sheet_id)) || b.quantity - a.quantity);

  const cards = el('div', { class: 'cards' });
  const draw = filter => {
    cards.replaceChildren();
    for (const p of sorted) {
      if (filter && !roll && p.sheet_id !== filter) continue;
      const heading = roll ? `Shelf ${p.pattern}, ${nf(p.shelf_height, 1)} mm tall` : `Sheet ${p.sheet_id}, pattern ${p.pattern}`;
      const periodic = !roll && p.quantity_by_period.length > 1;
      cards.append(el('div', { class: 'card' + (p.layout.problems.length ? ' problem' : ''), tabindex: 0, role: 'button',
        'aria-label': `Open ${heading}`,
        onclick: () => openPattern(p, g, colors, margins, roll), onkeydown: e => { if (e.key === 'Enter') openPattern(p, g, colors, margins, roll); } },
        el('div', { class: 'drawing' }, drawLayout(p.layout, colors, margins)),
        el('div', { class: 'caption' },
          el('b', { text: heading }),
          el('div', { text: `${nf(p.quantity)} ${roll ? 'shelf' : 'sheet'}${p.quantity === 1 ? '' : 's'} cut this way` + (periodic ? ` (by period: ${p.quantity_by_period.join(', ')})` : '') + `, ${pct(p.utilisation)} filled` }),
          el('div', { class: 'counts', text: countsText(p.item_counts) }),
          p.layout.problems.length ? el('div', { class: 'status-bad', text: 'Breaks the clearance rules' }) : null)));
    }
  };

  const toolbar = el('div', { class: 'toolbar' });
  if (!roll) {
    const sheetIds = Array.from(new Set(sorted.map(p => p.sheet_id)));
    if (sheetIds.length > 1) {
      const select = el('select', { 'aria-label': 'Show patterns for one sheet' },
        el('option', { value: '', text: 'All sheets' }), sheetIds.map(id => el('option', { value: id, text: 'Sheet ' + id })));
      select.addEventListener('change', () => draw(select.value));
      toolbar.append('Show', select);
    }
  }
  toolbar.append(el('span', { class: 'muted', text: 'Click a drawing to enlarge it. The dashed line is the edge margin and the grey strips are the gaps between items.' }));
  draw('');
  const box = nested ? el('div', {}) : el('div', { class: 'panel' });
  box.append(el(nested ? 'h3' : 'h2', nested ? { text: title, style: 'padding: 0 12px' } : { text: title }), toolbar, cards);
  return box;
}

function openPattern(p, g, colors, margins, roll) {
  const dialog = $('#pattern-dialog');
  $('#dialog-title').textContent = roll ? `Shelf ${p.pattern}` : `Sheet ${p.sheet_id}, pattern ${p.pattern}`;
  const body = $('#dialog-body');
  body.replaceChildren();
  body.append(el('div', { class: 'drawing' }, drawLayout(p.layout, colors, margins)));

  const used = new Set(p.layout.items.map(i => i.item_id));
  body.append(el('div', { class: 'legend' }, Array.from(used).map(id =>
    el('span', {}, el('i', { style: `background:${colors.get(id)}` }), id))));

  const facts = [
    roll ? ['Shelf', `${nf(p.layout.width, 2)} mm wide, ${nf(p.shelf_height, 2)} mm tall (${nf(p.layout.height, 2)} mm with the gap above and below)`]
         : ['Sheet', `${p.sheet_id}, ${nf(p.sheet_width, 2)} × ${nf(p.sheet_height, 2)} mm`],
    [roll ? 'Shelves cut this way' : 'Sheets cut this way', nf(p.quantity) + (p.quantity_by_period.length > 1 ? ` (by period: ${p.quantity_by_period.join(', ')})` : '')],
    ['Items on it', countsText(p.item_counts)],
    ['Filled', pct(p.utilisation)],
    ['Value of the items', nf(p.value, 2)],
    ['Clearance check', p.layout.problems.length ? 'Breaks the rules: ' + p.layout.problems.join('; ') : 'Passed: every item meets the gap and edge margins'],
  ];
  body.append(kvTable(facts));

  const sorted = p.layout.items.slice().sort((a, b) => a.y - b.y || a.x - b.x);
  body.append(el('h3', { text: 'Position of every item (mm, from the bottom-left corner)' }),
    dataTable(['Item', 'x', 'y', 'Width', 'Height', 'Rotated'], sorted.map(i => [i.item_id, nf(i.x, 2), nf(i.y, 2), nf(i.w, 2), nf(i.h, 2), i.rotated ? 'yes' : 'no']), 1));
  dialog.showModal();
}

// --- The roll ---

// The shelves in the order they are drawn along the roll. The plan says how many of
// each kind of shelf to cut, not their order, so they are laid out by kind, tallest
// first, each as many times as it is cut.
function shelvesAlongRoll(g) {
  const kinds = g.shelves.slice().sort((a, b) => b.shelf_height - a.shelf_height || a.pattern - b.pattern);
  const along = [];
  for (const kind of kinds) for (let i = 0; i < kind.quantity; i++) along.push(kind);
  return along;
}

// Draws the roll as one tall picture: shelves one under another, as wide as the roll
// and as tall as they are, separated by the gap, with one more gap at each end. The
// left and right margins are dashed lines down the roll. The top and bottom margins
// of a shelf only limit how tall it can be, so they are not drawn here.
function drawRoll(g) {
  const W = g.roll_width, gap = g.clearance.gap, c = g.clearance;
  const colors = itemColors(g);
  const shelves = shelvesAlongRoll(g);
  const length = gap + shelves.reduce((sum, p) => sum + p.shelf_height + gap, 0);
  const gutterLeft = W * 0.17, gutterRight = W * 0.09, pad = W * 0.01;
  const svg = svgEl('svg', { viewBox: `${-gutterLeft} ${-pad} ${W + gutterLeft + gutterRight} ${length + 2 * pad}`, role: 'img',
    preserveAspectRatio: 'xMidYMin meet' });
  svg.append(svgEl('rect', { class: 'sheet', x: 0, y: 0, width: W, height: length }));
  for (const x of [c.left, W - c.right]) {
    if (c.left || c.right) svg.append(svgEl('line', { class: 'margin', x1: x, y1: 0, x2: x, y2: length }));
  }

  const labelSize = W * 0.022;
  const minFont = W * 0.012;
  let top = gap;
  svg.append(svgEl('rect', { class: 'gap', x: 0, y: 0, width: W, height: gap }));
  shelves.forEach((p, n) => {
    const h = p.shelf_height;
    for (const item of p.layout.items) {
      const y = top + h - (item.y - c.gap) - item.h;          // a drawn shelf has a gap below its items
      const title = svgEl('title');
      title.textContent = `Shelf ${n + 1}, ${item.item_id}${item.rotated ? ' (rotated)' : ''}: ${nf(item.w, 2)} × ${nf(item.h, 2)}`;
      svg.append(svgEl('rect', { class: 'item', x: item.x, y, width: item.w, height: item.h, fill: colors.get(item.item_id) || '#ddd' }, title));
      const label = item.item_id + (item.rotated ? ' ↻' : '');
      const font = Math.min(item.h * 0.5, item.w / (label.length * 0.62 + 0.4));
      if (font >= minFont) {
        const text = svgEl('text', { x: item.x + item.w / 2, y: y + item.h / 2, 'font-size': font });
        text.textContent = label;
        svg.append(text);
      }
    }
    const tag = svgEl('text', { x: -W * 0.01, y: top + h / 2, 'font-size': labelSize });
    tag.setAttribute('style', 'text-anchor: end');
    tag.textContent = `${n + 1}: ${nf(h, 0)} mm`;
    svg.append(tag);
    top += h;
    svg.append(svgEl('rect', { class: 'gap', x: 0, y: top, width: W, height: gap }));
    top += gap;
  });

  // A ruler down the right side, in metres along the roll
  const step = niceStep(length / 12);
  for (let at = 0; at <= length; at += step) {
    svg.append(svgEl('line', { class: 'margin', x1: W, y1: at, x2: W + W * 0.015, y2: at }));
    const mark = svgEl('text', { x: W + W * 0.02, y: at, 'font-size': labelSize });
    mark.setAttribute('style', 'text-anchor: start');
    mark.textContent = `${nf(at / 1000, 1)} m`;
    svg.append(mark);
  }
  return { svg, shelves: shelves.length, length };
}

let rollZoom = 1;

function showRoll(g) {
  const body = $('#roll-dialog-body');
  const { svg, shelves, length } = drawRoll(g);
  svg.style.width = `${rollZoom * 100}%`;
  const used = new Set(g.shelves.flatMap(p => p.layout.items.map(i => i.item_id)));
  const colors = itemColors(g);
  body.replaceChildren(
    el('p', { class: 'note', text: `The roll is ${nf(length / 1000, 2)} m long and ${nf(g.roll_width, 0)} mm wide, cut into ${nf(shelves)} shelves. ` +
      `The plan gives how many of each shelf to cut, not their order, so they are stacked here by kind, tallest first. ` +
      `Grey strips are the gaps between shelves and at the ends of the roll, and the dashed lines are the left and right margins. ` +
      `Scroll to move along the roll; hover over an item to see its size.` }),
    el('div', { class: 'legend' }, Array.from(used).map(id => el('span', {}, el('i', { style: `background:${colors.get(id)}` }), id))),
    el('div', { class: 'roll-view' }, el('div', { class: 'drawing' }, svg)));
}

function openRoll(g) {
  rollZoom = 1;
  $('#roll-dialog-title').textContent = 'The roll: ' + g.label;
  showRoll(g);
  $('#roll-dialog').showModal();
  $('#roll-dialog').dataset.group = state.activeGroup;
  $('#roll-dialog-body').scrollTop = 0;
}

function zoomRoll(factor) {
  const g = resultGroups()[Number($('#roll-dialog').dataset.group)];
  if (!g) return;
  rollZoom = Math.min(8, Math.max(0.5, rollZoom * factor));
  const scroll = $('#roll-dialog-body').scrollTop / ($('#roll-dialog-body').scrollHeight || 1);
  showRoll(g);
  $('#roll-dialog-body').scrollTop = scroll * $('#roll-dialog-body').scrollHeight;
}

// --- Downloads ---

function planCsv() {
  const header = ['group', 'plan', 'pattern', 'sheet_id', 'times_cut', 'item_id', 'x_mm', 'y_mm', 'width_mm', 'height_mm', 'rotated'];
  const lines = [header.join(',')];
  const add = (g, plan, patterns, roll) => {
    for (const p of patterns) {
      for (const i of p.layout.items) {
        lines.push([g.label, plan, p.pattern, roll ? '' : p.sheet_id, p.quantity, i.item_id, i.x, i.y, i.w, i.h, i.rotated ? 'yes' : 'no'].map(csvCell).join(','));
      }
    }
  };
  for (const g of state.result.stock || []) {
    if (g.patterns) add(g, 'sheet stock', g.patterns, false);
    if (g.min_month && g.min_month.patterns) add(g, 'months of cover', g.min_month.patterns, false);
  }
  for (const g of state.result.roll || []) if (g.shelves) add(g, 'roll shelf', g.shelves, true);
  return lines.join('\n') + '\n';
}

// --- Start-up ---

async function init() {
  for (const button of $$('#tabs button')) button.addEventListener('click', () => showTab(button.dataset.tab));
  for (const button of $$('[data-goto]')) button.addEventListener('click', () => showTab(button.dataset.goto));
  $('#dialog-close').addEventListener('click', () => $('#pattern-dialog').close());
  $('#roll-dialog-close').addEventListener('click', () => $('#roll-dialog').close());
  $('#roll-zoom-in').addEventListener('click', () => zoomRoll(1.5));
  $('#roll-zoom-out').addEventListener('click', () => zoomRoll(1 / 1.5));
  $('#pattern-dialog').addEventListener('click', event => { if (event.target === event.currentTarget) event.currentTarget.close(); });

  try {
    state.defaults = await api('/api/defaults');
    $('#server-status').textContent = 'Server connected';
  } catch (error) {
    $('#server-status').textContent = 'Cannot reach the server. Start it with the start script.';
    $('#server-status').classList.add('bad');
    return;
  }

  const stored = loadStored();
  state.settings = deepMerge(state.defaults.settings, stored ? stored.settings : undefined);
  resetColumns('items');
  resetColumns('sheets');
  if (stored && stored.items && stored.items.columns.length) state.items = stored.items;
  if (stored && stored.sheets && stored.sheets.columns.length) state.sheets = stored.sheets;
  if (stored) { state.selectedGroups = stored.selectedGroups ?? null; state.runName = stored.runName || ''; }
  $('#run-name').value = state.runName;
  $('#run-name').addEventListener('input', () => { state.runName = $('#run-name').value; persist(); });

  $('#periods-count').textContent = String(demandColumns().length);
  $('#periods-less').addEventListener('click', () => setPeriods(demandColumns().length - 1));
  $('#periods-more').addEventListener('click', () => setPeriods(demandColumns().length + 1));
  setupTableControls('items');
  setupTableControls('sheets');
  renderTable('items');
  renderTable('sheets');
  bindSettings();

  $('#roll-copy').addEventListener('click', () => {
    for (const key of ['gap', 'left', 'right', 'top', 'bottom']) state.settings.roll[key] = state.settings.clearance[key];
    bindSettingsValues();
    renderRollWidths();
    persist();
    updateRunSummary();
  });
  $('#run-start').addEventListener('click', startRun);
  $('#run-cancel').addEventListener('click', cancelRun);
  $('#download-json').addEventListener('click', () => download(`results-${state.resultJobId}.json`, JSON.stringify(state.result, null, 1), 'application/json'));
  $('#download-csv').addEventListener('click', () => download(`cutting-plan-${state.resultJobId}.csv`, planCsv(), 'text/csv'));

  await renderExamples();
  validateNow();

  // Pick up a run that is still going, for example after the page is reloaded
  try {
    const jobs = await api('/api/jobs');
    const running = jobs.find(j => j.state === 'running');
    if (running) follow(running.id);
  } catch (e) { /* no runs */ }
}

// The example tables are drawn from the template files, so what is shown is what can be downloaded
async function renderExamples() {
  const draw = async (target, file) => {
    try {
      const text = await (await fetch('/web/templates/' + file)).text();
      const rows = text.trim().split(/\r?\n/).map(line => line.split(','));
      $(target).replaceChildren(el('table', {}, el('thead', {}, el('tr', {}, rows[0].map(h => el('th', { text: h })))),
        el('tbody', {}, rows.slice(1).map(r => el('tr', {}, r.map(c => el('td', { text: c })))))));
    } catch (e) { /* the examples are a convenience */ }
  };
  await Promise.all([draw('#example-items', 'items_template.csv'), draw('#example-items-periods', 'items_template_periods.csv'),
                     draw('#example-sheets', 'sheets_template.csv')]);
}

document.addEventListener('DOMContentLoaded', init);

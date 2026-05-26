// ══════════════════════════════════════════════════════════════
//  EXERCISE DATABASE
// ══════════════════════════════════════════════════════════════
const EXERCISES = [
  { name: 'Bench Press', muscle: 'Chest', type: 'Barbell' }, { name: 'Incline Bench Press', muscle: 'Chest', type: 'Barbell' },
  { name: 'Chest Fly', muscle: 'Chest', type: 'Dumbbell' }, { name: 'Push-Up', muscle: 'Chest', type: 'Bodyweight' },
  { name: 'Squat', muscle: 'Legs', type: 'Barbell' }, { name: 'Leg Press', muscle: 'Legs', type: 'Machine' },
  { name: 'Romanian Deadlift', muscle: 'Legs', type: 'Barbell' }, { name: 'Lunges', muscle: 'Legs', type: 'Dumbbell' },
  { name: 'Leg Curl', muscle: 'Legs', type: 'Machine' }, { name: 'Calf Raise', muscle: 'Legs', type: 'Machine' },
  { name: 'Deadlift', muscle: 'Back', type: 'Barbell' }, { name: 'Pull-Up', muscle: 'Back', type: 'Bodyweight' },
  { name: 'Lat Pulldown', muscle: 'Back', type: 'Machine' }, { name: 'Barbell Row', muscle: 'Back', type: 'Barbell' },
  { name: 'Cable Row', muscle: 'Back', type: 'Machine' }, { name: 'Overhead Press', muscle: 'Shoulders', type: 'Barbell' },
  { name: 'Lateral Raise', muscle: 'Shoulders', type: 'Dumbbell' }, { name: 'Front Raise', muscle: 'Shoulders', type: 'Dumbbell' },
  { name: 'Face Pull', muscle: 'Shoulders', type: 'Cable' }, { name: 'Barbell Curl', muscle: 'Arms', type: 'Barbell' },
  { name: 'Hammer Curl', muscle: 'Arms', type: 'Dumbbell' }, { name: 'Tricep Dip', muscle: 'Arms', type: 'Bodyweight' },
  { name: 'Skull Crusher', muscle: 'Arms', type: 'Barbell' }, { name: 'Plank', muscle: 'Core', type: 'Bodyweight' },
  { name: 'Crunch', muscle: 'Core', type: 'Bodyweight' }, { name: 'Ab Wheel', muscle: 'Core', type: 'Equipment' },
];

// ══════════════════════════════════════════════════════════════
//  STATE
// ══════════════════════════════════════════════════════════════
let token = localStorage.getItem('mrfit_token') || '';
let baseUrl = localStorage.getItem('mrfit_url') || 'http://localhost:8000';
let currentTab = 'login';
let prefillExercise = null;
let selectedMuscle = 'All';
let selectedExercise = null;
let sets = [{ reps: '', weight: '' }];
let recognition = null;
let listening = false;
let volumeChart = null;
let calsChart = null;
let todayLogs = [];
let heatmapData = null;
let heatmapLoaded = false;
let editingLogId = null;
let editingGroupName = null;
let coachHistory = []; // [{role: 'user'|'coach', text: '...'}]

// Restore saved backend URL into the input
document.getElementById('backend-url').value = baseUrl;

// ══════════════════════════════════════════════════════════════
//  INIT
// ══════════════════════════════════════════════════════════════
if (token) {
  showApp();
} else {
  document.getElementById('auth-screen').style.display = 'flex';
}

// ══════════════════════════════════════════════════════════════
//  API HELPER
// ══════════════════════════════════════════════════════════════
function getBase() {
  return (document.getElementById('backend-url').value.trim() || baseUrl).replace(/\/$/, '');
}

async function api(method, path, body) {
  const url = getBase() + path;
  const opts = { method, headers: { 'Content-Type': 'application/json' } };
  if (token) opts.headers['Authorization'] = `Bearer ${token}`;
  if (body) opts.body = JSON.stringify(body);

  let resp;
  try {
    resp = await fetch(url, opts);
  } catch (e) {
    throw new Error('Network error — is the backend running?');
  }

  if (resp.status === 204) return null;
  const data = await resp.json();
  if (!resp.ok) throw new Error(data.detail || `HTTP ${resp.status}`);
  return data;
}

// ══════════════════════════════════════════════════════════════
//  AUTH
// ══════════════════════════════════════════════════════════════
function switchAuthTab(tab) {
  currentTab = tab;
  document.querySelectorAll('.auth-tab').forEach((t, i) =>
    t.classList.toggle('active', ['login', 'signup'][i] === tab));
  document.getElementById('auth-btn').textContent =
    tab === 'login' ? 'Login' : 'Create Account';
  document.getElementById('auth-error').textContent = '';
}

async function submitAuth() {
  const email = document.getElementById('auth-email').value.trim();
  const password = document.getElementById('auth-password').value;
  const btn = document.getElementById('auth-btn');
  const errEl = document.getElementById('auth-error');

  if (!email || !password) { errEl.textContent = 'Please fill in both fields'; return; }

  btn.disabled = true;
  btn.textContent = 'Please wait…';
  errEl.textContent = '';

  baseUrl = getBase();
  localStorage.setItem('mrfit_url', baseUrl);

  try {
    const path = currentTab === 'login' ? '/auth/login' : '/auth/signup';
    const data = await api('POST', path, { email, password });
    token = data.access_token;
    localStorage.setItem('mrfit_token', token);
    showApp();
  } catch (e) {
    errEl.textContent = e.message;
    btn.disabled = false;
    btn.textContent = currentTab === 'login' ? 'Login' : 'Create Account';
  }
}

function logout() {
  token = '';
  localStorage.removeItem('mrfit_token');
  todayLogs = [];
  heatmapData = null;
  heatmapLoaded = false;
  if (document.getElementById('day-details-container')) {
    document.getElementById('day-details-container').style.display = 'none';
  }
  editingLogId = null;
  prefillExercise = null;
  if (volumeChart) { volumeChart.destroy(); volumeChart = null; }
  if (calsChart) { calsChart.destroy(); calsChart = null; }

  document.getElementById('app').style.display = 'none';
  document.getElementById('auth-screen').style.display = 'flex';
  document.getElementById('auth-email').value = '';
  document.getElementById('auth-password').value = '';
}

function showApp() {
  document.getElementById('auth-screen').style.display = 'none';
  document.getElementById('app').style.display = 'block';
  document.getElementById('today-date').textContent =
    new Date().toLocaleDateString('en', { weekday: 'long', month: 'long', day: 'numeric' });
  loadTodayLogs();
}

// ══════════════════════════════════════════════════════════════
//  PAGE NAVIGATION
// ══════════════════════════════════════════════════════════════
function showPage(page) {
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.nav-tab').forEach(t => t.classList.remove('active'));
  document.getElementById('page-' + page).classList.add('active');
  ['track', 'library', 'stats', 'coach'].forEach((p, i) => {
    if (p === page) document.querySelectorAll('.nav-tab')[i].classList.add('active');
  });
  if (page === 'library') loadLibraryPage();
  if (page === 'stats') loadStats();
  if (page === 'track') loadTodayLogs();
}

// ══════════════════════════════════════════════════════════════
//  TRACK PAGE
// ══════════════════════════════════════════════════════════════
async function loadTodayLogs() {
  try {
    const date = new Date().toISOString().slice(0, 10);
    todayLogs = await api('GET', `/logs?date=${date}`);
    renderTodayLog();
  } catch (e) {
    if (e.message.includes('401')) logout();
  }
}

function renderTodayLog() {
  const cals = todayLogs
    .filter(l => l.type === 'NUTRITION')
    .reduce((s, l) => s + (l.calories || 0), 0);
  const vol = todayLogs
    .filter(l => l.type === 'EXERCISE')
    .reduce((s, l) => s + (l.volume || 0), 0);

  document.getElementById('total-cals').textContent = Math.round(cals);
  document.getElementById('total-volume').textContent = Math.round(vol);

  const container = document.getElementById('today-log');
  if (!todayLogs.length) {
    container.innerHTML = '<div class="empty-state">Nothing logged yet — start with a set or a meal</div>';
    return;
  }
  
  container.innerHTML = getGroupedLogsHTML(todayLogs, true);
}

function getGroupedLogsHTML(logsArray, allowActions=true) {
  const groupsMap = new Map();
  const ungrouped = [];
  
  for (const log of logsArray) {
    if (log.type === 'EXERCISE') {
      if (!groupsMap.has(log.name)) groupsMap.set(log.name, []);
      groupsMap.get(log.name).push(log);
    } else {
      ungrouped.push(log);
    }
  }

  let html = '';
  for (const [name, logs] of groupsMap.entries()) {
    logs.sort((a,b) => a.id - b.id);
    html += logGroupHTML(logs, allowActions);
  }
  
  for (const log of ungrouped) {
    html += logItemHTML(log, allowActions);
  }
  
  return html;
}

function logGroupHTML(logs, allowActions=true) {
  const first = logs[0];
  const safeName = escapeHTML(first.name);
  const time = parseDate(first.created_at)
    .toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    
  if (editingGroupName === first.name) {
    return `
    <div class="log-item-group" style="background: var(--card-bg); border: 1px solid var(--border); border-radius: 12px; margin-bottom: 12px; padding: 10px;">
      <div class="edit-fields">
        <input type="text" id="edit-group-name-${first.id}" value="${safeName}" class="edit-input" placeholder="Exercise Name" />
        <div class="edit-actions" style="margin-top: 10px;">
          <button class="btn-save-edit" onclick="saveEditGroup('${escapeHTML(first.name).replace(/'/g, "\\'")}', ${first.id})">Save Group Name</button>
          <button class="btn-cancel-edit" onclick="cancelEditGroup()">Cancel</button>
        </div>
      </div>
    </div>
    `;
  }
    
  let totalVol = 0;
  const setsHTML = logs.map((l, i) => {
    totalVol += (l.volume || 0);
    const val = `${Math.round(l.volume || 0)} kg`;
    
    const repsInput = allowActions 
      ? `<input type="number" class="inline-set-input" value="${l.reps || ''}" placeholder="-" onchange="inlineUpdateLog(${l.id}, 'reps', this.value)" />` 
      : `${l.reps || '?'}`;
      
    const weightInput = allowActions 
      ? `<input type="number" class="inline-set-input" value="${l.weight || ''}" step="0.5" placeholder="-" onchange="inlineUpdateLog(${l.id}, 'weight', this.value)" />` 
      : `${l.weight || '?'}`;

    return `
      <div class="log-set-row" id="log-item-${l.id}" style="display: flex; align-items: center; padding: 8px 0; border-top: 1px solid rgba(255,255,255,0.05);">
        <div class="log-set-detail" style="flex: 1; font-family: 'DM Mono', monospace; font-size: 14px; color: var(--text-muted); display: flex; align-items: center; gap: 8px;">
          <span style="font-size: 12px; opacity: 0.7; width: 40px;">Set ${i+1}</span> ${weightInput} kg × ${repsInput}
        </div>
        <div class="log-val" style="font-size: 13px; color: var(--text-muted); margin-right: 15px;">${val}</div>
        ${allowActions ? `
        <div class="log-actions" style="display: flex; gap: 8px;">
          <button class="log-del" onclick="deleteLog(${l.id})" title="Delete Set">×</button>
        </div>
        ` : ''}
      </div>
    `;
  }).join('');
  
  const groupVolId = `group-vol-${first.id}`;
  
  return `
    <div class="log-item-group" style="background: var(--card-bg); border: 1px solid var(--border); border-radius: 12px; margin-bottom: 12px;">
      <div class="log-item" style="border-bottom: none; border-radius: 12px; margin-bottom: 0;">
        <div class="log-dot ${first.type}"></div>
        <div class="log-main">
          <div class="log-name">${safeName}</div>
          <div class="log-detail">${logs.length} sets · ${time}</div>
        </div>
        <div class="log-val" id="${groupVolId}">${Math.round(totalVol)} kg</div>
        ${allowActions ? `
        <div class="log-actions" style="display: flex; gap: 8px;">
          <button class="log-edit" onclick="startEditGroup('${escapeHTML(first.name).replace(/'/g, "\\'")}')" title="Edit Group Name">✎</button>
          <button class="log-del" onclick="deleteGroup('${escapeHTML(first.name).replace(/'/g, "\\'")}')" title="Delete Group">×</button>
        </div>
        ` : ''}
      </div>
      <div class="log-group-sets" style="padding: 0 15px 10px 15px;">
        ${setsHTML}
      </div>
    </div>
  `;
}

function logItemHTML(l, allowActions=true) {
  if (editingLogId === l.id) {
    return editLogHTML(l, false);
  }

  const detail = l.type === 'EXERCISE'
    ? `${l.sets || 1}×${l.reps || '?'} @ ${l.weight || '?'}kg`
    : `~${l.calories || 0} kcal`;
  const val = l.type === 'EXERCISE'
    ? `${Math.round(l.volume || 0)} kg`
    : `${l.calories || 0} cal`;
  const time = parseDate(l.created_at)
    .toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  const safeName = escapeHTML(l.name);
  return `<div class="log-item" id="log-item-${l.id}">
    <div class="log-dot ${l.type}"></div>
    <div class="log-main">
      <div class="log-name">${safeName}</div>
      <div class="log-detail">${detail} · ${time}</div>
    </div>
    <div class="log-val">${val}</div>
    ${allowActions ? `
    <div class="log-actions">
      <button class="log-edit" onclick="startEditLog(${l.id})" title="Edit">✎</button>
      <button class="log-del" onclick="deleteLog(${l.id})" title="Delete">×</button>
    </div>
    ` : ''}
  </div>`;
}

function startEditLog(id) {
  editingLogId = id;
  renderTodayLog();
}

function cancelEditLog() {
  editingLogId = null;
  renderTodayLog();
}

function editLogHTML(l, isGrouped=false) {
  const isEx = l.type === 'EXERCISE';
  const marginStyle = isGrouped ? 'margin: 5px 0; padding: 10px; background: rgba(0,0,0,0.2); border-radius: 8px; border: 1px solid var(--border);' : '';
  return `<div class="log-item edit-mode" id="log-item-${l.id}" style="${marginStyle}">
    <div class="edit-fields">
      ${!isGrouped ? `<input type="text" id="edit-name-${l.id}" value="${escapeHTML(l.name)}" class="edit-input" placeholder="Name" />` : `<input type="hidden" id="edit-name-${l.id}" value="${escapeHTML(l.name)}" />`}
      ${isEx ? `
        <div class="edit-row">
          <input type="number" id="edit-sets-${l.id}" value="${l.sets || ''}" class="edit-input num" placeholder="Sets" />×
          <input type="number" id="edit-reps-${l.id}" value="${l.reps || ''}" class="edit-input num" placeholder="Reps" />@
          <input type="number" step="0.5" id="edit-weight-${l.id}" value="${l.weight || ''}" class="edit-input num" placeholder="Weight" />kg
        </div>
      ` : `
        <div class="edit-row">
          <input type="number" id="edit-cals-${l.id}" value="${l.calories || ''}" class="edit-input num" placeholder="Calories" /> kcal
        </div>
      `}
      <div class="edit-actions">
        <button class="btn-save-edit" onclick="saveEditLog(${l.id}, '${l.type}')">Save</button>
        <button class="btn-cancel-edit" onclick="cancelEditLog()">Cancel</button>
      </div>
    </div>
  </div>`;
}

async function saveEditLog(id, type) {
  const name = document.getElementById(`edit-name-${id}`).value;
  const body = { name };
  if (type === 'EXERCISE') {
    body.sets = Number(document.getElementById(`edit-sets-${id}`).value) || null;
    body.reps = Number(document.getElementById(`edit-reps-${id}`).value) || null;
    body.weight = Number(document.getElementById(`edit-weight-${id}`).value) || null;
  } else {
    body.calories = Number(document.getElementById(`edit-cals-${id}`).value) || null;
  }
  
  try {
    const updated = await api('PUT', `/logs/${id}`, body);
    const idx = todayLogs.findIndex(l => l.id === id);
    if (idx !== -1) todayLogs[idx] = updated;
    
    editingLogId = null;
    renderTodayLog();
    
    heatmapLoaded = false;
    if (document.getElementById('page-library').classList.contains('active')) {
      loadLibraryPage();
    }
  } catch (e) {
    alert('Edit failed: ' + e.message);
    if (e.message.includes('401')) logout();
  }
}

function escapeHTML(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function parseDate(dateStr) {
  if (!dateStr) return new Date();
  // Handle both '2026-05-12T12:00:00' and '2026-05-12T12:00:00Z' formats
  const s = String(dateStr);
  if (s.endsWith('Z') || s.includes('+') || s.includes('-', 10)) return new Date(s);
  return new Date(s + 'Z');
}

async function deleteLog(id) {
  try {
    await api('DELETE', `/logs/${id}`);
    todayLogs = todayLogs.filter(l => l.id !== id);
    renderTodayLog();
    heatmapLoaded = false;
    if (document.getElementById('page-library').classList.contains('active')) {
      loadLibraryPage();
    }
  } catch (e) {
    alert('Delete failed: ' + e.message);
  }
}

function startEditGroup(name) {
  editingGroupName = name;
  renderTodayLog();
}

function cancelEditGroup() {
  editingGroupName = null;
  renderTodayLog();
}

async function saveEditGroup(name, firstId) {
  const newName = document.getElementById(`edit-group-name-${firstId}`).value;
  if (!newName) return;
  
  try {
    const sessionLogs = todayLogs.filter(l => l.name === name && l.type === 'EXERCISE');
    for (const log of sessionLogs) {
      const updated = await api('PUT', `/logs/${log.id}`, { name: newName });
      const idx = todayLogs.findIndex(l => l.id === log.id);
      if (idx !== -1) todayLogs[idx] = updated;
    }
    editingGroupName = null;
    renderTodayLog();
    heatmapLoaded = false;
    if (document.getElementById('page-library').classList.contains('active')) loadLibraryPage();
  } catch (e) {
    alert('Edit failed: ' + e.message);
  }
}

async function deleteGroup(name) {
  if (!confirm(`Delete all sets for ${name}?`)) return;
  try {
    const sessionLogs = todayLogs.filter(l => l.name === name && l.type === 'EXERCISE');
    for (const log of sessionLogs) {
      await api('DELETE', `/logs/${log.id}`);
      todayLogs = todayLogs.filter(l => l.id !== log.id);
    }
    renderTodayLog();
    heatmapLoaded = false;
    if (document.getElementById('page-library').classList.contains('active')) loadLibraryPage();
  } catch (e) {
    alert('Delete failed: ' + e.message);
  }
}

async function inlineUpdateLog(id, field, value) {
  const trimmed = String(value).trim();
  const numVal = trimmed === '' ? null : Number(trimmed);
  if (numVal !== null && (isNaN(numVal) || numVal < 0)) return;
  
  try {
    // Find log in local state
    let log = todayLogs.find(l => l.id === id);
    let sourceList = todayLogs;
    
    if (!log && heatmapData) {
      for (const date in heatmapData) {
         const found = heatmapData[date].details.find(l => l.id === id);
         if (found) { log = found; sourceList = heatmapData[date].details; break; }
      }
    }
    
    // Update local state immediately for snappy UI
    if (log) {
      log[field] = numVal;
      const s = Math.max(log.sets || 1, 1);
      const r = Math.max(log.reps || 0, 0);
      const w = Math.max(log.weight || 0, 0);
      log.volume = Math.round(s * r * w);
      
      // Update per-set volume in the DOM without re-render
      const row = document.getElementById(`log-item-${id}`);
      if (row) {
        const valEl = row.querySelector('.log-val');
        if (valEl) valEl.textContent = log.volume + ' kg';
      }
      
      // Update Total Volume summary if it's a today log
      if (sourceList === todayLogs) {
        const vol = todayLogs.filter(l => l.type === 'EXERCISE').reduce((s, l) => s + (l.volume || 0), 0);
        document.getElementById('total-volume').textContent = Math.round(vol);
      }
      
      // Update Group Volume header
      const groupLogs = sourceList.filter(l => l.name === log.name && l.type === 'EXERCISE');
      if (groupLogs.length > 0) {
        groupLogs.sort((a,b) => a.id - b.id);
        const groupVolEl = document.getElementById(`group-vol-${groupLogs[0].id}`);
        if (groupVolEl) {
          const gVol = groupLogs.reduce((s, l) => s + (l.volume || 0), 0);
          groupVolEl.textContent = Math.round(gVol) + ' kg';
        }
      }
    }
    
    // Send BOTH reps and weight to the server so volume calc uses current values
    // This prevents a race condition where rapid edits cause stale server-side calculations
    const body = {};
    if (log) {
      body.reps = log.reps;
      body.weight = log.weight;
    } else {
      body[field] = numVal;
    }
    
    const updated = await api('PUT', `/logs/${id}`, body);
    // Merge server response back into local state
    if (log && updated) {
      Object.assign(log, updated);
    }
  } catch (e) {
    console.error('Inline update failed:', e.message);
    // On failure, re-render to show the actual server state
    if (todayLogs.find(l => l.id === id)) {
      renderTodayLog();
    }
  }
}

async function logEntry() {
  const input = document.getElementById('magic-input');
  const text = input.value.trim();
  if (!text) return;

  const btn = document.getElementById('log-btn');
  btn.disabled = true;
  showStatus('loading', '<span class="spinner"></span>Parsing with AI…');

  try {
    // 1. Parse (returns a JSON list)
    const parsedArray = await api('POST', '/parse-entry', {
      text,
      prefill_exercise: prefillExercise || null,
    });

    if (parsedArray.error) throw new Error(parsedArray.error);

    const itemsToProcess = Array.isArray(parsedArray) ? parsedArray : [parsedArray];

    const savedItems = [];
    const sessionIds = {};
    
    // 2. Save each item via async loop
    for (const parsed of itemsToProcess) {
      if (parsed.type === 'EXERCISE' && !sessionIds[parsed.name]) {
         sessionIds[parsed.name] = Date.now().toString() + Math.random().toString(36).substring(2, 7);
      }

      const body = {
        type: parsed.type,
        session_id: parsed.type === 'EXERCISE' ? sessionIds[parsed.name] : null,
        name: parsed.name,
        sets: parsed.sets || null,
        reps: parsed.reps || null,
        weight: parsed.weight || null,
        calories: parsed.calories || null,
        volume: parsed.volume || null,
        raw_text: text,
      };

      const saved = await api('POST', '/logs', body);
      savedItems.push(saved);
    }

    for (let i = savedItems.length - 1; i >= 0; i--) {
      todayLogs.unshift(savedItems[i]);
    }

    renderTodayLog();
    heatmapLoaded = false;
    if (document.getElementById('page-library').classList.contains('active')) {
      loadLibraryPage();
    }
    input.value = '';
    clearPrefill();

    const itemNames = savedItems.map(item => item.name).join(', ');
    showStatus('success', `✓ Logged: ${itemNames}`);
    setTimeout(() => showStatus('', ''), 2500);
  } catch (e) {
    showStatus('error', '✗ ' + e.message);
    setTimeout(() => showStatus('', ''), 4000);
    if (e.message.includes('401')) logout();
  }

  btn.disabled = false;
}

function showStatus(type, html) {
  const el = document.getElementById('parse-status');
  el.className = 'parse-status' + (type ? ' ' + type : '');
  el.innerHTML = html;
}

function setPrefill(name) {
  prefillExercise = name;
  document.getElementById('prefill-name').textContent = name;
  document.getElementById('prefill-banner').style.display = 'flex';
  document.getElementById('magic-input').placeholder =
    "Just say the reps & weight, e.g. '4 sets of 8 at 60kg'";
  showPage('track');
  setTimeout(() => document.getElementById('magic-input').focus(), 100);
}

function clearPrefill() {
  prefillExercise = null;
  document.getElementById('prefill-banner').style.display = 'none';
  document.getElementById('magic-input').placeholder =
    "e.g. '3 sets of 12 reps bench press at 80kg' or 'had a chicken salad'";
}

function toggleMic() {
  const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!SR) { alert('Voice input requires Chrome or Edge.'); return; }

  if (listening) { recognition.stop(); return; }

  recognition = new SR();
  recognition.lang = 'en-US';
  recognition.interimResults = false;
  recognition.onresult = (e) => {
    document.getElementById('magic-input').value = e.results[0][0].transcript;
  };
  recognition.onend = () => {
    listening = false;
    document.getElementById('mic-btn').classList.remove('listening');
  };
  recognition.onerror = () => {
    listening = false;
    document.getElementById('mic-btn').classList.remove('listening');
  };
  recognition.start();
  listening = true;
  document.getElementById('mic-btn').classList.add('listening');
}

document.addEventListener('keydown', e => {
  if (e.key === 'Enter' && e.ctrlKey) logEntry();
});

// ══════════════════════════════════════════════════════════════
//  LIBRARY PAGE
// ══════════════════════════════════════════════════════════════
async function loadLibraryPage() {
  renderMuscleChips();
  filterExercises();

  if (heatmapLoaded) { renderHeatmapView(); return; }

  document.getElementById('heatmap-container').innerHTML =
    '<div class="empty-state"><span class="spinner"></span>Loading heatmap…</div>';
  try {
    heatmapData = await api('GET', '/logs/heatmap');
    heatmapLoaded = true;
    renderHeatmapView();
  } catch (e) {
    document.getElementById('heatmap-container').innerHTML =
      `<div class="empty-state" style="color:var(--red)">Failed to load: ${escapeHTML(e.message)}</div>`;
  }
}

function renderMuscleChips() {
  const groups = ['All', ...new Set(EXERCISES.map(e => e.muscle))];
  document.getElementById('muscle-chips').innerHTML = groups.map(g =>
    `<button class="muscle-chip ${g === selectedMuscle ? 'active' : ''}" onclick="selectMuscle('${g}')">${g}</button>`
  ).join('');
}

function selectMuscle(m) { selectedMuscle = m; renderMuscleChips(); filterExercises(); }

function filterExercises() {
  const q = (document.getElementById('exercise-search')?.value || '').toLowerCase();
  const filtered = EXERCISES.filter(e =>
    (selectedMuscle === 'All' || e.muscle === selectedMuscle) &&
    (e.name.toLowerCase().includes(q) || e.muscle.toLowerCase().includes(q))
  );
  document.getElementById('exercise-list').innerHTML = filtered.map(e => {
    const d = JSON.stringify(e).replace(/"/g, '&quot;');
    return `<div class="ex-card ${selectedExercise?.name === e.name ? 'selected' : ''}" onclick='selectExercise(${d})'>
      <div><div class="ex-name">${e.name}</div><div class="ex-meta">${e.muscle} · ${e.type}</div></div>
      <i class="ti ti-chevron-right ex-arrow"></i>
    </div>`;
  }).join('') || '<div class="empty-state" style="padding:20px">No exercises found</div>';
}

function selectExercise(e) {
  selectedExercise = e;
  sets = [{ reps: '', weight: '' }];
  renderQuickLog();
  filterExercises();
  document.getElementById('quick-log-container').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function renderQuickLog() {
  if (!selectedExercise) {
    document.getElementById('quick-log-container').innerHTML = '';
    return;
  }
  const setsHTML = sets.map((s, i) => `
    <tr>
      <td class="set-num">Set ${i + 1}</td>
      <td style="text-align:center">
        <input class="set-input" type="number" min="1" placeholder="12" value="${escapeHTML(String(s.reps))}"
          oninput="sets[${i}].reps = this.value" />
      </td>
      <td style="text-align:center">
        <input class="set-input" type="number" min="0" step="0.5" placeholder="50" value="${escapeHTML(String(s.weight))}"
          oninput="sets[${i}].weight = this.value" />
      </td>
    </tr>`).join('');

  const exName = escapeHTML(selectedExercise.name);
  document.getElementById('quick-log-container').innerHTML = `
    <div class="quick-log">
      <div class="ql-title">Quick Log · ${exName}
        <button class="ql-close" onclick="closeQuickLog()">×</button>
      </div>
      <button class="btn-voice-log" onclick="setPrefill('${exName}')">
        <i class="ti ti-microphone" style="font-size:12px;vertical-align:-1px;margin-right:4px"></i>Log via voice on Track page
      </button>
      <table class="sets-table">
        <thead><tr><th></th><th>Reps</th><th>Weight (kg)</th></tr></thead>
        <tbody>${setsHTML}</tbody>
      </table>
      <div class="ql-actions">
        <button class="btn-add-set" onclick="addSet()">+ Add set</button>
        <button class="btn-save-ex" onclick="saveQuickLog()">Save workout</button>
      </div>
    </div>`;
}

function addSet() { sets.push({ reps: '', weight: '' }); renderQuickLog(); }
function closeQuickLog() { selectedExercise = null; document.getElementById('quick-log-container').innerHTML = ''; filterExercises(); }

async function saveQuickLog() {
  const valid = sets.filter(s => s.reps || s.weight);
  if (!valid.length) { alert('Add at least one set.'); return; }

  const sessionId = Date.now().toString() + Math.random().toString(36).substring(2, 7);

  try {
    const savedItems = [];
    for (const s of valid) {
      const vol = Math.round((Number(s.reps || 0) * Number(s.weight || 0)) * 100) / 100;
      const body = {
        type: 'EXERCISE',
        session_id: sessionId,
        name: selectedExercise.name,
        sets: 1,
        reps: Number(s.reps || 0),
        weight: Number(s.weight || 0),
        volume: vol,
        raw_text: `Quick log: 1 set`,
      };
      const saved = await api('POST', '/logs', body);
      savedItems.push(saved);
    }
    
    for (let i = savedItems.length - 1; i >= 0; i--) {
      todayLogs.unshift(savedItems[i]);
    }
    heatmapLoaded = false;
    if (document.getElementById('page-library').classList.contains('active')) {
      loadLibraryPage();
    }
    renderTodayLog();
    closeQuickLog();
  } catch (e) {
    alert('Save failed: ' + e.message);
    if (e.message.includes('401')) logout();
  }
}

function renderHeatmapView() {
  const c = document.getElementById('heatmap-container');
  if (!c || !heatmapLoaded) return;

  const today = new Date();
  let html = '';
  
  for (let i = 89; i >= 0; i--) {
    const d = new Date(today);
    d.setDate(d.getDate() - i);
    const dateStr = d.toISOString().slice(0, 10);
    
    const dayData = heatmapData[dateStr] || { count: 0, details: [] };
    const count = dayData.count;
    
    let intensity = 0;
    if (count > 0 && count <= 2) intensity = 1;
    else if (count > 2 && count <= 4) intensity = 2;
    else if (count >= 5) intensity = 3;
    
    html += `<div class="heatmap-square intensity-${intensity}" 
                  title="${dateStr}: ${count} activities" 
                  onclick="showDayDetails('${dateStr}')">
             </div>`;
  }
  
  c.innerHTML = html;
}

function showDayDetails(dateStr) {
  const container = document.getElementById('day-details-container');
  const list = document.getElementById('day-details-list');
  const dateEl = document.getElementById('day-details-date');
  
  const dayData = heatmapData[dateStr] || { count: 0, details: [] };
  const details = dayData.details;
  
  const d = new Date(dateStr + 'T12:00:00');
  dateEl.textContent = d.toLocaleDateString('en', { weekday: 'long', month: 'short', day: 'numeric' });
  
  if (details.length === 0) {
    list.innerHTML = '<div class="empty-state">No activities logged on this day.</div>';
  } else {
    list.innerHTML = getGroupedLogsHTML(details, true);
  }
  
  container.style.display = 'block';
  container.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function closeDayDetails() {
  document.getElementById('day-details-container').style.display = 'none';
}

// ══════════════════════════════════════════════════════════════
//  STATS PAGE
// ══════════════════════════════════════════════════════════════
async function loadStats() {
  try {
    const data = await api('GET', '/stats?days=7');

    const labels = data.days.map(d => new Date(d.date + 'T12:00:00').toLocaleDateString('en', { weekday: 'short' }));
    const volumes = data.days.map(d => d.volume);
    const calories = data.days.map(d => d.calories);
    const hasVol = volumes.some(v => v > 0);
    const hasCal = calories.some(c => c > 0);

    document.getElementById('s-avg-vol').textContent = data.avg_volume + 'kg';
    document.getElementById('s-avg-cal').textContent = data.avg_calories + ' kcal';
    document.getElementById('s-workouts').textContent = data.total_workouts;
    document.getElementById('s-meals').textContent = data.total_meals;
    document.getElementById('avg-volume').innerHTML = `${data.avg_volume} <span class="unit">kg avg</span>`;
    document.getElementById('avg-cals').innerHTML = `${data.avg_calories} <span class="unit">kcal avg</span>`;

    document.getElementById('volume-empty').style.display = hasVol ? 'none' : 'block';
    document.getElementById('cals-empty').style.display = hasCal ? 'none' : 'block';
    document.getElementById('volume-chart').style.display = hasVol ? 'block' : 'none';
    document.getElementById('cals-chart').style.display = hasCal ? 'block' : 'none';

    const base = {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: { display: false } },
      scales: {
        x: { grid: { color: 'rgba(255,255,255,0.05)' }, ticks: { color: '#888', font: { family: 'DM Mono', size: 11 } } },
        y: { grid: { color: 'rgba(255,255,255,0.05)' }, ticks: { color: '#888', font: { family: 'DM Mono', size: 11 } }, beginAtZero: true },
      },
    };

    if (volumeChart) { volumeChart.destroy(); volumeChart = null; }
    if (calsChart) { calsChart.destroy(); calsChart = null; }

    if (hasVol) {
      volumeChart = new Chart(document.getElementById('volume-chart'), {
        type: 'bar',
        data: {
          labels, datasets: [{
            data: volumes,
            backgroundColor: 'rgba(106,180,255,0.4)',
            borderColor: '#6ab4ff',
            borderWidth: 1.5,
            borderRadius: 6,
          }]
        },
        options: base,
      });
    }
    if (hasCal) {
      calsChart = new Chart(document.getElementById('cals-chart'), {
        type: 'line',
        data: {
          labels, datasets: [{
            data: calories,
            borderColor: '#c8f56a',
            borderWidth: 2,
            pointBackgroundColor: '#c8f56a',
            pointRadius: 4,
            tension: 0.4,
            fill: true,
            backgroundColor: 'rgba(200,245,106,0.06)',
          }]
        },
        options: base,
      });
    }
  } catch (e) {
    if (e.message.includes('401')) logout();
  }
}

// ══════════════════════════════════════════════════════════════
//  COACH CHAT PAGE
// ══════════════════════════════════════════════════════════════
async function sendCoachMessage() {
  const input = document.getElementById('coach-input');
  const question = input.value.trim();
  if (!question) return;

  const sendBtn = document.getElementById('coach-send-btn');
  sendBtn.disabled = true;
  input.value = '';

  // Append user bubble
  appendCoachBubble('user', question);

  // Save to history
  coachHistory.push({ role: 'user', text: question });

  // Show typing indicator
  const typingId = appendTypingIndicator();

  try {
    const data = await api('POST', '/coach-chat', {
      message: question,
      history: coachHistory.slice(0, -1), // send history before this message
    });

    removeTypingIndicator(typingId);

    const answer = data.answer || '';
    const plan = data.workout_plan || [];

    // Save coach answer to history
    coachHistory.push({ role: 'coach', text: answer });

    // Render coach answer
    appendCoachBubble('bot', answer, plan);
  } catch (e) {
    removeTypingIndicator(typingId);
    const msg = e.message.includes('429')
      ? e.message
      : 'Something went wrong. Try again in a moment.';
    appendCoachBubble('bot', msg);
    if (e.message.includes('401')) logout();
  }

  sendBtn.disabled = false;
  input.focus();
}

function appendCoachBubble(role, text, workoutPlan = []) {
  const window = document.getElementById('coach-chat-window');
  const isBot = role === 'bot';

  let planHTML = '';
  if (workoutPlan.length > 0) {
    const rows = workoutPlan.map(ex => `
      <div class="coach-plan-row">
        <div class="coach-plan-name">${escapeHTML(ex.exercise)}</div>
        <div class="coach-plan-detail">
          ${ex.sets} × ${ex.reps}${ex.weight ? ` @ ${ex.weight}kg` : ''}
          ${ex.notes ? `<span class="coach-plan-note"> · ${escapeHTML(ex.notes)}</span>` : ''}
        </div>
      </div>`).join('');
    planHTML = `<div class="coach-plan">${rows}</div>`;
  }

  const el = document.createElement('div');
  el.className = `coach-bubble coach-bubble--${isBot ? 'bot' : 'user'}`;
  el.innerHTML = isBot
    ? `<div class="coach-bubble-avatar">AI</div><div class="coach-bubble-body">${escapeHTML(text)}${planHTML}</div>`
    : `<div class="coach-bubble-body">${escapeHTML(text)}</div>`;

  window.appendChild(el);
  window.scrollTop = window.scrollHeight;
}

function appendTypingIndicator() {
  const window = document.getElementById('coach-chat-window');
  const id = 'typing-' + Date.now();
  const el = document.createElement('div');
  el.id = id;
  el.className = 'coach-bubble coach-bubble--bot coach-typing';
  el.innerHTML = '<div class="coach-bubble-avatar">AI</div><div class="coach-bubble-body"><span class="typing-dot"></span><span class="typing-dot"></span><span class="typing-dot"></span></div>';
  window.appendChild(el);
  window.scrollTop = window.scrollHeight;
  return id;
}

function removeTypingIndicator(id) {
  const el = document.getElementById(id);
  if (el) el.remove();
}

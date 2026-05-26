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
let allLogs = [];
let allLogsLoaded = false;

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
  allLogs = [];
  allLogsLoaded = false;
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
  ['track', 'library', 'stats'].forEach((p, i) => {
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
  container.innerHTML = todayLogs.map(l => logItemHTML(l)).join('');
}

function logItemHTML(l) {
  const detail = l.type === 'EXERCISE'
    ? `${l.sets || 1}×${l.reps || '?'} @ ${l.weight || '?'}kg`
    : `~${l.calories || 0} kcal`;
  const val = l.type === 'EXERCISE'
    ? `${Math.round(l.volume || 0)} kg`
    : `${l.calories || 0} cal`;
  const time = new Date(l.created_at + 'Z')
    .toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  const safeName = escapeHTML(l.name);
  return `<div class="log-item">
    <div class="log-dot ${l.type}"></div>
    <div class="log-main">
      <div class="log-name">${safeName}</div>
      <div class="log-detail">${detail} · ${time}</div>
    </div>
    <div class="log-val">${val}</div>
    <button class="log-del" onclick="deleteLog(${l.id})" title="Delete">×</button>
  </div>`;
}

function escapeHTML(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

async function deleteLog(id) {
  try {
    await api('DELETE', `/logs/${id}`);
    todayLogs = todayLogs.filter(l => l.id !== id);
    allLogs = allLogs.filter(l => l.id !== id);
    renderTodayLog();
    const fullLogEl = document.getElementById('full-log');
    if (fullLogEl) renderFullHistory();
  } catch (e) {
    alert('Delete failed: ' + e.message);
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
    // 2. Save each item via async loop
    for (const parsed of itemsToProcess) {
      const body = {
        type: parsed.type,
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
      if (allLogsLoaded) allLogs.unshift(savedItems[i]);
    }

    renderTodayLog();
    if (document.getElementById('full-log')) {
      renderFullHistory();
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

  if (allLogsLoaded) { renderFullHistory(); return; }

  document.getElementById('full-log').innerHTML =
    '<div class="empty-state"><span class="spinner"></span>Loading history…</div>';
  try {
    allLogs = await api('GET', '/logs');
    allLogsLoaded = true;
    renderFullHistory();
  } catch (e) {
    document.getElementById('full-log').innerHTML =
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

  const totalReps = valid.reduce((s, v) => s + Number(v.reps || 0), 0);
  const avgWeight = valid.reduce((s, v) => s + Number(v.weight || 0), 0) / valid.length;
  const volume = Math.round(valid.reduce((s, v) => s + (Number(v.reps || 0) * Number(v.weight || 0)), 0));

  const body = {
    type: 'EXERCISE',
    name: selectedExercise.name,
    sets: valid.length,
    reps: Math.round(totalReps / valid.length),
    weight: Math.round(avgWeight * 10) / 10,
    volume,
    raw_text: `Quick log: ${valid.length} sets`,
  };

  try {
    const saved = await api('POST', '/logs', body);
    if (allLogsLoaded) allLogs.unshift(saved);
    todayLogs.unshift(saved);
    renderFullHistory();
    renderTodayLog();
    closeQuickLog();
  } catch (e) {
    alert('Save failed: ' + e.message);
    if (e.message.includes('401')) logout();
  }
}

function renderFullHistory() {
  const c = document.getElementById('full-log');
  if (!c) return;
  if (!allLogsLoaded) return;
  if (!allLogs.length) {
    c.innerHTML = '<div class="empty-state">No entries yet</div>';
    return;
  }
  c.innerHTML = allLogs.map(l => logItemHTML(l)).join('');
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

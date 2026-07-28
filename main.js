/* Adobe Services Disabler - site behavior */
(function () {
  'use strict';

  var reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

  /* ---------- Theme toggle ---------- */

  var themeBtn = document.getElementById('themeToggleBtn');
  var moon = document.getElementById('themeIconMoon');
  var sun = document.getElementById('themeIconSun');
  var themeMeta = document.querySelector('meta[name="theme-color"]');
  var lightScheme = window.matchMedia('(prefers-color-scheme: light)');

  function store(key, value) {
    try {
      localStorage.setItem(key, value);
    } catch (e) { /* private mode / cookies blocked - theme still applies */ }
  }

  function syncThemeButton() {
    var dark = document.documentElement.getAttribute('data-theme') !== 'light';
    moon.hidden = !dark;
    sun.hidden = dark;
    // No aria-pressed: the label already names the action ("Switch to light
    // theme"). Pairing an action label with a pressed state announces
    // "switch to light theme, not pressed", which reads as a contradiction.
    themeBtn.setAttribute('aria-label', dark ? 'Switch to light theme' : 'Switch to dark theme');
    // Keep the mobile browser chrome in step with the page.
    if (themeMeta) themeMeta.setAttribute('content', dark ? '#0f1317' : '#f3f4f6');
  }

  themeBtn.addEventListener('click', function () {
    var next = document.documentElement.getAttribute('data-theme') === 'light' ? 'dark' : 'light';
    document.documentElement.setAttribute('data-theme', next);
    store('theme', next);
    syncThemeButton();
  });
  syncThemeButton();

  // Follow the OS while the visitor has not expressed a preference of their own.
  function onSchemeChange(e) {
    var chosen = null;
    try {
      chosen = localStorage.getItem('theme');
    } catch (err) { /* ignore */ }
    if (chosen) return;
    document.documentElement.setAttribute('data-theme', e.matches ? 'light' : 'dark');
    syncThemeButton();
  }
  if (lightScheme.addEventListener) {
    lightScheme.addEventListener('change', onSchemeChange);
  } else if (lightScheme.addListener) {
    lightScheme.addListener(onSchemeChange);
  }

  /* ---------- OS detection + tabs ---------- */

  var tabs = {
    mac: document.getElementById('tab-mac'),
    win: document.getElementById('tab-win')
  };
  var panels = {
    mac: document.getElementById('panel-mac'),
    win: document.getElementById('panel-win')
  };
  var osName = document.getElementById('osName');
  var currentOS = 'mac';

  function detectOS() {
    var p = (navigator.userAgentData && navigator.userAgentData.platform) ||
      navigator.platform || navigator.userAgent || '';
    return /win/i.test(p) ? 'win' : 'mac';
  }

  function selectOS(os, focusTab) {
    currentOS = os;
    ['mac', 'win'].forEach(function (key) {
      var active = key === os;
      tabs[key].setAttribute('aria-selected', String(active));
      tabs[key].tabIndex = active ? 0 : -1;
      panels[key].hidden = !active;
    });
    if (focusTab) tabs[os].focus();
    renderMonitor(os);
    playWhenVisible();
  }

  Object.keys(tabs).forEach(function (key) {
    tabs[key].addEventListener('click', function () { selectOS(key, false); });
    tabs[key].addEventListener('keydown', function (e) {
      if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
        e.preventDefault();
        selectOS(key === 'mac' ? 'win' : 'mac', true);
      }
    });
  });

  /* ---------- Copy buttons ---------- */

  var copyStatus = document.getElementById('copyStatus');

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      var ok = document.execCommand('copy');
      document.body.removeChild(ta);
      ok ? resolve() : reject(new Error('copy failed'));
    });
  }

  document.querySelectorAll('.copy-btn').forEach(function (btn) {
    var label = btn.querySelector('.btn-text');
    var resetTimer = null;
    btn.addEventListener('click', function () {
      var cmd = document.getElementById(btn.getAttribute('data-copy-target')).textContent;
      copyText(cmd).then(function () {
        btn.classList.add('copied');
        label.textContent = 'Copied';
        copyStatus.textContent = 'Command copied to clipboard.';
        // A second click within the window restarts the timer, so the
        // "Copied" state does not get cut short by the first click's reset.
        clearTimeout(resetTimer);
        resetTimer = setTimeout(function () {
          btn.classList.remove('copied');
          label.textContent = 'Copy';
          copyStatus.textContent = '';
        }, 1800);
      }).catch(function () {
        copyStatus.textContent = 'Copy failed. Select the command text and copy it manually.';
      });
    });
  });

  /* ---------- Process monitor demo ---------- */

  var PROCESSES = {
    mac: [
      { name: 'Creative Cloud', mem: 214 },
      { name: 'Adobe Desktop Service', mem: 157 },
      { name: 'CoreSync', mem: 118 },
      { name: 'CCXProcess', mem: 96 },
      { name: 'CCLibrary', mem: 88 },
      { name: 'AdobeIPCBroker', mem: 41 },
      { name: 'ACCFinderSync', mem: 33 },
      { name: 'AdobeCRDaemon', mem: 24 }
    ],
    win: [
      { name: 'Creative Cloud.exe', mem: 203 },
      { name: 'Adobe Desktop Service.exe', mem: 149 },
      { name: 'CoreSync.exe', mem: 112 },
      { name: 'CCXProcess.exe', mem: 94 },
      { name: 'CCLibrary.exe', mem: 85 },
      { name: 'AdobeIPCBroker.exe', mem: 39 },
      { name: 'AGSService.exe', mem: 28 },
      { name: 'AdobeUpdateService.exe', mem: 19 }
    ]
  };

  var monitor = document.querySelector('.monitor');
  var monitorTitle = document.getElementById('monitorTitle');
  var monitorRows = document.getElementById('monitorRows');
  var monitorTally = document.getElementById('monitorTally');
  var replayBtn = document.getElementById('replayBtn');
  var killTimers = [];
  // On phones the monitor sits well below the fold, so firing the animation at
  // load meant it was always over before it was ever on screen.
  var monitorOnScreen = true;
  var monitorPlayed = false;

  function renderMonitor(os) {
    // Cancel any animation still in flight: its timers hold the old rows and
    // would write stale numbers into the fresh tally.
    killTimers.forEach(function (id) { clearTimeout(id); });
    killTimers = [];
    monitor.classList.toggle('os-win', os === 'win');
    monitorTitle.textContent = os === 'win' ? 'Task Manager · Adobe' : 'Activity Monitor · Adobe';
    monitorRows.innerHTML = '';
    PROCESSES[os].forEach(function (proc) {
      var li = document.createElement('li');
      li.className = 'mrow';

      var name = document.createElement('span');
      name.className = 'mname';
      name.textContent = proc.name;

      var mem = document.createElement('span');
      mem.className = 'mmem';
      mem.textContent = proc.mem + ' MB';

      var status = document.createElement('span');
      status.className = 'mstatus';
      status.textContent = 'running';

      li.append(name, mem, status);
      monitorRows.appendChild(li);
    });
    monitorPlayed = false;
    // Fill the tally now: the animation may not run until this scrolls into
    // view, and an empty strip under the rows looks like a rendering fault.
    setTally(0, 0, PROCESSES[os].length);
  }

  function setTally(stopped, freed, total) {
    if (stopped === 0) {
      monitorTally.textContent = total + ' background processes · 0 MB freed';
      monitorTally.classList.remove('done');
    } else {
      monitorTally.textContent = stopped + ' of ' + total + ' stopped · ' + freed + ' MB freed';
      monitorTally.classList.toggle('done', stopped === total);
    }
  }

  function killRow(row) {
    row.classList.add('killed');
    row.querySelector('.mstatus').textContent = 'stopped';
  }

  function playWhenVisible() {
    if (monitorOnScreen) playMonitor();
  }

  function playMonitor() {
    killTimers.forEach(function (id) { clearTimeout(id); });
    killTimers = [];
    monitorPlayed = true;

    var rows = Array.prototype.slice.call(monitorRows.children);
    var procs = PROCESSES[currentOS];
    var total = procs.length;
    var freed = 0;

    if (reducedMotion.matches) {
      rows.forEach(killRow);
      setTally(total, procs.reduce(function (sum, p) { return sum + p.mem; }, 0), total);
      return;
    }

    setTally(0, 0, total);
    rows.forEach(function (row, i) {
      killTimers.push(setTimeout(function () {
        killRow(row);
        freed += procs[i].mem;
        setTally(i + 1, freed, total);
      }, 900 + i * 320));
    });
  }

  replayBtn.addEventListener('click', function () {
    renderMonitor(currentOS);
    playMonitor();
  });

  if ('IntersectionObserver' in window) {
    monitorOnScreen = false;
    new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        // Not isIntersecting: that is true from the first visible pixel, so a
        // sliver of the monitor peeking above the fold would count as "on
        // screen" and the animation would play while effectively invisible.
        monitorOnScreen = entry.intersectionRatio >= 0.35;
        if (monitorOnScreen && !monitorPlayed) playMonitor();
      });
    }, { threshold: [0, 0.35] }).observe(monitor);
  }

  /* ---------- Scroll reveal ---------- */

  var cards = document.querySelectorAll('.card');
  if (!reducedMotion.matches && 'IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('revealed');
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12 });
    cards.forEach(function (card) {
      card.classList.add('reveal');
      io.observe(card);
    });
  }

  /* ---------- Boot ---------- */

  var detected = detectOS();
  osName.textContent = detected === 'win' ? 'Windows' : 'macOS';
  selectOS(detected, false);
})();

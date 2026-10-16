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
  var menus = {
    mac: document.getElementById('menu-mac'),
    win: document.getElementById('menu-win')
  };
  var osNote = document.getElementById('osNote');
  var currentOS = 'mac';
  var cmdMode = 'run';

  // 'mac', 'win', 'phone' or 'other'. Only the first two can run the scripts;
  // the rest still get the Mac tab, but must not be told it was "detected".
  function detectPlatform() {
    var p = (navigator.userAgentData && navigator.userAgentData.platform) ||
      navigator.platform || '';
    var ua = navigator.userAgent || '';
    // iPadOS reports itself as a Mac; only the touch points give it away.
    if (/android|iphone|ipad|ipod/i.test(p + ' ' + ua) ||
        (/mac/i.test(p) && navigator.maxTouchPoints > 1)) return 'phone';
    if (/win/i.test(p) || /windows nt/i.test(ua)) return 'win';
    if (/mac/i.test(p) || /macintosh/i.test(ua)) return 'mac';
    return 'other';
  }

  function describePlatform(platform) {
    var strong = document.createElement('strong');
    osNote.textContent = '';
    if (platform === 'mac' || platform === 'win') {
      strong.textContent = platform === 'win' ? 'Windows' : 'macOS';
      osNote.append('Detected ', strong, ". Use the tabs if that's not this machine.");
    } else if (platform === 'phone') {
      strong.textContent = 'On a phone?';
      osNote.append(strong, ' This runs on a Mac or a Windows PC. Pick yours with the tabs.');
    } else {
      strong.textContent = 'macOS and Windows only.';
      osNote.append(strong, ' Pick the machine you will run it on with the tabs.');
    }
  }

  var platform = detectPlatform();

  function osFromHash() {
    var h = (location.hash || '').replace(/^#/, '').toLowerCase();
    if (h === 'win' || h === 'windows') return 'win';
    if (h === 'mac' || h === 'macos' || h === 'osx') return 'mac';
    return null;
  }

  function setHash(os) {
    var id = os === 'win' ? 'windows' : 'macos';
    if ((location.hash || '').replace(/^#/, '') === id) return;
    if (history.replaceState) {
      history.replaceState(null, '', location.pathname + location.search + '#' + id);
    } else {
      location.hash = id;
    }
  }

  function selectOS(os, opts) {
    opts = opts || {};
    currentOS = os;
    ['mac', 'win'].forEach(function (key) {
      var active = key === os;
      tabs[key].setAttribute('aria-selected', String(active));
      tabs[key].tabIndex = active ? 0 : -1;
      panels[key].hidden = !active;
      menus[key].hidden = !active;
    });
    applyCmdMode();
    if (opts.focusTab) tabs[os].focus();
    if (opts.writeHash) setHash(os);
    renderMonitor(os);
    playWhenVisible();
  }

  Object.keys(tabs).forEach(function (key) {
    tabs[key].addEventListener('click', function () {
      // Re-selecting the current tab would reset the demo mid-play.
      if (key === currentOS) return;
      selectOS(key, { writeHash: true });
    });
    tabs[key].addEventListener('keydown', function (e) {
      var next = null;
      if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') next = key === 'mac' ? 'win' : 'mac';
      else if (e.key === 'Home') next = 'mac';
      else if (e.key === 'End') next = 'win';
      if (!next) return;
      e.preventDefault();
      if (next === currentOS) tabs[next].focus();
      else selectOS(next, { writeHash: true, focusTab: true });
    });
  });

  window.addEventListener('hashchange', function () {
    var os = osFromHash();
    if (os && os !== currentOS) selectOS(os, {});
  });

  /* ---------- Run / inspect ---------- */

  var modeBtns = Array.prototype.slice.call(document.querySelectorAll('.cmd-opt'));

  function applyCmdMode() {
    var panel = panels[currentOS];
    var body = panel.querySelector('.terminal-body');
    var run = body.getAttribute('data-run');
    var inspect = body.getAttribute('data-inspect');
    body.textContent = cmdMode === 'inspect' ? inspect : run;
    body.classList.toggle('prompt-mac', currentOS === 'mac' && cmdMode === 'run');
    body.classList.toggle('prompt-win', currentOS === 'win' && cmdMode === 'run');
    panel.querySelector('.hint-run').hidden = cmdMode !== 'run';
    panel.querySelector('.hint-inspect').hidden = cmdMode !== 'inspect';
  }

  function setCmdMode(mode, focusBtn) {
    cmdMode = mode;
    modeBtns.forEach(function (btn) {
      var on = btn.getAttribute('data-mode') === mode;
      btn.setAttribute('aria-checked', String(on));
      btn.tabIndex = on ? 0 : -1;
    });
    applyCmdMode();
    if (focusBtn) {
      modeBtns.filter(function (b) {
        return b.getAttribute('data-mode') === mode;
      })[0].focus();
    }
  }

  modeBtns.forEach(function (btn) {
    btn.tabIndex = btn.getAttribute('data-mode') === 'run' ? 0 : -1;
    btn.addEventListener('click', function () {
      setCmdMode(btn.getAttribute('data-mode'), false);
    });
    btn.addEventListener('keydown', function (e) {
      // Radio groups answer to all four arrows, unlike tabs.
      if (/^Arrow(Left|Right|Up|Down)$/.test(e.key)) {
        e.preventDefault();
        setCmdMode(cmdMode === 'run' ? 'inspect' : 'run', true);
      }
    });
  });

  /* ---------- Copy buttons ---------- */

  var copyStatus = document.getElementById('copyStatus');

  function copyViaTextarea(text) {
    return new Promise(function (resolve, reject) {
      // Selecting the textarea steals focus; hand it back afterwards so a
      // keyboard user is not dropped at the top of the page.
      var prev = document.activeElement;
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.top = '0';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      var ok = false;
      try {
        ok = document.execCommand('copy');
      } catch (e) { /* treated as a failure below */ }
      document.body.removeChild(ta);
      if (prev && prev.focus) prev.focus();
      ok ? resolve() : reject(new Error('copy failed'));
    });
  }

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      // The async API can still refuse (permissions policy in an embed, a
      // document that lost focus); the old path often works when it does.
      return navigator.clipboard.writeText(text).catch(function () {
        return copyViaTextarea(text);
      });
    }
    return copyViaTextarea(text);
  }

  document.querySelectorAll('.copy-btn').forEach(function (btn) {
    var label = btn.querySelector('.btn-text');
    var resetTimer = null;
    function resetLater(ms) {
      // A second click within the window restarts the timer, so the
      // "Copied" state does not get cut short by the first click's reset.
      clearTimeout(resetTimer);
      resetTimer = setTimeout(function () {
        btn.classList.remove('copied');
        label.textContent = 'Copy';
        copyStatus.textContent = '';
      }, ms);
    }

    btn.addEventListener('click', function () {
      var target = document.getElementById(btn.getAttribute('data-copy-target'));
      copyText(target.textContent).then(function () {
        btn.classList.add('copied');
        label.textContent = 'Copied';
        copyStatus.textContent = cmdMode === 'inspect' ? 'Commands copied to clipboard.' : 'Command copied to clipboard.';
        resetLater(1800);
      }).catch(function () {
        // Leave the command selected so one keystroke finishes the job, and
        // say which keystroke on the button itself, not only to screen readers.
        var range = document.createRange();
        range.selectNodeContents(target);
        var sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
        btn.classList.remove('copied');
        if (platform === 'phone') {
          label.textContent = 'Selected';
          copyStatus.textContent = 'Could not copy automatically. The command is selected; copy it from the selection menu.';
        } else {
          var keys = platform === 'mac' ? '⌘C' : 'Ctrl+C';
          label.textContent = 'Press ' + keys;
          copyStatus.textContent = 'Could not copy automatically. The command is selected; press ' + keys + ' to copy it.';
        }
        resetLater(4000);
      });
    });
  });

  document.querySelectorAll('.terminal-body').forEach(function (el) {
    var downX = 0;
    var downY = 0;
    el.addEventListener('mousedown', function (e) {
      downX = e.clientX;
      downY = e.clientY;
    });
    el.addEventListener('click', function (e) {
      if (Math.abs(e.clientX - downX) > 5 || Math.abs(e.clientY - downY) > 5) return;
      var btn = el.closest('.terminal').querySelector('.copy-btn');
      if (btn) btn.click();
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
  var tallyFill = document.getElementById('tallyFill');
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
    var procs = PROCESSES[os];
    var maxMem = 1;
    procs.forEach(function (proc) {
      if (proc.mem > maxMem) maxMem = proc.mem;
    });
    procs.forEach(function (proc) {
      var li = document.createElement('li');
      li.className = 'mrow';

      var name = document.createElement('span');
      name.className = 'mname';
      name.textContent = proc.name;

      var mem = document.createElement('span');
      mem.className = 'mmem';

      var bar = document.createElement('span');
      bar.className = 'mbar';
      bar.setAttribute('aria-hidden', 'true');
      var fill = document.createElement('i');
      fill.style.width = ((proc.mem / maxMem) * 100) + '%';
      bar.appendChild(fill);

      var amount = document.createElement('span');
      amount.className = 'mamt';
      amount.textContent = proc.mem + ' MB';

      mem.append(bar, amount);

      var status = document.createElement('span');
      status.className = 'mstatus';
      status.textContent = 'running';

      li.append(name, mem, status);
      monitorRows.appendChild(li);
    });
    monitorPlayed = false;
    // Fill the tally now: the animation may not run until this scrolls into
    // view, and an empty strip under the rows looks like a rendering fault.
    setTally(0, 0, procs.length);
  }

  function setTally(stopped, freed, total) {
    tallyFill.style.width = total ? ((stopped / total) * 100) + '%' : '0%';
    if (stopped === 0) {
      monitorTally.textContent = total + ' background processes · 0 MB freed';
      monitorTally.parentElement.classList.remove('done');
    } else {
      monitorTally.textContent = stopped + ' of ' + total + ' stopped · ' + freed + ' MB freed';
      monitorTally.parentElement.classList.toggle('done', stopped === total);
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
    // A margin, not a ratio threshold: at high zoom a card can be so tall that
    // the required share of it never fits on screen, and it would stay
    // invisible for good.
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('revealed');
          io.unobserve(entry.target);
        }
      });
    }, { rootMargin: '0px 0px -8% 0px' });
    cards.forEach(function (card) {
      card.classList.add('reveal');
      io.observe(card);
    });
  }

  /* ---------- Boot ---------- */

  describePlatform(platform);
  selectOS(osFromHash() || (platform === 'win' ? 'win' : 'mac'), {});
})();

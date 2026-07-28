// Runs synchronously in <head> so the correct theme paints on first frame.
(function () {
  var stored = null;
  // Safari with cookies blocked throws on the *access*, not just on write.
  // Left unguarded, this whole script dies and the page paints unthemed.
  try {
    stored = localStorage.getItem('theme');
  } catch (e) { /* no persisted preference available */ }

  var t = stored ||
    (window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark');

  document.documentElement.setAttribute('data-theme', t);

  // Set on the first frame too, so the mobile browser chrome never flashes the
  // wrong colour before main.js takes over.
  var meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute('content', t === 'light' ? '#f3f4f6' : '#0f1317');
})();

// The hero is three screens. One shows at a time; Continue, the keys 1 to 3 and the arrows move
// between them, and the address bar remembers which. Without this script all three stack.
(() => {
  const hero = document.getElementById('hero');
  if (!hero) return;
  const screens = [...hero.querySelectorAll('.screen')];
  const marks = [...document.querySelectorAll('.site-header canvas[data-mark]')];
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  let current = 0;
  function show(n, focus, scroll) {
    n = Math.max(0, Math.min(screens.length - 1, n));
    current = n;
    hero.dataset.screen = String(n + 1);
    screens.forEach((s, i) => { s.hidden = i !== n; });
    marks.forEach((m, i) => { m.hidden = i !== n; });
    const canvas = screens[n].querySelector('canvas[data-dither]');
    if (canvas) canvas.dispatchEvent(new Event('shift:resume'));
    if (window.shiftMarks && !reduce) { const m = marks[n]; window.shiftMarks.run(m, true); setTimeout(() => window.shiftMarks.run(m, m.matches(':hover')), 1400); }
    try { history.replaceState(null, '', n ? '#screen-' + (n + 1) : location.pathname + location.search); } catch (e) { /* the address bar is optional */ }
    if (focus) screens[n].querySelector('h1, h2').focus({ preventScroll: true });
    if (scroll) scrollTo({ top: 0, behavior: 'instant' });
  }
  hero.addEventListener('click', e => {
    const a = e.target.closest('a[href^="#screen-"]');
    if (!a) return;
    e.preventDefault();
    show(parseInt(a.hash.slice(8), 10) - 1, true, true);
  });
  addEventListener('keydown', e => {
    if (e.target.closest('input, textarea, select') || e.metaKey || e.ctrlKey || e.altKey) return;
    if (!hero.contains(document.activeElement) && document.activeElement !== document.body) return;
    if (e.key === 'ArrowRight') { show(current + 1, true, true); e.preventDefault(); }
    else if (e.key === 'ArrowLeft') { show(current - 1, true, true); e.preventDefault(); }
    else if (e.key >= '1' && e.key <= String(screens.length)) show(parseInt(e.key, 10) - 1, true, true);
  });
  addEventListener('hashchange', () => { const m = location.hash.match(/^#screen-(\d)$/); if (m) show(parseInt(m[1], 10) - 1, true, true); });
  const m = location.hash.match(/^#screen-(\d)$/);
  hero.dataset.js = '1';
  show(m ? parseInt(m[1], 10) - 1 : 0, false);
})();

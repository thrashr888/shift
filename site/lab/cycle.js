// Palette cycling on a canvas: the index map is drawn once and never changes; each tick
// applies the next frame's color table. The page decides when it runs.
(() => {
  const marks = new Map();
  async function load(el) {
    const meta = await (await fetch(el.dataset.mark)).json();
    const img = new Image(); img.src = new URL(meta.index, new URL(el.dataset.mark, location.href)).href; await img.decode();
    const probe = document.createElement('canvas'); probe.width = meta.width; probe.height = meta.height;
    const pc = probe.getContext('2d', { willReadFrequently: true }); pc.drawImage(img, 0, 0);
    const index = pc.getImageData(0, 0, meta.width, meta.height).data;   // red channel = palette entry
    el.width = meta.width; el.height = meta.height;
    const ctx = el.getContext('2d'); const out = ctx.createImageData(meta.width, meta.height);
    const state = { meta, index, ctx, out, frame: 0, running: false, timer: null };
    marks.set(el, state); paint(state);
    el.dataset.ready = '1';
  }
  function paint(state) {
    const pal = state.meta.frames[state.frame], px = state.out.data, idx = state.index;
    for (let i = 0, n = idx.length / 4; i < n; i++) {
      const c = pal[idx[i * 4]] || pal[0];
      px[i * 4] = c[0]; px[i * 4 + 1] = c[1]; px[i * 4 + 2] = c[2]; px[i * 4 + 3] = 255;
    }
    state.ctx.putImageData(state.out, 0, 0);
  }
  function tick(state) {
    state.frame = (state.frame + 1) % state.meta.frames.length; paint(state);
  }
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  function run(el, on) {
    const state = marks.get(el); if (!state) return;
    on = on && !reduce;
    if (on && !state.timer) state.timer = setInterval(() => tick(state), el.dataset.period ? +el.dataset.period : 90);
    if (!on && state.timer) { clearInterval(state.timer); state.timer = null; state.frame = 0; paint(state); }
    state.running = on; el.dataset.cycling = on ? '1' : '';
  }
  window.shiftMarks = { load, run, frame: el => marks.get(el)?.frame ?? 0 };
  document.querySelectorAll('canvas[data-mark]').forEach(el => {
    load(el).then(() => {
      // Hover means "look at it"; the page's own signal (data-work) means work is running.
      el.addEventListener('pointerenter', () => run(el, true));
      el.addEventListener('pointerleave', () => run(el, el.dataset.work === '1'));
      if (el.dataset.work === '1') run(el, true);
    });
  });
})();

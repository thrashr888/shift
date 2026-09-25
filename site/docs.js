// On a narrow screen the rail of every page starts closed; on a wide one it stays open and inert.
(() => {
  const rail = document.querySelector('details.rail');
  if (rail && matchMedia('(max-width: 900px)').matches) rail.open = false;
})();

// Now and then one header flickers into another generation's face: two or three frames, a few times a minute.
(() => {
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  const headers = [...document.querySelectorAll('.doc h1')];
  if (!headers.length) return;
  const faces = ['cga', 'vga'];
  function flicker() {
    const h = headers[Math.floor(Math.random() * headers.length)];
    const face = faces[Math.floor(Math.random() * faces.length)];
    const bursts = 1 + Math.floor(Math.random() * 3);
    let i = 0;
    const step = () => {
      h.dataset.glitch = face; setTimeout(() => { delete h.dataset.glitch; if (++i < bursts) setTimeout(step, 60 + Math.random() * 90); }, 50 + Math.random() * 100);
    };
    step();
    setTimeout(flicker, 5000 + Math.random() * 9000);
  }
  setTimeout(flicker, 3000 + Math.random() * 4000);
})();

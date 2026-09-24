// The capture as points: a 4x4 Bayer dither of the image, each point given depth from local
// contrast, drawn as WebGL point sprites that tilt with the cursor, with a glitch field.
// One canvas per element carrying data-dither="image url". Static under reduced motion.
(() => {
  const VS = `#version 300 es
  in vec2 a_pos; in float a_depth; in float a_lum;
  uniform vec2 u_mouse; uniform float u_time; uniform float u_glitch; uniform float u_size;
  out float v_depth; out float v_lum; out float v_tear;
  float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
  void main(){
    float t = mod(u_time, 2048.0);
    float epoch = floor(t * 0.25), ph = fract(t * 0.25);
    float w = 0.10 + 0.80 * hash(vec2(epoch, 3.0));
    float window = smoothstep(0.045, 0.015, abs(ph - w)) * u_glitch;
    float tick = floor(t * 12.0), row = floor((a_pos.y * 0.5 + 0.5) * 42.0);
    float burst = step(0.72, hash(vec2(row, tick))) * window;
    float shear = (hash(vec2(row, tick + 41.0)) - 0.5) * 0.18 * burst;
    v_tear = burst;
    float z = a_depth;
    vec2 p = a_pos + shear * vec2(1.0, 0.0);
    p += (u_mouse * 0.06) * z;
    p += (u_mouse * -0.015);
    p *= 1.0 + 0.04 * z;
    gl_Position = vec4(p, 0.0, 1.0);
    gl_PointSize = u_size * (0.85 + 0.45 * z);
    v_depth = a_depth; v_lum = a_lum;
  }`;
  const FS = `#version 300 es
  precision mediump float;
  in float v_depth; in float v_lum; in float v_tear; out vec4 o;
  uniform vec3 u_dot; uniform vec3 u_tear;
  void main(){ o = vec4(mix(u_dot, u_tear, v_tear * 0.8), 1.0); }`;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const css = getComputedStyle(document.documentElement);
  const rgb = name => { const c = document.createElement('canvas').getContext('2d'); c.fillStyle = css.getPropertyValue(name).trim() || '#000'; c.fillRect(0, 0, 1, 1); return [...c.getImageData(0, 0, 1, 1).data].slice(0, 3).map(x => x / 255); };

  function mount(canvas) {
    const gl = canvas.getContext('webgl2', { antialias: false, alpha: false });
    if (!gl) { canvas.replaceWith(fallback(canvas)); return; }
    const shader = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
    const prog = gl.createProgram(); gl.attachShader(prog, shader(gl.VERTEX_SHADER, VS)); gl.attachShader(prog, shader(gl.FRAGMENT_SHADER, FS)); gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) { canvas.replaceWith(fallback(canvas)); return; }
    const U = n => gl.getUniformLocation(prog, n);
    const plum = rgb('--plum-deep'), dot = rgb('--lime-hi'), tear = rgb('--magenta-hi');
    const img = new Image(); img.src = canvas.dataset.dither;
    let count = 0, mouse = [0, 0], target = [0, 0], start = performance.now(), cells = 1;
    img.onload = () => {
      const cell = 3, w = Math.floor(img.width / cell), h = Math.floor(img.height / cell); cells = w;
      const off = document.createElement('canvas'); off.width = w; off.height = h;
      const ctx = off.getContext('2d', { willReadFrequently: true }); ctx.drawImage(img, 0, 0, w, h);
      const px = ctx.getImageData(0, 0, w, h).data, lum = new Float32Array(w * h);
      for (let i = 0; i < w * h; i++) lum[i] = (0.2126 * px[i * 4] + 0.7152 * px[i * 4 + 1] + 0.0722 * px[i * 4 + 2]) / 255;
      const bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];
      const pos = [], dep = [], lums = [];
      for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
        const l = lum[y * w + x], th = bayer[(y & 3) * 4 + (x & 3)] / 16;
        if (l <= th) continue;
        let mn = 1, mx = 0;
        for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) { const yy = y + dy, xx = x + dx; if (yy < 0 || xx < 0 || yy >= h || xx >= w) continue; const v = lum[yy * w + xx]; if (v < mn) mn = v; if (v > mx) mx = v; }
        pos.push((x + 0.5) / w * 2 - 1, 1 - (y + 0.5) / h * 2); dep.push(Math.min(1, 0.25 * l + 0.9 * (mx - mn))); lums.push(l);
      }
      count = dep.length;
      const buf = (data, loc, size) => { const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(data), gl.STATIC_DRAW); const a = gl.getAttribLocation(prog, loc); gl.enableVertexAttribArray(a); gl.vertexAttribPointer(a, size, gl.FLOAT, false, 0, 0); };
      gl.bindVertexArray(gl.createVertexArray());
      buf(pos, 'a_pos', 2); buf(dep, 'a_depth', 1); buf(lums, 'a_lum', 1);
      canvas.dataset.ready = '1';
      requestAnimationFrame(frame);
    };
    const stage = canvas.parentElement;
    stage.addEventListener('pointermove', e => { const r = stage.getBoundingClientRect(); target = [((e.clientX - r.left) / r.width) * 2 - 1, -(((e.clientY - r.top) / r.height) * 2 - 1)]; });
    stage.addEventListener('pointerleave', () => { target = [0, 0]; });
    function frame(now) {
      const dpr = Math.min(devicePixelRatio || 1, 2), r = canvas.getBoundingClientRect();
      const W = Math.round(r.width * dpr), H = Math.round(r.height * dpr);
      if (canvas.width !== W || canvas.height !== H) { canvas.width = W; canvas.height = H; gl.viewport(0, 0, W, H); }
      mouse[0] += (target[0] - mouse[0]) * 0.08; mouse[1] += (target[1] - mouse[1]) * 0.08;
      gl.useProgram(prog);
      gl.uniform2f(U('u_mouse'), reduce ? 0 : mouse[0], reduce ? 0 : mouse[1]);
      gl.uniform1f(U('u_time'), (now - start) / 1000);
      gl.uniform1f(U('u_glitch'), reduce ? 0 : 1);
      gl.uniform1f(U('u_size'), (W / cells) * 1.15);
      gl.uniform3f(U('u_dot'), ...dot); gl.uniform3f(U('u_tear'), ...tear);
      gl.clearColor(plum[0], plum[1], plum[2], 1); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.drawArrays(gl.POINTS, 0, count);
      if (!reduce && !canvas.closest('[hidden]')) requestAnimationFrame(frame); else if (!reduce) canvas.dataset.paused = '1';
    }
    canvas.addEventListener('shift:resume', () => { if (canvas.dataset.paused) { delete canvas.dataset.paused; requestAnimationFrame(frame); } });
  }
  function fallback(canvas) { const img = new Image(); img.src = canvas.dataset.dither; img.alt = canvas.getAttribute('aria-label') || ''; img.className = canvas.className; return img; }
  document.querySelectorAll('canvas[data-dither]').forEach(mount);
})();

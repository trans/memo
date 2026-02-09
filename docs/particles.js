(function() {
  const canvas = document.getElementById('particles');
  const ctx = canvas.getContext('2d');
  let w, h, particles, mouse, rafId;
  const PARTICLE_COUNT = 80;
  const CONN_DIST_SQ = 150 * 150;
  const CONN_DIST = 150;
  const MOUSE_DIST_SQ = 200 * 200;
  const MOUSE_DIST = 200;
  const colors = ['#6c8cff', '#a855f7', '#ec4899', '#f97316', '#34d399'];

  function resize() {
    w = canvas.width = window.innerWidth;
    h = canvas.height = window.innerHeight;
  }

  function init() {
    mouse = { x: -1000, y: -1000 };
    particles = [];
    for (let i = 0; i < PARTICLE_COUNT; i++) {
      particles.push({
        x: Math.random() * w,
        y: Math.random() * h,
        vx: (Math.random() - 0.5) * 0.5,
        vy: (Math.random() - 0.5) * 0.5,
        r: Math.random() * 2 + 1,
        color: colors[Math.floor(Math.random() * colors.length)],
        alpha: Math.random() * 0.5 + 0.3
      });
    }
  }

  function draw() {
    ctx.clearRect(0, 0, w, h);

    // Draw particles
    for (let i = 0; i < particles.length; i++) {
      const p = particles[i];
      p.x += p.vx;
      p.y += p.vy;
      if (p.x < 0) p.x = w;
      if (p.x > w) p.x = 0;
      if (p.y < 0) p.y = h;
      if (p.y > h) p.y = 0;

      ctx.beginPath();
      ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2);
      ctx.fillStyle = p.color;
      ctx.globalAlpha = p.alpha;
      ctx.fill();
    }

    // Draw connections (batched by color)
    ctx.lineWidth = 0.5;
    for (let ci = 0; ci < colors.length; ci++) {
      ctx.strokeStyle = colors[ci];
      for (let i = 0; i < particles.length; i++) {
        const p = particles[i];
        if (p.color !== colors[ci]) continue;
        for (let j = i + 1; j < particles.length; j++) {
          const q = particles[j];
          const dx = p.x - q.x;
          const dy = p.y - q.y;
          const distSq = dx * dx + dy * dy;
          if (distSq < CONN_DIST_SQ) {
            const alpha = (1 - Math.sqrt(distSq) / CONN_DIST) * 0.15;
            ctx.globalAlpha = alpha;
            ctx.beginPath();
            ctx.moveTo(p.x, p.y);
            ctx.lineTo(q.x, q.y);
            ctx.stroke();
          }
        }
      }
    }

    // Draw mouse connections
    ctx.strokeStyle = '#6c8cff';
    ctx.lineWidth = 0.8;
    for (let i = 0; i < particles.length; i++) {
      const p = particles[i];
      const dx = p.x - mouse.x;
      const dy = p.y - mouse.y;
      const distSq = dx * dx + dy * dy;
      if (distSq < MOUSE_DIST_SQ) {
        ctx.globalAlpha = (1 - Math.sqrt(distSq) / MOUSE_DIST) * 0.3;
        ctx.beginPath();
        ctx.moveTo(p.x, p.y);
        ctx.lineTo(mouse.x, mouse.y);
        ctx.stroke();
      }
    }

    ctx.globalAlpha = 1;
    rafId = requestAnimationFrame(draw);
  }

  function start() {
    if (!rafId) rafId = requestAnimationFrame(draw);
  }

  function stop() {
    if (rafId) { cancelAnimationFrame(rafId); rafId = null; }
  }

  document.addEventListener('visibilitychange', function() {
    if (document.hidden) stop(); else start();
  });

  window.addEventListener('resize', function() { resize(); });
  window.addEventListener('mousemove', function(e) {
    mouse.x = e.clientX;
    mouse.y = e.clientY;
  });

  resize();
  init();
  start();
})();

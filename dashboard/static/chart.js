// Parma Ham: formatting helpers and the canvas Chart, shared by the dashboard
// (dashboard/static/index.html) and the compare page (compare/static/index.html).
"use strict";
// ---------------------------------------------------------------------------
// formatting
// ---------------------------------------------------------------------------
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
function fmtNum(v, digits) {
  if (v == null || isNaN(v)) return "–";
  const a = Math.abs(v);
  if (a >= 1e9) return (v / 1e9).toFixed(a >= 1e10 ? 1 : 2) + "B";
  if (a >= 1e6) return (v / 1e6).toFixed(a >= 1e7 ? 1 : 2) + "M";
  if (a >= 1e4) return (v / 1e3).toFixed(a >= 1e5 ? 0 : 1) + "k";
  if (digits != null) return v.toFixed(digits);
  if (a >= 100) return Math.round(v).toLocaleString();
  if (a >= 10) return v.toFixed(1);
  return v.toFixed(a === 0 ? 0 : 2);
}
function fmtInt(v) { return v == null || isNaN(v) ? "–" : Math.round(v).toLocaleString(); }
function fmtBytes(v, suffix = "") {
  if (v == null || isNaN(v)) return "–";
  const u = ["B", "KB", "MB", "GB", "TB", "PB"]; let i = 0; let x = Math.abs(v);
  while (x >= 1024 && i < u.length - 1) { x /= 1024; i++; }
  return (v < 0 ? "-" : "") + (x >= 100 || i === 0 ? x.toFixed(0) : x.toFixed(1)) + " " + u[i] + suffix;
}
const fmtPct = (v) => v == null || isNaN(v) ? "–" : (v >= 10 ? v.toFixed(0) : v.toFixed(1)) + "%";
function fmtDur(sec) {
  if (sec == null || isNaN(sec)) return "–";
  sec = Math.max(0, Math.round(sec));
  const d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60;
  if (d) return `${d}d ${h}h`;
  if (h) return `${h}h ${m}m`;
  if (m) return `${m}m ${String(s).padStart(2, "0")}s`;
  return `${s}s`;
}
const clock = (sec) => { sec = Math.max(0, Math.round(sec)); const m = Math.floor(sec / 60), s = sec % 60; return `${m}:${String(s).padStart(2, "0")}`; };
const parseTs = (s) => s ? Date.parse(s) / 1000 : null;
function fmtWhen(ts) {
  if (!ts) return "–";
  const d = new Date(ts * 1000), now = new Date();
  const t = d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  if (d.toDateString() === now.toDateString()) return t;
  return d.toLocaleDateString([], { month: "short", day: "numeric" }) + " " + t;
}
const ago = (ts) => ts ? fmtDur(Date.now() / 1000 - ts) + " ago" : "–";
const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

// ---------------------------------------------------------------------------
// canvas line chart
// ---------------------------------------------------------------------------
// new Chart("c-id", series, opts): series are {key | get(p), name, color, fill,
// dash, width, points}; opts: fmt, max, minMax, stacked, gap (seconds that
// break the line), connect (draw across points where a series has no value,
// for data merged from several sources), empty, minPoints, tipTitle.
class Chart {
  constructor(id, series, opts = {}) {
    this.box = $(id); this.legend = $("l-" + id.slice(2)); this.series = series; this.opts = opts;
    this.canvas = document.createElement("canvas"); this.box.appendChild(this.canvas);
    this.tip = document.createElement("div"); this.tip.className = "tip"; this.box.appendChild(this.tip);
    this.emptyEl = document.createElement("div"); this.emptyEl.className = "empty"; this.box.appendChild(this.emptyEl);
    this.data = []; this.hover = null;
    this.canvas.addEventListener("mousemove", (e) => { this.hover = e.offsetX; this.draw(); });
    this.canvas.addEventListener("mouseleave", () => { this.hover = null; this.draw(); });
    new ResizeObserver(() => this.draw()).observe(this.box);
  }
  set(data, x0, x1, res) { this.data = data; this.x0 = x0; this.x1 = x1; this.res = res || 5; this.draw(); this.renderLegend(); }
  value(s, p) { const v = typeof s.get === "function" ? s.get(p) : p[s.key]; return v == null || isNaN(v) ? null : v; }
  // newest value of a series (looking back a few points for merged data)
  lastValue(s) {
    for (let i = this.data.length - 1; i >= Math.max(0, this.data.length - (this.opts.connect ? 6 : 1)); i--) {
      const v = this.value(s, this.data[i]); if (v != null) return v;
    }
    return null;
  }
  renderLegend() {
    if (!this.legend) return;
    const fmt = this.opts.fmt || fmtNum;
    this.legend.innerHTML = this.series.map((s) => {
      const v = this.lastValue(s);
      return `<span><i class="${s.dash ? "dash" : ""}" style="${s.dash ? "border-color" : "background"}:${css(s.color)}"></i>${esc(s.name)} <b class="num">${v == null ? "–" : fmt(v)}</b></span>`;
    }).join("");
  }
  draw() {
    const W = this.box.clientWidth, H = this.box.clientHeight; if (!W || !H) return;
    const dpr = window.devicePixelRatio || 1;
    if (this.canvas.width !== Math.round(W * dpr) || this.canvas.height !== Math.round(H * dpr)) {
      this.canvas.width = Math.round(W * dpr); this.canvas.height = Math.round(H * dpr);
    }
    const g = this.canvas.getContext("2d"); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, W, H);
    const fmt = this.opts.fmt || fmtNum, axisFmt = this.opts.axisFmt || fmt;
    const data = this.data;
    const minPts = this.opts.minPoints ?? 2;
    this.emptyEl.textContent = data.length < minPts ? (this.opts.empty || "collecting data…") : "";
    if (data.length < minPts) { this.tip.style.display = "none"; return; }

    let x0 = this.x0 ?? data[0].t, x1 = this.x1 ?? data[data.length - 1].t;
    if (x1 - x0 < 60) { x0 -= 1800; x1 += 1800; }  // a single point: center it in an hour
    let ymax = this.opts.max ?? 0;
    if (this.opts.max == null) for (const p of data) for (const s of this.series) { const v = this.value(s, p); if (v != null) ymax = Math.max(ymax, s.stack ? 0 : v); }
    if (this.opts.stacked) for (const p of data) { let sum = 0; for (const s of this.series) sum += this.value(s, p) || 0; ymax = Math.max(ymax, sum); }
    if (this.opts.minMax) ymax = Math.max(ymax, this.opts.minMax);
    const ticks = niceTicks(ymax || 1, 4); ymax = ticks[ticks.length - 1];

    g.font = "11px system-ui, sans-serif";
    const padL = Math.max(...ticks.map((t) => g.measureText(axisFmt(t)).width)) + 10, padR = 6, padT = 6, padB = 18;
    const pw = W - padL - padR, ph = H - padT - padB;
    const X = (t) => padL + (x1 === x0 ? 0 : (t - x0) / (x1 - x0) * pw);
    const Y = (v) => padT + ph - (v / ymax) * ph;

    // grid & axes
    g.strokeStyle = css("--grid"); g.lineWidth = 1; g.fillStyle = css("--faint");
    g.textAlign = "right"; g.textBaseline = "middle";
    for (const t of ticks) { const y = Math.round(Y(t)) + .5; g.beginPath(); g.moveTo(padL, y); g.lineTo(W - padR, y); g.stroke(); g.fillText(axisFmt(t), padL - 6, y); }
    g.textAlign = "center"; g.textBaseline = "alphabetic";
    const span = x1 - x0, nlab = Math.max(2, Math.floor(pw / 90));
    const step = niceTimeStep(span / nlab);
    for (let t = Math.ceil(x0 / step) * step; t <= x1; t += step) {
      const d = new Date(t * 1000);
      const lab = span > 2 * 86400 ? d.toLocaleDateString([], { month: "short", day: "numeric" })
        : d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
      g.fillText(lab, X(t), H - 4);
    }

    // series
    const base = new Array(data.length).fill(0);
    this.series.forEach((s, si) => {
      const color = css(s.color);
      const pts = data.map((p, i) => { const v = this.value(s, p); if (v == null) return null; const y = this.opts.stacked ? base[i] + v : v; return [X(p.t), Y(y), y]; });
      const gapLimit = this.opts.gap ? Math.max(this.opts.gap, this.res * 2.5) : Infinity;
      g.lineWidth = s.width || 1.6; g.strokeStyle = color; g.setLineDash(s.dash ? [5, 4] : []);
      g.beginPath(); let pen = false, lastT = null;
      pts.forEach((pt, i) => {
        if ((!pt && !this.opts.connect) || (pt && lastT != null && data[i].t - lastT > gapLimit)) pen = false;
        if (!pt) return;
        if (pen) g.lineTo(pt[0], pt[1]); else g.moveTo(pt[0], pt[1]);
        pen = true; lastT = data[i].t;
      });
      g.stroke(); g.setLineDash([]);
      if (s.fill || this.opts.stacked) {
        g.globalAlpha = this.opts.stacked ? .35 : .12; g.fillStyle = color; g.beginPath();
        // one filled area per stretch of the line, so gaps stay empty
        // (stacked charts fill across gaps: every series shares the base)
        let run = [], last = null;
        const flush = () => {
          if (run.length) {
            g.moveTo(run[0][0], Y(base[run[0][3]]));
            for (const pt of run) g.lineTo(pt[0], pt[1]);
            for (let k = run.length - 1; k >= 0; k--) g.lineTo(run[k][0], Y(base[run[k][3]]));
            g.closePath();
          }
          run = [];
        };
        pts.forEach((pt, i) => {
          if (!this.opts.stacked && ((!pt && !this.opts.connect) || (pt && last != null && data[i].t - last > gapLimit))) flush();
          if (pt) { run.push([pt[0], pt[1], pt[2], i]); last = data[i].t; }
        });
        flush();
        g.fill(); g.globalAlpha = 1;
      }
      if (s.points) {
        g.fillStyle = color;
        pts.forEach((pt) => { if (pt) { g.beginPath(); g.arc(pt[0], pt[1], data.length > 300 ? 1.5 : 2.6, 0, 7); g.fill(); } });
      }
      if (this.opts.stacked) data.forEach((p, i) => { base[i] += this.value(s, p) || 0; });
    });

    // hover
    if (this.hover != null && this.hover >= padL) {
      const t = x0 + (this.hover - padL) / pw * (x1 - x0);
      let best = 0; for (let i = 1; i < data.length; i++) if (Math.abs(data[i].t - t) < Math.abs(data[best].t - t)) best = i;
      const p = data[best], x = X(p.t);
      g.strokeStyle = css("--faint"); g.lineWidth = 1; g.beginPath(); g.moveTo(Math.round(x) + .5, padT); g.lineTo(Math.round(x) + .5, padT + ph); g.stroke();
      const head = this.opts.tipTitle ? this.opts.tipTitle(p) : (this.res >= 60 ? "avg of minute · " : "") + new Date(p.t * 1000).toLocaleTimeString();
      // merged data: a series without a value here shows its nearest one
      const near = (s) => {
        let v = this.value(s, p);
        for (let d = 1; v == null && this.opts.connect && d <= 3; d++) v = this.value(s, data[best - d] || {}) ?? this.value(s, data[best + d] || {});
        return v;
      };
      this.tip.innerHTML = `<div class="t">${esc(head)}</div>` + this.series.map((s) =>
        `<div><span style="color:${css(s.color)}">●</span> ${esc(s.name)}: <b class="num">${(() => { const v = near(s); return v == null ? "–" : fmt(v); })()}</b></div>`).join("");
      this.tip.style.display = "block";
      const tw = this.tip.offsetWidth;
      this.tip.style.left = (x + 12 + tw > W ? x - tw - 12 : x + 12) + "px"; this.tip.style.top = "4px";
    } else this.tip.style.display = "none";
  }
}
function niceTicks(max, n) {
  const raw = max / n, mag = Math.pow(10, Math.floor(Math.log10(raw)));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw) || 10 * mag;
  const out = []; for (let v = 0; v <= max + step * 0.999; v += step) out.push(+v.toFixed(10));
  if (out.length < 2) out.push(step);
  return out;
}
function niceTimeStep(sec) {
  const steps = [10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800, 604800, 2592000];
  return steps.find((s) => s >= sec) || steps[steps.length - 1];
}

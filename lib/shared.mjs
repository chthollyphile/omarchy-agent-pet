// 生成文件，勿手改：node tools/build-shared.mjs

// ../dsh-pet/dsh-pet/src/shared/constants.ts
var CANVAS_H = 360;
var FEET_Y = 330;
var HIT_BOX = { x0: 200, y0: 50, x1: 440, y1: 335 };
var DRAG_THRESHOLD = 5;
var PET_REF_WIDTH = 462;

// ../dsh-pet/dsh-pet/src/shared/displays.ts
var rectRight = (r) => r.x + r.width;
var rectBottom = (r) => r.y + r.height;
var pointInRect = (r, x, y) => x >= r.x && x < rectRight(r) && y >= r.y && y < rectBottom(r);
var rectAtPoint = (rects, x, y) => {
  for (const r of rects) if (pointInRect(r, x, y)) return r;
  return null;
};
var indexAtPoint = (rects, x, y) => {
  for (let i = 0; i < rects.length; i++) if (pointInRect(rects[i], x, y)) return i;
  return -1;
};
var distToRectSq = (r, x, y) => {
  const dx = Math.max(r.x - x, 0, x - rectRight(r));
  const dy = Math.max(r.y - y, 0, y - rectBottom(r));
  return dx * dx + dy * dy;
};
var nearestIndex = (rects, x, y) => {
  let best = -1;
  let bestD = Infinity;
  for (let i = 0; i < rects.length; i++) {
    const d = distToRectSq(rects[i], x, y);
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return best;
};

// ../dsh-pet/dsh-pet/src/shared/physics.ts
var SPRING_K = 200;
var SPRING_C = 30;
var TRAIL_KEEP_MS = 200;
var RELEASE_WINDOW_MS = 150;
var RELEASE_STALE_MS = 150;
var MIN_SPAN_MS = 20;
var SEG_MIN_DT_MS = 8;
var DEAD_ZONE_SPEED = 500;
var MAX_THROW_SPEED = 3600;
var PEAK_WEIGHT = 0.5;
var ACCEL_REF = 8e3;
var ACCEL_GAIN_MAX = 0.6;
var GRAVITY = 1400;
var RESTITUTION = 0.78;
var GROUND_FRICTION = 2.5;
var DEFAULT_PHYSICS = {
  gravity: GRAVITY,
  restitution: RESTITUTION,
  groundFriction: GROUND_FRICTION,
  ceilingBounce: true,
  throwPower: 1,
  petCollision: false
};
var DEFAULT_THROW_POWER = 1;
var REST_VY = 40;
var REST_VX = 15;
var MAX_STEP_DT = 0.05;
var SQ_SQUASH = 0.55;
var SQ_DURATION_MS = 220;
var SQ_SOFT_SPEED = 300;
var SQ_HARD_SPEED = 1500;
var SQ_MAX_SQUASH = 0.55;
var landingSquash = (impactSpeed) => {
  const t = Math.min(Math.max((Math.abs(impactSpeed) - SQ_SOFT_SPEED) / (SQ_HARD_SPEED - SQ_SOFT_SPEED), 0), 1);
  return Math.min(0.8, 1 - t * (1 - SQ_MAX_SQUASH));
};
var squashScale = (u, squash = SQ_SQUASH) => {
  if (u < 0.45) {
    const p2 = u / 0.45;
    return 1 - (1 - squash) * p2 * p2;
  }
  const p = (u - 0.45) / 0.55;
  const c1 = 1.70158;
  const c3 = c1 + 1;
  const f = 1 + c3 * Math.pow(p - 1, 3) + c1 * Math.pow(p - 1, 2);
  return Math.min(1.12, squash + (1 - squash) * Math.max(f, 0));
};
var throwBoundsIn = (area, size, sideAllow) => {
  const h = size * 9 / 16;
  return {
    minX: area.x - sideAllow,
    minY: area.y,
    maxX: rectRight(area) - size + sideAllow,
    maxY: rectBottom(area) - h
  };
};
var throwSpace = (o) => ({
  bounds: o.areas.map((a) => throwBoundsIn(a, o.size, o.sideAllow)),
  areas: o.areas,
  panels: o.panels && o.panels.length === o.areas.length ? o.panels : o.areas,
  // 面板缺失/不同序：退化用工作区（保持旧行为）
  size: o.size,
  sideAllow: o.sideAllow
});
var screenOfBox = (space, x, y) => {
  const cx = x + space.size / 2;
  const cy = y + space.size * 9 / 16 / 2;
  const hit = indexAtPoint(space.areas, cx, cy);
  return hit >= 0 ? hit : nearestIndex(space.areas, cx, cy);
};
var trimTrail = (trail, now) => {
  const cutoff = now - TRAIL_KEEP_MS;
  let i = 0;
  while (i < trail.length && trail[i].t < cutoff) i++;
  return i === 0 ? trail : trail.slice(i);
};
var springStep = (v, x, target, dt, power = DEFAULT_THROW_POWER) => v + ((target - x) * SPRING_K - v * SPRING_C) * power * dt;
var softClampSpeed = (speed) => {
  if (speed <= 0) return 0;
  return MAX_THROW_SPEED * (1 - Math.exp(-speed / MAX_THROW_SPEED));
};
var estimateReleaseVelocity = (trail, now, physics = DEFAULT_PHYSICS) => {
  if (trail.length === 0) return null;
  const last = trail[trail.length - 1];
  if (now - last.t > RELEASE_STALE_MS) return null;
  const win = trail.filter((s) => now - s.t <= RELEASE_WINDOW_MS);
  if (win.length < 2) return null;
  const t0 = win[0].t;
  const x0 = win[0].x;
  const y0 = win[0].y;
  const t1 = win[win.length - 1].t;
  const x1 = win[win.length - 1].x;
  const y1 = win[win.length - 1].y;
  const spanMs = t1 - t0;
  if (spanMs < MIN_SPAN_MS) return null;
  const baseVx = (x1 - x0) / spanMs * 1e3;
  const baseVy = (y1 - y0) / spanMs * 1e3;
  const baseSpeed = Math.hypot(baseVx, baseVy);
  if (baseSpeed < 1e-6) return null;
  const segSpeeds = [];
  let px = x0;
  let py = y0;
  let pt = t0;
  for (const s of win.slice(1)) {
    const dt = s.t - pt;
    if (dt >= SEG_MIN_DT_MS) {
      segSpeeds.push({ speed: Math.hypot(s.x - px, s.y - py) / dt * 1e3, tEnd: s.t });
      px = s.x;
      py = s.y;
      pt = s.t;
    }
  }
  const peakSpeed = segSpeeds.length ? Math.max(...segSpeeds.map((v) => v.speed)) : baseSpeed;
  let accel = 0;
  if (segSpeeds.length >= 2) {
    const lastSeg = segSpeeds[segSpeeds.length - 1];
    const firstSeg = segSpeeds[0];
    accel = (lastSeg.speed - firstSeg.speed) / Math.max((lastSeg.tEnd - firstSeg.tEnd) / 1e3, MIN_SPAN_MS / 1e3);
  }
  const speedBeforeClamp = ((1 - PEAK_WEIGHT) * baseSpeed + PEAK_WEIGHT * peakSpeed) * (1 + Math.min(Math.max(accel, 0) / ACCEL_REF, 1) * ACCEL_GAIN_MAX);
  const speed = softClampSpeed(speedBeforeClamp) * physics.throwPower;
  if (speed < DEAD_ZONE_SPEED) return null;
  return { vx: baseVx / baseSpeed * speed, vy: baseVy / baseSpeed * speed };
};
var throwStepRegion = (s, dtRaw, space, physics = DEFAULT_PHYSICS, lockScreen = -1) => {
  const dt = Math.min(Math.max(dtRaw, 0), MAX_STEP_DT);
  let { x, y, vx, vy } = s;
  vy += physics.gravity * dt;
  x += vx * dt;
  y += vy * dt;
  if (space.areas.length === 0) return { x, y, vx, vy, screen: -1, bounced: false, atRest: false };
  const h = space.size * 9 / 16;
  let bounced = false;
  const locked = Number.isInteger(lockScreen) && lockScreen >= 0 && lockScreen < space.areas.length;
  const pick2 = (i) => locked ? lockScreen : i;
  let cur = screenOfBox(space, x, y);
  let b = space.bounds[pick2(cur)];
  let a = space.areas[pick2(cur)];
  const pa = space.panels[pick2(cur)] || a;
  const cy = y + h / 2;
  if (x < b.minX) {
    if (locked || indexAtPoint(space.panels, pa.x - 1, cy) < 0) {
      x = b.minX;
      vx = Math.abs(vx) * physics.restitution;
      bounced = true;
    }
  } else if (x > b.maxX) {
    if (locked || indexAtPoint(space.panels, rectRight(pa), cy) < 0) {
      x = b.maxX;
      vx = -Math.abs(vx) * physics.restitution;
      bounced = true;
    }
  }
  cur = screenOfBox(space, x, y);
  b = space.bounds[pick2(cur)];
  a = space.areas[pick2(cur)];
  const pa2 = space.panels[pick2(cur)] || a;
  const cx = x + space.size / 2;
  if (y < b.minY) {
    if (physics.ceilingBounce && (locked || indexAtPoint(space.panels, cx, pa2.y - 1) < 0)) {
      y = b.minY;
      vy = Math.abs(vy) * physics.restitution;
      bounced = true;
    }
  } else if (y >= b.maxY) {
    if (locked || indexAtPoint(space.panels, cx, rectBottom(pa2)) < 0) {
      y = b.maxY;
      vx *= Math.max(0, 1 - physics.groundFriction * dt);
      if (Math.abs(vy) < REST_VY) vy = 0;
      else vy = -Math.abs(vy) * physics.restitution;
      bounced = true;
    }
  }
  cur = pick2(screenOfBox(space, x, y));
  b = space.bounds[cur];
  const speed = Math.hypot(vx, vy);
  const atRest = y >= b.maxY - 1 && Math.abs(vy) < 1 && Math.abs(vx) < REST_VX || bounced && speed < REST_VY && Math.abs(vy) < 1;
  return { x, y, vx, vy, screen: cur, bounced, atRest };
};
var PET_BOUNCE_E = 0.995;
var bodyPixelBox = (o) => {
  const h = o.size * 9 / 16;
  return {
    left: o.x + HIT_BOX.x0 / 640 * o.size,
    top: o.y + o.bottomPad + HIT_BOX.y0 / 360 * h,
    right: o.x + HIT_BOX.x1 / 640 * o.size,
    bottom: o.y + o.bottomPad + HIT_BOX.y1 / 360 * h
  };
};
var rectsOverlap = (a, b) => a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
var collidePet = (fly, hit) => {
  const hf = fly.size * 9 / 16 / 2;
  const hh = hit.size * 9 / 16 / 2;
  const cx = hit.x + hit.size / 2 - (fly.x + fly.size / 2);
  const cy = hit.y + hh - (fly.y + hf);
  const dist = Math.hypot(cx, cy);
  if (dist < 1e-6) return null;
  const nx = cx / dist;
  const ny = cy / dist;
  const vrel = (fly.vx - hit.vx) * nx + (fly.vy - hit.vy) * ny;
  if (vrel <= 0) return null;
  const e = PET_BOUNCE_E;
  const m1 = fly.size * fly.size;
  const m2 = hit.size * hit.size;
  const v1n = fly.vx * nx + fly.vy * ny;
  const v2n = hit.vx * nx + hit.vy * ny;
  const v1n2 = ((m1 - e * m2) * v1n + (1 + e) * m2 * v2n) / (m1 + m2);
  const v2n2 = ((m2 - e * m1) * v2n + (1 + e) * m1 * v1n) / (m1 + m2);
  return {
    fvx: fly.vx - v1n * nx + v1n2 * nx,
    fvy: fly.vy - v1n * ny + v1n2 * ny,
    hvx: hit.vx - v2n * nx + v2n2 * nx,
    hvy: hit.vy - v2n * ny + v2n2 * ny
  };
};

// ../dsh-pet/dsh-pet/src/shared/pickers.ts
var pick = (pool, exclude) => {
  const entries = exclude ? pool.filter((n) => n !== exclude) : pool;
  const src = entries.length ? entries : pool;
  return src[Math.floor(Math.random() * src.length)];
};
var pickSlot = (slot, exclude) => {
  if (typeof slot === "string") return slot;
  const entries = exclude === void 0 ? slot : slot.filter((n) => n !== exclude);
  const src = entries.length ? entries : slot;
  return src[Math.floor(Math.random() * src.length)];
};
var slotIncludes = (slot, anim) => typeof slot === "string" ? slot === anim : slot.includes(anim);
var poolIncludes = (pool, anim) => pool.some((slot) => slotIncludes(slot, anim));
var isEventAnim = (events, anim) => events ? Object.values(events).some((pool) => poolIncludes(pool, anim)) : false;
var nextWorkStatusAnim = (pool, current) => {
  const idx = pool.findIndex((slot2) => slotIncludes(slot2, current));
  if (idx === -1) return null;
  const slot = pool[idx];
  if (!Array.isArray(slot) || slot.length <= 1) return null;
  return pickSlot(slot, current);
};
var randomBetween = (min, max) => Math.floor(min + Math.random() * (max - min));
var pickWeightedCategory = (categories, facing) => {
  const cats = categories.filter((c) => c.actions.length > 0);
  if (!cats.length) return null;
  const filtered = cats.filter((c) => !(c.noMirror && facing === "right"));
  const eligible = filtered.length ? filtered : cats;
  const totalW = eligible.reduce((s, c) => s + c.weight, 0) || 1;
  let t = Math.random() * totalW;
  for (const c of eligible) {
    t -= c.weight;
    if (t <= 0) return c;
  }
  return eligible[eligible.length - 1];
};
var rollKind = (roll, w, opts) => {
  const turn = (opts == null ? void 0 : opts.fixed) ? 0 : w.turn;
  const move = (opts == null ? void 0 : opts.fixed) ? 0 : w.move;
  const topEnd = (w.idle + turn + move) / 100;
  if (roll < w.idle / 100) return "idle";
  if (roll < (w.idle + turn) / 100) return "turn";
  if (roll < topEnd) return "move";
  return "action";
};
var pickCategoryAction = (categories, idlePool, facing, current) => {
  const cat = pickWeightedCategory(categories, facing);
  if (!cat) return { id: "FALLBACK", name: pick(idlePool, current) };
  return { id: cat.id, name: pick(cat.actions, current) };
};

// ../dsh-pet/dsh-pet/src/shared/motion.ts
var planMove = (o) => {
  var _a;
  const side = (_a = o.sideAllow) != null ? _a : 0;
  const distance = randomBetween(o.minDist, o.maxDist);
  const target = o.cx + o.dir * distance;
  if (o.areas && o.areas.length > 0) {
    const bodyHalf = o.halfW - side;
    if (!rectAtPoint(o.areas, target - bodyHalf - o.margin, o.cy)) return null;
    if (!rectAtPoint(o.areas, target + bodyHalf + o.margin, o.cy)) return null;
  } else {
    const leftBound = o.margin + o.halfW - side;
    const rightBound = o.W - o.margin - o.halfW + side;
    if (target < leftBound || target > rightBound) return null;
  }
  return {
    startRatio: o.cx / o.W,
    startYRatio: o.cy / o.H,
    targetRatio: target / o.W,
    totalRatio: Math.abs(target - o.cx) / o.W
  };
};
var anchorPixel = (o) => {
  var _a;
  const height = o.size * 9 / 16;
  const a = (_a = o.area) != null ? _a : { x: 0, y: 0, width: o.W, height: o.H };
  const left = a.x + o.marginX;
  const top = a.y + o.marginY;
  const right = a.x + a.width - o.size - o.marginX;
  const bottom = a.y + a.height - height - o.marginY;
  switch (o.corner) {
    case "top-left":
      return { x: left, y: top };
    case "top-right":
      return { x: right, y: top };
    case "bottom-left":
      return { x: left, y: bottom };
    case "bottom-right":
      return { x: right, y: bottom };
  }
};

// ../dsh-pet/dsh-pet/src/shared/menu.ts
var EVENT_LABELS = {
  balance: "\u4F59\u989D\u6863\u4F4D",
  whisper: "\u788E\u788E\u5FF5",
  workStatus: "\u5DE5\u4F5C\u72B6\u6001"
};
var leaf = (anim) => ({ label: anim, anim });
function buildMenuTree(animations) {
  var _a, _b, _c, _d;
  const groups = [];
  const pools = [
    ["\u5F85\u673A", animations.idle],
    ["\u8F6C\u5411", animations.turn],
    ["\u62D6\u62FD", animations.drag],
    ["\u70B9\u51FB\u56DE\u5E94", animations.clicks],
    ["\u79FB\u52A8", animations.moves.actions.map((m) => m.name)]
  ];
  for (const [label, pool] of pools) {
    if (pool.length) groups.push({ label, children: pool.map(leaf) });
  }
  const cats = ((_a = animations.categories) != null ? _a : []).filter((c) => c.actions.length > 0);
  for (const c of cats) {
    groups.push({ label: c.id, children: c.actions.map(leaf) });
  }
  const events = (_b = animations.events) != null ? _b : {};
  for (const key of Object.keys(events)) {
    const pool = (_c = events[key]) != null ? _c : [];
    const names = [];
    for (const slot of pool) {
      if (typeof slot === "string") names.push(slot);
      else names.push(...slot);
    }
    if (names.length) groups.push({ label: (_d = EVENT_LABELS[key]) != null ? _d : key, children: names.map(leaf) });
  }
  if (!groups.length) return [];
  return [{ label: "\u52A8\u4F5C", children: groups }];
}
function isNoMirrorAnimation(categories, anim) {
  return (categories != null ? categories : []).some((c) => c.noMirror === true && c.actions.includes(anim));
}
var MENU_CSS = [
  ".dsh-pet-menu{position:fixed;left:0;top:0;z-index:2147483000;color:#2b2b2b;font-size:13px;line-height:1.5;",
  "font-family:'Microsoft YaHei UI','Segoe UI','PingFang SC',sans-serif;user-select:none;pointer-events:auto}",
  ".dsh-pet-menu,.dsh-pet-menu *{box-sizing:border-box}",
  ".dsh-pet-menu-column{position:absolute;min-width:150px;max-width:240px;padding:4px;",
  "background:rgba(255,255,255,.98);border:1px solid rgba(0,0,0,.12);border-radius:8px;",
  "box-shadow:0 8px 28px rgba(0,0,0,.2);max-height:min(62vh,460px);overflow-y:auto;",
  // 自定义滚动条：细圆角半透明条（Chromium 系 Chrome/Edge/Electron 走 ::-webkit-scrollbar；
  // Firefox 走 scrollbar-width/scrollbar-color）。thumb 用 border+background-clip 内缩 2px 留白，
  // 与菜单的圆角白底协调；hover 加深并与 item:hover 的蓝呼应。track 透明不抢视觉。
  "scrollbar-width:thin;scrollbar-color:rgba(0,0,0,.22) transparent}",
  ".dsh-pet-menu-column::-webkit-scrollbar{width:8px;height:8px}",
  ".dsh-pet-menu-column::-webkit-scrollbar-track{background:transparent}",
  ".dsh-pet-menu-column::-webkit-scrollbar-thumb{background:rgba(0,0,0,.16);border-radius:4px;",
  "border:2px solid transparent;background-clip:content-box}",
  ".dsh-pet-menu-column::-webkit-scrollbar-thumb:hover{background:rgba(43,99,255,.4);",
  "border:2px solid transparent;background-clip:content-box}",
  ".dsh-pet-menu-column::-webkit-scrollbar-corner{background:transparent}",
  ".dsh-pet-menu-item{position:relative;display:flex;align-items:center;justify-content:space-between;",
  "gap:14px;padding:5px 12px;border-radius:6px;white-space:nowrap;cursor:default}",
  ".dsh-pet-menu-item:hover{background:rgba(43,99,255,.14)}",
  ".dsh-pet-menu-item>span:first-child{min-width:0;overflow:hidden;text-overflow:ellipsis}",
  ".dsh-pet-menu-arrow{color:#9aa0a6;font-size:12px;flex:none}"
].join("");

// ../dsh-pet/dsh-pet/src/shared/work-status.ts
var WORK_STATUS_STATES = ["thinking", "working", "result", "waiting", "success", "error"];
var WORK_STATUS_INDEX = {
  thinking: 0,
  // turn/start → 思考
  working: 1,
  // tool/call → 工作
  result: 2,
  // tool/result → 整理
  waiting: 3,
  // approval/asked → 等待
  success: 4,
  // turn/end completed → 完成
  error: 5
  // turn/end error/max-tokens → 出错
};
export {
  CANVAS_H,
  DEFAULT_PHYSICS,
  DRAG_THRESHOLD,
  FEET_Y,
  HIT_BOX,
  PET_REF_WIDTH,
  SQ_DURATION_MS,
  SQ_SQUASH,
  WORK_STATUS_INDEX,
  WORK_STATUS_STATES,
  anchorPixel,
  bodyPixelBox,
  buildMenuTree,
  collidePet,
  estimateReleaseVelocity,
  isEventAnim,
  isNoMirrorAnimation,
  landingSquash,
  nextWorkStatusAnim,
  pick,
  pickCategoryAction,
  pickSlot,
  planMove,
  poolIncludes,
  rectsOverlap,
  rollKind,
  slotIncludes,
  springStep,
  squashScale,
  throwSpace,
  throwStepRegion,
  trimTrail
};

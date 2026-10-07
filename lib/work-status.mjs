// Claude Code / Codex hooks 事件 → 工作状态档位，按会话聚合。
// 档位顺序与 dsh-pet 的 animations.events.workStatus / workStatusTexts 索引一致：
//   0 thinking / 1 working / 2 result / 3 waiting / 4 success / 5 error
// 纯逻辑（无 QML 依赖），QML 以 import "lib/work-status.mjs" 导入，node 可直接单测。

export const STATES = ['thinking', 'working', 'result', 'waiting', 'success', 'error'];

/** 多个会话同时活跃时展示哪一个：越需要人看的越优先 */
const PRIORITY = { waiting: 6, error: 5, working: 4, thinking: 3, result: 2, success: 1 };

/** 终态（success / error）只展示一会儿，过后让位给其他会话或回到随机动画链 */
export const TERMINAL_TTL_MS = 15 * 1000;
/** 非终态会话多久没有新事件就当作已失联（终端被直接关掉时收不到 SessionEnd） */
export const STALE_TTL_MS = 10 * 60 * 1000;

/** 模型在向用户提问的工具：归为 waiting，而不是普通的 working */
const QUESTION_TOOLS = new Set(['AskUserQuestion', 'request_user_input', 'ask_user_question']);
/** 需要用户处理的 Notification 类型（idle_prompt 跟在 Stop 后面，不重复处理） */
const WAITING_NOTIFICATIONS = new Set(['permission_prompt', 'elicitation_dialog']);

/**
 * 单个 hook 事件 → 动作。
 * 返回 { state } 设置该会话档位；{ clear: true } 结束该会话；null 忽略。
 */
export function classify(ev) {
  switch (ev.event) {
    case 'UserPromptSubmit':
      return { state: 'thinking' };
    case 'PreToolUse':
      return { state: QUESTION_TOOLS.has(ev.tool) ? 'waiting' : 'working' };
    case 'PostToolUse':
    case 'PostToolUseFailure': // 工具失败（命令非零退出等）很常见，不代表本轮出错
      return { state: 'result' };
    case 'PermissionRequest':
    case 'Elicitation':
      return { state: 'waiting' };
    case 'Notification':
      return WAITING_NOTIFICATIONS.has(ev.notificationType) ? { state: 'waiting' } : null;
    case 'Stop':
      return { state: 'success' };
    case 'StopFailure':
      return { state: 'error' };
    case 'SessionEnd':
      return { clear: true };
    default:
      return null;
  }
}

export const isTerminal = (state) => state === 'success' || state === 'error';

/** 步骤总结最多看最近几步 */
export const MAX_STEPS = 8;

/** 会话表：key = agent:session → { key, agent, session, cwd, state, at, tool, message, focused } */
export function createStore() {
  return { sessions: {} };
}

/**
 * 应用一个事件。返回 { changed, entered, entry }：
 * entered = 该会话本次进入的新档位（档位没变时为 null，供通知去重）。
 */
export function applyEvent(store, ev, now) {
  const action = classify(ev);
  if (!action) return { changed: false, entered: null, entry: null };
  const key = (ev.agent || 'agent') + ':' + (ev.session || 'default');
  if (action.clear) {
    const had = key in store.sessions;
    delete store.sessions[key];
    return { changed: had, entered: null, entry: null };
  }
  const prev = store.sessions[key];
  const newTurn = ev.event === 'UserPromptSubmit';
  // 最近几步工具调用（步骤总结的输入）；新一轮请求时清空
  const prevSteps = newTurn || !prev ? [] : prev.steps;
  const addStep = ev.event === 'PreToolUse' && ev.tool;
  const steps = addStep ? prevSteps.concat([{ tool: ev.tool, detail: ev.detail || '' }]).slice(-MAX_STEPS) : prevSteps;
  const entry = {
    key,
    agent: ev.agent || 'agent',
    session: ev.session || '',
    cwd: ev.cwd || (prev && prev.cwd) || '',
    state: action.state,
    at: now,
    tool: ev.tool || '',
    detail: ev.detail || '',
    message: ev.message || '',
    focused: ev.focused === true,
    prompt: newTurn ? ev.prompt || '' : (prev && prev.prompt) || '',
    steps,
    stepSeq: ((prev && prev.stepSeq) || 0) + (addStep ? 1 : 0),
    summary: newTurn || !prev ? '' : prev.summary,
    transcript: ev.transcript || (prev && prev.transcript) || '',
    // 本轮开始时间：读会话记录时忽略更早的内容
    turnAt: newTurn || !prev ? now : prev.turnAt,
  };
  store.sessions[key] = entry;
  const entered = !prev || prev.state !== action.state ? action.state : null;
  return { changed: true, entered, entry };
}

/** 清掉过期会话，返回是否有删除 */
export function prune(store, now) {
  let removed = false;
  for (const key of Object.keys(store.sessions)) {
    const s = store.sessions[key];
    const ttl = isTerminal(s.state) ? TERMINAL_TTL_MS : STALE_TTL_MS;
    if (now - s.at > ttl) {
      delete store.sessions[key];
      removed = true;
    }
  }
  return removed;
}

/** 当前该展示的会话（优先级最高，同级取最新）；没有活跃会话返回 null */
export function current(store) {
  let best = null;
  for (const key of Object.keys(store.sessions)) {
    const s = store.sessions[key];
    if (!best || PRIORITY[s.state] > PRIORITY[best.state] || (PRIORITY[s.state] === PRIORITY[best.state] && s.at > best.at))
      best = s;
  }
  return best;
}

/** 非终态会话是否存在（定时碎碎念据此跳过，避免和正在干活的 agent 抢额度） */
export function anyBusy(store) {
  return Object.keys(store.sessions).some((k) => !isTerminal(store.sessions[k].state));
}

export const stateIndex = (state) => STATES.indexOf(state);

/** cwd → 项目名（气泡前缀） */
export function projectName(cwd) {
  if (!cwd) return '';
  const parts = String(cwd).replace(/\/+$/, '').split('/');
  return parts[parts.length - 1] || '';
}

/** 写入某会话的步骤总结（会话已结束则丢弃），返回是否写入 */
export function setSummary(store, key, text) {
  const s = store.sessions[key];
  if (!s) return false;
  s.summary = text;
  return true;
}

/**
 * 工具参数 → 气泡里的一行短文本：去掉 shell 包装，项目内路径改成相对路径，压缩空白，超长截断。
 * 例：("Bash", "npm run build") → "Bash · npm run build"
 */
export function formatDetail(tool, detail, cwd, max = 48) {
  let d = String(detail || '')
    .replace(/^(\/usr)?(\/bin\/)?(ba|z)?sh\s+-l?c\s+/, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (cwd && d.indexOf(cwd + '/') === 0) d = d.slice(cwd.length + 1);
  if (d.length > max) d = d.slice(0, max - 1) + '…';
  if (!tool) return d;
  return d ? tool + ' · ' + d : tool;
}

/**
 * agent 自己写的一段话 → 气泡里的一行：取第一段，去掉 Markdown 标记，压缩空白，超长截断。
 */
export function formatNarration(text, max = 60) {
  let t = String(text || '').trim().split(/\n\s*\n/)[0];
  t = t
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/[`*_#>]/g, '')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\s+/g, ' ')
    .trim();
  if (t.length > max) t = t.slice(0, max - 1) + '…';
  return t;
}

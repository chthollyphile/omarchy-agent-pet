// omarchy.agents 用量记录（~/.local/state/omarchy/agents/usage/<agent>.json）→ 余额动画档位 + 气泡文案。
// limits[].percent 是 0–1 的小数（omarchy agents Panel.qml 同口径）。

import { t } from './i18n.mjs';

/** 档位与 dsh-pet 的 events.balance 一致：0–4 每 20% 一档，用满（≥100%）单独为 5 */
export function tierOf(p) {
  if (!(p >= 0)) return -1;
  if (p >= 1) return 5;
  return Math.min(4, Math.floor(p * 5));
}

const SHORT_LABELS = [
  [/5-?h|session/i, () => '5h'],
  [/week|7-day/i, (lang) => t(lang, 'usageWeek')],
];

/** 5 小时窗口：倒计时精确到分钟；其余（周额度等）精确到小时 */
const isSessionWindow = (label) => /5-?h|session/i.test(label);

function shortLabel(label, lang) {
  for (const [re, short] of SHORT_LABELS) if (re.test(label)) return label.match(/fable|opus|sonnet/i) ? label : short(lang);
  return label;
}

/** 距重置的剩余时间：byMinute = 精确到分钟（向上取整），否则精确到小时（向上取整）；已过期 / 无效返回 '' */
export function formatResetIn(resetsAt, now, byMinute, lang = 'zh') {
  const unit = (key, n) => (n ? t(lang, key, { n }) : '');
  const ts = Date.parse(resetsAt);
  if (!Number.isFinite(ts) || ts <= now) return '';
  const ms = ts - now;
  if (byMinute) {
    const total = Math.ceil(ms / 60000);
    const d = Math.floor(total / 1440);
    const h = Math.floor((total % 1440) / 60);
    const m = total % 60;
    return (unit('timeDay', d) + unit('timeHour', h) + unit('timeMinute', m)).trim();
  }
  const total = Math.ceil(ms / 3600000);
  const d = Math.floor(total / 24);
  const h = total % 24;
  return (unit('timeDay', d) + unit('timeHour', h)).trim();
}

/**
 * 解析一份用量记录。返回 null = 记录不可用（缺失 / 未登录 / 没有限额窗口）。
 * { agent, name, percent, tier, text }：percent / tier 取最紧张的窗口；text 每个窗口一行，带重置倒计时。
 */
export function summarize(record, now, lang = 'zh') {
  if (!record || !Array.isArray(record.limits)) return null;
  const windows = record.limits
    .map((l) => ({ label: String(l.label || ''), percent: Number(l.percent), resetsAt: l.resetsAt || '' }))
    .filter((w) => w.percent >= 0);
  if (!windows.length) return null;
  let worst = windows[0];
  for (const w of windows) if (w.percent > worst.percent) worst = w;
  const lines = windows.map((w) => {
    const reset = formatResetIn(w.resetsAt, now, isSessionWindow(w.label), lang);
    return shortLabel(w.label, lang) + ' ' + Math.round(w.percent * 100) + '%' + (reset ? ' · ' + t(lang, 'usageResets', { time: reset }) : '');
  });
  // 数据超过 5 分钟没更新（刷新失败时只能显示旧数据）就注明
  const updated = Date.parse(record.updatedAt);
  const ageMin = Number.isFinite(updated) ? Math.floor((now - updated) / 60000) : 0;
  if (ageMin >= 5) lines.push(ageMin < 120 ? t(lang, 'usageStaleMin', { n: ageMin }) : t(lang, 'usageStaleHour', { n: Math.floor(ageMin / 60) }));
  return {
    agent: record.id || '',
    name: record.name || record.id || '',
    percent: worst.percent,
    tier: tierOf(worst.percent),
    text: [record.name || record.id].concat(lines).join('\n'),
  };
}

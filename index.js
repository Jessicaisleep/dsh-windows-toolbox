/**
 * dsh-windows-toolbox — Host half.
 *
 * Two halves that used to be two separate plugins, merged into one package at
 * the user's request (2026-11-18): 「这两个插件合为一个吧，就叫WINDOWS工具箱」.
 *
 *   manage/   — Windows 插件化管理器: the registry/registration-point
 *               inventory (services, tasks, autoruns, shell extensions,
 *               programs, AppX, drivers, firewall, IFEO, file associations,
 *               credential providers) plus the system-repair board.
 *   toolbox/  — 360-style maintenance: cleanup, large/duplicate files, network
 *               diagnosis and repair, security/privacy posture, speed test,
 *               startup tweaks, shredder, driver and software catalogs.
 *
 * The two halves stay in separate modules (`lib/host-manage.js` and
 * `lib/host-toolbox.js`) instead of being interleaved: they were written
 * independently, each already registers six or seven routes and its own set of
 * agent tools, and keeping the seam visible is what makes the next bug hunt
 * tractable. The only thing this file does is mount both, and — critically —
 * mount each one *independently*, so a webServer that is missing or a tools
 * service that failed to come up cannot take the other half down with it.
 *
 * Routes (all `kind: 'exact'`, all same-origin-trusted):
 *   GET  /dsh-windows-toolbox/api/manage/status|entries|detail
 *   POST /dsh-windows-toolbox/api/manage/refresh|action|elevated|repair
 *   GET  /dsh-windows-toolbox/api/toolbox/status|result
 *   POST /dsh-windows-toolbox/api/toolbox/run|apply|elevated|clean
 *
 * Agent tools: wpm_* (7) from the manage half, tb360_* (5) from the toolbox
 * half. The two prefixes are kept apart on purpose — 12 flat verbs named
 * `*_status` would be indistinguishable to a model reading the tool list.
 */
import { mountManage } from './lib/host-manage.js';
import { mountToolbox } from './lib/host-toolbox.js';

const ID = 'dsh-windows-toolbox';

/** Mount one half without letting its failure stop the other. */
function mountHalf(name, fn, ctx, config) {
  try {
    fn(ctx, config);
  } catch (error) {
    // Swallowing here is deliberate: the UI shows whichever half is healthy,
    // and the message lands in the host log with enough prefix to find it.
    console.warn(`[${ID}] ${name} half failed to mount:`, error?.message ?? error);
  }
}

export function apply(ctx, config) {
  mountHalf('manage', mountManage, ctx, config);
  mountHalf('toolbox', mountToolbox, ctx, config);
}

/* Anximi WebUI — KernelSU / APatch WebUI（ksu.exec），无依赖 */
'use strict';

const MOD = '/data/adb/modules/anximi';
const DATA = '/data/adb/anximi';
const ANX = `sh ${MOD}/anximi.sh`;

const METHODS = [
  ['net', '网络拦截'],
  ['disable', '禁用'],
  ['uninstall', '卸载(保留APK)'],
  ['restrict', '限制后台/权限'],
];
const METHOD_NAME = Object.fromEntries(METHODS);
const RISK_NAME = { low: '低风险', med: '中风险', high: '高风险' };
const REGION_NAME = { all: '通用', cn: '国行', global: '国际/EEA' };
const SUSPECT = /(stat|track|report|upload|analytic|\.ad|ads|advert|cloud|collect|log|feedback|telemetry|mistat|onetrack|push|sync|recommend)/i;

/* ---------------------------------------------------------------- exec */
let cbSeq = 0;
const hasKsu = typeof window.ksu !== 'undefined' && typeof window.ksu.exec === 'function';

function exec(cmd) {
  if (!hasKsu) return Promise.resolve(mockExec(cmd));
  return new Promise((resolve) => {
    const name = `__anx_cb_${Date.now()}_${cbSeq++}`;
    window[name] = (errno, stdout, stderr) => {
      delete window[name];
      resolve({ errno, stdout: stdout || '', stderr: stderr || '' });
    };
    try {
      window.ksu.exec(cmd, '{}', name);
    } catch (e) {
      delete window[name];
      resolve({ errno: -1, stdout: '', stderr: String(e) });
    }
  });
}
const sh = async (cmd) => (await exec(cmd)).stdout;
const q = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

function b64(str) {
  const bytes = new TextEncoder().encode(str);
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

function toast(msg) {
  if (hasKsu && window.ksu.toast) { try { window.ksu.toast(msg); return; } catch (e) { /* fallthrough */ } }
  const t = $('#toast');
  t.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(toast.t);
  toast.t = setTimeout(() => t.classList.add('hidden'), 2200);
}

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (v === true) el.setAttribute(k, '');
    else if (v !== false && v != null) el.setAttribute(k, v);
  }
  for (const k of kids.flat()) if (k != null) el.append(k.nodeType ? k : document.createTextNode(k));
  return el;
}

/* ---------------------------------------------------------------- 配置模型 */
const S = {
  status: {},
  cats: [],          // [{id,name,desc}]
  inv: [],           // inventory rows
  settings: [],      // settings.list rows
  confLines: [],     // config.conf 原始行
  conf: {},          // key -> value
  pkgLines: [],      // packages.conf 原始行
  pkgOv: {},         // pkg -> override
  files: {},         // 其他可编辑文件文本
  comps: [],         // 扫描到的组件
  open: new Set(),   // 展开的分类
  dirty: false,
};

function parseKv(text) {
  const map = {};
  for (const line of text.split('\n')) {
    const m = line.match(/^([A-Za-z0-9_.\-]+)=(.*)$/);
    if (m) map[m[1]] = m[2];
  }
  return map;
}

function serializeKv(lines, map) {
  const seen = new Set();
  const out = lines.map((line) => {
    const m = line.match(/^([A-Za-z0-9_.\-]+)=(.*)$/);
    if (!m) return line;
    const k = m[1];
    if (seen.has(k)) return null;
    seen.add(k);
    if (!(k in map)) return null;
    return `${k}=${map[k]}`;
  }).filter((l) => l !== null);
  for (const [k, v] of Object.entries(map)) if (!seen.has(k)) out.push(`${k}=${v}`);
  return out.join('\n').replace(/\n*$/, '\n');
}

const confList = (k) => (S.conf[k] || '').split(/[,\s]+/).filter(Boolean);
function setConfList(k, arr) { S.conf[k] = arr.join(','); markDirty(); }
function markDirty() { S.dirty = true; $('#btnSave').textContent = '保存 *'; }

/* ---------------------------------------------------------------- 加载 */
async function loadAll() {
  const [status, cats, conf, pkgs, settings, custom, chosts, ahosts, comps] = await Promise.all([
    sh(`${ANX} status`),
    sh(`cat ${MOD}/lists/categories.list`),
    sh(`cat ${DATA}/config.conf`),
    sh(`cat ${DATA}/packages.conf`),
    sh(`cat ${MOD}/lists/settings.list`),
    sh(`cat ${DATA}/custom.list`),
    sh(`cat ${DATA}/custom.hosts`),
    sh(`cat ${DATA}/allow.hosts`),
    sh(`cat ${DATA}/components.conf`),
  ]);
  S.status = parseKv(status);
  S.cats = rows(cats).map(([id, name, desc]) => ({ id, name, desc }));
  S.confLines = conf.split('\n');
  S.conf = parseKv(conf);
  S.pkgLines = pkgs.split('\n');
  S.pkgOv = parseKv(pkgs);
  S.settings = rows(settings).map(([id, ns, key, val, risk, note]) => ({ id, ns, key, val, risk, note }));
  S.files = { custom_list: custom, custom_hosts: chosts, allow_hosts: ahosts, components: comps };
  renderStatus();
  renderAdvanced();
  renderSettings();
  $('#f_components').value = comps;
  await loadInventory();
  S.dirty = false;
  $('#btnSave').textContent = '保存';
}

async function loadInventory() {
  const inv = await sh(`${ANX} inventory`);
  S.inv = rows(inv).map(([cat, pkg, allowed, region, risk, note, users, eff, own]) =>
    ({ cat, pkg, allowed: allowed.split(','), region, risk, note, users, eff, own: +own || 0 }));
  renderCats();
  $('#pkgList').replaceChildren(...S.inv.filter((r) => r.users).map((r) => h('option', { value: r.pkg })));
}

function rows(text) {
  return text.split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#')).map((l) => l.split('|'));
}

/* ---------------------------------------------------------------- 渲染：概览 */
function renderStatus() {
  const s = S.status;
  const applied = ['disable', 'uninstall', 'appops', 'perms', 'bucket', 'comp', 'setting']
    .map((k) => +s[`applied_${k}`] || 0);
  const total = applied.reduce((a, b) => a + b, 0);
  const regionName = { cn: '国行', global: '国际版', eea: '欧版 EEA' }[s.region] || s.region;
  $('#sub').textContent = `${s.version || ''} · ${s.root || ''} · ${regionName || ''}`;
  const items = [
    ['设备', s.mod_device || '-'],
    ['系统', `${s.os || ''} / Android ${s.android || '?'}`],
    ['用户', `${(s.users_target || '-').trim()}（设备共有 ${(s.users_all || '-').trim()}）`],
    ['网络后端', `${s.backend}${s.backend === 'bpf' && s.bpf_supported !== '1' ? '（系统不支持，回落 iptables）' : ''}`],
    ['iptables', s.ipt_hooked === '1' ? `已挂载 · ${s.net_uids} 个 UID` : '未挂载'],
    ['hosts', s.hosts_file === '-' ? '未启用' : `模块 ${s.hosts_file} 条 · 系统当前 ${s.hosts_live} 条`],
    ['已接管改动', `${total}（禁用 ${applied[0]} · 卸载 ${applied[1]} · 后台 ${applied[2]} · 权限 ${applied[3]} · 分组 ${applied[4]} · 组件 ${applied[5]} · 设置 ${applied[6]}）`],
    ['上次应用', s.last_apply || '从未'],
    ['Surfing', s.surfing === '1' ? '已安装（兼容模式：只用 filter 表自有链）' : '未检测到'],
  ];
  if (s.net_skipped) items.push(['仅 hosts 拦截', s.net_skipped.replace(/;$/, '').replace(/;/g, '，')]);
  $('#status').replaceChildren(...items.flatMap(([k, v]) => [h('dt', {}, k), h('dd', {}, v)]));
  const b = $('#banner');
  if (s.rescue) {
    b.className = 'banner warn';
    b.textContent = `防砖保护已触发：${s.rescue}。检查最近启用的分类后再应用。`;
  } else if (!s.last_apply) {
    b.className = 'banner';
    b.textContent = '尚未应用过。选好分类与手段后点「保存并应用」。';
  } else b.className = 'banner hidden';
}

/* ---------------------------------------------------------------- 渲染：分类 */
function renderCats() {
  const onlyInstalled = $('#onlyInstalled').checked;
  $('#risk_level').value = S.conf.risk_level || 'low';
  const box = $('#cats');
  box.replaceChildren();
  for (const c of S.cats) {
    const methods = confList(`cat_${c.id}`);
    const items = S.inv.filter((r) => r.cat === c.id);
    const inst = items.filter((r) => r.users && !r.users.startsWith('('));
    const active = items.filter((r) => !r.eff.startsWith('skip') && r.users);
    const chips = METHODS.map(([m, label]) => h('button', {
      class: `chip${methods.includes(m) ? ' on' : ''}`,
      onclick: () => {
        let cur = confList(`cat_${c.id}`);
        if (cur.includes(m)) cur = cur.filter((x) => x !== m);
        else {
          cur.push(m);
          if (m === 'uninstall') cur = cur.filter((x) => x !== 'disable');
          if (m === 'disable') cur = cur.filter((x) => x !== 'uninstall');
        }
        setConfList(`cat_${c.id}`, METHODS.map(([k]) => k).filter((k) => cur.includes(k)));
        previewEff();
        renderCats();
      },
    }, label));
    const list = (onlyInstalled ? inst : items).map(pkgRow);
    box.append(h('div', { class: 'card' },
      h('div', { class: 'cat-head' },
        h('div', {}, h('h2', {}, c.name), h('p', { class: 'muted' }, c.desc)),
        h('span', { class: 'count' }, `${active.length}/${inst.length} 生效`)),
      h('div', { class: 'chips' }, chips),
      h('details', { open: S.open.has(c.id), ontoggle: (e) => { if (e.target.open) S.open.add(c.id); else S.open.delete(c.id); } },
        h('summary', {}, `组件清单（${onlyInstalled ? `已安装 ${inst.length}` : `共 ${items.length}`}）`),
        list.length ? list : h('p', { class: 'muted' }, '本机未安装此分类的任何组件'))));
  }
}

function pkgRow(r) {
  const ov = S.pkgOv[r.pkg] || '';
  const sel = h('select', {
    onchange: (e) => {
      if (e.target.value) S.pkgOv[r.pkg] = e.target.value; else delete S.pkgOv[r.pkg];
      markDirty(); previewEff(); renderCats();
    },
  },
  h('option', { value: '' }, '跟随分类'),
  h('option', { value: 'skip' }, '跳过'),
  h('option', { value: 'include' }, '强制包含'),
  h('option', { value: 'only:net' }, '只断网'),
  h('option', { value: 'only:net,restrict' }, '断网+限制'),
  h('option', { value: 'only:net,disable,restrict' }, '断网+禁用+限制'));
  if (ov && ![...sel.options].some((o) => o.value === ov)) sel.append(h('option', { value: ov }, ov));
  sel.value = ov;
  const eff = r.eff.startsWith('skip')
    ? h('span', { class: 'badge skip' }, r.eff.slice(5))
    : h('span', { class: 'badge eff' }, r.eff.split(',').map((m) => METHOD_NAME[m] || m).join(' + '));
  return h('div', { class: 'pkg' },
    h('div', {}, h('div', { class: 'name' }, r.note || r.pkg), h('div', { class: 'id' }, r.pkg)),
    sel,
    h('div', { class: 'badges' },
      h('span', { class: `badge ${r.risk}` }, RISK_NAME[r.risk] || r.risk),
      h('span', { class: 'badge' }, REGION_NAME[r.region] || r.region),
      h('span', { class: 'badge' }, r.users ? `用户 ${r.users}` : '未安装'),
      h('span', { class: 'badge' }, `可用：${r.allowed.map((m) => METHOD_NAME[m] || m).join('/')}`),
      eff,
      r.own ? h('span', { class: 'badge low' }, `已接管 ${r.own} 项`) : null));
}

/* 在前端按与脚本相同的规则预估“实际手段”，保存前即可看到效果 */
const RISKN = { low: 1, med: 2, high: 3 };
const PROTECTED = new Set(['com.miui.securitycenter', 'com.lbe.security.miui', 'com.miui.powerkeeper', 'com.miui.core',
  'com.miui.global.packageinstaller', 'com.miui.packageinstaller']);
function previewEff() {
  for (const r of S.inv) {
    let m = confList(`cat_${r.cat}`);
    const ov = S.pkgOv[r.pkg] || '';
    if (!m.length) { r.eff = 'skip:分类未启用'; continue; }
    if (ov === 'skip') { r.eff = 'skip:已设为跳过'; continue; }
    if (ov !== 'include' && !ov.startsWith('only:') && RISKN[r.risk] > RISKN[S.conf.risk_level || 'low']) {
      r.eff = `skip:风险 ${r.risk} 高于阈值`; continue;
    }
    if (ov.startsWith('only:')) m = ov.slice(5).split(',');
    let out = METHODS.map(([k]) => k).filter((k) => m.includes(k) && r.allowed.includes(k));
    if (PROTECTED.has(r.pkg)) out = out.filter((k) => k === 'net');
    if (out.includes('uninstall')) out = out.filter((k) => k !== 'disable');
    r.eff = out.length ? out.join(',') : 'skip:无可用手段';
  }
}

/* ---------------------------------------------------------------- 渲染：本地采集 */
function renderSettings() {
  const on = new Set(confList('settings'));
  $('#settings').replaceChildren(...S.settings.map((s) => h('label', { class: 'setting' },
    h('input', {
      type: 'checkbox', checked: on.has(s.id),
      onchange: (e) => {
        const cur = new Set(confList('settings'));
        if (e.target.checked) cur.add(s.id); else cur.delete(s.id);
        setConfList('settings', [...cur]);
      },
    }),
    h('span', {}, s.note, s.risk !== 'low' ? h('span', { class: `badge ${s.risk}` }, ` ${RISK_NAME[s.risk]}`) : null),
    h('span', { class: 'k' }, `${s.ns} ${s.key} = ${s.val}`))));
}

function compSet() {
  return new Set($('#f_components').value.split('\n').map((l) => l.replace(/#.*/, '').trim()).filter(Boolean));
}

function renderComps() {
  const set = compSet();
  const filt = $('#compFilter').checked;
  const list = S.comps.filter((c) => !filt || SUSPECT.test(c.split('/')[1] || '') || set.has(c));
  $('#compList').replaceChildren(...(list.length ? list.map((c) => h('label', {},
    h('input', {
      type: 'checkbox', checked: set.has(c),
      onchange: (e) => {
        const lines = $('#f_components').value.split('\n').filter((l) => l.trim() !== c);
        if (e.target.checked) lines.push(c);
        $('#f_components').value = lines.join('\n').replace(/\n*$/, '\n');
        markDirty();
      },
    }), c)) : [h('p', { class: 'muted' }, S.comps.length ? '没有匹配的疑似采集组件，取消过滤查看全部' : '未扫描到组件')]));
}

/* ---------------------------------------------------------------- 渲染：高级 */
function renderAdvanced() {
  const s = S.status;
  const all = (s.users_all || '0').trim().split(/\s+/).filter(Boolean);
  const want = S.conf.users || 'all';
  const sel = want === 'all' ? new Set(all) : new Set(want.split(/[,\s]+/));
  const box = $('#users');
  const allBox = h('label', { class: 'check' }, h('input', {
    type: 'checkbox', checked: want === 'all',
    onchange: (e) => { S.conf.users = e.target.checked ? 'all' : all.join(' '); markDirty(); renderAdvanced(); },
  }), '全部用户（自动包含之后新建的第二空间/Island）');
  box.replaceChildren(allBox, ...all.map((u) => h('label', { class: 'check' }, h('input', {
    type: 'checkbox', checked: sel.has(u), disabled: want === 'all',
    onchange: (e) => {
      const cur = new Set((S.conf.users || '').split(/[,\s]+/).filter((x) => x && x !== 'all'));
      if (e.target.checked) cur.add(u); else cur.delete(u);
      S.conf.users = [...cur].join(' ') || '0';
      markDirty();
    },
  }), `用户 ${u}${s[`user_name_${u}`] ? `（${s[`user_name_${u}`]}）` : ''}`)));

  for (const k of ['net_backend', 'net_target', 'region']) $(`#${k}`).value = S.conf[k] || $(`#${k}`).options[0].value;
  for (const k of ['hosts', 'net_watchdog', 'boot_apply', 'components']) $(`#${k}`).checked = (S.conf[k] ?? '1') === '1';
  $('#mihomo_export_dir').value = S.conf.mihomo_export_dir || '';
  $('#f_custom_list').value = S.files.custom_list || '';
  $('#f_custom_hosts').value = S.files.custom_hosts || '';
  $('#f_allow_hosts').value = S.files.allow_hosts || '';
}

/* ---------------------------------------------------------------- 保存 / 执行 */
async function put(name, text) {
  const r = await exec(`${ANX} put ${name} ${b64(text)}`);
  if (!r.stdout.includes('ok')) throw new Error(`${name}: ${r.stdout || r.stderr}`);
}

async function save() {
  const pk = {};
  for (const [k, v] of Object.entries(S.pkgOv)) if (v) pk[k] = v;
  try {
    await put('config.conf', serializeKv(S.confLines, S.conf));
    await put('packages.conf', serializeKv(S.pkgLines, pk));
    await put('custom.list', $('#f_custom_list').value);
    await put('custom.hosts', $('#f_custom_hosts').value);
    await put('allow.hosts', $('#f_allow_hosts').value);
    await put('components.conf', $('#f_components').value);
    S.dirty = false;
    $('#btnSave').textContent = '保存';
    toast('已保存');
    return true;
  } catch (e) {
    toast(`保存失败：${e.message}`);
    return false;
  }
}

async function runBg(title, args) {
  const r = await sh(`${ANX} bg ${args}`);
  if (r.includes('busy')) { toast('已有任务在运行'); return; }
  const ov = $('#overlay');
  $('#ovTitle').textContent = title;
  $('#ovLine').textContent = '启动中…';
  $('#ovLog').textContent = '';
  $('#ovClose').disabled = true;
  ov.classList.remove('hidden');
  const t0 = Date.now();
  for (;;) {
    await new Promise((res) => setTimeout(res, 900));
    const p = await sh(`${ANX} progress; echo; ${ANX} log 30`);
    const [prog, ...logLines] = p.split('\n@');
    const lines = prog.trim().split('\n');
    $('#ovLine').textContent = lines[lines.length - 1] || '';
    const rest = logLines.join('\n@');
    const running = rest.startsWith('running');
    $('#ovLog').textContent = rest.replace(/^(running|idle)\n?/, '');
    $('#ovLog').scrollTop = 1e9;
    if (!running && Date.now() - t0 > 1500) break;
  }
  $('#ovTitle').textContent = `${title} · 完成`;
  $('#ovClose').disabled = false;
  await loadAll();
}

/* ---------------------------------------------------------------- 事件 */
function bind() {
  $$('.tab').forEach((t) => t.addEventListener('click', () => {
    $$('.tab').forEach((x) => x.classList.toggle('active', x === t));
    $$('.panel').forEach((p) => p.classList.toggle('active', p.id === `tab-${t.dataset.tab}`));
    if (t.dataset.tab === 'log') refreshLog();
  }));
  $('#onlyInstalled').addEventListener('change', renderCats);
  $('#risk_level').addEventListener('change', (e) => { S.conf.risk_level = e.target.value; markDirty(); previewEff(); renderCats(); });
  for (const k of ['net_backend', 'net_target', 'region']) {
    $(`#${k}`).addEventListener('change', (e) => { S.conf[k] = e.target.value; markDirty(); });
  }
  for (const k of ['hosts', 'net_watchdog', 'boot_apply', 'components']) {
    $(`#${k}`).addEventListener('change', (e) => { S.conf[k] = e.target.checked ? '1' : '0'; markDirty(); });
  }
  $('#mihomo_export_dir').addEventListener('input', (e) => { S.conf.mihomo_export_dir = e.target.value.trim(); markDirty(); });
  for (const id of ['f_custom_list', 'f_custom_hosts', 'f_allow_hosts', 'f_components']) $(`#${id}`).addEventListener('input', markDirty);
  $('#f_components').addEventListener('input', renderComps);
  $('#compFilter').addEventListener('change', renderComps);
  $('#compScan').addEventListener('click', async () => {
    const pkg = $('#compPkg').value.trim();
    if (!/^[A-Za-z0-9_.]+$/.test(pkg)) { toast('包名格式不对'); return; }
    S.comps = (await sh(`${ANX} components ${q(pkg)}`)).split('\n').map((x) => x.trim()).filter(Boolean);
    renderComps();
  });
  $$('[data-preset]').forEach((b) => b.addEventListener('click', async () => {
    if (S.dirty && !(await save())) return;
    await sh(`${ANX} preset ${b.dataset.preset}`);
    await loadAll();
    toast(`已切换到「${b.textContent.trim().slice(0, 2)}」预设，尚未应用`);
  }));
  $('#btnSave').addEventListener('click', save);
  $('#btnApply').addEventListener('click', async () => { if (await save()) runBg('应用配置', 'apply'); });
  $('#btnRevert').addEventListener('click', () => {
    const b = $('#btnRevert');
    if (b.dataset.armed) { delete b.dataset.armed; b.textContent = '全部还原'; runBg('全部还原', 'revert'); return; }
    b.dataset.armed = '1'; b.textContent = '再点一次确认';
    setTimeout(() => { delete b.dataset.armed; b.textContent = '全部还原'; }, 3000);
  });
  $('#ovClose').addEventListener('click', () => $('#overlay').classList.add('hidden'));
  $('#logRefresh').addEventListener('click', refreshLog);
  $('#exportMihomo').addEventListener('click', async () => {
    if (S.dirty && !(await save())) return;
    const out = await sh(`${ANX} export-mihomo`);
    toast(out.trim().split('\n').pop() || '已导出');
  });
  $('#discover').addEventListener('click', async () => {
    const out = await sh(`${ANX} discover`);
    const pre = $('#discoverOut');
    pre.classList.remove('hidden');
    pre.textContent = out.trim() || '没有发现清单外的小米系包';
  });
}

async function refreshLog() { $('#log').textContent = await sh(`${ANX} log 400`) || '（空）'; $('#log').scrollTop = 1e9; }

/* ---------------------------------------------------------------- 浏览器预览用的模拟数据 */
function mockExec(cmd) {
  const M = mockExec.files || (mockExec.files = {
    status: 'version=v0.1.0\nroot=KernelSU\nregion=eea\nmod_device=songyuan_eea_global\nos=OS3.0.3.0\nandroid=16\nusers_all=0 10 \nusers_target=0 10\nuser_name_0=机主\nuser_name_10=Island\nbackend=iptables\nbpf_supported=1\nipt_hooked=1\nnet_uids=14\nnet_skipped=com.miui.daemon (uid 1000);com.miui.securitycenter (uid 1000);\nhosts_file=48\nhosts_live=48\napplied_disable=12\napplied_uninstall=0\napplied_appops=10\napplied_perms=10\napplied_bucket=4\napplied_comp=0\napplied_setting=4\nlast_apply=2026-11-24 20:10:00\nrescue=\nsurfing=1\nrunning=0\n',
    categories: 'ads|广告|系统广告服务 (MSA/MAB)、负一屏、壁纸轮播、应用商店推荐等\ntelemetry|遥测与统计|MIUI 统计分析、系统事件上报、错误报告\ncloudctl|云控|服务器下发性能/温控/后台策略\nseccloud|安全云检测|病毒云查、安装时云扫描\nai|AI 与内容识别上传|传送门/Taplus、AI 字幕、语音唤醒\ncloud|小米账号与云服务|云备份/同步、推送、查找设备\n',
    config: 'cat_ads=net,disable,restrict\ncat_telemetry=net,disable,restrict\ncat_cloudctl=net\ncat_seccloud=net\ncat_ai=net,disable,restrict\ncat_cloud=\nrisk_level=low\nusers=all\nregion=auto\nnet_backend=iptables\nnet_target=REJECT\nnet_watchdog=1\nhosts=1\nsettings=wifi_scan,ble_scan,ux_program,ux_debuglog\ncomponents=1\nboot_apply=1\nmihomo_export_dir=\n',
    inventory: 'ads|com.miui.msa.global|net,disable,uninstall,restrict|global|low|MSA 系统广告服务（国际/EEA）|0,10|net,disable,restrict|6\nads|com.mi.globalminusscreen|net,disable,uninstall,restrict|global|low|App Vault 负一屏|0|net,disable,restrict|3\nads|com.xiaomi.mipicks|net,disable,uninstall|global|med|GetApps 应用商店|0,10|skip:风险 med 高于阈值|0\ntelemetry|com.miui.analytics|net,disable,uninstall,restrict|all|low|MIUI Analytics 统计分析|0,10|net,disable,restrict|6\ntelemetry|com.miui.daemon|net,disable,restrict|all|low|MIUI 守护进程|0,10|net,disable,restrict|6\ncloudctl|com.xiaomi.joyose|net,disable,restrict|all|med|Joyose 云控|0,10|skip:风险 med 高于阈值|0\ncloudctl|com.miui.powerkeeper|net|all|low|电量与性能（核心，只允许断网）|0,10|net|0\nseccloud|com.miui.securitycenter|net|all|low|安全中心（核心，只允许断网）|0,10|net|0\nseccloud|com.miui.guardprovider|net,disable,restrict|all|med|安全扫描引擎|0,10|skip:风险 med 高于阈值|0\nai|com.miui.contentextension|net,disable,uninstall,restrict|all|low|传送门 / Taplus|0,10|net,disable,restrict|6\ncloud|com.xiaomi.xmsf|net,disable,restrict|all|med|小米服务框架（推送）|0,10|skip:分类未启用|0\n',
    settings: 'wifi_scan|global|wifi_scan_always_enabled|0|low|关闭“WLAN 扫描”\nble_scan|global|ble_scan_always_enabled|0|low|关闭“蓝牙扫描”\nagps|global|assisted_gps_enabled|0|med|关闭 A-GPS 辅助定位\n',
  });
  let out = '';
  if (cmd.includes(' put ')) out = 'ok';
  else if (cmd.endsWith(' status')) out = M.status;
  else if (cmd.includes('categories.list')) out = M.categories;
  else if (cmd.includes('config.conf')) out = M.config;
  else if (cmd.endsWith(' inventory')) out = M.inventory;
  else if (cmd.includes('settings.list')) out = M.settings;
  else if (cmd.includes(' components ')) out = 'com.miui.securitycenter/com.miui.securityscan.cloud.CloudUploadService\ncom.miui.securitycenter/com.miui.permcenter.MainActivity\n';
  else if (cmd.includes(' bg ')) out = 'started';
  else if (cmd.includes(' progress')) out = '完成：已接管 36 项改动\n@idle\n2026-11-24 20:10:00 完成';
  else if (cmd.includes(' log')) out = '2026-11-24 20:10:00 （浏览器预览模式，未连接 KernelSU）';
  return { errno: 0, stdout: out, stderr: '' };
}

bind();
loadAll().catch((e) => toast(`加载失败：${e.message}`));
if (!hasKsu) setTimeout(() => toast('浏览器预览模式：未检测到 KernelSU WebUI 接口'), 300);

#!/usr/bin/env node
/**
 * Capture the real deepseek-harness web UI: index, boot graph, plugin bundles, assets.
 * Raw URLs contain `plugins/??@scope/...` which cannot survive HTTP path routing
 * (`?` starts a query string), so every reference is sanitized to `__` on disk and
 * in all served files; the iOS server then serves byte-identical paths.
 */
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { createHash } from 'node:crypto'

const base = (process.argv[2] ?? 'http://127.0.0.1:3117').replace(/\/+$/, '')
const out = process.argv[3] ?? 'webui-capture'
const cookieFile = process.argv[4] ?? join(out, '.cookies')

// combo URL（一串 , 分隔的模块）路径太长，落盘时映射成 combo-<md5>.js；
// 引用重写也走同一映射，保证运行时按本地路径命中。
const COMBO_RE = /\/?plugins\/\?\?[^"'`\s]+(?:&amp;|&)rev=[a-f0-9]+/g
const comboName = (raw) => 'plugins/combo-' + createHash('md5').update(raw.replace(/^\//, '').replace(/&amp;/g, '&')).digest('hex').slice(0, 16) + '.js'
const sanitize = (u) => {
  let s = String(u).trim().replace(/^\//, '')
  const m = s.match(COMBO_RE)
  if (m && m[0] === s) return comboName(s)
  s = s.replace(COMBO_RE, (r) => comboName(r))
  s = s.replace(/[?#]/g, '_')
  for (const seg of ['rev=', '_rev_', '&', ';']) s = s.split(seg)[0]
  return s
}
const serverPath = (u) => {
  // Host 端用 pathname+search 原样拼接匹配（combo URL 的 ??/rev 都在 search 里），
  // 所以必须逐字回放原始 URL，任何编码或剥 rev 都会 404。
  const s = u.trim()
  return s.startsWith('/') ? s : '/' + s
}
const urlCollect = (from) => {
  const into = new Set()
  for (const m of from.matchAll(/["'`](\/(?:assets|plugins|fonts)\/[^"'`\s]*|\.\/(?:assets|fonts)\/[^"'`\s]*)["'`]/g)) {
    let u = m[1].replace(/^\.\//, '/')
    if (u.startsWith('//')) continue
    into.add(u)
  }
  return into
}

let cookie = ''
if (existsSync(cookieFile)) {
  for (const line of readFileSync(cookieFile, 'utf8').split('\n')) {
    if (line.includes('dsh-auth-')) {
      const cols = line.split('\t')
      if (cols.length >= 7) cookie += cols[5] + '=' + cols[6] + '; '
    }
  }
}
const headers = cookie ? { cookie: cookie.trim() } : {}

mkdirSync(out, { recursive: true })
const rawIndex = readFileSync(join(out, 'index.html'), 'utf8')

// ---- parse boot graph first so its sanitized JSON can be inlined back ----
const refs = urlCollect(rawIndex)
const bootMatch = /globalThis\[["']__DSH_BOOT__["']\]\s*=\s*(\{[\s\S]*?\})\s*<\/script>/.exec(rawIndex)
  ?? /globalThis\.__DSH_BOOT__\s*=\s*(\{[\s\S]*?\})\s*<\/script>/.exec(rawIndex)
let graphJson = null
if (bootMatch) {
  try {
    const graph = JSON.parse(bootMatch[1])
    for (const e of graph.entries ?? []) refs.add(e.url)
    for (const b of graph.batches ?? []) refs.add(b.url)
    graphJson = JSON.stringify({
      ...graph,
      entries: (graph.entries ?? []).map(e => ({ ...e, url: sanitize(e.url) })),
      batches: (graph.batches ?? []).map(b => ({ ...b, url: sanitize(b.url) })),
    })
    writeFileSync(join(out, '__DSH_BOOT__.json'), graphJson)
    console.log('boot graph entries:', (graph.entries ?? []).length, 'batches:', (graph.batches ?? []).length)
  } catch (e) { console.error('boot graph parse failed:', e.message) }
} else {
  console.error('WARN: __DSH_BOOT__ global not found in index.html')
}

// ---- rewrite index.html so every reference matches sanitized disk paths ----
const revStrip = rawIndex.replace(/(["'`])\/?[^"'`]*?&(?:amp;)?rev=[a-f0-9]+(?=\1)/g, '$1')
const comboStrip = revStrip.replace(COMBO_RE, (r) => comboName(r))
const bootRewrite = graphJson !== null
  ? comboStrip.replace(/(globalThis\[["']__DSH_BOOT__["']\]\s*=\s*)\{[\s\S]*?\}(\s*<\/script>)/, `$1${graphJson}$2`)
  : comboStrip
const sanitizedIndex = bootRewrite.replace(/\/?plugins\/\?\?/g, m => m.startsWith('/') ? '/plugins/__' : 'plugins/__').replace(/\/?plugins\/\?(?=[A-Za-z0-9_@])/g, m => m.startsWith('/') ? '/plugins/_' : 'plugins/_')
writeFileSync(join(out, 'index.html'), sanitizedIndex)
const indexHtml = sanitizedIndex
for (const extra of ['/manifest.webmanifest', '/favicon.svg', '/favicon-dark.svg']) refs.add(extra)

const fetched = new Map()
const SKIPPED = new Set(['/plugins/events'])
async function fetchPath(u) {
  if (fetched.has(u)) return 0
  fetched.set(u, 0)
  if (SKIPPED.has(u)) { console.log(`SKIP ${u}`); return 0 }
  const res = await fetch(base + serverPath(u), { headers, signal: AbortSignal.timeout(20000) })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  let buf = Buffer.from(await res.arrayBuffer())
  const fsPath = join(out, sanitize(u))
  // rewrite nested references so runtime stays local-safe
  const text = buf.toString('utf8')
  const rewritten = text.replace(/\/plugins\/\?\?[^"'`\s]+&rev=[a-f0-9]+/g, (r) => '/' + comboName(r))
    .replace(/\/plugins\/\?\?/g, '/plugins/__')
    .replace(/\/plugins\/\?(?=[A-Za-z0-9_@])/g, '/plugins/_')
  if (rewritten !== text) buf = Buffer.from(rewritten, 'utf8')
  mkdirSync(dirname(fsPath), { recursive: true })
  writeFileSync(fsPath, buf)
  const n = buf.length
  fetched.set(u, n)
  // discover nested local paths from this file (js/css/json)
  for (const r of urlCollect(rewritten)) if (!fetched.has(r)) refs.add(r)
  return n
}

let total = 0
const failures = []
for (let pass = 0; pass < 10; pass++) {
  const queue = [...refs].filter(u => !fetched.has(u)).map(u => u).sort()
  if (!queue.length) break
  console.log(`-- pass ${pass}: ${queue.length} urls`)
  for (const p of queue) {
    try {
      const n = await fetchPath(p)
      total += n
      console.log(`OK  ${sanitize(p)} (${n})`)
    } catch (e) {
      failures.push(p)
      console.error(`ERR ${p}: ${e.message}`)
    }
  }
}
writeFileSync(join(out, 'failed.txt'), failures.join('\n'))
console.log(`\ncaptured ${fetched.size - failures.length}/${fetched.size} resources, ${total} bytes`)
if (failures.length) { console.error('FAILURES:', failures.slice(0, 12)); process.exit(1) }

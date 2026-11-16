import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderChildren } from 'claude-code'

import type {
  CatalogEntry,
  FrameStrip,
  PreviewCatalog,
  PreviewError,
  PreviewFrame,
  PreviewHostInfo,
  PreviewInfo,
  PreviewSession,
  PreviewStatus,
  PreviewTab,
  RendererMode,
  SimDevice,
} from '../types'

// swiftpreview (tools/swiftpreview) does the work: it builds the Bazel preview
// host, generates @_dynamicReplacement thunks on every save and asks the host
// to render. This mod runs one `swiftpreview serve` per SwiftUI Preview pane
// (tab), draws its frames, lists the workspace's previews (`swiftpreview
// discover`), and tells Claude how each Swift edit compiled and rendered. The
// model's swiftui_preview tool is `swiftpreview mcp` (.mcp.json), which renders
// through this session's panes while they run.

/** The first pane's id; more tabs are `swiftui-preview-2`, `-3`, … */
const PANE = 'swiftui-preview'
/** Names developers see for the host's two ways of drawing a frame. */
const RENDERERS: Record<RendererMode, { label: string; about: string }> = {
  auto: { label: 'Auto', about: 'SwiftUI renderer, or Window snapshot when the view has AppKit controls' },
  swiftui: { label: 'SwiftUI renderer', about: "SwiftUI's own ImageRenderer: exact shapes, but AppKit controls draw as placeholders" },
  window: { label: 'Window snapshot', about: 'AppKit cacheDisplay of the host window: draws every control; stroked capsules can show tick marks' },
}
const MODES: RendererMode[] = ['auto', 'swiftui', 'window']

/** Commands that open a file at a line, by the plugin's `editor` option. */
const EDITORS: Record<string, (file: string, line: number) => string[]> = {
  xcode: (file, line) => ['xed', '--line', String(line), file],
  vscode: (file, line) => ['code', '-g', `${file}:${line}`],
  cursor: (file, line) => ['cursor', '-g', `${file}:${line}`],
  default: file => ['open', file],
}

function rendererLabel(r: string | undefined): string {
  return r === 'swiftui' || r === 'window' ? RENDERERS[r].label : (r ?? 'unknown')
}

/** Pane magnification steps, in percent. */
const ZOOMS = [25, 50, 75, 100]

const BUSY = ['xcode', 'starting', 'building', 'querying', 'launching', 'compiling', 'rebuilding', 'rendering']

const tabs = atom({ plugin: 'swiftui-previews', key: 'tabs' } as const, {}, { shape: 'tabs-1' })

function emptyTab(): PreviewTab {
  return { session: null, status: { phase: 'idle', message: '' }, frame: null, error: null, host: null, catalog: null }
}

function deviceLabel(d: SimDevice): string {
  return `${d.name} · ${d.runtime}`
}

/** One JSON line of `swiftpreview serve` / `snapshot` output. */
type Event = {
  event: 'status' | 'frame' | 'error' | 'host' | 'exit'
  phase?: string
  message?: string
  file?: string
  previews?: PreviewInfo[]
  selected?: number
  png?: string
  jpeg?: string
  width?: number
  height?: number
  reload?: string
  timings?: { compile?: number; load?: number; render?: number }
  seq?: number
  renderer?: string
  rendererReason?: string
  platform?: string
  devices?: SimDevice[]
  device?: string
  strips?: FrameStrip[]
  stripWidth?: number
  hosts?: string[]
}

/** `swiftpreview discover` output. */
type Discovery = {
  workspace: string
  workspaces?: string[]
  hosts: string[]
  files: { file: string; workspace?: string; hosts: string[]; previews: { index: number; name: string; line: number }[] }[]
}

type Options = {
  swiftpreviewPath?: string
  editor?: string
  discoverPreviews?: boolean
  keepHostMinutes?: number
  simulatorIdleMinutes?: number
  watch?: string
  pollIntervalMs?: number
  watchEventsAbove?: number
}

type ChildStream = { return?: (value?: unknown) => unknown }

/** What a tab keeps outside `$.state`: its child and caches. */
type TabRuntime = {
  /** The running `swiftpreview serve`: leaving its loop kills it. */
  child: ChildStream | null
  /** Bumped on every frame or error, so a waiter can tell a fresh result. */
  results: number
  /** The latest frame's strips as SVG sources, so a redraw reads no files. */
  strips: { seq: number; sources: string[] }
  /** The title last given the tab. */
  title?: string
  /** When discovery last ran (ms), so a redraw doesn't rerun it. */
  discoveredAt: number
}

// Module state starts over when the module reloads; the children die with it.
const ctx = {
  binary: 'swiftpreview',
  editor: 'xcode',
  /** Run `swiftpreview discover` for the pickers on every start (else on request). */
  discoverPreviews: false,
  /** Extra `swiftpreview serve` flags from the plugin's options. */
  serveFlags: [] as string[],
  cwd: '.',
  controlId: Date.now(),
  waiters: [] as Array<() => void>,
  lastSwiftFile: null as string | null,
  runtime: {} as Record<string, TabRuntime>,
}

function rt(id: string): TabRuntime {
  ctx.runtime[id] ??= { child: null, results: 0, strips: { seq: -1, sources: [] }, discoveredAt: 0 }
  return ctx.runtime[id]
}

async function readTab($: EngineInterface, id: string): Promise<PreviewTab> {
  return (await read($, tabs))[id] ?? emptyTab()
}

async function updateTab($: EngineInterface, id: string, fn: (t: PreviewTab) => PreviewTab): Promise<void> {
  await update($, tabs, all => ({ ...all, [id]: fn(all[id] ?? emptyTab()) }))
}

/** The session folder for a tab: `.swiftpreview/claude` for the first, `claude-2`, … */
function sessionDirFor(id: string): string {
  const n = id === PANE ? '' : id.slice(PANE.length)
  return `${ctx.cwd}/.swiftpreview/claude${n}`
}

/** A pane id no tab uses. */
async function newTabId($: EngineInterface): Promise<string> {
  const all = await read($, tabs)
  const open = new Set((await $.ui.panes()).map(p => p.id))
  if (!all[PANE]?.session?.isRunning && !open.has(PANE)) return PANE
  for (let n = 2; ; n++) {
    const id = `${PANE}-${n}`
    if (!all[id]?.session?.isRunning && !open.has(id)) return id
  }
}

/** One strip as an SVG document holding its image (at most 131,072 characters). */
function stripSvg(width: number, s: FrameStrip, base64: string): string {
  const w = Math.round(width)
  const ht = s.height
  const mime = s.format === 'png' ? 'image/png' : 'image/jpeg'
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" ` +
    `width="${w}" height="${ht}" viewBox="0 0 ${w} ${ht}">` +
    `<image width="${w}" height="${ht}" preserveAspectRatio="none" href="data:${mime};base64,${base64}"/></svg>`
  )
}

/** Reads a frame's strips into SVG sources (cached per tab and frame). */
async function stripSources($: EngineInterface, id: string, f: PreviewFrame): Promise<string[]> {
  if (!f.strips?.length) return []
  const r = rt(id)
  if (r.strips.seq === f.seq) return r.strips.sources
  const sources: string[] = []
  for (const s of f.strips) {
    // A device-framed strip is a whole SVG already: the vector bezel, sharp at
    // any size, with the screen's slice embedded.
    if (s.format === 'svg') {
      sources.push(String(await $.fs.read(s.path)))
      continue
    }
    const bytes = await $.fs.read(s.path, { as: 'bytes' })
    sources.push(stripSvg(f.stripWidth ?? f.width, s, bytes.base64))
  }
  r.strips = { seq: f.seq, sources }
  return sources
}

/** Text the pane may draw: no ANSI colors or other control characters
 * (Bazel's and the compiler's output carry them; a surface refuses them). */
function printable(text: string): string {
  // eslint-disable-next-line no-control-regex
  return text.replace(/\u001b\[[0-9;?]*[ -\/]*[@-~]/g, '').replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '')
}

function absolute(p: string): string {
  return p.startsWith('/') ? p : `${ctx.cwd}/${p}`.replace(/\/\.\//g, '/')
}

function basename(p: string): string {
  return p.split('/').pop() ?? p
}

function dirname(p: string): string {
  const i = p.lastIndexOf('/')
  return i > 0 ? p.slice(0, i) : '/'
}

function notify(id: string): void {
  rt(id).results += 1
  for (const w of ctx.waiters.splice(0)) w()
}

/** Resolves true on the next frame or error in any tab, false after `ms`. */
function nextResult($: EngineInterface, ms: number): Promise<boolean> {
  return new Promise<boolean>(resolve => {
    let done = false
    ctx.waiters.push(() => {
      if (!done) {
        done = true
        resolve(true)
      }
    })
    void $.clock.sleep(ms).then(() => {
      if (!done) {
        done = true
        resolve(false)
      }
    })
  })
}

/** Writes a command where the tab's swiftpreview polls for it. */
async function send($: EngineInterface, id: string, cmd: Record<string, unknown>): Promise<boolean> {
  const s = (await readTab($, id)).session
  if (!s?.isRunning) return false
  ctx.controlId += 1
  await $.fs.write(`${s.sessionDir}/control.json`, JSON.stringify({ ...cmd, id: ctx.controlId }))
  return true
}

async function handleEvent($: EngineInterface, id: string, ev: Event): Promise<void> {
  if (ev.event === 'status') {
    const next: PreviewStatus = { phase: ev.phase ?? '', message: ev.message ?? '' }
    await updateTab($, id, t => ({ ...t, status: next }))
    if (ev.phase === 'building' || ev.phase === 'compiling' || ev.phase === 'rebuilding') {
      $.ui.status(`Preview: ${ev.phase}…`)
    }
    // Bazel's cached Xcode detection was stale; swiftpreview refreshes it.
    if (ev.phase === 'xcode' && ev.message) $.ui.toast(ev.message)
    return
  }
  if (ev.event === 'frame' && (ev.jpeg || ev.strips?.length)) {
    let jpeg = ''
    if (!ev.strips?.length && ev.jpeg) {
      try {
        jpeg = (await $.fs.read(ev.jpeg, { as: 'bytes' })).base64
      } catch {
        jpeg = ''
      }
    }
    const f: PreviewFrame = {
      seq: ev.seq ?? 0,
      jpeg,
      png: ev.png ?? '',
      width: ev.width ?? 0,
      height: ev.height ?? 0,
      previews: ev.previews ?? [],
      selected: ev.selected ?? 0,
      reload: ev.reload ?? '',
      compile: ev.timings?.compile ?? 0,
      render: (ev.timings?.load ?? 0) + (ev.timings?.render ?? 0),
      renderer: ev.renderer,
      rendererReason: ev.rendererReason,
    }
    if (ev.strips?.length) f.strips = ev.strips
    if (ev.stripWidth) f.stripWidth = ev.stripWidth
    try {
      // Read the strips before the frame is published, so its redraw is ready.
      // Frame numbers restart with each swiftpreview run: never reuse a cache.
      rt(id).strips = { seq: -1, sources: [] }
      await stripSources($, id, f)
    } catch {
      f.strips = undefined
    }
    await updateTab($, id, t => ({ ...t, frame: f, error: null, loading: false }))
    void retitle($, id)
    $.ui.status(`Preview: ${f.reload === 'rebuild' ? 'rebuilt' : 'reloaded'} in ${(f.compile + f.render).toFixed(1)}s`)
    notify(id)
    return
  }
  if (ev.event === 'error') {
    const err: PreviewError = { phase: ev.phase ?? 'error', message: ev.message ?? '', seq: rt(id).results + 1 }
    if (ev.hosts?.length) err.hosts = ev.hosts
    await updateTab($, id, t => ({ ...t, error: err, loading: false }))
    $.ui.status(`Preview: ${err.phase} failed`)
    notify(id)
    return
  }
  if (ev.event === 'host') {
    const info: PreviewHostInfo = { platform: ev.platform ?? '', devices: ev.devices ?? [], device: ev.device ?? null }
    await updateTab($, id, t => ({ ...t, host: info }))
    return
  }
  if (ev.event === 'exit') {
    await updateTab($, id, t => ({ ...t, session: t.session ? { ...t.session, isRunning: false } : null }))
  }
}

/** Reads the tab's child's JSON lines until it exits. */
async function pump($: EngineInterface, id: string, stream: AsyncIterable<{ stream: 'stdout' | 'stderr'; text: string }>): Promise<void> {
  let buffer = ''
  let stderr = ''
  try {
    for await (const { stream: pipe, text } of stream) {
      if (pipe === 'stderr') {
        stderr = (stderr + text).slice(-4000)
        continue
      }
      buffer += text
      let nl = buffer.indexOf('\n')
      while (nl >= 0) {
        const line = buffer.slice(0, nl).trim()
        buffer = buffer.slice(nl + 1)
        nl = buffer.indexOf('\n')
        if (!line.startsWith('{')) continue
        try {
          await handleEvent($, id, JSON.parse(line) as Event)
        } catch {
          // A malformed line is skipped; the next event carries on.
        }
      }
    }
  } catch (e) {
    const message = `Could not run ${ctx.binary}: ${String(e)}`
    await updateTab($, id, t => ({ ...t, error: { phase: 'starting', message, seq: rt(id).results + 1 }, loading: false }))
  }
  const tail = stderr.trim()
  if (tail) {
    await updateTab($, id, t => ({ ...t, error: t.error ?? { phase: 'exited', message: tail, seq: rt(id).results + 1 }, loading: false }))
  }
  rt(id).child = null
  await updateTab($, id, t => ({
    ...t,
    session: t.session ? { ...t.session, isRunning: false } : null,
    status: { phase: 'stopped', message: '' },
  }))
  $.ui.status(undefined)
  notify(id)
}

/** iOS: a simulator no other running tab uses, so two tabs never share one. */
async function freeSimulator($: EngineInterface, id: string): Promise<string | undefined> {
  const all = await read($, tabs)
  const used = new Set(
    Object.entries(all)
      .filter(([other, t]) => other !== id && t.session?.isRunning && t.host?.platform === 'ios')
      .map(([, t]) => t.host?.device ?? t.session?.simulator)
      .filter((d): d is string => !!d),
  )
  if (used.size === 0) return undefined
  let devices: SimDevice[]
  try {
    devices = await listDevices($)
  } catch {
    return undefined
  }
  const free = devices.filter(d => !used.has(d.udid))
  return (free.find(d => d.state === 'Booted') ?? free[0])?.udid
}

/** Moves tab `id`'s zoom one step in `dir`, or to `to`. */
async function setZoom($: EngineInterface, id: string, change: { dir?: -1 | 1; to?: number }): Promise<number> {
  let z = 100
  await updateTab($, id, t => {
    const cur = ZOOMS.indexOf(t.zoom ?? 100)
    const i = change.to !== undefined ? ZOOMS.indexOf(change.to) : Math.min(ZOOMS.length - 1, Math.max(0, (cur < 0 ? ZOOMS.length - 1 : cur) + (change.dir ?? 0)))
    z = ZOOMS[i < 0 ? ZOOMS.length - 1 : i] ?? 100
    return { ...t, zoom: z }
  })
  return z
}

/** The tab's title: the file, and the preview shown when the file has several. */
function tabTitle(tab: PreviewTab): string {
  const file = tab.session ? basename(tab.session.file) : 'SwiftUI Preview'
  const f = tab.frame
  const name = f && f.previews.length > 1 ? f.previews[f.selected]?.name : undefined
  return name ? `${file} › ${name}` : file
}

/** Retitles tab `id` (an open of an open id only retitles it) when its title changed. */
async function retitle($: EngineInterface, id: string): Promise<void> {
  const title = tabTitle(await readTab($, id))
  if (rt(id).title === title) return
  rt(id).title = title
  await $.ui.open({ id, title })
}

/** Starts `swiftpreview serve` for `file` in tab `id`, or retargets the running one. */
async function start($: EngineInterface, id: string, file: string, preview: number, host?: string): Promise<void> {
  const tab = await readTab($, id)
  const current = tab.session
  const child = rt(id).child
  // A file in another Bazel workspace needs its own swiftpreview: restart.
  const workspaceOf = (f: string) => tab.catalog?.entries.find(e => e.file === f)?.workspace
  const otherWorkspace = !!current && workspaceOf(file) !== undefined && workspaceOf(file) !== workspaceOf(current.file)
  if (current?.isRunning && child && otherWorkspace) {
    await stop($, id)
    return start($, id, file, preview, host)
  }
  if (host && current?.isRunning && child && current.host !== host) {
    // Another host means another build: restart.
    await stop($, id)
    return start($, id, file, preview, host)
  }
  rt(id).title = basename(file)
  void $.ui.open({ id, title: basename(file) })
  if (current?.isRunning && child) {
    // Until the new file's first frame, the old one is stale: show loading.
    await updateTab($, id, t => ({ ...t, session: t.session ? { ...t.session, file } : null, loading: t.session?.file !== file || t.loading }))
    await send($, id, { cmd: 'open', file, preview })
    return
  }
  const sessionDir = sessionDirFor(id)
  const renderer: RendererMode = current?.renderer ?? 'auto'
  const s: PreviewSession = { file, sessionDir, isRunning: true, scheme: null, renderer }
  const simulator = current?.simulator ?? (await freeSimulator($, id))
  if (simulator) s.simulator = simulator
  // A picked host sticks for its file; another file finds its own.
  const keptHost = host ?? (current?.file === file ? current.host : undefined)
  if (keptHost) s.host = keptHost
  await updateTab($, id, t => ({
    ...t,
    session: s,
    host: null,
    error: null,
    loading: true,
    status: { phase: 'starting', message: `swiftpreview serve ${basename(file)}` },
  }))

  const argv = [ctx.binary, 'serve', file, '--session', sessionDir, '--preview', String(preview), '--renderer', renderer]
  if (s.simulator) argv.push('--simulator', s.simulator)
  if (s.host) argv.push('--host', s.host)
  argv.push(...ctx.serveFlags)
  const stream = $.process.spawn({ argv, cwd: ctx.cwd })
  rt(id).child = stream as unknown as ChildStream
  void pump($, id, stream)
  // Workspace discovery runs Bazel queries: only when asked for (the pane's
  // button, /preview list) unless the discoverPreviews option is on.
  if (ctx.discoverPreviews) void discover($, id, file)
}

/** Where to look for previews: the project folder when the file is in it
 * (finding every workspace below it), else the file's own folder. */
function discoveryRoot(file: string): string {
  return file.startsWith(`${ctx.cwd}/`) ? ctx.cwd : dirname(file)
}

/** Lists the previews the tab can switch to (Bazel queries, no build). */
async function discover($: EngineInterface, id: string, file: string, force = false): Promise<void> {
  const r = rt(id)
  if (!force && Date.now() - r.discoveredAt < 30_000) return
  r.discoveredAt = Date.now()
  await updateTab($, id, t => ({
    ...t,
    catalog: { workspace: t.catalog?.workspace ?? '', entries: t.catalog?.entries ?? [], state: 'finding' },
  }))
  let catalog: PreviewCatalog
  try {
    const run = await $.process.run([ctx.binary, 'discover', discoveryRoot(file)], { cwd: ctx.cwd })
    if (run.exitCode !== 0) throw new Error(run.stderr.trim().split('\n').slice(-3).join(' ') || 'swiftpreview discover failed')
    const d = JSON.parse(run.stdout) as Discovery
    const entries: CatalogEntry[] = d.files.flatMap(f =>
      f.previews.map(p => {
        const entry: CatalogEntry = { file: f.file, index: p.index, name: p.name, line: p.line }
        if (f.workspace) entry.workspace = f.workspace
        return entry
      }),
    )
    catalog = { workspace: d.workspace, entries, state: 'ready' }
  } catch (err) {
    catalog = { workspace: '', entries: [], state: 'failed', message: String(err) }
  }
  await updateTab($, id, t => ({ ...t, catalog }))
}

/** Opens `file` at `line` in the editor the plugin's `editor` option names. */
async function openInEditor($: EngineInterface, file: string, line: number): Promise<void> {
  const make = EDITORS[ctx.editor] ?? EDITORS.xcode ?? (() => ['open', file])
  const argv = make(file, Math.max(1, line))
  const run = await $.process.run(argv, { cwd: ctx.cwd })
  if (run.exitCode !== 0) $.ui.toast(`Could not open ${basename(file)} with ${argv[0]}: ${run.stderr.trim().slice(0, 160)}`)
}

/** Switches how the host draws frames. */
async function setRenderer($: EngineInterface, id: string, mode: RendererMode): Promise<boolean> {
  await updateTab($, id, t => ({ ...t, session: t.session ? { ...t.session, renderer: mode } : null }))
  return send($, id, { cmd: 'renderer', value: mode })
}

/** Lists this machine's iOS simulators (the default pick first). */
async function listDevices($: EngineInterface): Promise<SimDevice[]> {
  const run = await $.process.run([ctx.binary, 'devices'], { cwd: ctx.cwd })
  if (run.exitCode !== 0) throw new Error(run.stderr.trim() || 'swiftpreview devices failed')
  return JSON.parse(run.stdout) as SimDevice[]
}

/** Moves the tab's iOS preview to another simulator (kept for the next start too). */
async function setDevice($: EngineInterface, id: string, udid: string): Promise<boolean> {
  await updateTab($, id, t => ({
    ...t,
    session: t.session ? { ...t.session, simulator: udid } : null,
    host: t.host ? { ...t.host, device: udid } : null,
  }))
  return send($, id, { cmd: 'device', value: udid })
}

async function stop($: EngineInterface, id: string): Promise<void> {
  await send($, id, { cmd: 'quit' })
  await $.clock.sleep(300)
  rt(id).child?.return?.()
  rt(id).child = null
  await updateTab($, id, t => ({ ...t, session: t.session ? { ...t.session, isRunning: false } : null }))
}

function isPreviewPane(id: string): boolean {
  return id === PANE || id.startsWith(`${PANE}-`)
}

/** The tab a /preview command acts on: the one shown, else the first running one. */
async function currentTab($: EngineInterface): Promise<string> {
  const shown = (await $.ui.panes()).find(p => p.isShown && isPreviewPane(p.id))
  if (shown) return shown.id
  const all = await read($, tabs)
  const running = Object.keys(all).filter(id => all[id]?.session?.isRunning)
  return running.includes(PANE) ? PANE : (running[0] ?? PANE)
}

/** The plugin's options as `swiftpreview serve` flags (absent: its defaults). */
function serveFlags(o: Options): string[] {
  const flags: string[] = []
  const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : undefined)
  const keep = num(o.keepHostMinutes)
  if (keep !== undefined) flags.push('--keep-host', String(Math.round(keep * 60)))
  const idle = num(o.simulatorIdleMinutes)
  if (idle !== undefined) flags.push('--simulator-idle', String(Math.round(idle * 60)))
  if (o.watch === 'auto' || o.watch === 'poll' || o.watch === 'events') flags.push('--watch', o.watch)
  const poll = num(o.pollIntervalMs)
  if (poll !== undefined) flags.push('--poll-interval', String(Math.round(poll)))
  const above = num(o.watchEventsAbove)
  if (above !== undefined) flags.push('--events-above', String(Math.round(above)))
  return flags
}

/** `File.swift › Preview` labels; the file's folder is added when two files share a name. */
function catalogOptions(entries: CatalogEntry[]): { value: string; label: string }[] {
  const names = new Map<string, number>()
  for (const f of new Set(entries.map(e => e.file))) names.set(basename(f), (names.get(basename(f)) ?? 0) + 1)
  return entries.map(e => {
    const name = basename(e.file)
    const where = (names.get(name) ?? 0) > 1 ? `${basename(dirname(e.file))}/${name}` : name
    return { value: `${e.index}:${e.file}`, label: `${where} › ${e.name}` }
  })
}

function parsePick(value: string): { file: string; preview: number } {
  const at = value.indexOf(':')
  return { preview: Number.parseInt(value.slice(0, at), 10) || 0, file: value.slice(at + 1) }
}

export const register: Register = (on, options) => {
  const o = options as Options
  ctx.binary = o.swiftpreviewPath || 'swiftpreview'
  ctx.editor = o.editor || 'xcode'
  ctx.discoverPreviews = o.discoverPreviews === true
  ctx.serveFlags = serveFlags(o)

  on('session.start', async ($, e, next) => {
    ctx.cwd = e.cwd ?? ctx.cwd
    // A fresh module has no swiftpreview children: tabs stored as running
    // (from before a reload or restart) are not.
    await update($, tabs, all =>
      Object.fromEntries(
        Object.entries(all).map(([id, t]) => [
          id,
          {
            ...t,
            session: t.session?.isRunning ? { ...t.session, isRunning: false } : t.session,
            status: t.status.phase === 'stopped' || t.status.phase === 'idle' ? t.status : { phase: 'stopped', message: '' },
            catalog: t.catalog?.state === 'finding' ? null : t.catalog,
          },
        ]),
      ),
    )
    await $.command.register({
      name: 'preview',
      description:
        'SwiftUI preview with hot reload: /preview <File.swift> [n] | new <File.swift> [n] | list | stop | dark | light | rebuild | renderer auto|swiftui|window | device [name]',
    })
    return next(e)
  })

  // Closing a tab stops its swiftpreview.
  on('ui.close', async ($, e, next) => {
    if (isPreviewPane(e.id)) {
      if (rt(e.id).child) await stop($, e.id)
    }
    return next(e)
  })

  on('command.run', { command: 'preview' }, async ($, e) => {
    const parts = e.args.trim().split(/\s+/).filter(Boolean)
    let verb = parts[0] ?? ''
    const id = await currentTab($)
    if (verb === 'stop') {
      await stop($, id)
      return { text: 'SwiftUI preview stopped.' }
    }
    if (verb === 'list') {
      // `/preview list [folder]`: that folder's Bazel workspace and those below it.
      const dir = parts[1] ? absolute(parts.slice(1).join(' ')) : ctx.cwd
      const run = await $.process.run([ctx.binary, 'discover', dir], { cwd: ctx.cwd })
      if (run.exitCode !== 0) return { text: `Could not list previews: ${run.stderr.trim().slice(-400)}` }
      const d = JSON.parse(run.stdout) as Discovery
      const lines = d.files.flatMap(f => [
        f.file.startsWith(`${dir}/`) ? f.file.slice(dir.length + 1) : f.file,
        ...f.previews.map(p => `  ${p.index}: ${p.name}`),
      ])
      return {
        text: lines.length
          ? `Previews in ${dir}:\n${lines.join('\n')}\nOpen one with /preview <file> [index], or /preview new <file> for another tab.`
          : `No previews found in ${dir}.`,
      }
    }
    if (verb === 'dark' || verb === 'light') {
      const scheme: 'dark' | 'light' = verb
      await updateTab($, id, t => ({ ...t, session: t.session ? { ...t.session, scheme } : null }))
      const ok = await send($, id, { cmd: 'scheme', value: verb })
      return { text: ok ? `Preview in ${verb} mode.` : 'No preview is running. Start one with /preview <File.swift>.' }
    }
    if (verb === 'renderer') {
      const mode = parts[1] as RendererMode | undefined
      if (!mode || !MODES.includes(mode)) {
        const lines = MODES.map(m => `  ${m}: ${RENDERERS[m].label}, ${RENDERERS[m].about}`).join('\n')
        return { text: `Usage: /preview renderer auto|swiftui|window\n${lines}` }
      }
      const ok = await setRenderer($, id, mode)
      return { text: ok ? `Preview renderer: ${RENDERERS[mode].label}.` : 'No preview is running.' }
    }
    if (verb === 'device' || verb === 'devices') {
      const wanted = parts.slice(1).join(' ')
      let devices: SimDevice[]
      try {
        devices = await listDevices($)
      } catch (err) {
        return { text: `Could not list simulators: ${String(err)}` }
      }
      const tab = await readTab($, id)
      const current = tab.host?.device ?? tab.session?.simulator
      if (!wanted) {
        const lines = devices.map((d, i) => `  ${d.udid === current ? '•' : ' '} ${deviceLabel(d)}${i === 0 && !current ? '  (default)' : ''}`)
        return { text: `iOS simulators on this machine:\n${lines.join('\n')}\nPick one with /preview device <name>.` }
      }
      const d = devices.find(x => x.udid === wanted || x.name.toLowerCase() === wanted.toLowerCase())
      if (!d) return { text: `No simulator named "${wanted}". Run /preview device to list them.` }
      const ok = await setDevice($, id, d.udid)
      return { text: ok ? `Moving the preview to ${deviceLabel(d)}.` : `${deviceLabel(d)} will be used when the preview starts.` }
    }
    if (verb === 'zoom') {
      const want = Number.parseInt((parts[1] ?? '').replace('%', ''), 10)
      if (!ZOOMS.includes(want)) return { text: `Zoom is one of ${ZOOMS.map(z => `${z}%`).join(', ')}: /preview zoom 50` }
      await setZoom($, id, { to: want })
      return { text: `Preview zoom: ${want}%.` }
    }
    if (verb === 'rebuild') {
      const ok = await send($, id, { cmd: 'rebuild' })
      return { text: ok ? 'Rebuilding the preview host with Bazel.' : 'No preview is running.' }
    }
    // `/preview new <file>` opens another tab; `/preview <file>` reuses the current one.
    const isNew = verb === 'new'
    if (isNew) {
      parts.shift()
      verb = parts[0] ?? ''
    }
    const file = verb ? absolute(verb) : ctx.lastSwiftFile
    if (!file) {
      return { text: 'Usage: /preview [new] <path/to/View.swift> [preview index] [--host //label]   (also: list, stop, dark, light, rebuild, renderer, device, zoom)' }
    }
    // A wrong path otherwise surfaces later as a confusing "no host depends on it".
    if (!(await $.fs.exists(file))) {
      return { text: `No such file: ${file} (relative paths start at ${ctx.cwd}).` }
    }
    const hostAt = parts.indexOf('--host')
    const host = hostAt >= 0 ? parts[hostAt + 1] : undefined
    const preview = Number.parseInt(parts[1] && parts[1] !== '--host' ? parts[1] : '0', 10) || 0
    const target = isNew ? await newTabId($) : id
    // Open the pane first so it appears at once; it shows "starting…" until
    // swiftpreview reports.
    const placed = await $.ui.open({ id: target, title: basename(file) })
    await start($, target, file, preview, host)
    const where = placed.isPlaced ? '' : ' (no surface is showing the pane right now)'
    return { text: `Previewing ${basename(file)}${isNew ? ' in a new tab' : ''}${where}. Edits hot reload on save.` }
  })

  // After Claude edits a Swift file while previews run: wait briefly for the
  // hot reload and tell the model how each went, so a compile error is caught at once.
  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (e.tool !== 'Edit' && e.tool !== 'Write') return ran
    const path = e.file_path
    if (!path.endsWith('.swift')) return ran
    ctx.lastSwiftFile = path
    try {
      const all = await read($, tabs)
      const running = Object.keys(all).filter(id => all[id]?.session?.isRunning && rt(id).child)
      if (!running.length || !('result' in ran) || ran.result === undefined || ran.isError) return ran
      const before = Object.fromEntries(running.map(id => [id, rt(id).results]))
      if (!(await nextResult($, 8000))) return ran
      // Let other tabs that rebuild the same file report too.
      await $.clock.sleep(250)
      const now = await read($, tabs)
      const notes: string[] = []
      for (const id of running) {
        if (rt(id).results === before[id]) continue
        const t = now[id]
        if (!t?.session) continue
        const name = basename(t.session.file)
        if (t.error) notes.push(`SwiftUI preview (${name}) ${t.error.phase} failed after this edit:\n${t.error.message}`)
        else if (t.frame) notes.push(`SwiftUI preview (${name}) hot reloaded in ${(t.frame.compile + t.frame.render).toFixed(2)}s: ${t.frame.png}`)
      }
      if (!notes.length) return ran
      return { ...ran, context: [...(ran.context ?? []), ...notes] }
    } catch {
      // The preview note is extra: never let it cost the edit's result.
      return ran
    }
  })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    const id = e.requestId
    if (!isPreviewPane(id)) return next(e)
    const els = $.ui.resolve(e)
    const { Box, Text, Button, Code, Select } = els
    const Progress = 'Progress' in els ? els.Progress : undefined
    const zoomControl = (key: string, glyph: string, enabled: boolean, press: () => unknown) => (
      <Box key={`${key}-slot`} minWidth={4} justifyContent="center">
        {enabled
          ? <Button key={key} onPress={() => void press()}>{glyph}</Button>
          : <Text key={`${key}-off`} dimColor>{glyph}</Text>}
      </Box>
    )
    const tab = await readTab($, id)
    const { session: s, error: err, status: st, host: hi, catalog } = tab
    // While another file or a new run loads, the last frame is stale: hide it.
    const isLoading = !!tab.loading && s?.isRunning === true
    const f = isLoading ? null : tab.frame

    if (!s) {
      return (
        <Box flexDirection="column">
          <Text dimColor>No preview yet. Run /preview path/to/View.swift</Text>
        </Box>
      )
    }

    const isBusy = s.isRunning && BUSY.includes(st.phase)
    const timing = f ? `${f.reload === 'rebuild' ? 'rebuilt' : f.reload} · ${(f.compile + f.render).toFixed(2)}s` : ''
    // While loading, the catalog knows the new file's lines; the old frame does not.
    const selectedLine =
      f?.previews[f.selected]?.line ?? catalog?.entries.find(c => c.file === s.file)?.line ?? 1

    let picture: RenderChildren = null
    const alt = `SwiftUI preview ${f?.previews[f.selected]?.name ?? ''}`
    let sources: string[] = []
    if (f?.strips?.length) {
      try {
        sources = await stripSources($, id, f)
      } catch {
        sources = []
      }
    }
    const zoomPct = tab.zoom ?? 100
    const zoom = zoomPct / 100
    if (f && sources.length > 0 && 'Svg' in els && els.Svg) {
      const Svg = els.Svg
      const strips = f.strips ?? []
      // Full-resolution (2x) slices stacked without gaps: one picture.
      picture = (
        <Box key={`frame-${f.seq}`} flexDirection="column" gap={0}>
          {sources.map((source, i) => (
            <Svg
              key={`strip-${f.seq}-${i}`}
              source={source}
              alt={sources.length > 1 ? `${alt}, part ${i + 1} of ${sources.length}` : alt}
              width={Math.round((f.stripWidth ?? f.width) * zoom)}
              height={Math.round((strips[i]?.height ?? 0) * zoom) || undefined}
            />
          ))}
        </Box>
      )
    } else if (f && f.jpeg && 'Svg' in els && els.Svg) {
      const Svg = els.Svg
      const w = Math.round(f.width * zoom)
      const ht = Math.round(f.height * zoom)
      const uri = `data:image/jpeg;base64,${f.jpeg}`
      const source =
        `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" ` +
        `width="${w}" height="${ht}" viewBox="0 0 ${w} ${ht}">` +
        `<image width="${w}" height="${ht}" href="${uri}"/></svg>`
      picture =
        source.length <= 131000 ? (
          <Svg key={`frame-${f.seq}`} source={source} alt={alt} width={w} height={ht} />
        ) : (
          <Text dimColor>Frame too large to draw here: {f.png}</Text>
        )
    } else if (f) {
      picture = <Text dimColor>Frame: {f.png}</Text>
    }

    // The workspace's previews once discovered; until then the file's own.
    const options = catalog?.entries.length
      ? catalogOptions(catalog.entries)
      : (f?.previews ?? []).map((p, i) => ({ value: `${i}:${s.file}`, label: `${basename(s.file)} › ${p.name}` }))
    const currentPick = f ? `${f.selected}:${s.file}` : undefined

    return (
      <Box flexDirection="column" gap={1}>
        <Box flexDirection="row" gap={1}>
          <Button key="open-file" label={`${basename(s.file)}${s.isRunning ? '' : ' (stopped)'}`} onPress={() => void openInEditor($, s.file, selectedLine)} />
          <Text dimColor>{isBusy ? `${st.phase}…` : timing}</Text>
          {f && (
            <Box flexDirection="row" gap={1} alignItems="center">
              {/* Buttons have no disabled state, and a desktop draws its native button whatever the
                  dimColor on it or its Text: at a limit the glyph is plain dim Text instead. Each control
                  sits in a box of fixed width, so swapping one for the other moves nothing. */}
              {zoomControl('zoom-out', '−', zoomPct > ZOOMS[0]!, () => setZoom($, id, { dir: -1 }))}
              {/* Figure spaces pad 25% to 100%'s width, so the buttons never move. */}
              <Box key="zoom-level" minWidth={5} justifyContent="center">
                <Text>{`${zoomPct}%`.padStart(4, '\u2007')}</Text>
              </Box>
              {zoomControl('zoom-in', '+', zoomPct < ZOOMS.at(-1)!, () => setZoom($, id, { dir: 1 }))}
            </Box>
          )}
        </Box>
        {f && f.previews.length > 1 && (
          <Box flexDirection="row" gap={1} flexWrap="wrap">
            {f.previews.map((p, i) => (
              <Button
                key={`preview-${i}`}
                label={p.name}
                variant={i === f.selected ? 'primary' : undefined}
                onPress={() => void send($, id, { cmd: 'select', preview: i })}
              />
            ))}
          </Box>
        )}
        {isLoading && (
          <Box key="loading" flexDirection="column" alignItems="center" gap={1}>
            {Progress ? (
              <Progress label={`Loading ${basename(s.file)}`} valueText={BUSY.includes(st.phase) ? `${st.phase}…` : 'starting…'} />
            ) : (
              <Text bold>Loading {basename(s.file)}…</Text>
            )}
            {st.message && <Text dimColor>{printable(st.message).slice(0, 120)}</Text>}
          </Box>
        )}
        {picture && (
          <Box flexDirection="column" alignItems="center">
            {picture}
          </Box>
        )}
        {err && (
          <Box flexDirection="column">
            <Text color="error">{err.phase === 'host' ? 'Pick a preview host' : `Preview ${err.phase} failed`}</Text>
            <Code source={printable(err.message)} language="text" wrap="wrap" />
            {err.hosts && err.hosts.length > 1 && (
              <Box flexDirection="row" gap={1} flexWrap="wrap">
                {err.hosts.map(label => (
                  <Button key={`host-${label}`} label={label} onPress={() => void start($, id, s.file, f?.selected ?? 0, label)} />
                ))}
              </Box>
            )}
          </Box>
        )}
        {isBusy && st.message && <Text dimColor>{printable(st.message).slice(0, 160)}</Text>}
        {f?.renderer && (
          <Text dimColor>
            Drawn with {rendererLabel(f.renderer)}
            {f.rendererReason ? ` · ${f.rendererReason}` : ''}
          </Text>
        )}
        {options.length > 0 && (
          <Box flexDirection="column" gap={1}>
            <Select
              key="browse"
              label="Preview"
              options={options}
              value={options.some(o => o.value === currentPick) ? currentPick : undefined}
              onSelect={value => {
                const pick = parsePick(value)
                void start($, id, pick.file, pick.preview)
              }}
            />
            <Select
              key="new-tab"
              label="Open in new tab"
              options={options}
              onSelect={async value => {
                const pick = parsePick(value)
                const tabId = await newTabId($)
                await $.ui.open({ id: tabId, title: basename(pick.file), focus: true })
                await start($, tabId, pick.file, pick.preview)
              }}
            />
          </Box>
        )}
        {catalog?.state === 'finding' && <Text dimColor>Finding previews in the workspace…</Text>}
        {(!catalog || catalog.state === 'failed') && (
          <Box flexDirection="row">
            <Button key="discover" label="Find previews in the workspace" onPress={() => void discover($, id, s.file, true)} />
          </Box>
        )}
        {catalog?.state === 'failed' && <Text dimColor>Could not list the workspace's previews: {printable(catalog.message ?? "").slice(0, 200)}</Text>}
        {s.isRunning && hi?.platform === 'ios' && hi.devices.length > 0 && (
          <Select
            key="device"
            label="Device"
            options={hi.devices.map(d => ({ value: d.udid, label: deviceLabel(d) }))}
            value={hi.device ?? undefined}
            onSelect={udid => void setDevice($, id, udid)}
          />
        )}
        {s.isRunning && hi?.platform === 'macos' && (
          <Box flexDirection="column">
            <Box flexDirection="row" gap={1} flexWrap="wrap">
              <Text dimColor>Renderer</Text>
              {MODES.map(m => (
                <Button
                  key={`renderer-${m}`}
                  label={RENDERERS[m].label}
                  variant={(s.renderer ?? 'auto') === m ? 'primary' : undefined}
                  onPress={() => void setRenderer($, id, m)}
                />
              ))}
            </Box>
            <Text dimColor>{RENDERERS[s.renderer ?? 'auto'].about}</Text>
          </Box>
        )}
        <Box flexDirection="row" gap={1}>
          {s.isRunning && (
            <Button
              key="scheme"
              label={s.scheme === 'dark' ? 'Light' : 'Dark'}
              onPress={async () => {
                const value: 'light' | 'dark' = s.scheme === 'dark' ? 'light' : 'dark'
                await updateTab($, id, t => ({ ...t, session: t.session ? { ...t.session, scheme: value } : null }))
                await send($, id, { cmd: 'scheme', value })
              }}
            />
          )}
          {s.isRunning && <Button key="rebuild" label="Rebuild" onPress={() => void send($, id, { cmd: 'rebuild' })} />}
          {s.isRunning && <Button key="stop" label="Stop" onPress={() => void stop($, id)} />}
          {!s.isRunning && <Button key="restart" label="Start" onPress={() => void start($, id, s.file, f?.selected ?? 0)} />}
        </Box>
      </Box>
    )
  })
}

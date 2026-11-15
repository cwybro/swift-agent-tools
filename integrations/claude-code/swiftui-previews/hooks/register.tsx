import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderChildren } from 'claude-code'

import type { FrameStrip, PreviewError, PreviewFrame, PreviewHostInfo, PreviewInfo, PreviewSession, PreviewStatus, RendererMode, SimDevice } from '../types'

// swiftpreview (tools/swiftpreview) does the work: it builds the Bazel preview
// host, generates @_dynamicReplacement thunks on every save and asks the host
// to render. This mod runs `swiftpreview serve`, draws its frames in a pane,
// and tells Claude how each Swift edit compiled and rendered. The model's
// swiftui_preview tool is `swiftpreview mcp` (.mcp.json), which renders through
// this pane's session while it runs.

const PANE = 'swiftui-preview'
/** Names developers see for the host's two ways of drawing a frame. */
const RENDERERS: Record<RendererMode, { label: string; about: string }> = {
  auto: { label: 'Auto', about: 'SwiftUI renderer, or Window snapshot when the view has AppKit controls' },
  swiftui: { label: 'SwiftUI renderer', about: "SwiftUI's own ImageRenderer: exact shapes, but AppKit controls draw as placeholders" },
  window: { label: 'Window snapshot', about: 'AppKit cacheDisplay of the host window: draws every control; stroked capsules can show tick marks' },
}
const MODES: RendererMode[] = ['auto', 'swiftui', 'window']

function rendererLabel(r: string | undefined): string {
  return r === 'swiftui' || r === 'window' ? RENDERERS[r].label : (r ?? 'unknown')
}

const BUSY = ['xcode', 'starting', 'building', 'querying', 'launching', 'compiling', 'rebuilding', 'rendering']

const session = atom({ plugin: 'swiftui-previews', key: 'session' } as const, null, { shape: 'session-1' })
const status = atom({ plugin: 'swiftui-previews', key: 'status' } as const, { phase: 'idle', message: '' }, { shape: 'status-1' })
const frame = atom({ plugin: 'swiftui-previews', key: 'frame' } as const, null, { shape: 'frame-1' })
const error = atom({ plugin: 'swiftui-previews', key: 'error' } as const, null, { shape: 'error-1' })
const hostInfo = atom({ plugin: 'swiftui-previews', key: 'host' } as const, null, { shape: 'host-1' })

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

type Options = { swiftpreviewPath?: string }

type ChildStream = { return?: (value?: unknown) => unknown }

// Module state starts over when the module reloads; the child dies with it.
const ctx = {
  binary: 'swiftpreview',
  cwd: '.',
  /** The running `swiftpreview serve`: leaving its loop kills it. */
  child: null as ChildStream | null,
  controlId: Date.now(),
  /** Bumped on every frame or error, so a waiter can tell a fresh result. */
  results: 0,
  waiters: [] as Array<() => void>,
  lastSwiftFile: null as string | null,
  /** The latest frame's strips as SVG sources, so a redraw reads no files. */
  strips: { seq: -1, sources: [] as string[] },
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

/** Reads a frame's strips into SVG sources (cached per frame). */
async function stripSources($: EngineInterface, f: PreviewFrame): Promise<string[]> {
  if (!f.strips?.length) return []
  if (ctx.strips.seq === f.seq) return ctx.strips.sources
  const sources: string[] = []
  for (const s of f.strips) {
    const bytes = await $.fs.read(s.path, { as: 'bytes' })
    sources.push(stripSvg(f.stripWidth ?? f.width, s, bytes.base64))
  }
  ctx.strips = { seq: f.seq, sources }
  return sources
}

function absolute(p: string): string {
  return p.startsWith('/') ? p : `${ctx.cwd}/${p}`.replace(/\/\.\//g, '/')
}

function basename(p: string): string {
  return p.split('/').pop() ?? p
}

function notify(): void {
  ctx.results += 1
  for (const w of ctx.waiters.splice(0)) w()
}

/** Resolves true on the next frame or error, false after `ms`. */
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

/** Writes a command where the running swiftpreview polls for it. */
async function send($: EngineInterface, cmd: Record<string, unknown>): Promise<boolean> {
  const s = await read($, session)
  if (!s?.isRunning) return false
  ctx.controlId += 1
  await $.fs.write(`${s.sessionDir}/control.json`, JSON.stringify({ ...cmd, id: ctx.controlId }))
  return true
}

async function handleEvent($: EngineInterface, ev: Event): Promise<void> {
  if (ev.event === 'status') {
    const next: PreviewStatus = { phase: ev.phase ?? '', message: ev.message ?? '' }
    await update($, status, () => next)
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
      ctx.strips = { seq: -1, sources: [] }
      await stripSources($, f)
    } catch {
      f.strips = undefined
    }
    await update($, frame, () => f)
    await update($, error, () => null)
    $.ui.status(`Preview: ${f.reload === 'rebuild' ? 'rebuilt' : 'reloaded'} in ${(f.compile + f.render).toFixed(1)}s`)
    notify()
    return
  }
  if (ev.event === 'error') {
    const err: PreviewError = { phase: ev.phase ?? 'error', message: ev.message ?? '', seq: ctx.results + 1 }
    if (ev.hosts?.length) err.hosts = ev.hosts
    await update($, error, () => err)
    $.ui.status(`Preview: ${err.phase} failed`)
    notify()
    return
  }
  if (ev.event === 'host') {
    const info: PreviewHostInfo = { platform: ev.platform ?? '', devices: ev.devices ?? [], device: ev.device ?? null }
    await update($, hostInfo, () => info)
    return
  }
  if (ev.event === 'exit') {
    await update($, session, s => (s ? { ...s, isRunning: false } : s))
  }
}

/** Reads the child's JSON lines until it exits. */
async function pump($: EngineInterface, stream: AsyncIterable<{ stream: 'stdout' | 'stderr'; text: string }>): Promise<void> {
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
          await handleEvent($, JSON.parse(line) as Event)
        } catch {
          // A malformed line is skipped; the next event carries on.
        }
      }
    }
  } catch (e) {
    const message = `Could not run ${ctx.binary}: ${String(e)}`
    await update($, error, () => ({ phase: 'starting', message, seq: ctx.results + 1 }))
  }
  const tail = stderr.trim()
  if (tail) {
    await update($, error, prev => prev ?? { phase: 'exited', message: tail, seq: ctx.results + 1 })
  }
  ctx.child = null
  await update($, session, prev => (prev ? { ...prev, isRunning: false } : prev))
  await update($, status, () => ({ phase: 'stopped', message: '' }))
  $.ui.status(undefined)
  notify()
}

/** Starts `swiftpreview serve` for `file`, or retargets the running one. */
async function start($: EngineInterface, file: string, preview: number, host?: string): Promise<void> {
  const current = await read($, session)
  if (host && current?.isRunning && ctx.child && current.host !== host) {
    // Another host means another build: restart.
    await stop($)
    return start($, file, preview, host)
  }
  if (current?.isRunning && ctx.child) {
    await update($, session, s => (s ? { ...s, file } : s))
    await send($, { cmd: 'open', file, preview })
    return
  }
  const sessionDir = `${ctx.cwd}/.swiftpreview/claude`
  const renderer: RendererMode = current?.renderer ?? 'auto'
  const s: PreviewSession = { file, sessionDir, isRunning: true, scheme: null, renderer }
  if (current?.simulator) s.simulator = current.simulator
  // A picked host sticks for its file; another file finds its own.
  const keptHost = host ?? (current?.file === file ? current.host : undefined)
  if (keptHost) s.host = keptHost
  await update($, session, () => s)
  await update($, hostInfo, () => null)
  await update($, error, () => null)
  await update($, status, () => ({ phase: 'starting', message: `swiftpreview serve ${basename(file)}` }))

  const argv = [ctx.binary, 'serve', file, '--session', sessionDir, '--preview', String(preview), '--renderer', renderer]
  if (s.simulator) argv.push('--simulator', s.simulator)
  if (s.host) argv.push('--host', s.host)
  const stream = $.process.spawn({
    argv,
    cwd: ctx.cwd,
  })
  ctx.child = stream as unknown as ChildStream
  void pump($, stream)
}

/** Switches how the host draws frames. */
async function setRenderer($: EngineInterface, mode: RendererMode): Promise<boolean> {
  await update($, session, s => (s ? { ...s, renderer: mode } : s))
  return send($, { cmd: 'renderer', value: mode })
}

/** Lists this machine's iOS simulators (the default pick first). */
async function listDevices($: EngineInterface): Promise<SimDevice[]> {
  const run = await $.process.run([ctx.binary, 'devices'], { cwd: ctx.cwd })
  if (run.exitCode !== 0) throw new Error(run.stderr.trim() || 'swiftpreview devices failed')
  return JSON.parse(run.stdout) as SimDevice[]
}

/** Moves the iOS preview to another simulator (kept for the next start too). */
async function setDevice($: EngineInterface, udid: string): Promise<boolean> {
  await update($, session, s => (s ? { ...s, simulator: udid } : s))
  await update($, hostInfo, h => (h ? { ...h, device: udid } : h))
  return send($, { cmd: 'device', value: udid })
}

async function stop($: EngineInterface): Promise<void> {
  await send($, { cmd: 'quit' })
  await $.clock.sleep(300)
  ctx.child?.return?.()
  ctx.child = null
  await update($, session, s => (s ? { ...s, isRunning: false } : s))
}

export const register: Register = (on, options) => {
  ctx.binary = (options as Options).swiftpreviewPath || 'swiftpreview'

  on('session.start', async ($, e, next) => {
    ctx.cwd = e.cwd ?? ctx.cwd
    // A fresh module has no swiftpreview child: a session stored as running
    // (from before a reload or restart) is not.
    await update($, session, s => (s?.isRunning ? { ...s, isRunning: false } : s))
    await update($, status, st => (st.phase === 'stopped' || st.phase === 'idle' ? st : { phase: 'stopped', message: '' }))
    await $.command.register({
      name: 'preview',
      description:
        'SwiftUI preview with hot reload: /preview <File.swift> [n] | stop | dark | light | rebuild | renderer auto|swiftui|window | device [name]',
    })
    return next(e)
  })

  on('command.run', { command: 'preview' }, async ($, e) => {
    const parts = e.args.trim().split(/\s+/).filter(Boolean)
    const verb = parts[0] ?? ''
    if (verb === 'stop') {
      await stop($)
      return { text: 'SwiftUI preview stopped.' }
    }
    if (verb === 'dark' || verb === 'light') {
      const scheme: 'dark' | 'light' = verb
      await update($, session, s => (s ? { ...s, scheme } : s))
      const ok = await send($, { cmd: 'scheme', value: verb })
      return { text: ok ? `Preview in ${verb} mode.` : 'No preview is running. Start one with /preview <File.swift>.' }
    }
    if (verb === 'renderer') {
      const mode = parts[1] as RendererMode | undefined
      if (!mode || !MODES.includes(mode)) {
        const lines = MODES.map(m => `  ${m}: ${RENDERERS[m].label}, ${RENDERERS[m].about}`).join('\n')
        return { text: `Usage: /preview renderer auto|swiftui|window\n${lines}` }
      }
      const ok = await setRenderer($, mode)
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
      const s = await read($, session)
      const h = await read($, hostInfo)
      const current = h?.device ?? s?.simulator
      if (!wanted) {
        const lines = devices.map((d, i) => `  ${d.udid === current ? '•' : ' '} ${deviceLabel(d)}${i === 0 && !current ? '  (default)' : ''}`)
        return { text: `iOS simulators on this machine:\n${lines.join('\n')}\nPick one with /preview device <name>.` }
      }
      const d = devices.find(x => x.udid === wanted || x.name.toLowerCase() === wanted.toLowerCase())
      if (!d) return { text: `No simulator named "${wanted}". Run /preview device to list them.` }
      const ok = await setDevice($, d.udid)
      return { text: ok ? `Moving the preview to ${deviceLabel(d)}.` : `${deviceLabel(d)} will be used when the preview starts.` }
    }
    if (verb === 'rebuild') {
      const ok = await send($, { cmd: 'rebuild' })
      return { text: ok ? 'Rebuilding the preview host with Bazel.' : 'No preview is running.' }
    }
    const file = verb ? absolute(verb) : ctx.lastSwiftFile
    if (!file) {
      return { text: 'Usage: /preview <path/to/View.swift> [preview index] [--host //label]   (also: stop, dark, light, rebuild, renderer, device)' }
    }
    const hostAt = parts.indexOf('--host')
    const host = hostAt >= 0 ? parts[hostAt + 1] : undefined
    const preview = Number.parseInt(parts[1] && parts[1] !== '--host' ? parts[1] : '0', 10) || 0
    // Open the pane first so it appears at once; it shows "starting…" until
    // swiftpreview reports.
    const placed = await $.ui.open({ id: PANE, title: 'SwiftUI Preview' })
    await start($, file, preview, host)
    const where = placed.isPlaced ? '' : ' (no surface is showing the pane right now)'
    return { text: `Previewing ${basename(file)}${where}. Edits hot reload on save.` }
  })

  // After Claude edits a Swift file while a preview runs: wait briefly for the
  // hot reload and tell the model how it went, so a compile error is caught at once.
  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (e.tool !== 'Edit' && e.tool !== 'Write') return ran
    const path = e.file_path
    if (!path.endsWith('.swift')) return ran
    ctx.lastSwiftFile = path
    try {
      const s = await read($, session)
      if (!s?.isRunning || !ctx.child || !('result' in ran) || ran.result === undefined || ran.isError) return ran
      const got = await nextResult($, 8000)
      if (!got) return ran
      const err = await read($, error)
      const f = await read($, frame)
      const name = basename(s.file)
      const note = err
        ? `SwiftUI preview (${name}) ${err.phase} failed after this edit:\n${err.message}`
        : f
          ? `SwiftUI preview (${name}) hot reloaded in ${(f.compile + f.render).toFixed(2)}s: ${f.png}`
          : ''
      if (!note) return ran
      return { ...ran, context: [...(ran.context ?? []), note] }
    } catch {
      // The preview note is extra: never let it cost the edit's result.
      return ran
    }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const els = $.ui.resolve(e)
    const { Box, Text, Button, Code, Select } = els
    const s = await read($, session)
    const f = await read($, frame)
    const err = await read($, error)
    const st = await read($, status)
    const hi = await read($, hostInfo)

    if (!s) {
      return (
        <Box flexDirection="column">
          <Text dimColor>No preview yet. Run /preview path/to/View.swift</Text>
        </Box>
      )
    }

    const isBusy = s.isRunning && BUSY.includes(st.phase)
    const header = `${basename(s.file)}${s.isRunning ? '' : ' (stopped)'}`
    const timing = f ? `${f.reload === 'rebuild' ? 'rebuilt' : f.reload} · ${(f.compile + f.render).toFixed(2)}s` : ''

    let picture: RenderChildren = null
    const alt = `SwiftUI preview ${f?.previews[f.selected]?.name ?? ''}`
    let sources: string[] = []
    if (f?.strips?.length) {
      try {
        sources = await stripSources($, f)
      } catch {
        sources = []
      }
    }
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
              width={Math.round(f.stripWidth ?? f.width)}
              height={strips[i]?.height}
            />
          ))}
        </Box>
      )
    } else if (f && f.jpeg && 'Svg' in els && els.Svg) {
      const Svg = els.Svg
      const w = Math.round(f.width)
      const ht = Math.round(f.height)
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

    return (
      <Box flexDirection="column" gap={1}>
        <Box flexDirection="row" gap={1}>
          <Text bold>{header}</Text>
          <Text dimColor>{isBusy ? `${st.phase}…` : timing}</Text>
        </Box>
        {f && f.previews.length > 1 && (
          <Box flexDirection="row" gap={1} flexWrap="wrap">
            {f.previews.map((p, i) => (
              <Button
                key={`preview-${i}`}
                label={p.name}
                variant={i === f.selected ? 'primary' : undefined}
                onPress={() => void send($, { cmd: 'select', preview: i })}
              />
            ))}
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
            <Code source={err.message} language="text" wrap="wrap" />
            {err.hosts && err.hosts.length > 1 && (
              <Box flexDirection="row" gap={1} flexWrap="wrap">
                {err.hosts.map(label => (
                  <Button key={`host-${label}`} label={label} onPress={() => void start($, s.file, f?.selected ?? 0, label)} />
                ))}
              </Box>
            )}
          </Box>
        )}
        {isBusy && st.message && <Text dimColor>{st.message.slice(0, 160)}</Text>}
        {f?.renderer && (
          <Text dimColor>
            Drawn with {rendererLabel(f.renderer)}
            {f.rendererReason ? ` · ${f.rendererReason}` : ''}
          </Text>
        )}
        {s.isRunning && hi?.platform === 'ios' && hi.devices.length > 0 && (
          <Select
            key="device"
            label="Device"
            options={hi.devices.map(d => ({ value: d.udid, label: deviceLabel(d) }))}
            value={hi.device ?? undefined}
            onSelect={udid => void setDevice($, udid)}
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
                  onPress={() => void setRenderer($, m)}
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
                await update($, session, prev => (prev ? { ...prev, scheme: value } : prev))
                await send($, { cmd: 'scheme', value })
              }}
            />
          )}
          {s.isRunning && <Button key="rebuild" label="Rebuild" onPress={() => void send($, { cmd: 'rebuild' })} />}
          {s.isRunning && <Button key="stop" label="Stop" onPress={() => void stop($)} />}
          {!s.isRunning && <Button key="restart" label="Start" onPress={() => void start($, s.file, f?.selected ?? 0)} />}
        </Box>
      </Box>
    )
  })
}

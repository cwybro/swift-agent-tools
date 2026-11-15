import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Browse, DbgState, DbgVar, Hit, Live } from '../types'

// Mirrors the swiftdbg MCP server's session (swiftdbg/server.py, HTTP viewer
// endpoints) in a pane: the agent drives LLDB through MCP, the person watches
// and steps here, and both see the same session.
const BASE = 'http://127.0.0.1:7311'
const PANE = 'swiftdbg'
const TITLE = 'Swift debugger'

const live = atom({ plugin: 'swiftdbg-pane', key: 'live' } as const, { state: null, error: null } as Live, {
  shape: 'live-1',
})
const files = atom({ plugin: 'swiftdbg-pane', key: 'files' } as const, {} as Record<string, string[]>, {
  shape: 'files-1',
})
const expanded = atom({ plugin: 'swiftdbg-pane', key: 'expanded' } as const, {} as Record<string, DbgVar[]>, {
  shape: 'expanded-1',
})

const view = atom({ plugin: 'swiftdbg-pane', key: 'view' } as const, null as { file: string; line: number } | null, {
  shape: 'view-1',
})

const tab = atom({ plugin: 'swiftdbg-pane', key: 'tab' } as const, 'debug' as 'debug' | 'files', { shape: 'tab-1' })
const EMPTY_BROWSE: Browse = { filter: '', query: '', hits: null, searching: false, open: null }
const browse = atom({ plugin: 'swiftdbg-pane', key: 'browse' } as const, EMPTY_BROWSE, { shape: 'browse-1' })

const base = (p?: string | null) => (p ?? '').split('/').pop() ?? ''
const stopKey = (s: DbgState | null) =>
  s ? `${s.status}:${JSON.stringify(s.snapshot.frames?.[0] ?? null)}:${s.snapshot.selectedFrame ?? 0}` : ''


// Module state: restarts on a reload, which only costs one redraw.
let lastVersion = -1
let lastStop = ''
let wasActive = false
let failures = 0
let tick = 0
let inFlight = false
let projectRoot = ''
let projectFiles: { at: number; list: string[] } | null = null

// ---------------------------------------------------------------- breakpoints by name

const SKIP_DIRS = new Set(['.build', '.git', '.swiftpm', 'node_modules', 'DerivedData', 'Pods', 'Carthage', 'build', '.claude'])
const MAX_FILES = 5000

/** Every .swift file under the project, skipping build output; cached for 30s. */
async function listSwiftFiles($: any): Promise<string[]> {
  const now = await $.clock.now()
  if (projectFiles && now - projectFiles.at < 30_000) return projectFiles.list
  const out: string[] = []
  const queue: [string, number][] = projectRoot ? [[projectRoot, 0]] : []
  while (queue.length && out.length < MAX_FILES) {
    const [dir, depth] = queue.shift()!
    let entries: { name: string; kind: string }[] = []
    try {
      entries = await $.fs.list(dir)
    } catch {
      continue
    }
    for (const ent of entries) {
      const path = `${dir}/${ent.name}`
      if (ent.kind === 'dir') {
        if (depth < 12 && !SKIP_DIRS.has(ent.name) && !ent.name.startsWith('bazel-') && !ent.name.startsWith('.'))
          queue.push([path, depth + 1])
      } else if (ent.kind === 'file' && ent.name.endsWith('.swift')) {
        out.push(path)
      }
    }
  }
  projectFiles = { at: now, list: out }
  return out
}

/** `main.swift:27`, `Cart/main.swift 27` or an absolute path. */
function parseSpec(spec: string): { name: string; line: number } | null {
  const m = spec.trim().match(/^(.+?)(?::|\s+)(\d+)$/)
  if (!m || !m[1] || !m[2]) return null
  const line = Number(m[2])
  return line > 0 ? { name: m[1].trim(), line } : null
}

async function resolveFile($: any, name: string): Promise<{ path?: string; error?: string }> {
  const { state } = await read($, live)
  const known = state
    ? [...Object.keys(state.breakpoints), ...(state.snapshot.frames ?? []).map(f => f.file ?? '')].filter(Boolean)
    : []
  if (name.startsWith('/')) {
    if (known.includes(name) || (await $.fs.exists(name))) return { path: name }
    return { error: `No file at ${name}` }
  }
  const all = [...new Set([...known, ...(await listSwiftFiles($))])]
  const want = name.startsWith('/') ? name : '/' + name
  let hits = all.filter(p => p.endsWith(want))
  if (hits.length === 0) hits = all.filter(p => p.toLowerCase().endsWith(want.toLowerCase()))
  if (hits.length === 1) return { path: hits[0] }
  const rel = (p: string) => (projectRoot && p.startsWith(projectRoot + '/') ? p.slice(projectRoot.length + 1) : p)
  if (hits.length > 1)
    return { error: `${name} matches ${hits.length} files; add a folder, e.g. ${hits.slice(0, 2).map(rel).join(' or ')}` }
  const stem = base(name).replace(/\.swift$/i, '').toLowerCase()
  const near = all.filter(p => base(p).toLowerCase().includes(stem)).slice(0, 3).map(rel)
  return { error: `No ${name} in the project` + (near.length ? `. Did you mean ${near.join(', ')}?` : '') }
}

/** Adds a breakpoint from `File.swift:42` and returns a line to tell the person. */
async function addBreakpoint($: any, spec: string): Promise<string> {
  const parsed = parseSpec(spec)
  if (!parsed) return 'Write it as File.swift:42'
  const { state } = await read($, live)
  if (!state) return 'swiftdbg is not running: start a session with the swiftdbg tools first'
  const found = await resolveFile($, parsed.name)
  if (!found.path) return found.error ?? 'File not found'
  const path = found.path
  const lines = (state.breakpoints[path] ?? []).map(b => b.line)
  await update($, view, () => ({ file: path, line: parsed.line }))
  if (lines.includes(parsed.line)) return `Breakpoint already set at ${base(path)}:${parsed.line}`
  const out = await post($, 'toggle', { file: path, line: parsed.line })
  if (out.error) return `swiftdbg: ${out.error}`
  await ensureFile($, path)
  const bp = out[path]?.find((b: { line: number }) => b.line === parsed.line)
  return `Breakpoint set at ${base(path)}:${parsed.line}` + (bp && bp.verified === false ? ' (not resolved yet: no code on that line?)' : '')
}

async function post($: any, action: string, body: object = {}) {
  try {
    const r = await $.http.fetch(`${BASE}/${action}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    const out = JSON.parse(r.text || '{}')
    if (out.error) await $.ui.toast(`swiftdbg: ${out.error}`)
    return out
  } catch (err) {
    await $.ui.toast('swiftdbg: server not reachable')
    return { error: String(err) }
  } finally {
    void refresh($, true)
  }
}

async function ensureFile($: any, path: string) {
  const have = await read($, files)
  if (have[path]) return
  try {
    const r = await $.http.fetch(`${BASE}/source?path=${encodeURIComponent(path)}`)
    if (!r.ok) return
    const lines: string[] = JSON.parse(r.text).lines
    await update($, files, f => ({ ...f, [path]: lines }))
  } catch {
    // The pane shows the path without source.
  }
}

async function refresh($: any, force = false) {
  // While the server is down, try every 4th tick only.
  tick++
  if (!force && failures > 2 && tick % 4 !== 0) return
  if (inFlight && !force) return
  inFlight = true
  try {
    const r = await $.http.fetch(`${BASE}/state`)
    const state: DbgState = JSON.parse(r.text)
    failures = 0
    if (state.version === lastVersion) return
    lastVersion = state.version
    const key = stopKey(state)
    if (key !== lastStop) {
      // Variable refs are only valid for the stop that produced them.
      lastStop = key
      await update($, expanded, () => ({}))
      // A new stop takes the source view back to the current line.
      if (state.status === 'stopped') await update($, view, () => null)
    }
    await update($, live, () => ({ state, error: null }))
    const frame = state.snapshot.frames?.[state.snapshot.selectedFrame ?? 0]
    const path = (await read($, view))?.file ?? frame?.file ?? Object.keys(state.breakpoints)[0]
    if (path) await ensureFile($, path)
    const active = state.status === 'running' || state.status === 'stopped'
    if (active && !wasActive) void $.ui.open({ id: PANE, title: TITLE })
    wasActive = active
  } catch {
    failures++
    if (failures === 3 || lastVersion !== -1) {
      lastVersion = -1
      wasActive = false
      await update($, live, () => ({ state: null, error: 'swiftdbg server not running' }))
    }
  } finally {
    inFlight = false
  }
}

// ---------------------------------------------------------------- Files tab

const LIST_MAX = 40
const HITS_MAX = 60

const relPath = (p: string) => (projectRoot && p.startsWith(projectRoot + '/') ? p.slice(projectRoot.length + 1) : p)

/** Source lines for a path: from disk, else from swiftdbg (files outside the project it already knows). */
async function loadFile($: any, path: string): Promise<boolean> {
  if ((await read($, files))[path]) return true
  try {
    const text: string = await $.fs.read(path)
    await update($, files, f => ({ ...f, [path]: text.split('\n') }))
    return true
  } catch {
    await ensureFile($, path)
    return Boolean((await read($, files))[path])
  }
}

async function openFile($: any, file: string, line: number | null, rowsHint = 30) {
  await loadFile($, file)
  const top = Math.max(1, (line ?? 1) - Math.floor(rowsHint / 3))
  await update($, browse, b => ({ ...b, open: { file, line, top } }))
  await update($, tab, () => 'files' as const)
}

/** Fixed-string, case-insensitive search of the project's .swift files. */
async function searchText($: any, query: string) {
  const q = query.trim()
  if (!q) {
    await update($, browse, b => ({ ...b, query: '', hits: null, searching: false }))
    return
  }
  await update($, browse, b => ({ ...b, query: q, hits: null, searching: true, open: null }))
  let hits: Hit[] = []
  try {
    const exclude = [...SKIP_DIRS].map(d => `--exclude-dir=${d}`)
    const r = await $.process.run(
      ['grep', '-rnIiF', '--include=*.swift', ...exclude, '--exclude-dir=bazel-*', '-m', '20', '--', q, '.'],
      { cwd: projectRoot, timeoutMs: 15_000 },
    )
    for (const row of r.stdout.split('\n')) {
      // GNU grep prints "./path", BSD (macOS) grep prints "path".
      const m = row.match(/^(?:\.\/)?(.+?):(\d+):(.*)$/)
      if (m && m[1] && m[2]) hits.push({ file: `${projectRoot}/${m[1]}`, line: Number(m[2]), text: (m[3] ?? '').trim() })
      if (hits.length >= HITS_MAX) break
    }
  } catch {
    // No grep (or not allowed to run it): read the files instead.
    const needle = q.toLowerCase()
    for (const file of await listSwiftFiles($)) {
      if (hits.length >= HITS_MAX) break
      if (!(await loadFile($, file))) continue
      const lines = (await read($, files))[file] ?? []
      lines.forEach((text, i) => {
        if (hits.length < HITS_MAX && text.toLowerCase().includes(needle)) hits.push({ file, line: i + 1, text: text.trim() })
      })
    }
  }
  await update($, browse, b => ({ ...b, hits, searching: false }))
}

async function toggleIn($: any, file: string, line: number) {
  const { state } = await read($, live)
  if (!state) {
    await $.ui.toast('swiftdbg is not running: start a session with the swiftdbg tools first')
    return
  }
  await post($, 'toggle', { file, line })
}

async function focusField($: any, key: 'file-filter' | 'text-search') {
  await update($, tab, () => 'files' as const)
  if (key === 'file-filter') await update($, browse, b => ({ ...b, open: null, hits: null }))
  // Lands only while the pane holds the keyboard; otherwise the tab switch is enough.
  await $.ui.focus({ requestId: PANE, key }).catch(() => undefined)
}

/** The row of tabs and hotkeys that heads the pane in both tabs. */
function tabRow($: any, el: any, current: 'debug' | 'files') {
  const { Box, Button } = el
  return (
    <Box flexDirection="row" gap={1} flexWrap="wrap">
      <Button key="tab-debug" hotkey="1" dimColor={current !== 'debug'} label="Debug" onPress={() => void update($, tab, () => 'debug' as const)} />
      <Button key="tab-files" hotkey="2" dimColor={current !== 'files'} label="Files" onPress={() => void update($, tab, () => 'files' as const)} />
      <Button key="find-file" hotkey="f" plain dimColor label="Find file" onPress={() => void focusField($, 'file-filter')} />
      <Button key="find-text" hotkey="g" plain dimColor label="Search text" onPress={() => void focusField($, 'text-search')} />
    </Box>
  )
}

async function filesBody($: any, e: any, el: any, state: DbgState | null) {
  const { Box, Text, Button, Input } = el
  const b = await read($, browse)
  const rows = e.viewport?.rows ?? 40

  const fields = (
    <Box flexDirection="column">
      <Input
        key="file-filter"
        label="Find file"
        placeholder="name, e.g. cart"
        value={b.filter}
        onInput={(v: string) => void update($, browse, x => ({ ...x, filter: v, open: null, hits: null }))}
        onSubmit={(v: string) =>
          void (async () => {
            const all = await listSwiftFiles($)
            const first = all.find(p => relPath(p).toLowerCase().includes(v.trim().toLowerCase()))
            if (first) await openFile($, first, null, rows)
          })()
        }
      />
      <Input
        key="text-search"
        label="Search text"
        placeholder="text in .swift files"
        value={b.query}
        submitLabel="search"
        onSubmit={(v: string) => void searchText($, v)}
      />
    </Box>
  )

  // A file open: a page of its lines with the breakpoint gutter.
  if (b.open) {
    const { file, line: mark, top } = b.open
    const lines = (await read($, files))[file]
    const span = Math.max(12, Math.min(40, rows - 16))
    const total = lines?.length ?? 0
    const lo = Math.max(1, Math.min(top, Math.max(1, total - span + 1)))
    const hi = Math.min(total, lo + span - 1)
    const width = String(hi).length
    const bps = new Set((state?.breakpoints[file] ?? []).map(x => x.line))
    const frame = state?.snapshot.frames?.[state.snapshot.selectedFrame ?? 0]
    const cur = state?.status === 'stopped' && frame?.file === file ? frame.line ?? -1 : -1
    const move = (to: number) => void update($, browse, x => (x.open ? { ...x, open: { ...x.open, top: Math.max(1, to) } } : x))
    return (
      <Box flexDirection="column" gap={1}>
        {fields}
        <Box flexDirection="row" gap={1}>
          <Button key="back" plain dimColor label="← list" onPress={() => void update($, browse, x => ({ ...x, open: null }))} />
          <Text bold wrap="truncate-middle">
            {relPath(file)}
          </Text>
          <Text dimColor>
            {total ? `${lo}–${hi} of ${total}` : ''}
          </Text>
        </Box>
        {!lines && <Text dimColor>Could not read this file.</Text>}
        {lines && (
          <Box flexDirection="column">
            {lines.slice(lo - 1, hi).map((text, i) => {
              const n = lo + i
              const isCur = n === cur
              const isMark = n === mark
              return (
                <Box key={`fv-${n}`} flexDirection="row" backgroundColor={isCur ? 'warning' : undefined}>
                  <Button
                    key={`fbp-${n}`}
                    plain
                    dimColor={!bps.has(n)}
                    label={bps.has(n) ? '●' : '·'}
                    onPress={() => void toggleIn($, file, n)}
                  />
                  <Text mono dimColor={!isCur && !isMark} bold={isMark} color={isCur ? 'inverseText' : isMark ? 'suggestion' : undefined}>
                    {` ${String(n).padStart(width)} ${isCur ? '→' : isMark ? '›' : ' '} `}
                  </Text>
                  <Text mono wrap="truncate-end" color={isCur ? 'inverseText' : undefined}>
                    {text || ' '}
                  </Text>
                </Box>
              )
            })}
          </Box>
        )}
        <Box flexDirection="row" gap={1}>
          {lo > 1 && <Button key="page-up" label="▲ earlier" onPress={() => move(lo - span)} />}
          {hi < total && <Button key="page-down" label="▼ later" onPress={() => move(lo + span)} />}
        </Box>
      </Box>
    )
  }

  // Search results.
  if (b.searching || b.hits) {
    const hits = b.hits ?? []
    return (
      <Box flexDirection="column" gap={1}>
        {fields}
        <Box flexDirection="row" gap={1}>
          <Text bold>{b.searching ? `Searching for “${b.query}”…` : `${hits.length}${hits.length >= HITS_MAX ? '+' : ''} matches for “${b.query}”`}</Text>
          {!b.searching && (
            <Button key="clear-search" plain dimColor label="clear" onPress={() => void update($, browse, x => ({ ...x, query: '', hits: null }))} />
          )}
        </Box>
        <Box flexDirection="column">
          {hits.map((hit, i) => (
            <Button
              key={`hit-${i}`}
              plain
              label={`${relPath(hit.file)}:${hit.line}  ${hit.text}`}
              onPress={() => void openFile($, hit.file, hit.line, rows)}
            />
          ))}
        </Box>
      </Box>
    )
  }

  // The file list, filtered by name.
  const all = await listSwiftFiles($)
  const f = b.filter.trim().toLowerCase()
  const shown = (f ? all.filter(p => relPath(p).toLowerCase().includes(f)) : all).sort((x, y) =>
    relPath(x).localeCompare(relPath(y)),
  )
  const withBps = new Set(Object.keys(state?.breakpoints ?? {}))
  return (
    <Box flexDirection="column" gap={1}>
      {fields}
      <Text dimColor>
        {all.length === 0
          ? 'No .swift files found in this project.'
          : `${shown.length} of ${all.length} Swift files${shown.length > LIST_MAX ? ` (first ${LIST_MAX}; type to narrow)` : ''}`}
      </Text>
      <Box flexDirection="column">
        {shown.slice(0, LIST_MAX).map((p, i) => (
          <Button key={`file-${i}`} plain label={`${withBps.has(p) ? '● ' : '  '}${relPath(p)}`} onPress={() => void openFile($, p, null, rows)} />
        ))}
      </Box>
    </Box>
  )
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    projectRoot = e.cwd.replace(/\/+$/, '')
    await $.command.register({
      name: 'swiftdbg',
      description: 'Show the live Swift debugger pane, or set a breakpoint: /swiftdbg break File.swift:42',
      argumentHint: '[break File.swift:42]',
    })
    $.clock.every(700, () => void refresh($))
    return next(e)
  })

  on('command.run', { command: 'swiftdbg' }, async ($, e) => {
    const args = e.args.trim()
    const m = args.match(/^(?:break|b)\s+(.+)$/i)
    if (m && m[1]) {
      await refresh($, true)
      const text = await addBreakpoint($, m[1])
      return { text }
    }
    if (args) return { text: 'Usage: /swiftdbg, or /swiftdbg break File.swift:42' }
    await $.ui.open({ id: PANE, title: TITLE })
    void refresh($, true)
    return { text: 'Swift debugger pane opened.' }
  })

  // A one-line row above the prompt while a debug session is active: one click
  // (or ctrl+x tab, then d, in the terminal) opens the pane.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const { state } = await read($, live)
    const active = state && (state.status === 'running' || state.status === 'stopped')
    if (!state || !active || e.props.hasSurvey) return next(e)

    const { Box, Text, Button } = $.ui.resolve(e)
    const frame = state.snapshot.frames?.[state.snapshot.selectedFrame ?? 0]
    const where =
      state.status === 'stopped' && frame
        ? `stopped at ${base(frame.file) || frame.name}${frame.line ? ':' + frame.line : ''}`
        : state.status

    return (
      <Box flexDirection="row" gap={1}>
        <Text color={state.status === 'stopped' ? 'warning' : 'success'}>●</Text>
        <Text wrap="truncate-end">Debugger · {where}</Text>
        <Button key="open" hotkey="d" label="Open debugger" onPress={() => void $.ui.open({ id: PANE, title: TITLE, focus: true })} />
        {state.status === 'stopped' && (
          <Button key="band-continue" hotkey="c" label="Continue" onPress={() => void post($, 'continue')} />
        )}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Input } = $.ui.resolve(e)
    const { state, error } = await read($, live)
    const cols = Math.max(30, (e.props as any)?.bodyColumns ?? e.viewport?.columns ?? 60)
    const rows = e.viewport?.rows ?? 40
    const el = { Box, Text, Button, Input }
    const current = await read($, tab)

    if (current === 'files') {
      return (
        <Box flexDirection="column" gap={1}>
          {tabRow($, el, current)}
          {await filesBody($, e, el, state)}
        </Box>
      )
    }

    if (!state) {
      return (
        <Box flexDirection="column" gap={1}>
          {tabRow($, el, current)}
          <Text dimColor>{error ?? 'Connecting to swiftdbg…'}</Text>
          <Text dimColor wrap="wrap">
            Start a debug session with the swiftdbg MCP tools (debug_set_breakpoints, debug_launch). This pane follows it live
            from {BASE}.
          </Text>
        </Box>
      )
    }

    const snap = state.snapshot ?? {}
    const stopped = state.status === 'stopped'
    const frames = snap.frames ?? []
    const sel = snap.selectedFrame ?? 0
    const frame = frames[sel]
    const viewing = await read($, view)
    const file = viewing?.file ?? frame?.file ?? Object.keys(state.breakpoints)[0] ?? null
    const lines = file ? (await read($, files))[file] : undefined
    const bps = new Set((file ? state.breakpoints[file] ?? [] : []).map(b => b.line))
    const cur = stopped && frame?.file === file ? frame?.line ?? -1 : -1
    const open = await read($, expanded)

    // A window of source around the line just given a breakpoint, else the
    // current line, else the first breakpoint.
    const span = Math.max(7, Math.min(21, rows - 24))
    const anchor = viewing?.file === file ? viewing.line : cur > 0 ? cur : [...bps][0] ?? 1
    const total = lines?.length ?? 0
    const lo = Math.max(1, Math.min(anchor - Math.floor(span / 2), total - span + 1))
    const hi = Math.min(total, lo + span - 1)
    const width = String(hi).length

    const statusColor = stopped ? 'warning' : state.status === 'running' ? 'success' : undefined
    const statusText =
      state.status + (snap.reason ? ` · ${snap.reason}` : '') + (state.status === 'exited' ? ` · code ${snap.exitCode}` : '')

    const varRows = (vars: DbgVar[] | undefined, depth: number): any[] =>
      (vars ?? []).flatMap(v => {
        const kids = v.ref ? open[String(v.ref)] : undefined
        const label = `${'  '.repeat(depth)}${v.ref ? (kids ? '▾ ' : '▸ ') : '  '}${v.name}: ${v.type ?? ''} = ${v.value ?? ''}`
        const row = v.ref ? (
          <Button
            key={`var-${v.ref}`}
            plain
            label={label}
            onPress={() =>
              kids
                ? void update($, expanded, m => {
                    const { [String(v.ref)]: _, ...rest } = m
                    return rest
                  })
                : void post($, 'expand', { ref: v.ref }).then(out =>
                    out.variables ? update($, expanded, m => ({ ...m, [String(v.ref)]: out.variables })) : undefined,
                  )
            }
          />
        ) : (
          <Text mono wrap="truncate-end">
            {label}
          </Text>
        )
        return [row, ...(kids ? varRows(kids, depth + 1) : [])]
      })

    const tail = (text: string, n: number) => text.split('\n').filter(Boolean).slice(-n)

    return (
      <Box flexDirection="column" gap={1}>
        {tabRow($, el, current)}
        <Box flexDirection="column">
          <Text color={statusColor} bold>
            {statusText}
          </Text>
          <Text dimColor wrap="truncate-middle">
            {state.program ?? ''}
          </Text>
        </Box>

        <Box flexDirection="row" gap={1} flexWrap="wrap">
          {stopped && <Button key="continue" variant="primary" label="Continue" onPress={() => void post($, 'continue')} />}
          {stopped && <Button key="over" label="Step over" onPress={() => void post($, 'over')} />}
          {stopped && <Button key="in" label="Step in" onPress={() => void post($, 'in')} />}
          {stopped && <Button key="out" label="Step out" onPress={() => void post($, 'out')} />}
          {state.status === 'running' && <Button key="pause" label="Pause" onPress={() => void post($, 'pause')} />}
        </Box>

        <Input
          key="add-breakpoint"
          label="Add breakpoint"
          placeholder="File.swift:42"
          submitLabel="set"
          onSubmit={value => void addBreakpoint($, value).then(msg => $.ui.toast(msg))}
        />

        <Box flexDirection="column">
          <Box flexDirection="row" gap={1}>
            <Text bold>{file ? base(file) : 'Source'}</Text>
            {viewing && stopped && frame?.file && (
              <Button key="follow" plain dimColor label="↩ current line" onPress={() => void update($, view, () => null)} />
            )}
          </Box>
          {!lines && <Text dimColor>{file ? 'Loading source…' : 'No breakpoints yet.'}</Text>}
          {lines &&
            lines.slice(lo - 1, hi).map((text, i) => {
              const n = lo + i
              const isCur = n === cur
              return (
                <Box key={`ln-${n}`} flexDirection="row" backgroundColor={isCur ? 'warning' : undefined}>
                  <Button
                    key={`bp-${n}`}
                    plain
                    dimColor={!bps.has(n)}
                    label={bps.has(n) ? '●' : '·'}
                    onPress={() => void post($, 'toggle', { file, line: n })}
                  />
                  <Text mono dimColor={!isCur} color={isCur ? 'inverseText' : undefined}>
                    {` ${String(n).padStart(width)} ${isCur ? '→' : ' '} `}
                  </Text>
                  <Text mono wrap="truncate-end" color={isCur ? 'inverseText' : undefined}>
                    {text || ' '}
                  </Text>
                </Box>
              )
            })}
        </Box>

        {stopped && (
          <Box flexDirection="column">
            <Text bold>Call stack</Text>
            {frames.map((f, i) => (
              <Button
                key={`frame-${i}`}
                plain
                dimColor={i !== sel}
                label={`${i === sel ? '›' : ' '} #${i} ${f.name}  ${base(f.file)}${f.line ? ':' + f.line : ''}`}
                onPress={() => void post($, 'frame', { index: i })}
              />
            ))}
          </Box>
        )}

        {stopped && (
          <Box flexDirection="column">
            <Text bold>Variables</Text>
            {(snap.locals ?? []).length === 0 && <Text dimColor>No locals</Text>}
            {varRows(snap.locals, 0)}
          </Box>
        )}

        {state.output && (
          <Box flexDirection="column">
            <Text bold>Program output</Text>
            {tail(state.output, 5).map(l => (
              <Text mono wrap="truncate-end">
                {l}
              </Text>
            ))}
          </Box>
        )}

        <Box flexDirection="column">
          <Text bold>Activity</Text>
          {(state.activity ?? []).slice(-6).map(a => {
            const who = a.split(' ')[1]?.replace(':', '')
            return (
              <Text wrap="truncate-end" color={who === 'agent' ? 'suggestion' : who === 'human' ? 'success' : undefined} dimColor={who === 'process'}>
                {a}
              </Text>
            )
          })}
        </Box>
      </Box>
    )
  })
}

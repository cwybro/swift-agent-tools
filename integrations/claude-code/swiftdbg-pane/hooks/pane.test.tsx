import { expect, mock, test } from 'claude-code/testing'

const FILE = '/proj/Sources/App/main.swift'
const SOURCE = Array.from({ length: 30 }, (_, i) => `line ${i + 1}`)

const STOPPED = {
  version: 3,
  status: 'stopped',
  program: '/proj/.build/debug/App',
  breakpoints: { [FILE]: [{ line: 18, condition: null, verified: true }] },
  snapshot: {
    reason: 'breakpoint',
    selectedFrame: 0,
    frames: [
      { id: 1, name: 'Cart.subtotal()', file: FILE, line: 18 },
      { id: 2, name: 'main', file: FILE, line: 25 },
    ],
    locals: [
      { name: 'total', type: 'Double', value: '0', ref: 0 },
      { name: 'item', type: 'App.Item', value: 'App.Item @ 0x1', ref: 7 },
    ],
  },
  output: '',
  activity: ['00:00:01 agent: launched App', '00:00:02 process: stopped (breakpoint) at main.swift:18'],
}

const PANE = (surface: 'desktop' | 'terminal') =>
  ({
    plugin: 'swiftdbg-pane',
    component: 'Pane',
    requestId: 'swiftdbg',
    surface,
    props: {
      title: 'Swift debugger',
      isFocused: false,
      bodyColumns: 60,
      placement: 'dock',
      scroll: { offset: 0, bodyRows: 40 },
      view: {},
    },
  }) as const

const TOASTS: string[] = []

function fakeServer(on: any, posts: { url: string; body: any }[], opened: string[]) {
  on('command.register', () => ({ value: { command: 'swiftdbg' } }))
  on('ui.open', (_: any, e: any) => {
    opened.push(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.toast', (_: any, e: any) => {
    TOASTS.push(typeof e === 'string' ? e : e.text ?? JSON.stringify(e))
    return { value: undefined }
  })
  on('session.start', (_: any, e: any) => ({ cwd: e.cwd }))
  // A live copy, so a toggle shows up in the next /state like the real server.
  const state = JSON.parse(JSON.stringify(STOPPED))
  on('http.fetch', (_: any, e: any) => {
    const ok = (body: unknown) => ({ value: { status: 200, ok: true, headers: {}, text: JSON.stringify(body) } })
    if (e.url.endsWith('/state')) return ok(state)
    if (e.url.includes('/source?')) {
      const path = decodeURIComponent(e.url.split('path=')[1])
      return ok({ path, lines: DISK[path]?.split('\n') ?? SOURCE })
    }
    posts.push({ url: e.url, body: JSON.parse(e.init?.body ?? '{}') })
    if (e.url.endsWith('/toggle')) {
      const { file, line } = JSON.parse(e.init.body)
      const list = state.breakpoints[file] ?? []
      state.breakpoints[file] = list.some((b: any) => b.line === line)
        ? list.filter((b: any) => b.line !== line)
        : [...list, { line, condition: null, verified: true }]
      state.version++
      return ok(state.breakpoints)
    }
    if (e.url.endsWith('/expand'))
      return ok({ variables: [{ name: 'price', type: 'Double', value: '4.5', ref: 0 }] })
    return ok({ status: 'stopped' })
  })
}

for (const surface of ['desktop', 'terminal'] as const) {
  test(`a stopped session draws and its controls post to swiftdbg (${surface})`, async ($, on) => {
    const posts: { url: string; body: any }[] = []
    const opened: string[] = []
    const clock = mock.clock(on)
    fakeServer(on, posts, opened)

    await $.session.start({ cwd: '/', surface, isInteractive: true })
    await clock.advance(700)
    await clock.advance(700)

    // The pane opens itself when a session becomes active.
    expect(opened).toContain('swiftdbg')

    const ui = await $.ui.mount(PANE(surface))
    expect((await ui.find({ type: 'Text', text: /stopped · breakpoint/ }))?.text).toBe('stopped · breakpoint')
    // Current line marked, breakpoint dot drawn, frames listed.
    expect(await ui.find({ type: 'Text', text: /18 →/ })).toBeDefined()
    expect(await ui.find({ type: 'Button', key: 'bp-18' })).toBeDefined()
    expect((await ui.findAll({ type: 'Button', text: /#\d/ })).length).toBe(2)

    await ui.press({ key: 'bp-20' })
    expect(posts.at(-1)).toEqual({ url: 'http://127.0.0.1:7311/toggle', body: { file: FILE, line: 20 } })

    await ui.press({ key: 'continue' })
    expect(posts.at(-1)?.url).toBe('http://127.0.0.1:7311/continue')

    await ui.press({ key: 'frame-1' })
    expect(posts.at(-1)).toEqual({ url: 'http://127.0.0.1:7311/frame', body: { index: 1 } })

    await ui.press({ key: 'var-7' })
    expect(posts.at(-1)?.url).toBe('http://127.0.0.1:7311/expand')
    expect(await ui.find({ type: 'Text', text: /price: Double = 4.5/ })).toBeDefined()

    await ui.unmount()
  })
}

test('a row above the prompt opens the pane while a session is active', async ($, on) => {
  const posts: { url: string; body: any }[] = []
  const opened: string[] = []
  const clock = mock.clock(on)
  fakeServer(on, posts, opened)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await clock.advance(700)
  opened.length = 0

  const band = await $.ui.mount({
    plugin: 'swiftdbg-pane',
    component: 'AbovePrompt',
    requestId: 'swiftdbg-pane',
    surface: 'desktop',
    props: { hasSurvey: false, bodyColumns: 80 } as any,
  })
  expect((await band.find({ type: 'Text', text: /Debugger/ }))?.text).toBe('Debugger · stopped at main.swift:18')
  await band.press({ key: 'open' })
  expect(opened).toEqual(['swiftdbg'])
  await band.press({ key: 'band-continue' })
  expect(posts.at(-1)?.url).toBe('http://127.0.0.1:7311/continue')
  await band.unmount()
})

// A project on disk: /proj with two Cart.swift files and main.swift, plus build output to skip.
const TREE: Record<string, { name: string; kind: 'file' | 'dir' }[]> = {
  '/proj': [
    { name: 'Sources', kind: 'dir' },
    { name: '.build', kind: 'dir' },
  ],
  '/proj/Sources': [
    { name: 'App', kind: 'dir' },
    { name: 'Store', kind: 'dir' },
  ],
  '/proj/Sources/App': [
    { name: 'main.swift', kind: 'file' },
    { name: 'Cart.swift', kind: 'file' },
  ],
  '/proj/Sources/Store': [{ name: 'Cart.swift', kind: 'file' }],
  '/proj/.build': [{ name: 'Generated.swift', kind: 'file' }],
}

function fakeDisk(on: any) {
  on('fs.list', (_: any, e: any) => ({
    value: (TREE[e.path] ?? []).map(x => ({ ...x, size: 1, mtimeMs: 0 })),
  }))
  on('fs.exists', (_: any, e: any) => ({ value: Object.values(TREE).flat().length > 0 && e.path in TREE }))
}

test('typing File.swift:line in the pane sets a breakpoint and shows that line', async ($, on) => {
  const posts: { url: string; body: any }[] = []
  const toasts = TOASTS
  const clock = mock.clock(on)
  fakeServer(on, posts, [])
  fakeDisk(on)
  await $.session.start({ cwd: '/proj', surface: 'desktop', isInteractive: true })
  await clock.advance(700)

  const ui = await $.ui.mount(PANE('desktop'))
  await ui.input({ key: 'add-breakpoint', text: 'App/Cart.swift:3' })
  expect(posts.at(-1)).toEqual({
    url: 'http://127.0.0.1:7311/toggle',
    body: { file: '/proj/Sources/App/Cart.swift', line: 3 },
  })
  expect(toasts.at(-1)).toContain('Breakpoint set at Cart.swift:3')
  // The source view moved to the new file, with the new dot.
  expect((await ui.find({ type: 'Text', text: /^Cart\.swift$/ }))?.text).toBe('Cart.swift')
  expect((await ui.find({ type: 'Button', key: 'bp-3' }))?.props.label).toBe('●')

  // Ambiguous and unknown names explain themselves and post nothing.
  const before = posts.length
  await ui.input({ key: 'add-breakpoint', text: 'Cart.swift:3' })
  expect(toasts.at(-1)).toContain('matches 2 files')
  await ui.input({ key: 'add-breakpoint', text: 'Crt.swift:3' })
  expect(toasts.at(-1)).toContain('No Crt.swift in the project')
  await ui.input({ key: 'add-breakpoint', text: 'Generated.swift:1' })
  expect(toasts.at(-1)).toContain('No Generated.swift')
  await ui.input({ key: 'add-breakpoint', text: 'nonsense' })
  expect(toasts.at(-1)).toContain('File.swift:42')
  expect(posts.length).toBe(before)
  await ui.unmount()
})

test('/swiftdbg break File.swift:line sets a breakpoint without the pane', async ($, on) => {
  const posts: { url: string; body: any }[] = []
  const clock = mock.clock(on)
  fakeServer(on, posts, [])
  fakeDisk(on)
  await $.session.start({ cwd: '/proj', surface: 'desktop', isInteractive: true })
  await clock.advance(700)

  const out: any = await $.command.run({ command: 'swiftdbg', args: 'break main.swift:22' } as any)
  expect(JSON.stringify(out)).toContain('Breakpoint set at main.swift:22')
  expect(posts.at(-1)?.body).toEqual({ file: '/proj/Sources/App/main.swift', line: 22 })

  const again: any = await $.command.run({ command: 'swiftdbg', args: 'break main.swift:22' } as any)
  expect(JSON.stringify(again)).toContain('already set')
})

const DISK: Record<string, string> = {
  '/proj/Sources/App/main.swift': Array.from({ length: 60 }, (_, i) => (i === 41 ? 'let total = cart.total()' : `// main ${i + 1}`)).join('\n'),
  '/proj/Sources/App/Cart.swift': 'struct Cart {\n  func total() -> Double { 0 }\n}',
  '/proj/Sources/Store/Cart.swift': 'struct StoreCart {}',
}

function fakeFiles(on: any, grep: 'works' | 'missing') {
  fakeDisk(on)
  on('fs.read', (_: any, e: any) => {
    if (!(e.path in DISK)) throw new Error('ENOENT')
    return { value: DISK[e.path] }
  })
  on('ui.focus', { plugin: '*' }, () => ({ value: {} }))
  on('process.run', (_: any, e: any) => {
    if (grep === 'missing') throw new Error('not allowed')
    const q = e.argv.at(-2).toLowerCase()
    const out: string[] = []
    for (const [path, text] of Object.entries(DISK))
      text.split('\n').forEach((l, i) => l.toLowerCase().includes(q) && out.push(`${path.slice('/proj/'.length)}:${i + 1}:${l}`))
    return { value: { exitCode: out.length ? 0 : 1, stdout: out.join('\n'), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
}

for (const grep of ['works', 'missing'] as const) {
  test(`the Files tab lists, filters, searches (grep ${grep}) and opens files`, async ($, on) => {
    const posts: { url: string; body: any }[] = []
    const clock = mock.clock(on)
    fakeServer(on, posts, [])
    fakeFiles(on, grep)
    await $.session.start({ cwd: '/proj', surface: 'desktop', isInteractive: true })
    await clock.advance(700)

    const ui = await $.ui.mount(PANE('desktop'))
    await ui.press({ key: 'tab-files' })
    // .build is skipped; files are sorted by project-relative path.
    expect((await ui.find({ type: 'Text', text: /Swift files/ }))?.text).toBe('3 of 3 Swift files')
    const names = (await ui.findAll({ type: 'Button', text: /\.swift/ })).map(x => x.text.trim())
    expect(names).toEqual(['Sources/App/Cart.swift', '● Sources/App/main.swift', 'Sources/Store/Cart.swift'].map(s => s.trim()))

    // Typing filters by name.
    await ui.input({ key: 'file-filter', text: 'store', kind: 'change' } as any)
    expect((await ui.find({ type: 'Text', text: /Swift files/ }))?.text).toBe('1 of 3 Swift files')

    // Text search opens the file at the matching line.
    await ui.input({ key: 'text-search', text: 'cart.total' })
    expect((await ui.find({ type: 'Text', text: /matches/ }))?.text).toBe('1 matches for “cart.total”')
    await ui.press({ key: 'hit-0' })
    expect((await ui.find({ type: 'Text', text: /Sources\/App\/main.swift/ }))?.text).toBe('Sources/App/main.swift')
    expect(await ui.find({ type: 'Text', text: /42 ›/ })).toBeDefined()

    // The gutter toggles breakpoints; paging moves through the file.
    await ui.press({ key: 'fbp-42' })
    expect(posts.at(-1)).toEqual({ url: 'http://127.0.0.1:7311/toggle', body: { file: '/proj/Sources/App/main.swift', line: 42 } })
    await ui.press({ key: 'page-down' })
    expect(await ui.find({ type: 'Text', text: /of 60/ })).toBeDefined()

    await ui.press({ key: 'back' })
    await ui.press({ key: 'tab-debug' })
    expect(await ui.find({ type: 'Button', key: 'continue' })).toBeDefined()
    await ui.unmount()
  })
}

test('f and g switch to the Files tab from the Debug tab', async ($, on) => {
  // The kit gives no hook for $.ui.focus itself; the focus move is checked in the app.
  const clock = mock.clock(on)
  fakeServer(on, [], [])
  fakeDisk(on)
  on('fs.read', () => ({ value: '' }))
  await $.session.start({ cwd: '/proj', surface: 'terminal', isInteractive: true })
  await clock.advance(700)

  const ui = await $.ui.mount(PANE('terminal'))
  expect((await ui.find({ type: 'Button', key: 'find-file' }))?.props.hotkey).toBe('f')
  expect((await ui.find({ type: 'Button', key: 'find-text' }))?.props.hotkey).toBe('g')
  expect((await ui.find({ type: 'Button', key: 'tab-debug' }))?.props.hotkey).toBe('1')
  expect((await ui.find({ type: 'Button', key: 'tab-files' }))?.props.hotkey).toBe('2')
  expect(await ui.find({ type: 'Input', key: 'file-filter' })).toBeUndefined()
  await ui.press({ key: 'find-file' })
  expect(await ui.find({ type: 'Input', key: 'file-filter' })).toBeDefined()
  await ui.press({ key: 'tab-debug' })
  await ui.press({ key: 'find-text' })
  expect(await ui.find({ type: 'Input', key: 'text-search' })).toBeDefined()
  await ui.unmount()
})

test('without a server the pane says so', async ($, on) => {
  const clock = mock.clock(on)
  on('command.register', () => ({ value: { command: 'swiftdbg' } }))
  on('session.start', (_: any, e: any) => ({ cwd: e.cwd }))
  on('http.fetch', () => {
    throw new Error('connection refused')
  })
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  for (let i = 0; i < 4; i++) await clock.advance(700)

  const ui = await $.ui.mount(PANE('desktop'))
  expect((await ui.find({ type: 'Text', text: /not running/ }))?.text).toBe('swiftdbg server not running')
  await ui.unmount()
})

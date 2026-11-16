import { expect, mock, test } from 'claude-code/testing'

const FILE = '/proj/Features/Profile/ProfileView.swift'
const OTHER = '/proj/Features/Feed/FeedView.swift'
const DEVICES = [
  { udid: 'A', name: 'iPhone 18 Pro', runtime: 'iOS 27.2', state: 'Booted', runtimeID: 'com.apple.CoreSimulator.SimRuntime.iOS-27-2' },
  { udid: 'B', name: 'iPad Air 11-inch (M4)', runtime: 'iOS 27.2', state: 'Shutdown', runtimeID: 'com.apple.CoreSimulator.SimRuntime.iOS-27-2' },
]
const STRIPS = [0, 1, 2].map(i => ({ path: `/s/strip-${i}.png`, format: 'png', pixelWidth: 804, pixelHeight: 1024, height: 256 }))

/** What `swiftpreview serve` prints for an iOS host: its devices, then a frame in three strips. */
const SERVE_OUTPUT = [
  { event: 'status', phase: 'building', message: 'bazel build //:preview_host' },
  { event: 'host', platform: 'ios', devices: DEVICES, device: 'A' },
  {
    event: 'frame',
    seq: 1,
    png: '/s/frames/frame-1.png',
    width: 402,
    height: 768,
    previews: [
      { name: 'Default', line: 40 },
      { name: 'Long name', line: 44 },
    ],
    selected: 0,
    reload: 'initial',
    timings: { compile: 0.4, load: 0.1, render: 0.1 },
    strips: STRIPS,
    // iOS: the strips show the device bezel, wider than the 402 pt screen.
    stripWidth: 458,
  },
  { event: 'status', phase: 'watching' },
]
  .map(e => JSON.stringify(e))
  .join('\n')

/** What `swiftpreview discover` prints for the workspace. */
const DISCOVERY = {
  workspace: '/proj',
  hosts: ['//:preview_host'],
  files: [
    { file: OTHER, hosts: ['//:preview_host'], previews: [{ index: 0, name: 'Feed', line: 12 }] },
    {
      file: FILE,
      hosts: ['//:preview_host'],
      previews: [
        { index: 0, name: 'Default', line: 40 },
        { index: 1, name: 'Long name', line: 44 },
      ],
    },
  ],
}

type Fakes = { writes: { path: string; text: string }[]; spawned: string[][]; ran: string[][]; opened: string[]; titles: Record<string, string> }

function fakeEngine(on: any, spawnFails = false): Fakes & { release: () => void } {
  const f: Fakes = { writes: [], spawned: [], ran: [], opened: [], titles: {} }
  on('command.register', () => ({ value: { command: 'preview' } }))
  on('ui.open', (_: any, e: any) => {
    if (!f.opened.includes(e.id)) f.opened.push(e.id)
    if (e.title) f.titles[e.id] = e.title
    return { value: { isPlaced: true } }
  })
  on('ui.panes', () => ({
    value: f.opened.map((id, i) => ({ id, title: id, isShown: i === f.opened.length - 1, isFocused: false, isPlaced: true })),
  }))
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))
  on('session.start', (_: any, e: any) => ({ cwd: e.cwd }))
  on('fs.read', () => ({ value: { base64: 'iVBORw0KGgo=' } }))
  on('fs.exists', (_: any, e: any) => ({ value: !String(e.path ?? e).includes('Missing') }))
  on('fs.write', (_: any, e: any) => {
    f.writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('process.run', (_: any, e: any) => {
    f.ran.push([...e.argv])
    const verb = e.argv[1]
    const stdout = verb === 'discover' ? JSON.stringify(DISCOVERY) : verb === 'devices' ? JSON.stringify(DEVICES) : ''
    return { value: { exitCode: 0, stdout, stderr: '' } }
  })
  let release: () => void = () => {}
  const exited = new Promise<void>(r => (release = r))
  on('process.spawn', async function* (_: any, e: any) {
    f.spawned.push([...e.argv])
    if (spawnFails) throw new Error('ENOENT: Executable not found in $PATH: "swiftpreview"')
    yield { stream: 'stdout', text: SERVE_OUTPUT + '\n' }
    // Keep running until the test stops it.
    await exited
    return { value: { code: 0, signal: null } }
  })
  return { ...f, release: () => release() }
}

const PANE = {
  plugin: 'swiftui-previews',
  component: 'Pane',
  requestId: 'swiftui-preview',
  surface: 'desktop',
  props: { title: 'SwiftUI Preview', isFocused: false, bodyColumns: 60, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} },
} as const

test('/preview starts swiftpreview serve and the pane draws its frame, previews and devices', async ($, on) => {
  const clock = mock.clock(on)
  const fx = fakeEngine(on)

  await $.session.start({ cwd: '/proj', surface: 'desktop', isInteractive: true })
  const out: any = await $.command.run({ command: 'preview', args: 'Features/Profile/ProfileView.swift' } as any)
  expect(out.text).toContain('Previewing ProfileView.swift')
  await clock.advance(50)

  expect(fx.spawned[0]?.slice(1, 3)).toEqual(['serve', FILE])
  expect(fx.spawned[0]).toContain('--session')
  // The tab's title follows the preview shown.
  expect(fx.titles['swiftui-preview']).toBe('ProfileView.swift › Default')

  const ui = await $.ui.mount(PANE as any)
  // Every strip is drawn, each with its own alt (a blank alt is dropped on desktop).
  const svgs: any[] = await ui.findAll({ type: 'Svg' })
  expect(svgs.length).toBe(3)
  const alts = svgs.map(s => s.props.alt)
  expect(new Set(alts).size).toBe(3)
  expect(alts[1]).toBe('SwiftUI preview Default, part 2 of 3')
  expect(svgs[0].props.width).toBe(458)


  // One button per preview; picking one asks serve to select it.
  expect(await ui.find({ type: 'Button', text: 'Long name' })).toBeDefined()
  // iOS hosts get the device picker.
  expect(await ui.find({ type: 'Select', key: 'device' })).toBeDefined()

  await ui.press({ key: 'scheme' })
  const last = JSON.parse(fx.writes.at(-1)?.text ?? '{}')
  expect(fx.writes.at(-1)?.path).toBe('/proj/.swiftpreview/claude/control.json')
  expect(last.cmd).toBe('scheme')
  expect(last.value).toBe('dark')

  await ui.unmount()
  fx.release()
  await clock.advance(400)
})

test('the pane lists the workspace previews on request and opens one', async ($, on) => {
  const clock = mock.clock(on)
  const fx = fakeEngine(on)
  await $.session.start({ cwd: '/proj', surface: 'desktop', isInteractive: true })
  await $.command.run({ command: 'preview', args: FILE } as any)
  await clock.advance(50)

  const ui = await $.ui.mount(PANE as any)
  await ui.press({ key: 'discover' })
  expect(fx.ran.some(a => a[1] === 'discover' && a[2] === '/proj')).toBe(true)
  const browse: any = await ui.find({ type: 'Select', key: 'browse' })
  expect(browse.props.options.map((o: any) => o.label)).toEqual([
    'FeedView.swift › Feed',
    'ProfileView.swift › Default',
    'ProfileView.swift › Long name',
  ])
  expect(browse.props.value).toBe(`0:${FILE}`)

  // Picking another file's preview opens it in the running serve.
  await ui.select({ key: 'browse', value: `0:${OTHER}` })
  const open = JSON.parse(fx.writes.at(-1)?.text ?? '{}')
  expect(open.cmd).toBe('open')
  expect(open.file).toBe(OTHER)
  // Until FeedView's first frame, ProfileView's is stale: loading replaces it.
  expect(await ui.find({ type: 'Text', text: /Loading FeedView\.swift/ })).toBeDefined()

  await ui.unmount()
  fx.release()
  await clock.advance(400)
})

test('the file name opens the source at the preview line in the editor', async ($, on) => {
  const clock = mock.clock(on)
  const fx = fakeEngine(on)
  await $.session.start({ cwd: '/proj', surface: 'desktop', isInteractive: true })
  await $.command.run({ command: 'preview', args: FILE } as any)
  await clock.advance(50)
  const ui = await $.ui.mount(PANE as any)
  await ui.press({ key: 'discover' })
  await clock.advance(50)
  await ui.select({ key: 'browse', value: `0:${OTHER}` })
  // Before FeedView's first frame, the catalog knows its line (Xcode by default).
  await ui.press({ key: 'open-file' })
  expect(fx.ran.at(-1)).toEqual(['xed', '--line', '12', OTHER])
  await ui.unmount()
  fx.release()
  await clock.advance(400)
})

test('workspace discovery waits for the button; the pickers list the file meanwhile', async ($, on) => {
  const clock = mock.clock(on)
  const fx = fakeEngine(on)
  await $.session.start({ cwd: '/proj', surface: 'desktop', isInteractive: true })
  await $.command.run({ command: 'preview', args: FILE } as any)
  await clock.advance(50)
  // Discovery runs Bazel queries: not on start (its option is off by default).
  expect(fx.ran.some(a => a[1] === 'discover')).toBe(false)
  const ui = await $.ui.mount(PANE as any)
  const own: any = await ui.find({ type: 'Select', key: 'browse' })
  expect(own.props.options.map((o: any) => o.label)).toEqual(['ProfileView.swift › Default', 'ProfileView.swift › Long name'])
  expect(await ui.find({ type: 'Button', key: 'discover' } as any)).toBeDefined()
  await ui.unmount()
  fx.release()
  await clock.advance(400)
})

test('a new tab runs its own swiftpreview in its own session folder', async ($, on) => {
  const clock = mock.clock(on)
  const fx = fakeEngine(on)
  await $.session.start({ cwd: '/proj', surface: 'desktop', isInteractive: true })
  await $.command.run({ command: 'preview', args: FILE } as any)
  await clock.advance(50)
  const out: any = await $.command.run({ command: 'preview', args: `new ${OTHER}` } as any)
  expect(out.text).toContain('in a new tab')
  await clock.advance(50)

  expect(fx.opened).toEqual(['swiftui-preview', 'swiftui-preview-2'])
  expect(fx.spawned.length).toBe(2)
  const second = fx.spawned[1] ?? []
  const sessionOf = (argv: string[]) => argv[argv.indexOf('--session') + 1]
  expect(sessionOf(fx.spawned[0] ?? [])).toBe('/proj/.swiftpreview/claude')
  expect(sessionOf(second)).toBe('/proj/.swiftpreview/claude-2')
  // The first tab's iOS host holds simulator A: the new tab gets another.
  expect(second[second.indexOf('--simulator') + 1]).toBe('B')

  // Commands go to the tab shown (the new one).
  await $.command.run({ command: 'preview', args: 'dark' } as any)
  expect(fx.writes.at(-1)?.path).toBe('/proj/.swiftpreview/claude-2/control.json')

  const ui = await $.ui.mount({ ...PANE, requestId: 'swiftui-preview-2' } as any)
  expect(await ui.find({ type: 'Button', key: 'open-file' })).toBeDefined()
  await ui.unmount()
  fx.release()
  await clock.advance(400)
})

test('/preview list searches the given folder, else the project folder', async ($, on) => {
  const fx = fakeEngine(on)
  await $.session.start({ cwd: '/proj', surface: 'desktop', isInteractive: true })
  const out: any = await $.command.run({ command: 'preview', args: 'list' } as any)
  expect(fx.ran.at(-1)).toEqual(['swiftpreview', 'discover', '/proj'])
  expect(out.text).toContain('Features/Profile/ProfileView.swift\n  0: Default\n  1: Long name')
  await $.command.run({ command: 'preview', args: 'list /elsewhere/app' } as any)
  expect(fx.ran.at(-1)).toEqual(['swiftpreview', 'discover', '/elsewhere/app'])
  // A wrong path is caught before anything starts.
  const missing: any = await $.command.run({ command: 'preview', args: 'Missing.swift' } as any)
  expect(missing.text).toContain('No such file: /proj/Missing.swift')
  expect(fx.spawned.length).toBe(0)
})

test('the zoom buttons and /preview zoom scale the frame in 25% steps', async ($, on) => {
  const clock = mock.clock(on)
  const fx = fakeEngine(on)
  await $.session.start({ cwd: '/proj', surface: 'desktop', isInteractive: true })
  await $.command.run({ command: 'preview', args: FILE } as any)
  await clock.advance(50)
  const ui = await $.ui.mount(PANE as any)

  // Zoom steps down by 25%, never past 25%, and scales every strip.
  // At 100%, + is dim text, not a button; - is a button.
  const off: any[] = await ui.findAll({ type: 'Text', text: '+' })
  expect(off[0]?.props.dimColor).toBe(true)
  await ui.press({ key: 'zoom-out' })
  await ui.press({ key: 'zoom-out' })
  const half: any[] = await ui.findAll({ type: 'Svg' })
  expect(half[0].props.width).toBe(229)
  expect(half[0].props.height).toBe(128)
  await $.command.run({ command: 'preview', args: 'zoom 100' } as any)
  const full: any[] = await ui.findAll({ type: 'Svg' })
  expect(full[0].props.width).toBe(458)

  await ui.unmount()
  fx.release()
  await clock.advance(400)
})

test('the pane says how to start when nothing is previewed', async ($, on) => {
  fakeEngine(on)
  await $.session.start({ cwd: '/proj', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' } as any)
  expect(await ui.find({ type: 'Text', text: /Run \/preview/ })).toBeDefined()
  await ui.unmount()
})

test('a swiftpreview that cannot start says why in the pane', async ($, on) => {
  const clock = mock.clock(on)
  const fx = fakeEngine(on, true)
  await $.session.start({ cwd: '/proj', surface: 'desktop', isInteractive: true })
  await $.command.run({ command: 'preview', args: FILE } as any)
  await clock.advance(50)
  const ui = await $.ui.mount(PANE as any)
  expect(await ui.find({ type: 'Text', text: 'Preview starting failed' })).toBeDefined()
  const code: any = await ui.find({ type: 'Code' } as any)
  expect(code.props.source).toContain('Could not run swiftpreview')
  await ui.unmount()
  fx.release()
})

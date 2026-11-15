import { expect, mock, test } from 'claude-code/testing'

const FILE = '/proj/Features/Profile/ProfileView.swift'
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

function fakeEngine(on: any, writes: { path: string; text: string }[], spawned: string[][]) {
  on('command.register', () => ({ value: { command: 'preview' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.status', () => ({ value: undefined }))
  on('session.start', (_: any, e: any) => ({ cwd: e.cwd }))
  on('fs.read', () => ({ value: { base64: 'iVBORw0KGgo=' } }))
  on('fs.write', (_: any, e: any) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  let release: () => void = () => {}
  const exited = new Promise<void>(r => (release = r))
  on('process.spawn', async function* (_: any, e: any) {
    spawned.push([...e.argv])
    yield { stream: 'stdout', text: SERVE_OUTPUT + '\n' }
    // Keep running until the test stops it.
    await exited
    return { value: { code: 0, signal: null } }
  })
  return release
}

const PANE = {
  plugin: 'swiftui-previews',
  component: 'Pane',
  requestId: 'swiftui-preview',
  surface: 'desktop',
  props: { title: 'SwiftUI Preview', isFocused: false, bodyColumns: 60, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} },
} as const

test('/preview starts swiftpreview serve and the pane draws its frame, previews and devices', async ($, on) => {
  const writes: { path: string; text: string }[] = []
  const spawned: string[][] = []
  const clock = mock.clock(on)
  const release = fakeEngine(on, writes, spawned)

  await $.session.start({ cwd: '/proj', surface: 'desktop', isInteractive: true })
  const out: any = await $.command.run({ command: 'preview', args: 'Features/Profile/ProfileView.swift' } as any)
  expect(out.text).toContain('Previewing ProfileView.swift')
  await clock.advance(50)

  expect(spawned[0]?.slice(1, 3)).toEqual(['serve', FILE])
  expect(spawned[0]).toContain('--session')

  const ui = await $.ui.mount(PANE as any)
  // Every strip is drawn, each with its own alt (a blank alt is dropped on desktop).
  const svgs = await ui.findAll({ type: 'Svg' })
  expect(svgs.length).toBe(3)
  const alts = svgs.map((s: any) => s.props.alt)
  expect(new Set(alts).size).toBe(3)
  expect(alts[1]).toBe('SwiftUI preview Default, part 2 of 3')
  expect(svgs[0].props.width).toBe(458)

  // One button per preview; picking one asks serve to select it.
  expect(await ui.find({ type: 'Button', text: 'Long name' })).toBeDefined()
  // iOS hosts get the device picker.
  expect(await ui.find({ type: 'Select', key: 'device' })).toBeDefined()

  await ui.press({ key: 'scheme' })
  const last = JSON.parse(writes.at(-1)?.text ?? '{}')
  expect(writes.at(-1)?.path).toBe('/proj/.swiftpreview/claude/control.json')
  expect(last.cmd).toBe('scheme')
  expect(last.value).toBe('dark')

  await ui.unmount()
  release()
  await clock.advance(400)
})

test('the pane says how to start when nothing is previewed', async ($, on) => {
  fakeEngine(on, [], [])
  await $.session.start({ cwd: '/proj', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' } as any)
  expect(await ui.find({ type: 'Text', text: /Run \/preview/ })).toBeDefined()
  await ui.unmount()
})

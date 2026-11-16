/** How the host draws a frame: `auto` picks per frame. */
export type RendererMode = 'auto' | 'swiftui' | 'window'

export type PreviewInfo = { name: string; line: number }

export type PreviewSession = {
  /** Absolute path of the Swift file shown. */
  file: string
  /** Directory swiftpreview reads control.json from and writes frames to. */
  sessionDir: string
  isRunning: boolean
  scheme: 'light' | 'dark' | null
  /** Missing in sessions stored before the renderer option: means `auto`. */
  renderer?: RendererMode
  /** iOS: the simulator's UDID picked in the pane; missing means the default. */
  simulator?: string
  /** The swiftui_preview_host picked when several include the file. */
  host?: string
}

/** An available iOS simulator, as `swiftpreview devices` lists it. */
export type SimDevice = { udid: string; name: string; runtime: string; state: string; runtimeID: string }

/** What the running host reported: its platform, and for iOS the simulators to pick from. */
export type PreviewHostInfo = {
  platform: string
  devices: SimDevice[]
  /** UDID of the simulator in use. */
  device: string | null
}

export type PreviewStatus = { phase: string; message: string }

export type PreviewFrame = {
  seq: number
  /** Base64 JPEG thumbnail (under ~90 KB); empty when `strips` carry the frame. */
  jpeg: string
  png: string
  width: number
  height: number
  previews: PreviewInfo[]
  selected: number
  reload: string
  /** Seconds. */
  compile: number
  render: number
  /** Which renderer drew this frame (`swiftui` or `window`), and why. */
  renderer?: string
  rendererReason?: string
  /** The frame at 2x in slices the pane's SVG element can hold, top to bottom. */
  strips?: FrameStrip[]
  /** The strips' width in points when it isn't `width`: iOS frames come inside the device's bezel. */
  stripWidth?: number
}

export type FrameStrip = { path: string; format: string; pixelWidth: number; pixelHeight: number; height: number }

export type PreviewError = {
  phase: string
  message: string
  seq: number
  /** Phase `host`: the preview hosts that include the file, to pick from. */
  hosts?: string[]
}

/** One preview a workspace can render, as `swiftpreview discover` lists it. */
export type CatalogEntry = { file: string; index: number; name: string; line: number; workspace?: string }

/** Every preview in the tab's workspace, found without a build. */
export type PreviewCatalog = {
  workspace: string
  entries: CatalogEntry[]
  /** Set while discovery runs, or when it failed. */
  state: 'ready' | 'finding' | 'failed'
  message?: string
}

/** One SwiftUI Preview pane (tab): its own `swiftpreview serve` and what it last showed. */
export type PreviewTab = {
  session: PreviewSession | null
  status: PreviewStatus
  frame: PreviewFrame | null
  error: PreviewError | null
  host: PreviewHostInfo | null
  catalog: PreviewCatalog | null
  /** Set from starting a run or opening another file until its first frame or error: the last frame is stale. */
  loading?: boolean
  /** How large the pane draws the frame, in percent (25, 50, 75 or 100); missing means 100. */
  zoom?: number
}

declare module 'claude-code' {
  interface PluginState {
    'swiftui-previews': {
      /** By pane id: `swiftui-preview`, then `swiftui-preview-2`, … */
      tabs: Shaped<Record<string, PreviewTab>>
    }
  }
}

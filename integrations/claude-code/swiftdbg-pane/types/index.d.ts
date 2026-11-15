export type DbgVar = { name: string; type: string | null; value: string | null; ref: number }
export type DbgFrame = { id: number; name: string; file: string | null; line: number | null }
export type DbgState = {
  version: number
  status: 'idle' | 'running' | 'stopped' | 'exited'
  program: string | null
  breakpoints: Record<string, { line: number; condition: string | null; verified: boolean | null }[]>
  snapshot: {
    reason?: string
    frames?: DbgFrame[]
    selectedFrame?: number
    locals?: DbgVar[]
    exitCode?: number | null
  }
  output: string
  activity: string[]
}
export type Hit = { file: string; line: number; text: string }
/** The Files tab: name filter, text search and the file open in the viewer. */
export type Browse = {
  filter: string
  query: string
  hits: Hit[] | null
  searching: boolean
  open: { file: string; line: number | null; top: number } | null
}
/** null: the swiftdbg server is not reachable. */
export type Live = { state: DbgState | null; error: string | null }

declare module 'claude-code' {
  interface PluginState {
    'swiftdbg-pane': {
      live: Shaped<Live>
      files: Shaped<Record<string, string[]>>
      expanded: Shaped<Record<string, DbgVar[]>>
      /** Where the person last put a breakpoint: the source view shows it until the next stop. */
      view: Shaped<{ file: string; line: number } | null>
      tab: Shaped<'debug' | 'files'>
      browse: Shaped<Browse>
    }
  }
}

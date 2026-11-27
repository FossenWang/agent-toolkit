import plugin from "../../opencode/plugins/warming/index.ts"

export type Ctx = Parameters<typeof plugin.setup>[0]

export type FakeOptions = {
  /** 传给插件的 options */
  options?: Record<string, unknown>
  /** session.get 的返回值；undefined 表示查不到 */
  session?: { time?: { archived?: number; busy?: number }; title?: string } | null
  /** 每次 generate 的缓存用量；函数形式可以随次数变化 */
  usage?: { read: number; write: number } | (() => { read: number; write: number })
}

/** 内存 storage，行为与 clean-tmp 测试里的实现一致 */
export const memoryStorage = (preset: Record<string, unknown> = {}) => {
  const data = new Map(Object.entries(preset))
  return {
    data,
    get: async (key: string) => data.get(key),
    set: async (key: string, value: unknown) => void data.set(key, value),
    remove: async (key: string) => void data.delete(key),
  }
}

/** 手动推事件的异步流 */
export const eventQueue = () => {
  const items: { type: string; data: { sessionID: string } }[] = []
  let wake: (() => void) | undefined
  let closed = false

  const push = (type: string, sessionID = "ses_test") => {
    items.push({ type, data: { sessionID } })
    wake?.()
  }

  const close = () => {
    closed = true
    wake?.()
  }

  const iterate = async function* (signal?: AbortSignal) {
    for (;;) {
      if (closed || signal?.aborted) return
      if (items.length === 0) {
        await new Promise<void>((resolve) => {
          wake = resolve
          signal?.addEventListener("abort", () => resolve(), { once: true })
        })
        wake = undefined
        continue
      }
      yield items.shift()
    }
  }

  return { push, close, iterate }
}

export const waitFor = async (check: () => boolean, timeout = 2000) => {
  const started = Date.now()
  while (!check()) {
    if (Date.now() - started > timeout) throw new Error("waitFor timeout")
    await Bun.sleep(10)
  }
}

export const createFake = async (options: FakeOptions = {}) => {
  const storage = memoryStorage()
  const queue = eventQueue()
  const pings: string[] = []
  const synthetic: string[] = []
  let command: { name: string; execute: (input: { sessionID: string; prompt: { text: string } }) => Promise<void> } | undefined

  let count = 0
  const ctx = {
    options: options.options ?? {},
    storage,
    event: { subscribe: ({ signal }: { signal?: AbortSignal }) => queue.iterate(signal) },
    session: {
      get: async () => options.session ?? { time: {} },
      generate: async ({ prompt }: { sessionID: string; prompt: string }) => {
        count += 1
        pings.push(prompt)
        const usage = typeof options.usage === "function" ? options.usage() : (options.usage ?? { read: 100, write: 0 })
        return { text: "OK", tokens: { cache: usage }, cost: 0 }
      },
      synthetic: async ({ text }: { text: string }) => {
        synthetic.push(text)
      },
    },
    command: {
      transform: async (fn: (editor: { add: (definition: typeof command) => void }) => void) =>
        fn({ add: (definition) => void (command = definition) }),
    },
  } as unknown as Ctx

  const cleanup = (await plugin.setup(ctx)) as () => Promise<void>

  return {
    storage,
    queue,
    pings,
    synthetic,
    cleanup,
    run: async (text: string, sessionID = "ses_test") => {
      if (!command) throw new Error("command not registered")
      await command.execute({ sessionID, prompt: { text } })
    },
  }
}

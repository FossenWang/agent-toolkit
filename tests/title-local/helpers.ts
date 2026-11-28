import plugin from "../../opencode/plugins/title-local/index.ts"

// ctx 类型从插件反推，避免手抄后与源码漂移
export type Ctx = Parameters<typeof plugin.setup>[0]
export type TitleEvent = { sessionID: string; result?: string }
export type TitleHook = (event: TitleEvent) => Promise<void> | void
export type Message = { type: string; text?: string }

export type FakeOptions = {
  /** 已有标题；null 表示“没有标题” */
  title?: string | null
  /** session.get 是否抛错，模拟查不到会话 */
  getThrows?: boolean
  /** session.context 返回的消息 */
  messages?: Message[]
}

export type Fake = {
  ctx: Ctx
  /** 触发注册的 title 回调 */
  run: (event: TitleEvent) => Promise<void>
}

/** 每个用例独立构造，不共享可变状态 */
export const createFake = async (options: FakeOptions = {}): Promise<Fake> => {
  const captured: TitleHook[] = []

  const fake = {
    session: {
      hook: async (_name: string, fn: TitleHook) => {
        captured.push(fn)
      },
      get: async () => {
        if (options.getThrows) throw new Error("session not found")
        // 没有标题时不要给 title 赋值（undefined 与缺省等价）
        return options.title ? { title: options.title } : {}
      },
      context: async () => options.messages ?? [],
    },
  }

  const ctx = fake as unknown as Ctx
  await plugin.setup(ctx)

  return {
    ctx,
    run: async (event) => {
      if (captured.length !== 1) {
        throw new Error(`expected exactly one hook, got ${captured.length}`)
      }
      const hook = captured[0]
      if (!hook) throw new Error("hook is missing")
      await hook(event)
    },
  }
}

import { Plugin } from "@opencode/plugin"

const MAX = 40

// 首条消息 → 标题。纯文本处理，不认识 OpenCode 的提示词模板。
const titleOf = (text: string) => {
  const line = text
    .split(/\r?\n/)
    .map((item) => item.trim())
    .find(Boolean)
  if (!line) return undefined
  const cleaned = line.replace(/^[#>*\-\s]+/, "").replace(/\s+/g, " ").trim()
  if (!cleaned) return undefined
  return cleaned.length <= MAX ? cleaned : `${[...cleaned].slice(0, MAX - 1).join("").trimEnd()}…`
}

// 只认“有文本”的 user 消息；纯附件消息不带 text
const firstUserText = (messages: ReadonlyArray<{ type: string; text?: string }>) =>
  messages.find((message) => message.type === "user" && typeof message.text === "string")?.text

export default Plugin.define({
  id: "title-local",
  async setup(ctx) {
    await ctx.session.hook("title", async (event) => {
      // 已经有标题就不接管，交给原本的链路。
      // 查不到会话时按“还没有标题”处理：本地标题总比空标题好。
      const session = await ctx.session.get({ sessionID: event.sessionID }).catch(() => undefined)
      if (session?.title !== undefined) return

      // 标题取自会话本身，不从请求里的提示词反推
      const messages = await ctx.session.context({ sessionID: event.sessionID })
      const text = firstUserText(messages)
      if (!text) return

      const title = titleOf(text)
      if (title) event.result = title
    })
  },
})

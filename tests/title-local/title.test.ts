import { describe, expect, test } from "bun:test"
import { createFake } from "./helpers.ts"

const sessionID = "ses_test"

const setup = createFake

describe("title-local", () => {
  test("无标题时用首行生成标题", async () => {
    const { run } = await setup({
      messages: [{ type: "user", text: "# verify title-local 20261125" }],
    })
    const event: { sessionID: string; result?: string } = { sessionID }

    await run(event)

    expect(event.result).toBe("verify title-local 20261125")
  })

  test("已有标题时不接管", async () => {
    const { run } = await setup({
      title: "existing",
      messages: [{ type: "user", text: "new title" }],
    })
    const event: { sessionID: string; result?: string } = { sessionID }

    await run(event)

    expect(event.result).toBeUndefined()
    expect("result" in event).toBe(false)
  })

  test("session.get 抛错时按没有标题继续", async () => {
    const { run } = await setup({
      getThrows: true,
      messages: [{ type: "user", text: "fallback title" }],
    })
    const event: { sessionID: string; result?: string } = { sessionID }

    await run(event)

    expect(event.result).toBe("fallback title")
  })

  test("首条消息没有 text（纯附件）时不写标题", async () => {
    const { run } = await setup({
      messages: [{ type: "user" }],
    })
    const event: { sessionID: string; result?: string } = { sessionID }

    await run(event)

    expect(event.result).toBeUndefined()
    expect("result" in event).toBe(false)
  })

  test("多行文本只取第一个非空行", async () => {
    const { run } = await setup({
      messages: [
        {
          type: "user",
          text: "\n \nSecond line ignored\nfirst real line\nthird line",
        },
      ],
    })
    const event: { sessionID: string; result?: string } = { sessionID }

    await run(event)

    expect(event.result).toBe("Second line ignored")
  })

  test("去掉行首标记并压缩连续空白", async () => {
    const { run } = await setup({
      messages: [{ type: "user", text: "  ## > * -   hello    world  " }],
    })
    const event: { sessionID: string; result?: string } = { sessionID }

    await run(event)

    expect(event.result).toBe("hello world")
  })

  test("超过 40 字符时截断并以省略号结尾", async () => {
    const text = "a".repeat(50)
    const { run } = await setup({
      messages: [{ type: "user", text }],
    })
    const event: { sessionID: string; result?: string } = { sessionID }

    await run(event)

    expect(event.result).toBeDefined()
    expect([...event.result!].length).toBe(40)
    expect(event.result!.endsWith("…")).toBe(true)
    expect(event.result!.startsWith("a".repeat(39))).toBe(true)
  })

  test("40 字符边界附近含 emoji 时不切坏代理对", async () => {
    // 38 个 a + emoji + 5 个 a：按字符数组算 44 个字符，超过上限
    const text = `${"a".repeat(38)}😀aaaaa`
    const { run } = await setup({
      messages: [{ type: "user", text }],
    })
    const event: { sessionID: string; result?: string } = { sessionID }

    await run(event)

    const result = event.result!
    expect(result).toBeDefined()
    expect([...result].length).toBe(40)
    expect(result.endsWith("…")).toBe(true)
    expect(result.startsWith("a".repeat(38))).toBe(true)
    expect(result).toContain("😀")
    // 没有孤立代理项（半个 emoji）
    expect(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])/.test(result)).toBe(false)
    expect(/(^|[^\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(result)).toBe(false)
  })

  test("文本全是空白时不写标题", async () => {
    const { run } = await setup({
      messages: [{ type: "user", text: "\n  \n\t\n   " }],
    })
    const event: { sessionID: string; result?: string } = { sessionID }

    await run(event)

    expect(event.result).toBeUndefined()
    expect("result" in event).toBe(false)
  })
})

// S6 exit test (GOAL.md): the *unmodified* iii Node SDK connects to a running
// Zygos kernel, worker A registers a function, worker B invokes it, and the
// result round-trips. Exits 0 on success, 1 on any failure.
import { registerWorker } from 'iii-sdk'

const url = process.env.III_URL ?? 'ws://localhost:49134'
const deadline = Date.now() + 10_000

const fail = (msg, err) => {
  console.error(`E2E FAIL: ${msg}`, err ?? '')
  process.exit(1)
}

const workerA = registerWorker(url, { name: 'zygos-e2e-a' })
workerA.registerFunction('echo::reverse', async (input) => ({
  reversed: [...String(input.text)].reverse().join(''),
}))

const workerB = registerWorker(url, { name: 'zygos-e2e-b' })

// Registration races dispatch: retry until the kernel routes the call or the
// deadline passes. A function_not_found error before A's frame lands is
// expected on the first attempts.
let result
for (;;) {
  try {
    result = await workerB.trigger({
      function_id: 'echo::reverse',
      payload: { text: 'zygos' },
    })
    break
  } catch (err) {
    if (Date.now() > deadline) fail('trigger never succeeded before deadline', err)
    await new Promise((r) => setTimeout(r, 250))
  }
}

if (result?.reversed !== 'sogyz') {
  fail(`bad result: ${JSON.stringify(result)}`)
}

console.log('E2E OK:', JSON.stringify(result))
process.exit(0)

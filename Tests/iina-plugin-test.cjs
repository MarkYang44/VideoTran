const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

const files = new Map()
const actions = new Map()
const events = new Map()
const messages = []
const player = { idle: false, isNetworkResource: false, url: 'file:///tmp/映像 100%.mkv',
  position: 1, duration: 40, paused: false }
let output
let tick
let now = 1000
const iina = {
  core: { status: player, osd(message) { messages.push(message) } },
  mpv: { getString() { return null }, getNative() { return [] } },
  menu: { item: (name, action) => [name, action], addItem: ([name, action]) => actions.set(name, action) },
  event: { on: (name, action) => events.set(name, action) },
  overlay: { simpleMode() {}, setStyle() {}, setClickable() {},
    setContent(value) { output = value }, show() {}, hide() {} },
  file: { exists: file => files.has(file), read: file => files.get(file),
    write: (file, data) => files.set(file, data), delete: file => files.delete(file) },
}
const plugin = path.join(__dirname, '../Plugin/VideoTran.iinaplugin/main.js')
vm.runInNewContext(fs.readFileSync(plugin, 'utf8'), {
  iina, setInterval: callback => { tick = callback; return 1 }, clearInterval: () => { tick = null },
  Date: { now: () => now * 1000 },
})
actions.get('同步翻译此窗口')()
assert.match(messages.at(-1), /等待 VideoTran/)
const state = JSON.parse(files.get('@data/player.json'))
assert.equal(state.path, '/tmp/映像 100%.mkv')
files.set('@data/captions.json', JSON.stringify({ session: state.session, updated: now, showJapanese: true,
  cues: [{ start: 0.5, end: 2, japanese: 'くそっ！', chinese: '该死！<字>' },
    { start: 25, end: 27, japanese: 'こんにちは', chinese: '你好' }] }))
tick()
assert.match(output, /该死！&lt;字&gt;/)
assert.match(output, /くそっ！/)
player.paused = true
tick()
assert.match(output, /该死！/)
player.position = 9
events.get('mpv.seek')()
assert.equal(output, '')
player.position = 25.5
tick()
assert.match(output, /你好/)
now += 4
tick()
assert.equal(output, '')
events.get('iina.file-loaded')()
assert.equal(files.has('@data/player.json'), false)
assert.equal(tick, null)
assert.equal(messages.length, 1, 'a window VideoTran answered gets no reminder')

actions.get('同步翻译此窗口')()
now += 4
tick()
assert.equal(messages.length, 2, 'no reminder while VideoTran may still be starting')
now += 1
tick()
assert.match(messages.at(-1), /打开 VideoTran/)
now += 10
tick()
assert.equal(messages.length, 3, 'the reminder is shown once')
console.log('IINA bridge tests passed: file path, literal dialogue, pause, seek, expiry, disconnect, and reminder')

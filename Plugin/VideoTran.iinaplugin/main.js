const { core, mpv, menu, overlay, file, event } = iina
const playerFile = '@data/player.json'
const captionFile = '@data/captions.json'
let timer
let currentSession
let currentPath
let lastHTML = ''
// When this window started waiting for VideoTran's first reply. Cleared once it replies or after one reminder.
let waitingSince

function readJSON(path) {
  if (!file.exists(path)) return null
  try { return JSON.parse(file.read(path, {})) } catch (_) { return null }
}

function mediaPath() {
  if (core.status.isNetworkResource || core.status.idle) return null
  const raw = mpv.getString('path')
  if (typeof raw === 'string' && raw.startsWith('/')) return raw
  const url = core.status.url
  // IINA's status API returns a percent-decoded file URL.
  if (typeof url === 'string' && url.startsWith('file:///')) return url.slice('file://'.length)
  return null
}

function escapeHTML(text) {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function render(html) {
  if (html === lastHTML) return
  lastHTML = html
  overlay.setContent(html)
}

function stop() {
  if (!currentSession) return
  if (timer !== undefined) clearInterval(timer)
  if (readJSON(playerFile)?.session === currentSession) file.delete(playerFile)
  timer = undefined
  currentSession = undefined
  currentPath = undefined
  waitingSince = undefined
  render('')
  overlay.hide()
}

function update(force) {
  if (!currentSession) return
  if ((!force && readJSON(playerFile)?.session !== currentSession) || mediaPath() !== currentPath) {
    stop()
    return
  }
  const { position, duration, paused } = core.status
  if (!Number.isFinite(position) || !Number.isFinite(duration) || duration <= 0) return
  const tracks = mpv.getNative('track-list')
  const audio = Array.isArray(tracks) ? tracks.find(track => track.type === 'audio' && track.selected) : null
  const audioStream = audio && Number.isInteger(audio['ff-index']) ? audio['ff-index'] : null
  const now = Date.now() / 1000
  file.write(playerFile, JSON.stringify({
    session: currentSession, path: currentPath, position, duration, paused, updated: now, audioStream,
  }))

  const snapshot = readJSON(captionFile)
  if (snapshot?.session === currentSession) {
    waitingSince = undefined
  } else if (waitingSince !== undefined && now - waitingSince >= 5) {
    waitingSince = undefined
    core.osd('请打开 VideoTran 控制台以开始翻译')
  }
  if (!snapshot || snapshot.session !== currentSession || now - snapshot.updated >= 3 ||
      !Array.isArray(snapshot.cues)) {
    render('')
    return
  }

  render(snapshot.cues
    .filter(cue => cue.start <= position && position < cue.end)
    .map(cue => '<div class="cue">' + escapeHTML(cue.chinese) +
      (snapshot.showJapanese ? '<small>' + escapeHTML(cue.japanese) + '</small>' : '') +
      '</div>').join(''))
}

function start() {
  const path = mediaPath()
  if (!path || !Number.isFinite(core.status.position) ||
      !Number.isFinite(core.status.duration) || core.status.duration <= 0) {
    core.osd('请先打开一个本地视频')
    return
  }
  stop()
  currentPath = path
  currentSession = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2)
  waitingSince = Date.now() / 1000
  overlay.simpleMode()
  // Padding and corners scale with the text, matching VideoTran's floating captions.
  overlay.setStyle(`
    #content { position: fixed; bottom: 11%; left: 4%; right: 4%; text-align: center; }
    .cue { display: table; margin: 4px auto; padding: .35em .65em;
      border-radius: .45em; background: rgba(0,0,0,.82); color: white;
      font: 600 clamp(16px, 4.1vw, 36px) system-ui; white-space: pre-wrap; overflow-wrap: anywhere; }
    small { display: block; margin-top: .2em; font-size: .65em; font-weight: 400; color: rgba(255,255,255,.88); }
  `)
  overlay.setClickable(false)
  overlay.show()
  update(true)
  timer = setInterval(() => update(false), 200)
  core.osd('同步翻译已开启，等待 VideoTran…')
}

menu.addItem(menu.item('同步翻译此窗口', start))
menu.addItem(menu.item('停止同步翻译', stop))
event.on('mpv.seek', () => { if (currentSession) render('') })
event.on('mpv.playback-restart', () => update(false))
event.on('mpv.end-file', stop)
event.on('iina.file-loaded', stop)

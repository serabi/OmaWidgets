// MPRIS player selection and track presentation.
//
// Deliberately duck-typed: every function takes a plain object with the property
// names Quickshell's MprisPlayer exposes, so a QML player object and a literal in
// a test go through exactly the same code.
//
// Track metadata is untrusted text. A title and artist come from whatever the
// player was handed — a streaming service, a file someone downloaded, a podcast
// feed — so both are stripped of control characters and length capped before
// they reach a card, and rendered as PlainText once they get there.
var UNKNOWN = -1

var MAX_TEXT = 120

// Bidirectional overrides are dropped as well as control characters: they
// reorder what is around them, so a track title can be made to read as
// something else.
var BIDI_OVERRIDE = /[\u202A-\u202E\u2066-\u2069]/g

function cleanText(raw, cap) {
  if (typeof raw !== "string") return ""
  var limit = typeof cap === "number" && cap > 0 ? cap : MAX_TEXT
  return raw.replace(BIDI_OVERRIDE, "").replace(/[\u0000-\u001F\u007F]/g, " ")
    .replace(/\s+/g, " ").trim().slice(0, limit)
}

function num(value, fallback) {
  return typeof value === "number" && isFinite(value) ? value : fallback
}

// Mpris.players.values is a QML list, not a JavaScript Array, so Array.isArray
// reports false for it. Guarding with Array.isArray silently produced an empty
// list and a card that said "no track" while a player sat there with a title.
// Anything indexable with a length is accepted, and copied so the rest of this
// file works on a plain array.
// Bounded like every other list taken from outside: a length of 1e8 is a
// broken value, and walking it costs seconds.
function toArray(value) {
  if (Array.isArray(value)) return value.slice()
  if (!value || typeof value !== "object") return []
  var length = value.length
  if (typeof length !== "number" || !isFinite(length) || length < 0) return []
  var out = []
  for (var i = 0; i < Math.min(Math.floor(length), 256); i++) out.push(value[i])
  return out
}

function empty() {
  return {
    present: false,
    title: "",
    artist: "",
    album: "",
    artUrl: "",
    appName: "",
    isPlaying: false,
    canControl: false,
    canGoNext: false,
    canGoPrevious: false,
    canTogglePlaying: false,
    position: 0,
    length: 0,
    progress: UNKNOWN
  }
}

// A player is worth showing once it has a title or an artist. Spotify sits on
// the bus with empty metadata from the moment it launches, so "the player
// exists" is not the same as "there is something to show".
function hasTrack(player) {
  if (!player) return false
  return cleanText(player.trackTitle) !== "" || cleanText(player.trackArtist) !== ""
}

function matchesPreferred(player, preferred) {
  var wanted = String(preferred || "").trim().toLowerCase()
  if (wanted === "" || !player) return false
  var identity = String(player.identity || "").toLowerCase()
  var dbusName = String(player.dbusName || "").toLowerCase()
  var entry = String(player.desktopEntry || "").toLowerCase()
  return identity.indexOf(wanted) !== -1 || dbusName.indexOf(wanted) !== -1
    || entry.indexOf(wanted) !== -1
}

// Best player, in the order a person would pick one: the one they named and is
// playing, then the one they named, then whatever is actually playing, then
// whatever has a track loaded. Returns null rather than a stopped player with no
// metadata, so the card can say "nothing playing" instead of showing a blank.
function pickPlayer(players, preferred) {
  var list = toArray(players)
  var preferredPlaying = null
  var preferredAny = null
  var playing = null
  var loaded = null

  for (var i = 0; i < list.length; i++) {
    var player = list[i]
    if (!player) continue
    var track = hasTrack(player)
    var active = player.isPlaying === true
    var named = matchesPreferred(player, preferred)

    if (named && active && !preferredPlaying) preferredPlaying = player
    if (named && track && !preferredAny) preferredAny = player
    if (active && track && !playing) playing = player
    if (track && !loaded) loaded = player
  }
  return preferredPlaying || preferredAny || playing || loaded || null
}

function progressFraction(position, length) {
  var at = num(position, 0)
  var total = num(length, 0)
  if (!(total > 0)) return UNKNOWN
  return Math.max(0, Math.min(1, at / total))
}

// Quickshell reports position and length in seconds.
function describe(player) {
  var out = empty()
  if (!player) return out
  out.present = true
  out.title = cleanText(player.trackTitle)
  out.artist = cleanText(player.trackArtist)
  out.album = cleanText(player.trackAlbum)
  out.appName = cleanText(player.identity, 40)
  out.artUrl = artUrl(player.trackArtUrl)
  out.isPlaying = player.isPlaying === true
  out.canControl = player.canControl === true
  // A player that cannot control anything still reports canGoNext, so the
  // buttons follow canControl as well as the individual capability.
  out.canGoNext = out.canControl && player.canGoNext === true
  out.canGoPrevious = out.canControl && player.canGoPrevious === true
  out.canTogglePlaying = out.canControl && player.canTogglePlaying !== false
  out.position = num(player.position, 0)
  out.length = num(player.length, 0)
  out.progress = progressFraction(out.position, out.length)
  return out
}

// Art URLs come from the player, so the scheme is checked rather than assumed.
// `https` is what Spotify hands out and `file` is what local players use;
// anything else — a `data:` blob, a `javascript:` string — is dropped.
function artUrl(raw) {
  var text = String(raw || "")
  // Bounded before anything else runs over it, and a control character anywhere
  // in it is disqualifying: a URL with a newline in it is two things pretending
  // to be one.
  if (text.length > 2048) return ""
  if (/[\u0000-\u001F\u007F]/.test(text)) return ""
  text = text.trim()
  if (text === "") return ""
  if (!/^(https|http|file):\/\//i.test(text)) return ""
  return text
}

function isRemoteArt(url) { return /^https?:\/\//i.test(String(url || "")) }

// A file on this machine, which is not the same as one worth opening: see
// ui/RemoteArt.qml for what the ones that block do to the shell.
function isLocalArt(url) { return /^file:\/\//i.test(String(url || "")) }

// The path inside a file:// URL, or "". Percent escapes are decoded: the
// player wrote a URL, the helper wants a path.
function localArtPath(url) {
  var text = String(url || "")
  if (!isLocalArt(text)) return ""
  var path = text.substring(7)
  var query = path.indexOf("?")
  if (query !== -1) path = path.substring(0, query)
  if (path === "" || path.charAt(0) !== "/") return ""
  try {
    path = decodeURIComponent(path)
  } catch (e) {
    return ""
  }
  // A control character in a decoded path is not something a player meant.
  return /[\u0000-\u001F\u007F]/.test(path) ? "" : path
}

if (typeof module !== "undefined") {
  module.exports = {
    UNKNOWN: UNKNOWN,
    cleanText: cleanText,
    empty: empty,
    hasTrack: hasTrack,
    matchesPreferred: matchesPreferred,
    pickPlayer: pickPlayer,
    toArray: toArray,
    progressFraction: progressFraction,
    describe: describe,
    artUrl: artUrl,
    isRemoteArt: isRemoteArt,
    isLocalArt: isLocalArt,
    localArtPath: localArtPath
  }
}

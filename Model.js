.pragma library

// Pure helpers for the SL Departures widget. Everything here is free of QML
// types so the parsing and formatting rules can be reasoned about (and
// exercised with `node`) without a running shell.
//
// Data comes from SL's open "Transport" API, which needs no key:
//   https://transport.integration.sl.se/v1/sites?expand=false
//   https://transport.integration.sl.se/v1/sites/<siteId>/departures
// Responses are Swedish-language and Europe/Stockholm-local throughout.

var API_BASE = "https://transport.integration.sl.se/v1"
var TIMEZONE = "Europe/Stockholm"

// SL's transport_mode values mapped to Nerd Font glyphs. Every codepoint here
// is in the JetBrainsMono Nerd Font that Omarchy ships as `monospace`.
var MODE_ICONS = {
  BUS: "",
  METRO: "",
  TRAIN: "",
  TRAM: "󰴏",
  SHIP: "",
  FERRY: "",
  TAXI: ""
}
var DEFAULT_ICON = "󰥔"  // nf-md-clock_outline, for unknown modes

var MODE_NAMES = {
  BUS: "Bus",
  METRO: "Metro",
  TRAIN: "Train",
  TRAM: "Tram",
  SHIP: "Ship",
  FERRY: "Ferry",
  TAXI: "Taxi"
}

function transportIcon(mode) {
  return MODE_ICONS[String(mode || "").toUpperCase()] || DEFAULT_ICON
}

function transportName(mode) {
  var key = String(mode || "").toUpperCase()
  return MODE_NAMES[key] || (key ? key.charAt(0) + key.slice(1).toLowerCase() : "")
}

function trim(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

// API-derived display strings pass through here before anything renders them.
// Angle brackets are what flips a QML Text in its default AutoText mode into
// rich-text interpretation (Qt's mightBeRichText sniff), and no legitimate SL
// name, destination, or message contains them. Our own Text items also set
// Text.PlainText explicitly; this covers the strings that flow into shell
// components we do not own — the hero title, the bar label, the tooltip.
function plain(value) {
  return trim(value).replace(/[<>]/g, "")
}

function intOr(value, fallback) {
  var n = parseInt(value, 10)
  return isFinite(n) ? n : fallback
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

// ------------------------------------------------------------------ config

// One place that turns a shell.json layout entry into the values the widget
// actually uses, so Panel/Service never repeat a default or a bound.
function resolveConfig(settings) {
  var s = settings || {}
  var read = function(key, fallback) {
    var v = s[key]
    return v === undefined || v === null || v === "" ? fallback : v
  }
  return {
    siteId: Math.max(0, intOr(read("siteId", 0), 0)),
    siteName: trim(read("siteName", "")),
    transport: trim(read("transport", "")).toUpperCase(),
    direction: clamp(intOr(read("direction", 0), 0), 0, 2),
    lines: parseLineFilter(read("lines", "")),
    walkMinutes: clamp(intOr(read("walkMinutes", 0), 0), 0, 120),
    barCount: clamp(intOr(read("barCount", 2), 2), 1, 6),
    panelCount: clamp(intOr(read("panelCount", 12), 12), 1, 40),
    forecastMinutes: clamp(intOr(read("forecastMinutes", 90), 90), 10, 360),
    refreshIntervalSec: clamp(intOr(read("refreshIntervalSec", 30), 30), 15, 600),
    barFormat: String(read("barFormat", "{line} {wait}")),
    showIcon: read("showIcon", true) !== false
  }
}

function parseLineFilter(raw) {
  var parts = String(raw || "").split(/[,\s]+/)
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var part = trim(parts[i])
    if (part !== "") out.push(part.toUpperCase())
  }
  return out
}

// Server-side filters keep the payload small; `lines` and `walkMinutes` are
// applied client-side because the API has no equivalent.
function departuresUrl(config) {
  var query = ["forecast=" + config.forecastMinutes]
  if (config.transport !== "") query.push("transport=" + encodeURIComponent(config.transport))
  if (config.direction !== 0) query.push("direction=" + config.direction)
  return API_BASE + "/sites/" + config.siteId + "/departures?" + query.join("&")
}

function sitesUrl() {
  return API_BASE + "/sites?expand=false"
}

// -------------------------------------------------------------------- time

// Departure timestamps are naive Europe/Stockholm wall-clock times, so
// subtracting the machine's clock is only correct on a machine set to
// Stockholm. Rather than assume that (or trust an Intl implementation the QML
// engine may not ship), the widget anchors itself to the API's own clock: a
// departure that reports both a relative `display` ("4 min") and an absolute
// `expected` pins down what "now" was when the server answered.
//
// Returns the offset to add to Date.now() to land in the API's frame, or null
// when the payload carries no relative display to anchor on — the caller then
// keeps whatever offset it learned last.
function clockOffset(departures, wallNow) {
  var samples = []
  for (var i = 0; i < (departures || []).length; i++) {
    var d = departures[i] || {}
    var display = trim(d.display)
    var relative = display.match(/^(\d+)\s*min$/i)
    var imminent = /^(nu|now)$/i.test(display)
    if (!relative && !imminent) continue
    var stamp = parseNaive(d.expected || d.scheduled)
    if (stamp === null) continue
    // The server floors its minute counts, so each sample sits up to a minute
    // late; the half-minute correction centers them.
    samples.push(stamp - (imminent ? 0 : parseInt(relative[1], 10) * 60000) - 30000)
  }
  if (samples.length === 0) return null

  samples.sort(function(a, b) { return a - b })
  return samples[Math.floor(samples.length / 2)] - wallNow
}

// A legitimate anchor offset is bounded by how far a machine's timezone can
// sit from Stockholm — just over a day across the extremes of UTC-12 and
// UTC+14. Anything past that is a garbage anchor, not a timezone.
function saneClockOffset(offset) {
  return offset !== null && Math.abs(offset) < 26 * 3600 * 1000
}

// Best guess at the API's clock with no payload to anchor against. Tries the
// zone conversion first and falls back to the machine clock, which is right
// for the Stockholm-based machines this widget is for.
function nowMs() {
  var real = new Date()
  try {
    var stamp = String(real.toLocaleString("sv-SE", { timeZone: TIMEZONE })).replace(" ", "T")
    var parsed = parseNaive(stamp)
    // Reject anything absurd: QML replaces Date.prototype.toLocaleString with
    // Qt's own overload, which ignores the options object entirely.
    if (parsed !== null && Math.abs(parsed - real.getTime()) < 14 * 3600 * 1000) return parsed
  } catch (e) {
    // No Intl, no tz database — the machine clock it is.
  }
  return real.getTime()
}

// Parses "2026-08-25T23:30:00" as a wall-clock time with no zone applied.
// Deliberately not `new Date(string)`: engines disagree on whether a
// seconds-precision ISO string without a zone is local or UTC.
function parseNaive(value) {
  var m = String(value || "").match(/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?/)
  if (!m) return null
  return new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0)).getTime()
}

// Minutes until a departure, counted against the anchored clock. Timestamps
// lead because they keep ticking down between fetches; the relative `display`
// is only a fallback for a payload that somehow omits both times, and is
// frozen at whatever the last fetch said.
function departureMinutes(departure, now) {
  var stamp = parseNaive(departure.expected || departure.scheduled)
  if (stamp !== null) return Math.max(0, Math.round((stamp - now) / 60000))

  var display = trim(departure.display)
  var relative = display.match(/^(\d+)\s*min$/i)
  if (relative) return parseInt(relative[1], 10)
  if (/^(nu|now)$/i.test(display)) return 0
  return null
}

function clockText(departure) {
  var stamp = departure.expected || departure.scheduled
  var m = String(stamp || "").match(/T(\d{2}:\d{2})/)
  return m ? m[1] : ""
}

// Minutes as the bar and popup show them. Under a minute reads "now" rather
// than "0" — the number is the wait, and there isn't one.
//
// Three renderings, because the unit belongs in a different place in each:
// bare for user templates that supply their own unit, primed for the bar
// where width is scarce, and spelled out for the popup rows.
function minutesText(minutes) {
  if (minutes === null || minutes === undefined) return "?"
  return minutes <= 0 ? "now" : String(minutes)
}

function waitText(minutes) {
  if (minutes === null || minutes === undefined) return "?"
  return minutes <= 0 ? "now" : minutes + "′"
}

function waitLabel(minutes) {
  if (minutes === null || minutes === undefined) return "?"
  if (minutes <= 0) return "now"
  return minutes + " min"
}

// ------------------------------------------------------------- departures

function parseDepartures(raw) {
  var text = trim(raw)
  if (text === "") return { ok: false, departures: [], stopDeviations: [], error: "No response from SL" }
  try {
    var data = JSON.parse(text)
    if (!data || typeof data !== "object") throw new Error("not an object")
    var stopDeviations = (Array.isArray(data.stop_deviations) ? data.stop_deviations : [])
      .map(function(dev) {
        return {
          message: plain(dev && dev.message),
          importance_level: intOr(dev && dev.importance_level, 0)
        }
      })
    return {
      ok: true,
      departures: Array.isArray(data.departures) ? data.departures : [],
      stopDeviations: stopDeviations,
      error: ""
    }
  } catch (e) {
    return { ok: false, departures: [], stopDeviations: [], error: "Unreadable response from SL" }
  }
}

// Flattens the API shape into rows the UI can bind to directly, so no QML
// delegate has to reach through `departure.line.designation` and friends.
function toRows(departures, now) {
  var rows = []
  for (var i = 0; i < departures.length; i++) {
    var d = departures[i] || {}
    var line = d.line || {}
    var minutes = departureMinutes(d, now)
    var deviations = Array.isArray(d.deviations) ? d.deviations : []
    var cancelled = String(d.state || "").toUpperCase() === "CANCELLED"
      || deviations.some(function(dev) { return String(dev.consequence || "").toUpperCase() === "CANCELLED" })

    rows.push({
      key: String(d.journey && d.journey.id ? d.journey.id : i) + ":" + (d.scheduled || i),
      line: plain(line.designation),
      mode: String(line.transport_mode || "").toUpperCase(),
      icon: transportIcon(line.transport_mode),
      destination: plain(d.destination || d.direction),
      direction: intOr(d.direction_code, 0),
      minutes: minutes,
      minutesText: minutesText(minutes),
      waitText: waitText(minutes),
      waitLabel: waitLabel(minutes),
      clock: clockText(d),
      display: plain(d.display),
      atStop: String(d.state || "").toUpperCase() === "ATSTOP",
      cancelled: cancelled,
      // The berth letter is the useful half of stop_point; its `name` just
      // repeats the site you already asked for.
      berth: plain(d.stop_point && d.stop_point.designation),
      deviationText: deviationText(deviations),
      deviationLevel: maxImportance(deviations)
    })
  }
  return rows
}

function deviationText(deviations) {
  var messages = []
  for (var i = 0; i < (deviations || []).length; i++) {
    var message = plain(deviations[i] && deviations[i].message)
    if (message !== "" && messages.indexOf(message) === -1) messages.push(message)
  }
  return messages.join(" · ")
}

function maxImportance(deviations) {
  var level = 0
  for (var i = 0; i < (deviations || []).length; i++) {
    level = Math.max(level, intOr(deviations[i] && deviations[i].importance_level, 0))
  }
  return level
}

// Client-side narrowing: line whitelist, and dropping departures that leave
// before you could physically get there. Sorted because a line filter can
// interleave modes the API returned in separate blocks.
function filterRows(rows, config) {
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (config.lines.length > 0 && config.lines.indexOf(row.line.toUpperCase()) === -1) continue
    if (row.minutes !== null && row.minutes < config.walkMinutes) continue
    out.push(row)
  }
  out.sort(function(a, b) {
    var am = a.minutes === null ? 1e9 : a.minutes
    var bm = b.minutes === null ? 1e9 : b.minutes
    return am - bm
  })
  return out
}

// The bar shows what you can actually board, so cancellations are dropped
// here; the popup still lists them, struck through, because a cancellation is
// exactly the thing you open the popup to find out about.
function barRows(rows, config) {
  var boardable = rows.filter(function(row) { return !row.cancelled })
  return boardable.slice(0, config.barCount)
}

function formatSegment(template, row) {
  return String(template)
    .replace(/\{line\}/g, row.line)
    .replace(/\{wait\}/g, row.waitText)
    .replace(/\{min\}/g, row.minutesText)
    .replace(/\{clock\}/g, row.clock)
    .replace(/\{display\}/g, row.display)
    .replace(/\{destination\}/g, row.destination)
    .replace(/\{icon\}/g, row.icon)
    .replace(/^\s+|\s+$/g, "")
}

// The bar label: an optional mode icon (taken from the soonest departure, so a
// mixed stop shows whatever is actually next) followed by the segments.
function barLabel(rows, config, state) {
  if (config.siteId <= 0) return "SL"
  if (state === "loading" && rows.length === 0) return "SL …"
  if (state === "error" && rows.length === 0) return "SL ✗"
  if (rows.length === 0) return config.showIcon ? DEFAULT_ICON + " –" : "–"

  var segments = []
  for (var i = 0; i < rows.length; i++) {
    var segment = formatSegment(config.barFormat, rows[i])
    if (segment !== "") segments.push(segment)
  }
  var text = segments.join(" · ")
  return config.showIcon ? rows[0].icon + " " + text : text
}

// Vertical bars get one short line per departure instead of a wide label.
function verticalBarLines(rows, config) {
  if (config.siteId <= 0) return ["SL"]
  if (rows.length === 0) return [config.showIcon ? DEFAULT_ICON : "–"]
  var lines = []
  if (config.showIcon) lines.push(rows[0].icon)
  for (var i = 0; i < rows.length; i++) lines.push(rows[i].minutesText === "now" ? "●" : rows[i].minutesText)
  return lines
}

function tooltipText(rows, config, siteLabel) {
  if (config.siteId <= 0) return "SL Departures — click to pick a stop"
  if (rows.length === 0) return siteLabel + " — no departures"
  var parts = []
  for (var i = 0; i < Math.min(rows.length, 5); i++) {
    var row = rows[i]
    parts.push(row.line + " " + row.destination + " " + (row.minutes === null ? row.clock : row.waitLabel))
  }
  return siteLabel + "\n" + parts.join("\n")
}

// A one-line summary of what the widget is currently showing, for the popup
// header: the filters in force, not just the stop name.
function filterSummary(config) {
  var parts = []
  if (config.transport !== "") parts.push(transportName(config.transport))
  if (config.lines.length > 0) parts.push("Line " + config.lines.join(", "))
  if (config.direction !== 0) parts.push("Direction " + config.direction)
  if (config.walkMinutes > 0) parts.push(config.walkMinutes + " min walk")
  return parts.join(" · ")
}

// ------------------------------------------------------------------- sites

// The folded search keys are computed here, once per list load, because
// searchSites runs on every keystroke over all ~6500 sites — folding inside
// the search loop would redo a few million character comparisons per keypress.
function parseSites(raw) {
  try {
    var data = JSON.parse(trim(raw) || "[]")
    if (!Array.isArray(data)) return []
    var out = []
    for (var i = 0; i < data.length; i++) {
      var site = data[i]
      if (!site || site.id === undefined || !site.name) continue
      var name = plain(site.name)
      var note = plain(site.note)
      out.push({
        id: intOr(site.id, 0),
        name: name,
        note: note,
        folded: fold(name),
        foldedNote: note === "" ? "" : fold(note)
      })
    }
    return out
  } catch (e) {
    return []
  }
}

// Diacritic folding, so a stop can be found from a keyboard the typist
// actually has: "sodermalm" reaches Södermalm, "radmans" reaches Rådmansgatan.
// A table rather than String.normalize("NFKD") — the QML engine's Unicode
// support is not something to bet the stop picker on.
var FOLD_FROM = "àáâãäåèéêëìíîïòóôõöøùúûüýÿçñšž"
var FOLD_TO   = "aaaaaaeeeeiiiioooooouuuuyycnsz"

function fold(value) {
  var lower = String(value || "").toLowerCase()
  var out = ""
  for (var i = 0; i < lower.length; i++) {
    var at = FOLD_FROM.indexOf(lower.charAt(i))
    out += at === -1 ? lower.charAt(i) : FOLD_TO.charAt(at)
  }
  return out
}

// Ranked substring search. Prefix matches come first because typing "slu"
// should surface Slussen ahead of every stop that merely contains "slu".
function searchSites(sites, query, limit) {
  var needle = fold(trim(query))
  if (needle === "") return []
  var max = intOr(limit, 8)
  var scored = []
  for (var i = 0; i < sites.length; i++) {
    var site = sites[i]
    var haystack = site.folded
    var at = haystack.indexOf(needle)
    if (at === -1) {
      if (site.foldedNote === "" || site.foldedNote.indexOf(needle) === -1) continue
      at = 100
    }
    scored.push({ site: site, score: at * 1000 + haystack.length })
  }
  scored.sort(function(a, b) {
    if (a.score !== b.score) return a.score - b.score
    return a.site.name.localeCompare(b.site.name)
  })
  var out = []
  for (var j = 0; j < Math.min(scored.length, max); j++) out.push(scored[j].site)
  return out
}

function findSiteById(sites, id) {
  for (var i = 0; i < sites.length; i++) {
    if (sites[i].id === id) return sites[i]
  }
  return null
}

// Used when a config names a stop but not an id, so `"siteName": "Slussen"`
// alone is a working configuration.
function findSiteByName(sites, name) {
  var needle = fold(trim(name))
  if (needle === "") return null
  for (var i = 0; i < sites.length; i++) {
    if (sites[i].folded === needle) return sites[i]
  }
  return null
}

function siteLabel(site) {
  if (!site) return ""
  return site.note === "" ? site.name : site.name + " (" + site.note + ")"
}

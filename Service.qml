import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Data layer for the SL Departures widget: fetching, caching, and the clock
// anchoring that keeps the countdown honest between fetches. All parsing and
// formatting lives in Model.js; this file owns processes, timers, and state.
Item {
  id: root

  property var settings: ({})
  readonly property var config: Model.resolveConfig(settings)

  // "idle" (no stop configured) | "loading" | "ready" | "error"
  property string fetchState: "idle"
  property string lastError: ""
  property var rows: []
  property var stopDeviations: []
  property double lastUpdated: 0

  // Offset from the machine clock to the API's Europe/Stockholm wall clock,
  // learned from each payload (Model.clockOffset) and kept across fetches so a
  // late-night payload with no relative times still counts down correctly.
  property double clockOffset: 0
  property bool clockAnchored: false

  readonly property bool busy: departuresProcess.running
  readonly property int siteId: config.siteId
  readonly property string siteLabel: {
    if (resolvedSiteName !== "") return resolvedSiteName
    if (config.siteName !== "") return config.siteName
    return config.siteId > 0 ? "Site " + config.siteId : "No stop selected"
  }

  // Filled in once the site list is available, so a hand-written config that
  // only carries an id still shows a name in the popup header.
  property string resolvedSiteName: ""

  // ------------------------------------------------------------ departures

  property string _payload: ""
  property string _stderr: ""

  function refresh() {
    if (config.siteId <= 0) {
      fetchState = "idle"
      if (rows.length > 0) rows = []
      if (stopDeviations.length > 0) stopDeviations = []
      return
    }
    if (departuresProcess.running) return
    if (fetchState !== "ready") fetchState = "loading"
    _payload = ""
    _stderr = ""
    departuresProcess.command = ["curl", "-fsS", "--max-time", "10", Model.departuresUrl(config)]
    departuresProcess.running = true
  }

  // Re-derives the rows from the payload already in hand. Called on a short
  // tick so "4 min" becomes "3 min" without another round trip to SL.
  function recompute() {
    if (_payload === "") return
    var parsed = Model.parseDepartures(_payload)
    if (!parsed.ok) return
    rows = Model.filterRows(Model.toRows(parsed.departures, Date.now() + clockOffset), config)
    stopDeviations = parsed.stopDeviations
  }

  function applyPayload(text, wallNowAtFetch) {
    var parsed = Model.parseDepartures(text)
    if (!parsed.ok) {
      failWith(parsed.error)
      return
    }

    var offset = Model.clockOffset(parsed.departures, wallNowAtFetch)
    // Guard against a nonsense anchor (a payload of one oddly-labelled
    // departure, say) dragging the countdown off by hours.
    if (offset !== null && Math.abs(offset) < 14 * 3600 * 1000) {
      clockOffset = offset
      clockAnchored = true
    } else if (!clockAnchored) {
      clockOffset = Model.nowMs() - Date.now()
    }

    _payload = text
    lastError = ""
    fetchState = "ready"
    lastUpdated = Date.now()
    recompute()
  }

  // A failed refresh keeps the last good rows on screen — a stale departure
  // board beats a blank one — and only blanks out when there was never one.
  function failWith(message) {
    lastError = message
    fetchState = rows.length > 0 ? "ready" : "error"
  }

  // Only the fields that go into the request URL force a refetch; the rest
  // (line whitelist, walk time, row counts) just re-derive from the payload
  // already in hand.
  readonly property string _fetchKey: config.siteId + "|" + config.transport
    + "|" + config.direction + "|" + config.forecastMinutes
  property string _appliedFetchKey: ""

  // Deferred rather than run straight out of onConfigChanged: `config` is a
  // binding that rebuilds its object on every settings change, and mutating
  // `rows` while a consumer is mid-evaluation of that same object reads as a
  // binding loop to the QML engine.
  onConfigChanged: Qt.callLater(applyConfig)

  function applyConfig() {
    if (config.siteId <= 0) {
      _appliedFetchKey = ""
      _payload = ""
      resolvedSiteName = ""
      fetchState = "idle"
      if (rows.length > 0) rows = []
      if (stopDeviations.length > 0) stopDeviations = []
      if (config.siteName !== "") resolveSiteByName()
      return
    }

    if (_fetchKey !== _appliedFetchKey) {
      _appliedFetchKey = _fetchKey
      resolvedSiteName = ""
      _payload = ""
      resolveSiteName()
      refresh()
      return
    }

    resolveSiteName()
    recompute()
  }

  // Deferred for the same reason as onConfigChanged: the first consumer to
  // read `rows` is what forces this object's completion, and clearing state
  // inside that read looks like a binding loop from the outside.
  Component.onCompleted: {
    ensureSiteCache()
    Qt.callLater(applyConfig)
  }

  property Process departuresProcess: Process {
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._payload = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._stderr = String(text || "").replace(/^\s+|\s+$/g, "")
    }
    onExited: function(exitCode) {
      // Time the fetch from its completion, not from `startedAt`: the offset
      // must describe the clock skew, and folding the request latency into it
      // would make every departure look that much closer.
      if (exitCode === 0) root.applyPayload(root._payload, Date.now())
      else root.failWith(root._stderr !== "" ? root._stderr : "Could not reach SL (curl " + exitCode + ")")
    }
  }

  property Timer refreshTimer: Timer {
    interval: Math.max(15, root.config.refreshIntervalSec) * 1000
    repeat: true
    running: root.config.siteId > 0
    onTriggered: root.refresh()
  }

  property Timer tickTimer: Timer {
    interval: 15000
    repeat: true
    running: root.config.siteId > 0
    onTriggered: root.recompute()
  }

  // ----------------------------------------------------------------- sites

  // The full site list is a 1.3 MB document that changes a few times a year,
  // so it is cached on disk and only re-fetched weekly. It is loaded into
  // memory lazily — the picker needs it, the departure board does not.
  property var sites: []
  property bool sitesLoading: false
  property string sitesError: ""
  property bool _sitesRetried: false
  readonly property string sitesCachePath: Quickshell.env("HOME") + "/.cache/omarchy/sl-sites.json"

  function ensureSiteCache() {
    if (siteCacheProcess.running) return
    siteCacheProcess.command = ["bash", "-c",
      "set -e; cache=\"$1\"; url=\"$2\"; mkdir -p \"$(dirname -- \"$cache\")\"; "
      + "if [ ! -s \"$cache\" ] || [ -n \"$(find \"$cache\" -mtime +7 2>/dev/null)\" ]; then "
      + "  curl -fsS --max-time 30 \"$url\" -o \"$cache.tmp\" && mv -f \"$cache.tmp\" \"$cache\"; "
      + "fi",
      "bash", root.sitesCachePath, Model.sitesUrl()]
    siteCacheProcess.running = true
  }

  function loadSites() {
    if (sites.length > 0 || sitesLoading) return
    sitesLoading = true
    sitesError = ""
    _sitesRetried = false
    sitesFile.reload()
  }

  function searchSites(query) {
    return Model.searchSites(sites, query, 8)
  }

  // Turns a configured id into a display name, and a configured name into an
  // id, so either half of the pair is a complete configuration on its own.
  function resolveSiteName() {
    if (sites.length === 0) { loadSites(); return }
    for (var i = 0; i < sites.length; i++) {
      if (sites[i].id === config.siteId) {
        resolvedSiteName = Model.siteLabel(sites[i])
        return
      }
    }
  }

  signal siteResolved(int siteId, string name)

  function resolveSiteByName() {
    if (sites.length === 0) { loadSites(); return }
    var match = Model.findSiteByName(sites, config.siteName)
    if (match) siteResolved(match.id, Model.siteLabel(match))
  }

  function onSitesReady() {
    sitesLoading = false
    if (config.siteId > 0) resolveSiteName()
    else if (config.siteName !== "") resolveSiteByName()
  }

  property Process siteCacheProcess: Process {
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.sitesLoading = false
        root.sitesError = "Could not download the SL stop list"
        return
      }
      if (root.sitesLoading) root.sitesFile.reload()
    }
  }

  property FileView sitesFile: FileView {
    path: root.sitesCachePath
    printErrors: false
    onLoaded: {
      root.sites = Model.parseSites(text())
      root.sitesError = root.sites.length > 0 ? "" : "The SL stop list came back empty"
      root.onSitesReady()
    }
    // A miss on the first read is the normal cold-start path: the cache has
    // not been downloaded yet. Ask for it once and stop, so a download that
    // keeps producing an unreadable file cannot spin.
    onLoadFailed: {
      if (root._sitesRetried) {
        root.sitesLoading = false
        root.sitesError = "Could not read the SL stop list cache"
        return
      }
      root._sitesRetried = true
      root.ensureSiteCache()
    }
  }
}

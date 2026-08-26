import QtQuick
import "Model.js" as Model

// Per-instance data layer for the SL Departures widget: resolves this entry's
// config, subscribes to the shared fetch hub (SlHub) for its departures URL,
// and derives the filtered, sorted rows the UI binds to. Fetching, payload
// parsing, and the site directory live in the hub so that several instances —
// including the copy each monitor's bar surface mounts — share one fetch loop
// and one in-memory site list.
Item {
  id: root

  property var settings: ({})
  readonly property var config: Model.resolveConfig(settings)

  // "idle" (no stop configured) | "loading" | "ready" | "error".
  // "error" only while there has never been a payload to show; once rows
  // exist, a failed refresh keeps them (still counting down, since the hub
  // keeps the parsed departures) and surfaces through lastError alone.
  property string fetchState: "idle"
  property string lastError: ""
  property var rows: []
  property var stopDeviations: []
  property double lastUpdated: 0
  property bool busy: false

  readonly property int siteId: config.siteId
  readonly property string siteLabel: {
    if (resolvedSiteName !== "") return resolvedSiteName
    if (config.siteName !== "") return config.siteName
    return config.siteId > 0 ? "Site " + config.siteId : "No stop selected"
  }

  // Filled in from the site list when it happens to be in memory, so a
  // hand-written config that only carries an id still shows a name in the
  // popup header. Deliberately not worth loading the list for: when the
  // config already names the stop, the label is already known.
  property string resolvedSiteName: ""

  property string _url: ""
  property int _subToken: 0

  function refresh() {
    if (_url !== "") SlHub.requestNow(_url)
  }

  // Re-derives the rows from the hub's parsed payload. Cheap enough to run on
  // every 15s tick — the parse happened once, at fetch time, in the hub.
  function recompute() {
    var e = _url !== "" ? SlHub.entry(_url) : null
    if (!e) return
    busy = e.fetching
    lastError = e.error
    if (!e.hasPayload) {
      fetchState = e.error !== "" ? "error" : "loading"
      return
    }
    // Most ticks change nothing on the board; reassigning `rows` anyway would
    // make the Repeater tear down and rebuild every delegate each time.
    var next = Model.filterRows(Model.toRows(e.departures, Date.now() + e.clockOffset), config)
    if (!Model.sameRows(rows, next)) rows = next
    if (stopDeviations !== e.stopDeviations) stopDeviations = e.stopDeviations
    lastUpdated = e.lastUpdated
    fetchState = "ready"
  }

  // Deferred rather than run straight out of onConfigChanged: `config` is a
  // binding that rebuilds its object on every settings change, and mutating
  // `rows` while a consumer is mid-evaluation of that same object reads as a
  // binding loop to the QML engine.
  onConfigChanged: Qt.callLater(applyConfig)

  function applyConfig() {
    var url = config.siteId > 0 ? Model.departuresUrl(config) : ""
    if (url !== _url) {
      if (_url !== "") SlHub.unsubscribe(_url, _subToken)
      _url = url
      _subToken = _url !== "" ? SlHub.subscribe(_url, config.refreshIntervalSec) : 0
      // The rows on screen were derived from the old URL's payload; keeping
      // them under the new stop's name until the new fetch lands (or fails)
      // would present another stop's times as current. Drop them so the
      // loading and error states can surface.
      if (rows.length > 0) rows = []
      if (stopDeviations.length > 0) stopDeviations = []
      lastUpdated = 0
      resolvedSiteName = ""
    } else if (_url !== "") {
      // Same URL, but the interval is not part of it — re-declare it so an
      // edit to refreshIntervalSec alone still reaches the hub.
      SlHub.updateInterval(_url, _subToken, config.refreshIntervalSec)
    }

    if (config.siteId <= 0) {
      fetchState = "idle"
      lastError = ""
      resolvedSiteName = ""
      if (rows.length > 0) rows = []
      if (stopDeviations.length > 0) stopDeviations = []
      if (config.siteName !== "") resolveSiteByName()
      return
    }

    resolveSiteName()
    recompute()
  }

  Component.onCompleted: Qt.callLater(applyConfig)
  Component.onDestruction: if (_url !== "") SlHub.unsubscribe(_url, _subToken)

  Connections {
    target: SlHub
    function onUpdated(url) { if (url === root._url) root.recompute() }
    function onFetchingChanged(url) {
      if (url !== root._url) return
      var e = SlHub.entry(url)
      root.busy = e ? e.fetching === true : false
    }
    function onSitesReady() {
      if (root.config.siteId > 0) root.resolveSiteName()
      else if (root.config.siteName !== "") root.resolveSiteByName()
    }
  }

  // Ages the countdown between fetches, so "4 min" becomes "3 min" without
  // another round trip to SL.
  Timer {
    interval: 15000
    repeat: true
    running: root.config.siteId > 0
    onTriggered: root.recompute()
  }

  // ----------------------------------------------------------------- sites

  readonly property bool sitesLoading: SlHub.sitesLoading
  readonly property string sitesError: SlHub.sitesError

  function loadSites() {
    SlHub.loadSites()
  }

  function searchSites(query) {
    return SlHub.searchSites(query, 8)
  }

  // Adds the "(note)" suffix to the header when the list is already in
  // memory; never triggers the 1.3 MB load just for a suffix. The one case
  // that does warrant loading is an id-only config, which has no name at all.
  function resolveSiteName() {
    if (SlHub.sites.length === 0) {
      if (config.siteName === "") SlHub.loadSites()
      return
    }
    var site = Model.findSiteById(SlHub.sites, config.siteId)
    if (site) resolvedSiteName = Model.siteLabel(site)
  }

  signal siteResolved(int siteId, string name)

  // Turns a name-only config into an id, so `"siteName": "Slussen"` alone is
  // a working configuration. Needs the list — there is nothing to fetch
  // without the id — so this one loads it.
  function resolveSiteByName() {
    if (SlHub.sites.length === 0) { SlHub.loadSites(); return }
    var match = Model.findSiteByName(SlHub.sites, config.siteName)
    if (match) siteResolved(match.id, Model.siteLabel(match))
  }
}

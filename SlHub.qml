pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// One hub per shell process for everything SL-shaped that should not be
// duplicated per widget instance: the departure fetch loop and the site
// directory. Omarchy instantiates a bar surface per monitor and this widget
// allows multiple entries, so without the hub every copy would run its own
// curl loop against the same URL and parse its own copy of the 1.3 MB site
// list. Here, instances subscribe to a departures URL and share one fetch,
// one parsed payload, and one clock anchor.
//
// Entries are plain JS objects mutated in place; consumers are notified by
// the explicit updated()/fetchingChanged() signals, not by property bindings.
Item {
  id: hub

  // url -> { subs, intervalMs, nextDue, departures, stopDeviations,
  //          hasPayload, lastUpdated, clockOffset, clockAnchored, error,
  //          fetching, queued }
  property var _entries: ({})
  property var _queue: []
  property int _nextToken: 1

  signal updated(string url)
  signal fetchingChanged(string url)

  function entry(url) {
    return _entries[url] || null
  }

  // Subscriptions are tokened so each subscriber's interval is known
  // individually: the merged interval is the true minimum across live
  // subscribers, and recovers when the tightest subscriber leaves or relaxes
  // (updateInterval below) instead of sticking at the smallest value ever asked.
  function subscribe(url, intervalSec) {
    var e = _entries[url]
    if (!e) {
      e = { subs: {}, intervalMs: 0, nextDue: 0, departures: [], stopDeviations: [],
            hasPayload: false, lastUpdated: 0, clockOffset: 0, clockAnchored: false,
            error: "", fetching: false, queued: false }
      _entries[url] = e
    }
    var token = _nextToken++
    e.subs[token] = Math.max(15, intervalSec) * 1000
    _remergeInterval(e)
    scheduler.running = true
    if (!e.hasPayload) requestNow(url)
    return token
  }

  // Re-declares one subscriber's interval. The interval is not part of the
  // departures URL, so a config edit that changes only refreshIntervalSec
  // arrives through here rather than through a resubscribe.
  function updateInterval(url, token, intervalSec) {
    var e = _entries[url]
    if (!e || e.subs[token] === undefined) return
    e.subs[token] = Math.max(15, intervalSec) * 1000
    _remergeInterval(e)
  }

  function unsubscribe(url, token) {
    var e = _entries[url]
    if (!e) return
    delete e.subs[token]
    if (Object.keys(e.subs).length > 0) {
      _remergeInterval(e)
      return
    }
    // Last subscriber gone: drop the entry, or every URL ever subscribed
    // would keep its parsed payload (and its slot in the scheduler loop) for
    // the life of the shell process. A fetch already in flight for this URL
    // finds no entry in maybeFinish and discards its result.
    delete _entries[url]
    var at = _queue.indexOf(url)
    if (at !== -1) _queue.splice(at, 1)
  }

  // The merged interval is the minimum across subscribers. On a tightening,
  // nextDue is pulled in against the payload's age, so a new 15s subscriber
  // is not left waiting out the remainder of a previous 600s lap.
  function _remergeInterval(e) {
    var min = 0
    for (var token in e.subs) {
      var ms = e.subs[token]
      if (min === 0 || ms < min) min = ms
    }
    e.intervalMs = min
    if (min > 0 && e.nextDue > 0)
      e.nextDue = Math.min(e.nextDue, (e.lastUpdated > 0 ? e.lastUpdated : Date.now()) + min)
  }

  function requestNow(url) {
    var e = _entries[url]
    if (!e || e.queued || (e.fetching && _activeUrl === url)) return
    e.queued = true
    _queue.push(url)
    pump()
  }

  // ------------------------------------------------------------ fetch loop
  //
  // One Process, one URL at a time. Departure payloads answer in ~150ms, so
  // serializing keeps the hub simple without a visible cost even with several
  // distinct stops subscribed.

  property string _activeUrl: ""
  property var _stdoutText: null
  property var _stderrText: null
  property var _exitCode: null

  function pump() {
    if (fetchProcess.running || watchdog.running || settle.running || _queue.length === 0) return
    var url = _queue.shift()
    var e = _entries[url]
    if (!e) { pump(); return }
    e.queued = false
    e.fetching = true
    _activeUrl = url
    _stdoutText = null
    _stderrText = null
    _exitCode = null
    // The response is capped in transit: --max-filesize aborts early when the
    // server declares a size, and the head pipe hard-bounds what can reach
    // this process when it does not. pipefail makes a truncated (i.e. above
    // cap) transfer a failed fetch rather than a silently clipped payload.
    fetchProcess.command = ["bash", "-c",
      "set -o pipefail; curl -fsS --max-time 10 --max-filesize 4194304 -- \"$1\" | head -c 4194304",
      "bash", url]
    fetchProcess.running = true
    watchdog.restart()
    fetchingChanged(url)
  }

  // Exit and stream-finished have no guaranteed order (see the shell's
  // speedtest panel for the same caveat), so completion is a barrier: the
  // payload is applied only once the exit code AND both streams are in.
  // Acting on exit alone can read an empty stdout from a successful fetch.
  function maybeFinish() {
    if (_exitCode === null || _stdoutText === null || _stderrText === null) return
    watchdog.stop()
    var url = _activeUrl
    var e = _entries[url]
    _activeUrl = ""
    if (e) {
      applyResult(e, _exitCode, _stdoutText, _stderrText)
      e.fetching = false
      e.nextDue = Date.now() + (e.intervalMs || 30000)
      fetchingChanged(url)
      updated(url)
    }
    pump()
  }

  function applyResult(e, exitCode, stdoutText, stderrText) {
    if (exitCode !== 0) {
      // The last good departures are kept: a stale board that keeps counting
      // down beats a blank one, and beats one frozen at old minutes.
      var message = String(stderrText || "").replace(/^\s+|\s+$/g, "")
      e.error = message !== "" ? message : "Could not reach SL (curl " + exitCode + ")"
      return
    }
    var parsed = Model.parseDepartures(stdoutText)
    if (!parsed.ok) {
      e.error = parsed.error
      return
    }
    e.departures = parsed.departures
    e.stopDeviations = parsed.stopDeviations
    e.hasPayload = true
    e.lastUpdated = Date.now()
    e.error = ""

    var offset = Model.clockOffset(parsed.departures, Date.now())
    if (Model.saneClockOffset(offset)) {
      e.clockOffset = offset
      e.clockAnchored = true
    } else if (!e.clockAnchored) {
      e.clockOffset = Model.nowMs() - Date.now()
    }
  }

  Process {
    id: fetchProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { hub._stdoutText = String(text || ""); hub.maybeFinish() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { hub._stderrText = String(text || ""); hub.maybeFinish() }
    }
    onExited: function(exitCode) { hub._exitCode = exitCode; hub.maybeFinish() }
  }

  // If a stream signal never lands (a process that could not spawn, a stream
  // that never closes), the barrier above would wedge the queue for the whole
  // shell session. Well past curl's own 10s ceiling, give up on the run.
  Timer {
    id: watchdog
    interval: 20000
    onTriggered: {
      if (fetchProcess.running) fetchProcess.running = false
      if (hub._exitCode === null) hub._exitCode = -1
      if (hub._stdoutText === null) hub._stdoutText = ""
      if (hub._stderrText === null) hub._stderrText = "Fetch timed out"
      // The killed process's own exit/stream signals can still arrive after
      // this forced completion; started straight away, the next fetch would
      // share the three slots with them and could apply a mix of the two
      // runs. Hold the queue while they drain (settle below).
      settle.restart()
      hub.maybeFinish()
    }
  }

  // Absorbs the abandoned run's late signals: anything landing in the shared
  // _exitCode/_stdoutText/_stderrText slots before this fires belongs to the
  // killed fetch (maybeFinish ignores it — _activeUrl is already empty), and
  // the slots are wiped before the queue moves on.
  Timer {
    id: settle
    interval: 1500
    onTriggered: {
      hub._exitCode = null
      hub._stdoutText = null
      hub._stderrText = null
      hub.pump()
    }
  }

  // Coarse scheduler: wakes every 5s and fetches whatever is due. Overdue
  // entries (after suspend, say) fetch on the first tick back.
  Timer {
    id: scheduler
    interval: 5000
    repeat: true
    onTriggered: {
      var now = Date.now()
      var anyLive = false
      for (var url in hub._entries) {
        var e = hub._entries[url]
        anyLive = true
        if (!e.fetching && !e.queued && now >= e.nextDue) hub.requestNow(url)
      }
      if (!anyLive) scheduler.running = false
    }
  }

  // ----------------------------------------------------------------- sites
  //
  // The 1.3 MB site list is cached on disk, refreshed weekly, and parsed into
  // memory once per shell process — and only when something actually needs it
  // (the picker, or resolving a configured name to an id).

  property var sites: []
  property bool sitesLoading: false
  property string sitesError: ""
  property bool _sitesRetried: false
  property string _siteCacheText: ""

  // The cache download and the hardened cache read (O_NOFOLLOW, fstat, size
  // cap) live in bin/sl-sites, which ships alongside this file; the widget
  // and the CLI govern the shared cache with one audited protocol instead of
  // two hand-synced copies.
  readonly property string _slSitesBin: {
    var url = Qt.resolvedUrl("bin/sl-sites").toString()
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : url
  }

  signal sitesReady()

  function loadSites() {
    if (sites.length > 0 || sitesLoading) return
    sitesLoading = true
    sitesError = ""
    _sitesRetried = false
    readSiteCache()
  }

  // Exit codes: 2 = missing (the normal cold start), 3 = refused (symlink,
  // not regular, or too large).
  function readSiteCache() {
    siteReadProcess.command = ["bash", _slSitesBin, "--read-cache"]
    siteReadProcess.running = true
  }

  function searchSites(query, limit) {
    return Model.searchSites(sites, query, limit)
  }

  function ensureSiteCache() {
    if (siteCacheProcess.running) return
    siteCacheProcess.command = ["bash", _slSitesBin, "--ensure-cache"]
    siteCacheProcess.running = true
  }

  Process {
    id: siteCacheProcess
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        hub.sitesLoading = false
        hub.sitesError = "Could not download the SL stop list"
        return
      }
      if (hub.sitesLoading) hub.readSiteCache()
    }
  }

  Process {
    id: siteReadProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: hub._siteCacheText = String(text || "")
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        hub.sites = Model.parseSites(hub._siteCacheText)
        hub._siteCacheText = ""
        hub.sitesError = hub.sites.length > 0 ? "" : "The SL stop list came back empty"
        hub.sitesLoading = false
        hub.sitesReady()
        return
      }
      hub._siteCacheText = ""
      // A miss on the first read is the normal cold-start path: the cache has
      // not been downloaded yet. Ask for it once and stop, so a download that
      // keeps producing an unreadable file cannot spin.
      if (exitCode === 2 && !hub._sitesRetried) {
        hub._sitesRetried = true
        hub.ensureSiteCache()
        return
      }
      hub.sitesLoading = false
      hub.sitesError = exitCode === 3
        ? "Refusing the SL stop list cache (not a regular file, or too large)"
        : "Could not read the SL stop list cache"
    }
  }
}

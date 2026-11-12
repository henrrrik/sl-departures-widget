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

  // Rate-limit backoff. SL's quota is enforced on the caller, not per
  // endpoint (every URL answers 429 once it trips), so the backoff is
  // hub-wide: while it runs, no stop fetches and the site list is not
  // downloaded. Each consecutive 429 doubles the wait up to the cap, and a
  // Retry-After from SL lengthens it when it asks for more. Any answer from
  // SL that is not a 429 clears it. Between the backoff lapsing and that
  // answer the hub is "recovering" (_backoffMs > 0) and fetches one stop at
  // a time, so a pile of overdue stops does not burst into a quota still
  // near its limit.
  readonly property int _backoffFloorMs: 60000
  readonly property int _backoffCapMs: 600000
  property int _backoffMs: 0
  // The wait actually set for the current backoff: _backoffMs, or longer
  // when Retry-After asked for more.
  property int _backoffWaitMs: 0
  property real _backoffUntil: 0

  // The deadline is wall-clock time, so a clock stepped backwards (an NTP
  // correction, a manual change) would stretch it by the size of the step.
  // What is left can never legitimately exceed the wait that was set, so a
  // longer remainder is clamped back to it.
  function _backingOff() {
    var remaining = _backoffUntil - Date.now()
    if (remaining <= 0) return false
    if (remaining > _backoffWaitMs) _backoffUntil = Date.now() + _backoffWaitMs
    return true
  }

  // Every SL call writes its HTTP status and any Retry-After to stderr
  // (Model.parseHttpStatus has the format), so a 429 is read from the status
  // itself rather than from curl's wording of the error.
  function _httpStatus(stderrText) {
    return Model.parseHttpStatus(stderrText, Date.now())
  }

  function _isRateLimited(status) {
    return status.code === 429
  }

  function _noteRateLimit(status) {
    var now = Date.now()
    // A 429 long after the last backoff ended starts a fresh episode; only
    // 429s close together are consecutive. Between them, network failures
    // carry no news about the quota either way.
    if (_backoffMs > 0 && now - _backoffUntil > _backoffCapMs) _backoffMs = 0
    _backoffMs = _backoffMs > 0 ? Math.min(_backoffMs * 2, _backoffCapMs) : _backoffFloorMs
    _backoffWaitMs = Math.max(_backoffMs, status ? status.retryAfterMs : 0)
    _backoffUntil = now + _backoffWaitMs
    // Anything queued behind the 429 would only draw another; the scheduler
    // re-requests it once the backoff lapses.
    for (var i = 0; i < _queue.length; i++) {
      var queued = _entries[_queue[i]]
      if (queued) queued.queued = false
    }
    _queue = []
  }

  // SL answered with something other than a 429, so the quota is not
  // tripped: the next 429 starts again from the floor. Not while a backoff
  // is still running, which a request already in flight when it started
  // (the site download) cannot speak for.
  function _noteAnswered(status) {
    if (status.code > 0 && status.code !== 429 && !_backingOff()) {
      _backoffMs = 0
      _backoffWaitMs = 0
      _backoffUntil = 0
    }
  }

  function _minutesUntil(at) {
    return Math.max(1, Math.ceil((at - Date.now()) / 60000)) + " min"
  }

  // The backoff blocks every stop, so every subscriber shows it, not only
  // the one whose fetch drew the 429. The retry time is the later of the
  // backoff's end and the entry's own next due time, which is when the
  // scheduler will actually fetch it. Empty when no backoff is running.
  function rateLimitMessage(url) {
    if (!_backingOff()) return ""
    var e = _entries[url]
    var at = Math.max(_backoffUntil, e ? e.nextDue : 0)
    return "SL rate limit reached — retrying in " + _minutesUntil(at)
  }

  function _notifyAll() {
    for (var url in _entries) updated(url)
  }

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
    // Manual refreshes included: during a backoff they would only draw
    // another 429 and push the quota window further out. The scheduler
    // picks the entry up once the backoff lapses. The updated() lets the
    // subscriber redraw the rate-limit countdown, so the refused request
    // still answers with something on screen.
    if (_backingOff()) {
      updated(url)
      return
    }
    // Recovering: one fetch in flight at a time until a success clears the
    // backoff. Refused requests are picked up by the scheduler's next tick.
    if (_backoffMs > 0 && (_activeUrl !== "" || _queue.length > 0)) return
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
    // No backoff check here: requestNow refuses to queue during one, and
    // _noteRateLimit empties the queue when one starts.
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
      "set -o pipefail; curl -fsS --max-time 10 --max-filesize 4194304"
        + " -w '%{stderr}SLHTTP %{http_code} %header{retry-after}\\n' -- \"$1\" | head -c 4194304",
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
    // Checked before the entry lookup: a 429 for a URL that was unsubscribed
    // mid-fetch still counts against the caller's quota, and must start the
    // backoff before the next stop's fetch goes out.
    var status = _httpStatus(_stderrText)
    var limited = _isRateLimited(status)
    if (limited) _noteRateLimit(status)
    else _noteAnswered(status)
    if (e) {
      applyResult(e, _exitCode, _stdoutText, Model.stripHttpStatus(_stderrText), limited)
      e.fetching = false
      // A rate-limited entry retries as soon as the backoff allows.
      e.nextDue = limited ? _backoffUntil : Date.now() + (e.intervalMs || 30000)
      fetchingChanged(url)
      if (!limited) updated(url)
    }
    if (limited) _notifyAll()
    pump()
  }

  function applyResult(e, exitCode, stdoutText, stderrText, limited) {
    if (exitCode !== 0) {
      // The last good departures are kept: a stale board that keeps counting
      // down beats a blank one, and beats one frozen at old minutes.
      if (limited) {
        // The countdown comes from rateLimitMessage() while the backoff
        // runs; this stays behind until the retry lands.
        e.error = "SL rate limit reached"
        return
      }
      var message = stderrText
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
      // Nothing can fetch during a backoff; requestNow would only refuse.
      var blocked = hub._backingOff()
      for (var url in hub._entries) {
        var e = hub._entries[url]
        anyLive = true
        // nextDue is wall-clock too: after the clock steps backwards, a due
        // time further out than one interval (or one backoff) is the step,
        // not a schedule, and would stall the stop by its size.
        if (e.nextDue - now > Math.max(e.intervalMs || 30000, hub._backoffWaitMs)) e.nextDue = now
        if (!blocked && !e.fetching && !e.queued && now >= e.nextDue) hub.requestNow(url)
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

  // The download hits the same SL API as the departures, so it honors the
  // hub-wide backoff and a 429 from it starts one. Without the guard, every
  // reopening of the picker on a cold cache would spend quota mid-backoff.
  //
  // background: the weekly refresh check that follows a successful read of
  // an existing cache. It stays silent (the list on screen is still good),
  // and re-reads only when bin/sl-sites reports it actually downloaded.
  function ensureSiteCache(background) {
    if (siteCacheProcess.running) return
    if (_backingOff()) {
      if (background) return
      sitesLoading = false
      sitesError = "SL rate limit reached — try again in " + _minutesUntil(_backoffUntil)
      return
    }
    // A foreground download is itself this process's refresh check.
    _siteRefreshChecked = true
    _siteCacheBackground = background === true
    _siteCacheExit = null
    _siteCacheStdout = null
    _siteCacheStderr = null
    siteCacheProcess.command = ["bash", _slSitesBin, "--ensure-cache", "--status"]
    siteCacheProcess.running = true
  }

  // Same exit/stream ordering caveat as the departures fetch: the result is
  // handled once the exit code and both streams have landed.
  property var _siteCacheExit: null
  property var _siteCacheStdout: null
  property var _siteCacheStderr: null
  property bool _siteCacheBackground: false
  // Once per shell process: a cache that already exists is checked for age
  // after it is read, or the weekly refresh would never happen.
  property bool _siteRefreshChecked: false

  function _siteCacheFinish() {
    if (_siteCacheExit === null || _siteCacheStdout === null || _siteCacheStderr === null) return
    var exitCode = _siteCacheExit
    var fetched = /\bfetched\b/.test(_siteCacheStdout)
    var status = _httpStatus(_siteCacheStderr)
    var background = _siteCacheBackground
    _siteCacheExit = null
    _siteCacheStdout = null
    _siteCacheStderr = null
    if (!_isRateLimited(status)) _noteAnswered(status)
    if (exitCode !== 0) {
      var limited = _isRateLimited(status)
      if (limited) {
        _noteRateLimit(status)
        _notifyAll()
      }
      if (background) return
      sitesLoading = false
      sitesError = limited
        ? "SL rate limit reached — try again in " + _minutesUntil(_backoffUntil)
        : "Could not download the SL stop list"
      return
    }
    if (background ? fetched : sitesLoading) readSiteCache()
  }

  Process {
    id: siteCacheProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { hub._siteCacheStdout = String(text || ""); hub._siteCacheFinish() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { hub._siteCacheStderr = String(text || ""); hub._siteCacheFinish() }
    }
    onExited: function(exitCode) { hub._siteCacheExit = exitCode; hub._siteCacheFinish() }
  }

  Process {
    id: siteReadProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: hub._siteCacheText = String(text || "")
    }
    onExited: function(exitCode) {
      // A re-read after the background refresh: the list in memory is good,
      // so a failed or empty re-read keeps it rather than blanking the picker.
      var refreshing = hub.sites.length > 0
      if (exitCode === 0) {
        var parsed = Model.parseSites(hub._siteCacheText)
        hub._siteCacheText = ""
        if (parsed.length > 0 || !refreshing) hub.sites = parsed
        hub.sitesError = hub.sites.length > 0 ? "" : "The SL stop list came back empty"
        hub.sitesLoading = false
        hub.sitesReady()
        if (!hub._siteRefreshChecked) {
          hub._siteRefreshChecked = true
          hub.ensureSiteCache(true)
        }
        return
      }
      hub._siteCacheText = ""
      if (refreshing) return
      // A miss on the first read is the normal cold-start path: the cache has
      // not been downloaded yet. Ask for it once and stop, so a download that
      // keeps producing an unreadable file cannot spin.
      if (exitCode === 2 && !hub._sitesRetried) {
        hub._sitesRetried = true
        hub.ensureSiteCache(false)
        return
      }
      hub.sitesLoading = false
      hub.sitesError = exitCode === 3
        ? "Refusing the SL stop list cache (not a regular file, or too large)"
        : "Could not read the SL stop list cache"
    }
  }
}

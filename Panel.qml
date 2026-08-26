import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// SL departures in the Omarchy bar: the next few departures as a label, and a
// popup with the full board, service messages, and a searchable stop picker.
//
//   left click   toggle the popup      r  refresh
//   right click  refresh               s  pick a stop
//   middle click pick a stop           j/k, arrows  scroll the board
Panel {
  id: root
  moduleName: "io.github.henrrrik.sl-departures"

  readonly property var config: Model.resolveConfig(settings)
  readonly property bool vertical: bar ? bar.vertical : false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var visibleRows: service.rows.slice(0, config.panelCount)

  // How stale the board is, recomputed off the same tick that ages the
  // countdown so the two never disagree.
  property double freshnessTick: 0
  readonly property string freshnessText: {
    freshnessTick  // reactive dependency
    if (service.lastUpdated <= 0) return "r to refresh"
    var seconds = Math.max(0, Math.round((Date.now() - service.lastUpdated) / 1000))
    var age = seconds < 60 ? seconds + "s ago" : Math.round(seconds / 60) + " min ago"
    return "Updated " + age + " · r to refresh"
  }
  readonly property var barDepartures: Model.barRows(service.rows, config)
  readonly property string barText: Model.barLabel(barDepartures, config, service.fetchState)
  readonly property var barLines: Model.verticalBarLines(barDepartures, config)

  // Stop picker state. `picking` swaps the popup body for the search field;
  // the board stays loaded behind it so cancelling costs nothing.
  property bool picking: false
  property var suggestions: []
  property int suggestionIndex: 0
  property bool cursorActive: false
  property int rowIndex: 0

  // ---------------------------------------------------------------- actions

  function refresh() {
    service.refresh()
  }

  function startPicking() {
    picking = true
    suggestions = []
    suggestionIndex = 0
    service.loadSites()
    if (!opened) open()
    Qt.callLater(function() {
      searchField.text = ""
      searchField.forceActiveFocus()
    })
  }

  function cancelPicking() {
    picking = false
    suggestions = []
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function updateSuggestions() {
    suggestions = service.searchSites(searchField.text)
    suggestionIndex = 0
  }

  // Key-sorted copy of a layout entry minus its id, so two entries can be
  // compared for identity regardless of key order.
  function entryFingerprint(entry) {
    var keys = []
    for (var key in entry) if (key !== "id") keys.push(key)
    keys.sort()
    var out = {}
    for (var i = 0; i < keys.length; i++) out[keys[i]] = entry[keys[i]]
    return JSON.stringify(out)
  }

  // Persists the chosen stop back into this widget's own shell.json entry, so
  // picking a stop is a durable configuration change rather than a setting
  // that evaporates on restart. Applied locally first so the board switches on
  // the click itself, before the config round-trips through the shell.
  //
  // The write goes through mutateShellConfig and finds THIS instance's entry
  // by comparing settings, not just ids: this widget allows multiple
  // instances, and the shell's updateEntryInline convenience updates every
  // entry with a matching id — picking a stop in one widget would repoint all
  // of them. (Identical entries are interchangeable, so first match is fine.)
  function selectSite(site) {
    if (!site) return
    var oldFingerprint = entryFingerprint(root.settings)
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.siteId = site.id
    entry.siteName = site.name

    root.settings = entry
    var shell = root.bar ? root.bar.shell : null
    if (shell && typeof shell.mutateShellConfig === "function") {
      shell.mutateShellConfig(function(config) {
        if (!config.bar || !config.bar.layout) return
        var sections = ["left", "center", "right"]
        for (var s = 0; s < sections.length; s++) {
          var arr = config.bar.layout[sections[s]] || []
          for (var i = 0; i < arr.length; i++) {
            if (!arr[i] || String(arr[i].id) !== root.moduleName) continue
            if (root.entryFingerprint(arr[i]) !== oldFingerprint) continue
            arr[i] = entry
            return
          }
        }
      })
    } else if (shell && typeof shell.updateEntryInline === "function") {
      shell.updateEntryInline(root.moduleName, entry)
    }

    cancelPicking()
  }

  function commitSuggestion() {
    if (suggestions.length === 0) return
    selectSite(suggestions[Math.max(0, Math.min(suggestionIndex, suggestions.length - 1))])
  }

  function moveCursor(dx, dy) {
    if (dy === 0 || visibleRows.length === 0) return
    cursorActive = true
    rowIndex = Math.max(0, Math.min(visibleRows.length - 1, rowIndex + dy))
    scrollCursorIntoView()
  }

  function scrollCursorIntoView() {
    if (!cursorActive || rowIndex < 0 || rowIndex >= rowColumn.children.length) return
    var item = rowColumn.children[rowIndex]
    if (!item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // A refresh can shrink the board under the keyboard cursor; clamping keeps
  // the highlight on the last row instead of silently vanishing.
  onVisibleRowsChanged: {
    if (cursorActive && rowIndex >= visibleRows.length)
      rowIndex = Math.max(0, visibleRows.length - 1)
  }

  onOpenedChanged: {
    if (!opened) {
      picking = false
      return
    }
    cursorActive = false
    rowIndex = 0
    panelFlick.contentY = 0
    service.refresh()
    // A stop has to be chosen before there is anything to show, so an
    // unconfigured widget opens straight into the picker.
    if (config.siteId <= 0) startPicking()
    else Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Timer {
    interval: 5000
    repeat: true
    running: root.opened
    onTriggered: root.freshnessTick = Date.now()
  }

  Service {
    id: service
    settings: root.settings

    // A config that names a stop without an id gets the id filled in once the
    // site list lands, so the next start skips the lookup entirely.
    onSiteResolved: function(siteId, name) {
      if (root.config.siteId > 0 || root.config.siteName === "") return
      root.selectSite({ id: siteId, name: root.config.siteName })
    }
  }

  // ------------------------------------------------------------ bar button

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.barText
    labelVisible: !root.vertical
    hasVisualContent: true
    fixedHeight: root.vertical ? root.barLines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: root.opened ? "" : Model.tooltipText(service.rows, root.config, service.siteLabel)
    dimmed: service.fetchState === "loading" && service.rows.length === 0

    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh()
      else if (b === Qt.MiddleButton) root.startPicking()
      else root.toggle()
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.barLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 2 ? button.fontSize * 0.85 : button.fontSize
          color: button.foreground
        }
      }
    }
  }

  // ------------------------------------------------------------------ popup
  // Three bands rather than one long scroll: the stop name and the change-stop
  // action are the two things you must always be able to see and reach, so
  // only the board between them scrolls.
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.picking ? searchField : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(chromeHeight + bodyColumn.implicitHeight, Style.space(560))

    // Everything the fixed bands occupy around the scrolling body. The anchors
    // below read the same three gaps, so the reservation cannot drift out of
    // step with the layout — and a body of one search field or one row asks
    // for exactly the height it needs instead of coming up a few pixels short
    // and being clipped by the Flickable.
    readonly property int bodyTopGap: Style.space(12)
    readonly property int bodyBottomGap: Style.space(10)
    readonly property int footerTopGap: Style.space(10)
    readonly property int chromeHeight: headerBlock.implicitHeight + bodyTopGap + bodyBottomGap
      + footerSeparator.height + footerTopGap + footerBlock.implicitHeight

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.picking

      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = t.toLowerCase()
        if (key === "r") root.refresh()
        else if (key === "s") root.startPicking()
      }

      // -------------------------------------------------------- header

      PanelHero {
        id: headerBlock
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        title: service.siteLabel
        meta: root.picking
          ? "Search for a stop"
          : (Model.filterSummary(root.config) || "Live departures")
        foreground: root.foreground
        fontFamily: root.fontFamily

        iconComponent: Component {
          Text {
            textFormat: Text.PlainText
            text: root.barDepartures.length > 0 ? root.barDepartures[0].icon : "󰥔"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
        }
      }

      // ---------------------------------------------------------- body

      Flickable {
        id: panelFlick
        anchors.top: headerBlock.bottom
        anchors.topMargin: panel.bodyTopGap
        anchors.bottom: footerSeparator.top
        anchors.bottomMargin: panel.bodyBottomGap
        anchors.left: parent.left
        anchors.right: parent.right
        contentWidth: width
        contentHeight: bodyColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: bodyColumn
          width: panelFlick.width
          spacing: Style.space(12)

          // ------------------------------------------------ stop picker

          Column {
            visible: root.picking
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: searchField
              width: parent.width
              placeholderText: service.sitesLoading ? "Loading stops…" : "Stop, station or berth"
              enabled: !service.sitesLoading
              foreground: root.foreground
              font.family: root.fontFamily

              onTextChanged: root.updateSuggestions()

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.cancelPicking()
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  if (root.suggestionIndex < root.suggestions.length - 1) root.suggestionIndex++
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  if (root.suggestionIndex > 0) root.suggestionIndex--
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.commitSuggestion()
                  event.accepted = true
                }
              }
            }

            Text {

              textFormat: Text.PlainText
              visible: service.sitesError !== ""
              width: parent.width
              text: service.sitesError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {

              textFormat: Text.PlainText
              visible: !service.sitesLoading && service.sitesError === ""
                && searchField.text.length > 0 && root.suggestions.length === 0
              width: parent.width
              text: "No stop matches that."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.suggestions

                CursorSurface {
                  id: suggestionRow
                  required property var modelData
                  required property int index

                  width: parent.width
                  implicitHeight: suggestionLabel.implicitHeight + Style.spacing.rowPaddingX
                  hasCursor: root.suggestionIndex === index
                  foreground: root.foreground

                  Text {

                    textFormat: Text.PlainText
                    id: suggestionLabel
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.siteLabel(suggestionRow.modelData)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.suggestionIndex = suggestionRow.index
                    onClicked: root.selectSite(suggestionRow.modelData)
                  }
                }
              }
            }
          }

          // -------------------------------------------- departure board

          Text {

            textFormat: Text.PlainText
            visible: !root.picking && service.lastError !== ""
            width: parent.width
            text: service.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {

            textFormat: Text.PlainText
            visible: !root.picking && root.visibleRows.length === 0 && service.lastError === ""
            width: parent.width
            text: root.config.siteId <= 0
              ? "No stop selected yet."
              : (service.fetchState === "loading" ? "Loading departures…" : "Nothing leaving in the next "
                  + root.config.forecastMinutes + " minutes.")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            id: rowColumn
            visible: !root.picking && root.visibleRows.length > 0
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.visibleRows

              DepartureRow {
                required property var modelData
                required property int index
                width: rowColumn.width
                departure: modelData
                rowIndex: index
              }
            }
          }

          // ---------------------------------------- service disruptions

          PanelSeparator {
            visible: !root.picking && service.stopDeviations.length > 0
            foreground: root.foreground
          }

          Column {
            visible: !root.picking && service.stopDeviations.length > 0
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "SERVICE INFO"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: service.stopDeviations

              Text {

                textFormat: Text.PlainText
                required property var modelData
                width: parent.width
                text: "• " + String(modelData.message || "")
                color: (modelData.importance_level || 0) >= 5 ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }

      // -------------------------------------------------------- footer

      PanelSeparator {
        id: footerSeparator
        anchors.bottom: footerBlock.top
        anchors.bottomMargin: panel.footerTopGap
        anchors.left: parent.left
        anchors.right: parent.right
        foreground: root.foreground
      }

      Item {
        id: footerBlock
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        implicitHeight: Math.max(footerHint.implicitHeight, footerAction.implicitHeight)

        Text {

          textFormat: Text.PlainText
          id: footerHint
          anchors.left: parent.left
          anchors.right: footerAction.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: root.picking
            ? "Type to search · enter to select"
            : (service.busy ? "Refreshing…" : root.freshnessText)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Button {
          id: footerAction
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.picking ? "Cancel" : "Change stop"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.picking ? root.cancelPicking() : root.startPicking()
        }
      }
    }
  }

  // A single line of the departure board: mode icon, line number, where it is
  // headed, and how long you have. Cancelled services stay on the board —
  // struck through and in the urgent color — because their absence is the
  // information you opened the popup for.
  component DepartureRow: CursorSurface {
    id: departureRow

    property var departure: null
    property int rowIndex: 0

    readonly property bool imminent: departure && departure.minutes !== null && departure.minutes <= 1
    readonly property color rowColor: departure && departure.cancelled ? root.urgent : root.foreground

    hasCursor: root.cursorActive && root.rowIndex === rowIndex
    foreground: root.foreground
    implicitHeight: rowBody.implicitHeight + Style.space(8)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onEntered: {
        root.cursorActive = true
        root.rowIndex = departureRow.rowIndex
      }
    }

    Column {
      id: rowBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Item {
        width: parent.width
        implicitHeight: Math.max(lineLabel.implicitHeight, waitLabel.implicitHeight)

        Text {

          textFormat: Text.PlainText
          id: modeIcon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: departureRow.departure ? departureRow.departure.icon : ""
          color: Qt.darker(departureRow.rowColor, 1.3)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {

          textFormat: Text.PlainText
          id: lineLabel
          anchors.left: modeIcon.right
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(30)
          text: departureRow.departure ? departureRow.departure.line : ""
          color: departureRow.rowColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {

          textFormat: Text.PlainText
          id: destinationLabel
          anchors.left: lineLabel.right
          anchors.leftMargin: Style.space(6)
          anchors.right: waitLabel.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: departureRow.departure ? departureRow.departure.destination : ""
          color: departureRow.rowColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.strikeout: departureRow.departure ? departureRow.departure.cancelled : false
          elide: Text.ElideRight
        }

        Text {

          textFormat: Text.PlainText
          id: waitLabel
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: {
            if (!departureRow.departure) return ""
            if (departureRow.departure.cancelled) return "cancelled"
            return departureRow.departure.waitLabel
          }
          color: departureRow.imminent && !departureRow.departure.cancelled
            ? departureRow.rowColor
            : Qt.darker(departureRow.rowColor, 1.25)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: departureRow.imminent
        }
      }

      Text {

        textFormat: Text.PlainText
        visible: text !== ""
        width: parent.width
        text: {
          if (!departureRow.departure) return ""
          var parts = []
          if (departureRow.departure.clock !== "") parts.push(departureRow.departure.clock)
          if (departureRow.departure.berth !== "") parts.push("Stop " + departureRow.departure.berth)
          if (departureRow.departure.deviationText !== "") parts.push(departureRow.departure.deviationText)
          return parts.join(" · ")
        }
        color: departureRow.departure && departureRow.departure.deviationLevel >= 5
          ? root.urgent
          : Qt.darker(root.foreground, 1.7)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}

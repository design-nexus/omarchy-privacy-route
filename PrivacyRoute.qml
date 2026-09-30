import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "pages/nord" as Nord
import "pages/tor" as Tor
import "pages/nord/Model.js" as NordModel

// NordVPN and Tor behind one icon, with one rule the two plugins could not
// enforce on their own: only one of them carries system traffic at a time.
// Each page is a copy of the original plugin; their services call back into
// request() before connecting, and this widget takes the other route down
// first. Tor's SOCKS-only mode reroutes nothing, so it may run beside NordVPN.
BarWidget {
  id: root
  moduleName: "design-nexus.privacy-route"

  readonly property var pageKeys: ["nord", "tor"]
  readonly property var pageTitles: ({ nord: "NordVPN", tor: "Tor" })

  property string currentKey: "nord"
  property bool popupOpen: false
  property bool popoutSwitchClosing: false
  property bool switching: false
  property var panels: ({})
  readonly property var activePanel: panels[currentKey] || null
  readonly property bool activePanelShown: !!activePanel && activePanel.open

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var nord: nordPage.service
  readonly property var tor: torPage.service

  // ------------------------------------------------------------ route state

  readonly property bool nordLive: nord.connected || nord.transitioning
  readonly property bool torSystemWide: tor.effectiveMode !== "socks"
  readonly property bool torLive: tor.liveConnection || tor.bootstrapping
  readonly property bool conflict: nord.connected && tor.liveConnection && torSystemWide && pending === null
  readonly property bool nordKillSwitch: NordModel.settingEnabled(nord.vpnSettings["kill-switch"])
  readonly property string route: nord.connected ? "nord" : (tor.active ? "tor" : "off")
  property string lastRoute: String(setting("lastRoute", "nord")) === "tor" ? "tor" : "nord"

  // { target, go, since, lastNudge } while one route waits for the other to go down.
  property var pending: null
  property string routeError: ""
  property bool killSwitchWarning: false

  onRouteChanged: if (route !== "off" && route !== lastRoute) {
    lastRoute = route
    savePageSettings("lastRoute", route)
  }

  function otherLive(target) {
    return target === "tor" ? nordLive : (torLive && torSystemWide)
  }

  function takeDown(target) {
    if (target === "tor") nord.setConnected(false)
    else tor.disconnect()
  }

  // Called by the copied services before they connect.
  function request(target, go, mode) {
    routeError = ""
    if (target === "tor") {
      nord.refreshSettings()
      killSwitchWarning = nordKillSwitch && mode !== "socks"
    }
    if ((target === "tor" && mode === "socks") || !otherLive(target)) {
      pending = null
      go()
      return
    }
    pending = { target: target, go: go, since: Date.now(), lastNudge: Date.now(), settled: 0 }
    takeDown(target)
    pendingTimer.restart()
  }

  function cancelPending() {
    pending = null
    pendingTimer.stop()
  }

  Timer {
    id: pendingTimer
    interval: 1000
    repeat: true
    running: root.pending !== null
    onTriggered: {
      var p = root.pending
      if (!p) return
      if (p.target === "tor") root.nord.refresh()
      else root.tor.refresh()

      if (!root.otherLive(p.target)) {
        // One more beat after it reports down, so its firewall rules are gone
        // before the next route installs its own.
        if (p.settled++ < 1) return
        root.pending = null
        p.go()
        return
      }
      var now = Date.now()
      if (now - p.since > 30000) {
        root.routeError = (p.target === "tor" ? "NordVPN" : "Tor") + " did not disconnect; "
          + root.pageTitles[p.target] + " was not started."
        root.pending = null
        Quickshell.execDetached(["omarchy-notification-send", "Privacy route", root.routeError])
        return
      }
      // A disconnect can be dropped while the service is mid-command; ask again.
      if (now - p.lastNudge > 5000) {
        p.lastNudge = now
        root.takeDown(p.target)
      }
    }
  }

  function setRoute(target) {
    if (target === "off") {
      cancelPending()
      if (nordLive) nord.setConnected(false)
      if (tor.active || tor.torRunning) tor.disconnect()
    } else if (target === "nord") {
      if (!nord.connected) nord.toggle()
    } else if (target === "tor") {
      if (!tor.active) tor.connect(tor.effectiveMode)
    }
  }

  // ------------------------------------------------------------ page host API

  readonly property alias pageArea: pageArea
  readonly property real borderInsetV: Border.top(panel.borderSpec) + Border.bottom(panel.borderSpec)
  readonly property real borderInsetH: Border.left(panel.borderSpec) + Border.right(panel.borderSpec)
  readonly property real availablePageWidth: Math.max(120, panel.availableCardWidth - borderInsetH)
  readonly property real availablePageHeight: Math.max(120, panel.availableCardHeight - borderInsetV - header.height)

  function pageSettings(key) {
    var value = settings ? settings[key] : null
    return value && typeof value === "object" ? value : ({})
  }

  function savePageSettings(key, entry) {
    var shell = bar ? bar.shell : null
    if (!shell || typeof shell.updateEntryInline !== "function") return false
    var next = {}
    for (var k in settings) if (k !== "id") next[k] = settings[k]
    if (entry !== null && typeof entry === "object") {
      var page = {}
      for (var p in entry) if (p !== "id") page[p] = entry[p]
      next[key] = page
    } else {
      next[key] = entry
    }
    return shell.updateEntryInline(root.moduleName, next)
  }

  function registerPanel(item) {
    if (!item || !item.pageKey || panels[item.pageKey] === item) return
    var next = {}
    for (var k in panels) next[k] = panels[k]
    next[item.pageKey] = item
    panels = next
    if (item.open) pageOpenChanged(item)
  }

  function pageOpenChanged(item) {
    if (!item || item.pageKey !== currentKey) return
    if (item.open) {
      if (popupOpen) Qt.callLater(focusActive)
      return
    }
    if (switching || !popupOpen) return
    var key = item.pageKey
    Qt.callLater(function() {
      if (!root.switching && root.popupOpen && root.currentKey === key && !root.pageIsOpen(key)) root.close()
    })
  }

  function focusActive() {
    if (popupOpen && activePanel && activePanel.focusTarget) activePanel.focusTarget.forceActiveFocus()
  }

  function cyclePage(direction) {
    var i = pageKeys.indexOf(currentKey) + (direction < 0 ? -1 : 1)
    if (i < 0 || i >= pageKeys.length) {
      return bar && typeof bar.switchPanelFrom === "function" ? bar.switchPanelFrom(root, direction) : false
    }
    showPage(pageKeys[i])
    return true
  }

  function entry(key) { return key === "tor" ? torPage : (key === "nord" ? nordPage : null) }
  function pageIsOpen(key) { var e = entry(key); return !!e && e.opened === true }

  // ------------------------------------------------------------ open / close

  function open() {
    if (popupOpen) return
    // Land on whichever route is carrying traffic.
    if (route !== "off") currentKey = route
    popupOpen = true
    entry(currentKey).open()
  }

  function close() {
    if (!popupOpen) return
    popupOpen = false
    switching = true
    entry(currentKey).close()
    switching = false
  }

  function toggle() { popupOpen ? close() : open() }

  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { root.popoutSwitchClosing = false })
  }

  function showPage(key) {
    if (pageKeys.indexOf(key) < 0) return
    if (key === currentKey) {
      if (!popupOpen) { popupOpen = true; entry(key).open() }
      return
    }
    switching = true
    if (popupOpen) entry(currentKey).close()
    currentKey = key
    switching = false
    if (!popupOpen) popupOpen = true
    entry(key).open()
    Qt.callLater(focusActive)
  }

  function refreshAll() {
    nord.refresh()
    nord.refreshSettings()
    tor.refresh()
  }

  function statusLine() {
    if (pending) return "Switching to " + pageTitles[pending.target] + "…"
    if (conflict) return "NordVPN and Tor are both on"
    if (route === "nord") return "Route: NordVPN" + (nord.country ? " · " + nord.country : "")
    if (route === "tor") {
      if (tor.bootstrapping) return "Route: Tor · bootstrapping " + tor.bootstrap + "%"
      return "Route: Tor · " + tor.effectiveMode + (tor.exitCountry ? " · exit " + tor.exitCountry.toUpperCase() : "")
    }
    return "Route: direct"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: nord.refreshSettings()

  // ------------------------------------------------------------ hosted pages

  PageBar { id: nordBar; realBar: root.bar; pageHost: root; pageKey: "nord"; pageEntry: nordPage }
  PageBar { id: torBar; realBar: root.bar; pageHost: root; pageKey: "tor"; pageEntry: torPage }

  Item {
    id: pageHolder
    visible: false
    width: 0
    height: 0

    Nord.Panel { id: nordPage; bar: nordBar; settings: root.pageSettings("nord") }
    Tor.Panel { id: torPage; bar: torBar; settings: root.pageSettings("tor") }
  }

  Binding { target: root.nord; property: "routeGuard"; value: root }
  Binding { target: root.tor; property: "routeGuard"; value: root }

  IpcHandler {
    target: "design-nexus.privacy-route"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function page(name: string): string {
      if (root.pageKeys.indexOf(name) < 0) return "unknown page: " + name + " (nord, tor)"
      root.showPage(name)
      return "ok"
    }
    function route(name: string): string {
      if (["off", "nord", "tor"].indexOf(name) < 0) return "unknown route: " + name + " (off, nord, tor)"
      root.setRoute(name)
      return "ok"
    }
    function status(): string { return root.statusLine() }
    function current(): string { return root.popupOpen ? root.currentKey : "closed" }
    function refresh(): string { root.refreshAll(); return "ok" }
  }

  // ------------------------------------------------------------ bar button

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    active: root.conflict || root.routeError !== ""
    tooltipText: root.statusLine() + (root.route === "off" ? "\nRight click: connect " + root.pageTitles[root.lastRoute] : "\nRight click: disconnect")
    fixedWidth: root.vertical ? -1 : Style.bar.iconSlot
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refreshAll()
      else if (b === Qt.RightButton) root.setRoute(root.route === "off" ? root.lastRoute : "off")
      else root.toggle()
    }

    readonly property color iconColor: button.active ? root.urgent
      : (root.route === "off" && root.pending === null ? Qt.darker(root.foreground, 1.55) : root.foreground)

    Item {
      anchors.fill: parent
      opacity: root.pending !== null || root.tor.bootstrapping || root.nord.transitioning ? 0.55 : 1

      SequentialAnimation on opacity {
        running: root.pending !== null || root.tor.bootstrapping || root.nord.transitioning
        loops: Animation.Infinite
        NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutQuad }
        NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutQuad }
      }

      Tor.TorIcon {
        visible: root.route === "tor"
        x: Math.round((parent.width - width) / 2)
        y: Math.round((parent.height - height) / 2)
        iconSize: Style.space(13)
        color: button.iconColor
      }

      OpticalGlyph {
        anchors.fill: parent
        visible: root.route !== "tor"
        // nf-md-shield_lock (NordVPN's own mark) when up, nf-md-shield_off when direct.
        text: String.fromCodePoint(root.route === "nord" ? 0xF099D : 0xF099E)
        fontFamily: root.fontFamily
        fontSize: Style.bar.iconFont
        color: button.iconColor
      }
    }
  }

  // ------------------------------------------------------------ popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.popupOpen
    padding: 0
    focusTarget: root.activePanel ? root.activePanel.focusTarget : null
    contentWidth: panel.fittedContentWidth(Math.max(Style.space(440),
      (root.activePanelShown ? root.activePanel.contentWidth : 0) + root.borderInsetH))
    contentHeight: root.borderInsetV + header.height
      + (root.activePanelShown ? root.activePanel.contentHeight : Style.space(80))

    Item {
      width: 0
      height: 0
      Shortcut {
        sequences: ["Ctrl+Tab", "Ctrl+Shift+Tab", "Ctrl+Backtab", "Ctrl+PgDown", "Ctrl+PgUp"]
        enabled: root.popupOpen
        onActivated: root.showPage(root.currentKey === "nord" ? "tor" : "nord")
      }
      Shortcut { sequence: "Alt+1"; enabled: root.popupOpen; onActivated: root.showPage("nord") }
      Shortcut { sequence: "Alt+2"; enabled: root.popupOpen; onActivated: root.showPage("tor") }
    }

    Column {
      anchors.fill: parent

      Column {
        id: header
        width: parent.width
        topPadding: Style.space(12)
        bottomPadding: Style.space(4)
        spacing: Style.space(8)

        Item {
          width: parent.width
          height: tabs.implicitHeight

          ButtonGroup {
            id: tabs
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            focusable: false
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            value: root.currentKey
            options: root.pageKeys.map(function(key) {
              var live = key === "nord" ? root.nord.connected : root.tor.active
              return { value: key, label: root.pageTitles[key] + (live ? " ●" : "") }
            })
            onChanged: function(value) { root.showPage(value) }
          }

          Button {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            visible: root.route !== "off" || root.pending !== null
            text: "Go direct"
            tooltipText: "Disconnect NordVPN and Tor"
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.setRoute("off")
          }
        }

        Text {
          x: Style.space(14)
          width: parent.width - Style.space(28)
          textFormat: Text.PlainText
          text: root.statusLine()
          color: root.conflict ? root.urgent : Color.foreground
          opacity: 0.75
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // Warnings that need an answer, one at a time.
        Rectangle {
          id: banner
          readonly property string kind: root.conflict ? "conflict"
            : (root.routeError !== "" ? "error"
            : (root.killSwitchWarning && root.nordKillSwitch && root.route === "tor" ? "killswitch" : ""))
          visible: kind !== ""
          x: Style.space(12)
          width: parent.width - Style.space(24)
          height: visible ? bannerRow.implicitHeight + Style.space(16) : 0
          radius: Style.cornerRadius
          color: Util.alpha(root.urgent, 0.14)
          border.width: 1
          border.color: Util.alpha(root.urgent, 0.5)

          Row {
            id: bannerRow
            anchors.verticalCenter: parent.verticalCenter
            x: Style.space(10)
            width: parent.width - Style.space(20)
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - actions.width - parent.spacing
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              color: Color.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              text: banner.kind === "conflict" ? "Both routes are up; traffic goes through NordVPN and Tor at once."
                : banner.kind === "error" ? root.routeError
                : banner.kind === "killswitch" ? "NordVPN's kill switch is on and can block Tor from connecting."
                : ""
            }

            Row {
              id: actions
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Button {
                visible: banner.kind === "conflict"
                text: "Keep NordVPN"
                fontSize: Style.font.caption
                onClicked: root.tor.disconnect()
              }
              Button {
                visible: banner.kind === "conflict"
                text: "Keep Tor"
                fontSize: Style.font.caption
                onClicked: root.nord.setConnected(false)
              }
              Button {
                visible: banner.kind === "killswitch"
                text: "Turn it off"
                fontSize: Style.font.caption
                onClicked: { root.nord.setSetting("killswitch", "off"); root.killSwitchWarning = false }
              }
              Button {
                visible: banner.kind === "error" || banner.kind === "killswitch"
                text: "Dismiss"
                fontSize: Style.font.caption
                onClicked: { root.routeError = ""; root.killSwitchWarning = false }
              }
            }
          }
        }
      }

      Item {
        id: pageArea
        width: parent.width
        height: parent.height - header.height
        clip: true
      }
    }
  }
}

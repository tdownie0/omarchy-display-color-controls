import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.monitor"
  ipcTarget: "omarchy.monitor"
  manageIpc: false

  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the brightness + state methods below.
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  property string internalMonitor: ""
  property string externalMonitor: ""
  property string focusedMonitor: ""
  property bool internalEnabled: false
  property bool mirrorEnabled: false
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0

  // wl-gammarelay-rs state (global root path). Independent of the hardware
  // backlight slider above.
  property bool gammaAvailable: false
  property int gammaBrightnessPercent: 100
  property int temperatureValue: 6500
  property real gammaValue: 1.0
  property bool invertedValue: false
  // Queued set-property command (args array) for the shared gammarelay writer.
  property var gammaQueuedCommand: []

  // View mode for the panel body: "main" shows the everyday controls
  // (brightness, text size, scale, displays); "advanced" swaps in the
  // wl-gammarelay-rs controls (brightness, temperature, gamma, invert).
  property string viewMode: "main"

  function toggleViewMode() {
    root.viewMode = root.viewMode === "main" ? "advanced" : "main"
    var sections = root.visibleSections
    if (sections && sections.length > 0) {
      root.focusSection = sections[0]
      root.selectedIndex = root.sectionFirstIndex(root.focusSection)
    }
  }

  // Virtual "header" section for the hero ADVANCED/BACK toggle, so it is
  // reachable from the keyboard
  readonly property bool headerHasCursor: cursorActive && focusSection === "header"
  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    selectedIndex = -1
  }

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Cursor model shared by keyboard and mouse. Sections:
  //   "brightness" - single slider row, selectedIndex = -1 sentinel
  //                  (mirrors Audio's slider rows). Only present if a
  //                  controllable backlight was detected.
  //   "scale"      - 6 Button scale presets; treated as a single
  //                  horizontal row from j/k's perspective. h/l moves
  //                  between presets, identical to bluetooth's header.
  //   "monitors"   - vertical display row list for enabling/disabling displays;
  //                  j/k walks each row.
  // Mouse hover on a target updates root state via the components' `hovered`
  // signal so keyboard cursor and pointer share one highlight.
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var scaleValues: {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.availableScales(scalePresets, display.width, display.height)
    }
    return scalePresets
  }
  property string focusSection: "scale"
  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property string resetGlyph: "󰑐"

  // Text size slider — curated macOS-style notches (px). The panel snaps to
  // these stops; the CLI (omarchy-display-text-size) accepts any integer in range.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // While a change is in flight, the chosen stop index overrides the live
  // base-size so the knob doesn't snap back during the file round-trip. -1 =
  // no pending change; follow Style.font.baseSize.
  property int textSizePreviewIndex: -1

  // A text-size change reflows the whole panel (both font and spacing scale),
  // which slides rows under a stationary pointer and fires synthetic hover.
  // While true, hover is not allowed to hijack the keyboard focus section —
  // otherwise h/l on the text-size slider can jump focus to another row.
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  readonly property var visibleSections: {
    var list = []
    if (root.viewMode === "advanced") {
      if (gammaAvailable) {
        list.push("gammabrightness")
        list.push("temperature")
        list.push("gamma")
        list.push("inverted")
      }
      return list
    }
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize")
    list.push("scale")
    if (displays.length > 1) list.push("monitors")
    return list
  }

  function sectionCount(section) {
    if (section === "brightness") return 0  // only the slider sentinel at -1
    if (section === "textsize") return 0    // slider sentinel at -1, like brightness
    if (section === "gammabrightness" || section === "temperature"
        || section === "gamma" || section === "inverted") return 0  // sentinel -1
    if (section === "scale") return scaleValues.length
    if (section === "monitors") return displays.length
    return 0
  }

  function sectionIsSingleRow(section) {
    // brightness, text size and the gammarelay controls are lone sliders/toggles;
    // scale presets sit horizontally.
    return section === "brightness" || section === "textsize" || section === "scale"
        || section === "gammabrightness" || section === "temperature"
        || section === "gamma" || section === "inverted"
  }

  function sectionHasReset(section) {
    return section === "gammabrightness" || section === "temperature" || section === "gamma"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "textsize") return -1
    if (section === "gammabrightness" || section === "temperature"
        || section === "gamma" || section === "inverted") return -1
    return 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections || sections.length === 0) return
    if (focusSection === "header") {
      if (delta > 0) {
        focusSection = sections[0]
        selectedIndex = sectionFirstIndex(focusSection)
      }
      return
    }
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (delta > 0) {
      // Gamma slider sections step slider (-1) → reset (0), then onward.
      if (sectionHasReset(focusSection) && selectedIndex === -1) { selectedIndex = 0; return }
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (sectionHasReset(focusSection) && selectedIndex === 0) { selectedIndex = -1; return }
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        // Coming up from below — land on the last navigable row of the prev
        // section, its sentinel for single-row sections, or on the reset
        // button when the section has one.
        selectedIndex = sectionHasReset(prev) ? 0
          : (sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1)
      } else {
        // At the top-most section — escape up onto the hero ADVANCED button.
        focusSection = "header"
      }
    }
  }

  // h/l: in scale section, walks the preset row; everywhere else, no-op
  // because adjustBrightness handles horizontal motion on the brightness
  // slider.
  function moveCursorH(delta) {
    if (focusSection !== "scale") return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > scaleValues.length - 1) next = scaleValues.length - 1
    selectedIndex = next
  }

  function adjustBrightness(delta) {
    if (focusSection !== "brightness") return
    if (!brightnessAvailable) return
    setBrightness(root.brightnessPercent + delta)
  }

  // h/l on a gammarelay section walks that control. Only active on the slider
  // (selectedIndex === -1); when the reset button is focused h/l is a no-op.
  function adjustGammarelay(delta) {
    if (selectedIndex !== -1) return
    if (focusSection === "gammabrightness") {
      var nb = Math.max(1, Math.min(100, root.gammaBrightnessPercent + delta * 5))
      root.gammaBrightnessPercent = nb
      commitGammaBrightness(nb)
    } else if (focusSection === "temperature") {
      var nt = Math.max(1000, Math.min(10000, root.temperatureValue + delta * 50))
      root.temperatureValue = nt
      commitTemperature(nt)
    } else if (focusSection === "gamma") {
      var ng = Math.max(0.1, Math.min(3.0, root.gammaValue + delta * 0.05))
      root.gammaValue = ng
      commitGamma(ng)
    }
  }

  function activateCursor() {
    if (focusSection === "header") { toggleViewMode(); return }
    // Gamma reset buttons (selectedIndex === 0) restore their default value.
    if (sectionHasReset(focusSection) && selectedIndex === 0) {
      if (focusSection === "gammabrightness") resetGammaBrightness()
      else if (focusSection === "temperature") resetTemperature()
      else resetGamma()
      return
    }
    if (focusSection === "scale" && selectedIndex >= 0 && selectedIndex < scaleValues.length) {
      setScale(scaleValues[selectedIndex])
      return
    }
    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {
      var d = displays[selectedIndex]
      if (d) toggleDisplay(d.name, d.enabled)
    }
    if (focusSection === "inverted") toggleInverted()
    // brightness / other gammarelay sliders: no separate action; the value is the action.
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (focusSection === "header") return  // hero toggle stays hoverable
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var count = sectionCount(focusSection)
    if (sectionHasReset(focusSection)) {
      // Valid gamma states: -1 (slider) or 0 (reset). Anything else snaps to the slider.
      if (selectedIndex !== -1 && selectedIndex !== 0) selectedIndex = -1
      return
    }
    if (sectionIsSingleRow(focusSection)) {
      // brightness / text size / gammarelay rows use the -1 sentinel; scale
      // clamps into the presets.
      if (focusSection === "scale") {
        if (selectedIndex < 0 || selectedIndex >= count) selectedIndex = 0
      } else {
        selectedIndex = -1
      }
      return
    }
    if (count === 0) {
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // Keep the keyboard-focused row inside the viewport when the panel grows
  // taller than its allotted height (lots of displays). Mirrors audio's
  // ensureCursorVisible helper.
  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    var value = Number(percent)
    root.setBrightness(value)
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      focusedMonitor: root.focusedMonitor,
      scale: root.monitorScale,
      displays: root.displays
    })
  }

  IpcHandler {
    target: "omarchy.monitor"

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
    if (!gammaStateProc.running) gammaStateProc.running = true
  }

  function setBrightness(value) {
    var percent = Model.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, percent + "%"]
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Model.clampBrightness(value)
    brightnessDebounce.restart()
  }

  // ---- wl-gammarelay-rs write helpers (global root path `/`) ----
  function queueGammaCommand(args) {
    root.gammaQueuedCommand = args
    if (!gammaActionProc.running) {
      gammaActionProc.command = args
      gammaActionProc.running = true
    }
  }

  function commitGammaBrightness(percent) {
    var frac = Math.max(0, Math.min(1, percent / 100))
    queueGammaCommand(["busctl", "--user", "set-property", "rs.wl-gammarelay", "/", "rs.wl.gammarelay", "Brightness", "d", String(frac)])
  }

  function commitTemperature(kelvin) {
    var k = Math.max(1000, Math.min(10000, Math.round(kelvin)))
    queueGammaCommand(["busctl", "--user", "set-property", "rs.wl-gammarelay", "/", "rs.wl.gammarelay", "Temperature", "q", String(k)])
  }

  function commitGamma(value) {
    var g = Math.max(0.1, Math.min(3.0, Number(value)))
    queueGammaCommand(["busctl", "--user", "set-property", "rs.wl-gammarelay", "/", "rs.wl.gammarelay", "Gamma", "d", g.toFixed(2)])
  }

  function toggleInverted() {
    root.invertedValue = !root.invertedValue
    queueGammaCommand(["busctl", "--user", "set-property", "rs.wl-gammarelay", "/", "rs.wl.gammarelay", "Inverted", "b", root.invertedValue ? "true" : "false"])
  }

  // Inline "reset to default" actions for the gammarelay section. Defaults
  // mirror wl-gammarelay-rs's Color::default(): 100% brightness, 6500K,
  // gamma 1.0, no inversion.
  function resetGammaBrightness() {
    root.gammaBrightnessPercent = 100
    commitGammaBrightness(100)
  }

  function resetTemperature() {
    root.temperatureValue = 6500
    commitTemperature(6500)
  }

  function resetGamma() {
    root.gammaValue = 1.0
    commitGamma(1.0)
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  function normalizeScale(scale) {
    return Model.normalizeScale(scale)
  }

  function activeScaleIndex() {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.matchingScaleIndex(scaleValues, monitorScale, display.width, display.height)
    }
    return -1
  }

  function effectiveScale(scale) {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.cleanScale(scale, display.width, display.height)
    }
    return normalizeScale(scale)
  }

  // Playful mood-name for a given brightness percent. Bands intentionally
  // span ~10–20 points so casual tweaks change the label, while small
  // nudges within one band don't.
  function brightnessName(percent) {
    return Model.brightnessName(percent)
  }

  function updateDisplays(displaysJson) {
    var parsed = Model.parseDisplays(displaysJson)
    root.displays = parsed.displays
    root.enabledDisplayCount = parsed.enabledDisplayCount
  }

  function toggleDisplay(name, enabled) {
    if (!name) return
    if (enabled && root.enabledDisplayCount <= 1) return

    actionProc.command = ["hyprctl", "keyword", "monitor", name + (enabled ? ",disable" : ",preferred,auto,auto")]
    if (!actionProc.running) actionProc.running = true
  }

  function setScale(scale) {
    actionProc.command = ["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale]
    if (!actionProc.running) actionProc.running = true
  }

  // ---- Text size (shell base font + GTK text-scaling, via one CLI) ----
  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise whatever Style's live base-size rounds to.
  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  // px shown in the header: the pending stop if any, else the true base-size
  // (which may be an off-notch value set from the CLI).
  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = currentTextIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > textSizeStops.length - 1) idx = textSizeStops.length - 1
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  // KeyboardPanel primes focus at open-time, so SUPER-bound IPC summons land
  // with j/k ready to navigate. Keep a default landing point, but don't paint
  // the cursor until hover or the first navigation key.
  onOpenedChanged: {
    if (opened) {
      refresh()
      if (viewMode !== "main") viewMode = "main"
      if (brightnessAvailable) {
        focusSection = "brightness"
        selectedIndex = -1
      } else {
        focusSection = "scale"
        selectedIndex = 0
      }
      cursorActive = false
    }
  }

  onBrightnessAvailableChanged: clampCursor()
  onDisplaysChanged: clampCursor()
  onScaleValuesChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()
  onViewModeChanged: if (opened) clampCursor()

  // Only poll while the panel is open; the bar glyph tracks monitor count via
  // Quickshell.screens, and open-time refresh + Component.onCompleted cover the
  // rest. External brightness changes are reflected whenever the panel is open.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        root.brightnessAvailable = brightness !== "unavailable" && brightness !== ""
        root.brightnessPercent = root.brightnessAvailable ? Math.max(0, Math.min(100, parseInt(brightness, 10))) : 0
        root.internalMonitor = String(lines[1] || "").trim()
        root.externalMonitor = String(lines[2] || "").trim()
        root.internalEnabled = String(lines[3] || "").trim() !== ""
        root.mirrorEnabled = String(lines[4] || "").trim() === root.externalMonitor && root.externalMonitor !== ""
        root.focusedMonitor = String(lines[5] || "").trim()
        root.monitorScale = root.normalizeScale(String(lines[6] || "").trim())
        root.updateDisplays(String(lines[7] || "[]").trim())
      }
    }
  }

  // Reads wl-gammarelay-rs global state (4 props, one per line) from the root
  // object. If the service is down, busctl emits an error and no valid number
  // lands on the first line — treat that as unavailable and hide the section.
  Process {
    id: gammaStateProc
    command: ["bash", "-c",
      "busctl --user get-property rs.wl-gammarelay / rs.wl.gammarelay Brightness | awk '{print $2}'; "
      + "busctl --user get-property rs.wl-gammarelay / rs.wl.gammarelay Temperature | awk '{print $2}'; "
      + "busctl --user get-property rs.wl-gammarelay / rs.wl.gammarelay Gamma | awk '{print $2}'; "
      + "busctl --user get-property rs.wl-gammarelay / rs.wl.gammarelay Inverted | awk '{print $2}'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = parseFloat(String(lines[0] || "").trim())
        if (!isFinite(brightness)) {
          root.gammaAvailable = false
          return
        }
        root.gammaAvailable = true
        root.gammaBrightnessPercent = Model.clampGammaBrightness(brightness)
        root.temperatureValue       = Model.parseTemperature(lines[1])
        root.gammaValue             = Model.parseGamma(lines[2])
        root.invertedValue = String(lines[3] || "").trim() === "true"
      }
    }
  }

  // Shares a single process for gammarelay writes; queued commands are
  // dispatched on completion so rapid slider commits aren't dropped.
  Process {
    id: gammaActionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root.gammaQueuedCommand.length > 0) {
        var pending = root.gammaQueuedCommand
        root.gammaQueuedCommand = []
        gammaActionProc.command = pending
        gammaActionProc.running = true
      }
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    // Do NOT call refresh() after a brightness set completes. The local
    // brightnessPercent we just wrote is authoritative; re-reading via
    // `omarchy-brightness-display` races the hardware/driver and can
    // return an empty string, which the parser then coerces to 0 —
    // visible as a "bounce to zero" after h/l keypresses. External
    // brightness changes are still picked up by the 5s periodic refresh,
    // the open-time refresh, and Component.onCompleted.
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent)
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch, so there's
  // nothing to refresh here.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Clears the hover-suppression flag once the reflow triggered by a text-size
  // change has settled.
  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  // Once Style's base-size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again. The change itself reflows the
  // panel, so suppress hover for a beat while it lands.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightnessPercent + wheel.steps * 5)
      root.showBrightnessOsd(root.brightnessPercent)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "textsize") root.adjustTextSize(dx)
          else if (root.focusSection === "scale") root.moveCursorH(dx)
          else root.adjustGammarelay(dx)
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: display icon · title/status · view toggle ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, Math.max(heroLabels.implicitHeight, viewToggle.implicitHeight))

            Text {
              id: heroIcon
              text: root.displays.length > 1 ? "󰍺" : "󰍹"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: viewToggle.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Display"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                text: {
                  if (root.viewMode === "advanced")
                    return "COLOR CONTROLS"
                  if (root.brightnessAvailable) {
                    return root.brightnessName(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent).toUpperCase()
                  }
                  return "FIXED BRIGHTNESS"
                }
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }

            Button {
              id: viewToggle
              text: root.viewMode === "advanced" ? "BACK" : "ADVANCED"
              tooltipText: root.viewMode === "advanced" ? "Back to display controls" : "Advanced color controls"
              bordered: true
              hasCursor: root.headerHasCursor
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.sm
              verticalPadding: Style.spacing.controlPaddingY
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onHovered: function(on) { if (on && root.opened) root.setHeaderCursor() }
              onClicked: root.toggleViewMode()
            }
          }

          // ---------- Brightness ----------
          PanelSeparator {
            visible: root.brightnessAvailable && root.viewMode === "main"
            foreground: root.bar.foreground
          }

          Column {
            visible: root.brightnessAvailable && root.viewMode === "main"
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercent.implicitHeight)

              PanelSectionHeader {
                id: brightnessHeader
                text: "BRIGHTNESS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: brightnessPercent
                text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: brightnessRow
              width: parent.width
              height: brightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: brightnessSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 1
                maximum: 100
                step: 1
                value: root.brightnessPercent
                integer: true
                onMoved: function(v) { root.previewBrightness(v) }
                onReleased: function(v) {
                  brightnessDebounce.stop()
                  root.setBrightness(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "brightness"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- wl-gammarelay-rs (brightness · temperature · gamma · invert) ----------
          // ---- Gammarelay brightness ----
          PanelSeparator {
            visible: root.gammaAvailable && root.viewMode === "advanced"
            foreground: root.bar.foreground
          }

          Column {
            visible: root.gammaAvailable && root.viewMode === "advanced"
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(gammaBrightnessHeader.implicitHeight, gammaBrightnessPct.implicitHeight)

              PanelSectionHeader {
                id: gammaBrightnessHeader
                text: "BRIGHTNESS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: gammaBrightnessPct
                text: Math.round(gammaBrightnessSlider.dragging ? gammaBrightnessSlider.liveValue : root.gammaBrightnessPercent) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: gammaBrightnessReset.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }

              PanelActionButton {
                id: gammaBrightnessReset
                iconText: root.resetGlyph
                tooltipText: "Reset brightness to 100%"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                hasCursor: root.cursorActive && root.focusSection === "gammabrightness" && root.selectedIndex === 0
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(gammaBrightnessReset)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                onHovered: function(on) { if (on && root.opened) { root.cursorActive = true; root.focusSection = "gammabrightness"; root.selectedIndex = 0 } }
                onClicked: root.resetGammaBrightness()
              }
            }

            CursorSurface {
              id: gammaBrightnessRow
              width: parent.width
              height: gammaBrightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "gammabrightness" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(gammaBrightnessRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: gammaBrightnessSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 1
                maximum: 100
                step: 1
                integer: true
                value: root.gammaBrightnessPercent
                onMoved: function(v) { root.gammaBrightnessPercent = Math.round(v) }
                onReleased: function(v) {
                  root.gammaBrightnessPercent = Math.round(v)
                  root.commitGammaBrightness(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "gammabrightness"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---- Temperature ----
          PanelSeparator {
            visible: root.gammaAvailable && root.viewMode === "advanced"
            foreground: root.bar.foreground
          }

          Column {
            visible: root.gammaAvailable && root.viewMode === "advanced"
            width: parent.width
            spacing: Style.space(6)
            
            Item {
              width: parent.width
              implicitHeight: Math.max(tempHeader.implicitHeight, tempValue.implicitHeight)

              PanelSectionHeader {
                id: tempHeader
                text: "TEMPERATURE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: tempValue
                text: (tempSlider.dragging ? Math.round(tempSlider.liveValue) : root.temperatureValue) + "K"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: tempReset.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }

              PanelActionButton {
                id: tempReset
                iconText: root.resetGlyph
                tooltipText: "Reset temperature to 6500K"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                hasCursor: root.cursorActive && root.focusSection === "temperature" && root.selectedIndex === 0
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(tempReset)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                onHovered: function(on) { if (on && root.opened) { root.cursorActive = true; root.focusSection = "temperature"; root.selectedIndex = 0 } }
                onClicked: root.resetTemperature()
              }
            }

            CursorSurface {
              id: tempRow
              width: parent.width
              height: tempSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "temperature" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(tempRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: tempSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 1000
                maximum: 10000
                step: 50
                integer: true
                value: root.temperatureValue
                onMoved: function(v) { root.temperatureValue = Math.round(v) }
                onReleased: function(v) {
                  root.temperatureValue = Math.round(v)
                  root.commitTemperature(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "temperature"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---- Gamma ----
          PanelSeparator {
            visible: root.gammaAvailable && root.viewMode === "advanced"
            foreground: root.bar.foreground
          }

          Column {
            visible: root.gammaAvailable && root.viewMode === "advanced"
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(gammaHeader.implicitHeight, gammaValueText.implicitHeight)

              PanelSectionHeader {
                id: gammaHeader
                text: "GAMMA"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: gammaValueText
                text: (gammaSlider.dragging ? gammaSlider.liveValue : root.gammaValue).toFixed(2)
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: gammaReset.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }

              PanelActionButton {
                id: gammaReset
                iconText: root.resetGlyph
                tooltipText: "Reset gamma to 1.00"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                hasCursor: root.cursorActive && root.focusSection === "gamma" && root.selectedIndex === 0
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(gammaReset)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                onHovered: function(on) { if (on && root.opened) { root.cursorActive = true; root.focusSection = "gamma"; root.selectedIndex = 0 } }
                onClicked: root.resetGamma()
              }
            }

            CursorSurface {
              id: gammaRow
              width: parent.width
              height: gammaSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "gamma" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(gammaRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: gammaSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0.1
                maximum: 3.0
                step: 0.01
                value: root.gammaValue
                onMoved: function(v) { root.gammaValue = v }
                onReleased: function(v) {
                  root.gammaValue = v
                  root.commitGamma(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "gamma"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---- Invert ----
          PanelSeparator {
            visible: root.gammaAvailable && root.viewMode === "advanced"
            foreground: root.bar.foreground
          }

          Column {
            visible: root.gammaAvailable && root.viewMode === "advanced"
            width: parent.width
            spacing: Style.space(6)

            CursorSurface {
              id: invertRow
              width: parent.width
              implicitHeight: invertRowInner.implicitHeight + Style.space(8)
              hasCursor: root.cursorActive && root.focusSection === "inverted" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(invertRow)
              foreground: root.bar.foreground
              outline: true

              Row {
                id: invertRowInner
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(8)

                Text {
                  id: invertLabel
                  text: "INVERT COLORS"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - invertSwitch.implicitWidth - parent.spacing
                }

                ToggleSwitch {
                  id: invertSwitch
                  checked: root.invertedValue
                  interactive: false
                  cursorRing: false
                  foreground: root.bar.foreground
                  accent: Color.accent
                  anchors.verticalCenter: parent.verticalCenter
                  onToggled: root.toggleInverted()
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "inverted"
                  root.selectedIndex = -1
                }
                onClicked: root.toggleInverted()
              }
            }
          }

          // ---------- Text size ----------
          PanelSeparator {
            visible: root.viewMode === "main"
            foreground: root.bar.foreground
          }

          Column {
            visible: root.viewMode === "main"
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

              PanelSectionHeader {
                id: textSizeHeader
                text: "TEXT SIZE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: textSizePx
                text: (textSizeSlider.dragging
                       ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                       : root.displayedTextPx()) + "px"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: textSizeRow
              width: parent.width
              height: textSizeSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: textSizeSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: root.textSizeStops.length - 1
                step: 1
                integer: true
                tickCount: root.textSizeStops.length
                value: root.currentTextIndex()
                onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "textsize"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Scale ----------
          PanelSeparator {
            visible: root.viewMode === "main"
            foreground: root.bar.foreground
          }

          Column {
            visible: root.viewMode === "main"
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(scaleHeader.implicitHeight, scaleMonitor.implicitHeight)

              PanelSectionHeader {
                id: scaleHeader
                text: "SCALE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // Name the monitor SCALE targets, since it only applies to the
              // focused one.
              Text {
                id: scaleMonitor
                text: root.focusedMonitor
                // Only worth naming when more than one display is in play.
                visible: root.focusedMonitor !== "" && root.enabledDisplayCount > 1
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Grid {
              id: scaleRow
              width: parent.width
              columns: root.scaleValues.length
              spacing: Style.spacing.xs

              readonly property real cellWidth: root.scaleValues.length > 0
                ? (width - spacing * (columns - 1)) / columns
                : 0

              Repeater {
                model: root.scaleValues

                ScalePill {
                  required property string modelData
                  required property int index

                  scaleValue: modelData
                  scaleIndex: index
                  width: scaleRow.cellWidth
                }
              }
            }
          }

          // ---------- Monitors ----------
          PanelSeparator {
            visible: root.displays.length > 1 && root.viewMode === "main"
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.displays.length > 1 && root.viewMode === "main"

            PanelSectionHeader {
              text: "DISPLAYS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.displays

              MonitorRow {
                required property var modelData
                required property int index

                width: panelColumn.width
                display: modelData
                rowIndex: index
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  component ScalePill: Button {
    id: pill
    required property string scaleValue
    required property int scaleIndex

    text: root.effectiveScale(scaleValue) + "x"
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: root.activeScaleIndex() === scaleIndex
    hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === scaleIndex

    onClicked: root.setScale(scaleValue)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "scale"
      root.selectedIndex = pill.scaleIndex
    }
  }

  component MonitorRow: CursorSurface {
    id: monitorRow
    required property var display
    required property int rowIndex

    readonly property bool isFocused: display && display.focused
    readonly property bool canToggle: display && (!display.enabled || root.enabledDisplayCount > 1)

    hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(monitorRow)
    current: isFocused
    foreground: root.bar.foreground
    fill: Style.hoverFillFor(root.bar.foreground, Color.accent)
    currentFill: Style.selectedFillFor(root.bar.foreground, Color.accent)
    implicitHeight: monitorInner.implicitHeight + Style.spacing.xl
    opacity: canToggle ? 1.0 : 0.45

    Row {
      id: monitorInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: "󰍹"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: monitorRow.display.name + (monitorRow.display.focused ? " · focused" : "")
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: monitorRow.display.enabled ? "󰄬" : ""
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        width: Style.space(14)
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: monitorRow.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
        root.cursorActive = true
        root.focusSection = "monitors"
        root.selectedIndex = monitorRow.rowIndex
      }
      onClicked: if (monitorRow.canToggle) root.toggleDisplay(monitorRow.display.name, monitorRow.display.enabled)
    }
  }
}

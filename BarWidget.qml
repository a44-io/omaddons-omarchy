import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The omaddons setup button (https://github.com/a44-io/omaddons-omarchy).
//
// The omaddons bar widget is rendered for each machine by the omaddons program, so the
// plugin site carries this button instead. It holds the widget's plugin id,
// a44.omaddons, until `omaddons omarchy install` replaces this folder with the real
// widget and rescans Omarchy's plugins: the widget then takes this button's place on the
// bar. One click does the whole setup:
//
//   1. Find omaddons (~/.local/bin, then PATH) and ask it where it installs the widget
//      (`omaddons omarchy status --json`). A build that names plugins/a44.omaddons
//      replaces this folder; an older one would install beside it.
//   2. When omaddons is missing or older, install it the Omarchy way, as the HEY plugin
//      installs its CLI: `omarchy-mise-install github:a44-io/omaddons omaddons`, then run
//      it once so mise downloads the release.
//   3. Run `omaddons omarchy install` in a session of its own (`setsid -w`): the install
//      outlives this button when the rescan unloads it, and a failure still comes back
//      here with its message.
//
// Every command is an argument list. The one shell script, the probe, is a constant that
// takes no input.
Panel {
  id: root
  moduleName: "a44.omaddons"
  ipcTarget: "a44.omaddons"

  // checking, missing, outdated, ready, installing-cli, downloading, installing, done,
  // failed
  property string phase: "checking"
  // The omaddons the probe found (absolute) and its version.
  property string binary: ""
  property string version: ""
  // ~/.local/bin/omaddons exists now, and existed before this attempt's mise install.
  property bool wrapperExists: false
  property bool wrapperBefore: false
  // What went wrong, for `failed`: one sentence, and the tool's own last words.
  property string failure: ""
  property string failureOutput: ""
  // A click asked for the whole setup: go on to the widget once omaddons is usable.
  property bool continueToWidget: false
  // This attempt already installed omaddons through mise: never loop on it.
  property bool cliTried: false
  // `done` for a while and still here: the shell did not take the widget in.
  property bool doneStale: false
  property real spinAngle: 0

  readonly property string readmeUrl: "https://github.com/a44-io/omaddons-omarchy#readme"
  readonly property string wrapper: Quickshell.env("HOME") + "/.local/bin/omaddons"
  readonly property var miseArgv: ["omarchy-mise-install", "github:a44-io/omaddons", "omaddons"]
  readonly property bool busy: ["checking", "installing-cli", "downloading", "installing"].indexOf(phase) !== -1
  // U+F0297 nf-md-gamepad_variant (the widget's own glyph) and U+F04E6 nf-md-sync.
  readonly property string glyph: String.fromCodePoint(0xF0297)
  readonly property string syncGlyph: String.fromCodePoint(0xF04E6)
  readonly property color foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color muted: Commons.Color.muted
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // Line 1: `wrapper` when ~/.local/bin/omaddons exists, else `nowrapper`. Line 2:
  // `binary<TAB><path>` for the first candidate (~/.local/bin, then PATH) whose
  // `omarchy status --json` works, followed by that JSON; `broken<TAB><path>` and the
  // last failing answer when every candidate failed (their stderr goes to stderr); or
  // `missing`. A wrapper that cannot download never hides a working omaddons on PATH.
  readonly property string probeScript:
      'w="$HOME/.local/bin/omaddons"; '
    + 'if [ -e "$w" ]; then echo wrapper; else echo nowrapper; fi; '
    + 'found=""; prev=""; last=""; '
    + 'for p in "$w" "$(command -v omaddons 2>/dev/null)"; do '
    + '[ -n "$p" ] && [ -x "$p" ] && [ "$p" != "$prev" ] || continue; '
    + 'prev=$p; found=${found:-$p}; '
    + 'if out=$("$p" omarchy status --json); then printf "binary\\t%s\\n%s\\n" "$p" "$out"; exit 0; fi; '
    + 'last=$out; '
    + 'done; '
    + 'if [ -n "$found" ]; then printf "broken\\t%s\\n%s\\n" "$found" "$last"; else echo missing; fi'

  // ------------------------------------------------------------------ the steps

  function probe() {
    root.phase = root.cliTried ? "downloading" : "checking"
    root.failure = ""
    root.failureOutput = ""
    // Through the mise wrapper, the first run downloads the release, and offline mise
    // can wait on its version check for over a minute.
    probeStep.begin(["sh", "-c", root.probeScript], 300)
  }

  function probed(code, out, err) {
    var lines = String(out || "").split("\n")
    root.wrapperExists = lines[0].trim() === "wrapper"
    var head = (lines[1] || "").trim()
    var json = lines.slice(2).join("\n").trim()
    var env = null
    try { env = json !== "" ? JSON.parse(json) : null } catch (e) { env = null }
    if (head === "missing") {
      root.binary = ""
      root.version = ""
      root.phase = "missing"
    } else {
      var found = /^(binary|broken)\t(.+)$/.exec(head)
      if (!found) return fail("omaddons could not be checked.", err || out)
      root.binary = found[2]
      root.version = env && env.tool_version ? String(env.tool_version) : ""
      if (found[1] === "broken") {
        var message = env && env.error && env.error.message ? String(env.error.message) : ""
        if (root.cliTried) return failAfterCli("mise could not download omaddons.", err || message)
        return fail("The omaddons at " + root.binary + " did not work.", message || err)
      }
      var path = env && env.data && env.data.plugin ? String(env.data.plugin.path || "") : ""
      root.phase = /\/plugins\/a44\.omaddons$/.test(path) ? "ready" : "outdated"
    }
    if (root.continueToWidget) next(err)
  }

  // The click: the whole setup, from wherever it stands.
  function setUp() {
    if (root.busy) return
    root.continueToWidget = true
    root.cliTried = false
    root.doneStale = false
    if (root.phase === "failed" || root.phase === "done") probe()
    else next()
  }

  // `err`: the probe's stderr, where a failing mise wrapper says why.
  function next(err) {
    if (root.phase === "ready") return installWidget()
    if (root.phase !== "missing" && root.phase !== "outdated") return
    if (!root.cliTried) return installCli()
    // After the mise install: the wrapper answered but is still too old, or it did not
    // work and the probe fell back to an older omaddons on PATH, or found nothing.
    if (root.binary === root.wrapper)
      return failAfterCli("The newest omaddons release still installs the widget elsewhere, so it cannot replace this button yet.", "")
    return failAfterCli("mise could not download omaddons.", err)
  }

  function installCli() {
    root.cliTried = true
    root.wrapperBefore = root.wrapperExists
    root.phase = "installing-cli"
    cliStep.begin(root.miseArgv, 60)
  }

  // A failure after this attempt's mise install. A wrapper the install just created
  // that does not work would shadow a working omaddons in the terminal: it goes.
  function failAfterCli(sentence, output) {
    if (!root.wrapperBefore && root.wrapperExists) {
      Quickshell.execDetached(["rm", "-f", "--", root.wrapper])
      root.wrapperExists = false
      sentence += " The ~/.local/bin/omaddons wrapper it had just created was removed."
    }
    return fail(sentence, output)
  }

  function cliDone(code, out, err) {
    if (code !== 0) return fail("Omarchy's mise installer could not install omaddons.", err || out)
    probe()
  }

  function installWidget() {
    root.phase = "installing"
    widgetStep.begin(["setsid", "-w", root.binary, "--actor", "widget", "--reason", "setup plugin",
      "omarchy", "install"], 180)
  }

  function widgetDone(code, out, err) {
    if (code !== 0) return fail("omaddons could not install its widget.", err || out)
    // The rescan omaddons ran replaces this button in a moment; if it is still here
    // after a while, the shell did not take the widget in.
    root.phase = "done"
    root.continueToWidget = false
    staleTimer.restart()
  }

  function fail(sentence, output) {
    root.phase = "failed"
    root.continueToWidget = false
    root.failure = sentence
    var lines = String(output || "").trim().split("\n").filter(function(l) { return l.trim() !== "" })
    root.failureOutput = lines.slice(-6).join("\n")
  }

  // The commands that do this by hand, for Copy.
  function manualCommand() {
    var install = (root.binary !== "" ? root.binary : "omaddons") + " omarchy install"
    return root.binary !== "" && root.phase !== "outdated" ? install
      : root.miseArgv.join(" ") + " && ~/.local/bin/omaddons omarchy install"
  }

  function copyCommand() {
    Quickshell.execDetached(["wl-copy", "--", manualCommand()])
  }

  function rescan() {
    Quickshell.execDetached(["omarchy-shell", "shell", "rescanPlugins"])
  }

  // ------------------------------------------------------------------ the words

  function statusText() {
    var v = root.version !== "" ? " " + root.version : ""
    switch (root.phase) {
    case "checking": return "Looking for omaddons…"
    case "missing": return "omaddons isn't installed yet. The button below installs it with Omarchy's mise installer, from its GitHub releases, then puts the omaddons widget in this button's place."
    case "outdated": return "The omaddons" + v + " at " + root.binary + " is too old to install this widget. The button below installs the newest release with mise, then puts the widget in this button's place."
    case "ready": return "omaddons" + v + " is installed. Install the widget to put it in this button's place on the bar."
    case "installing-cli": return "Installing omaddons with mise…"
    case "downloading": return "Downloading omaddons…"
    case "installing": return "Installing the omaddons widget…"
    case "done": return root.doneStale
      ? "The widget is installed, but Omarchy's shell has not picked it up yet. Reload the plugins to finish."
      : "Done. The omaddons widget is taking this button's place."
    case "failed": return root.failure
    }
    return ""
  }

  function primaryText() {
    switch (root.phase) {
    case "missing": return "Install omaddons and the widget"
    case "outdated": return "Update omaddons and install the widget"
    case "ready": return "Install the widget"
    case "failed": return "Try again"
    case "done": return root.doneStale ? "Reload plugins" : "Installing…"
    }
    return "Working…"
  }

  function primary() {
    if (root.phase === "done" && root.doneStale) return rescan()
    setUp()
  }

  function tooltip() {
    if (root.phase === "failed") return "omaddons setup failed: click for details"
    if (root.busy) return "omaddons: " + statusText()
    if (root.phase === "done") return "omaddons: the widget is on its way"
    return "omaddons: click to set up the bar widget"
  }

  // ------------------------------------------------------------------ the processes

  // One command: its exit code and both streams, reported once all three are in (exit
  // and stream ends come in no fixed order), or a timeout.
  component Step: Process {
    id: step
    property int code: -1
    property bool exitSeen: false
    property bool outSeen: false
    property bool errSeen: false
    property string outText: ""
    property string errText: ""
    property bool settled: true
    // The command as a plain array, for the timeout's message.
    property var argv: []
    signal finished(int code, string out, string err)

    function begin(args, seconds) {
      argv = args
      code = -1
      exitSeen = false
      outSeen = false
      errSeen = false
      outText = ""
      errText = ""
      settled = false
      command = args
      watchdog.interval = seconds * 1000
      watchdog.restart()
      running = true
    }

    function settle() {
      if (settled || !(exitSeen && outSeen && errSeen)) return
      settled = true
      watchdog.stop()
      finished(code, outText, errText)
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { step.outText = String(text || ""); step.outSeen = true; step.settle() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { step.errText = String(text || ""); step.errSeen = true; step.settle() }
    }
    onExited: function(exitCode) { step.code = exitCode; step.exitSeen = true; step.settle() }
    // Quickshell reports no exit at all for a program that is not there: the process
    // just stops running. That is a failure to start, said at once.
    onRunningChanged: {
      if (running || step.settled || step.exitSeen) return
      step.settled = true
      watchdog.stop()
      step.finished(-1, "", "Could not start " + String(step.argv[0] || "the command") + ": is it installed?")
    }

    property Timer watchdog: Timer {
      repeat: false
      onTriggered: {
        if (step.settled) return
        step.settled = true
        step.running = false
        step.finished(-1, step.outText, "Stopped after " + Math.round(interval / 1000) + " s without an answer: " + step.argv.join(" "))
      }
    }
  }

  Step { id: probeStep; onFinished: function(code, out, err) { root.probed(code, out, err) } }
  Step { id: cliStep; onFinished: function(code, out, err) { root.cliDone(code, out, err) } }
  Step { id: widgetStep; onFinished: function(code, out, err) { root.widgetDone(code, out, err) } }

  Timer {
    id: staleTimer
    interval: 15000
    repeat: false
    onTriggered: if (root.phase === "done") root.doneStale = true
  }

  // For scripts and agents: `omarchy-shell a44.omaddons.setup state|setUp|check`.
  IpcHandler {
    target: "a44.omaddons.setup"

    function state(): string {
      return JSON.stringify({ "phase": root.phase, "binary": root.binary, "version": root.version,
        "failure": root.failure, "output": root.failureOutput, "stale": root.doneStale })
    }
    function setUp(): string { root.setUp(); return root.phase }
    function check(): string { root.continueToWidget = false; root.probe(); return root.phase }
  }

  Component.onCompleted: probe()
  // Opened again after omaddons was installed in a terminal: look again.
  onOpenedChanged: if (opened && !busy && !continueToWidget && phase !== "done") probe()

  // ------------------------------------------------------------------ the bar button

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.busy ? root.syncGlyph : root.glyph
    textRotation: root.busy && Style.reduceMotion !== true ? root.spinAngle : 0
    active: root.phase === "failed"
    dimmed: root.phase === "checking"
    tooltipText: root.tooltip()
    Accessible.role: Accessible.Button
    Accessible.name: "omaddons setup"
    Accessible.description: root.statusText()
    onPressed: function(which) { root.toggle() }
  }

  NumberAnimation on spinAngle {
    running: root.busy && Style.reduceMotion !== true
    from: 0
    to: 360
    duration: 1200
    loops: Animation.Infinite
  }

  // ------------------------------------------------------------------ the panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(Math.ceil(body.implicitHeight), Style.space(520))

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Keys.onReturnPressed: root.primary()
      Keys.onEnterPressed: root.primary()
      Keys.onEscapePressed: root.close()

      ColumnLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.spacing.lg

        Text {
          Layout.fillWidth: true
          text: "omaddons setup"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          textFormat: Text.PlainText
        }

        Text {
          Layout.fillWidth: true
          text: root.statusText()
          color: root.phase === "failed" ? Commons.Color.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
        }

        Text {
          Layout.fillWidth: true
          visible: root.phase === "failed" && root.failureOutput !== ""
          text: root.failureOutput
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WrapAnywhere
          textFormat: Text.PlainText
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.controlGap

          Button {
            id: primaryButton
            text: root.primaryText()
            iconText: root.busy || (root.phase === "done" && !root.doneStale) ? root.syncGlyph : ""
            iconSpinning: root.busy || (root.phase === "done" && !root.doneStale)
            bordered: true
            active: !root.busy && root.phase !== "done" || root.doneStale
            enabled: !root.busy && (root.phase !== "done" || root.doneStale)
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.primary()
          }

          Button {
            text: "Check again"
            visible: !root.busy && root.phase !== "done"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: { root.continueToWidget = false; root.probe() }
          }

          Button {
            text: "Copy command"
            tooltipText: root.manualCommand()
            visible: root.phase === "failed"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.copyCommand()
          }

          Item { Layout.fillWidth: true }
        }

        Text {
          Layout.fillWidth: true
          text: "Runs " + (root.binary !== "" && root.phase === "ready" ? "" : "omarchy-mise-install, then ")
            + "omaddons omarchy install, which records the change in omaddons' history. Enter presses the first button, Esc closes."
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
        }

        Button {
          text: "How this works"
          foreground: root.muted
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: Qt.openUrlExternally(root.readmeUrl)
        }
      }
    }
  }
}

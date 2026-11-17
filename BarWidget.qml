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
// bar.
//
// It runs exactly one omaddons: the release pinned below, and only after the installed
// binary's SHA-256 matches the one pinned with it. A later or replaced upstream release
// is never run by this button. One click does the whole setup:
//
//   1. Ask mise where the pinned release is installed (`mise where`, local and offline)
//      and hash its binary. A match is ready; a mismatch is refused, and nothing runs.
//   2. When it is not installed, install exactly that release with mise:
//      `mise use -g github:a44-io/omaddons@<version>`, or `mise install …` when another
//      omaddons is already on PATH, so the user's own mise configuration is left as it is.
//      Then check the downloaded binary as in step 1.
//   3. Run the verified binary's `omarchy install` in a session of its own (`setsid -w`):
//      the install outlives this button when the rescan unloads it, and a failure still
//      comes back here with its message.
//
// Every command is an argument list. The one shell script, the probe, is a constant; the
// pinned tool is passed to it as an argument, never written into it.
Panel {
  id: root
  moduleName: "a44.omaddons"
  ipcTarget: "a44.omaddons"

  // The one omaddons this button installs and runs: its release, and the SHA-256 of the
  // `omaddons` binary in that release's tarball. A new omaddons release changes both
  // here, in a commit the plugin marketplace reviews before it is published.
  readonly property string pinnedVersion: "0.2.1"
  readonly property string pinnedSha256: "0b0353001971176dc2ef6e545193962c11bed65c9ecd4e30ddcc38ce5c18091b"
  readonly property string toolSpec: "github:a44-io/omaddons@" + pinnedVersion

  // checking, verifying, missing, ready, installing-cli, installing, done, failed
  property string phase: "checking"
  // The verified binary of the pinned release (absolute), once the probe has hashed it.
  property string binary: ""
  // An omaddons the probe found on PATH: never run, only named in the panel.
  property string other: ""
  // What went wrong, for `failed`: one sentence, and the tool's own last words.
  property string failure: ""
  property string failureOutput: ""
  // A click asked for the whole setup: go on to the widget once omaddons is verified.
  property bool continueToWidget: false
  // This attempt already installed the pinned release with mise: never loop on it.
  property bool cliTried: false
  // `done` for a while and still here: the shell did not take the widget in.
  property bool doneStale: false
  property real spinAngle: 0

  readonly property string readmeUrl: "https://github.com/a44-io/omaddons-omarchy#readme"
  readonly property bool busy: ["checking", "verifying", "installing-cli", "installing"].indexOf(phase) !== -1
  // U+F0297 nf-md-gamepad_variant (the widget's own glyph) and U+F04E6 nf-md-sync.
  readonly property string glyph: String.fromCodePoint(0xF0297)
  readonly property string syncGlyph: String.fromCodePoint(0xF04E6)
  readonly property color foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color muted: Commons.Color.muted
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // `$1` is the pinned tool. Prints `nomise` without mise; else `pinned<TAB><binary>`
  // and that binary's `sha256sum` line when mise has the pinned release; else `missing`,
  // then `other<TAB><path>` when some other omaddons is on PATH. It runs no omaddons.
  readonly property string probeScript:
      'command -v mise >/dev/null 2>&1 || { echo nomise; exit 0; }; '
    + 'if dir=$(mise where "$1" 2>/dev/null) && [ -f "$dir/omaddons" ]; then '
    + 'printf "pinned\\t%s\\n" "$dir/omaddons"; sha256sum -- "$dir/omaddons"; exit 0; fi; '
    + 'echo missing; '
    + 'if other=$(command -v omaddons 2>/dev/null); then printf "other\\t%s\\n" "$other"; fi'

  // ------------------------------------------------------------------ the steps

  function probe() {
    root.phase = root.cliTried ? "verifying" : "checking"
    root.failure = ""
    root.failureOutput = ""
    probeStep.begin(["sh", "-c", root.probeScript, "sh", root.toolSpec], 60)
  }

  function probed(code, out, err) {
    var lines = String(out || "").split("\n")
    var head = lines[0].trim()
    root.binary = ""
    root.other = ""
    if (code !== 0) return fail("omaddons could not be checked.", err || out)
    if (head === "nomise")
      return fail("mise is not on PATH. Omarchy ships it, and this button installs omaddons with it.", "")
    if (head === "missing") {
      var found = /^other\t(.+)$/.exec((lines[1] || "").trim())
      root.other = found ? found[1] : ""
      root.phase = "missing"
      if (root.continueToWidget) next(err)
      return
    }
    var pinned = /^pinned\t(.+)$/.exec(head)
    if (!pinned) return fail("omaddons could not be checked.", err || out)
    var digest = String(lines[1] || "").trim().split(/\s+/)[0]
    if (digest !== root.pinnedSha256)
      return fail("The omaddons " + root.pinnedVersion + " that mise installed is not the release this plugin pins, so it was not run. "
        + "Remove it with `mise uninstall " + root.toolSpec + "`, then try again.",
        "binary: " + pinned[1] + "\nSHA-256: " + (digest || "none") + "\npinned:  " + root.pinnedSha256)
    root.binary = pinned[1]
    root.phase = "ready"
    if (root.continueToWidget) next(err)
  }

  // The click: the whole setup, from wherever it stands.
  function setUp() {
    if (root.busy) return
    root.continueToWidget = true
    root.cliTried = false
    root.doneStale = false
    if (root.phase === "failed" || root.phase === "done") probe()
    else next("")
  }

  function next(err) {
    if (root.phase === "ready") return installWidget()
    if (root.phase !== "missing") return
    if (!root.cliTried) return installCli()
    return fail("mise reported omaddons " + root.pinnedVersion + " installed, but it is not where mise keeps it.", err)
  }

  // The pinned release only. With another omaddons on PATH, `mise install` leaves the
  // user's mise configuration as it is; otherwise `mise use -g` also puts omaddons on
  // PATH, through the mise activation Omarchy sets up.
  function installArgv() {
    return root.other !== "" ? ["mise", "install", root.toolSpec] : ["mise", "use", "-g", root.toolSpec]
  }

  function installCli() {
    root.cliTried = true
    root.phase = "installing-cli"
    cliStep.begin(root.installArgv(), 300)
  }

  function cliDone(code, out, err) {
    if (code !== 0) return fail("mise could not install omaddons " + root.pinnedVersion + ".", err || out)
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
    return root.installArgv().join(" ") + " && \"$(mise where " + root.toolSpec + ")/omaddons\" omarchy install"
  }

  function copyCommand() {
    Quickshell.execDetached(["wl-copy", "--", manualCommand()])
  }

  function rescan() {
    Quickshell.execDetached(["omarchy-shell", "shell", "rescanPlugins"])
  }

  // ------------------------------------------------------------------ the words

  function statusText() {
    var v = root.pinnedVersion
    switch (root.phase) {
    case "checking": return "Looking for omaddons " + v + "…"
    case "verifying": return "Checking the downloaded omaddons " + v + " against its pinned SHA-256…"
    case "missing": return "omaddons " + v + " isn't installed yet. The button below installs exactly that release with mise, checks its SHA-256 against the one this plugin pins, then puts the omaddons widget in this button's place."
      + (root.other !== "" ? " The omaddons at " + root.other + " is left alone and never run; to use it instead, run `omaddons omarchy install`." : "")
    case "ready": return "omaddons " + v + " is installed and matches its pinned SHA-256. Install the widget to put it in this button's place on the bar."
    case "installing-cli": return "Installing omaddons " + v + " with mise…"
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
    case "missing": return "Install omaddons " + root.pinnedVersion + " and the widget"
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
      return JSON.stringify({ "phase": root.phase, "pinned": root.toolSpec, "sha256": root.pinnedSha256,
        "binary": root.binary, "other": root.other, "failure": root.failure, "output": root.failureOutput,
        "stale": root.doneStale })
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
          text: "Installs only omaddons " + root.pinnedVersion + " (SHA-256 " + root.pinnedSha256.slice(0, 12)
            + "…), then runs its omarchy install, which records the change in omaddons' history. Enter presses the first button, Esc closes."
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

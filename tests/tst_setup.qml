import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import ".."

TestCase {
  id: testCase
  name: "Setup"
  when: windowShown
  visible: true
  width: 500
  height: 100

  readonly property string spec: "github:a44-io/omaddons@0.2.1"
  readonly property string sha: "0b0353001971176dc2ef6e545193962c11bed65c9ecd4e30ddcc38ce5c18091b"
  readonly property string pinnedBinary: "/h/.local/share/mise/installs/github-a44-io-omaddons/0.2.1/omaddons"

  Component { id: widgetComponent; BarWidget {} }

  function make() {
    ProcessRegistry.reset()
    Quickshell.resetDetachedCommands()
    var w = createTemporaryObject(widgetComponent, testCase)
    verify(w !== null)
    return w
  }

  function launches() {
    return ProcessRegistry.launches.map(function(l) { return l.command })
  }

  // The button's own commands: the shell kit's lookups (hyprctl, fc-match) left out.
  function ownLaunches() {
    return launches().filter(function(a) { return ["sh", "mise", "setsid"].indexOf(a[0]) !== -1 })
  }

  function lastLaunch() {
    var all = ProcessRegistry.launches
    return all[all.length - 1]
  }

  // The newest launched process ends with these streams and code.
  function answer(out, err, code) {
    var p = lastLaunch().process
    p.stdout.text = out
    p.stdout.streamFinished()
    p.stderr.text = err || ""
    p.stderr.streamFinished()
    p.exit(code || 0)
  }

  // What the probe prints for the pinned release installed with the binary `digest`.
  function pinned(digest) {
    return "pinned\t" + pinnedBinary + "\n" + digest + "  " + pinnedBinary + "\n"
  }

  // No command ever runs an omaddons other than the verified pinned binary.
  function verifyOnlyPinnedRuns(other) {
    for (var i = 0; i < ProcessRegistry.launches.length; i++) {
      var argv = ProcessRegistry.launches[i].command
      verify(argv.indexOf(other) === -1, JSON.stringify(argv))
      if (argv[0] === "setsid") compare(argv[2], pinnedBinary)
    }
  }

  function test_the_pins_are_the_reviewed_release() {
    var w = make()
    compare(w.pinnedVersion, "0.2.1")
    compare(w.pinnedSha256, sha)
    compare(w.toolSpec, spec)
    // The probe takes the pinned tool as an argument, never written into its script.
    var probe = lastLaunch().command
    compare(probe.slice(0, 2), ["sh", "-c"])
    compare(probe.slice(3), ["sh", spec])
    verify(probe[2].indexOf("a44-io") === -1)
  }

  function test_missing_installs_the_pinned_release_then_the_widget() {
    var w = make()
    compare(w.phase, "checking")
    answer("missing\n", "", 0)
    compare(w.phase, "missing")
    compare(w.other, "")

    w.setUp()
    compare(w.phase, "installing-cli")
    compare(lastLaunch().command, ["mise", "use", "-g", spec])
    answer("", "", 0)
    compare(w.phase, "verifying")
    compare(lastLaunch().command[0], "sh")
    answer(pinned(sha), "", 0)
    compare(w.phase, "installing")
    compare(lastLaunch().command, ["setsid", "-w", pinnedBinary, "--actor", "widget", "--reason", "setup plugin", "omarchy", "install"])
    answer("", "", 0)
    compare(w.phase, "done")
  }

  function test_a_pinned_binary_that_matches_is_ready() {
    var w = make()
    answer(pinned(sha), "", 0)
    compare(w.phase, "ready")
    compare(w.binary, pinnedBinary)
    w.setUp()
    compare(lastLaunch().command.slice(0, 3), ["setsid", "-w", pinnedBinary])
  }

  function test_a_digest_mismatch_is_refused_and_nothing_runs() {
    var w = make()
    var wrong = "3645d8c34def8b7df171313c1674b0467ab6ff2d9882e18f1061787541091f3e"
    answer(pinned(wrong), "", 0)
    compare(w.phase, "failed")
    compare(w.binary, "")
    verify(w.failure.indexOf("not the release this plugin pins") !== -1, w.failure)
    verify(w.failure.indexOf("mise uninstall " + spec) !== -1, w.failure)
    verify(w.failureOutput.indexOf(wrong) !== -1 && w.failureOutput.indexOf(sha) !== -1, w.failureOutput)
    // Try again only looks again; the same answer is refused again.
    w.setUp()
    compare(w.phase, "checking")
    answer(pinned(wrong), "", 0)
    compare(w.phase, "failed")
    // Only the two probes ran: no mise install, no omaddons. (The first test also sees
    // the shell kit's own hyprctl and fc-match lookups as it loads.)
    var ours = ownLaunches()
    compare(ours.length, 2, JSON.stringify(ours))
    verify(ours.every(function(a) { return a[0] === "sh" }), JSON.stringify(ours))
  }

  function test_another_omaddons_is_never_run_and_mise_config_is_left_alone() {
    var w = make()
    var other = "/home/u/.cargo/bin/omaddons"
    answer("missing\nother\t" + other + "\n", "", 0)
    compare(w.phase, "missing")
    compare(w.other, other)
    verify(w.statusText().indexOf("never run") !== -1, w.statusText())
    w.setUp()
    compare(lastLaunch().command, ["mise", "install", spec])
    answer("", "", 0)
    answer(pinned(sha), "", 0)
    compare(lastLaunch().command[2], pinnedBinary)
    answer("", "", 0)
    compare(w.phase, "done")
    verifyOnlyPinnedRuns(other)
  }

  function test_without_mise_it_says_so() {
    var w = make()
    answer("nomise\n", "", 0)
    compare(w.phase, "failed")
    verify(w.failure.indexOf("mise is not on PATH") === 0, w.failure)
  }

  function test_a_failed_mise_install_shows_mise_words() {
    var w = make()
    answer("missing\n", "", 0)
    w.setUp()
    answer("", "mise ERROR Failed to install github:a44-io/omaddons@0.2.1: timed out\n", 1)
    compare(w.phase, "failed")
    compare(w.failure, "mise could not install omaddons 0.2.1.")
    compare(w.failureOutput, "mise ERROR Failed to install github:a44-io/omaddons@0.2.1: timed out")
    compare(w.manualCommand(), "mise use -g " + spec + " && \"$(mise where " + spec + ")/omaddons\" omarchy install")
  }

  function test_installed_but_still_not_found_fails_without_looping() {
    var w = make()
    answer("missing\n", "", 0)
    w.setUp()
    answer("", "", 0)
    answer("missing\n", "", 0)
    compare(w.phase, "failed")
    verify(w.failure.indexOf("not where mise keeps it") !== -1, w.failure)
    compare(ownLaunches().filter(function(a) { return a[0] === "mise" }).length, 1)
  }

  function test_a_failed_widget_install_shows_omaddons_words_and_tries_again() {
    var w = make()
    answer(pinned(sha), "", 0)
    w.setUp()
    answer("", "error: the global lock is held by another omaddons\n  fix: wait for it to finish\n", 5)
    compare(w.phase, "failed")
    compare(w.failure, "omaddons could not install its widget.")
    compare(w.failureOutput, "error: the global lock is held by another omaddons\n  fix: wait for it to finish")
    w.setUp()
    compare(w.phase, "checking", "Try again looks first")
  }

  function test_a_program_that_is_not_there_fails_at_once() {
    var w = make()
    answer("missing\n", "", 0)
    ProcessRegistry.missingBinary = true
    w.setUp()
    wait(50)
    compare(w.phase, "failed")
    verify(w.failureOutput.indexOf("Could not start mise") === 0, w.failureOutput)
  }
}

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

  // The stub Quickshell.env gives "" for HOME.
  readonly property string wrapper: "/.local/bin/omaddons"

  Component { id: widgetComponent; BarWidget {} }

  function make() {
    ProcessRegistry.reset()
    Quickshell.resetDetachedCommands()
    var w = createTemporaryObject(widgetComponent, testCase)
    verify(w !== null)
    return w
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
    p.exit(code)
  }

  function status(path, version) {
    return JSON.stringify({ "ok": true, "tool_version": version, "data": { "plugin": { "path": path } } })
  }

  function test_old_build_is_updated_through_mise_then_the_widget_installs() {
    var w = make()
    compare(w.phase, "checking")
    compare(lastLaunch().command[0], "sh")
    compare(lastLaunch().command[1], "-c")
    answer("nowrapper\nbinary\t/home/u/.cargo/bin/omaddons\n" + status("/c/omarchy/plugins/omaddons", "0.1.0") + "\n", "", 0)
    compare(w.phase, "outdated")
    compare(w.binary, "/home/u/.cargo/bin/omaddons")

    w.setUp()
    compare(w.phase, "installing-cli")
    compare(lastLaunch().command, ["omarchy-mise-install", "github:a44-io/omaddons", "omaddons"])
    answer("", "", 0)
    compare(w.phase, "downloading")
    compare(lastLaunch().command[0], "sh")
    answer("wrapper\nbinary\t" + wrapper + "\n" + status("/c/omarchy/plugins/a44.omaddons", "0.2.0") + "\n", "", 0)
    compare(w.phase, "installing")
    compare(lastLaunch().command, ["setsid", "-w", wrapper, "--actor", "widget", "--reason", "setup plugin", "omarchy", "install"])
    answer("", "", 0)
    compare(w.phase, "done")
    compare(Quickshell.detachedCommands.length, 0, "nothing removed")
  }

  function test_a_ready_build_installs_the_widget_at_once() {
    var w = make()
    answer("nowrapper\nbinary\t/usr/bin/omaddons\n" + status("/c/omarchy/plugins/a44.omaddons", "0.2.0") + "\n", "", 0)
    compare(w.phase, "ready")
    compare(w.version, "0.2.0")
    w.setUp()
    compare(lastLaunch().command.slice(0, 3), ["setsid", "-w", "/usr/bin/omaddons"])
  }

  function test_a_failed_download_removes_the_wrapper_it_created() {
    var w = make()
    answer("nowrapper\nmissing\n", "", 0)
    compare(w.phase, "missing")
    w.setUp()
    answer("", "", 0)   // the wrapper is written
    answer("wrapper\nbroken\t" + wrapper + "\n", "mise ERROR no release found for linux-x64\n", 0)
    compare(w.phase, "failed")
    verify(w.failure.indexOf("mise could not download omaddons.") === 0, w.failure)
    verify(w.failure.indexOf("removed") !== -1, w.failure)
    compare(w.failureOutput, "mise ERROR no release found for linux-x64")
    compare(Quickshell.detachedCommands, [["rm", "-f", "--", wrapper]])
  }

  function test_a_wrapper_that_fails_beside_an_older_build_is_removed_too() {
    var w = make()
    answer("nowrapper\nbinary\t/home/u/.cargo/bin/omaddons\n" + status("/c/omarchy/plugins/omaddons", "0.1.0") + "\n", "", 0)
    w.setUp()
    answer("", "", 0)
    // The probe fell back past the broken wrapper to the older build.
    answer("wrapper\nbinary\t/home/u/.cargo/bin/omaddons\n" + status("/c/omarchy/plugins/omaddons", "0.1.0") + "\n",
      "mise ERROR offline\n", 0)
    compare(w.phase, "failed")
    verify(w.failure.indexOf("mise could not download omaddons.") === 0, w.failure)
    compare(Quickshell.detachedCommands, [["rm", "-f", "--", wrapper]])
  }

  function test_a_wrapper_that_was_there_before_is_never_removed() {
    var w = make()
    answer("wrapper\nbroken\t" + wrapper + "\n", "mise ERROR offline\n", 0)
    compare(w.phase, "failed")
    compare(Quickshell.detachedCommands.length, 0)
  }

  function test_a_failed_widget_install_shows_omaddons_words_and_tries_again() {
    var w = make()
    answer("nowrapper\nbinary\t/usr/bin/omaddons\n" + status("/c/omarchy/plugins/a44.omaddons", "0.2.0") + "\n", "", 0)
    w.setUp()
    answer("", "error: the global lock is held by another omaddons\n  fix: wait for it to finish\n", 5)
    compare(w.phase, "failed")
    compare(w.failure, "omaddons could not install its widget.")
    compare(w.failureOutput, "error: the global lock is held by another omaddons\n  fix: wait for it to finish")
    compare(w.manualCommand(), "/usr/bin/omaddons omarchy install")
    w.setUp()
    compare(w.phase, "checking", "Try again looks first")
  }

  function test_a_program_that_is_not_there_fails_at_once() {
    var w = make()
    answer("nowrapper\nmissing\n", "", 0)
    ProcessRegistry.missingBinary = true
    w.setUp()
    wait(50)
    compare(w.phase, "failed")
    verify(w.failureOutput.indexOf("Could not start omarchy-mise-install") === 0, w.failureOutput)
  }
}

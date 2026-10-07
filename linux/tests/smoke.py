"""Exercise actual GTK widgets, PTY processes, WebKit storage and file monitors."""
import http.server
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
import threading
import time
import traceback

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "linux"))

from multiterminal.app import Application, Window
from multiterminal.model import Store, groups
from multiterminal.native import GLib, WebKit
from multiterminal.panes import BrowserPane, FilePreviewPane, TerminalPane

ERRORS = []


def callback_error(kind, value, tb):
    ERRORS.append(str(value))
    traceback.print_exception(kind, value, tb)


sys.excepthook = callback_error


def pump(predicate=lambda: False, timeout=1):
    deadline = time.monotonic() + timeout
    context = GLib.MainContext.default()
    while time.monotonic() < deadline:
        while context.pending():
            context.iteration(False)
        if ERRORS:
            raise AssertionError("GTK callback errors: " + "; ".join(ERRORS))
        if predicate():
            return True
        time.sleep(.01)
    return bool(predicate())


def wait(predicate, message, timeout=15):
    assert pump(predicate, timeout), message


def evaluate(web, script):
    result = []
    def done(view, task, _data):
        try:
            value = view.evaluate_javascript_finish(task)
            result.append((value.to_string(), None))
        except GLib.Error as exc:
            result.append((None, exc.message))
    web.evaluate_javascript(script, -1, None, None, None, done, None)
    wait(lambda: bool(result), "JavaScript evaluation did not complete")
    assert result[0][1] is None, result[0][1]
    return result[0][0]


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(b"<!doctype html><title>Native browser test</title><h1>Ubuntu WebKit works</h1><a target='_blank' href='/new'>New tab</a>")

    def log_message(self, *_args):
        pass


def main():
    with tempfile.TemporaryDirectory(prefix="multiterminal-smoke-") as folder:
        temporary = Path(folder)
        os.environ["MULTITERMINAL_WORKSPACE_FILE"] = str(temporary / "config/workspaces.json")
        os.environ["XDG_DATA_HOME"] = str(temporary / "data")
        os.environ["XDG_CACHE_HOME"] = str(temporary / "cache")
        workdir = temporary / "a project's folder"
        workdir.mkdir()
        store = Store()
        wsid = store.create("Ubuntu test")
        terminal_id = store.workspace(wsid)["panes"][0]["id"]
        store.update_pane(wsid, terminal_id, directoryPath=str(workdir))
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{server.server_port}/"
        app = Application()
        assert app.register(None)
        app.activate()
        window = app.window
        assert isinstance(window, Window), "App did not create its workspace window"
        def error(text):
            raise AssertionError(text)
        window.error = error
        terminal = window.panes[(wsid, terminal_id)]
        assert isinstance(terminal, TerminalPane)
        wait(lambda: terminal.pid_child is not None, "Shell did not spawn")
        shell_pid = terminal.pid_child
        cwd_file = temporary / "cwd.txt"
        command = f"pwd > {shlex.quote(str(cwd_file))}\n".encode()
        terminal.terminal.feed_child(command)
        wait(lambda: cwd_file.exists() and cwd_file.read_text().strip() == str(workdir), "Shell did not execute in the saved folder")
        print("PASS: real PTY, login shell and starting folder with spaces/apostrophe", flush=True)

        browser = window.add_pane("browser", wsid=wsid, value=url)
        assert isinstance(browser, BrowserPane)
        wait(lambda: browser.web.get_title() == "Native browser test" and not browser.web.is_loading(), "Browser did not load the local HTTP server")
        assert evaluate(browser.web, "document.querySelector('h1').textContent") == "Ubuntu WebKit works"
        evaluate(browser.web, "document.cookie='workspace=one; path=/; max-age=86400'; localStorage.setItem('workspace','one'); 'done'")
        browser_two = window.add_browser_tab(wsid, browser.pid)
        browser_two.web.load_uri(url)
        wait(lambda: not browser_two.web.is_loading() and browser_two.web.get_title() == "Native browser test", "Second browser tab did not load")
        assert evaluate(browser_two.web, "localStorage.getItem('workspace')") == "one"
        assert "workspace=one" in evaluate(browser_two.web, "document.cookie")
        # Exercise WebKit's create signal through an actual new-window link.
        browser.web.get_settings().set_javascript_can_open_windows_automatically(True)
        count = len(window.panes)
        evaluate(browser.web, "window.open('/new'); 'opened'")
        wait(lambda: len(window.panes) == count + 1, "New-window link did not create a browser tab")
        popup = next(p for p in window.panes.values() if isinstance(p, BrowserPane) and p not in (browser, browser_two))
        wait(lambda: popup.web.get_title() == "Native browser test", "Related browser tab did not navigate")
        browser.web.get_settings().set_javascript_can_open_windows_automatically(False)
        print("PASS: browser navigation, new-window tabs, and shared cookies/storage", flush=True)

        window.new_workspace()
        second_wsid = window.active
        other_browser = window.add_pane("browser", wsid=second_wsid, value=url)
        wait(lambda: not other_browser.web.is_loading() and other_browser.web.get_title() == "Native browser test", "Other workspace browser did not load")
        assert evaluate(other_browser.web, "localStorage.getItem('workspace')") == "null"
        assert "workspace=one" not in evaluate(other_browser.web, "document.cookie")
        assert terminal.pid_child == shell_pid
        os.kill(shell_pid, 0)
        window.switch_workspace(wsid)
        print("PASS: isolated workspace browser storage; hidden terminal stays alive", flush=True)

        terminal_group = next(g["id"] for g in groups(window.store.workspace(wsid)["layout"]) if terminal_id in g["paneIDs"])
        browser_group = next(g["id"] for g in groups(window.store.workspace(wsid)["layout"]) if browser.pid in g["paneIDs"])
        assert window.dock(wsid, terminal_id, browser_group)
        pump(timeout=.3)
        assert window.panes[(wsid, terminal_id)] is terminal
        assert terminal.pid_child == shell_pid
        assert window.dock(wsid, terminal_id, browser_group, "bottom")
        pump(timeout=.3)
        assert terminal.pid_child == shell_pid
        print("PASS: tab grouping and splitting preserve the running PTY", flush=True)

        preview_path = workdir / "notes.md"
        preview_path.write_text("# First preview\n\nLive **Markdown**.")
        preview = window.add_pane("filePreview", wsid=wsid, value=str(preview_path))
        assert isinstance(preview, FilePreviewPane)
        wait(lambda: preview.body.get_visible_child_name() == "web" and not preview.web.is_loading(), "Markdown preview did not render")
        assert not preview.web.get_settings().get_enable_javascript()
        # Temporarily enable JS for test observation only. Production previews
        # always have it disabled; no application bridge exists.
        preview.web.get_settings().set_enable_javascript(True)
        wait(lambda: evaluate(preview.web, "document.querySelector('h1')?.textContent || ''") == "First preview", "Markdown heading missing")
        preview.web.get_settings().set_enable_javascript(False)
        generation = preview.generation
        replacement = workdir / ".replacement.md"
        replacement.write_text("# Atomic save\n\nUpdated content.")
        replacement.replace(preview_path)
        wait(lambda: preview.generation > generation and not preview.web.is_loading(), "Directory monitor missed atomic replacement")
        pump(timeout=.5)
        preview.web.get_settings().set_enable_javascript(True)
        assert evaluate(preview.web, "document.querySelector('h1').textContent") == "Atomic save"
        preview.web.get_settings().set_enable_javascript(False)
        print("PASS: rendered live Markdown and atomic-save file monitoring", flush=True)

        window.set_theme("amber")
        assert window.store.state["globalTheme"] == "amber"
        window.theme_pane(wsid, terminal_id, "highContrast")
        loaded = Store()
        assert loaded.pane(wsid, terminal_id)["themeOverride"] == "highContrast"
        assert loaded.workspace(wsid)["layout"]["type"] == "split"
        assert loaded.state["activeWorkspaceID"] == wsid
        print("PASS: themes and nested layout persist across reload", flush=True)

        screenshot = os.environ.get("MULTITERMINAL_TEST_SCREENSHOT")
        if screenshot:
            from capture import capture
            pump(timeout=1)
            capture(screenshot)

        sleep_pid_file = temporary / "job.txt"
        job_script = f"echo $$ > {shlex.quote(str(sleep_pid_file))}; exec sleep 120"
        terminal.terminal.feed_child(f"sh -c {shlex.quote(job_script)}\n".encode())
        wait(lambda: sleep_pid_file.exists() and sleep_pid_file.read_text().strip(), "Foreground shell job did not start")
        job_pid = int(sleep_pid_file.read_text().strip())
        # Ctrl-C interrupts the actual foreground job while retaining the shell.
        terminal.terminal.feed_child(b"\x03")
        wait(lambda: not Path(f"/proc/{job_pid}").exists(), "Ctrl-C did not stop the foreground job")
        assert terminal.pid_child == shell_pid
        sleep_pid_file.unlink()
        terminal.terminal.feed_child(f"sh -c {shlex.quote(job_script)}\n".encode())
        wait(lambda: sleep_pid_file.exists() and sleep_pid_file.read_text().strip(), "Second foreground job did not start")
        job_pid = int(sleep_pid_file.read_text().strip())
        window.close_workspace(wsid)
        wait(lambda: terminal.pid_child is None, "Closing workspace did not reap the shell")
        def stopped():
            try:
                return Path(f"/proc/{job_pid}/stat").read_text().split()[2] == "Z"
            except FileNotFoundError:
                return True
        wait(stopped, "Closing workspace left its shell job alive")
        assert wsid not in window.store.state["openWorkspaceIDs"]
        assert window.store.workspace(wsid)["name"] == "Ubuntu test"
        window.open_workspace(wsid)
        fresh = window.panes[(wsid, terminal_id)]
        wait(lambda: fresh.pid_child is not None, "Reopening workspace did not spawn a fresh shell")
        assert fresh.pid_child != shell_pid
        reopened_browser = window.panes[(wsid, browser.pid)]
        wait(lambda: not reopened_browser.web.is_loading() and reopened_browser.web.get_title() == "Native browser test", "Reopened browser did not load")
        assert evaluate(reopened_browser.web, "localStorage.getItem('workspace')") == "one"
        assert "workspace=one" in evaluate(reopened_browser.web, "document.cookie")
        print("PASS: persistent browser cookies and local storage survive closing/reopening", flush=True)
        window.close_workspace(wsid, delete=True)
        assert not any(path.exists() for path in window.profile_paths(wsid))
        assert preview_path.exists()
        print("PASS: close stops jobs; reopen starts fresh shells; delete preserves project files", flush=True)
        window._quit_confirmed = True
        window.close()
        app.quit()
        pump(timeout=.2)
        server.shutdown()
        assert not ERRORS
        print("All native Ubuntu integration checks passed.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.exit(1)

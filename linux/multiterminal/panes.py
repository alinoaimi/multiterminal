from concurrent.futures import ThreadPoolExecutor
import html
import os
from pathlib import Path
import pwd
import signal
from urllib.parse import urlsplit

import markdown

from . import __version__
from .model import normalize_url
from .native import Gdk, Gio, GLib, Gtk, Pango, Vte, WebKit

READERS = ThreadPoolExecutor(max_workers=2, thread_name_prefix="preview")
COLORS = {
    "midnight": ("#dce5f5", "#101522", ["#283142", "#ff7185", "#90d68d", "#f6ce79", "#82aaff", "#c792ea", "#7fdbca", "#c7d2e5", "#607087", "#ff9baa", "#b3edaf", "#ffe3a1", "#abc7ff", "#ddb8fa", "#a8eee2", "#ffffff"]),
    "highContrast": ("#ffffff", "#000000", ["#000000", "#ff5555", "#55ff55", "#ffff55", "#5599ff", "#ff55ff", "#55ffff", "#ffffff", "#aaaaaa", "#ff8888", "#88ff88", "#ffff88", "#88bbff", "#ff88ff", "#88ffff", "#ffffff"]),
    "amber": ("#ffd27d", "#20170b", ["#312617", "#e57859", "#d0c47a", "#ffd27d", "#d3aa67", "#d99570", "#c9bc87", "#eddaa9", "#94754b", "#f8a27b", "#e3dd9e", "#ffe4aa", "#e6c28c", "#f0b694", "#e3d6b0", "#fff1cd"]),
}


def button(icon, tooltip, callback):
    widget = Gtk.Button.new_from_icon_name(icon)
    widget.set_tooltip_text(tooltip)
    widget.add_css_class("icon-button")
    widget.connect("clicked", lambda _b: callback())
    return widget


def external(window, uri):
    launcher = Gtk.UriLauncher.new(uri)
    def finished(obj, result):
        try:
            obj.launch_finish(result)
        except GLib.Error as exc:
            window.error(str(exc))
    launcher.launch(window, None, finished)


def color(value):
    rgba = Gdk.RGBA()
    rgba.parse(value)
    return rgba


class Pane:
    def __init__(self, window, wsid, pid):
        self.window, self.wsid, self.pid = window, wsid, pid
        self.closed = False
        self.widget = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.widget.set_hexpand(True)
        self.widget.set_vexpand(True)
        self.widget.add_css_class("pane-content")
        self.toolbar = Gtk.Box(spacing=4)
        self.toolbar.add_css_class("pane-toolbar")
        self.widget.append(self.toolbar)
        self.status_box = Gtk.Box(spacing=8)
        self.status_box.add_css_class("pane-status")
        self.status = Gtk.Label(wrap=True, xalign=0, hexpand=True)
        self.status_action = Gtk.Button()
        self.status_callback = None
        self.status_action.connect("clicked", lambda _b: self.status_callback() if self.status_callback else None)
        self.status_box.append(self.status)
        self.status_box.append(self.status_action)
        self.status_box.set_visible(False)
        self.widget.append(self.status_box)
        focus = Gtk.EventControllerFocus()
        focus.connect("enter", lambda _c: window.focus_pane(wsid, pid))
        self.widget.add_controller(focus)

    @property
    def model(self):
        return self.window.store.pane(self.wsid, self.pid)

    def message(self, text, action=None, action_label="Restart shell"):
        self.status.set_text(text)
        self.status_callback = action
        self.status_action.set_label(action_label)
        self.status_action.set_visible(action is not None)
        self.status_box.set_visible(bool(text))

    def close(self):
        self.closed = True


class TerminalPane(Pane):
    def __init__(self, window, wsid, pid):
        super().__init__(window, wsid, pid)
        self.pid_child = None
        self.spawn_pending = False
        self.started = False
        # Terminal actions live in the group header/menu, leaving one compact
        # header row above the terminal rather than a second full toolbar.
        self.toolbar.set_visible(False)
        self.terminal = Vte.Terminal()
        self.terminal.set_hexpand(True)
        self.terminal.set_vexpand(True)
        self.terminal.add_css_class("terminal-surface")
        self.terminal.set_font(Pango.FontDescription.from_string("DejaVu Sans Mono 11"))
        self.terminal.set_scrollback_lines(20000)
        self.terminal.set_scroll_on_keystroke(True)
        self.terminal.set_scroll_on_output(False)
        self.terminal.set_mouse_autohide(True)
        self.terminal.connect("child-exited", self.exited)
        self.terminal.connect("map", self.mapped)
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.key_pressed)
        self.terminal.add_controller(keys)
        scroller = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroller.set_child(self.terminal)
        self.widget.append(scroller)
        self.apply_theme()

    def apply_theme(self):
        theme = self.model.get("themeOverride") or self.window.store.state["globalTheme"]
        foreground, background, palette = COLORS[theme]
        self.terminal.set_colors(color(foreground), color(background), [color(c) for c in palette])
        self.set_font_size(self.window.store.state.get("terminalFontSize", 11))

    def set_font_size(self, size):
        self.terminal.set_font(Pango.FontDescription.from_string(f"DejaVu Sans Mono {size}"))

    def has_running_job(self):
        if not self.pid_child:
            return False
        pty = self.terminal.get_pty()
        try:
            if pty and os.tcgetpgrp(pty.get_fd()) != self.pid_child:
                return True
            # Background shell jobs also deserve confirmation before closing.
            children = Path(f"/proc/{self.pid_child}/task/{self.pid_child}/children")
            try:
                return bool(children.read_text().strip())
            except FileNotFoundError:
                # Some Linux kernels omit the optional task/children file.
                # Read parent PIDs instead; a process may exit during the scan.
                for process in Path("/proc").iterdir():
                    if not process.name.isdecimal():
                        continue
                    try:
                        fields = (process / "stat").read_text().rsplit(")", 1)[1].split()
                    except (FileNotFoundError, ProcessLookupError):
                        continue
                    if int(fields[1]) == self.pid_child:
                        return True
                return False
        except (OSError, ValueError):
            return True

    def mapped(self, _widget):
        if not self.started:
            self.started = True
            self.spawn()

    def spawn(self):
        if self.closed or self.spawn_pending:
            return
        self.message("")
        directory = str(Path(self.model["directoryPath"]).expanduser())
        if not Path(directory).is_dir():
            self.message(f"Starting folder is unavailable: {directory}. Using your home folder.")
            directory = str(Path.home())
        shell = os.environ.get("SHELL") or pwd.getpwuid(os.getuid()).pw_shell or "/bin/bash"
        if not os.path.isabs(shell) or not os.access(shell, os.X_OK):
            shell = "/bin/bash"
        env = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor", TERM_PROGRAM="MultiTerminal", TERM_PROGRAM_VERSION=__version__)
        self.spawn_pending = True
        self.terminal.spawn_async(Vte.PtyFlags.DEFAULT, directory, [shell, "-l"], [f"{k}={v}" for k, v in env.items()], GLib.SpawnFlags.DEFAULT, None, None, -1, None, self.spawned, None)

    def spawned(self, _terminal, pid, error, _data):
        self.spawn_pending = False
        if error:
            if not self.closed:
                self.message(f"Could not start shell: {error.message}", self.spawn, "Try again")
            return
        self.pid_child = pid
        if self.closed:
            self.stop()
        else:
            self.window.update_status()

    def exited(self, _terminal, status):
        self.pid_child = None
        if not self.closed:
            code = os.waitstatus_to_exitcode(status)
            self.message(f"Shell exited (status {code}).", self.restart)
            self.window.update_status()

    def stop(self):
        if not self.pid_child:
            return
        # SIGHUP both the foreground job and the shell's process group. Detached
        # jobs retain their own lifetime, just as they do in other terminals.
        pgids = {self.pid_child}
        pty = self.terminal.get_pty()
        if pty:
            try:
                foreground = os.tcgetpgrp(pty.get_fd())
                if foreground > 1 and foreground != os.getpgrp():
                    pgids.add(foreground)
            except OSError:
                pass
        for pgid in pgids:
            try:
                os.killpg(pgid, signal.SIGHUP)
            except ProcessLookupError:
                pass
            except PermissionError:
                pass

    def restart(self):
        if self.spawn_pending:
            return
        if self.has_running_job():
            self.window.confirm("Restart shell?", "The current shell and its running jobs will stop.", self._restart, "Restart")
        elif self.pid_child:
            self._restart()
        else:
            self.spawn()

    def _restart(self):
        if self.closed:
            return
        if not self.pid_child:
            self.spawn()
            return
        # Spawn only after VTE has reaped the old child.
        def after_exit(_terminal, _status):
            self.terminal.disconnect(handler)
            if not self.closed:
                GLib.idle_add(self.spawn)
        handler = self.terminal.connect("child-exited", after_exit)
        self.stop()

    def choose_directory(self):
        def selected(path):
            if self.closed:
                return
            if self.window.perform(lambda: self.window.store.update_pane(self.wsid, self.pid, directoryPath=path)):
                self.window.update_labels()
                self.window.update_status()
                self.message("Start folder saved. Apply it to a fresh shell when you're ready.", self.restart, "Restart here")
        self.window.choose_file(selected, folder=True)

    def copy(self):
        self.terminal.copy_clipboard_format(Vte.Format.TEXT)

    def paste(self):
        self.terminal.paste_clipboard()

    def key_pressed(self, _controller, keyval, _keycode, state):
        modifiers = Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK
        if state & modifiers == modifiers:
            if keyval in (Gdk.KEY_c, Gdk.KEY_C):
                self.copy()
                return True
            if keyval in (Gdk.KEY_v, Gdk.KEY_V):
                self.paste()
                return True
        return False

    def close(self):
        super().close()
        self.stop()


class BrowserPane(Pane):
    def __init__(self, window, wsid, pid, related_view=None):
        super().__init__(window, wsid, pid)
        self.web = WebKit.WebView(related_view=related_view) if related_view else WebKit.WebView(network_session=window.browser_session(wsid))
        self.web.set_hexpand(True)
        self.web.set_vexpand(True)
        self.back = button("go-previous-symbolic", "Back", self.web.go_back)
        self.forward = button("go-next-symbolic", "Forward", self.web.go_forward)
        self.reload = button("view-refresh-symbolic", "Reload / stop", self.refresh)
        self.address = Gtk.Entry(hexpand=True, placeholder_text="localhost:5173 or https://example.com")
        self.address.connect("activate", self.navigate)
        for widget in (self.back, self.forward, self.reload, self.address, button("web-browser-symbolic", "Open in default browser", self.open_external)):
            self.toolbar.append(widget)
        self.web.connect("notify::uri", self.uri_changed)
        self.web.connect("load-changed", self.load_changed)
        self.web.connect("load-failed", self.load_failed)
        self.web.connect("decide-policy", self.policy)
        self.web.connect("create", self.create_window)
        self.widget.append(self.web)
        self.back.set_sensitive(False)
        self.forward.set_sensitive(False)
        url = self.model["url"]
        self.address.set_text(url)
        if url:
            self.web.load_uri(normalize_url(url))
        elif related_view is None:
            self.web.load_html("<html><body style='background:#101522;color:#dce5f5;font:18px sans-serif;padding:40px'><h2>Your app, beside your tools.</h2><p>Enter a website or localhost address above.</p></body></html>", None)

    def navigate(self, _entry):
        try:
            uri = normalize_url(self.address.get_text())
            if uri:
                self.message("")
                self.web.load_uri(uri)
        except ValueError as exc:
            self.message(str(exc))

    def policy(self, _web, decision, kind):
        if kind in (WebKit.PolicyDecisionType.NAVIGATION_ACTION, WebKit.PolicyDecisionType.NEW_WINDOW_ACTION):
            uri = decision.get_navigation_action().get_request().get_uri()
            if urlsplit(uri).scheme not in ("http", "https", "about"):
                decision.ignore()
                self.message("This browser accepts HTTP and HTTPS links.")
                return True
        return False

    def create_window(self, _web, _action):
        incoming = self.window.add_browser_tab(self.wsid, self.pid, related_view=self.web)
        return incoming.web if incoming else None

    def uri_changed(self, _web, _spec):
        if self.closed:
            return
        uri = self.web.get_uri() or ""
        if urlsplit(uri).scheme in ("http", "https"):
            self.address.set_text(uri)
            if uri != self.model["url"]:
                self.window.perform(lambda: self.window.store.update_pane(self.wsid, self.pid, url=uri))
                self.window.update_labels()

    def load_changed(self, _web, _event):
        self.back.set_sensitive(self.web.can_go_back())
        self.forward.set_sensitive(self.web.can_go_forward())
        self.reload.set_icon_name("process-stop-symbolic" if self.web.is_loading() else "view-refresh-symbolic")

    def load_failed(self, _web, _event, _uri, error):
        if not self.closed:
            self.message(error.message)
        return False

    def refresh(self):
        self.web.stop_loading() if self.web.is_loading() else self.web.reload()

    def open_external(self):
        uri = self.web.get_uri() or ""
        if urlsplit(uri).scheme in ("http", "https"):
            external(self.window, uri)

    def close(self):
        if self.closed:
            return
        super().close()
        self.web.stop_loading()
        self.widget.remove(self.web)
        self.web.run_dispose()


def read_preview(path):
    selected = Path(path)
    if selected.stat().st_size > 10 * 1024 * 1024:
        raise ValueError("Text and HTML previews are limited to 10 MB. Open this file in its default application.")
    data = selected.read_bytes()
    if len(data) > 10 * 1024 * 1024:
        raise ValueError("The file grew beyond the 10 MB preview limit.")
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        text = data.decode("utf-16")
    else:
        text = data.decode("utf-8-sig")
    if "\x00" in text:
        raise ValueError("This binary file needs its default application.")
    extension = selected.suffix.lower()
    if extension in (".html", ".htm"):
        return text
    if extension in (".md", ".markdown"):
        body = markdown.markdown(text, extensions=["fenced_code", "tables", "sane_lists"])
    else:
        body = "<pre>" + html.escape(text) + "</pre>"
    return """<!doctype html><html><head><meta charset='utf-8'>
<meta http-equiv='Content-Security-Policy' content="default-src 'none'; img-src file: data: https: http:; style-src 'unsafe-inline'">
<style>html{color-scheme:dark}body{background:#101522;color:#dce5f5;font:15px/1.6 sans-serif;padding:20px;overflow-wrap:anywhere}pre,code{font-family:monospace}pre{white-space:pre-wrap}img{max-width:100%}a{color:#82aaff}table{border-collapse:collapse}td,th{border:1px solid #445;padding:6px}blockquote{border-left:3px solid #82aaff;padding-left:12px}</style></head><body>""" + body + "</body></html>"


class FilePreviewPane(Pane):
    def __init__(self, window, wsid, pid):
        super().__init__(window, wsid, pid)
        self.monitor = None
        self.timer = None
        self.generation = 0
        self.label = Gtk.Label(xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.MIDDLE)
        self.toolbar.append(button("document-open-symbolic", "Choose another file", self.choose))
        self.toolbar.append(self.label)
        self.toolbar.append(button("view-refresh-symbolic", "Reload preview", self.refresh))
        self.toolbar.append(button("document-open-symbolic", "Open in default application", self.open_external))
        self.body = Gtk.Stack(hexpand=True, vexpand=True)
        session = WebKit.NetworkSession.new_ephemeral()
        self.web = WebKit.WebView(network_session=session)
        self.web.get_settings().set_enable_javascript(False)
        self.web.connect("decide-policy", self.policy)
        self.body.add_named(self.web, "web")
        self.picture = Gtk.Picture(hexpand=True, vexpand=True, can_shrink=True)
        self.picture.set_content_fit(Gtk.ContentFit.CONTAIN)
        self.body.add_named(self.picture, "image")
        self.placeholder = Gtk.Label(label="Choose a file to preview it live.", wrap=True)
        self.body.add_named(self.placeholder, "empty")
        self.widget.append(self.body)
        self.watch()
        self.refresh()

    def policy(self, _web, decision, kind):
        if kind == WebKit.PolicyDecisionType.NAVIGATION_ACTION:
            action = decision.get_navigation_action()
            if action.is_user_gesture():
                uri = action.get_request().get_uri()
                if urlsplit(uri).scheme in ("http", "https"):
                    external(self.window, uri)
                decision.ignore()
                return True
        if kind == WebKit.PolicyDecisionType.NEW_WINDOW_ACTION:
            decision.ignore()
            return True
        return False

    def choose(self):
        def selected(path):
            if self.window.perform(lambda: self.window.store.update_pane(self.wsid, self.pid, path=path)):
                self.watch()
                self.refresh()
                self.window.update_labels()
        self.window.choose_file(selected)

    def watch(self):
        if self.monitor:
            self.monitor.cancel()
            self.monitor = None
        path = self.model["path"]
        if not path:
            return
        try:
            self.monitor = Gio.File.new_for_path(str(Path(path).parent)).monitor_directory(Gio.FileMonitorFlags.NONE, None)
            self.monitor.connect("changed", self.changed)
        except GLib.Error as exc:
            self.message(f"Live refresh unavailable: {exc.message}")

    def changed(self, _monitor, file, other, _event):
        if self.closed:
            return
        path = self.model["path"]
        if file.get_path() == path or (other and other.get_path() == path):
            if self.timer:
                GLib.source_remove(self.timer)
            self.timer = GLib.timeout_add(200, self.delayed_refresh)

    def delayed_refresh(self):
        self.timer = None
        self.refresh()
        return False

    def refresh(self):
        if self.closed:
            return
        self.generation += 1
        generation = self.generation
        path = self.model["path"]
        self.label.set_text(path or "File preview")
        self.label.set_tooltip_text(path)
        self.message("")
        if not path:
            self.body.set_visible_child_name("empty")
            return
        extension = Path(path).suffix.lower()
        if extension in (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp"):
            try:
                if Path(path).stat().st_size > 20 * 1024 * 1024:
                    raise ValueError("Image preview is limited to 20 MB.")
                self.picture.set_filename(path)
                self.body.set_visible_child_name("image")
            except (OSError, ValueError) as exc:
                self.show_error(str(exc))
            return
        future = READERS.submit(read_preview, path)
        def finished(task):
            if task.cancelled() or self.closed:
                return
            try:
                result, error = task.result(), None
            except (OSError, UnicodeError, ValueError) as exc:
                result, error = None, str(exc)
            GLib.idle_add(self.loaded, generation, path, result, error)
        future.add_done_callback(finished)

    def loaded(self, generation, path, content, error):
        if self.closed or generation != self.generation:
            return False
        if error:
            self.show_error(error)
        else:
            self.body.set_visible_child_name("web")
            self.web.load_html(content, Path(path).parent.as_uri() + "/")
        return False

    def show_error(self, error):
        self.placeholder.set_text("Preview unavailable. Use Open in default application for PDF and other formats.")
        self.body.set_visible_child_name("empty")
        self.message(error)

    def open_external(self):
        if self.model["path"]:
            external(self.window, Path(self.model["path"]).as_uri())

    def close(self):
        if self.closed:
            return
        super().close()
        if self.monitor:
            self.monitor.cancel()
        if self.timer:
            GLib.source_remove(self.timer)
        self.web.stop_loading()
        self.body.remove(self.web)
        self.web.run_dispose()


PANE_CLASSES = {"terminal": TerminalPane, "browser": BrowserPane, "filePreview": FilePreviewPane}

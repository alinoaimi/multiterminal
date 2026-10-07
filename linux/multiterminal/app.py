import os
from pathlib import Path
import shutil
from urllib.parse import urlsplit

from . import __linux_revision__, __version__
from .model import Store, THEMES, data_home, groups, nodes, pane
from .native import Gdk, Gio, GLib, GObject, Gtk, Pango, WebKit
from .panes import BrowserPane, PANE_CLASSES, READERS, TerminalPane, button, external

CSS = """
window { background: #0f1520; color: #dce5f5; }
headerbar { background: #151d2b; border-bottom: 1px solid #263247; min-height: 42px; }
headerbar .title { font-weight: 600; }
button { border-radius: 6px; }
button:focus-visible { outline: 2px solid #94b8ff; outline-offset: -2px; }
.icon-button { min-width: 24px; min-height: 24px; padding: 3px; background: transparent; box-shadow: none; border-color: transparent; }
.icon-button:hover { background: #2a374d; }
.workspace-strip { padding: 5px 8px; background: #151d2b; border-bottom: 1px solid #263247; }
.workspace-tab { border-radius: 6px; padding: 0; border: 1px solid transparent; }
.workspace-tab.active { background: #253a58; border-color: #3d5c85; }
.workspace-tab button { background: transparent; box-shadow: none; border: none; padding: 3px 8px; min-height: 24px; }
.workspace-tab .icon-button { padding: 3px; }
.workspace-tab .workspace-name { font-weight: 500; }
.workspace-tab.active .workspace-name { font-weight: 600; }
.workspace-actions { margin-left: 8px; }
.pane-group { border: 1px solid #28364c; border-radius: 7px; }
.pane-group.focused { border-color: #7b9ecc; }
.pane-header { background: #182231; padding: 3px 5px; border-radius: 6px 6px 0 0; }
.pane-tabs { padding: 0; }
.pane-tabs button { background: transparent; box-shadow: none; border: none; padding: 3px 7px; min-height: 24px; }
.pane-tabs .icon-button { padding: 3px; }
.pane-tab { border-radius: 5px; }
.pane-tab.active { background: #283950; }
.pane-type-icon { color: #90a6c4; }
.pane-toolbar { padding: 4px 6px; background: #141d2a; }
.pane-toolbar entry { min-width: 100px; }
.pane-status { background: #322b1e; color: #ffe3a1; padding: 6px 10px; }
.pane-content { background: #0f1520; }
.terminal-surface { padding: 8px 10px; }
.workspace-body { padding: 6px; }
paned > separator { min-width: 6px; min-height: 6px; background: #0f1520; }
paned > separator:hover { background: #7195c5; }
.statusbar { padding: 3px 10px; background: #141c29; color: #93a8c6; border-top: 1px solid #263247; font-size: 11px; }
.shortcut-hint { color: #8398b4; }
.dock-center { box-shadow: inset 0 0 0 3px #82aaff; }
.dock-left { border-left: 6px solid #82aaff; }
.dock-right { border-right: 6px solid #82aaff; }
.dock-top { border-top: 6px solid #82aaff; }
.dock-bottom { border-bottom: 6px solid #82aaff; }
.empty-state { padding: 40px; }
popover contents { background: #1a2435; color: #dce5f5; }
.menu-heading { font-weight: 600; margin: 4px 6px 8px; }
.menu-item { padding: 7px 10px; }
.workspace-form { padding: 20px; }
"""


def pane_title(p):
    if p["kind"] == "terminal":
        return Path(p["directoryPath"]).name or "Terminal"
    if p["kind"] == "filePreview":
        return Path(p["path"]).name or "File preview"
    return urlsplit(p["url"]).hostname or "Browser"


class Window(Gtk.ApplicationWindow):
    def __init__(self, app, store):
        super().__init__(application=app, title="MultiTerminal", default_width=1280, default_height=800)
        self.store = store
        self.panes = {}
        self.sessions = {}
        self.pages = {}
        self.group_widgets = {}
        self.labels = {}
        self.tab_rows = {}
        self.group_stacks = {}
        self.group_menus = {}
        self.zoomed_groups = {}
        self.workspace_rows = {}
        self.split_timers = {}
        self.closing = False
        self.rebuilding = False
        self._quit_confirmed = False
        self.connect("close-request", self.close_requested)
        header = Gtk.HeaderBar()
        header.set_title_widget(Gtk.Label(label="MultiTerminal"))
        self.new_terminal_button = Gtk.Button(label="New Terminal", tooltip_text="Split the focused pane with a terminal · Ctrl+Shift+T")
        self.new_terminal_button.add_css_class("suggested-action")
        self.new_terminal_button.connect("clicked", lambda _b: self.add_pane("terminal"))
        header.pack_start(self.new_terminal_button)
        self.add_menu = Gtk.MenuButton(label="Add Pane", tooltip_text="Add a browser, terminal, or live file preview")
        header.pack_start(self.add_menu)
        self.restore_button = Gtk.Button(label="Restore Layout", tooltip_text="Leave pane focus mode · Escape")
        self.restore_button.connect("clicked", lambda _b: self.restore_layout())
        self.restore_button.set_visible(False)
        header.pack_end(self.restore_button)
        menu = Gtk.MenuButton(icon_name="open-menu-symbolic", tooltip_text="Workspace options, theme and text size")
        self.main_menu = menu
        self.fill_main_menu(menu)
        header.pack_end(menu)
        self.set_titlebar(header)
        self.root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        workspace_strip = Gtk.Box(spacing=4)
        workspace_strip.add_css_class("workspace-strip")
        self.tabs = Gtk.Box(spacing=4)
        tab_scroll = Gtk.ScrolledWindow(hexpand=True)
        tab_scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER)
        tab_scroll.set_child(self.tabs)
        workspace_strip.append(tab_scroll)
        workspace_actions = Gtk.Box(spacing=4)
        workspace_actions.add_css_class("workspace-actions")
        new_workspace = Gtk.Button(label="+ Workspace", tooltip_text="Name a new workspace and choose its starting folder · Ctrl+Shift+N")
        new_workspace.add_css_class("flat")
        new_workspace.connect("clicked", lambda _b: self.prompt_workspace())
        workspace_actions.append(new_workspace)
        self.open_menu = Gtk.MenuButton(label="Open", tooltip_text="Reopen a saved workspace")
        workspace_actions.append(self.open_menu)
        workspace_strip.append(workspace_actions)
        self.root.append(workspace_strip)
        self.stack = Gtk.Stack(hexpand=True, vexpand=True)
        self.stack.set_transition_type(Gtk.StackTransitionType.NONE)
        empty = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14, halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
        empty.add_css_class("empty-state")
        title = Gtk.Label(label="Make room for your whole workflow.")
        title.add_css_class("title-1")
        empty.append(title)
        empty.append(Gtk.Label(label="Create a workspace or reopen a saved one from the menu.", wrap=True))
        start = Gtk.Button(label="New Workspace")
        start.add_css_class("suggested-action")
        start.connect("clicked", lambda _b: self.prompt_workspace())
        empty.append(start)
        self.stack.add_named(empty, "empty")
        self.root.append(self.stack)
        statusbar = Gtk.Box(spacing=16)
        statusbar.add_css_class("statusbar")
        self.status_label = Gtk.Label(xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.MIDDLE)
        self.shortcut_label = Gtk.Label(label="Ctrl+Shift+T  New terminal")
        self.shortcut_label.add_css_class("shortcut-hint")
        statusbar.append(self.status_label)
        statusbar.append(self.shortcut_label)
        self.root.append(statusbar)
        self.set_child(self.root)
        self.fill_add_menu()
        self.install_actions()
        for wsid in store.state["openWorkspaceIDs"]:
            self.render(wsid)
        self.sync_tabs()

    def perform(self, callback):
        try:
            callback()
            return True
        except (OSError, ValueError, KeyError, StopIteration) as exc:
            self.error(str(exc))
            return False

    def error(self, text):
        dialog = Gtk.AlertDialog(message="MultiTerminal", detail=text)
        dialog.show(self)

    def confirm(self, title, detail, callback, accept="Close"):
        dialog = Gtk.AlertDialog(message=title, detail=detail, buttons=["Cancel", accept], cancel_button=0, default_button=0)
        def finished(obj, result):
            try:
                if obj.choose_finish(result) == 1:
                    callback()
            except GLib.Error:
                pass
        dialog.choose(self, None, finished)

    def choose_file(self, callback, folder=False, parent=None):
        dialog = Gtk.FileDialog(title="Choose starting folder" if folder else "Choose a file to preview")
        def finished(obj, result):
            try:
                selected = obj.select_folder_finish(result) if folder else obj.open_finish(result)
                path = selected.get_path()
                if path:
                    callback(path)
                else:
                    self.error("Select a local file or folder.")
            except GLib.Error as exc:
                if exc.matches(Gtk.dialog_error_quark(), Gtk.DialogError.DISMISSED) or exc.matches(Gtk.dialog_error_quark(), Gtk.DialogError.CANCELLED):
                    return
                self.error(exc.message)
        if folder:
            dialog.select_folder(parent or self, None, finished)
        else:
            dialog.open(parent or self, None, finished)

    def popover(self, owner, entries):
        pop = Gtk.Popover()
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        box.set_margin_top(8)
        box.set_margin_bottom(8)
        box.set_margin_start(8)
        box.set_margin_end(8)
        for label, callback in entries:
            if callback is None:
                box.append(Gtk.Separator())
            else:
                b = Gtk.Button(label=label, halign=Gtk.Align.FILL)
                b.add_css_class("flat")
                def clicked(_button, fn=callback):
                    pop.popdown()
                    fn()
                b.connect("clicked", clicked)
                box.append(b)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_max_content_height(460)
        scroll.set_propagate_natural_height(True)
        scroll.set_child(box)
        pop.set_child(scroll)
        owner.set_popover(pop)

    @property
    def active(self):
        return self.store.state.get("activeWorkspaceID")

    def fill_add_menu(self):
        self.add_popover(self.add_menu)

    def add_popover(self, owner, wsid=None, target=None):
        pop = Gtk.Popover()
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        for side in ("top", "bottom", "start", "end"):
            getattr(box, "set_margin_" + side)(10)
        title = Gtk.Label(label="Add a pane", xalign=0)
        title.add_css_class("menu-heading")
        box.append(title)
        placement = {"value": "tab" if target else "right"}
        choices = Gtk.Box(spacing=3)
        choices.add_css_class("linked")
        first = None
        for label, value in (("New tab", "tab"), ("Split right", "right"), ("Split below", "bottom")):
            toggle = Gtk.ToggleButton(label=label)
            if first:
                toggle.set_group(first)
            else:
                first = toggle
            toggle.set_active(value == placement["value"])
            toggle.connect("toggled", lambda b, v=value: placement.update(value=v) if b.get_active() else None)
            choices.append(toggle)
        box.append(choices)
        for label, kind, icon in (("Terminal", "terminal", "utilities-terminal-symbolic"), ("Browser", "browser", "web-browser-symbolic"), ("File preview", "filePreview", "text-x-generic-symbolic")):
            item = Gtk.Button()
            row = Gtk.Box(spacing=10)
            row.append(Gtk.Image.new_from_icon_name(icon))
            row.append(Gtk.Label(label=label, xalign=0, hexpand=True))
            item.set_child(row)
            item.add_css_class("flat")
            item.add_css_class("menu-item")
            def clicked(_button, k=kind):
                pop.popdown()
                selected = placement["value"]
                self.add_pane(k, edge="right" if selected == "tab" else selected, as_tab=selected == "tab", wsid=wsid, target=target)
            item.connect("clicked", clicked)
            box.append(item)
        pop.set_child(box)
        owner.set_popover(pop)

    def fill_main_menu(self, menu):
        entries = [("Rename workspace…", self.rename_workspace), ("Close workspace", self.request_close_workspace), ("Delete workspace…", self.request_delete_workspace), ("", None)]
        for ws in self.store.state["workspaces"]:
            if ws["id"] not in self.store.state["openWorkspaceIDs"]:
                entries.append(("Open " + ws["name"], lambda i=ws["id"]: self.open_workspace(i)))
        entries.append(("", None))
        for label, theme in (("Midnight", "midnight"), ("High Contrast", "highContrast"), ("Amber", "amber")):
            mark = "✓ " if theme == self.store.state["globalTheme"] else ""
            entries.append((mark + label + " theme", lambda t=theme: self.set_theme(t)))
        entries.extend([("", None), ("Larger terminal text  ·  Ctrl++", lambda: self.resize_text(1)), ("Smaller terminal text  ·  Ctrl+−", lambda: self.resize_text(-1)), ("Reset terminal text  ·  Ctrl+0", lambda: self.resize_text(reset=True))])
        entries.extend([("", None), ("Help & keyboard shortcuts", self.help), ("About MultiTerminal", self.about), ("Quit", self.close)])
        self.popover(menu, entries)

    def install_actions(self):
        actions = {"new-workspace": self.prompt_workspace, "new-terminal": lambda: self.add_pane("terminal"), "new-browser": lambda: self.add_pane("browser"), "close-workspace": self.request_close_workspace, "close-pane": self.request_close_active_pane, "rename": self.rename_workspace, "next-workspace": lambda: self.cycle_workspace(1), "previous-workspace": lambda: self.cycle_workspace(-1), "quit": self.close, "zoom-pane": self.toggle_zoom, "restore-layout": self.restore_layout, "larger-text": lambda: self.resize_text(1), "smaller-text": lambda: self.resize_text(-1), "reset-text": lambda: self.resize_text(reset=True)}
        for name, callback in actions.items():
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", lambda _a, _p, fn=callback: fn())
            self.add_action(action)
        shortcuts = {"new-workspace": ["<Control><Shift>n"], "new-terminal": ["<Control><Shift>t"], "new-browser": ["<Control><Shift>b"], "close-pane": ["<Control><Shift>w"], "close-workspace": ["<Control><Shift>q"], "rename": ["F2"], "next-workspace": ["<Control>Page_Down"], "previous-workspace": ["<Control>Page_Up"], "quit": ["<Control>q"], "zoom-pane": ["<Control><Shift>Return"], "restore-layout": ["Escape"], "larger-text": ["<Control>plus", "<Control>equal", "<Control>KP_Add"], "smaller-text": ["<Control>minus", "<Control>KP_Subtract"], "reset-text": ["<Control>0"]}
        for name, keys in shortcuts.items():
            self.get_application().set_accels_for_action("win." + name, keys)

    def sync_tabs(self):
        child = self.tabs.get_first_child()
        while child:
            self.tabs.remove(child)
            child = self.tabs.get_first_child()
        opened = self.store.state["openWorkspaceIDs"]
        self.workspace_rows = {}
        for wsid in opened:
            ws = self.store.workspace(wsid)
            row = Gtk.Box(spacing=0)
            row.add_css_class("workspace-tab")
            self.workspace_rows[wsid] = row
            if wsid == self.active:
                row.add_css_class("active")
            label = Gtk.Button()
            name = Gtk.Label(label=ws["name"], max_width_chars=24, ellipsize=Pango.EllipsizeMode.END)
            name.add_css_class("workspace-name")
            label.set_child(name)
            label.set_tooltip_text(f"{ws['name']} · Double-click to rename · F2")
            label.connect("clicked", lambda _b, i=wsid: self.switch_workspace(i))
            double = Gtk.GestureClick()
            double.connect("pressed", lambda _g, count, _x, _y, i=wsid: self.rename_workspace(i) if count == 2 else None)
            label.add_controller(double)
            row.append(label)
            row.append(button("window-close-symbolic", "Close workspace; keep its saved layout", lambda i=wsid: self.request_close_workspace(i)))
            self.tabs.append(row)
        closed = [ws for ws in self.store.state["workspaces"] if ws["id"] not in opened]
        self.popover(self.open_menu, [(ws["name"], lambda i=ws["id"]: self.open_workspace(i)) for ws in closed])
        self.open_menu.set_sensitive(bool(closed))
        self.stack.set_visible_child_name(self.active or "empty")
        self.fill_main_menu(self.main_menu)
        self.update_status()

    def update_status(self):
        if not hasattr(self, "status_label"):
            return
        wsid = self.active
        zoomed = bool(wsid and wsid in self.zoomed_groups)
        self.restore_button.set_visible(zoomed)
        action = self.lookup_action("restore-layout")
        if action:
            action.set_enabled(zoomed)
        if not wsid:
            self.status_label.set_text("Create a workspace to get started.")
            self.shortcut_label.set_text("Ctrl+Shift+N  New workspace")
            self.set_title("MultiTerminal")
            return
        ws = self.store.workspace(wsid)
        self.set_title(ws["name"] + " · MultiTerminal")
        g = next((g for g in groups(ws["layout"]) if g["id"] == ws["focusedGroupID"]), None)
        if g:
            p = self.store.pane(wsid, g["selectedPaneID"])
            if p["kind"] == "terminal":
                path = self.short_path(p["directoryPath"])
                text = "Terminal · Start folder: " + path
            elif p["kind"] == "browser":
                text = "Browser · " + (p["url"] or "Enter an address to get started")
            else:
                text = "Live preview · " + (self.short_path(p["path"]) if p["path"] else "Choose a file")
            self.status_label.set_text(text)
            self.status_label.set_tooltip_text(text)
        else:
            self.status_label.set_text("Add a pane to this workspace.")
        self.shortcut_label.set_text("Escape  Restore layout" if zoomed else "Ctrl+Shift+Enter  Focus pane")

    @staticmethod
    def short_path(path):
        home = str(Path.home())
        return "~" + path[len(home):] if path == home or path.startswith(home + "/") else path

    def switch_workspace(self, wsid):
        if wsid == self.active:
            return
        if self.perform(lambda: self.store.open(wsid)):
            for identifier, row in self.workspace_rows.items():
                row.add_css_class("active") if identifier == wsid else row.remove_css_class("active")
            self.stack.set_visible_child_name(wsid)
            self.fill_main_menu(self.main_menu)
            self.update_status()
            self.focus_selected(wsid)

    def cycle_workspace(self, direction):
        opened = self.store.state["openWorkspaceIDs"]
        if opened:
            index = opened.index(self.active) if self.active in opened else 0
            self.switch_workspace(opened[(index + direction) % len(opened)])

    def new_workspace(self, name=None, directory=None):
        created = []
        if self.perform(lambda: created.append(self.store.create(name, directory))):
            self.render(created[0])
            self.sync_tabs()
            self.focus_selected(created[0])
            return created[0]
        return None

    def open_workspace(self, wsid):
        if self.perform(lambda: self.store.open(wsid)):
            if wsid not in self.pages:
                self.render(wsid)
            self.sync_tabs()
            self.focus_selected(wsid)

    def prompt_workspace(self):
        return self.workspace_dialog()

    def rename_workspace(self, wsid=None):
        wsid = wsid or self.active
        if wsid:
            return self.workspace_dialog(wsid)
        return None

    def workspace_dialog(self, wsid=None):
        creating = wsid is None
        dialog = Gtk.Dialog(title="New Workspace" if creating else "Rename Workspace", transient_for=self, modal=True)
        dialog.set_default_size(420, -1)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        accept = dialog.add_button("Create Workspace" if creating else "Save Name", Gtk.ResponseType.ACCEPT)
        accept.add_css_class("suggested-action")
        dialog.set_default_response(Gtk.ResponseType.ACCEPT)
        form = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        form.add_css_class("workspace-form")
        form.append(Gtk.Label(label="Workspace name", xalign=0))
        name = self.store.workspace(wsid)["name"] if wsid else f"Workspace {len(self.store.state['workspaces']) + 1}"
        entry = Gtk.Entry(text=name, placeholder_text="Project name", activates_default=True, hexpand=True)
        entry.connect("changed", lambda e: accept.set_sensitive(bool(e.get_text().strip())))
        form.append(entry)
        folder = {"path": str(Path.home())}
        if creating:
            form.append(Gtk.Label(label="Start folder", xalign=0))
            choose = Gtk.Button(label=self.short_path(folder["path"]))
            choose.set_tooltip_text("The first terminal starts in this folder")
            def selected(path):
                folder["path"] = path
                choose.set_label(self.short_path(path))
                if entry.get_text().startswith("Workspace "):
                    entry.set_text(Path(path).name or "Workspace")
            choose.connect("clicked", lambda _b: self.choose_file(selected, folder=True, parent=dialog))
            form.append(choose)
        dialog.get_content_area().append(form)
        def response(_dialog, code):
            chosen_name = entry.get_text().strip()
            dialog.destroy()
            if code == Gtk.ResponseType.ACCEPT and chosen_name:
                if creating:
                    self.new_workspace(chosen_name, folder["path"])
                elif self.perform(lambda: self.store.edit(wsid, lambda ws: ws.update(name=chosen_name))):
                    self.sync_tabs()
        dialog.connect("response", response)
        dialog.present()
        entry.grab_focus()
        entry.select_region(0, -1)
        return dialog

    def request_close_workspace(self, wsid=None):
        wsid = wsid or self.active
        if not wsid:
            return
        terminals = [p for (w, _), p in self.panes.items() if w == wsid and isinstance(p, TerminalPane) and p.has_running_job()]
        if terminals:
            self.confirm("Close workspace?", "Its terminal sessions and running jobs will stop. The workspace remains saved.", lambda: self.close_workspace(wsid))
        else:
            self.close_workspace(wsid)

    def request_delete_workspace(self):
        wsid = self.active
        if wsid:
            self.confirm("Delete workspace?", "Terminal sessions will stop, and this workspace's settings and browser profile will be removed. Project files are kept.", lambda: self.close_workspace(wsid, delete=True), "Delete")

    def close_workspace(self, wsid, delete=False):
        if not self.perform(lambda: self.store.close(wsid, delete)):
            return
        self.cancel_split_saves(wsid)
        for key in [key for key in self.panes if key[0] == wsid]:
            self.panes.pop(key).close()
            self.labels.pop(key, None)
        if wsid in self.pages:
            self.stack.remove(self.pages.pop(wsid))
        self.sessions.pop(wsid, None)
        self.group_widgets.pop(wsid, None)
        self.group_stacks.pop(wsid, None)
        self.group_menus.pop(wsid, None)
        self.zoomed_groups.pop(wsid, None)
        for key in [key for key in self.tab_rows if key[0] == wsid]:
            self.tab_rows.pop(key)
        if delete:
            for path in self.profile_paths(wsid):
                if path.exists():
                    self.perform(lambda p=path: shutil.rmtree(p))
        self.sync_tabs()

        if self.active:
            self.focus_selected(self.active)

    def add_pane(self, kind, edge=None, as_tab=False, wsid=None, target=None, value="", related_view=None):
        wsid = wsid or self.active
        if not wsid:
            self.new_workspace()
            wsid = self.active
        if not wsid:
            return None
        if kind == "filePreview" and not value:
            self.choose_file(lambda path: self.add_pane(kind, edge, as_tab, wsid, target, path))
            return None
        if edge is None:
            ws = self.store.workspace(wsid)
            gid = target or ws["focusedGroupID"]
            region = self.group_widgets.get(wsid, {}).get(gid)
            edge = "bottom" if region and region.get_height() > region.get_width() else "right"
        if kind == "terminal" and not value:
            ws = self.store.workspace(wsid)
            focused = next((g for g in groups(ws["layout"]) if g["id"] == (target or ws["focusedGroupID"])), None)
            source = self.store.pane(wsid, focused["selectedPaneID"]) if focused else None
            if not source or source["kind"] != "terminal":
                source = next((p for p in ws["panes"] if p["kind"] == "terminal"), None)
            if source:
                value = source["directoryPath"]
        p = pane(kind, value)
        if self.perform(lambda: self.store.add(wsid, p, target, edge, as_tab)):
            if related_view is not None and kind == "browser":
                self.panes[(wsid, p["id"])] = BrowserPane(self, wsid, p["id"], related_view=related_view)
            if not as_tab:
                self.zoomed_groups.pop(wsid, None)
            self.render(wsid)
            self.sync_tabs()
            self.focus_content(self.panes[(wsid, p["id"])])
            return self.panes[(wsid, p["id"])]
        return None

    def add_browser_tab(self, wsid, source, related_view=None):
        target = next(g["id"] for g in groups(self.store.workspace(wsid)["layout"]) if source in g["paneIDs"])
        return self.add_pane("browser", as_tab=True, wsid=wsid, target=target, related_view=related_view)

    def request_close_active_pane(self):
        if self.active:
            ws = self.store.workspace(self.active)
            g = next((g for g in groups(ws["layout"]) if g["id"] == ws["focusedGroupID"]), None)
            if g:
                self.request_close_pane(self.active, g["selectedPaneID"])

    def request_close_pane(self, wsid, pid):
        content = self.panes[(wsid, pid)]
        if isinstance(content, TerminalPane) and content.has_running_job():
            self.confirm("Close terminal?", "Its shell and running jobs will stop.", lambda: self.close_pane(wsid, pid))
        else:
            self.close_pane(wsid, pid)

    def close_pane(self, wsid, pid):
        if (wsid, pid) not in self.panes:
            return
        if self.perform(lambda: self.store.remove(wsid, pid)):
            content = self.panes.pop((wsid, pid))
            content.close()
            self.detach(content.widget)
            self.labels.pop((wsid, pid), None)
            self.render(wsid)
            if wsid == self.active:
                self.focus_selected(wsid)

    def set_theme(self, theme):
        if self.perform(lambda: self.store.commit(lambda s: s.update(globalTheme=theme))):
            for content in self.panes.values():
                if isinstance(content, TerminalPane):
                    content.apply_theme()
            self.fill_main_menu(self.main_menu)

    def theme_pane(self, wsid, pid, theme):
        if self.perform(lambda: self.store.update_pane(wsid, pid, themeOverride=theme)):
            self.panes[(wsid, pid)].apply_theme()
            g = next(g for g in groups(self.store.workspace(wsid)["layout"]) if pid in g["paneIDs"])
            menu = self.group_menus.get(wsid, {}).get(g["id"])
            if menu:
                self.fill_pane_menu(menu, wsid, g["id"])

    def focus_pane(self, wsid, pid):
        if self.rebuilding or self.closing or (wsid, pid) not in self.panes:
            return
        ws = self.store.workspace(wsid)
        current = next(g for g in groups(ws["layout"]) if pid in g["paneIDs"])
        if ws["focusedGroupID"] != current["id"]:
            self.perform(lambda: self.store.select(wsid, pid))
            self.highlight_groups(wsid)
            self.update_status()

    def select_pane(self, wsid, pid):
        if self.perform(lambda: self.store.select(wsid, pid)):
            selected = next(g for g in groups(self.store.workspace(wsid)["layout"]) if pid in g["paneIDs"])
            stack = self.group_stacks.get(wsid, {}).get(selected["id"])
            if stack:
                stack.set_visible_child_name(pid)
            for sibling in selected["paneIDs"]:
                row = self.tab_rows.get((wsid, sibling))
                if row:
                    row.add_css_class("active") if sibling == pid else row.remove_css_class("active")
            menu = self.group_menus.get(wsid, {}).get(selected["id"])
            if menu:
                self.fill_pane_menu(menu, wsid, selected["id"])
            self.highlight_groups(wsid)
            self.update_status()
            self.focus_content(self.panes[(wsid, pid)])

    @staticmethod
    def focus_content(content):
        if isinstance(content, TerminalPane):
            content.terminal.grab_focus()
        elif isinstance(content, BrowserPane):
            (content.web if content.model["url"] else content.address).grab_focus()
        else:
            content.web.grab_focus()

    def focus_selected(self, wsid):
        ws = self.store.workspace(wsid)
        g = next((g for g in groups(ws["layout"]) if g["id"] == ws["focusedGroupID"]), None)
        if g and (wsid, g["selectedPaneID"]) in self.panes:
            self.focus_content(self.panes[(wsid, g["selectedPaneID"])])

    def resize_text(self, delta=0, reset=False):
        current = self.store.state.get("terminalFontSize", 11)
        size = 11 if reset else max(8, min(24, current + delta))
        if size == current:
            return
        if self.perform(lambda: self.store.commit(lambda state: state.update(terminalFontSize=size))):
            for content in self.panes.values():
                if isinstance(content, TerminalPane):
                    content.set_font_size(size)

    def toggle_zoom(self):
        if self.active:
            ws = self.store.workspace(self.active)
            if ws["focusedGroupID"]:
                self.zoom_group(self.active, ws["focusedGroupID"])

    def zoom_group(self, wsid, gid):
        if self.zoomed_groups.get(wsid) == gid:
            self.restore_layout(wsid)
            return
        gs = groups(self.store.workspace(wsid)["layout"])
        if len(gs) < 2:
            return
        selected = next((g for g in gs if g["id"] == gid), None)
        if selected and self.perform(lambda: self.store.select(wsid, selected["selectedPaneID"])):
            self.zoomed_groups[wsid] = gid
            self.render(wsid)
            self.update_status()
            self.focus_selected(wsid)

    def restore_layout(self, wsid=None):
        wsid = wsid or self.active
        if wsid in self.zoomed_groups:
            self.zoomed_groups.pop(wsid)
            self.render(wsid)
            self.update_status()
            self.focus_selected(wsid)

    def highlight_groups(self, wsid):
        focused = self.store.workspace(wsid)["focusedGroupID"]
        for gid, widget in self.group_widgets.get(wsid, {}).items():
            widget.add_css_class("focused") if gid == focused else widget.remove_css_class("focused")

    @staticmethod
    def detach(widget):
        parent = widget.get_parent()
        if isinstance(parent, (Gtk.Stack, Gtk.Box)):
            parent.remove(widget)

    def render(self, wsid):
        self.rebuilding = True
        self.cancel_split_saves(wsid, flush=True)
        for (w, _pid), content in self.panes.items():
            if w == wsid:
                self.detach(content.widget)
        if wsid not in self.pages:
            self.pages[wsid] = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, hexpand=True, vexpand=True)
            self.pages[wsid].add_css_class("workspace-body")
            self.stack.add_named(self.pages[wsid], wsid)
        page = self.pages[wsid]
        child = page.get_first_child()
        while child:
            page.remove(child)
            child = page.get_first_child()
        self.group_widgets[wsid] = {}
        self.group_stacks[wsid] = {}
        self.group_menus[wsid] = {}
        for key in [key for key in self.tab_rows if key[0] == wsid]:
            self.tab_rows.pop(key)
        ws = self.store.workspace(wsid)
        if ws["layout"]:
            zoomed = next((g for g in groups(ws["layout"]) if g["id"] == self.zoomed_groups.get(wsid)), None)
            if not zoomed:
                self.zoomed_groups.pop(wsid, None)
            page.append(self.build_node(wsid, zoomed or ws["layout"]))
        else:
            page.append(Gtk.Label(label="This workspace is empty. Use New Terminal or Add Pane to get started.", hexpand=True, vexpand=True, wrap=True))
        self.highlight_groups(wsid)
        self.rebuilding = False
        self.update_status()

    def build_node(self, wsid, node):
        if node["type"] == "split":
            horizontal = node["axis"] == "horizontal"
            widget = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL if horizontal else Gtk.Orientation.VERTICAL, hexpand=True, vexpand=True)
            widget.set_start_child(self.build_node(wsid, node["first"]))
            widget.set_end_child(self.build_node(wsid, node["second"]))
            widget.set_resize_start_child(True)
            widget.set_resize_end_child(True)
            widget.set_shrink_start_child(False)
            widget.set_shrink_end_child(False)
            # Restore percentages once allocated, then preserve them when the
            # window changes size. Only user divider moves are persisted.
            sizing = {"size": 0, "setting": False, "percent": node["firstPercent"]}
            def allocated(_widget, _clock):
                extent = widget.get_width() if horizontal else widget.get_height()
                if extent > 6 and extent != sizing["size"]:
                    sizing["size"] = extent
                    sizing["setting"] = True
                    widget.set_position(round((extent - 6) * sizing["percent"] / 100))
                    sizing["setting"] = False
                return True
            widget.add_tick_callback(allocated)
            def position(_widget, _spec):
                extent = (widget.get_width() if horizontal else widget.get_height()) - 6
                if self.rebuilding or sizing["setting"] or extent <= 0:
                    return
                percentage = max(5.0, min(95.0, 100 * widget.get_position() / extent))
                sizing["percent"] = percentage
                self.save_split_later(wsid, node["id"], percentage)
            widget.connect("notify::position", position)
            return widget
        container = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, hexpand=True, vexpand=True)
        container.add_css_class("pane-group")
        self.group_widgets[wsid][node["id"]] = container
        tabs = Gtk.Box(spacing=2)
        tabs.add_css_class("pane-tabs")
        content_stack = Gtk.Stack(hexpand=True, vexpand=True)
        content_stack.set_transition_type(Gtk.StackTransitionType.NONE)
        self.group_stacks[wsid][node["id"]] = content_stack
        for pid in node["paneIDs"]:
            p = self.store.pane(wsid, pid)
            key = (wsid, pid)
            if key not in self.panes:
                self.panes[key] = PANE_CLASSES[p["kind"]](self, wsid, pid)
            content_stack.add_named(self.panes[key].widget, pid)
            row = Gtk.Box()
            row.add_css_class("pane-tab")
            self.tab_rows[key] = row
            if pid == node["selectedPaneID"]:
                row.add_css_class("active")
            label = Gtk.Label(label=pane_title(p), ellipsize=Pango.EllipsizeMode.END, max_width_chars=20)
            self.labels[key] = label
            select = Gtk.Button()
            tab_content = Gtk.Box(spacing=6)
            icon_name = {"terminal": "utilities-terminal-symbolic", "browser": "web-browser-symbolic", "filePreview": "text-x-generic-symbolic"}[p["kind"]]
            icon = Gtk.Image.new_from_icon_name(icon_name)
            icon.add_css_class("pane-type-icon")
            tab_content.append(icon)
            tab_content.append(label)
            select.set_child(tab_content)
            location = p.get("directoryPath") or p.get("path") or p.get("url") or "Browser"
            select.set_tooltip_text(location + "\nDrag to an edge to split, or to the center to group into tabs.")
            select.connect("clicked", lambda _b, i=pid: self.select_pane(wsid, i))
            source = Gtk.DragSource(actions=Gdk.DragAction.MOVE)
            source.connect("prepare", lambda _s, _x, _y, i=pid: Gdk.ContentProvider.new_for_value(f"{wsid}:{i}"))
            select.add_controller(source)
            reorder = Gtk.DropTarget.new(GObject.TYPE_STRING, Gdk.DragAction.MOVE)
            reorder.connect("drop", lambda _d, value, _x, _y, i=pid: self.drop(value, wsid, node["id"], before=i))
            select.add_controller(reorder)
            row.append(select)
            row.append(button("window-close-symbolic", "Close pane", lambda i=pid: self.request_close_pane(wsid, i)))
            tabs.append(row)
        header = Gtk.Box(spacing=3)
        header.add_css_class("pane-header")
        scroll = Gtk.ScrolledWindow(hexpand=True)
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER)
        scroll.set_child(tabs)
        header.append(scroll)
        add = Gtk.MenuButton(icon_name="list-add-symbolic", tooltip_text="Add a tab to this group")
        add.add_css_class("icon-button")
        self.add_popover(add, wsid, node["id"])
        header.append(add)
        split = Gtk.MenuButton(label="Split", tooltip_text="Create a terminal beside or below this pane")
        split.add_css_class("flat")
        self.popover(split, [("Split right", lambda: self.add_pane("terminal", edge="right", wsid=wsid, target=node["id"])), ("Split below", lambda: self.add_pane("terminal", edge="bottom", wsid=wsid, target=node["id"]))])
        header.append(split)
        zoomed = self.zoomed_groups.get(wsid) == node["id"]
        zoom = button("view-restore-symbolic" if zoomed else "view-fullscreen-symbolic", "Restore layout · Escape" if zoomed else "Focus this pane · Ctrl+Shift+Enter", lambda: self.zoom_group(wsid, node["id"]))
        zoom.set_sensitive(zoomed or len(groups(self.store.workspace(wsid)["layout"])) > 1)
        header.append(zoom)
        menu = Gtk.MenuButton(icon_name="view-more-symbolic", tooltip_text="Folder, clipboard, theme and pane actions")
        menu.add_css_class("icon-button")
        self.group_menus[wsid][node["id"]] = menu
        self.fill_pane_menu(menu, wsid, node["id"])
        header.append(menu)
        container.append(header)
        container.append(content_stack)
        content_stack.set_visible_child_name(node["selectedPaneID"])
        drop = Gtk.DropTarget.new(GObject.TYPE_STRING, Gdk.DragAction.MOVE)
        drop.connect("motion", lambda _d, x, y: self.drag_motion(container, x, y))
        drop.connect("leave", lambda _d: self.clear_dock(container))
        def dropped(_d, value, x, y):
            edge = self.drop_edge(container, x, y)
            self.clear_dock(container)
            return self.drop(value, wsid, node["id"], edge=edge)
        drop.connect("drop", dropped)
        container.add_controller(drop)
        return container

    def fill_pane_menu(self, menu, wsid, gid):
        g = next((g for g in groups(self.store.workspace(wsid)["layout"]) if g["id"] == gid), None)
        if not g:
            return
        pid = g["selectedPaneID"]
        terminal = self.store.pane(wsid, pid)["kind"] == "terminal"
        entries = []
        if terminal:
            content = self.panes[(wsid, pid)]
            entries.extend([("Copy  ·  Ctrl+Shift+C", content.copy), ("Paste  ·  Ctrl+Shift+V", content.paste), ("Change start folder…", content.choose_directory), ("Restart shell", content.restart), ("Open start folder", lambda: external(self, Path(self.store.pane(wsid, pid)["directoryPath"]).expanduser().as_uri())), ("", None)])
        entries.extend([("New terminal tab", lambda: self.add_pane("terminal", as_tab=True, wsid=wsid, target=gid)), ("New browser tab", lambda: self.add_pane("browser", as_tab=True, wsid=wsid, target=gid)), ("New file preview tab", lambda: self.add_pane("filePreview", as_tab=True, wsid=wsid, target=gid)), ("", None)])
        for edge in ("right", "bottom"):
            entries.append(("Split " + edge + " with terminal", lambda e=edge: self.add_pane("terminal", edge=e, wsid=wsid, target=gid)))
        for dest in groups(self.store.workspace(wsid)["layout"]):
            for edge in (None, "left", "right", "top", "bottom"):
                if dest["id"] == gid and (edge is None or len(g["paneIDs"]) == 1):
                    continue
                name = pane_title(self.store.pane(wsid, dest["selectedPaneID"]))
                entries.append((f"Move pane {'as tab in' if edge is None else edge + ' of'} {name}", lambda d=dest["id"], e=edge: self.dock(wsid, pid, d, e)))
        if terminal:
            entries.append(("", None))
            chosen = self.store.pane(wsid, pid).get("themeOverride")
            for label, theme in (("Follow workspace theme", None), ("Midnight", "midnight"), ("High Contrast", "highContrast"), ("Amber", "amber")):
                entries.append((("✓ " if chosen == theme else "") + label, lambda t=theme: self.theme_pane(wsid, pid, t)))
        entries.extend([("", None), ("Close pane", lambda: self.request_close_pane(wsid, pid))])
        self.popover(menu, entries)

    @staticmethod
    def drop_edge(widget, x, y):
        width, height = max(1, widget.get_width()), max(1, widget.get_height())
        if x / width < .22:
            return "left"
        if x / width > .78:
            return "right"
        if y / height < .22:
            return "top"
        if y / height > .78:
            return "bottom"
        return None

    @staticmethod
    def clear_dock(widget):
        for edge in ("center", "left", "right", "top", "bottom"):
            widget.remove_css_class("dock-" + edge)

    def drag_motion(self, widget, x, y):
        self.clear_dock(widget)
        widget.add_css_class("dock-" + (self.drop_edge(widget, x, y) or "center"))
        return Gdk.DragAction.MOVE

    def drop(self, value, wsid, target, edge=None, before=None):
        try:
            origin, pid = value.split(":", 1)
            if origin != wsid or (wsid, pid) not in self.panes:
                return False
            return self.dock(wsid, pid, target, edge, before)
        except (ValueError, AttributeError):
            return False

    def dock(self, wsid, pid, target, edge=None, before=None):
        if self.perform(lambda: self.store.dock(wsid, pid, target, edge, before)):
            self.zoomed_groups.pop(wsid, None)
            self.render(wsid)
            if wsid == self.active:
                self.focus_selected(wsid)
            return True
        return False

    def save_split_later(self, wsid, nodeid, percentage):
        key = (wsid, nodeid)
        if key in self.split_timers:
            GLib.source_remove(self.split_timers[key][0])
        self.split_timers[key] = (GLib.timeout_add(200, self.flush_split, key), percentage)

    def flush_split(self, key):
        _timer, percent = self.split_timers.pop(key)
        wsid, nodeid = key
        def change(ws):
            node = next((n for n in nodes(ws["layout"]) if n["id"] == nodeid), None)
            if node and node["type"] == "split":
                node["firstPercent"] = percent
        self.perform(lambda: self.store.edit(wsid, change))
        return False

    def cancel_split_saves(self, wsid, flush=False):
        for key in [k for k in self.split_timers if k[0] == wsid]:
            GLib.source_remove(self.split_timers[key][0])
            if flush:
                self.flush_split(key)
            else:
                self.split_timers.pop(key)

    def update_labels(self):
        for (wsid, pid), label in self.labels.items():
            if (wsid, pid) in self.panes:
                label.set_text(pane_title(self.store.pane(wsid, pid)))
        self.update_status()

    @staticmethod
    def profile_paths(wsid):
        cached = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "multiterminal-source/browsers" / wsid
        return data_home() / "browsers" / wsid, cached

    def browser_session(self, wsid):
        if wsid not in self.sessions:
            paths = self.profile_paths(wsid)
            for path in paths:
                path.mkdir(parents=True, exist_ok=True, mode=0o700)
            session = WebKit.NetworkSession.new(*(str(p) for p in paths))
            session.get_cookie_manager().set_persistent_storage(str(paths[0] / "cookies.sqlite"), WebKit.CookiePersistentStorage.SQLITE)
            session.connect("download-started", self.download)
            self.sessions[wsid] = session
        return self.sessions[wsid]

    def download(self, _session, download):
        # Hand downloads to the user's browser, which already has download UI.
        uri = download.get_request().get_uri()
        download.cancel()
        self.confirm("Open download in your browser?", "Downloads are handled by your default browser.", lambda: external(self, uri), "Open browser")

    def help(self):
        self.error("Ctrl+Shift+N: new workspace\nCtrl+Shift+T: new terminal\nCtrl+Shift+B: new browser\nCtrl+Shift+W: close pane\nCtrl+Shift+Q: close workspace\nCtrl+Page Up / Down: switch workspace\nCtrl+Shift+C / V: terminal copy / paste\nF2: rename workspace\nCtrl+Q: quit\nCtrl+Shift+Enter: focus this pane\nEscape: restore the layout\nCtrl++ / Ctrl+− / Ctrl+0: terminal text size\n\nDouble-click a workspace tab to rename it. Use Split to add a terminal beside or below a pane. Drag pane tabs to a group's edge to split, its center to group, or another tab to reorder. The pane menu provides the same move actions. Workspaces save automatically. Switching workspaces keeps sessions running; reopening closed workspaces starts fresh shells. Folder changes apply after restarting the shell. Idle shells close directly; closing running jobs asks first.\n\nMarkdown, HTML, text and images refresh after file changes. Preview scripts are disabled. PDF and other formats open in their default app. Browser downloads open in your default browser. This source build has no automatic updater.")

    def about(self):
        dialog = Gtk.AboutDialog(transient_for=self, modal=True, program_name="MultiTerminal", version=f"{__version__}-{__linux_revision__}", comments="Your whole stack. One native Linux workspace.", copyright="© 2026 Ali Alnoaimi", authors=["Ali Alnoaimi"], license_type=Gtk.License.AGPL_3_0_ONLY, license="AGPL-3.0-only. See LICENSE at the source repository root.", logo_icon_name="ac.multiterminal")
        dialog.present()

    def close_requested(self, _window):
        if not self._quit_confirmed and any(isinstance(p, TerminalPane) and p.has_running_job() for p in self.panes.values()):
            self.confirm("Quit MultiTerminal?", "Terminal sessions and running jobs will stop. Your workspace configuration remains saved.", self.confirm_quit, "Quit")
            return True
        self.shutdown()
        return False

    def confirm_quit(self):
        self._quit_confirmed = True
        self.close()

    def shutdown(self):
        if self.closing:
            return
        self.closing = True
        for wsid in list(self.pages):
            self.cancel_split_saves(wsid, flush=True)
        for content in self.panes.values():
            content.close()
        READERS.shutdown(wait=False, cancel_futures=True)


class Application(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="ac.multiterminal.source", flags=Gio.ApplicationFlags.DEFAULT_FLAGS)
        self.window = None
        self.connect("activate", self.activate_app)
        self.connect("shutdown", self.shutdown_app)

    def activate_app(self, _app):
        if self.window:
            self.window.present()
            return
        provider = Gtk.CssProvider()
        provider.load_from_string(CSS)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        Gtk.Settings.get_default().set_property("gtk-application-prefer-dark-theme", True)
        try:
            store = Store()
            if not store.state["workspaces"]:
                store.create()
            self.window = Window(self, store)
            self.window.present()
            if self.window.active:
                self.window.focus_selected(self.window.active)
        except (OSError, ValueError) as exc:
            # Keep invalid/inaccessible configuration intact; never silently reset.
            window = Gtk.ApplicationWindow(application=self, title="MultiTerminal", default_width=620, default_height=240)
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=20)
            for side in ("top", "bottom", "start", "end"):
                getattr(box, "set_margin_" + side)(24)
            box.append(Gtk.Label(label=str(exc), wrap=True, selectable=True))
            box.append(button("application-exit-symbolic", "Quit", self.quit))
            window.set_child(box)
            window.present()
            self.window = window

    def shutdown_app(self, _app):
        if isinstance(self.window, Window):
            self.window.shutdown()

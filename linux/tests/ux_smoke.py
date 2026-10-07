"""Native UX behavior: focus, idle vs busy close, stable tabs and workspace dialogs."""
from copy import deepcopy
import os
from pathlib import Path
import shlex
import sys
import tempfile
import traceback

from smoke import pump, wait, ERRORS
from multiterminal.app import Application, Window
from multiterminal.model import Store, groups
from multiterminal.native import Gtk
from multiterminal.panes import TerminalPane


def descendants(widget):
    yield widget
    child = widget.get_first_child()
    while child:
        yield from descendants(child)
        child = child.get_next_sibling()


def main():
    with tempfile.TemporaryDirectory(prefix="multiterminal-ux-") as folder:
        temporary = Path(folder)
        os.environ["MULTITERMINAL_WORKSPACE_FILE"] = str(temporary / "config/workspaces.json")
        os.environ["XDG_DATA_HOME"] = str(temporary / "data")
        os.environ["XDG_CACHE_HOME"] = str(temporary / "cache")
        project = temporary / "supernotes"
        project.mkdir()
        store = Store()
        wsid = store.create("Supernotes", directory=str(project))
        app = Application()
        app.register(None)
        app.activate()
        window = app.window
        assert isinstance(window, Window)
        window.error = lambda message: (_ for _ in ()).throw(AssertionError(message))
        confirmations = []
        window.confirm = lambda title, detail, callback, accept="Close": confirmations.append((title, callback))
        first = next(iter(window.panes.values()))
        wait(lambda: first.pid_child is not None and not first.has_running_job(), "Initial shell did not become idle")
        first_pid = first.pid_child
        assert window.get_focus() is first.terminal, "The initial terminal did not receive keyboard focus"
        assert not first.toolbar.get_visible(), "Terminals still have a duplicate action toolbar"
        assert not window.lookup_action("restore-layout").get_enabled(), "Escape must remain available to terminal programs outside focus mode"

        first_group = next(iter(window.group_widgets[wsid].values()))
        split = next(w for w in descendants(first_group) if isinstance(w, Gtk.MenuButton) and w.get_label() == "Split")
        split.get_popover().popup()
        pump(timeout=.1)
        next(w for w in descendants(split.get_popover()) if isinstance(w, Gtk.Button) and w.get_label() == "Split right").emit("clicked")
        second = next(p for p in window.panes.values() if p is not first)
        wait(lambda: second.pid_child is not None and not second.has_running_job(), "Split shell did not become idle")
        assert second.model["directoryPath"] == str(project), "Split terminal lost the project start folder"
        second_pid = second.pid_child
        layout = deepcopy(window.store.workspace(wsid)["layout"])
        group_id = next(g["id"] for g in groups(layout) if second.pid in g["paneIDs"])
        window.zoom_group(wsid, group_id)
        pump(timeout=.3)
        assert window.restore_button.get_visible()
        assert window.lookup_action("restore-layout").get_enabled()
        assert len(window.group_widgets[wsid]) == 1
        assert first.pid_child == first_pid and second.pid_child == second_pid
        assert window.store.workspace(wsid)["layout"] == layout, "Focus mode changed the saved layout"
        window.lookup_action("restore-layout").activate(None)
        pump(timeout=.3)
        assert len(window.group_widgets[wsid]) == 2
        assert not window.restore_button.get_visible()
        assert not window.lookup_action("restore-layout").get_enabled()
        assert first.pid_child == first_pid and second.pid_child == second_pid
        print("PASS: pane focus/restore keeps every shell alive and leaves layout intact", flush=True)

        add = next(w for w in descendants(window.group_widgets[wsid][group_id]) if isinstance(w, Gtk.MenuButton) and w.get_icon_name() == "list-add-symbolic")
        add.get_popover().popup()
        pump(timeout=.1)
        terminal_button = next(w for w in descendants(add.get_popover()) if isinstance(w, Gtk.Button) and any(isinstance(child, Gtk.Label) and child.get_text() == "Terminal" for child in descendants(w)))
        terminal_button.emit("clicked")
        third = next(p for p in window.panes.values() if p not in (first, second))
        wait(lambda: third.pid_child is not None and not third.has_running_job(), "Tabbed shell did not become idle")
        parent = second.widget.get_parent()
        header = window.group_widgets[wsid][group_id]
        window.select_pane(wsid, second.pid)
        assert second.widget.get_parent() is parent
        assert window.group_widgets[wsid][group_id] is header, "Selecting a tab rebuilt the pane UI"
        assert window.get_focus() is second.terminal, "Selected terminal did not receive keyboard focus"
        assert second.pid_child == second_pid
        window.select_pane(wsid, third.pid)
        assert third.widget.get_parent() is parent
        window.request_close_pane(wsid, third.pid)
        assert not confirmations, "Closing an idle shell asked for confirmation"
        wait(lambda: third.pid_child is None, "Idle shell was not reaped")
        assert window.get_focus() is second.terminal, "Closing a tab lost focus in its surviving group"
        print("PASS: switching tabs avoids reparenting; idle terminal closes immediately", flush=True)

        window.lookup_action("larger-text").activate(None)
        assert Store().state["terminalFontSize"] == 12
        assert first.terminal.get_font().get_size() == 12 * 1024
        window.lookup_action("reset-text").activate(None)
        assert Store().state["terminalFontSize"] == 11
        print("PASS: terminal text zoom applies to live shells and persists", flush=True)

        dialog = window.prompt_workspace()
        entry = next(w for w in descendants(dialog) if isinstance(w, Gtk.Entry))
        entry.set_text("   ")
        assert not dialog.get_widget_for_response(Gtk.ResponseType.ACCEPT).get_sensitive(), "Blank workspace name was allowed"
        entry.set_text("Client project")
        dialog.response(Gtk.ResponseType.CANCEL)
        assert len(window.store.state["workspaces"]) == 1
        dialog = window.prompt_workspace()
        entry = next(w for w in descendants(dialog) if isinstance(w, Gtk.Entry))
        entry.set_text("Client project")
        dialog.response(Gtk.ResponseType.ACCEPT)
        client_wsid = window.active
        client = next(p for (w, _), p in window.panes.items() if w == client_wsid)
        wait(lambda: client.pid_child is not None and not client.has_running_job(), "New workspace shell did not become idle")
        assert window.get_focus() is client.terminal, "Created workspace did not receive keyboard focus"
        assert window.store.workspace(client_wsid)["name"] == "Client project"
        rename = window.rename_workspace(client_wsid)
        entry = next(w for w in descendants(rename) if isinstance(w, Gtk.Entry))
        entry.set_text("Client API")
        rename.response(Gtk.ResponseType.ACCEPT)
        assert Store().workspace(client_wsid)["name"] == "Client API"
        assert client.pid_child is not None
        window.request_close_workspace(client_wsid)
        wait(lambda: client.pid_child is None, "Closed workspace shell was not reaped")
        assert not confirmations
        assert window.open_menu.get_sensitive()
        assert isinstance(window.get_focus(), type(first.terminal)), "Closing a workspace lost terminal focus"
        window.switch_workspace(wsid)
        print("PASS: workspace naming/cancel/rename flow and reopening affordance", flush=True)

        job_file = temporary / "foreground-job.txt"
        command = f"echo $$ > {shlex.quote(str(job_file))}; exec sleep 120"
        second.terminal.feed_child(f"sh -c {shlex.quote(command)}\n".encode())
        wait(lambda: job_file.exists() and second.has_running_job(), "Foreground job was not detected")
        window.request_close_pane(wsid, second.pid)
        assert len(confirmations) == 1, "Closing a foreground job did not ask first"
        assert second.pid_child == second_pid
        confirmations.clear()
        second.terminal.feed_child(b"\x03")
        wait(lambda: not second.has_running_job(), "Interrupted shell did not return idle")
        bg_file = temporary / "background-job.txt"
        second.terminal.feed_child(f"sleep 120 & echo $! > {shlex.quote(str(bg_file))}\n".encode())
        wait(lambda: bg_file.exists() and second.has_running_job(), "Background job was not detected")
        window.request_close_workspace(wsid)
        assert len(confirmations) == 1, "Closing a background job did not ask first"
        second.terminal.feed_child(f"kill {bg_file.read_text().strip()}\n".encode())
        wait(lambda: not second.has_running_job(), "Background job did not stop")
        confirmations.clear()
        print("PASS: foreground and background jobs still require close confirmation", flush=True)

        # Use the genuine folder workflow, substituting only the OS picker.
        new_folder = temporary / "API project"
        new_folder.mkdir()
        window.choose_file = lambda callback, **_kw: callback(str(new_folder))
        first.choose_directory()
        assert first.status_action.get_visible()
        assert first.status_action.get_label() == "Restart here"
        first.status_action.emit("clicked")
        wait(lambda: first.pid_child is not None and first.pid_child != first_pid and not first.has_running_job(), "Apply folder did not restart the idle shell")
        cwd_file = temporary / "new-cwd.txt"
        first.terminal.feed_child(f"pwd > {shlex.quote(str(cwd_file))}\n".encode())
        wait(lambda: cwd_file.exists() and cwd_file.read_text().strip() == str(new_folder), "New shell did not use selected start folder")
        assert not confirmations
        assert not first.status_box.get_visible()
        assert second.pid_child == second_pid
        print("PASS: saved folder offers Restart here and applies without disturbing other shells", flush=True)

        window.select_pane(wsid, first.pid)
        window.theme_pane(wsid, first.pid, "amber")
        screenshot = os.environ.get("MULTITERMINAL_TEST_SCREENSHOT")
        if screenshot:
            from capture import capture
            pump(timeout=.6)
            capture(screenshot)
            window.add_menu.get_popover().popup()
            pump(timeout=.3)
            capture(str(Path(screenshot).with_name("ux-add-pane.png")))
            window.add_menu.get_popover().popdown()
            dialog = window.prompt_workspace()
            pump(timeout=.3)
            capture(str(Path(screenshot).with_name("ux-workspace.png")))
            dialog.response(Gtk.ResponseType.CANCEL)
        window._quit_confirmed = True
        window.close()
        app.quit()
        pump(timeout=.2)
        assert not ERRORS
        print("All native UX checks passed.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.exit(1)

from copy import deepcopy
import json
import math
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from multiterminal.model import Store, groups, normalize_url, pane, validate


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "settings/workspaces.json"
        self.store = Store(self.path)
        self.wsid = self.store.create("Project")

    def test_workspace_creation_uses_chosen_folder(self):
        folder = str(Path(self.temporary.name) / "project with spaces")
        wsid = self.store.create("Project folder", directory=folder)
        self.assertEqual(Store(self.path).workspace(wsid)["panes"][0]["directoryPath"], folder)

    def test_font_size_persists_and_old_settings_use_default(self):
        self.assertNotIn("terminalFontSize", Store(self.path).state)
        self.store.commit(lambda state: state.update(terminalFontSize=14))
        self.assertEqual(Store(self.path).state["terminalFontSize"], 14)
        for size in (7, 25, 11.5, "11", True):
            with self.assertRaises(ValueError):
                self.store.commit(lambda state, value=size: state.update(terminalFontSize=value))
        self.assertEqual(Store(self.path).state["terminalFontSize"], 14)

    def test_closing_tab_preserves_surviving_focused_group(self):
        second = pane("terminal")
        self.store.add(self.wsid, second, edge="right")
        focused = self.store.workspace(self.wsid)["focusedGroupID"]
        third = pane("terminal")
        self.store.add(self.wsid, third, target=focused, as_tab=True)
        self.store.remove(self.wsid, third["id"])
        workspace = Store(self.path).workspace(self.wsid)
        self.assertEqual(workspace["focusedGroupID"], focused)
        self.assertEqual(next(g for g in groups(workspace["layout"]) if g["id"] == focused)["selectedPaneID"], second["id"])

    def test_atomic_private_persistence(self):
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(Store(self.path).state, self.store.state)
        self.assertEqual(list(self.path.parent.glob(".workspaces-*")), [])

    def test_save_failure_keeps_memory_and_disk(self):
        original = deepcopy(self.store.state)
        data = self.path.read_bytes()
        with patch("multiterminal.model.os.replace", side_effect=OSError("Disk failure")):
            with self.assertRaises(OSError):
                self.store.create("Unsaved")
        self.assertEqual(self.store.state, original)
        self.assertEqual(self.path.read_bytes(), data)
        self.assertEqual(list(self.path.parent.glob(".workspaces-*")), [])

    def test_invalid_saved_data_is_preserved(self):
        for contents in (b"{broken", b'{"schemaVersion":999}', b'[]', b'null'):
            self.path.write_bytes(contents)
            with self.assertRaisesRegex(ValueError, "preserved"):
                Store(self.path)
            self.assertEqual(self.path.read_bytes(), contents)

    def test_close_open_and_delete(self):
        second = self.store.create("Second")
        self.store.close(self.wsid)
        self.assertEqual(self.store.state["openWorkspaceIDs"], [second])
        self.assertEqual(self.store.workspace(self.wsid)["name"], "Project")
        self.store.open(self.wsid)
        self.assertEqual(self.store.state["activeWorkspaceID"], self.wsid)
        self.store.close(self.wsid, delete=True)
        self.assertEqual(len(self.store.state["workspaces"]), 1)
        self.assertEqual(self.store.state["activeWorkspaceID"], second)

    def test_nested_splits_and_collapse(self):
        browser, preview = pane("browser", "localhost:5173"), pane("filePreview", "/tmp/notes.md")
        self.store.add(self.wsid, browser)
        self.store.add(self.wsid, preview, edge="bottom")
        ws = self.store.workspace(self.wsid)
        self.assertEqual(ws["layout"]["second"]["axis"], "vertical")
        self.store.remove(self.wsid, browser["id"])
        self.assertEqual(len(groups(self.store.workspace(self.wsid)["layout"])), 2)
        self.store.remove(self.wsid, preview["id"])
        self.assertEqual(self.store.workspace(self.wsid)["layout"]["type"], "group")

    def test_docking_preserves_all_panes_and_settings(self):
        first = self.store.workspace(self.wsid)["panes"][0]
        browser = pane("browser", "https://example.com")
        self.store.add(self.wsid, browser)
        original = {p["id"]: p for p in self.store.workspace(self.wsid)["panes"]}
        target = groups(self.store.workspace(self.wsid)["layout"])[0]["id"]
        self.store.dock(self.wsid, browser["id"], target)
        ws = self.store.workspace(self.wsid)
        self.assertEqual(len(groups(ws["layout"])), 1)
        self.assertEqual(ws["layout"]["selectedPaneID"], browser["id"])
        self.store.dock(self.wsid, browser["id"], target, "bottom")
        ws = self.store.workspace(self.wsid)
        self.assertEqual(ws["layout"]["axis"], "vertical")
        self.assertEqual({p["id"]: p for p in ws["panes"]}, original)
        validate(Store(self.path).state)

    def test_reorder_tabs(self):
        first = self.store.workspace(self.wsid)["panes"][0]["id"]
        second, third = pane(), pane()
        self.store.add(self.wsid, second, as_tab=True)
        self.store.add(self.wsid, third, as_tab=True)
        target = self.store.workspace(self.wsid)["layout"]["id"]
        self.store.dock(self.wsid, third["id"], target, before=first)
        self.assertEqual(self.store.workspace(self.wsid)["layout"]["paneIDs"], [third["id"], first, second["id"]])
        self.store.remove(self.wsid, third["id"])
        self.assertEqual(self.store.workspace(self.wsid)["layout"]["selectedPaneID"], first)

    def test_invalid_transaction_does_not_replace_saved_state(self):
        original = deepcopy(self.store.state)
        data = self.path.read_bytes()
        with self.assertRaises(ValueError):
            self.store.edit(self.wsid, lambda ws: ws["panes"].append(deepcopy(ws["panes"][0])))
        self.assertEqual(self.store.state, original)
        self.assertEqual(self.path.read_bytes(), data)

    def test_invalid_profile_identifier_rejected(self):
        state = deepcopy(self.store.state)
        state["workspaces"][0]["id"] = "../../other-folder"
        with self.assertRaises(ValueError):
            validate(state)

    def test_split_percentage_validation(self):
        self.store.add(self.wsid, pane())
        for percentage in (0, 100, -1, math.inf, math.nan, "50"):
            with self.assertRaises(ValueError):
                self.store.edit(self.wsid, lambda ws, v=percentage: ws["layout"].update(firstPercent=v))
        self.store.edit(self.wsid, lambda ws: ws["layout"].update(firstPercent=37.5))
        self.assertEqual(Store(self.path).workspace(self.wsid)["layout"]["firstPercent"], 37.5)

    def test_empty_workspace_is_valid_and_can_add(self):
        first = self.store.workspace(self.wsid)["panes"][0]["id"]
        self.store.remove(self.wsid, first)
        self.assertIsNone(self.store.workspace(self.wsid)["layout"])
        self.store.add(self.wsid, pane("browser"))
        self.assertEqual(len(groups(self.store.workspace(self.wsid)["layout"])), 1)

    def test_theme_folder_and_url_survive_restart(self):
        first = self.store.workspace(self.wsid)["panes"][0]["id"]
        self.store.update_pane(self.wsid, first, directoryPath="/tmp/a folder's project", themeOverride="amber")
        self.store.commit(lambda state: state.update(globalTheme="highContrast"))
        restored = Store(self.path)
        self.assertEqual(restored.pane(self.wsid, first)["directoryPath"], "/tmp/a folder's project")
        self.assertEqual(restored.pane(self.wsid, first)["themeOverride"], "amber")
        self.assertEqual(restored.state["globalTheme"], "highContrast")


class AddressTests(unittest.TestCase):
    def test_normalizes_addresses(self):
        self.assertEqual(normalize_url(" localhost:5173/path "), "http://localhost:5173/path")
        self.assertEqual(normalize_url("example.com"), "https://example.com")
        self.assertEqual(normalize_url("127.0.0.1:8000"), "http://127.0.0.1:8000")
        self.assertEqual(normalize_url("[::1]:8000"), "http://[::1]:8000")
        self.assertEqual(normalize_url(""), "")

    def test_rejects_non_web_and_invalid_addresses(self):
        for url in ("file:///etc/passwd", "javascript:alert(1)", "javascript://example.com", "https://", "https://example.com:bad", "http://example.com/\nthing"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                normalize_url(url)


if __name__ == "__main__":
    unittest.main()

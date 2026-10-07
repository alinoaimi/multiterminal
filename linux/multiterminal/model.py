"""Workspace transactions and atomic, private XDG persistence (no GTK required)."""
from copy import deepcopy
import json
import math
import os
from pathlib import Path
import tempfile
from urllib.parse import urlsplit
from uuid import UUID, uuid4

THEMES = ("midnight", "highContrast", "amber")
KINDS = ("terminal", "browser", "filePreview")


def identifier():
    return str(uuid4())


def data_home():
    return Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "multiterminal-source"


def config_file():
    override = os.environ.get("MULTITERMINAL_WORKSPACE_FILE")
    return Path(override) if override else Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "multiterminal-source/workspaces.json"


def normalize_url(value):
    value = value.strip()
    if not value:
        return ""
    if "://" not in value:
        # Ports are not URI schemes. Use HTTP for local development only.
        host = value.split("/", 1)[0].split(":", 1)[0]
        value = ("http://" if host in ("localhost", "127.0.0.1", "[", "[::1]") else "https://") + value
    parsed = urlsplit(value)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("Enter an HTTP or HTTPS address, such as localhost:5173.")
    _ = parsed.port  # Reject malformed ports before passing the URI to WebKit.
    if any(ord(c) < 32 for c in value):
        raise ValueError("The address contains invalid characters.")
    return value


def pane(kind="terminal", value=""):
    result = {"id": identifier(), "kind": kind}
    if kind == "terminal":
        result.update(directoryPath=value or str(Path.home()), themeOverride=None)
    elif kind == "browser":
        result["url"] = normalize_url(value)
    elif kind == "filePreview":
        result["path"] = str(Path(value).expanduser().absolute()) if value else ""
    else:
        raise ValueError("Unknown pane type")
    return result


def group(ids):
    return {"type": "group", "id": identifier(), "paneIDs": list(ids), "selectedPaneID": ids[0]}


def groups(node):
    if not node:
        return []
    return [node] if node["type"] == "group" else groups(node["first"]) + groups(node["second"])


def nodes(node):
    if not node:
        return []
    return [node] if node["type"] == "group" else [node] + nodes(node["first"]) + nodes(node["second"])


def replace(node, target, replacement):
    if node["id"] == target:
        return replacement
    if node["type"] == "split":
        node["first"] = replace(node["first"], target, replacement)
        node["second"] = replace(node["second"], target, replacement)
    return node


def remove(node, ids):
    if not node:
        return None
    if node["type"] == "group":
        node["paneIDs"] = [p for p in node["paneIDs"] if p not in ids]
        if not node["paneIDs"]:
            return None
        if node["selectedPaneID"] not in node["paneIDs"]:
            node["selectedPaneID"] = node["paneIDs"][0]
    else:
        node["first"], node["second"] = remove(node["first"], ids), remove(node["second"], ids)
        if not node["first"]:
            return node["second"]
        if not node["second"]:
            return node["first"]
    return node


def split(existing, incoming, edge):
    if edge not in ("left", "right", "top", "bottom"):
        raise ValueError("Invalid split edge")
    first = edge in ("left", "top")
    return {"type": "split", "id": identifier(), "axis": "horizontal" if edge in ("left", "right") else "vertical", "firstPercent": 50.0,
            "first": incoming if first else existing, "second": existing if first else incoming}


def valid_uuid(value):
    if not isinstance(value, str) or str(UUID(value)) != value:
        raise ValueError("Invalid workspace identifier")


def validate(state):
    if state.get("schemaVersion") != 1 or state.get("globalTheme") not in THEMES:
        raise ValueError("Unsupported Linux workspace format")
    font_size = state.get("terminalFontSize", 11)
    if type(font_size) is not int or not 8 <= font_size <= 24:
        raise ValueError("Invalid terminal text size")
    seen_workspaces = set()
    for ws in state["workspaces"]:
        valid_uuid(ws["id"])
        if ws["id"] in seen_workspaces or not isinstance(ws["name"], str) or not ws["name"].strip():
            raise ValueError("Invalid workspace")
        seen_workspaces.add(ws["id"])
        pane_ids = []
        if len(ws["panes"]) > 256:
            raise ValueError("Too many panes")
        for p in ws["panes"]:
            valid_uuid(p["id"])
            if p["kind"] not in KINDS:
                raise ValueError("Invalid pane type")
            field = {"terminal": "directoryPath", "browser": "url", "filePreview": "path"}[p["kind"]]
            if not isinstance(p[field], str):
                raise ValueError("Invalid pane location")
            if p["kind"] == "terminal" and p.get("themeOverride") not in (None, *THEMES):
                raise ValueError("Invalid terminal theme")
            if p["kind"] == "browser" and p["url"]:
                normalize_url(p["url"])
            pane_ids.append(p["id"])
        found, node_ids = [], set()

        def check(node, depth=0):
            if depth > 64:
                raise ValueError("Workspace layout is too deeply nested")
            valid_uuid(node["id"])
            if node["id"] in node_ids:
                raise ValueError("Duplicate layout node")
            node_ids.add(node["id"])
            if node["type"] == "group":
                ids = node["paneIDs"]
                if not ids or node["selectedPaneID"] not in ids:
                    raise ValueError("Invalid pane group")
                found.extend(ids)
            elif node["type"] == "split":
                percentage = node["firstPercent"]
                if node["axis"] not in ("horizontal", "vertical") or not isinstance(percentage, (int, float)) or not math.isfinite(percentage) or not 0 < percentage < 100:
                    raise ValueError("Invalid split")
                check(node["first"], depth + 1)
                check(node["second"], depth + 1)
            else:
                raise ValueError("Invalid layout node")
        if ws["layout"]:
            check(ws["layout"])
        if len(pane_ids) != len(set(pane_ids)) or len(found) != len(set(found)) or set(found) != set(pane_ids):
            raise ValueError("Layout does not match panes")
        if ws.get("focusedGroupID") not in [g["id"] for g in groups(ws["layout"])] + [None]:
            raise ValueError("Invalid focused group")
    opened = state["openWorkspaceIDs"]
    if len(opened) != len(set(opened)) or not set(opened) <= seen_workspaces:
        raise ValueError("Invalid open workspace list")
    if state.get("activeWorkspaceID") not in opened + [None]:
        raise ValueError("Invalid active workspace")


class Store:
    def __init__(self, path=None):
        self.path = Path(path) if path else config_file()
        self.state = {"schemaVersion": 1, "workspaces": [], "openWorkspaceIDs": [], "activeWorkspaceID": None, "globalTheme": "midnight"}
        if self.path.exists():
            try:
                if self.path.stat().st_size > 10 * 1024 * 1024:
                    raise ValueError("Workspace file exceeds 10 MB")
                state = json.loads(self.path.read_text(encoding="utf-8"))
                validate(state)
                self.state = state
            except (OSError, ValueError, KeyError, TypeError, RecursionError, AttributeError) as exc:
                raise ValueError(f"Could not read {self.path}: {exc}. Your saved file has been preserved.") from exc

    def workspace(self, wsid):
        return next(ws for ws in self.state["workspaces"] if ws["id"] == wsid)

    def pane(self, wsid, pid):
        return next(p for p in self.workspace(wsid)["panes"] if p["id"] == pid)

    def commit(self, change):
        candidate = deepcopy(self.state)
        change(candidate)
        validate(candidate)
        self._write(candidate)
        self.state = candidate

    def _write(self, state):
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, temporary = tempfile.mkstemp(prefix=".workspaces-", dir=self.path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump(state, stream, ensure_ascii=False, indent=2, allow_nan=False)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def edit(self, wsid, change):
        self.commit(lambda state: change(next(ws for ws in state["workspaces"] if ws["id"] == wsid)))

    def create(self, name=None, directory=None):
        p = pane("terminal", directory or "")
        g = group([p["id"]])
        ws = {"id": identifier(), "name": name or f"Workspace {len(self.state['workspaces']) + 1}", "panes": [p], "layout": g, "focusedGroupID": g["id"]}
        def change(state):
            state["workspaces"].append(ws)
            state["openWorkspaceIDs"].append(ws["id"])
            state["activeWorkspaceID"] = ws["id"]
        self.commit(change)
        return ws["id"]

    def open(self, wsid):
        self.workspace(wsid)
        def change(state):
            if wsid not in state["openWorkspaceIDs"]:
                state["openWorkspaceIDs"].append(wsid)
            state["activeWorkspaceID"] = wsid
        self.commit(change)

    def close(self, wsid, delete=False):
        def change(state):
            state["openWorkspaceIDs"] = [i for i in state["openWorkspaceIDs"] if i != wsid]
            if delete:
                state["workspaces"] = [ws for ws in state["workspaces"] if ws["id"] != wsid]
            if state["activeWorkspaceID"] == wsid:
                state["activeWorkspaceID"] = next(iter(state["openWorkspaceIDs"]), None)
        self.commit(change)

    def add(self, wsid, p, target=None, edge="right", as_tab=False):
        def change(ws):
            if len(ws["panes"]) >= 256:
                raise ValueError("A workspace can contain up to 256 panes.")
            ws["panes"].append(p)
            gs = groups(ws["layout"])
            dest = next((g for g in gs if g["id"] == (target or ws["focusedGroupID"])), next(iter(gs), None))
            if dest and as_tab:
                dest["paneIDs"].append(p["id"])
                dest["selectedPaneID"] = p["id"]
                ws["focusedGroupID"] = dest["id"]
            else:
                incoming = group([p["id"]])
                ws["layout"] = replace(ws["layout"], dest["id"], split(deepcopy(dest), incoming, edge)) if dest else incoming
                ws["focusedGroupID"] = incoming["id"]
        self.edit(wsid, change)

    def remove(self, wsid, pid):
        def change(ws):
            ws["panes"] = [p for p in ws["panes"] if p["id"] != pid]
            ws["layout"] = remove(ws["layout"], {pid})
            remaining = groups(ws["layout"])
            focused = ws["focusedGroupID"]
            ws["focusedGroupID"] = next((g["id"] for g in remaining if g["id"] == focused), next((g["id"] for g in remaining), None))
        self.edit(wsid, change)

    def dock(self, wsid, pid, target, edge=None, before=None):
        def change(ws):
            gs = groups(ws["layout"])
            source = next(g for g in gs if pid in g["paneIDs"])
            dest = next(g for g in gs if g["id"] == target)
            if source is dest and (len(source["paneIDs"]) == 1 or before == pid):
                return
            remainder = remove(ws["layout"], {pid})
            dest = next(g for g in groups(remainder) if g["id"] == target)
            if edge:
                incoming = group([pid])
                ws["layout"] = replace(remainder, target, split(deepcopy(dest), incoming, edge))
                ws["focusedGroupID"] = incoming["id"]
            else:
                at = dest["paneIDs"].index(before) if before in dest["paneIDs"] else len(dest["paneIDs"])
                dest["paneIDs"].insert(at, pid)
                dest["selectedPaneID"] = pid
                ws["layout"] = remainder
                ws["focusedGroupID"] = target
        self.edit(wsid, change)

    def select(self, wsid, pid):
        def change(ws):
            dest = next(g for g in groups(ws["layout"]) if pid in g["paneIDs"])
            dest["selectedPaneID"] = pid
            ws["focusedGroupID"] = dest["id"]
        self.edit(wsid, change)

    def update_pane(self, wsid, pid, **values):
        def change(ws):
            p = next(p for p in ws["panes"] if p["id"] == pid)
            p.update(values)
        self.edit(wsid, change)

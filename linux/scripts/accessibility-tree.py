#!/usr/bin/python3
# Reads an app's accessibility tree, as a screen reader such as Orca reads it, through pyatspi on
# the accessibility bus, for the self-check's parts (SelfCheck/AccessibilityTree.swift):
#   accessibility-tree.py --pid <id> [--depth N] [--children N] [--text]
#   accessibility-tree.py --pid <id> --events <seconds> <event>...
# The first prints one JSON object a line for each element, in the order Orca walks them, from
# the app down: its depth, role, name, description, states, number of children, place among its
# parent's, relations and attributes, and with --text its text. --depth stops that far down
# (default 40), and --children lists at most that many children of each element (default 100),
# though each says how many it has. The second prints each event of those kinds the app sends
# within the seconds, such as object:announcement, one JSON object a line. Exits with 1 when the
# app isn't on the bus.
import argparse
import json
import sys

import pyatspi
from gi.repository import GLib


def words(value):
    return value.value_nick if value is not None else ""


def element(node, depth, with_text):
    found = {
        "depth": depth,
        "role": node.getRoleName(),
        "name": node.name or "",
        "description": node.description or "",
        "states": sorted(words(state) for state in node.getState().getStates()),
        "children": node.childCount,
        "index": node.getIndexInParent(),
        "relations": {},
        "attributes": {},
    }
    for relation in node.getRelationSet():
        targets = [relation.getTarget(index) for index in range(relation.getNTargets())]
        found["relations"][words(relation.getRelationType())] = [
            target.name or target.getRoleName() for target in targets if target is not None
        ]
    for attribute in node.getAttributes():
        name, _, value = attribute.partition(":")
        found["attributes"][name] = value
    if with_text:
        try:
            text = node.queryText()
            found["text"] = text.getText(0, min(text.characterCount, 2000))
        except NotImplementedError:
            pass
    return found


def walk(node, depth, options):
    try:
        print(json.dumps(element(node, depth, options.text), ensure_ascii=False))
        if depth >= options.depth:
            return
        for index in range(min(node.childCount, options.children)):
            child = node.getChildAtIndex(index)
            if child is not None:
                walk(child, depth + 1, options)
    except GLib.Error as error:
        print(json.dumps({"depth": depth, "role": "unreadable", "name": error.message}))


def app_with(pid):
    desktop = pyatspi.Registry.getDesktop(0)
    for index in range(desktop.childCount):
        app = desktop.getChildAtIndex(index)
        if app is not None and app.get_process_id() == pid:
            return app
    return None


def listen(pid, seconds, kinds):
    def heard(event):
        source = event.source
        if source is None or source.get_process_id() != pid:
            return
        carried = event.any_data
        detail = str(carried) if isinstance(carried, (str, int, float, bool)) else None
        print(
            json.dumps(
                {
                    "type": event.type,
                    "role": source.getRoleName(),
                    "name": source.name or "",
                    "detail": detail,
                },
                ensure_ascii=False,
            ),
            flush=True,
        )

    for kind in kinds:
        pyatspi.Registry.registerEventListener(heard, kind)
    GLib.timeout_add(int(seconds * 1000), lambda: pyatspi.Registry.stop() or False)
    pyatspi.Registry.start()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--depth", type=int, default=40)
    parser.add_argument("--children", type=int, default=100)
    parser.add_argument("--text", action="store_true")
    parser.add_argument("--events", type=float)
    parser.add_argument("kinds", nargs="*")
    options = parser.parse_args()
    app = app_with(options.pid)
    if app is None:
        print(f"No app with process {options.pid} is on the accessibility bus.", file=sys.stderr)
        return 1
    if options.events is not None:
        listen(options.pid, options.events, options.kinds)
    else:
        walk(app, 0, options)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""State-file handling for the ADC (rung-2) md-to-google-doc create/update
path. Tracks which local markdown source files have already been rendered
to which Google Doc IDs, so a rerun on the same source updates in place
instead of creating a duplicate doc every time.

Pattern borrowed from selfreview-to-gdoc's rendered.json / CLI state
handling, generalized for arbitrary source files instead of one fixed
review file.

Pure file-I/O logic, no network/Google client dependency — fully unit
testable (see tests/test_adc_state.py).
"""
import json
import os

DEFAULT_STATE_DIR = os.path.expanduser("~/.config/gws-md-to-gdoc")
DEFAULT_STATE_FILE = os.path.join(DEFAULT_STATE_DIR, "rendered.json")


def source_key(file_path: str) -> str:
    """Normalize a source file path into a stable state-file key."""
    return os.path.abspath(os.path.expanduser(file_path))


def load_state(state_file: str = DEFAULT_STATE_FILE) -> dict:
    if not os.path.exists(state_file):
        return {}
    with open(state_file, "r", encoding="utf-8") as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError:
            return {}
    return data if isinstance(data, dict) else {}


def save_state(state: dict, state_file: str = DEFAULT_STATE_FILE) -> None:
    os.makedirs(os.path.dirname(state_file), exist_ok=True)
    tmp = state_file + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, state_file)


def get_entry(state: dict, file_path: str) -> dict | None:
    return state.get(source_key(file_path))


def set_entry(state: dict, file_path: str, doc_id: str, title: str) -> dict:
    state[source_key(file_path)] = {"doc_id": doc_id, "title": title}
    return state


def remove_entry(state: dict, file_path: str) -> dict:
    state.pop(source_key(file_path), None)
    return state

"""A deliberately small YAML subset reader.

The repository is stdlib-only on purpose: a security baseline that requires
`pip install` before it can check anything has a bootstrap problem. This parser
covers exactly the shapes the baseline's own config files use and refuses
everything else loudly, which is the right trade for config we also author.

Supported
    key: value                  scalars: str, int, float, bool, null
    key:                        nested mappings by indentation
      sub: value
    key: [a, b, c]              inline flow sequences of scalars
    - value                     block sequences of scalars
    - key: value                block sequences of mappings
    # comment                   full-line and trailing comments
    "quoted"  'quoted'          quoted scalars (no escapes beyond \\" and \\\\)

Not supported (raises MiniYAMLError)
    anchors, aliases, tags, multi-document streams, block scalars (| >),
    inline flow mappings, multi-line strings.
"""

from __future__ import annotations

import re

__all__ = ["MiniYAMLError", "loads", "load", "dumps"]


class MiniYAMLError(ValueError):
    """Raised on any construct outside the supported subset."""


_UNSUPPORTED = re.compile(r"^\s*(?:%|---|\.\.\.|&\w|\*\w|!)")
_INT = re.compile(r"^[+-]?\d+$")
_FLOAT = re.compile(r"^[+-]?(?:\d+\.\d*|\.\d+)(?:[eE][+-]?\d+)?$")


def _strip_comment(line: str) -> str:
    """Drop a trailing comment, respecting quotes."""
    out = []
    quote = None
    for i, ch in enumerate(line):
        if quote:
            out.append(ch)
            if ch == quote and line[i - 1 : i] != "\\":
                quote = None
            continue
        if ch in "\"'":
            quote = ch
            out.append(ch)
            continue
        if ch == "#" and (not out or out[-1] in " \t"):
            break
        out.append(ch)
    return "".join(out).rstrip()


def _scalar(raw: str):
    text = raw.strip()
    if not text:
        return None
    if text[0] in "\"'" and len(text) > 1 and text[-1] == text[0]:
        inner = text[1:-1]
        return inner.replace('\\"', '"').replace("\\\\", "\\")
    low = text.lower()
    if low in ("null", "~"):
        return None
    if low == "true":
        return True
    if low == "false":
        return False
    if _INT.match(text):
        return int(text)
    if _FLOAT.match(text):
        return float(text)
    return text


def _flow_sequence(raw: str) -> list:
    inner = raw.strip()[1:-1].strip()
    if not inner:
        return []
    if "[" in inner or "{" in inner:
        raise MiniYAMLError(f"nested flow collections are not supported: {raw!r}")
    return [_scalar(part) for part in inner.split(",")]


def _value(raw: str):
    text = raw.strip()
    if text.startswith("[") and text.endswith("]"):
        return _flow_sequence(text)
    if text.startswith("{"):
        raise MiniYAMLError(f"inline flow mappings are not supported: {raw!r}")
    if text in ("|", ">", "|-", ">-"):
        raise MiniYAMLError("block scalars are not supported")
    return _scalar(text)


class _Line:
    __slots__ = ("indent", "text", "no")

    def __init__(self, indent: int, text: str, no: int) -> None:
        self.indent = indent
        self.text = text
        self.no = no


def _tokenize(source: str) -> list[_Line]:
    lines: list[_Line] = []
    for no, raw in enumerate(source.splitlines(), start=1):
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            raise MiniYAMLError(f"line {no}: tab indentation is not supported")
        stripped = _strip_comment(raw)
        if not stripped.strip():
            continue
        if _UNSUPPORTED.match(stripped) and stripped.strip() not in ("---",):
            raise MiniYAMLError(f"line {no}: unsupported construct: {stripped.strip()!r}")
        if stripped.strip() == "---":
            continue
        lines.append(_Line(len(stripped) - len(stripped.lstrip()), stripped.strip(), no))
    return lines


def _parse_block(lines: list[_Line], pos: int, indent: int):
    """Parse one block at `indent`. Returns (value, next_pos)."""
    if pos >= len(lines):
        return None, pos
    if lines[pos].text.startswith("- "):
        return _parse_sequence(lines, pos, indent)
    if lines[pos].text == "-":
        return _parse_sequence(lines, pos, indent)
    return _parse_mapping(lines, pos, indent)


def _parse_sequence(lines: list[_Line], pos: int, indent: int):
    items: list = []
    while pos < len(lines) and lines[pos].indent == indent:
        line = lines[pos]
        if not (line.text == "-" or line.text.startswith("- ")):
            break
        body = line.text[1:].strip()
        pos += 1
        if not body:
            child, pos = _parse_block(lines, pos, _child_indent(lines, pos, indent))
            items.append(child)
            continue
        if ":" in body and not body.strip().startswith(("[", '"', "'")):
            # A mapping starting on the dash line: re-tokenize it as a mapping
            # whose first key sits at indent + 2.
            synth = [_Line(indent + 2, body, line.no)]
            while pos < len(lines) and lines[pos].indent > indent:
                synth.append(lines[pos])
                pos += 1
            value, _ = _parse_mapping(synth, 0, indent + 2)
            items.append(value)
            continue
        items.append(_value(body))
    return items, pos


def _child_indent(lines: list[_Line], pos: int, parent_indent: int) -> int:
    if pos >= len(lines):
        return parent_indent + 2
    return lines[pos].indent


def _parse_mapping(lines: list[_Line], pos: int, indent: int):
    mapping: dict = {}
    while pos < len(lines) and lines[pos].indent == indent:
        line = lines[pos]
        if line.text.startswith("- "):
            break
        if ":" not in line.text:
            raise MiniYAMLError(f"line {line.no}: expected 'key: value', got {line.text!r}")
        key, _, rest = line.text.partition(":")
        key = key.strip().strip("\"'")
        rest = rest.strip()
        pos += 1
        if rest:
            mapping[key] = _value(rest)
            continue
        if pos < len(lines) and lines[pos].indent > indent:
            child_indent = lines[pos].indent
            mapping[key], pos = _parse_block(lines, pos, child_indent)
        elif pos < len(lines) and lines[pos].indent == indent and lines[pos].text.startswith("- "):
            mapping[key], pos = _parse_sequence(lines, pos, indent)
        else:
            mapping[key] = None
    return mapping, pos


def loads(source: str):
    lines = _tokenize(source)
    if not lines:
        return {}
    value, pos = _parse_block(lines, 0, lines[0].indent)
    if pos != len(lines):
        raise MiniYAMLError(f"line {lines[pos].no}: unexpected indentation")
    return value


def load(path) -> dict:
    from pathlib import Path

    return loads(Path(path).read_text(encoding="utf-8"))


def dumps(value, indent: int = 0) -> str:
    """Emit the same subset. Used by the bootstrap to write inventory.yaml."""
    pad = " " * indent
    out: list[str] = []
    if isinstance(value, dict):
        for key, val in value.items():
            if isinstance(val, dict) and val:
                out.append(f"{pad}{key}:")
                out.append(dumps(val, indent + 2))
            elif isinstance(val, list):
                if not val:
                    out.append(f"{pad}{key}: []")
                elif all(not isinstance(v, (dict, list)) for v in val):
                    out.append(f"{pad}{key}: [{', '.join(_emit(v) for v in val)}]")
                else:
                    out.append(f"{pad}{key}:")
                    out.append(dumps(val, indent + 2))
            else:
                out.append(f"{pad}{key}: {_emit(val)}")
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, dict):
                body = dumps(item, indent + 2).splitlines()
                out.append(f"{pad}- {body[0].strip()}")
                out.extend(body[1:])
            else:
                out.append(f"{pad}- {_emit(item)}")
    else:
        out.append(f"{pad}{_emit(value)}")
    return "\n".join(line for line in out if line != "")


def _emit(value) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return str(value)
    text = str(value)
    if text == "" or text.strip() != text or any(c in text for c in "#:[]{},&*!|>'\"%@`"):
        return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return text

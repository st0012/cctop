"""Appearance and local preferences for the Cinnamon panel."""

import json
import os
from dataclasses import dataclass
from tempfile import NamedTemporaryFile


TOOLS = ("Claude Code", "Codex CLI", "Codex Desktop")
MODES = ("Sistema", "Claro", "Escuro")

# Panel, text, secondary text, permission, waiting, working and completed.
# Each palette follows the light and dark variants of the cctop Mac panel.
PALETTES = {
    "Claude": {
        "Claro":  ("#F4F3EE", "#141413", "#585750", "#DD5353", "#C15F3C", "#4A8238", "#2D5A82"),
        "Escuro": ("#262624", "#F4F3EE", "#B1ADA1", "#DD5353", "#C15F3C", "#7EAA6E", "#80A7CF"),
    },
    "Tokyo Night": {
        "Claro":  ("#E6E7ED", "#343B59", "#4F566C", "#8C4351", "#965027", "#33635C", "#3A5BA0"),
        "Escuro": ("#1A1B26", "#C0CAF5", "#8E94AD", "#F7768E", "#FF9E64", "#9ECE6A", "#7AA2F7"),
    },
    "Gruvbox": {
        "Claro":  ("#FBF1C7", "#3C3836", "#675E51", "#9D0006", "#B57614", "#427B58", "#076678"),
        "Escuro": ("#282828", "#EBDBB2", "#B8A891", "#FB4934", "#FABD2F", "#B8BB26", "#83A598"),
    },
    "Nord": {
        "Claro":  ("#ECEFF4", "#2E3440", "#4C566A", "#BF616A", "#D08770", "#4E7A35", "#5E81AC"),
        "Escuro": ("#2E3440", "#ECEFF4", "#BCC5D4", "#BF616A", "#D08770", "#A3BE8C", "#81A1C1"),
    },
}


@dataclass(frozen=True)
class Preferences:
    palette: str = "Claude"
    mode: str = "Sistema"
    tools: frozenset = frozenset(TOOLS)

    @classmethod
    def load(cls, path):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return cls()
        if not isinstance(data, dict):
            return cls()
        palette = data.get("palette")
        mode = data.get("mode")
        tools = data.get("tools")
        return cls(palette=palette if isinstance(palette, str) and palette in PALETTES else cls.palette,
                   mode=mode if mode in MODES else cls.mode,
                   tools=frozenset(t for t in TOOLS if t in tools) if isinstance(tools, list) else cls.tools)

    def save(self, path):
        data = {"palette": self.palette, "mode": self.mode, "tools": [t for t in TOOLS if t in self.tools]}
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as temp:
            try:
                json.dump(data, temp, ensure_ascii=False, indent=2)
                temp.write("\n")
                temp.flush()
                os.replace(temp.name, path)
            finally:
                if os.path.exists(temp.name):
                    os.unlink(temp.name)


def theme_colors(palette, mode):
    keys = ("panel", "ink", "muted", "permission", "waiting", "working", "ready")
    definitions = [f"@define-color lc_{key} {color};" for key, color in zip(keys, PALETTES[palette][mode])]
    for tone in keys[3:]:
        # Keep small colored labels readable on their tinted backgrounds.
        weight = 0.54 if mode == "Claro" else 0.43
        definitions.append(f"@define-color lc_{tone}_text mix(@lc_{tone}, @lc_ink, {weight});")
    return "\n".join(definitions) + "\n"

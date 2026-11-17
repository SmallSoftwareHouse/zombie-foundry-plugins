# Zombie Foundry plugins for Left 4 Dead 2

SourceMod plugins for Left 4 Dead 2 dedicated servers, free software under the
[GNU General Public License v3.0 or later](LICENSE).

| Plugin | What it does | Needs |
|---|---|---|
| [Zombie Foundry Core](core/) | Shared library for the other plugins (MOTD, player preferences, storage) | SourceMod |
| [Stripper Map Editor](stripper-map-editor/) | Moves the map's items in game and writes the layout for Stripper:Source | SourceMod, Stripper:Source |
| [Match Report](match-report/) | Per-round match statistics | SourceMod, Left4DHooks, Zombie Foundry Core |
| [Tank Warning](tank-warning/) | Audio warning when a Tank aims and throws a rock | SourceMod, Left4DHooks, Zombie Foundry Core |

Tested on SourceMod 1.12 with Metamod:Source 1.12.

## Building

Compile each `.sp` file in `*/scripting/` with the SourceMod compiler (`spcomp`), adding these include
folders:

- SourceMod's own includes;
- the Left4DHooks includes (Match Report and Tank Warning);
- `core/include` (Match Report and Tank Warning use `zf_core.inc`).

## Installing

Copy the compiled `.smx` files into `addons/sourcemod/plugins/` and the `translations/` files into
`addons/sourcemod/translations/`.

The Stripper Map Editor also has an optional game mode, `zfstrippermapeditor`: copy
`stripper-map-editor/modes/zfstrippermapeditor.txt` into `left4dead2/modes/` and
`stripper-map-editor/vscripts/zfstrippermapeditor.nut` into `left4dead2/scripts/vscripts/`.

## Sounds

The Tank Warning ships its own warning sounds in `tank-warning/sound/`: copy that folder into
`left4dead2/`. Players hear them if they have the files too (the Zombie Foundry - Tank Warning addon on
the Steam Workshop); otherwise the plugin falls back to one of the game's own sounds.

## License

Copyright (C) 2026 Zombie Foundry. These plugins are free software: you can redistribute them and/or
modify them under the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later version. See [LICENSE](LICENSE).

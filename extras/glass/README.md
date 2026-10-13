# Glass cards

This fork makes the desktop cards rounded, translucent and frosted instead of
square with a solid outline. The card changes live in the plugin itself
(`cards/Card.qml`, plus rounded bars and controls). Two settings live outside it:

## 1. Hyprland blur (`~/.config/hypr/looknfeel.lua`)

Append [`looknfeel.lua`](looknfeel.lua) from this folder to
`~/.config/hypr/looknfeel.lua`, then run `hyprctl reload` and check
`hyprctl configerrors` is empty.

It turns blur on globally (Hyprland requires that for layer rules), opts every
window back out, and blurs only the `omawidgets-desktop` layer.

## 2. Card opacity (`~/.config/omarchy/shell.json`)

In the `io.github.fabandrade88.omawidgets` entry, set:

```json
"opacity": 0.45,
```

## Tuning

- Corner roundness: `glassRadius` in `cards/Card.qml` (22)
- See-through amount: `opacity` in `shell.json` (0.45)
- Frost strength: blur `size` / `passes` in `looknfeel.lua`

## Restoring on a fresh install

```bash
omarchy plugin add https://github.com/serabi/OmaWidgets --enable
```

Then do steps 1 and 2 above. If the cards still look square, run
`omarchy restart shell` (the shell can cache the old card component).

## Pulling in upstream updates

```bash
cd ~/.config/omarchy/plugins/io.github.fabandrade88.omawidgets
git fetch upstream
git merge upstream/main
git push origin main
```

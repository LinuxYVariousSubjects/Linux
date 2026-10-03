# Lesson: Mouse can't move to the monitor above (GNOME multi-monitor)

**Goal:** With one monitor placed *above* another in Settings → Displays, the mouse crosses between them exactly where the screens touch.

**Setup:** Ubuntu 24.04, GNOME Shell 46 on Wayland, laptop + 3 external monitors on a Thunderbolt dock, extensions Hide Top Bar and Ubuntu Dock.

## Final working solution

Turn off every "push the mouse against the edge to reveal" feature. The top bar and the dock then show only in the Activities overview (Super / Windows key).

```bash
cd gnome-multi-monitor
dconf load /org/gnome/ < barrier-free.dconf
```

Takes effect immediately, no log-out needed.

### Key files

| File | Purpose |
|---|---|
| `barrier-free.dconf` | the settings, loaded with `dconf load /org/gnome/` |
| `~/.config/monitors.xml` | GNOME's saved monitor layouts (one per set of connected monitors) |

### Useful commands

```bash
# Check the settings (all four should print false)
dconf read /org/gnome/shell/extensions/hidetopbar/mouse-sensitive
dconf read /org/gnome/shell/extensions/dash-to-dock/autohide
dconf read /org/gnome/shell/extensions/dash-to-dock/intellihide
gsettings get org.gnome.desktop.interface enable-hot-corners

# Current monitor layout: position of each screen, '*' marks the primary
xrandr --listmonitors

# Which extensions are active
gnome-extensions list --enabled
```

---

## Why it happened

- **Hide Top Bar** with `mouse-sensitive=true` puts an invisible pressure barrier along the **whole top edge of the primary monitor**, so pushing the mouse up reveals the hidden top bar. The barrier lets the pointer pass downward but blocks it going up, and pushing only reveals the bar; it never lets the pointer through. A monitor placed above the primary is unreachable from it.
  (Source: `panelVisibilityManager.js` → `_initPressureBarrier`, a `Meta.Barrier` across the full panel width.)
- **Ubuntu Dock** with `autohide` + `require-pressure-to-show` does the same on the dock edge of the primary monitor (the left edge here): moving to a monitor on that side first hits the barrier until the dock pops out.
- **Hot corner** (`enable-hot-corners`) adds a small barrier at the top-left corner of the primary monitor. Ubuntu ships it off; the file keeps it off explicitly.
- It looked random because **the primary monitor kept changing**. After the dock reconnects, connector names get renumbered (DP-1 … DP-9) and GNOME loads a different saved layout for each combination (33 of them in `monitors.xml`). The wall moved together with the top bar.

## Gotchas

- **Corners:** GNOME (Mutter) stops a mouse move on *both* axes when its target is outside every screen. Moving diagonally into a corner with nothing beyond it can stick; moving straight up passes. This is GNOME by design, not a barrier.
- **Offset edges:** where monitors are shifted against each other in Settings → Displays, the strip with no monitor on the other side is a wall by definition. Align the edges if it bothers you.
- Making a side monitor with nothing above it the primary also avoids the wall, but the primary can change after a dock reconnect. That's why the fix is the settings, not the layout.

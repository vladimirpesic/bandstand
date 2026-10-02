# Page turners and foot pedals

Written per §1 / §15, for §9's *"Bluetooth page turner support (AirTurn) —
build in M8. Just MIDI/HID input mapped to next/prev."*

"Just" is right about the mapping and wrong about the input. A page turner is
not a category of device: it is a **Bluetooth keyboard** that happens to have
two pedals instead of a hundred keys, and the operating system already presents
it as one. There is no driver to write and no permission to ask for.

## 1. What a page turner actually sends

AirTurn, Coda, PageFlip and the rest are HID keyboards in a box. Each pedal is
configured, on the device itself, to send a keystroke. The conventional sets:

| Mode | Down / next | Up / previous |
| --- | --- | --- |
| AirTurn default | `↓` | `↑` |
| Page mode | `PageDown` | `PageUp` |
| Space mode | `Space` | `Backspace` |
| Arrow mode | `→` | `←` |

Bandstand honours **all four**, because which one a pedal is in is a setting on
the pedal that a player has already made for some other app and will not want
to change.

## 2. The rule

**A page turner is a keyboard, so it is handled where keyboards are handled.**
Reading mode already takes keyboard input for a desktop user; a pedal arrives
through the same `Shortcuts`, and nothing knows the difference.

That is the whole design, and it is why this is a short document. What would be
wrong is a page-turner *mode*, a pairing screen, or a device list: none of them
would work better and all of them would be things to maintain.

## 3. What the keys do

Only in **reading mode**, and only these:

| Key | Does |
| --- | --- |
| `↓` `→` `PageDown` `Space` | Next page |
| `↑` `←` `PageUp` `Backspace` | Previous page |

Not transport control. A pedal that started and stopped the band would be a
pedal that starts the band when a player shifts their weight, and the cost of
that on stage is far worse than the convenience.

**A page turn at the last page does nothing** rather than wrapping to the
first. A player pressing a pedal twice at the end of a tune means to be at the
end of the tune.

## 4. Elsewhere in the app

Nowhere. Outside reading mode, `Space` types a space and `PageDown` scrolls a
list, and stealing them would break the editor for the sake of a pedal that is
not being used.

## 5. What this deliberately does not do

- **MIDI foot controllers.** §7.5 puts MIDI input at a later milestone and it
  needs `midir` plus a JNI shim on Android. A HID pedal needs neither, which is
  why it comes first.
- **Configurable mappings.** Four conventions cover the devices that exist. A
  fifth is a line in the table above, not a settings screen.
- **Half-press, long-press, or double-tap gestures.** A pedal has one bit.

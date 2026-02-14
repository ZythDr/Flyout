# Flyout

Flyout is a WoW Vanilla (1.12) addon that mimics retail-style flyout action buttons.

## What This Fork Adds

- Item support in flyout entries (`item`, `selfItem`, `rightSelfItem`)
- Spell self-cast variants (`selfCast`, `rightSelfCast`)
- Working auto-direction fallback (no required `[up]/[down]/[left]/[right]` workaround)
- Item tooltips on flyout buttons
- Item stack counters on flyout buttons
  - Counts are summed across all bag stacks of the same item
  - Stackable items show count (including `1`)
  - Non-stackable items do not show a count
- Optional pfUI count-font inheritance (if pfUI is loaded)
- Bag snapshot caching for efficient updates (rebuilds on `BAG_UPDATE`)

## Macro Syntax

Base format:

```lua
/flyout Action1; Action2; Action3
```

Actions can be:

- Spell name (e.g. `Flash Heal`, `Frostbolt(Rank 1)`)
- Macro name
- Item name (auto-detected if currently in bags)

Keywords:

- `item <name>`: use item
- `selfItem <name>`: use item on self
- `rightSelfItem <name>`: left-click normal use, right-click self-use
- `selfCast <spell>`: cast spell on self
- `rightSelfCast <spell>`: left-click normal cast, right-click self-cast

Direction modifiers:

- `[up]`, `[down]`, `[left]`, `[right]`

Other modifiers:

- `[sticky]` keeps flyout open after use
- `[icon]` uses the first flyout action icon on the parent button

Example:

```lua
/flyout [up] rightSelfCast Flash Heal; rightSelfItem Scroll of Spirit; selfCast Heal; item Nordanaar Herbal Tea; Holy Nova
```

## Item Availability Behavior

- If an item is not in your bags, that entry is hidden from the opened flyout.
- When restocked, it appears again the next time the flyout is opened.

## Setup

1. Create a macro.
2. Put a `/flyout ...` line in the macro body.
   - `/flyout` can be on any line (for example after a `#showtooltip` line added by macro addons).
3. Place the macro on an action bar.

## Compatibility

Tested with:

- ElvUI
- pfUI
- Bartender2
- Bongos
- Roid-Macros
- CleverMacro
- MacroExtender

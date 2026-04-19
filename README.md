# SaucedCarts - Pushable Carts

A Project Zomboid Build 42 mod that adds pushable carts for transporting large amounts of items. Fully multiplayer-safe with no item duplication bugs.

## Features

### Cart Types

| Cart | Capacity | Weight Reduction | Speed | Durability | Weight |
|------|----------|------------------|-------|------------|--------|
| **Shopping Cart** | 60 units | 95% | 70% | 100 | 8 kg |

- **Capacity**: How much the cart can hold (like a container)
- **Weight Reduction**: Items inside the cart weigh this much less (95% = items weigh only 5% of normal)
- **Speed**: Your movement speed while pushing the cart (70% = 30% slower)
- **Durability**: How much damage the cart can take before breaking

### Gameplay

- **Push Cart**: Right-click a cart on the ground to pick it up and start pushing
- **Drop**: Use vanilla "Drop" option to place an equipped cart back on the ground
- **Storage**: Carts act as containers - open your inventory to access the cart's storage while pushing
- **Visual States**: Cart model changes to show empty, partially full, or full states
- **Two-Handed**: Carts require both hands, automatically unequipping other items
- **Realistic Restrictions**: Cannot sneak or aim weapons while pushing a cart

### Spawn Locations

**Shopping Carts** spawn on the ground in:
- **Large Retail**: Gigamarts (50%), supermarkets (45%), department stores (40%)
- **Grocery Stores**: Standard grocery stores (45%), convenience stores (15%)
- **Tool/Hardware Stores**: Tool stores, garden stores, warehouses (25-35%)
- **Other Retail**: Bookstores, clothing stores, electronics stores (25-30%)
- **Outdoor Areas**: Parking lots (15%)
- **Vehicles**: Grocery delivery truck beds

Carts spawn on the floor when you first visit a building - one cart per building maximum. This is more realistic than finding carts inside containers!

### Cart Restrictions

Carts can only exist in two states:
- **On the ground** - Dropped carts sit as world objects
- **Equipped in both hands** - When you're pushing the cart

You **cannot** put carts into bags, backpacks, vehicle trunks, or other containers. This prevents duplication exploits and makes gameplay more realistic. Use the "Push Cart" context menu option to pick up carts.

## Sandbox Settings

Access via **Sandbox Options > SaucedCarts** when creating or editing a game:

| Setting | Range | Default | Description |
|---------|-------|---------|-------------|
| **Enable Mod** | On/Off | On | Enable or disable the mod entirely |
| **Spawn Rate** | 0-500% | 100% | Spawn probability multiplier. 0 = none, 200 = double chance |
| **Enable World Spawning** | On/Off | On | Carts spawn on ground in stores. Off = only in vehicle cargo |
| **Capacity Multiplier** | 25-400% | 100% | Adjust cart storage capacity. 200 = double capacity |
| **Durability Multiplier** | 25-400% | 100% | Adjust cart durability. 200 = twice as durable |

## Multiplayer

This mod is fully multiplayer compatible:
- No item duplication exploits
- Server-authoritative pickup/drop actions
- Proper synchronization across all clients
- Works with dedicated servers

## Installation

1. Subscribe on Steam Workshop, OR
2. Download and extract to your `%USERPROFILE%\Zomboid\mods\` folder

## Debug Commands

For server admins and testing (requires debug mode or admin privileges):

```lua
-- Spawn a cart at your feet
SaucedCartsDebug.spawnCart("ShoppingCart")

-- Give yourself a cart (equipped in hands)
SaucedCartsDebug.giveCart("ShoppingCart")

-- Pick up a nearby cart (bypasses menu)
SaucedCartsDebug.pickupWorldCart()

-- Set condition of held cart (0-100%)
SaucedCartsDebug.setCondition(50)

-- Show status of held cart
SaucedCartsDebug.showStatus()

-- List all cart types
SaucedCartsDebug.listCarts()
```

## Compatibility

- **Project Zomboid**: Build 42.13.1+
- **Multiplayer**: Fully supported
- **Split-screen**: Supported (up to 4 players)

## Technical Details

### Why SaucedCarts? (vs ZuperCarts)

[ZuperCarts](https://steamcommunity.com/sharedfiles/filedetails/?id=3433203442) is an excellent cart mod with great features like multiple cart colors, custom keybinds, and visual model swapping between empty and full states. We love what they've built and have used it ourselves.

However, ZuperCarts has persistent duplication bugs in multiplayer that have been difficult to fix due to its architectural complexity. Rather than try to patch those issues, SaucedCarts takes a simpler approach from the ground up - fewer features, but rock-solid multiplayer stability.

#### Root Cause of ZuperCarts Duplication Bugs

ZuperCarts defines **12 separate item types** - an empty and full variant for each cart color:

```
CartContainer ↔ CartContainer2      (empty ↔ full)
CartContainerBlue ↔ CartContainerBlue2
CartContainerGray ↔ CartContainerGray2
... etc
```

The mod runs `OnTick` and `OnContainerUpdate` handlers that check cart contents and **swap the item** when contents change (see `ZuperCartsModelSwap.lua` lines 143-165, 167-185). This swap:

1. Creates a NEW item instance via `instanceItem(newType)`
2. Transfers container contents from old → new
3. Removes old item from inventory
4. Adds new item to inventory
5. Re-equips if needed

This creates several failure modes:

| ZuperCarts Issue | What Happens | Root Cause |
|------------------|--------------|------------|
| **Relog duplication** | New cart spawns with copied contents on server rejoin | During swap, both old and new items briefly exist. If client disconnects mid-swap, server may persist both |
| **Vanilla "Grab" conflict** | Using vanilla grab causes ghost carts that reappear | ZuperCarts hooks `ISGrabItemAction.isValid` to block grab, but timing issues let it through |
| **MP desync** | Cart invisible or player can't interact | `swapCartVariant()` runs client-side without proper MP sync - server doesn't know about the swap |
| **Progressive duplication** | Duplicates accumulate over weeks | Each swap has a small chance of failure; `swapInProgress` flag doesn't prevent all race conditions |

The `OnTick` polling (every 500ms) combined with `OnContainerUpdate` events means swaps can be triggered from multiple code paths simultaneously.

#### Our Approach

We traded some of ZuperCarts' nice-to-have features (color variants, keybinds) for a simpler architecture that's easier to keep bug-free, while still supporting visual empty/full states using the correct Build 42 API.

**1. Single Item Definition (Model Swap, Not Item Swap)**

```
ZuperCarts: 12 item types (6 carts × 2 variants each) - swaps ITEM
SaucedCarts: 1 item type with 3 visual states - swaps MODEL only
```

Each cart type is ONE item definition. The cart never transforms into a different item type. Visual states (empty/partial/full) change the 3D model via `setStaticModel()` without creating new items. Contents stay in the native PZ container system. No item swap code, no duplication risk.

**2. Server-Authoritative Timed Actions**

ZuperCarts `dropCartAtPlayerPosition()` and `Carts.EquipCart()` directly manipulate inventory without timed actions:

```lua
-- ZuperCarts: Instant client-side manipulation (OnEquipCart.lua lines 35-56, 150-188)
playerObj:getInventory():Remove(cartItem)
square:AddWorldInventoryItem(cartItem, 0, 0, 0)
-- No server validation, no timed action
```

SaucedCarts uses proper timed actions with MP serialization:

```lua
-- SaucedCarts: Server-authoritative timed action
ISCartPickupAction.FromWorldItem(player, worldObject)  -- Extracts coordinates + item ID
-- Server reconstructs and validates before executing

-- Drop uses vanilla's battle-tested ISDropWorldItemAction
ISDropWorldItemAction:new(player, item, square, ...)
```

**3. No Custom Keybind System**

ZuperCarts uses a custom equip system with extensive vanilla hooks:
- Hooks `ISHotbar.equipItem` (line 210)
- Hooks `ISInventoryPaneContextMenu.canEquipItem` (line 191)
- Hooks `isForceDropHeavyItem` (line 201)
- Hooks `ISGrabItemAction.isValid` (line 485)
- Hooks `ISWorldObjectContextMenu.doGrabItemOption` (line 472)

Each hook is a potential failure point. SaucedCarts uses standard right-click context menus with minimal hooks:
- Blocks vanilla equip options via `context:removeOptionByName()`
- Adds "Push Cart" option (drop uses vanilla action)
- No keybind conflicts, no hook chains

**4. Minimal Per-Frame Overhead**

ZuperCarts registers TWO tick handlers:
- `CartModelSwap.onTick` - polls every 500ms checking all carts (line 261)
- `onEquipCartTick` - polls every frame checking for duplicates (line 468)

SaucedCarts is event-driven with minimal overhead:
- `OnPlayerUpdate` - ~6 ops for players who never held a cart, ~12 ops max for cart holders
- `OnTick` (visual updates) - queue-based, exits immediately when empty
- No inventory scanning, no state polling, no accumulated drift

#### Summary: Tradeoffs

If you want cart colors and keybinds and don't mind occasional MP quirks, ZuperCarts is great. If you need bulletproof MP stability and can live with fewer bells and whistles, that's what SaucedCarts is for.

| Aspect | ZuperCarts | SaucedCarts |
|--------|------------|-------------|
| Item definitions | 12 types (empty/full pairs) | 1 type with 3 visual states |
| Visual change | Swap entire item (duplication risk) | Swap model only via `setStaticModel()` |
| Equip method | Hooks + direct manipulation | Timed actions via context menu |
| MP sync | Client-side, no validation | Server-authoritative timed actions |
| Per-frame cost | ~50+ ops/player (polling) | ~6-12 ops/player (event-driven) |
| Vanilla hooks | 5+ function overrides | 1 (removeOptionByName) |
| Duplication risk | High (item swap race conditions) | None (model swap only) |

#### How We Handle Visual States

Build 42 supports changing an item's 3D model **without swapping item types** via `setStaticModel()`. We use this to show empty/partial/full cart states without ZuperCarts' duplication risks:

```lua
-- Change model without creating new item (Build 42+)
if fillPercent < 0.33 then
    item:setStaticModel("ShoppingCartEmpty")
elseif fillPercent < 0.66 then
    item:setStaticModel("ShoppingCartPartial")
else
    item:setStaticModel("ShoppingCartFull")
end
player:resetEquippedHandsModels()  -- Refresh visual
```

| Approach | What Changes | Duplication Risk |
|----------|--------------|------------------|
| ZuperCarts (item swap) | Creates NEW item, transfers contents | High - two items exist during swap |
| SaucedCarts (model swap) | Same item, just visual model | None - one item always |

The item instance, container contents, and item ID all remain constant - only the visual representation changes. Updates are triggered by inventory transfer events, not polling.

### Item Properties

Both carts are defined as `InventoryContainer` items with:
- `RequiresEquippedBothHands = true` - Must hold with both hands
- Custom cart-holding animations
- Proper condition/durability system
- Weight reduction for stored items

### Code Architecture

| Component | Location | Purpose |
|-----------|----------|---------|
| Core.lua | shared | Namespace, validation, utilities |
| CartData.lua | shared | Cart type definitions |
| SpawnLocations.lua | shared | Room-based spawn definitions |
| ContainerRestrictions.lua | shared | Blocks carts from bags/vehicles |
| ISCartPickupAction.lua | shared | MP-safe timed pickup action |
| ContextMenu.lua | client | Right-click menu options |
| CartStateHandler.lua | client | Animation variables + movement restrictions |
| TransferRestrictions.lua | client | Blocks drag-drop transfers, removes equip options |
| DebugCommands.lua | client | In-game debug utilities |
| WorldSpawning.lua | server | Ground-based room spawning system |
| Distributions.lua | server | Vehicle loot table integration |

## Credits

- **Authors**: Dark Sauce, Bjork Son of Bork
- **Version**: 1.0.0

## License

This mod is provided as-is for personal use with Project Zomboid.

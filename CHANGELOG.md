# Changelog

All notable changes to SaucedCarts are documented here. Latest version first.

## v2.1.5 — 2026-04-20 (MP transfer fixes)

### Bug Fixes

**Container ↔ cart transfers on dedicated MP — duplication / silent no-op**
`ISCartTransferAction.classifySide` had no branch for world containers (shelves, freezers, counters, barbecues, wardrobes) bound to `IsoObject`s on tiles. They collapsed to `"inv"` and the server resolved `playerInv` as the non-cart endpoint — so a transfer between a cart and a shelf silently used the player's main inventory instead. Symptoms: source unchanged + cart gets a copy (duplication, with `container already has id` log spam), or transfer animates but item doesn't move. Three-part fix: new `"world"` kind in `classifySide` (serializes tile coords + container type via `getSourceGrid()`), new `"world"` branch in `resolveSide` (iterates the tile's objects matching by container type), defensive fallback for pre-v2.1.5 clients via `item:getContainer()` plus an idempotence guard for "Take All" duplicate sends.

**Cart → equipped bag deposited into main inv instead of the bag**
`classifySide` also had no branch for containers whose `containingItem` is a non-cart `InventoryItem` (equipped backpacks, satchels, holsters, bag-in-bag). They fell through to `"inv"` so the server resolved `playerInv`. Two-part fix: new `"bag"` kind in `classifySide` (serializes the containing item's ID), new `"bag"` branch in `resolveSide` with recursive lookup that finds the bag by ID anywhere in the player's inventory tree.

**Internal: findItemNearPlayer reachability**
The pre-existing in-hand cart scan was placed after the gated `psq` check — so if the player had no current square, items in in-hand carts were unreachable. Refactored to use the new `findInventoryItemRecursive` helper as the first lookup, removing the dependency.

### Known Limitation

Pre-v2.1.5 clients that classify equipped bags as `"inv"` and send `destKind="inv"` for cart → bag transfers cannot be recovered server-side. Item lands in main inventory instead of the bag (same as v2.1.4 behaviour). Only fully-restarted v2.1.5 clients use the new `"bag"` classifier — reconnecting alone doesn't reload Lua.

### Dev Tooling

- 5 new offline regression tests for `"world"` kind + 5 for `"bag"` kind. 158/158 tests passing.
- 1000-iteration property-based fuzzer alternates new/old client classifier per iteration, verifies conservation + uniqueness + moved invariants.
- `pz-test-kit/shell` live stress probe drives 60+ real `handleCartTransfer` invocations against a running dedicated server using actual PZ objects (not mocks): 0 invariant violations.
- Decompiled-source-verified writeup of PZ item transmit semantics in `pz-dev-tools/knowledge/pz-item-transmit-semantics.md` (cross-cutting; covers `AddItem` vs `SynchSpawn`, `sendAddItemToContainer` wire format, container-routing rules).

### Beta Opt-in

A WIP corpse-storage feature ships in this build but is **disabled by default**. Two new sandbox toggles, both off:

- `Enable Corpse Storage [BETA]` — load corpses into carts via grapple + right-click, with vanilla-faithful rot accounting (corpses age in the cart, despawn at the sandbox `HoursForCorpseRemoval` threshold)
- `Cart Corpse Stink [BETA]` — loaded carts contribute to vanilla's corpse-sickness and flies-buzz registries on every nearby player in MP

Off by default while we tighten up MP edges (single-mutation invariants for sickness, late-joiner replay correctness on dedi restart, animal-corpse coverage). Players who want to try it can flip the toggles in sandbox; expect rough edges. Public release of the feature is planned for a future version.

### Backward Compatibility

Save-safe. No ModData schema changes. Safe to upgrade mid-save. Old `depositToGroundCart` server command and `ISCartDepositAction` symbol both still aliased.

## v2.1.4 — 2026-04-19 (Hotfix)

### Bug Fixes

**Cart transfers on dedicated MP — only inv→ground-cart worked**
The v2.1.3 `CartTransferInterceptor` only matched on destination container. Three of the four cart-involved transfer cases silently fell through to vanilla's `TransactionManager.isConsistent`, which rejects them on dedicated servers because Java-internal `getEffectiveCapacity` bypasses our Lua capacity override. Symptom: progress bar completes, item stays in place. Rewrote the classifier as direction-neutral — matches ANY transfer where source OR destination is a cart's inner container, in-hand or on-ground. All four directions now route through the custom `ISCartTransferAction` which bypasses `TransactionManager` entirely and delegates to vanilla `ISTransferAction:transferItem` (keeps unequip, worn-item removal, `OnClothingUpdated` model refresh, radio / candle / lantern swaps intact).

- `player inv → ground cart`: worked → still works
- `ground cart → player inv`: broken → fixed
- `player inv → in-hand cart`: broken → fixed
- `in-hand cart → player inv`: broken → fixed

### Back-compat

- The old `ISCartDepositAction` symbol remains as an alias to `ISCartTransferAction` so any integration that referenced it directly keeps working.
- The old `depositToGroundCart` server command is aliased to the new `cartTransfer` handler so a client loaded before this update can still complete their in-flight transfer mid-session.
- `SaucedCarts.performCartDeposit(player, item, cart)` kept as a thin wrapper around `SaucedCarts.performCartTransfer(player, item, src, dst)`.

### Dev Tooling

Tests now cover the full 4-way cart transfer matrix (ground/in-hand × source/dest) plus drop-to-floor and floor-to-cart pickup paths (broadcast counts, worldItem lifecycle, 5-arg `AddWorldInventoryItem` contract). Previous test file only asserted on destContainer — the exact coverage gap that let the v2.1.3 bug ship. 50/50 offline tests pass; regression simulations (reverting the classifier to v2.1.3-style dest-only match; reverting to the 4-arg `AddWorldInventoryItem` form) each cause their expected tests to fail.

### Backward Compatibility

Save-safe. No ModData schema changes. Safe to upgrade mid-save.

---

## v2.1.3 — 2026-04-19

### Bug Fixes

**Crafting on dedicated MP servers**
Players could not craft the Shopping Cart on dedicated servers — the action would animate on the client but never complete. Root cause was the recipe living in `module SaucedCarts` instead of `module Base`: vanilla's `NetTimedAction.parse` on the server looks up the recipe by full name and returned null, so `ISHandcraftAction.lua:400` threw `attempted index: isCanWalk of non-table: null` and silently cancelled the action. Moved the recipe to `module Base` (and removed `imports {Base}` from the items file to avoid a module-import cycle that would have infinite-recursed PZ's `ScriptBucket.get`).

**Ground-cart duplication on MP**
Pushing a cart while entering a vehicle could produce two copies of the cart on the ground, contents duplicated. Vanilla's `forceDropHeavyItems` has no precondition guard — when the hand ref is stale (cart already on the ground, or already removed from inventory), it calls `AddWorldInventoryItem` on the stale reference and spawns a second world object. Added `ForceDropGuard` that wraps the vanilla function and clears stale hand refs before vanilla runs. Bug is engine-level and affects every path that touches heavy items (`ISEnterVehicle`, `ISEquipWeaponAction`, `ISEquipHeavyItem`, `ISGrabCorpseAction`); the guard covers the whole class.

**Capacity / item transfer on MP ground carts**
Items could not be transferred into a cart on the ground beyond ~50kg on dedicated servers, even when the cart's displayed capacity was higher. Root cause: vanilla's `TransactionManager.isConsistent` on the server uses Java-internal `getEffectiveCapacity`, which bypasses our Lua override and hits PZ's hardcoded 50-cap. Added `CartTransferInterceptor` + `ISCartDepositAction`: narrowly intercepts `ISInventoryTransferAction` ONLY when the destination is a SaucedCarts cart whose inner container is NOT parented to an `IsoGameCharacter` (ground carts, vehicle-storage carts). In-hand transfers and non-cart transfers continue through vanilla unchanged. The custom action bypasses `TransactionManager` and delegates to vanilla `ISTransferAction:transferItem` so all the edge cases (clothing unequip, worn-item removal, `OnClothingUpdated` fire for model refresh, radio / candle / lantern item swaps) keep working.

**Spawn locations**
Carts were spawning in weird places — apartments, chicken coops, parking lots adjacent to residential buildings. The old default list had several phantom room names (`supermarket`, `mall`, `parkinglot`, `electronicsstore` [typo — vanilla spells it `electronicstore`]) that have no distribution entry in PZ's vanilla `Distributions.lua`. Those registrations silently never fired on vanilla maps. Replaced the default list with 34 vanilla-verified room names and added a building-signature filter that uses PZ's own `BuildingDef.isResidential()` and `IsoGridSquare:getBuilding()` — rejects residential buildings (apartments + houses, which have bedrooms) and purely-outdoor squares. Addon authors opt out per-entry via flags (see **New Features** below).

**ForceDropGuard init on dedicated server**
The guard relied on `OnGameStart`, which does not fire on dedicated server for mod Lua. Fixed by also hooking `OnServerStarted` AND doing a load-time install when classes are available. Install is idempotent (double-firing is a no-op). Initialization is now logged at info level so the fact that the guard installed is visible in the server DebugLog without debug flags.

**Capacity display/deposit asymmetry**
Inner/outer `getCapacity` Lua overrides were not installed on dedicated servers because of the `OnGameStart` issue above. Same fix (`OnServerStarted` + load-time install) applies. Carts in hand and on the ground now show consistent capacity server-side.

### New Features (Addon Authors)

**Per-entry spawn opt-outs**

`SaucedCarts.registerCart` now accepts per-entry flags in `spawnRooms`:

```lua
spawnRooms = {
    { room = "warehouse", chance = 40 },                          -- framework defaults
    { room = "kitchen",   chance = 10, allowResidential = true }, -- opt into houses
    { room = "parkinglot", chance = 20, allowOutdoor = true },    -- opt into outdoor
    { room = "any",       chance = 10, skipFrameworkFilters = true }, -- escape hatch
}
```

- `allowResidential` — bypass the "building has a bedroom" check
- `allowOutdoor` — bypass the "requires indoor building" check
- `skipFrameworkFilters` — bypass ALL framework filters

The base ShoppingCart uses none of these flags — it ships with the safe defaults. Existing addon carts that didn't set flags now inherit the new filters. If one of your spawns stops firing after this update, adding `allowResidential = true` / `allowOutdoor = true` to the relevant entry restores prior behaviour.

**Vanilla room discovery API**

```lua
SaucedCarts.isVanillaRoom("grocery")       -- true
SaucedCarts.isVanillaRoom("supermarket")   -- false (phantom)
SaucedCarts.getPhantomSpawnRooms()         -- { <phantom names> }
```

Wraps PZ's `ItemPickerJava.hasDistributionForRoom` — authoritative for "does this room name exist in vanilla". Use before shipping an addon to confirm `spawnRooms` entries match vanilla maps.

**Debug commands**

Client console (admin / debug mode):
- `SaucedCartsDebug.capacityReport()` — auto (held or nearest ground cart)
- `SaucedCartsDebug.capacityReportServer()` — fires server-side report
- `SaucedCartsDebug.spawnEligibility()` — why is / isn't this spawn firing
- `SaucedCartsDebug.listSpawnRooms()` — all registered rooms + cart types + flags

Server admin console:
- `SaucedCarts.capacityReport(getOnlinePlayers():get(0))`
- `SaucedCarts.capacityReportAllPlayers()`

**Optional `StrictShopOnly` sandbox**

Default OFF. When on, requires `BuildingDef.isShop() == true` in addition to the existing residential / outdoor filters. For servers that want tighter control over cart distribution.

### Dev Tooling

- Offline test harness via pz-test-kit. 35 tests running on PZ's actual Kahlua VM — force-drop guard, dual-VM MP sync, spawn filter, cart deposit interception. All tests exercise real vanilla PZ Lua (`ISTransferAction`, `ISBaseTimedAction`) via pz-test-kit's `vanilla_requires` mechanism — no mock drift.
- GitHub Actions CI workflow runs the full test suite on every push.

### Known-Harmless Warnings

These appear on server startup and are NOT bugs in this mod:
- `ModelScript.checkMesh > no such mesh "weapons/2handed/ShoppingCart_PZ|ShoppingCart"`

Vanilla's fbx mesh-name verification flags this but the model still loads and renders. Will be addressed in a future release.

### Backward Compatibility

Save-safe. ModData schema unchanged. Existing carts keep their durability, content, and pickup state across the update. No ModData migration needed.

---

## v2.1.2

### Bug Fixes

- Cart capacity was limited to ~42 instead of the displayed 50. The capacity override only activated when the sandbox multiplier exceeded 100%. At default settings, Java's internal cap (50 minus cart weight = 42) blocked item transfers even though the UI showed the correct capacity. Fixed — override now runs for all carts.
- Carts on the ground couldn't be filled past ~40 capacity. PZ's per-tile floor weight limit was treating items going into a cart as loose items on the ground. Items inside a cart container are not on the floor — the floor weight check is now skipped for cart containers.
- Weight reduction showed 95 when sandbox was set to 100. The old `WeightReductionMultiplier` setting multiplied the base 95% value instead of setting the weight reduction directly. Renamed to `WeightReduction` — now an absolute percentage (95 means items weigh 5% of normal). Capped at 99.
- Changing sandbox capacity mid-game had no effect on existing carts. Cart capacity was frozen at creation time. The capacity system now reads the live sandbox setting dynamically. Admin changes the multiplier, all carts update immediately.
- Recipe display showed raw ID instead of name. Added translation file for crafting UI.

### Sandbox Changes

- `WeightReductionMultiplier` renamed to `WeightReduction`. Existing saves with the old setting fall back gracefully. Default changed from 100 to 95.

### Compatibility

- Guns of 93 crashes when picking up carts (AttachmentAdjust tries to call weapon methods on a cart item). Root cause is an operator precedence error in Guns93's instanceof guard — bug report filed with the Guns93 developer.

---

## v2.0.0 — Initial B42 release

Clean rewrite of the cart system for Project Zomboid Build 42. Fixes the duplication, equip, and MP desync bugs from the pre-existing ZuperCarts family.

Features at launch:
- ShoppingCart with durability system (distance-based degradation)
- MP-safe timed actions (pickup, drop, equip, repair)
- Native container support (Capacity, WeightReduction, RunSpeedModifier)
- Server-authoritative instant drop for combat reactivity
- Visual fill-state model switching (empty / partial / full)
- Sandbox-configurable capacity, durability, spawn rate
- Addon extensibility API (`SaucedCarts.registerCart`)
- Tooltip + context menu integration

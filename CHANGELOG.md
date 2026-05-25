# Changelog

All notable changes to SaucedCarts are documented here. Latest version first.

## v2.1.8 — 2026-05-26 (Weight Reduction sandbox setting now applies)

### Bug Fixes

**Cart weight reduction ignored the sandbox "Weight Reduction %" setting**
Carts always reduced contents weight by the script default (95%) no matter what the sandbox option was set to — set it to the 99% max and the game still showed and applied 95%. Root cause: `applyMultipliers` called `setWeightReduction` on `cart:getItemContainer()` (the inner `ItemContainer`), a field the engine never reads. Vanilla reads the **outer `InventoryContainer`'s** own `weightReduction` field for both the tooltip display (`InventoryContainer.java:207-210`) and the actual encumbrance reduction (`InventoryContainer.getEquippedWeight`, `:283-291`). The inner write was a no-op, so the cart stayed pinned to the script's `WeightReduction=95` regardless of the sandbox value. Two-part fix:
- Stamp the value on the cart item itself (`cart:setWeightReduction`), which `InventoryContainer.setWeightReduction` (`:139-143`) propagates to both the wrapper and inner fields.
- Decoupled weight-reduction application from the one-shot `multipliersApplied` guard. Unlike capacity (interceptable via `__classmetatables`), weight reduction is a plain Java field read by Java-internal callers, so it can't be overridden on read — it's re-stamped on every `applyMultipliers` touch instead. Existing carts therefore pick up a mid-game sandbox change on the next equip / pickup / relog.

### Technical

- 4 new regression tests in `OfflineCapacityOverrideTests.lua` assert against the outer `InventoryContainer.weightReduction` (the field vanilla reads): stamps the sandbox value, re-stamps past the `multipliersApplied` guard, defaults to 95 when the key is absent, and propagates to the inner container. Sensitivity-checked: all wrapper assertions fail against the old inner-container code.
- 244 offline tests passing (was 240 at v2.1.7).

### Known limitation (unchanged)

The capacity number shown in a cart's tooltip is still vanilla's `50 − cartWeight` cap (≈42), not the sandbox-scaled value. That figure is computed by a Java-internal call inside the tooltip renderer that our Lua capacity override can't intercept; the cart's *actual* working capacity is unaffected and honors the multiplier. Left as-is — correcting only the displayed label would require re-implementing the vanilla tooltip.

### Backward Compatibility

- Save-safe. No ModData schema changes. No `SCHEMA_VERSION` bump.
- Carts created on older versions re-stamp to the current sandbox weight-reduction value automatically on next equip/pickup/load.

## v2.1.7 — 2026-05-22 (Stacked containers, vehicle trunks, sprite refresh, batch tuning)

### Bug Fixes

**Vehicle trunk ↔ cart transfers silently bailed** (reported by friend playtest)
Vehicle containers (trunk, glovebox, seats, trailer bed) collapsed to `"inv"` in `classifySide` because there was no vehicle branch — same shape as the v2.1.5 bag bug and the v2.1.6 stacked-box bug. The server then resolved `playerInv` as the non-cart endpoint, the item was nowhere to be found, the action animated but nothing moved. Two-part fix:
- `classifySide` detects vehicle containers via `container:getVehiclePart()` (with `instanceof(parent, "BaseVehicle")` + parts-iteration fallback for builds where the Java method isn't Lua-exposed), emits a new `"vehicle"` kind serializing `(vehicleId, partIndex)`. Mirrors vanilla `ContainerID.setObject`'s `Vehicle` type (`ContainerID.java:174-178`).
- `resolveSide` adds a `"vehicle"` branch: `getVehicleById(vid)` → `vehicle:getPartByIndex(idx)` → `part:getItemContainer()`. Same path vanilla `ContainerID.findObject` takes at `ContainerID.java:444-459`.
- `findItemNearPlayer` was the symmetric gap on the lookup side. Added two scans: (1) parts of `player:getVehicle()` for the seated case, (2) per-tile `IsoGridSquare:getVehicleContainer()` within the search radius for the "player walked up to a trunk" case (dedupes multi-tile vehicles via a seen-set). `IsoCell.getVehicles()` is a Java `Set` — no indexed access — so we use vanilla's per-square lookup instead.

**Stacked same-type containers — item landed in the wrong box** (Workshop report: MrSplendid)
When two boxes / crates / fridges-with-freezers / double-door wardrobes share a tile, the client's old serialization (`square, containerType`) couldn't disambiguate them — the server picked the first match (typically the bottom box) and the item landed there instead of where the user clicked. Mirrors vanilla `ISInventoryPage.lua:1405-1410`: `classifySide` now also emits `objectIndex` (which `IsoObject` on the tile) and `containerIndex` (which container on that object); `resolveSide` resolves exactly that pair first, with legacy type-match kept as fallback for old in-flight clients. Three regression tests in `OfflineCartTransferTargetTests.lua`.

**Content-display furniture sprites never refreshed after cart transfer**
Vanilla `ISInventoryTransferAction:transferItem` calls `ItemPicker.updateOverlaySprite` on each side's parent `IsoObject` so bookcase / fridge / stacked-crate overlay sprites update when contents change (`ISInventoryTransferAction.lua:661-668`, server/SP only). Our `ISCartTransferAction` bypasses that action entirely — so the underlying overlay never refreshed for any cart transfer. Now mirrored in `performCartTransfer`'s container↔container branch with the same `not isClient()` gate. `setOverlaySprite`'s server-side broadcast (`IsoObject.java:5100`, `GameServer.updateOverlayForClients`) propagates to remote clients automatically. Locked by `OfflineCartTransferSpriteTests.lua`.

**Stacks (nails, screws, etc.) transferred one at a time**
Vanilla `ISInventoryTransferAction` absorbs a contiguous run of same-src/same-dest queued actions inside one timed action (`ISInventoryTransferAction.lua:699-731`'s `checkQueueList`). Our `ISCartTransferAction` derives from `ISBaseTimedAction` (not `ISInventoryTransferAction`) so it didn't inherit that — every queued transfer ran its full duration in series. Added `canMergeAction` + pure `collectBatch` that coalesces same-`FullType` light items (weight ≤ 0.1, vanilla's `checkQueueList` threshold at line 713) into one batched `cartTransfer` network command. Mixed types or heavier items each get their own action with their own weight-scaled duration. `MERGE_CAP=50` prevents pathological packet sizes on huge "take all" runs.

**Item transfer duration didn't scale with weight**
`ISCartTransferAction:new` was using a flat `maxTime = time or 10` so a nail and a brick took the same time. Ported vanilla `ISInventoryTransferAction:new`'s full encumbrance formula inline: base 120 (cross-container) or 50 (mixed with character inv), × `min(weight, 3)` × destCapacityDelta (clamped ≥ 0.4), × game-mode / floor-drop / Dextrous (0.5×) / All Thumbs + awkward gloves (2.0×) modifiers, with `isTimedActionInstant()` override. Bit-identical to vanilla's tuning — light items snappy, heavy items feel weighty.

**Right-click "Unequip" → cart duplicated in MP**
The unequip path's local `ForceDropGuard` window opened *before* `requestInstantDrop` told the server to remove the cart from the player's hand, so by the time the server's drop ran, the guard had already closed and vanilla's `forceDropHeavyItems` re-dropped the same cart a second time (V1 dupe vector, MP-specific). Reordered: server-authoritative drop request fires first; local guard now wraps the full server round-trip.

**Network-boundary type-coercion missing in `handleCartTransfer`**
A buggy / pre-version / modified client could send non-numeric `itemId` / `cartId` / square-coords; the server-side `getItemById` / `getGridSquare` / `getItemWithIDRecursiv` calls are Java methods that throw an uncaught `RuntimeException` on non-numeric args, aborting the handler mid-flight. Added `tonumber()` coercion + reject for the two required IDs at the one place client input enters. Filters non-numeric entries from `itemIds` batches. Regression: probe-cart-transfer-fuzz G10 + the 20-case malformed-arg gauntlet.

### Corpse Storage BETA

**Gate now requires explicit `true` (was: anything-not-false)**
`SandboxVars.SaucedCarts.EnableCorpseStorage == false` returned `nil` on v2.1.4 saves missing the new option — `not (nil == false)` is `true`, so the BETA silently activated on every upgraded save. Now checks for explicit `true`. Saves without the option read as "feature off".

**Silent-drop boundary fixed (no more "corpse appears, instantly disappears")**
Past-rot unload used the `removalAt` threshold (sandbox `HoursForCorpseRemoval`), but vanilla `IsoDeadBody.updateBodies` (`IsoDeadBody.java:1534`) despawns non-skeleton zombie corpses at `age >= hoursForCorpseRemoval` which is our **`skeletonAt`**, not `removalAt`. Materializing a body in the 24-32h window meant it appeared for one frame and vanilla removed it on the next tick. Boundary is now `skeletonAt`, matching vanilla's effective despawn line.

**`loadCorpseFailed` client notification path**
Race window (cart filled between client gate-check and server handler firing) used to silent-fizzle: no halo, no log. Server now signals the originating client with a reason code (`cart_full` / `no_cart` / `fallback`); client renders the corresponding halo via `HaloTextHelper`.

**Removed: cart corpse-stink integration + `EnableCorpseStink` sandbox option**
The investigated MP-stink design relied on `CorpseCount` and `FliesSound` being Lua-exposed for cross-client broadcast. Verified against B42.18 decompiled source — neither has `@LuaMethod` annotations and neither is in `LuaManager.exposeAll`. Not implementable from a mod without engine-level changes. Pulled `publishCartStink`, `emitDelta`, all `__broadcast.stink` packet handling, and the sandbox toggle. `reconcile` simplified to pure modData accounting. No save-data impact.

### Hardening

**Vanilla-API contract test (`OfflineApiContractTests.lua`)**
Locks our `ISCartTransferAction`'s public surface against `ISInventoryTransferAction`'s. Walks every public method on vanilla's class — every one must either exist on ours or be in an audited `KNOWN_VANILLA_INTERNALS` allowlist. Lifecycle methods (`:new`, `:isValid`, `:start`, `:update`, `:perform`, `:stop`, `:waitToStart`, `:getDuration`) asserted directly-defined-not-inherited via `rawget`. Catches future PZ-patch additions OR an accidental inheritance refactor before players hit the "Object tried to call nil" crash.

**Test coverage**
240 offline tests passing (was 221 at v2.1.6). New: `OfflineCartTransferTargetTests` (stacked-box disambiguation), `OfflineCartTransferSpriteTests` (sprite refresh both sides), `OfflineCartTransferBatchTests` extended (canMergeAction + collectBatch + new FullType/weight gates + cap), `OfflineApiContractTests`, `OfflineCorpseObserverTests`.

### Backward Compatibility

- Save-safe. No ModData schema changes. No `SCHEMA_VERSION` bump.
- `EnableCorpseStink` sandbox option removed — silently ignored on old configs.
- BETA gate hardening means upgraded v2.1.4 saves no longer have corpse-storage accidentally enabled; users who *want* it on must toggle it in sandbox.
- Old `depositToGroundCart` server command and `ISCartDepositAction` symbol both still aliased (no break for pre-v2.1.4 in-flight clients).
- Pre-v2.1.7 clients connecting to a v2.1.7 dedi will still work for stacked-container and vehicle transfers — server falls back to the defensive `item:getContainer()` recovery path when classifications are missing.

## v2.1.6 — 2026-04-28 (Multi-container resolution + vanilla compat hardening)

### Bug Fixes

**Fridge / freezer / multi-container objects → cart silently failed**
`findItemNearPlayer` and `resolveSide` for `kind="world"` only iterated `obj:getContainer()` — which returns the FIRST container of an `IsoObject`. Multi-container tiles (fridges have a fridge + freezer pair, some counters have multiple cells, double-door wardrobes, certain workbenches) silently failed item lookup when the player opened a non-primary container. Symptom: progress bar fills, animation plays, item never moves; dedi log showed `cartTransfer: item NNN NOT FOUND for player ... srcKind=world` repeating every drag. Both call sites now iterate every container per object via `getContainerCount()` + `getContainerByIndex(i)`, and `resolveSide` adds a `getContainerByType(containerType)` fast path. Mirrors vanilla `ContainerID.findObject`'s `ObjectContainer` resolution.

**Crash when crafting with cart as source container (`Object tried to call nil`)**
Vanilla `ISCraftingUI.ReturnItemToContainer` calls `action:setAllowMissingItems(true)` to keep the action alive when ingredients were destroyed mid-craft (e.g. molotov gas can). Our `ISCartTransferAction` is substituted for vanilla's `ISInventoryTransferAction` by the interceptor — but didn't expose `setAllowMissingItems`. Reproducer: charcoal in cart → simple furnace → smelt iron in crucible → crash. Added explicit shims for both `setAllowMissingItems` and `setOnComplete` (the latter is also called by craft-complete, alarm, map-check, inspect-clothing flows). `:isValid` now honors `allowMissingItems` by setting `dontAdd=true` and proceeding; `:perform` skips the move and fires `onCompleteFunc` so vanilla cleanup chains complete normally.

**Cart in vehicle trunk not findable**
`findCartNearPlayer` only checked the player's main inventory and a 3-tile ground sweep. Carts stowed in a vehicle's trunk container were invisible to the lookup, causing transfers to silently bail. Added a vehicle-part scan when `player:getVehicle()` is non-nil (mirrors vanilla `ContainerID.ObjectInVehicle` resolution), and bumped the ground-sweep radius from 3 → 4 tiles. The inventory lookup now uses `getItemWithIDRecursiv` (vanilla's recursive primitive) instead of the non-recursive `getItemById`, so any future cart-in-bag scenario also resolves correctly.

**Tooltip + DisplayName translations missing in-game**
`Tooltip_SaucedCarts_ShoppingCart`, `Tooltip_SaucedCarts_AttachmentKit`, and `DisplayName_SaucedCarts_ShoppingCart` were defined in `UI_EN.txt` / `UI.json`. PZ's translation system looks up item-script `Tooltip = ...` references in `Tooltip_EN` and item display names in `ItemName_EN` — the keys never resolved. Created `Tooltip_EN.txt` + `Tooltip.json` and `ItemName_EN.txt` + `ItemName.json` and moved the entries into them. `UI_EN.txt` retains pointer comments noting where they moved.

### Hardening

**Vanilla-API contract test (`OfflineApiContractTests.lua`)**
Locks `ISCartTransferAction`'s API surface against `ISInventoryTransferAction`'s. Walks every public method on vanilla's class — every one must either exist on our class or be in an audited `KNOWN_VANILLA_INTERNALS` allowlist. Also asserts `:new`, `:isValid`, `:start`, `:update`, `:perform`, `:stop`, `:waitToStart`, `:getDuration` are *directly* defined on our class (not inherited). When PZ ships a new vanilla method in a future patch — or a future refactor accidentally tries inheritance — the test fails before players hit the crash. 7 new tests; 221 offline tests passing total (was 214).

**Network dispatcher logs back to debug-gated**
The dedi-side bail logs (`cart NOT FOUND`, `item NOT FOUND`, etc.) and per-cmd dispatcher receipts in `Network.lua` were promoted to `.log()` for diagnostic capture. After confirming the multi-container bug above with their help, reverted to `.debug()` to keep server logs quiet. Kept the bail-path code structured so re-promoting is a one-line edit when chasing the next "doesn't move" report.

### Backward Compatibility

Save-safe. No ModData schema changes. Safe to upgrade mid-save. No new sandbox options, no API breaks.

## v2.1.5 — 2026-04-26 (MP transfer fixes + durability UX + corpse storage BETA)

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

- 5 new offline regression tests for `"world"` kind + 5 for `"bag"` kind for the transfer fixes above.
- 1000-iteration property-based fuzzer alternates new/old client classifier per iteration, verifies conservation + uniqueness + moved invariants.
- `pz-test-kit/shell` live stress probe drives 60+ real `handleCartTransfer` invocations against a running dedicated server using actual PZ objects (not mocks): 0 invariant violations.
- Decompiled-source-verified writeup of PZ item transmit semantics in `pz-dev-tools/knowledge/pz-item-transmit-semantics.md` (cross-cutting; covers `AddItem` vs `SynchSpawn`, `sendAddItemToContainer` wire format, container-routing rules).

### Additional Bug Fixes

**`ISGrabCorpseAction` freeze when grappling with a cart equipped**
The instant-drop force-drop path in `InstantDrop.lua` (and its `AnimationSync.requestInstantDrop` server-handler twin) called `ISTimedActionQueue.clear(player)` mid-tick, which destroyed the in-flight `ISGrabCorpseAction` that triggered the force-drop in the first place. Symptom: player could spin and push but not walk after grappling a corpse with a cart in hand. Removed the queue clear from both SP + MP paths and the server handler. Locked by 2 offline tests in `OfflineInstantDropQueueTests.lua`.

**Cart inventory UI not refreshing after a transfer to/from an equipped cart**
`performCartTransfer`'s container-↔-container, floor-pickup, and floor-drop branches mutated containers but never marked them dirty for repaint. Server-authoritative state was correct; the player's local UI was stale until they reopened the cart panel. Added `setDrawDirty(true)` on src + dest in every `performCartTransfer` branch. Locked by 3 offline tests.

**Server→client broadcasts silently dropped on first session**
`Network.lua` registered the `Events.OnServerCommand` dispatcher only when `isClient()` returned true at module-load time — which it doesn't during the main-menu cold-start. Lua's `require` cache then prevented the file from re-running on dedi connect, so the dispatcher was never installed and every server-broadcast command (cart visual sync, etc.) silently no-op'd on the client. Both dispatchers now register unconditionally; vanilla only fires each in the right context anyway.

**Sandbox option lookup returned nil from Lua**
The decompiled Java pattern `SandboxOptions.instance.hoursForCorpseRemoval.getValue()` works because Java has direct field access. From Lua, that path always returns `nil` — the correct API is `SandboxOptions.instance:getOptionByName("HoursForCorpseRemoval")` (capitalized name). Without this fix, the corpse-storage rot threshold logic always took the "never decay" branch regardless of sandbox setting.

**SP grapple lock — "spin and push but can't walk"**
Server load handler called `becomeCorpseSilently` on the grapple-wrapper zombie *before* releasing the player's grapple. In SP (single VM), the grappleable's reference was dangling at release time; vanilla's `setDoGrappleLetGo` couldn't unwind the drag-corpse movement state cleanly → player stuck in the "dragging" pose. Reordered: release grapple while the wrapper is still live, then mutate.

**Right-click "Grab Body" bypassed cart rot check**
`ISCartTransferAction`'s drag-to-ground path silently dropped past-skeletonAt corpses correctly, but the right-click "Grab Body" path went through vanilla's `ISGrabCorpseItem` directly — which materialized the body via `pickUpCorpseItem`, vanilla's `updateBodies` ticker then despawned it on the next tick (silent flicker, no halo). New `GrabCorpseInterceptor` wraps `ISGrabCorpseItem:complete` and silent-drops with the same halo as the drag path, only when the corpse is sourced from a SaucedCart (vanilla containers like crates / coffins keep their normal grab semantics).

**V hotkey queued bugged pickup when grappling with corpse storage off**
If a player was actively dragging a corpse but `EnableCorpseStorage` was disabled, the V hotkey forced `draggingCorpse = false` and fell through to equip/pickup. Vanilla blocks pickup while grappling so the action immediately failed its own `:isValid` mid-tick, logging "bugged action" with no player feedback. Now halos `"Drop the body before picking up a cart."` and bails before queueing the doomed action.

**Flashlight install rejected valid materials**
The attachment-material table in `FlashlightMenu.lua` + `ISInstallFlashlightAction.lua` referenced `Base.CableTies` (which doesn't exist in vanilla — the actual item is `Base.Zipties`) and required `uses = 2` for `Base.Rope` and `Base.Scotchtape` (both `base:normal` single-use items). The finder iterates per-item without aggregating, so 2 ropes were treated as 2 items each with 1 use, none satisfying `>= 2`. Renamed CableTies → Zipties; dropped Rope and Scotchtape to `uses = 1`. DuctTape (drainable) and Twine (drainable, UseDelta=0.2 → 5 uses per fresh item) unchanged — they already worked.

### Beta Opt-in

A WIP **corpse-storage** feature ships in this build but is **disabled by default** behind one sandbox toggle: `Enable Corpse Storage [BETA]`. When enabled:
- Right-click a corpse → "Grab Body", then right-click your cart → "Load Corpse into &lt;cart&gt;" (or use the V hotkey while grappling). The corpse goes into the cart's inventory as a `Base.CorpseMale/Female` item with full byteData preserved (clothing, attached items, rot stage, reanimation state — vanilla's own serialization).
- Vanilla-faithful rot accounting: the body's `deathTime` is stamped onto the item's modData at load, restored on unload via `setDeathTime`, so vanilla's `updateBodies` ticker resumes at the correct rot stage. Corpses age while stored.
- Drag-to-ground and right-click "Grab" both unload normally for fresh corpses; past the sandbox `HoursForCorpseRemoval` threshold (the vanilla despawn boundary for non-skeleton zombie corpses), the corpse silent-drops with a halo "Corpse fully decomposed" — no body materializes since vanilla would despawn it on the next tick anyway.
- In-cart purge of fully-decomposed items fires on cart equip / drop / break events (not per-tile during pushes — checked at the moments players actually interact with the cart).
- Cart-full / no-cart / decomposed scenarios all halo immediately, including races where the cart fills between click-time and the server-handler firing (server fires a `loadCorpseFailed` notification back to the originating client).

Public release planned for a future version. The companion "cart corpse stink" idea (loaded carts contribute to vanilla's corpse-sickness + flies-buzz registries) was investigated and pulled — vanilla's `CorpseCount` and `FliesSound` are not Lua-exposed (no `@LuaMethod` annotations, not in `LuaManager.exposeAll`), so feeding cart contributions into vanilla's sickness pathway isn't implementable from a mod without engine-level changes.

### Durability UX

Three player-feedback improvements addressing "carts unexpectedly explode" reports:

- **Threshold halos at 50% / 25% / 10%** — `"The cart is starting to creak under the load"`, `"This cart is getting pretty beat up..."`, `"This cart is about to fail! I need to repair or unload NOW."` Centralized inside `applyAccumulatedDamage` so both the pickup and combat-drop paths fire them. modData marker prevents repeat-spamming on the same threshold; repair resets the marker so warnings start fresh on the next damage cycle.
- **Repair menu shows material requirement inline** — option label is now `"Repair Cart (have Scrap Metal)"` (option enabled) or `"Repair Cart (need Scrap Metal)"` (grayed out). Players see what's missing without having to hover for the tooltip.
- **Pre-existing 25% halo** centralized along with the new 50% / 10% — same code path, no more duplicated logic in `InstantDrop.lua`.

### Test Coverage

- 214 offline tests passing (was 158 at v2.1.4). New coverage spans corpse load/unload, rot stamp/restore/purge, dual-VM observer semantics, the instant-drop queue regression, and cross-VM observer contract for the corpse pipeline.

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

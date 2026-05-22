--[[
    SaucedCarts — PZ Test Kit configuration

    Runs only the offline-capable tests. The existing in-game Tests/*.lua
    files (CoreTests, DuplicationTests, etc.) depend on real PZ world state
    (getCell():getGridSquare, instanceItem for real InventoryContainer,
    live animation variables). Those stay in-game-only for now.

    New offline tests for vanilla-interaction bugs (forceDropHeavyItems dupe,
    etc.) live in Tests/offline/*.lua and use faithful Lua reimplementations
    of the vanilla functions to prove the mechanism without needing the
    real PZ world.
]]

-- Stub vanilla UI singletons that vanilla_requires-loaded files reference
-- at module-load time. This file runs BEFORE vanilla_requires fires (the
-- pz-test.lua body executes during config-load, vanilla_requires fires
-- after). Without these stubs, e.g. ISInventoryTransferAction.lua would
-- crash at line 5 trying to set `ISInventoryPage.putSoundContainer = nil`.
if not ISInventoryPage then ISInventoryPage = {} end


return {
    -- Cross-mod: none required.
    dependencies = {},

    -- Load real vanilla PZ files into the test env so our code exercises
    -- the actual implementation (not a hand-written mock). Required for
    -- CartTransferInterceptor which delegates moves to vanilla
    -- ISTransferAction:transferItem. Paths are relative to
    -- $PZ_INSTALL/media/lua/ without the .lua extension.
    vanilla_requires = {
        "shared/ISBaseObject",              -- base class for ISTransferAction
        "shared/TimedActions/ISBaseTimedAction",  -- base for ISCartDepositAction
        "shared/TimedActions/ISTransferAction",   -- canonical item move
        -- ISInventoryTransferAction: introspected by OfflineApiContractTests.
        -- Locks the API surface our ISCartTransferAction must mirror so
        -- vanilla code calling action:setOnComplete / action:setAllowMissing-
        -- Items / etc. doesn't crash. Depends on the ISInventoryPage stub at
        -- the top of this file.
        "client/TimedActions/ISInventoryTransferAction",
        -- ISUnequipAction: ContainerRestrictions hooks its :complete to
        -- force-drop carts. OfflineUnequipDupeTests wraps the real vanilla
        -- complete to prove the MP client+server double-drop dupe.
        "shared/TimedActions/ISUnequipAction",
    },

    -- GrabCorpseInterceptor.lua does `pcall(require,
    -- "TimedActions/ISGrabCorpseItem")` — at runtime that pcall gracefully
    -- skips when the vanilla file is absent, but the pz-test-kit module
    -- pre-scanner resolves requires eagerly and hard-fails. The grab hook
    -- has no offline test depending on the real vanilla class, so silently
    -- ignore the require in the test env.
    stub_requires = {
        "TimedActions/ISGrabCorpseItem",
    },

    -- Preload SaucedCarts namespace so tests can inspect it without each
    -- file re-requiring. CartData defines SaucedCarts.registerCart /
    -- getCartData / CartTypes — tests for capacity / durability / pickup
    -- need a registered cart type to exercise lookup paths.
    preload = {
        "SaucedCarts/Core",
        "SaucedCarts/CartData",
    },

    -- Sandbox defaults — mostly mirror media/sandbox-options.txt, but the
    -- BETA corpse-storage + stink toggles ship to the live Workshop with
    -- default=false (they're flagged [BETA] in the UI for opt-in testing).
    -- Force them ON in the offline test environment so the storage / rot /
    -- Sync code paths stay covered by the 200+ offline tests; without
    -- this override every CorpseStorage.isEnabled() returns false and the
    -- handler short-circuits.
    sandbox = {
        SaucedCarts = {
            EnableMod = true,
            EnableCorpseStorage = true,
            SpawnRate = 100,
            CapacityMultiplier = 100,
            DurabilityMultiplier = 100,
            MaxCartsPerBuilding = 1,
        },
    },

    -- The existing in-game test files assume real PZ state. Exclude them
    -- from offline runs — they're still executed by the in-game TestRunner.
    -- Offline tests live in Tests/offline/*.lua.
    test_file_excludes = {
        "CoreTests.lua",
        "DuplicationTests.lua",
        "FlashlightTests.lua",
        "FunctionalTests.lua",
        "MPSyncTests.lua",
        "OrphanTests.lua",
        "SaucedCartsTests.lua",
        "SaucedCartsTestsPanel.lua",
        "SerializationTests.lua",
        "TestFileOutput.lua",
        "TestHelpers.lua",
        "TestRunner.lua",
        "VisualTests.lua",
        "WorldSpawningTests.lua",
    },
}

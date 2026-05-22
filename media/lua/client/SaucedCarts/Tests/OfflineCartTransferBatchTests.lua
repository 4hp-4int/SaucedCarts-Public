--[[
    SaucedCarts — Cart transfers run ONE ITEM AT A TIME
    ===================================================

    Player report (v2.1.6): moving a stack of nails between a container and a
    cart, the player transfers them one at a time; with non-cart containers
    they go in bulk.

    Root cause: CartTransferInterceptor swaps vanilla ISInventoryTransferAction
    for ISCartTransferAction, which derives from ISBaseTimedAction and does
    NOT inherit vanilla's checkQueueList / canMergeAction. Vanilla coalesces a
    run of same-src/dest queued transfer actions into batches; without it each
    of the N queued ISCartTransferActions runs as its own full-duration timed
    action → one nail at a time.

    Fix: give ISCartTransferAction a canMergeAction + a pure collectBatch that
    coalesces a contiguous run of mergeable following actions, so perform()
    sends ONE batched cartTransfer (and removes the merged actions from the
    queue). These tests lock the merge predicate + batching logic.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/TimedActions/ISCartTransferAction"

local function act(opts)
    -- A minimal stand-in for a queued ISCartTransferAction. Real actions
    -- carry these same fields; canMergeAction only inspects them.
    -- v2.1.7: items now also need getFullType + getWeight because we gate
    -- batching on same-type + light-weight (vanilla's checkQueueList parity).
    local fullType = opts.fullType or "Base.Nails"
    local weight   = opts.weight   or 0.01
    return setmetatable({
        Type = "ISCartTransferAction",
        item = {
            _id = opts.itemId,
            _fullType = fullType,
            _weight = weight,
            getID = function(s) return s._id end,
            getFullType = function(s) return s._fullType end,
            getWeight = function(s) return s._weight end,
        },
        srcContainer = opts.src,
        destContainer = opts.dest,
        direction = opts.direction or "in",
        cartItem = opts.cart,
        onCompleteFunc = opts.onComplete,
    }, { __index = ISCartTransferAction })
end

local tests = {}

local SRC, DST, CART = {}, {}, {}

tests["canMerge_true_for_same_src_dest_dir_cart"] = function()
    local a = act({ itemId = 1, src = SRC, dest = DST, cart = CART })
    local b = act({ itemId = 2, src = SRC, dest = DST, cart = CART })
    return Assert.isTrue(a:canMergeAction(b),
        "identical src/dest/direction/cart actions merge")
end

tests["canMerge_false_for_different_dest"] = function()
    local a = act({ itemId = 1, src = SRC, dest = DST, cart = CART })
    local b = act({ itemId = 2, src = SRC, dest = {}, cart = CART })
    return Assert.isFalse(a:canMergeAction(b), "different destContainer blocks merge")
end

tests["canMerge_false_for_different_direction"] = function()
    local a = act({ itemId = 1, src = SRC, dest = DST, cart = CART, direction = "in" })
    local b = act({ itemId = 2, src = SRC, dest = DST, cart = CART, direction = "out" })
    return Assert.isFalse(a:canMergeAction(b), "different direction blocks merge")
end

tests["canMerge_false_when_onComplete_present"] = function()
    local a = act({ itemId = 1, src = SRC, dest = DST, cart = CART })
    local b = act({ itemId = 2, src = SRC, dest = DST, cart = CART,
        onComplete = function() end })
    return Assert.isFalse(a:canMergeAction(b),
        "callback-bearing action stays standalone (vanilla parity)")
end

tests["canMerge_false_for_non_cart_transfer_action"] = function()
    local a = act({ itemId = 1, src = SRC, dest = DST, cart = CART })
    return Assert.isFalse(a:canMergeAction({ Type = "ISInventoryTransferAction" }),
        "only merges with other ISCartTransferActions")
end

tests["canMerge_false_for_different_fulltype"] = function()
    local a = act({ itemId = 1, src = SRC, dest = DST, cart = CART, fullType = "Base.Nails" })
    local b = act({ itemId = 2, src = SRC, dest = DST, cart = CART, fullType = "Base.Screws" })
    return Assert.isFalse(a:canMergeAction(b),
        "different item types do NOT batch — each stack runs in its own timed action")
end

tests["canMerge_false_for_heavy_item"] = function()
    local a = act({ itemId = 1, src = SRC, dest = DST, cart = CART, weight = 0.5 })
    local b = act({ itemId = 2, src = SRC, dest = DST, cart = CART, weight = 0.5 })
    return Assert.isFalse(a:canMergeAction(b),
        "items above the 0.1 light-item threshold do NOT batch (vanilla parity)")
end

tests["canMerge_true_for_same_light_stack"] = function()
    local a = act({ itemId = 1, src = SRC, dest = DST, cart = CART,
        fullType = "Base.Nails", weight = 0.01 })
    local b = act({ itemId = 2, src = SRC, dest = DST, cart = CART,
        fullType = "Base.Nails", weight = 0.01 })
    return Assert.isTrue(a:canMergeAction(b),
        "two light nails of the same FullType merge")
end

-- The batching itself: a contiguous run of mergeable followers is absorbed,
-- and the first non-mergeable action stops the run (order preserved).
tests["collectBatch_coalesces_contiguous_run_and_stops_at_boundary"] = function()
    local self_ = act({ itemId = 10, src = SRC, dest = DST, cart = CART })
    local following = {
        act({ itemId = 11, src = SRC, dest = DST, cart = CART }), -- merge
        act({ itemId = 12, src = SRC, dest = DST, cart = CART }), -- merge
        act({ itemId = 13, src = SRC, dest = {},  cart = CART }), -- BOUNDARY
        act({ itemId = 14, src = SRC, dest = DST, cart = CART }), -- after boundary
    }
    local items, merged = ISCartTransferAction.collectBatch(self_, following)

    if not Assert.equal(merged, 2, "exactly 2 followers absorbed (stops at boundary)") then
        return false
    end
    if not Assert.equal(#items, 3, "batch = self + 2 = 3 items") then return false end
    if not Assert.equal(items[1]:getID(), 10, "self item first") then return false end
    if not Assert.equal(items[2]:getID(), 11, "then follower 11") then return false end
    return Assert.equal(items[3]:getID(), 12, "then follower 12; 13/14 excluded")
end

tests["collectBatch_single_when_next_not_mergeable"] = function()
    local self_ = act({ itemId = 20, src = SRC, dest = DST, cart = CART })
    local following = { act({ itemId = 21, src = SRC, dest = {}, cart = CART }) }
    local items, merged = ISCartTransferAction.collectBatch(self_, following)
    if not Assert.equal(merged, 0, "nothing absorbed") then return false end
    return Assert.equal(#items, 1, "batch is just self")
end

tests["collectBatch_caps_batch_size"] = function()
    local self_ = act({ itemId = 0, src = SRC, dest = DST, cart = CART })
    local following = {}
    for i = 1, 200 do
        following[i] = act({ itemId = i, src = SRC, dest = DST, cart = CART })
    end
    local items = ISCartTransferAction.collectBatch(self_, following)
    -- Bounded so a huge "take all" can't build a pathological single packet.
    if not Assert.isTrue(#items <= 50, "batch capped at 50 (got " .. #items .. ")") then
        return false
    end
    return Assert.isTrue(#items > 1, "but it does batch")
end

return tests

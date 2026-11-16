--!nonstrict
--[[
	Anchor / Trade - dupe-proof, loss-proof trades and gifts (docs/SPEC.md section 4).

	USAGE
		local ok, reason = Anchor.Trade(Data:Get(a), Data:Get(b), function(da, db)
			if da.Coins < 100 or db.Items.Gem == nil then
				return false                    -- cancel: nothing changes
			end
			da.Coins -= 100; db.Coins += 100
			da.Items.Gem, db.Items.Gem = db.Items.Gem, nil
		end)

		Data:Gift(userId, function(data) data.Coins += 50 end)   -- online anywhere or offline
		Data:Gift(userId, fn, { Id = "event_2026_login" })       -- Id: at most once per player

	RESULT (what the game should show)
		true                    Trade done. Both sides have their new data now (or, if B left
		                        mid-trade, B gets it on whichever server loads B next). Show "Trade
		                        complete".
		false, "Cancelled"      fn returned false. Nothing changed.
		false, "Error", msg     fn errored. Nothing changed. Show "Trade failed".
		false, "Invalid", msg   Bad arguments, same profile twice, view-mode profile, or the
		                        drafts hold values a DataStore can't store. Nothing changed.
		false, "Inactive"       A or B is not loaded on this server (left / not loaded yet).
		false, "Busy"           Another trade on A or B did not finish within opts.Timeout.
		false, "SaveFailed"     A's save kept failing (DataStore outage). The trade was undone;
		                        nothing changed. Show "Trade failed, try again".
		false, "SessionLost"    A's session ended mid-commit and no write of the trade could be
		                        confirmed. Usually nothing changed; if the trade did reach A's
		                        save, it completes on its own when A is next loaded. Either way
		                        no item is duplicated or lost.

	PROTOCOL
		1. Lock A and B (one trade at a time per profile; later trades QUEUE, up to
		   opts.Timeout = 30 s, then "Busy"). Queued trades run fn on fresh data.
		2. fn(draftA, draftB) on deep copies, in a pcall. Diff drafts -> patches PA, PB.
		3. Same tick: apply PA to live A and add A.MetaData.Anchor.Tx[id] = {peer, patch=PB, t}.
		   Force-save A (up to 3 tries). This write is the durable intent.
		   - Not saved and A still active: undo PA and the Tx record -> "SaveFailed".
		   - A's session ended: wait for its release save (it carries the Tx) -> true when it
		     lands, else "SessionLost".
		4. Once a write of A containing Tx[id] has landed (AfterSave hook): deliver PB.
		   B active here: apply PB to live B + B.MetaData.Anchor.Applied[id] in the same tick,
		   force-save B. Otherwise (or if that save fails): MessageAsync B's key with
		   {AnchorTx = id, Patch = PB}; whichever server owns B applies it once (Applied dedup).
		5. When B's save (or the message) is confirmed: drop A's Tx[id] and save A.
		6. Recovery: a profile that loads with Tx records re-delivers them (B dedups).
		   Applied entries are pruned after 30 days, max 500.

	Live proxies: opts.Live = {liveA, liveB} (Ripple states wrapping profile.Data in place),
	or the states from store:UseRipple(). Patches are applied through them; a write the proxy
	rejects is written to the plain table instead and Anchor.OnError fires.
--]]

local TX_LOCK_TIMEOUT = 30
local INTENT_SAVE_ATTEMPTS = 3
local APPLIED_MAX_AGE = 30 * 24 * 60 * 60
local APPLIED_MAX_COUNT = 500

local Trade = {}

function Trade.install(Anchor, Core)
	local Patch = require(script.Parent.Patch)
	local HttpService = game:GetService("HttpService")
	local OnError = Anchor.OnError

	local function report(profile, message)
		local store_name = profile.ProfileStore and profile.ProfileStore.Name or "?"
		warn(`[Anchor]: {message} (STORE:{store_name}; KEY:{tostring(profile.Key)})`)
		OnError:Fire(message, store_name, profile.Key)
	end

	local function reporter(profile)
		return function(message)
			report(profile, message)
		end
	end

	local function liveFor(profile)
		return rawget(profile, "_anchor_live")
	end

	local function newId(): string
		return HttpService:GenerateGUID(false)
	end

	-- Per-profile in-memory tx state: [id] = "pending" | "durable" | "delivering"
	local function txState(profile)
		local state = rawget(profile, "_anchor_tx_state")
		if state == nil then
			state = {}
			rawset(profile, "_anchor_tx_state", state)
		end
		return state
	end

	-- Live proxies passed to Anchor.Trade for B, kept until the patch is applied.
	local PendingLive = setmetatable({}, { __mode = "v" })

	----- Store lookup (for delivering to B by name) -----

	local function storeFor(peer)
		local name = peer[1]
		local stores = Anchor._stores
		local store = stores ~= nil and stores[name] or nil
		if store == nil then
			store = Anchor.New(name, {})
		end
		return store
	end

	----- B side: apply a patch once -----

	local function pruneApplied(applied)
		local now = os.time()
		local entries = {}
		for id, t in next, applied do
			if type(t) ~= "number" or now - t > APPLIED_MAX_AGE then
				applied[id] = nil
			else
				table.insert(entries, { id, t })
			end
		end
		if #entries > APPLIED_MAX_COUNT then
			table.sort(entries, function(a, b)
				return a[2] < b[2]
			end)
			for i = 1, #entries - APPLIED_MAX_COUNT do
				applied[entries[i][1]] = nil
			end
		end
	end

	-- Applies `patch` to profile once per id. Returns true if it was applied now.
	local function applyOnce(profile, id, patch, live): boolean
		local meta = profile.anchor_meta
		local applied = meta.Applied
		if type(applied) ~= "table" then
			applied = {}
			meta.Applied = applied
		end
		if applied[id] ~= nil then
			return false
		end
		local ok_patch, problem = Patch.check(patch)
		if ok_patch ~= true then
			report(profile, `Anchor tx {id} has an invalid patch ({tostring(problem)}); not applied`)
			return false
		end
		local _, missed = Patch.apply(profile.Data, patch, live or liveFor(profile), reporter(profile))
		if missed > 0 then
			report(profile, `Anchor tx {id}: {missed} array item(s) to remove were no longer there`)
		end
		applied[id] = os.time()
		pruneApplied(applied)
		profile:MarkMetaDirty()
		return true
	end

	Core.AddHook("Message", function(profile, message, processed)
		if type(message) ~= "table" or type(message.AnchorTx) ~= "string" or type(message.Patch) ~= "table" then
			return false -- not ours (or not well-formed): user handlers see it
		end
		applyOnce(profile, message.AnchorTx, message.Patch)
		processed()
		return true
	end)

	----- A side: deliver a durable intent -----

	local deliver

	local function clearTx(A, id, rec)
		local tx = A.anchor_meta.Tx
		if type(tx) == "table" and tx[id] == rec then
			tx[id] = nil
			if next(tx) == nil then
				A.anchor_meta.Tx = nil
			end
			A:MarkMetaDirty()
		end
		txState(A)[id] = nil
		PendingLive[id] = nil
		if A:IsActive() then
			A:SaveAsync() -- drop the record now (a later save would do it too)
		end
	end

	local function sendTx(peer, id, patch): boolean
		local store = storeFor(peer)
		local ok, accepted = pcall(function()
			if peer[3] == true then
				return store.Mock:MessageAsync(peer[2], { AnchorTx = id, Patch = patch })
			end
			return store:MessageAsync(peer[2], { AnchorTx = id, Patch = patch })
		end)
		return ok == true and accepted == true
	end

	deliver = function(A, id)
		local tx = A.anchor_meta.Tx
		local rec = type(tx) == "table" and tx[id] or nil
		local state = txState(A)
		if rec == nil or state[id] == "delivering" then
			return
		end
		state[id] = "delivering"

		local peer, patch = rec.peer, rec.patch
		local confirmed = false
		local ok_shape = type(peer) == "table" and type(peer[1]) == "string" and type(peer[2]) == "string"
		if ok_shape then
			local B = Core.GetActiveProfile({ Name = peer[1] }, peer[2], peer[3] == true)
			if B ~= nil and B:IsActive() and B.view_mode ~= true then
				applyOnce(B, id, patch, PendingLive[id])
				confirmed = B:SaveAsync()
			end
			if not confirmed then
				-- Always safe: B applies a tx id at most once.
				confirmed = sendTx(peer, id, patch)
			end
		else
			report(A, `Anchor tx {id} has an invalid peer; dropped`)
			confirmed = true
		end

		if confirmed then
			clearTx(A, id, rec)
		elseif state[id] == "delivering" then
			state[id] = "durable" -- retried after A's next save or load
		end
	end

	-- A write containing Tx[id] landed (or it was loaded from the DataStore): deliver it,
	-- unless a delivery is already running. A failed delivery is retried on the next call.
	local function markDurable(A, id)
		local tx = A.anchor_meta.Tx
		if type(tx) ~= "table" or tx[id] == nil then
			return
		end
		local state = txState(A)
		if state[id] ~= "delivering" then
			state[id] = "durable"
			task.spawn(deliver, A, id)
		end
	end

	Core.AddHook("AfterSave", function(profile, wrote, raw)
		if wrote ~= true or type(raw) ~= "table" or type(raw.MetaData) ~= "table" then
			return
		end
		local stored = raw.MetaData.Anchor
		local stored_tx = type(stored) == "table" and stored.Tx or nil
		local tx = profile.anchor_meta.Tx
		if type(stored_tx) ~= "table" or type(tx) ~= "table" then
			return
		end
		for id in next, stored_tx do
			markDurable(profile, id)
		end
	end)

	Core.AddHook("Loaded", function(profile)
		local tx = profile.anchor_meta.Tx
		if type(tx) == "table" then
			for id in next, tx do
				markDurable(profile, id) -- loaded from the DataStore: durable
			end
		end
	end)

	----- Locks -----

	local function locked(profile)
		return rawget(profile, "_anchor_trade_lock") == true
	end

	local function setLock(profile, value)
		rawset(profile, "_anchor_trade_lock", if value then true else nil)
	end

	local function acquire(A, B, timeout): boolean
		local start = os.clock()
		while locked(A) or locked(B) do
			if os.clock() - start >= timeout then
				return false
			end
			task.wait()
		end
		setLock(A, true)
		setLock(B, true)
		return true
	end

	local function isProfile(p)
		return type(p) == "table" and type(p.Data) == "table" and type(p.anchor_meta) == "table"
	end

	----- Anchor.Trade -----

	local commit

	function Anchor.Trade(A, B, fn, opts)
		opts = opts or {}
		if not isProfile(A) or not isProfile(B) or type(fn) ~= "function" then
			return false, "Invalid", "Trade(profileA, profileB, fn) needs two profiles and a function"
		end
		if A == B or (A.Key == B.Key and A.ProfileStore.Name == B.ProfileStore.Name) then
			return false, "Invalid", "A profile can't trade with itself"
		end
		if A.view_mode == true or B.view_mode == true then
			return false, "Invalid", "View-mode profiles can't trade"
		end
		if not A:IsActive() or not B:IsActive() then
			return false, "Inactive"
		end
		local timeout = opts.Timeout or TX_LOCK_TIMEOUT
		if not acquire(A, B, timeout) then
			return false, "Busy"
		end
		local results = table.pack(pcall(commit, A, B, fn, opts, timeout))
		setLock(A, false)
		setLock(B, false)
		if results[1] == false then
			-- Internal error (e.g. a profile's Data was replaced with a non-table). If A's
			-- intent was already recorded it still completes on A's next save.
			report(A, `Trade errored: {tostring(results[2])}`)
			return false, "Error", tostring(results[2])
		end
		return table.unpack(results, 2, results.n)
	end

	commit = function(A, B, fn, opts, timeout)
		if not A:IsActive() or not B:IsActive() then
			return false, "Inactive"
		end

		local live = opts.Live
		local liveA = type(live) == "table" and live[1] or liveFor(A)
		local liveB = type(live) == "table" and live[2] or liveFor(B)

		-- 1. drafts
		local baseA, baseB = Patch.deepCopy(A.Data), Patch.deepCopy(B.Data)
		local draftA, draftB = Patch.deepCopy(baseA), Patch.deepCopy(baseB)
		local ok_fn, result = pcall(fn, draftA, draftB)
		if ok_fn == false then
			return false, "Error", tostring(result)
		end
		if result == false then
			return false, "Cancelled"
		end
		if not A:IsActive() or not B:IsActive() then
			return false, "Inactive"
		end

		-- 2. patches
		local PA, PB = Patch.diff(baseA, draftA), Patch.diff(baseB, draftB)
		for _, p in { PA, PB } do
			local ok_patch, problem = Patch.check(p)
			if ok_patch ~= true then
				return false, "Invalid", problem
			end
		end
		if #PA == 0 and #PB == 0 then
			return true
		end
		if #PA == 0 or #PB == 0 then
			-- Only one side changes: a plain single-profile edit, atomic in its next save.
			local P = if #PA > 0 then A else B
			Patch.apply(P.Data, if #PA > 0 then PA else PB, if #PA > 0 then liveA else liveB, reporter(P))
			P:MarkMetaDirty() -- never skipped as "clean" (IsDirty hooks can't see plain writes)
			return true
		end

		-- 3. durable intent on A (same tick as the in-memory change)
		local id = newId()
		local inverseA = Patch.apply(A.Data, PA, liveA, reporter(A))
		local tx = A.anchor_meta.Tx
		if type(tx) ~= "table" then
			tx = {}
			A.anchor_meta.Tx = tx
		end
		local rec = {
			peer = { B.ProfileStore.Name, B.Key, if B.is_mock == true then true else nil },
			patch = PB,
			t = os.time(),
		}
		tx[id] = rec
		A:MarkMetaDirty()
		local state = txState(A)
		state[id] = "pending"
		if liveB ~= nil then
			PendingLive[id] = liveB
		end

		for attempt = 1, INTENT_SAVE_ATTEMPTS do
			if state[id] ~= "pending" or not A:IsActive() then
				break
			end
			if A:SaveAsync() == true then
				markDurable(A, id) -- a write with the current state (and Tx[id]) landed
				break
			end
			if state[id] ~= "pending" or not A:IsActive() then
				break
			end
			if attempt < INTENT_SAVE_ATTEMPTS then
				task.wait(attempt)
			end
		end

		if state[id] ~= "pending" then
			return true
		end

		if A:IsActive() then
			-- Never confirmed while we still own A: undo (same tick, no yield).
			if tx[id] == rec then
				tx[id] = nil
				if next(tx) == nil then
					A.anchor_meta.Tx = nil
				end
			end
			state[id] = nil
			PendingLive[id] = nil
			Patch.apply(A.Data, inverseA, liveA, reporter(A))
			A:MarkMetaDirty()
			return false, "SaveFailed"
		end

		-- A's session ended mid-commit; its release save carries Tx[id].
		local start = os.clock()
		while state[id] == "pending" and os.clock() - start < timeout do
			task.wait()
		end
		if state[id] ~= "pending" then
			return true
		end
		return false, "SessionLost"
	end

	----- store:Gift -----

	local function keyFor(store, target)
		if type(target) == "number" then
			return (store.key_prefix or "Player_") .. tostring(target)
		elseif type(target) == "string" then
			return target
		end
		error("[Anchor]: Gift target must be a UserId or a profile key")
	end

	-- store:Gift(userIdOrKey, fn(data) | patch, { Id = string? }) -> (boolean, reason?)
	-- Delivered through the profile's message queue: applied exactly once by whichever
	-- server owns the profile (now or at its next load). fn runs on a copy of the latest
	-- data and its changes are sent as a patch (numbers as increments, so progress made in
	-- the meantime is kept). Id makes it idempotent: the same Id is applied at most once.
	function Anchor:Gift(target, gift, opts)
		if type(self) ~= "table" or self.template == nil then
			error("[Anchor]: Gift must be called on a store (Data:Gift(userId, fn))")
		end
		opts = opts or {}
		local key = keyFor(self, target)
		local patch
		if type(gift) == "function" then
			local base
			local is_mock = self.anchor_options.Mock == true
			local active = Core.GetActiveProfile(self, key, is_mock)
			if active ~= nil then
				base = Patch.deepCopy(active.Data)
			else
				local view = self:GetAsync(key)
				base = if view ~= nil then view.Data else Patch.deepCopy(self.template)
			end
			local draft = Patch.deepCopy(base)
			local ok, result = pcall(gift, draft)
			if ok == false then
				return false, "Error", tostring(result)
			end
			if result == false then
				return false, "Cancelled"
			end
			patch = Patch.diff(base, draft)
		elseif type(gift) == "table" then
			patch = gift
		else
			error("[Anchor]: Gift needs a function or a patch")
		end
		local ok_patch, problem = Patch.check(patch)
		if ok_patch ~= true then
			return false, "Invalid", problem
		end
		if #patch == 0 then
			return true
		end
		local id = if type(opts.Id) == "string" then opts.Id else newId()
		if self:MessageAsync(key, { AnchorTx = id, Patch = patch }) ~= true then
			return false, "Failed"
		end
		return true
	end

	Anchor.Patch = Patch
	Anchor._Trade = {
		deliver = deliver,
		applyOnce = applyOnce,
	}
end

return Trade

--!nonstrict
--[[
	Anchor - session-locked profiles for Roblox, a drop-in upgrade of ProfileStore 1.0.3.

	Stock API (unchanged; swap the module and existing code keeps working):
		Anchor.New(store_name, template?, options?) -> store
		Anchor.SetConstant(name, value)
		Anchor.IsClosing, Anchor.IsCriticalState, Anchor.DataStoreState
		Anchor.OnError(message, store_name, key), Anchor.OnOverwrite(store_name, key),
		Anchor.OnCriticalToggle(is_critical)
		store:StartSessionAsync(key, {Steal?, Cancel?}) / :MessageAsync / :GetAsync /
		      :VersionQuery / :RemoveAsync, store.Mock
		profile.Data / .LastSavedData / .FirstSessionTime / .SessionLoadCount / .Session /
		        .RobloxMetaData / .UserIds / .KeyInfo / .OnSave / .OnLastSave / .OnSessionEnd /
		        .OnAfterSave / .ProfileStore / .Key
		profile:IsActive / :Reconcile / :EndSession / :AddUserId / :RemoveUserId /
		        :MessageHandler / :Save / :SetAsync

	Anchor additions:
		options = { Format = "Compat" (default) | "Compact", VerifyWrites = true,
		            LockRefresh = 300, IsDirty = fn(profile) -> boolean, ClearDirty = fn(profile) }
		profile:SaveAsync() -> boolean     -- yields; true once a write with the current state succeeded

	Easy API:
		local Data = Anchor.new("Main", Template, { Format = "Compat" })
		Data:Bind({ Key = fn(player) -> string, OnLoaded = fn(player, profile), KickMessage = "...",
		            LoadTimeout = 120 })
		Data:Get(player) -> profile?       Data:Await(player) -> profile?
		Data.Loaded:Connect(function(player, profile) end)
		Data:Update(player, function(data) data.Cash += 10 end) -> boolean

	Feature modules (Trade, Receipts, ...) placed as children of this module are
	installed automatically: each returns { install = function(Anchor, Core) }.
--]]

local Core = require(script.Core)
local Signal = require(script.Signal)

local Anchor = Core.Module

export type JSONAcceptable = { JSONAcceptable } | { [string]: JSONAcceptable } | number | string | boolean | buffer

export type Options = {
	Format: ("Compat" | "Compact")?,
	VerifyWrites: boolean?,
	LockRefresh: number?,
	IsDirty: ((profile: any) -> boolean)?,
	ClearDirty: ((profile: any) -> ())?,
}

export type BindOptions = {
	Key: ((player: Player) -> string)?,
	OnLoaded: ((player: Player, profile: any) -> ())?,
	KickMessage: string?,
	LoadTimeout: number?,
}

local DEFAULT_KICK_MESSAGE = "Your data could not be loaded. Please rejoin."
local DEFAULT_LOAD_TIMEOUT = 120 -- stock START_SESSION_TIMEOUT

----- Store construction -----

local CoreNew = Anchor.New

function Anchor.New(store_name, template, options: Options?)
	local store = CoreNew(store_name, template, options)
	store.Loaded = Signal.New() -- (player, profile), fired by Bind
	return store
end

Anchor.new = Anchor.New

----- Easy API (store methods; stores use the module table as __index) -----

function Anchor:Bind(bind_options: BindOptions?)
	if type(self) ~= "table" or self.template == nil then
		error("[Anchor]: Bind must be called on a store (Data:Bind())")
	end
	if self.bind_state ~= nil then
		error(`[Anchor]: Store "{self.Name}" is already bound`)
	end
	bind_options = bind_options or {}

	local Players = game:GetService("Players")
	local key_fn = bind_options.Key or function(player)
		return "Player_" .. player.UserId
	end
	local kick_message = bind_options.KickMessage or DEFAULT_KICK_MESSAGE
	local on_loaded = bind_options.OnLoaded
	local load_timeout = bind_options.LoadTimeout or DEFAULT_LOAD_TIMEOUT

	local state = {
		profiles = {}, -- [player] = profile
		loading = {}, -- [player] = true
		changed = Signal.New(),
	}
	self.bind_state = state

	local function in_game(player)
		return player.Parent == Players
	end

	local function on_player_added(player)
		if state.profiles[player] ~= nil or state.loading[player] == true then
			return
		end
		state.loading[player] = true

		local started = os.clock()
		local profile = self:StartSessionAsync(key_fn(player), {
			Cancel = function()
				-- Stock applies no timeout when Cancel is given; Bind kicks after LoadTimeout.
				return in_game(player) == false or os.clock() - started > load_timeout
			end,
		})

		state.loading[player] = nil

		if profile == nil then
			if in_game(player) then
				player:Kick(kick_message)
			end
			state.changed:Fire()
			return
		end

		profile:AddUserId(player.UserId)
		profile:Reconcile()

		profile.OnSessionEnd:Connect(function()
			if state.profiles[player] == profile then
				-- Ended without the player leaving (another server took it, or shutdown):
				state.profiles[player] = nil
				if in_game(player) then
					player:Kick(kick_message)
				end
				state.changed:Fire()
			end
		end)

		if in_game(player) and profile:IsActive() then
			state.profiles[player] = profile
			if on_loaded ~= nil then
				task.spawn(on_loaded, player, profile)
			end
			self.Loaded:Fire(player, profile)
		else
			profile:EndSession()
		end
		state.changed:Fire()
	end

	Players.PlayerAdded:Connect(on_player_added)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(on_player_added, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local profile = state.profiles[player]
		if profile ~= nil then
			state.profiles[player] = nil
			profile:EndSession()
		end
		state.changed:Fire()
	end)

	return self
end

function Anchor:Get(player)
	local state = self.bind_state
	if state == nil then
		error("[Anchor]: Call store:Bind() before store:Get()")
	end
	local profile = state.profiles[player]
	if profile ~= nil and profile:IsActive() then
		return profile
	end
	return nil
end

function Anchor:Await(player)
	local state = self.bind_state
	if state == nil then
		error("[Anchor]: Call store:Bind() before store:Await()")
	end
	local Players = game:GetService("Players")
	while true do
		local profile = state.profiles[player]
		if profile ~= nil and profile:IsActive() then
			return profile
		end
		if player.Parent ~= Players then
			return nil
		end
		if profile == nil and state.loading[player] ~= true and Anchor.IsClosing == true then
			return nil
		end
		state.changed:Wait()
	end
end

function Anchor:Update(player, fn: (data: any) -> ()): boolean
	local profile = self:Get(player)
	if profile == nil then
		return false
	end
	fn(profile.Data)
	return true
end

----- Internals for feature modules and tests -----

Anchor._Core = Core

----- Feature modules -----

do
	local ok, children = pcall(function()
		return script:GetChildren()
	end)
	if ok == true and type(children) == "table" then
		for _, name in ipairs({ "Trade", "Receipts" }) do
			for _, child in ipairs(children) do
				if child.Name == name then
					local feature = require(child)
					if type(feature) == "table" and type(feature.install) == "function" then
						feature.install(Anchor, Core)
					end
				end
			end
		end
	end
end

return Anchor

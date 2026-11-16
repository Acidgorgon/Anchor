--!optimize 2
-- MessagingService mock: one bus per Sim world, one service per server.
--
--   SubscribeAsync(topic, callback) -> RBXScriptConnection   (yields briefly)
--   PublishAsync(topic, data)                                 (yields briefly)
-- A published message is JSON round-tripped (Roblox rules, 1 kB limit) and
-- delivered after `messageDelay` (default 0.05-0.25 s) to every subscriber
-- of the topic on every LIVE server (including the sender) as
-- callback({Data = data, Sent = unixSeconds}) on a new thread of the
-- subscriber's server. `messageDropRate` drops messages (best effort, like
-- the real service). Error injection: Sim.injectError{method = "PublishAsync"}.

local JSON = require("./json")
local Roblox = require("./roblox")
local DS = require("./datastore")

local MS = {}

local MAX_MESSAGE_BYTES = 1024
local MAX_TOPIC_LENGTH = 80

function MS.newBus(world)
	return {
		world = world,
		topics = {}, -- [topic] = { subscription, ... }
		options = { latency = { 0.02, 0.08 }, messageDelay = { 0.05, 0.25 }, messageDropRate = 0 },
		totals = { publishes = 0, delivered = 0, dropped = 0, subscribes = 0 },
	}
end

local function range(world, r): number
	if type(r) == "number" then
		return r
	end
	return r[1] + (r[2] - r[1]) * world.rng:NextNumber()
end

local SubscriptionMT = { __robloxtype = "RBXScriptConnection" }
SubscriptionMT.__index = SubscriptionMT
function SubscriptionMT.Disconnect(self)
	if not self.Connected then
		return
	end
	self.Connected = false
	local list = self._bus.topics[self._topic]
	if list then
		local i = table.find(list, self)
		if i then
			table.remove(list, i)
		end
	end
end

local function checkTopic(topic)
	if type(topic) ~= "string" or #topic == 0 then
		error("Argument 1 missing or nil", 0)
	end
	if #topic > MAX_TOPIC_LENGTH then
		error(`Topic exceeds {MAX_TOPIC_LENGTH} characters`, 0)
	end
end

local function request(bus, server, method: string, topic: string)
	local world = bus.world
	local sched = world.sched
	if not server.alive then
		error("MessagingService request from a dead server", 0)
	end
	sched:assertCanYield(`MessagingService:{method}`)
	server.stats.calls[method] = (server.stats.calls[method] or 0) + 1
	world.ds.callCount += 1
	local rule = DS.matchRule(world.ds, {
		method = method,
		key = topic,
		server = server,
		callNumber = world.ds.callCount,
	})
	sched:wait(server, range(world, bus.options.latency))
	if rule then
		error(rule.message or "MessagingService: request failed", 0)
	end
end

function MS.newService(bus, server)
	local world = bus.world
	local service = Roblox.newInstance("MessagingService", "MessagingService")

	rawset(service, "SubscribeAsync", function(_self, topic: string, callback)
		checkTopic(topic)
		if type(callback) ~= "function" then
			error("Argument 2 missing or nil", 2)
		end
		request(bus, server, "SubscribeAsync", topic)
		bus.totals.subscribes += 1
		local sub = setmetatable({
			Connected = true,
			_bus = bus,
			_topic = topic,
			_server = server,
			_callback = callback,
		}, SubscriptionMT)
		local list = bus.topics[topic]
		if list == nil then
			list = {}
			bus.topics[topic] = list
		end
		table.insert(list, sub)
		return sub
	end)

	rawset(service, "PublishAsync", function(_self, topic: string, data)
		checkTopic(topic)
		local json = JSON.encode(data)
		if #json > MAX_MESSAGE_BYTES then
			error(`PublishAsync: message size {#json} exceeds 1kB`, 0)
		end
		request(bus, server, "PublishAsync", topic)
		bus.totals.publishes += 1
		server.stats.publishes += 1
		if bus.options.messageDropRate > 0 and world.rng:NextNumber() < bus.options.messageDropRate then
			bus.totals.dropped += 1
			return
		end
		local sent = world:unixMillis() / 1000
		world.sched:callAfter(nil, range(world, bus.options.messageDelay), function()
			local list = bus.topics[topic]
			if list == nil then
				return
			end
			for _, sub in table.clone(list) do
				local target = sub._server
				if sub.Connected and target.alive then
					bus.totals.delivered += 1
					target.stats.messagesReceived += 1
					world.sched:resume(target, coroutine.create(sub._callback), { Data = JSON.decode(json), Sent = sent })
				end
			end
		end)
	end)

	return service
end

return MS

--!strict
-- Fixture: a Rojo-style library (init.luau + children) for require tests.
local Child = require(script.Child)
local Sibling = require("./Lib/Sub/Deep") -- init.luau: "./" is relative to the parent folder
local Self = require("@self/Child")
counter = (counter or 0) + 1 -- module global: must be per module instance
return {
	child = Child,
	deep = Sibling,
	same = Self == Child,
	counter = function()
		return counter
	end,
	jobId = game.JobId,
	scriptName = script.Name,
	parentName = script.Parent.Name,
	clock = os.clock,
	typeofDate = typeof(DateTime.now()),
}

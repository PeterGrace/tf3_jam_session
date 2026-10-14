local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local content_card = ug_require "::/gui/main/content_card.tl" as ContentCard
local industry_eow = ug_require "::/gui/entity_window/industry/industry_eow.script.tl" as IndustryEow
local util = ug_require "pgrace_vehicle_destination::/gui/pgrace_vehicle_destination/util.tl" as PgraceVehicleDestinationUtil

local record BodyParams
	entityId : Engine.Entity
end

local function computeText(entity : Engine.Entity) : string
	local ok, textOrError = pcall(function() : string
		return util.greet(api.engine.util.getEntityName(entity))
	end)
	if ok then
		return textOrError as string
	end
	debugPrint("[pgrace_vehicle_destination] error for entity " .. tostring(entity) .. ": " .. tostring(textOrError))
	return _("Error (see log)")
end

-- Computed once when the window opens.
local Body = react.RegisterRecipe("PgraceVehicleDestinationBody", function(params : BodyParams) : TreeNodeId
	local text = react.useStateLazy(function() : string
		return computeText(params.entityId)
	end)
	return builtin.TextView{ text = text:old() }
end)

local IndustryPlugin = react.RegisterPluginRecipe(industry_eow.IndustryEowExtensionPoint, "PgraceVehicleDestinationIndustryPlugin", function(params : IndustryEow.IndustryWidgetPluginParams) : TreeNodeId
	return builtin.BoxLayout{
		child = content_card.ContentCard{
			title = _("Vehicle Destination"),
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(Body, { entityId = params.entityId } as BodyParams),
			gameCtx = params.gameCtx,
			showOnRightSide = params.showCalloutOnRightSide,
		},
	}
end)

debugPrint("[pgrace_vehicle_destination] script loaded")

return {
	IndustryPlugin = IndustryPlugin,
}

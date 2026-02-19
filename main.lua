local _G = getfenv(0)

local revision = 1.0
local bars = {
   'Action',
   'BonusAction',
   'MultiBarBottomLeft',
   'MultiBarBottomRight',
   'MultiBarRight',
   'MultiBarLeft'
}

FLYOUT_DEFAULT_CONFIG = {
   ['REVISION'] = revision,
   ['BUTTON_SIZE'] = 28,
   ['BORDER_COLOR'] = { 0, 0, 0 },
   ['ARROW_SCALE'] = 5/9,
}

local ARROW_RATIO = 0.6  -- Height to width.

-- upvalues
local ActionButton_GetPagedID = ActionButton_GetPagedID
local ChatEdit_SendText = ChatEdit_SendText
local GetActionText = GetActionText
local GetNumSpellTabs = GetNumSpellTabs
local GetSpellName = GetSpellName
local GetSpellTabInfo = GetSpellTabInfo
local GetScreenHeight = GetScreenHeight
local GetScreenWidth = GetScreenWidth
local HasAction = HasAction
local GetMacroIndexByName = GetMacroIndexByName
local GetMacroInfo = GetMacroInfo

local insert = table.insert
local rawset = rawset
local remove = table.remove
local sizeof = table.getn

local strfind = string.find
local strgsub = string.gsub
local strlower = string.lower
local strsub = string.sub

local bagItemCache = {}
local bagCacheDirty = true

-- helper functions
local function strtrim(str)
   local _, e = strfind(str, '^%s*')
   local s, _ = strfind(str, '%s*$', e + 1)
   return strsub(str, e + 1, s - 1)
end

local function tblclear(tbl)
	if type(tbl) ~= 'table' then
		return
	end

	-- Clear array-type tables first so table.insert will start over at 1.
	for i = sizeof(tbl), 1, -1 do
		remove(tbl, i)
	end

	-- Remove any remaining associative table elements.
	-- Credit: https://stackoverflow.com/a/27287723
	for k in next, tbl do
		rawset(tbl, k, nil)
	end
end

local strSplitReturn = {}  -- Reusable table for strsplit() when fillTable parameter isn't used.
local function strsplit(str, delimiter, fillTable)
   fillTable = fillTable or strSplitReturn
   tblclear(fillTable)
   strgsub(str, '([^' .. delimiter .. ']+)', function(value)
      insert(fillTable, strtrim(value))
   end)

   return fillTable
end

local function ExtractFlyoutBody(macroBody)
   if not macroBody then
      return
   end

   local lines = strsplit(macroBody, '\n')
   for i = 1, sizeof(lines) do
      local line = lines[i]
      local _, e = strfind(line, '^%s*/flyout%s*')
      if e then
         return strsub(line, e + 1)
      end
   end
end

local function BuildBagItemCache()
   if not bagCacheDirty then
      return
   end

   tblclear(bagItemCache)

   for bag = 0, 4 do
      local slots = GetContainerNumSlots(bag)
      if slots then
         for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            if link then
               local _, _, itemName = strfind(link, "%[(.+)%]")
               if itemName then
                  local key = strlower(itemName)
                  local texture, count = GetContainerItemInfo(bag, slot)
                  local maxStack = nil
                  local _, _, itemID = strfind(link, "item:(%d+)")
                  itemID = tonumber(itemID)

                  if itemID then
                     local _, _, _, _, _, _, _, stackByID = GetItemInfo(itemID)
                     maxStack = tonumber(stackByID)
                  end

                  if not maxStack then
                     local _, _, _, _, _, _, _, stackByName = GetItemInfo(itemName)
                     maxStack = tonumber(stackByName)
                  end

                  if not maxStack then
                     local _, _, _, _, _, _, _, stackByLink = GetItemInfo(link)
                     maxStack = tonumber(stackByLink)
                  end

                  -- If metadata is missing, only treat as stackable when a stack is visibly larger than 1.
                  local stackable = (maxStack and maxStack > 1) or (not maxStack and (count or 1) > 1)
                  count = count or 1

                  local itemData = bagItemCache[key]
                  if itemData then
                     itemData.count = itemData.count + count
                     itemData.stackable = itemData.stackable or stackable
                  else
                     bagItemCache[key] = {
                        bag = bag,
                        slot = slot,
                        texture = texture,
                        count = count,
                        stackable = stackable,
                     }
                  end
               end
            end
         end
      end
   end

   bagCacheDirty = false
end

local function FindItemInBags(name)
   if not name then return end
   BuildBagItemCache()

   local itemData = bagItemCache[strlower(name)]
   if itemData then
      return itemData.bag, itemData.slot, itemData.texture, itemData.count, itemData.stackable
   end
end

local function GetItemNameFromLink(link)
   if not link then
      return
   end

   local _, _, itemName = strfind(link, "%[(.+)%]")
   return itemName
end

local function ApplyTooltipInfo(tooltipInfo)
   if not tooltipInfo then
      return nil
   end

   if tooltipInfo.mode == "spell_slot" and tooltipInfo.spellSlot then
      GameTooltip:SetSpell(tooltipInfo.spellSlot, tooltipInfo.bookType or 'spell')
      return true
   end

   if tooltipInfo.mode == "spell_name" and tooltipInfo.spellName then
      local slot = GetSpellSlotByName(tooltipInfo.spellName)
      if slot then
         GameTooltip:SetSpell(slot, 'spell')
      else
         GameTooltip:SetText(tooltipInfo.spellName, 1, 1, 1)
      end
      return true
   end

   if tooltipInfo.mode == "item_bag" and tooltipInfo.bag and tooltipInfo.slot then
      GameTooltip:SetBagItem(tooltipInfo.bag, tooltipInfo.slot)
      return true
   end

   if tooltipInfo.mode == "item_inv" and tooltipInfo.slot then
      GameTooltip:SetInventoryItem("player", tooltipInfo.slot)
      return true
   end

   if tooltipInfo.mode == "item_link" and tooltipInfo.link then
      GameTooltip:SetHyperlink(tooltipInfo.link)
      return true
   end

   if tooltipInfo.mode == "text" and tooltipInfo.text then
      GameTooltip:SetText(tooltipInfo.text, 1, 1, 1)
      return true
   end
end

local function ResolveSCRMTooltipAction(actionInfo, fallbackTexture, depth)
   if not actionInfo or depth > 3 then
      return { mode = "macro_text", texture = fallbackTexture }
   end

   local tooltipInfo = {
      mode = "macro_text",
      texture = actionInfo.texture or fallbackTexture,
   }

   if actionInfo.spell then
      if actionInfo.spell.spellSlot then
         tooltipInfo.mode = "spell_slot"
         tooltipInfo.spellSlot = actionInfo.spell.spellSlot
         tooltipInfo.bookType = actionInfo.spell.bookType or 'spell'
      elseif actionInfo.action then
         tooltipInfo.mode = "spell_name"
         tooltipInfo.spellName = actionInfo.action
      end
      return tooltipInfo
   end

   if actionInfo.item then
      tooltipInfo.itemName = actionInfo.action
      if actionInfo.item.bagID and actionInfo.item.slot then
         tooltipInfo.mode = "item_bag"
         tooltipInfo.bag = actionInfo.item.bagID
         tooltipInfo.slot = actionInfo.item.slot
      elseif actionInfo.item.inventoryID then
         tooltipInfo.mode = "item_inv"
         tooltipInfo.slot = actionInfo.item.inventoryID
      elseif actionInfo.item.link then
         tooltipInfo.mode = "item_link"
         tooltipInfo.link = actionInfo.item.link
      elseif actionInfo.action then
         local bag, slot = FindItemInBags(actionInfo.action)
         if bag then
            tooltipInfo.mode = "item_bag"
            tooltipInfo.bag = bag
            tooltipInfo.slot = slot
         end
      end
      return tooltipInfo
   end

   if actionInfo.macro and type(actionInfo.macro) == "table" then
      return ResolveSCRMTooltipAction(actionInfo.macro, tooltipInfo.texture, depth + 1)
   end

   if actionInfo.action then
      tooltipInfo.mode = "spell_name"
      tooltipInfo.spellName = actionInfo.action
      return tooltipInfo
   end

   return tooltipInfo
end

local function ExtractShowtooltipArg(macroBody)
   if not macroBody then
      return
   end

   local lines = strsplit(macroBody, '\n')
   for i = 1, sizeof(lines) do
      local line = lines[i]
      local _, _, arg = strfind(line, '^%s*#showtooltip%s*(.-)%s*$')
      if arg ~= nil then
         arg = strtrim(arg)
         if arg == "" then
            return ""
         end
         -- Remove bracket conditionals for a best-effort static fallback.
         arg = strgsub(arg, "%b[]", "")
         arg = strtrim(arg)
         return arg
      end
   end
end

local function ResolveMacroShowtooltip(macroIndex, depth)
   depth = depth or 0

   local macroName, macroTexture, macroBody = GetMacroInfo(macroIndex)
   local fallback = {
      mode = "text",
      text = macroName,
      texture = macroTexture,
   }

   if _G.CleveRoids and _G.CleveRoids.GetMacro and macroName then
      local ok, macroData = pcall(_G.CleveRoids.GetMacro, macroName)
      if ok and macroData and macroData.actions and macroData.actions.tooltip then
         local resolved = ResolveSCRMTooltipAction(macroData.actions.tooltip, macroTexture, 0)
         if resolved then
            resolved.text = resolved.text or macroName
            return resolved
         end
      end
   end

   local showtooltipArg = ExtractShowtooltipArg(macroBody)
   if showtooltipArg == "" then
      return fallback
   end

   if showtooltipArg and showtooltipArg ~= "" then
      local nestedMacro = GetMacroIndexByName(showtooltipArg)
      if nestedMacro and nestedMacro > 0 and depth < 3 then
         local nested = ResolveMacroShowtooltip(nestedMacro, depth + 1)
         if nested then
            nested.text = nested.text or macroName
            return nested
         end
      end

      local spellSlot = GetSpellSlotByName(showtooltipArg)
      if spellSlot then
         return {
            mode = "spell_slot",
            spellSlot = spellSlot,
            bookType = 'spell',
            texture = GetSpellTexture(spellSlot, 'spell') or macroTexture,
            text = macroName,
         }
      end

      local bag, slot, texture = FindItemInBags(showtooltipArg)
      if bag then
         return {
            mode = "item_bag",
            bag = bag,
            slot = slot,
            itemName = showtooltipArg,
            texture = texture or macroTexture,
            text = macroName,
         }
      end

      local _, itemLink = GetItemInfo(showtooltipArg)
      if itemLink then
         return {
            mode = "item_link",
            link = itemLink,
            itemName = GetItemNameFromLink(itemLink) or showtooltipArg,
            texture = macroTexture,
            text = macroName,
         }
      end
   end

   return fallback
end

local function GetPfUIFlyoutCountStyle()
   if not (_G.pfUI and _G.pfUI_config) then
      return
   end

   local source = _G["pfActionBarMainButton1Count"]
   if source and source.GetFont then
      local font, size, flags = source:GetFont()
      local r, g, b, a = source:GetTextColor()
      if font and size then
         return font, size, flags, r, g, b, a, source:GetJustifyH(), source:GetJustifyV()
      end
   end

   local media = _G.pfUI and _G.pfUI.media
   local bars = _G.pfUI_config and _G.pfUI_config.bars
   if not media or not bars then
      return
   end

   local font = media[bars.font]
   local size = tonumber(bars.count_size)
   if size == 0 then size = 1 end

   local r, g, b, a = 1, 1, 1, 1
   if bars.count_color then
      local _, _, c1, c2, c3, c4 = string.find(bars.count_color, "^%s*([^,]+),%s*([^,]+),%s*([^,]+),?%s*([^,]*)")
      r = tonumber(c1) or r
      g = tonumber(c2) or g
      b = tonumber(c3) or b
      a = tonumber(c4) or a
   end

   return font, size, "OUTLINE", r, g, b, a, "RIGHT", "BOTTOM"
end

local function ApplyCountStyle(button, font, size, flags, r, g, b, a, justifyH, justifyV)
   local countText = _G[button:GetName() .. "Count"]
   if not countText then
      return
   end

   if font and size and size > 0 then
      countText:SetFont(font, size, flags or "OUTLINE")
   end
   if r and g and b then
      countText:SetTextColor(r, g, b, a or 1)
   end
   if justifyH then
      countText:SetJustifyH(justifyH)
   end
   if justifyV then
      countText:SetJustifyV(justifyV)
   end
end

-- credit: https://github.com/DanielAdolfsson/CleverMacro
local function GetSpellSlotByName(name)
   name = strlower(name)
   local b, _, rank = strfind(name, '%(%s*rank%s+(%d+)%s*%)')
   if b then name = (b > 1) and strtrim(strsub(name, 1, b - 1)) or '' end

   for tabIndex = GetNumSpellTabs(), 1, -1 do
      local _, _, offset, count = GetSpellTabInfo(tabIndex)
      for index = offset + count, offset + 1, -1 do
         local spell, subSpell = GetSpellName(index, 'spell')
         spell = strlower(spell)
         if name == spell and (not rank or subSpell == 'Rank ' .. rank) then
            return index
         end
      end
   end
end

--self cast/use functions
local function GetSpellTextureByName(spellName)
   local slot = GetSpellSlotByName(spellName)
   if slot then return GetSpellTexture(slot, 'spell') end
end

local function Flyout_CastSpellOnPlayerByName(spellName)
   if not spellName then return end
   if _G.SUPERWOW_VERSION then
      CastSpellByName(spellName, "player")
   else
      local hadTarget = UnitExists("target")
      TargetUnit("player")
      CastSpellByName(spellName)
      if hadTarget then TargetLastTarget() else ClearTarget() end
   end
end

local function Flyout_UseItemOnPlayer(bag, slot)
   if not bag or not slot then return end
   local hadTarget = UnitExists("target")
   TargetUnit("player")
   UseContainerItem(bag, slot)
   if hadTarget then TargetLastTarget() else ClearTarget() end
end

-- Returns <action>, <actionType>
local function GetFlyoutActionInfo(action)
   if not action then return end
   local _, _, kw, rest = string.find(action, "^(%S+)%s+(.+)$")

   if kw and rest then
      if kw == "item" then
         if FindItemInBags(rest) then return rest, 2 end
      elseif kw == "selfItem" then
         if FindItemInBags(rest) then return rest, 5 end
      elseif kw == "rightSelfItem" then
         if FindItemInBags(rest) then return rest, 6 end
      end

      if kw == "selfCast" then
         if GetSpellSlotByName(rest) then return rest, 3 end
      elseif kw == "rightSelfCast" then
         if GetSpellSlotByName(rest) then return rest, 4 end
      end
   end

   local slot = GetSpellSlotByName(action)
   if slot then return slot, 0 end

   local macroIndex = GetMacroIndexByName(action)
   if macroIndex and macroIndex > 0 then return macroIndex, 1 end

   if FindItemInBags(action) then return action, 2 end
end

--flyout direction override
local function ExtractDirectionOverride(body)
   if strfind(body, "%[up%]") then return "TOP" end
   if strfind(body, "%[down%]") then return "BOTTOM" end
   if strfind(body, "%[left%]") then return "LEFT" end
   if strfind(body, "%[right%]") then return "RIGHT" end
   return nil
end

local function GetFlyoutDirection(button)
   local horizontal = false
   local bar = button:GetParent()
   if bar:GetWidth() > bar:GetHeight() then
      horizontal = true
   end

   local direction = horizontal and 'TOP' or 'LEFT'

   local centerX, centerY = button:GetCenter()
   if centerX and centerY then
      if horizontal then
         local halfScreen = GetScreenHeight() / 2
         direction = centerY < halfScreen and 'TOP' or 'BOTTOM'
      else
         local halfScreen = GetScreenWidth() / 2
         direction = centerX > halfScreen and 'LEFT' or 'RIGHT'
      end
   end
   return direction
end

local function FlyoutBarButton_OnLeave()
   this.updateTooltip = nil
   GameTooltip:Hide()

   local focus = GetMouseFocus()
   if focus and not strfind(focus:GetName(), 'Flyout') then
      Flyout_Hide()
   end
end

local function FlyoutBarButton_OnEnter()
   ActionButton_SetTooltip()
   Flyout_Show(this)
 end

local function UpdateBarButton(slot)
   local button = Flyout_GetActionButton(slot)
   if button then
      local arrow = _G[button:GetName() .. 'FlyoutArrow']
      if arrow then
         arrow:Hide()
      end

      if HasAction(slot) then
         button.sticky = false

         local macro = GetActionText(slot)
         if macro then
            local _, _, body = GetMacroInfo(GetMacroIndexByName(macro))
            local flyoutBody = ExtractFlyoutBody(body)
            if flyoutBody then
               if not button.preFlyoutOnEnter then
                  button.preFlyoutOnEnter = button:GetScript('OnEnter')
                  button.preFlyoutOnLeave = button:GetScript('OnLeave')
               end

               body = flyoutBody

               -- Identify sticky menus.
               if strfind(body, '%[sticky%]') then
                  body = strgsub(body, '%[sticky%]', '')
                  button.sticky = true
               end

               if strfind(body, '%[icon%]') then
                  body = strgsub(body, '%[icon%]', '')
               end

               --extract direction override
               button.flyoutDirectionOverride = ExtractDirectionOverride(body)
               if button.flyoutDirectionOverride then
                  body = strgsub(body, "%[up%]", "")
                  body = strgsub(body, "%[down%]", "")
                  body = strgsub(body, "%[left%]", "")
                  body = strgsub(body, "%[right%]", "")
               end

               if not button.flyoutActions then
                  button.flyoutActions = {}
               end

               strsplit(body, ';', button.flyoutActions)

               if table.getn(button.flyoutActions) > 0 then
                  button.flyoutAction, button.flyoutActionType = GetFlyoutActionInfo(button.flyoutActions[1])
               end

               Flyout_UpdateFlyoutArrow(button)

               button:SetScript('OnLeave', FlyoutBarButton_OnLeave)
               button:SetScript('OnEnter', FlyoutBarButton_OnEnter)
            end
         end

      else
         -- Reset button to pre-Flyout condition.
         button.flyoutActionType = nil
         button.flyoutAction = nil
         if button.preFlyoutOnEnter then
            button:SetScript('OnEnter', button.preFlyoutOnEnter)
            button:SetScript('OnLeave', button.preFlyoutOnLeave)
            button.preFlyoutOnEnter = nil
            button.preFlyoutOnLeave = nil
         end
      end
   end
end

local FlyoutBarButton_UpdateCooldown
local FlyoutBarButton_UpdateCount

local function HandleEvent()
   if event == 'VARIABLES_LOADED' then
      if not Flyout_Config or (Flyout_Config['REVISION'] == nil or Flyout_Config['REVISION'] ~= revision) then
         Flyout_Config = {}
      end
      -- Initialize defaults if not present.
      for key, value in pairs(FLYOUT_DEFAULT_CONFIG) do
         if not Flyout_Config[key] then
            Flyout_Config[key] = value
         end
      end
   elseif event == 'ACTIONBAR_SLOT_CHANGED' then
      Flyout_Hide(true)  -- Keep sticky menus open.
      UpdateBarButton(arg1)
   elseif event == 'BAG_UPDATE' then
      bagCacheDirty = true
      BuildBagItemCache()

      local i = 1
      local button = _G['FlyoutButton' .. i]
      while button do
         if button:IsVisible() and (button.flyoutActionType == 1 or button.flyoutActionType == 2 or button.flyoutActionType == 5 or button.flyoutActionType == 6) then
            FlyoutBarButton_UpdateCount(button)
            FlyoutBarButton_UpdateCooldown(button, true)
         end
         i = i + 1
         button = _G['FlyoutButton' .. i]
      end
   else
      Flyout_Hide()
      Flyout_UpdateBars()
   end
end

local handler = CreateFrame('Frame')
handler:RegisterEvent('VARIABLES_LOADED')
handler:RegisterEvent('PLAYER_ENTERING_WORLD')
handler:RegisterEvent('ACTIONBAR_SLOT_CHANGED')
handler:RegisterEvent('ACTIONBAR_PAGE_CHANGED')
handler:RegisterEvent('BAG_UPDATE')
handler:SetScript('OnEvent', HandleEvent)

-- globals
function Flyout_OnClick(button)
   if not button or not button.flyoutActionType or not button.flyoutAction then
      return
   end
   
   local actionType = button.flyoutActionType
   local action = button.flyoutAction
   local isRight = (arg1 == "RightButton")

   if actionType == 4 and isRight then
      Flyout_CastSpellOnPlayerByName(action)
      Flyout_Hide(true)
      return
   end

   if actionType == 6 and isRight then
      local bag, slot = button.flyoutItemBag, button.flyoutItemSlot
      if not bag then bag, slot = FindItemInBags(action) end
      if bag then Flyout_UseItemOnPlayer(bag, slot) end
      Flyout_Hide(true)
      return
   end

   if actionType == 0 or actionType == 4 then
      if type(action) == "number" or tonumber(action) then
         CastSpell(action, 'spell')
      else
         local slot = GetSpellSlotByName(action)
         if slot then CastSpell(slot, 'spell') else CastSpellByName(action) end
      end
      Flyout_Hide(true)
      return
   end

   if actionType == 1 then
      Flyout_ExecuteMacro(action)
      Flyout_Hide(true)
      return
   end

   if actionType == 2 then
      local bag, slot = button.flyoutItemBag, button.flyoutItemSlot
      if not bag then bag, slot = FindItemInBags(action) end
      if bag then UseContainerItem(bag, slot) end
      Flyout_Hide(true)
      return
   end

   if actionType == 3 then
      Flyout_CastSpellOnPlayerByName(action)
      Flyout_Hide(true)
      return
   end

   if actionType == 5 then
      local bag, slot = button.flyoutItemBag, button.flyoutItemSlot
      if not bag then bag, slot = FindItemInBags(action) end
      if bag then Flyout_UseItemOnPlayer(bag, slot) end
      Flyout_Hide(true)
      return
   end
end

function Flyout_SetTooltip(button)
   if not button or not button.flyoutActionType or not button.flyoutAction then
      return
   end

   local actionType = button.flyoutActionType
   local action = button.flyoutAction

   if actionType == 0 then
      GameTooltip:SetSpell(action, 'spell')
      return
   end

   if actionType == 1 then
      if button.flyoutMacroTooltip and ApplyTooltipInfo(button.flyoutMacroTooltip) then
         return
      end
      GameTooltip:SetText(GetMacroInfo(action), 1, 1, 1)
      return
   end

   if actionType == 3 or actionType == 4 then
      local slot = GetSpellSlotByName(action)
      if slot then
         GameTooltip:SetSpell(slot, 'spell')
      else
         GameTooltip:SetText(action, 1, 1, 1)
      end
      return
   end

   if actionType == 2 or actionType == 5 or actionType == 6 then
      local bag, slot = button.flyoutItemBag, button.flyoutItemSlot
      if not bag then
         bag, slot = FindItemInBags(action)
         button.flyoutItemBag = bag
         button.flyoutItemSlot = slot
      end

      if bag and slot then
         GameTooltip:SetBagItem(bag, slot)
      else
         GameTooltip:SetText(action, 1, 1, 1)
      end
   end
end

function Flyout_ExecuteMacro(macro)
   local _, _, body = GetMacroInfo(macro)
   local commands = strsplit(body, '\n')
   for i = 1, sizeof(commands) do
      ChatFrameEditBox:SetText(commands[i])
      ChatEdit_SendText(ChatFrameEditBox)
   end
end

function Flyout_Hide(keepOpenIfSticky)
   local i = 1
   local button = _G['FlyoutButton' .. i]
   while button do
      i = i + 1

      if not keepOpenIfSticky or (keepOpenIfSticky and not button.sticky) then
         button:Hide()
         button:GetNormalTexture():SetTexture(nil)
         button:GetPushedTexture():SetTexture(nil)
      end
      -- Un-highlight if no longer needed.
      if button.flyoutActionType ~= 0 or not IsCurrentCast(button.flyoutAction, 'spell') then
         button:SetChecked(false)
      end

      button = _G['FlyoutButton' .. i]
   end

   -- Restore arrow to original strata (it was moved to FULLSCREEN in Flyout_Show())
   if _G['FlyoutButton1'] and not _G['FlyoutButton1']:IsVisible() and _G['FlyoutButton1'].flyoutParent then
      local arrow = _G[_G['FlyoutButton1'].flyoutParent:GetName() .. 'FlyoutArrow']
      arrow:SetFrameStrata(arrow.flyoutOriginalStrata)
   end
end

-- Reusable variables for FlyoutBarButton_UpdateCooldown().
local cooldownStart, cooldownDuration, cooldownEnable

FlyoutBarButton_UpdateCooldown = function(button, reset)
   button = button or this

   if button.flyoutActionType == 0 or button.flyoutActionType == 3 or button.flyoutActionType == 4 then
      local spellSlot
      if button.flyoutActionType == 0 then
         spellSlot = button.flyoutAction
      else
         spellSlot = GetSpellSlotByName(button.flyoutAction)
      end

      if spellSlot then
		cooldownStart, cooldownDuration, cooldownEnable = GetSpellCooldown(button.flyoutAction, BOOKTYPE_SPELL)
		if cooldownStart > 0 and cooldownDuration > 0 then
			-- Start/Duration check is needed to get the shine animation.
			CooldownFrame_SetTimer(button.cooldown, cooldownStart, cooldownDuration, cooldownEnable)
		elseif reset then
			-- When switching flyouts, need to hide cooldown if it shouldn't be visible.
			button.cooldown:Hide()
         end
      elseif reset then
         button.cooldown:Hide()
      end

   elseif button.flyoutActionType == 2 or button.flyoutActionType == 5 or button.flyoutActionType == 6 then
      local bag, slot = button.flyoutItemBag, button.flyoutItemSlot
      if not bag then bag, slot = FindItemInBags(button.flyoutAction) end

      if bag then
         cooldownStart, cooldownDuration, cooldownEnable = GetContainerItemCooldown(bag, slot)
         if cooldownStart > 0 and cooldownDuration > 0 then
            CooldownFrame_SetTimer(button.cooldown, cooldownStart, cooldownDuration, cooldownEnable)
         elseif reset then
            button.cooldown:Hide()
         end
      elseif reset then
         button.cooldown:Hide()
      end

   else
      button.cooldown:Hide()
   end
end

FlyoutBarButton_UpdateCount = function(button)
   button = button or this
   local countText = _G[button:GetName() .. 'Count']
   if not countText then
      return
   end

   local count = nil
   local stackable = false
   if button.flyoutActionType == 2 or button.flyoutActionType == 5 or button.flyoutActionType == 6 then
      local bag, slot, _, total, isStackable = FindItemInBags(button.flyoutAction)
      button.flyoutItemBag = bag
      button.flyoutItemSlot = slot
      count = total
      stackable = isStackable
   elseif button.flyoutActionType == 1 and button.flyoutMacroTooltip then
      local tooltipInfo = button.flyoutMacroTooltip
      local countName = tooltipInfo.itemName

      if not countName and tooltipInfo.link then
         countName = GetItemNameFromLink(tooltipInfo.link)
      end

      if not countName and tooltipInfo.mode == "item_bag" and tooltipInfo.bag and tooltipInfo.slot then
         local link = GetContainerItemLink(tooltipInfo.bag, tooltipInfo.slot)
         countName = GetItemNameFromLink(link)
      end

      if countName and countName ~= "" then
         local bag, slot, _, total, isStackable = FindItemInBags(countName)
         button.flyoutItemBag = bag
         button.flyoutItemSlot = slot
         count = total
         stackable = isStackable
      end
   end

   if stackable and count and count > 0 then
      countText:SetText(count)
   else
      countText:SetText('')
   end
end

local function FlyoutButton_OnUpdate()
   -- Update tooltip.
   if GetMouseFocus() == this and (not this.lastUpdate or GetTime() - this.lastUpdate > 1) then
      this:GetScript('OnEnter')()
      this.lastUpdate = GetTime()
   end
   FlyoutBarButton_UpdateCooldown(this)
end

function Flyout_Show(button)
   local direction = button.flyoutDirectionOverride or GetFlyoutDirection(button)
   local size = Flyout_Config['BUTTON_SIZE']
   local offset = size
   local countFont, countSize, countFlags, countR, countG, countB, countA, countJustifyH, countJustifyV = GetPfUIFlyoutCountStyle()
   BuildBagItemCache()

   -- Put arrow above the flyout buttons.
   _G[button:GetName() .. 'FlyoutArrow']:SetFrameStrata('FULLSCREEN')

   for i, n in button.flyoutActions do
      local b = _G['FlyoutButton' .. i]
      if not b then
         b = CreateFrame('CheckButton', 'FlyoutButton' .. i, UIParent, 'FlyoutButtonTemplate')
         b:SetID(i)
      end

      b.flyoutParent = button

      -- Things that only need to happen once.
      if not b.cooldown then
         b.cooldown = _G['FlyoutButton' .. i .. 'Cooldown']
         b:SetScript('OnUpdate', FlyoutButton_OnUpdate)
      end

      b.sticky = button.sticky
      local texture = nil

      b.flyoutAction, b.flyoutActionType = GetFlyoutActionInfo(n)

      b.flyoutItemBag = nil
      b.flyoutItemSlot = nil
      b.flyoutMacroTooltip = nil

      if b.flyoutActionType == 0 then
         texture = GetSpellTexture(b.flyoutAction, 'spell')
      elseif b.flyoutActionType == 1 then
         b.flyoutMacroTooltip = ResolveMacroShowtooltip(b.flyoutAction, 0)
         texture = b.flyoutMacroTooltip and b.flyoutMacroTooltip.texture
         if not texture then
            _, texture = GetMacroInfo(b.flyoutAction)
         end
      elseif b.flyoutActionType == 2 then
         local bag, slot, tex = FindItemInBags(b.flyoutAction)
         b.flyoutItemBag = bag
         b.flyoutItemSlot = slot
         texture = tex
      elseif b.flyoutActionType == 3 or b.flyoutActionType == 4 then
         texture = GetSpellTextureByName(b.flyoutAction)
      elseif b.flyoutActionType == 5 or b.flyoutActionType == 6 then
         local bag, slot, tex = FindItemInBags(b.flyoutAction)
         b.flyoutItemBag = bag
         b.flyoutItemSlot = slot
         texture = tex
      end

      if texture then
         b:ClearAllPoints()
         b:SetWidth(size)
         b:SetHeight(size)
         b.cooldown:SetScale(size / b.cooldown:GetWidth())
         b:SetBackdropColor(Flyout_Config['BORDER_COLOR'][1], Flyout_Config['BORDER_COLOR'][2], Flyout_Config['BORDER_COLOR'][3])
         ApplyCountStyle(b, countFont, countSize, countFlags, countR, countG, countB, countA, countJustifyH, countJustifyV)
         b:Show()

         b:GetNormalTexture():SetTexture(texture)
         b:GetPushedTexture():SetTexture(texture)

         -- Highlight professions and channeled casts.
         if b.flyoutActionType == 0 and IsCurrentCast(b.flyoutAction, 'spell') then
            b:SetChecked(true)
         end

         -- Force an instant update.
         this.lastUpdate = nil
         FlyoutBarButton_UpdateCooldown(b, true)
         FlyoutBarButton_UpdateCount(b)

         if direction == 'BOTTOM' then
            b:SetPoint('BOTTOM', button, 0, -offset)
         elseif direction == 'LEFT' then
            b:SetPoint('LEFT', button, -offset, 0)
         elseif direction == 'RIGHT' then
            b:SetPoint('RIGHT', button, offset, 0)
         else
            b:SetPoint('TOP', button, 0, offset)
         end

         offset = offset + size
      end

   end
end

function Flyout_GetActionButton(action)
   for i = 1, sizeof(bars) do
      for j = 1, 12 do
         local button = _G[bars[i] .. 'Button' .. j]
         local slot = ActionButton_GetPagedID(button)
         if slot == action and button:IsVisible() then
            return button
         end
      end
   end
end

function Flyout_UpdateBars()
   for i = 1, 120 do
      UpdateBarButton(i)
   end
end

function Flyout_UpdateFlyoutArrow(button)
   if not button then return end

   local direction = GetFlyoutDirection(button)

   local arrow = _G[button:GetName() .. 'FlyoutArrow']
   if not arrow then
      arrow = CreateFrame('Frame', button:GetName() .. 'FlyoutArrow', button)
      arrow:SetPoint('TOPLEFT', button)
      arrow:SetPoint('BOTTOMRIGHT', button)
      arrow.flyoutOriginalStrata = arrow:GetFrameStrata()
      arrow.texture = arrow:CreateTexture(arrow:GetName() .. 'Texture', 'ARTWORK')
      arrow.texture:SetTexture('Interface\\AddOns\\Flyout\\assets\\FlyoutButton')
   end

   arrow:Show()
   arrow.texture:ClearAllPoints()

   local arrowWideDimension = (button:GetWidth() or 36) * Flyout_Config['ARROW_SCALE']
   local arrowShortDimension = arrowWideDimension * ARROW_RATIO

   if direction == 'BOTTOM' then
      arrow.texture:SetWidth(arrowWideDimension)
      arrow.texture:SetHeight(arrowShortDimension)
      arrow.texture:SetTexCoord(0, 0.565, 0.315, 0)
      arrow.texture:SetPoint('BOTTOM', arrow, 0, -6)
   elseif direction == 'LEFT' then
      arrow.texture:SetWidth(arrowShortDimension)
      arrow.texture:SetHeight(arrowWideDimension)
      arrow.texture:SetTexCoord(0, 0.315, 0.375, 1)
      arrow.texture:SetPoint('LEFT', arrow, -6, 0)
   elseif direction == 'RIGHT' then
      arrow.texture:SetWidth(arrowShortDimension)
      arrow.texture:SetHeight(arrowWideDimension)
      arrow.texture:SetTexCoord(0.315, 0, 0.375, 1)
      arrow.texture:SetPoint('RIGHT', arrow, 6, 0)
   else
      arrow.texture:SetWidth(arrowWideDimension)
      arrow.texture:SetHeight(arrowShortDimension)
      arrow.texture:SetTexCoord(0, 0.565, 0, 0.315)
      arrow.texture:SetPoint('TOP', arrow, 0, 6)
   end
end

local Flyout_UseAction = UseAction
function UseAction(slot, checkCursor)
   Flyout_UseAction(slot, checkCursor)
   Flyout_OnClick(Flyout_GetActionButton(slot))
   Flyout_Hide()
end

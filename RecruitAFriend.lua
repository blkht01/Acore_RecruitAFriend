--
-- Created by IntelliJ IDEA.
-- User: Silvia
-- Date: 08/03/2021
-- Time: 20:39
-- To change this template use File | Settings | File Templates.
-- Originally created by Honey for Azerothcore
-- requires ElunaLua module


-- This module allows players to connect accounts with their friends to gain benefits
------------------------------------------------------------------------------------------------
-- ADMIN GUIDE:  -  compile the core with ElunaLua module
--               -  adjust config in this file
--               -  add this script to ../lua_scripts/
--               -  use the given commands via SOAP from the website to add/remove links (requires changes to acore-cms):
--               -  bind a recruiter: .bindraf $newRecruitId $existingRecruiterId
------------------------------------------------------------------------------------------------
-- PLAYER GUIDE: - as the new player(RECRUIT): make yourself RECRUITED by selecting your recruiters ID during account creation on the website
--               - as the existing player (RECRUITER): summon your friend with ".raf summon $FriendsCharacterName"
--               - discover your own account id by typing ".raf help"
--               - once the RECRUIT reaches a level set in config, the RECRUITER receives a reward.
--               - same IP possibly restricts or removes the bind (sorry families, roommates and the like)
------------------------------------------------------------------------------------------------

local Config = {}
local Config_maps = {}
local Config_rewards = {}
local Config_amounts = {}
local Config_defaultRewards = {}
local Config_defaultAmounts = {}

-- Name of Eluna dB scheme
Config.customDbName = "ac_eluna"

-- set to 1 to print error messages to the console. Any other value including nil turns it off.
Config.printErrorsToConsole = 1

-- min GM level to bind accounts
Config.minGMRankForBind = 3

-- max RAF duration in seconds. 2,592,000 = 30days
Config.maxRAFduration = 2592000

-- set to 1 to grant always rested. Any other value including nil turns it off.
Config.grantRested = 1

-- set to 1 to print a login message. Any other value including nil turns it off.
Config.displayLoginMessage = 1

-- the level which a player must reach to reward it's recruiter and automatically end RAF
Config.targetLevel = 39

-- maximum number of RAF related command uses before a kick. Includes summon requests.
Config.abuseTreshold = 1000

-- determines if there is a check for summoner and target being on the same Ip
Config.checkSameIp = 1

-- set to 1 to end RAF if linked accounts share an IP. Any other value including nil turns it off.
Config.endRAFOnSameIP = 0

-- text for the mail to send when rewarding a recruiter
Config.mailText = "Hello Adventurer!\nYou've earned a reward for introducing your friends to Chromie.\nDon't stop here, there might be more goods to gain.\n\n"

-- modify's the mail database to prevent returning of rewards. Changes sender from character to creature. Config.senderGUID points to a creature if this is 1
Config.preventReturn = 1

-- GUID/ID of the player/creature. If Config.preventReturn = 1, you need to put creature ID. Else player GUID. 0 = No sender aka "From: Unknown". Creature 10667 is "Chromie".
Config.senderGUID = 10667

-- stationary used in the mail sent to the player. (41 Normal Mail, 61 GM/Blizzard Support, 62 Auction, 64 Valentines, 65 Christmas) Note: Use 62, 64, and 65 At your own risk.
Config.mailStationery = 41

-- rewards towards the recruiter for certain amounts of recruits who reached the target level. If not defined for a level, send the whole set of default potions
Config_rewards[1] = 56806    -- Mini Thor , Pet which is bound to account
Config_rewards[3] = 14046    -- Runecloth Bag - 14-slot
Config_rewards[5] = 13584    -- Diablos Stone, Pet which is bound to account
Config_rewards[10] = 39656   -- Tyrael's Hilt, Pet which is bound to account

-- amount of rewards per reward_level
Config_amounts[1] = 1
Config_amounts[3] = 1
Config_amounts[5] = 1
Config_amounts[10] = 1

-- default rewards if nothing is set in Config_rewards for a certain level. May be changed. May NOT be removed.
Config_defaultRewards[1] = 9155   -- Battle elixir spellpower
Config_defaultRewards[2] = 9187   -- Battle elixir agility
Config_defaultRewards[3] = 9206   -- Battle elixir strength
Config_defaultRewards[4] = 5634   -- Potion of Free Action

Config_defaultAmounts[1] = 10
Config_defaultAmounts[2] = 10
Config_defaultAmounts[3] = 10
Config_defaultAmounts[4] = 9

-- The following are the allowed maps to summon to. Additional maps can be added with a table.insert() line.
-- Remove or comment all table.insert below to forbid summoning
-- Eastern kingdoms
table.insert(Config_maps, 0)
-- Kalimdor
table.insert(Config_maps, 1)
-- Outland
--table.insert(Config_maps, 530)
-- Northrend
--table.insert(Config_maps, 571)
------------------------------------------
-- NO ADJUSTMENTS REQUIRED BELOW THIS LINE
------------------------------------------
local PLAYER_EVENT_ON_LOGIN = 3          -- (event, player)
local PLAYER_EVENT_ON_LEVEL_CHANGE = 13  -- (event, player, oldLevel)
local PLAYER_EVENT_ON_COMMAND = 42       -- (event, player, command) - player is nil if command used from console. Can return false

CharDBQuery('CREATE DATABASE IF NOT EXISTS `'..Config.customDbName..'`;');
CharDBQuery('CREATE TABLE IF NOT EXISTS `'..Config.customDbName..'`.`recruit_a_friend_links` (`account_id` INT NOT NULL, `recruiter_account` INT DEFAULT 0, `time_stamp` INT DEFAULT 0, `ip_abuse_counter` INT DEFAULT 0, `kick_counter` INT DEFAULT 0, PRIMARY KEY (`account_id`) );');
CharDBQuery('CREATE TABLE IF NOT EXISTS `'..Config.customDbName..'`.`recruit_a_friend_rewards` (`recruiter_account` INT DEFAULT 0, `reward_level` INT DEFAULT 0, PRIMARY KEY (`recruiter_account`) );');

--sanity check
if Config_defaultRewards[1] == nil or Config_defaultRewards[2] == nil or Config_defaultRewards[3] == nil or Config_defaultRewards[4] == nil then
    print("RAF: The Config_defaultRewards value was removed for at least one flag ([1]-[4] are required.)")
end
--INIT sequence:
--globals:
RAF_xpPerLevel = {}
RAF_recruiterAccount = {}
RAF_timeStamp = {}
RAF_abuseCounter = {}
RAF_sameIpCounter = {}
RAF_kickCounter = {}
RAF_lastIP = {}
RAF_rewardLevel = {}

--global table which reads the required XP per level one single time on load from the db instead of one value every levelup event
local RAF_Data_SQL
local RAF_row = 1
local RAF_Data_SQL = WorldDBQuery('SELECT Experience FROM player_xp_for_level WHERE Level <= 80;')
if RAF_Data_SQL ~= nil then
    repeat
        RAF_xpPerLevel[RAF_row] = RAF_Data_SQL:GetUInt32(0)
        RAF_row = RAF_row + 1
    until not RAF_Data_SQL:NextRow()
else
    print("RAF: Error reading player_xp_for_level from tha database.")
end
RAF_Data_SQL = nil
RAF_row = nil

--global table which stores already granted rewards
local RAF_Data_SQL
local RAF_id
RAF_Data_SQL = CharDBQuery('SELECT * FROM `'..Config.customDbName..'`.`recruit_a_friend_rewards`;')
if RAF_Data_SQL ~= nil then
    repeat
        RAF_id = tonumber(RAF_Data_SQL:GetUInt32(0))
        RAF_rewardLevel[RAF_id] = tonumber(RAF_Data_SQL:GetUInt32(1))
    until not RAF_Data_SQL:NextRow()
else
    print("RAF: Found no granted rewards in the recruit_a_friend_rewards table. Possibly there are none yet.")
end

--global table which stores all RAF links
local RAF_Data_SQL
local RAF_id
RAF_Data_SQL = CharDBQuery('SELECT * FROM `'..Config.customDbName..'`.`recruit_a_friend_links`;')

if RAF_Data_SQL ~= nil then
    repeat
        RAF_id = tonumber(RAF_Data_SQL:GetUInt32(0))
        RAF_recruiterAccount[RAF_id] = tonumber(RAF_Data_SQL:GetUInt32(1))
        RAF_timeStamp[RAF_id] = tonumber(RAF_Data_SQL:GetUInt32(2))
        RAF_sameIpCounter[RAF_id] = RAF_Data_SQL:GetUInt32(3)
        RAF_kickCounter[RAF_id] = tonumber(RAF_Data_SQL:GetUInt32(4))
    until not RAF_Data_SQL:NextRow()
else
    print("RAF: Found no linked accounts in the recruit_a_friend table. Possibly there are none yet.")
end

local function RAF_command(event, player, command)
    local commandArray = {}
    -- split the command variable into several strings which can be compared individually
    commandArray = RAF_splitString(command)

    if commandArray[2] ~= nil then
        commandArray[2] = commandArray[2]:gsub("[';\\, ]", "")
        if commandArray[3] ~= nil then
            commandArray[3] = commandArray[3]:gsub("[';\\, ]", "")
        end
    end

    if commandArray[1] == "bindraf" then

        if player ~= nil then
            if player:GetGMRank() < Config.minGMRankForBind then
                if Config.printErrorsToConsole == 1 then print("Account "..player:GetAccountId().." tried the .bindraf command without sufficient rights.") end
                return
            end
        end

        local commandSource
        if player == nil then
            commandSource = "worldserver console"
        else
            commandSource = "account id: "..tostring(player:GetAccountId())
        end
        -- GM/SOAP command to bind from console or ingame commands
        if commandArray[2] ~= nil and commandArray[3] ~= nil then
            local accountId = tonumber(commandArray[2])
            if RAF_recruiterAccount[accountId] == nil then
                RAF_recruiterAccount[accountId] = tonumber(commandArray[3])
                RAF_timeStamp[accountId] = (tonumber(tostring(GetGameTime())))
                CharDBExecute('REPLACE INTO `'..Config.customDbName..'`.`recruit_a_friend_links` VALUES ('..accountId..', '..RAF_recruiterAccount[accountId]..', '..RAF_timeStamp[accountId]..', 0, 0);')
                 if Config.printErrorsToConsole == 1 then print(commandSource.." has succesfully used the .bindraf command on recruit "..accountId.." and recruiter "..RAF_recruiterAccount[accountId]..".") end
            else
                player:SendBroadcastMessage("The selected account "..accountId.." is already recruited by "..RAF_recruiterAccount[accountId]..".")
            end
        end
        RAF_cleanup()
        return false

    elseif commandArray[1] == "forcebindraf" then

        if player ~= nil then
            if player:GetGMRank() < Config.minGMRankForBind then
                if Config.printErrorsToConsole == 1 then print("Account "..player:GetAccountId().." tried the .forcebindraf command without sufficient rights.") end
                return
            end
        end

        local commandSource
        if player == nil then
            commandSource = "worldserver console"
        else
            commandSource = "account id: "..tostring(player:GetAccountId())
        end
        -- GM/SOAP command to force bind from console or ingame commands
        if commandArray[2] ~= nil and commandArray[3] ~= nil then
            local accountId = tonumber(commandArray[2])
            RAF_recruiterAccount[accountId] = tonumber(commandArray[3])
            RAF_timeStamp[accountId] = (tonumber(tostring(GetGameTime())))
            CharDBExecute('REPLACE INTO `'..Config.customDbName..'`.`recruit_a_friend_links` VALUES ('..accountId..', '..RAF_recruiterAccount[accountId]..', '..RAF_timeStamp[accountId]..', 0, 0);')
            if Config.printErrorsToConsole == 1 then print(commandSource.." has succesfully used the .forcebindraf command on recruit "..accountId.." and recruiter "..RAF_recruiterAccount[accountId]..".") end
        end
        RAF_cleanup()
        return false


    elseif commandArray[1] == "raf" then
        if player == nil then
            print(".raf is not meant to be used from the console.")
            return
        end

        local playerAccount = player:GetAccountId()
        if player ~= nil then
            if RAF_checkAbuse(playerAccount) == true then
                local recruitId
                player:KickPlayer()
                for index, value in pairs(RAF_recruiterAccount) do
                    if value == playerAccount then
                        recruitId = index
                    end
                end
                if RAF_kickCounter[recruitId] == nil then
                    RAF_kickCounter[recruitId] = 1
                else
                    RAF_kickCounter[recruitId] = RAF_kickCounter[recruitId] + 1
                    CharDBExecute('UPDATE `'..Config.customDbName..'`.`recruit_a_friend_links` SET `kick_counter` = '..RAF_kickCounter[recruitId]..' WHERE `account_id` = '..recruitId..';')
                    if Config.printErrorsToConsole == 1 then print("RAF: account id "..playerAccount.." was kicked because of too many .raf commands.") end
                end
            end
        end

        -- list all accounts recruited by this account
        if commandArray[2] == "list" then
            if player == nil then return end

            -- print all recruits bound to this account by charname
            local idList
            for index, value in pairs(RAF_recruiterAccount) do
                if value == playerAccount then
                    if RAF_timeStamp[index] > 1 then
                        if idList == nil then
                            idList = index
                        else
                            idList = idList.." "..index
                        end
                    end
                end
            end
            if idList == nil then
                idList = "none"
            end


            player:SendBroadcastMessage("Your current recruits are: "..idList)
            RAF_cleanup()
            return false

        elseif commandArray[2] == "summon" and commandArray[3] ~= nil and player ~= nil then
            if player == nil then return end

            -- check if the target is a recruit of the player
            local summonPlayer = GetPlayerByName(commandArray[3])
            if summonPlayer == nil then
                player:SendBroadcastMessage("Target not found. Check spelling and capitalization.")
                RAF_cleanup()
                return false
            end
            if RAF_recruiterAccount[summonPlayer:GetAccountId()] ~= player:GetAccountId() then
                player:SendBroadcastMessage("The requested player is not your recruit.")
                RAF_cleanup()
                return false
            end

            if RAF_timeStamp[summonPlayer:GetAccountId()] == 0 or RAF_timeStamp[summonPlayer:GetAccountId()] == 1 then
                player:SendBroadcastMessage("The requested player is not your recruit anymore.")
                RAF_cleanup()
                return false
            end

            -- do the zone/combat checks and possibly summon
            local mapId = player:GetMapId()
            -- allow to proceed if the player is on one of the maps listed above
            if RAF_hasValue(Config_maps, mapId) then
                --allow to proceed if the player is not in combat
                if not player:IsInCombat() then
                    local group = player:GetGroup()
                    if group == nil then
                        player:SendBroadcastMessage("You must be in a party or raid to summon your recruit.")
                        return false
                    end
                    local groupPlayers = group:GetMembers()
                    for _, v in pairs(groupPlayers) do
                        if v:GetName() == commandArray[3] then
                            if player:GetPlayerIP() == v:GetPlayerIP() and Config.checkSameIp == 1 and RAF_timeStamp[summonPlayer:GetAccountId()] >= 2 then
                                player:SendBroadcastMessage("Possible abuse detected. Aborting. This action is logged.")
                                if RAF_sameIpCounter[summonPlayer:GetAccountId()] == nil then
                                    RAF_sameIpCounter[summonPlayer:GetAccountId()] = 1
                                    CharDBExecute('UPDATE `'..Config.customDbName..'`.`recruit_a_friend_links` SET ip_abuse_counter = '..RAF_sameIpCounter[summonPlayer:GetAccountId()]..' WHERE `account_id` = '..summonPlayer:GetAccountId()..';')
                                    RAF_cleanup()
                                    return false
                                else
                                    RAF_sameIpCounter[summonPlayer:GetAccountId()] = RAF_sameIpCounter[summonPlayer:GetAccountId()] + 1
                                    CharDBExecute('UPDATE `'..Config.customDbName..'`.`recruit_a_friend_links` SET ip_abuse_counter = '..RAF_sameIpCounter[summonPlayer:GetAccountId()]..' WHERE `account_id` = '..summonPlayer:GetAccountId()..';')
                                    RAF_cleanup()
                                    return false
                                end
                            end
                            v:SummonPlayer(player)
                        end
                    end
                else
                    player:SendBroadcastMessage("Summoning is not possible in combat.")
                end
                return false
            else
                player:SendBroadcastMessage("Summoning is not possible here.")
            end
            return false

        elseif commandArray[2] == "unbind" and commandArray[3] == nil then
            if player == nil then return end

            local accountId = player:GetAccountId()
            if RAF_recruiterAccount[accountId] ~= nil then
                RAF_timeStamp[accountId] = 0
                CharDBExecute('UPDATE `'..Config.customDbName..'`.`recruit_a_friend_links` SET time_stamp = 0 WHERE `account_id` = '..accountId..';')
                player:SendBroadcastMessage("Your Recruit-a-friend link was removed by choice.")
                return false
            end

        elseif commandArray[2] == "help" or commandArray[2] == nil then
            if player == nil then return end

            player:SendBroadcastMessage("Your account id is: "..player:GetAccountId())
            player:SendBroadcastMessage("Syntax to list all recruits: .raf list")
            player:SendBroadcastMessage("Syntax to summon the recruit: .raf summon $FriendsCharacterName")
            player:SendBroadcastMessage("Only the recruiter can summon the recruit. The recruit can NOT summon. You must be in a party/raid with each other.")
            RAF_cleanup()
            return false
        end
    end
end

local function RAF_login(event, player)
    local accountId = player:GetAccountId()

    -- display login message
    if Config.displayLoginMessage == 1 then
        player:SendBroadcastMessage("This server features a Recruit-a-friend module. Type .raf for help.")
    end

    RAF_lastIP[accountId] = player:GetPlayerIP()

    -- check for an existing RAF connection when a RECRUIT or RECRUITER logs in
    local recruiterId = RAF_recruiterAccount[player:GetAccountId()]
    if recruiterId == nil and RAF_hasIndex(RAF_recruiterAccount, player:GetAccountId()) == false then
        return false
    end

    -- check for RAF timeout on login of the RECRUIT, possibly remove the link
    if RAF_timeStamp[accountId] <= 1 and RAF_timeStamp[accountId] ~= -1 then
        return false
    end

    --reset abuse counter
    RAF_abuseCounter[accountId] = 0

    local targetDuration = RAF_timeStamp[accountId] + Config.maxRAFduration
    if (tonumber(tostring(GetGameTime()))) > targetDuration then
        RAF_timeStamp[accountId] = 0
        CharDBExecute('UPDATE `'..Config.customDbName..'`.`recruit_a_friend_links` SET time_stamp = 0 WHERE `account_id` = '..accountId..';')
        player:SendBroadcastMessage("Your RAF link has reached the time-limit and expired.")
        return false
    end

    -- add 1 full level of rested at login while in RAF
    if Config.grantRested == 1 then
        player:SetRestBonus(RAF_xpPerLevel[player:GetLevel()])
    end

    -- same IP check
    local recruiterId = RAF_recruiterAccount[accountId]
    if RAF_lastIP[accountId] == RAF_lastIP[recruiterId] then
        if Config.endRAFOnSameIP == 1 then
            player:SendBroadcastMessage("The RAF link was removed")
            CharDBExecute('UPDATE `'..Config.customDbName..'`.`recruit_a_friend_links` SET time_stamp = 0 WHERE `account_id` = '..accountId..';')
            RAF_timeStamp[accountId] = 0
        else
            player:SendBroadcastMessage("Recruit a friend: Possible abuse detected. This action is logged.")
            RAF_sameIpCounter[accountId] = RAF_sameIpCounter[accountId] + 1
            CharDBExecute('UPDATE `'..Config.customDbName..'`.`recruit_a_friend_links` SET ip_abuse_counter = '..RAF_sameIpCounter[accountId]..' WHERE `account_id` = '..accountId..';')
        end
    end

    RAF_cleanup()
    return false
end

local function RAF_levelChange(event, player, oldLevel)

    local accountId = player:GetAccountId()
    -- check for RAF timeout on login of the RECRUIT, possibly remove the link
    if RAF_recruiterAccount[accountId] == nil or RAF_timeStamp[accountId] <= 1 and RAF_timeStamp[accountId] ~= -1 then
        return false
    end

    if oldLevel + 1 >= Config.targetLevel and RAF_timeStamp[accountId] ~= -1 then
        -- set time_stamp to 1 and Grant rewards
        RAF_timeStamp[accountId] = 1
        CharDBExecute('UPDATE `'..Config.customDbName..'`.`recruit_a_friend_links` SET time_stamp = 1 WHERE `account_id` = '..accountId..';')
        GrantReward(RAF_recruiterAccount[accountId])
        player:SendBroadcastMessage("Your RAF link has reached the level-limit. Your recruiter has earned a reward. Go and bring your friends, too!")
        return false
    end

    local recruiterId = RAF_recruiterAccount[accountId]
    if recruiterId == nil then
        return false
    end

     -- add 1 full level of rested at levelup while in RAF and not at maxlevel with Player:SetRestBonus( restBonus )
    if Config.grantRested == 1 then
        player:SetRestBonus(RAF_xpPerLevel[oldLevel + 1])
    end 
end

function GrantReward(recruiterId)

    local recruiterCharacter
    if RAF_rewardLevel[recruiterId] == nil then
        RAF_rewardLevel[recruiterId] = 1
        CharDBExecute('REPLACE INTO `'..Config.customDbName..'`.`recruit_a_friend_rewards` VALUES ('..recruiterId..', '..RAF_rewardLevel[recruiterId]..');')
    else
        RAF_rewardLevel[recruiterId] = RAF_rewardLevel[recruiterId] + 1
        CharDBExecute('UPDATE `'..Config.customDbName..'`.`recruit_a_friend_rewards` SET reward_level = '..RAF_rewardLevel[recruiterId]..' WHERE `recruiter_account` = '..recruiterId..';')
    end

    local Data_SQL = CharDBQuery('SELECT `guid` FROM `characters` WHERE `account` = '..recruiterId..' LIMIT 1;')
    if Data_SQL ~= nil then
        recruiterCharacter = Data_SQL:GetUInt32(0)
    else
        if Config.printErrorsToConsole == 1 then print("RAF: No character found on recruiter account with id "..recruiterId..", which was eligable for a RAF reward of level "..RAF_recruiterAccount[recruiterId]..".") end
        return
    end

    --reward the recruiter
    local rewardLevel = RAF_rewardLevel[recruiterId]
    if Config_rewards[rewardLevel] == nil then
        --send the default set
        SendMail("RAF reward level "..rewardLevel, Config.mailText, recruiterCharacter, Config.senderGUID, Config.mailStationery, 0, 0, 0, Config_defaultRewards[1], Config_defaultAmounts[1], Config_defaultRewards[2], Config_defaultAmounts[2], Config_defaultRewards[3], Config_defaultAmounts[3], Config_defaultRewards[4], Config_defaultAmounts[4])
    else
        SendMail("RAF reward level "..rewardLevel, Config.mailText, recruiterCharacter, Config.senderGUID, Config.mailStationery, 0, 0, 0, Config_rewards[rewardLevel], Config_amounts[rewardLevel])
    end
    RAF_PreventReturn(recruiterCharacter)
end

function RAF_PreventReturn(playerGUID)
    if Config.preventReturn == 1 then
        CharDBExecute('UPDATE `mail` SET `messageType` = 3 WHERE `sender` = '..Config.senderGUID..' AND `receiver` = '..playerGUID..' AND `messageType` = 0;')
    end
end

function RAF_cleanup()
    --todo: check variables for required cleanups
    --set all non local runtime variables to nil
end

function RAF_splitString(inputstr, seperator)
    if seperator == nil then
        seperator = "%s"
    end
    local t={}
    for str in string.gmatch(inputstr, "([^"..seperator.."]+)") do
        table.insert(t, str)
    end
    return t
end

function RAF_hasValue (tab, val)
    for index, value in ipairs(tab) do
        if value == val then
            return true
        end
    end
    return false
end

function RAF_hasIndex (tab, val)
    for index, value in ipairs(tab) do
        if index == val then
            return true
        end
    end
    return false
end

function RAF_checkAbuse(accountId)
    if RAF_abuseCounter[accountId] == nil then
        RAF_abuseCounter[accountId] = 1
    else
        RAF_abuseCounter[accountId] = RAF_abuseCounter[accountId] + 1
    end

    if RAF_abuseCounter[accountId] > Config.abuseTreshold then
        return true
    end
    return false
end

RegisterPlayerEvent(PLAYER_EVENT_ON_COMMAND, RAF_command)
RegisterPlayerEvent(PLAYER_EVENT_ON_LOGIN, RAF_login)
RegisterPlayerEvent(PLAYER_EVENT_ON_LEVEL_CHANGE, RAF_levelChange)

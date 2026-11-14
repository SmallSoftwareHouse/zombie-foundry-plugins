// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zombie Foundry
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. This program is distributed in the hope that it
// will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details: LICENSE
// file next to this source, or <https://www.gnu.org/licenses/>.

/**
 * Zombie Foundry — Match Report v0.1.68
 *
 * Data-first round statistics collector (no MOTD/HUD/SQLite yet).
 * Match boundary = round_start … round_end (campaign/coop).
 * Survival (zf_mr_reset_on_survival_start=1): timed attempt = survival_round_start … round_end,
 * with post-wipe reset after deferred round_end handling.
 */

#include <sourcemod>
#include <halflife>
#include <left4dhooks>
#include <zf_core>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "0.1.81"

// VotePass details for a passed restart vote. The engine log says "RestartGame", but the
// message measured in game (Survival) is restart_chapter; restart_game is
// kept for the other modes.
#define ZMR_VOTE_PASSED_RESTART_CHAPTER "#L4D_vote_passed_restart_chapter"
#define ZMR_VOTE_PASSED_RESTART_GAME "#L4D_vote_passed_restart_game"
#define ZMR_RESTART_VOTE_WINDOW_SEC 15.0

// player_hurt "type" bitfield (Source DMG_*); fall = survivor jump / drop damage.
#define ZMR_DMGTYPE_FALL (1 << 5)
// L4D2 tank death cleanup: 1-dmg ticks + 5000 finisher with equipped weapon (not real hits).
#define ZMR_DMGTYPE_SCRIPT (1 << 17)

// Survivor round table (METRIC log + sm_mr_dump / debug round-end chat).
#define ZMR_STAT_LABEL_SI "SI:"
#define ZMR_STAT_LABEL_FF "FF:"
#define ZMR_STAT_LABEL_DMG_TAKEN "DmgTaken:"
#define ZMR_STAT_LABEL_KILL_SI "KillSI:"
#define ZMR_STAT_LABEL_KILL_TANK "KillTank:"

// In-memory slots for tanks this attempt (closed kept until round reset so end Tank % still
// sees fire/world). Survival rarely exceeds a handful; g_iTanksSpawnedThisRound has no cap.
#define ZMR_MAX_TANK_TRACKING_SLOTS 32

// Compact debug trace in chat for in-game humans (zf_mr_debug_trace_chat). L4D2 stock codes — no MoreColors.
#define ZMR_TRACE_COLOR_SERVER "\x01"  // white — server/engine events
#define ZMR_TRACE_COLOR_PLUGIN "\x03"  // cyan — plugin actions
#define ZMR_TRACE_VISIBLE_MAX 41

#define ZMR_DEBUG_CLOCK_HUD_INTERVAL 1.0
#define ZMR_DEBUG_CLOCK_CHAT_FALLBACK_INTERVAL 60.0

#define ZMR_CHAT_TAG "[zf_mr]"
// Longest survivor name in chat table (truncate with ..); column width grows to longest name in this dump.
#define ZMR_CHAT_NAME_MAX 12
// L4D chat line budget — shrink name cap if the composed row would exceed this.
#define ZMR_CHAT_LINE_MAX 192
#define ZMR_CHAT_STAT_TRAIL_SPACES 2
#define ZMR_CHAT_DUMP_SEPARATOR "[zf_mr] --------------------------------"
#define ZMR_METRIC_DUMP_SEPARATOR "[zf_mr] METRIC --------------------------------"
// Tank-death chat box: plain lines (no [zf_mr] tag); L4D2 chat is roughly monospace.
#define ZMR_TANK_DEATH_CHAT_SEPARATOR "--------------------------------"
#define ZMR_TANK_EXTRA_CHAT_OMIT_PCT 1.0
#define ZMR_TANK_CHAT_LABEL_ROCK "Rock"
#define ZMR_TANK_CHAT_LABEL_ZOMBIES "Zombies"
#define ZMR_TANK_CHAT_LABEL_FIRE "Fire"
#define ZMR_TANK_CHAT_MAX_ROWS 48
#define ZMR_TANK_CHAT_PCT_TOTAL_TENTHS 1000

enum struct ZMR_TankChatRow
{
	char label[48];
	int eff;
	int pct10;
}

// Tank bd= category keys (schema 3 — see DATA-MODEL.md Damage registration).
#define ZMR_DMG_SURVIVOR_SLOT 0
#define ZMR_DMG_CAT_TANK_ROCK 1
#define ZMR_DMG_CAT_TANK_MELEE 2
#define ZMR_DMG_CAT_FIRE 3
#define ZMR_DMG_CAT_ENV 4
#define ZMR_DMG_CAT_SI_COMMON 5
#define ZMR_DMG_CAT_SI_TANK 6
#define ZMR_DMG_CAT_SI_CLASS 7
#define ZMR_DMG_CAT_OTHER 8

// Survival often fires multiple round_end in quick succession; defer one chat dump so stats settle.
#define ZMR_ROUND_END_DUMP_DEFER_SEC 0.4
// Survival: after a real wipe the game shows its end screen and the second round_end (reason 0)
// comes ~15 s later; after an interrupted match (restart vote) it comes ~1 s later. Waiting this
// long before the dump tells the two apart (measured in game).
#define ZMR_SURVIVAL_END_DECIDE_SEC 3.0
// End report: [ZF] chat first (after METRIC settle), then the full console box later.
// PrintToChat always echoes into the client console; chat-before-console keeps that
// echo above MATCH REPORT…END REPORT (never after END REPORT, never between Tank % and END).
// 0.1.68 used 1.0s after chat; client still painted the echo BELOW the box — bump to 2.0s.
#define ZMR_END_REPORT_CHAT_DELAY_SEC 1.50
#define ZMR_END_REPORT_CONSOLE_AFTER_CHAT_SEC 2.00
// Tank-death chat is deferred briefly so a wipe that fires round_end in the same
// moment can cancel it — never print tank #N dead after the closing report.
#define ZMR_TANK_DEATH_CHAT_DEFER_SEC 0.45
// ShowMOTDPanel msg field limit (Source engine).
#define ZMR_REPORT_URL_MAX 192
// L4D2 chat is proportional (Verdana-like / ChatFont). Widths approx; space = 4.
// Tank-death columns pad to the MAX measured width in the current block (not a fixed px).
// Dev measure: sm_mr_chatglyphs.
#define ZMR_CHAT_SPACE_PX 4
// Soft cap so a absurdly long name cannot blow the chat line; pad target is still max-in-block.
#define ZMR_TANK_DEATH_CHAT_NAME_CAP_PX 110

// 6: authoritative round_end dump carries match=<n> in the header and a closing "METRIC end match=<n>".
#define ZMR_SCHEMA_VERSION 6

// Hunter deadstop/skeet: correlate shove within this window (seconds).
#define ZMR_HUNTER_SHOVE_CORRELATE_SEC 1.25

// infected_hurt hitgroup (Source SDK).
#define ZMR_HITGROUP_HEAD 1

// Special infected classes tracked for per-class dmg/kill (excludes Tank — see tank instances).
#define ZMR_SI_CLASS_COUNT 7

ConVar g_cvEnabled;
ConVar g_cvDebugAutoDump;
ConVar g_cvDebugRoundEnd;
ConVar g_cvDebugEvents;
ConVar g_cvDebugBoundaries;
ConVar g_cvDebugClock;
ConVar g_cvDebugClockChatFallback;
ConVar g_cvDebugTraceChat;
ConVar g_cvResetOnSurvivalStart;
ConVar g_cvTankReportOnDeath;
ConVar g_cvDevAllowPause;
ConVar g_cvReportOpenOnRoundEnd;
ConVar g_cvReportOpenDelay;
ConVar g_cvReportUrl;
ConVar g_cvReportTitle;
ConVar g_cvReportChat;
ConVar g_cvReportConsole;
ConVar g_hZTankHealthCvar;

int g_iTanksSpawnedThisRound;
Handle g_hRoundEndChatDumpTimer = null;
Handle g_hDebugClockHudSync = null;
Handle g_hDebugClockTimer = null;
Handle g_hDebugClockChatFallbackTimer = null;
Handle g_hPendingTankDeathChatTimer[ZMR_MAX_TANK_TRACKING_SLOTS];
int g_iMapStartUnix;
int g_iDebugClockAnchorUnix;
bool g_bAutoRoundEndChatDumpSentThisRound;
bool g_bSurvivalTimedRoundBegun;
// Set when the authoritative end-report sequence starts; stays true until round reset.
// Suppresses / cancels per-tank death chat for the rest of this attempt (no flush later).
bool g_bEndChatSequenceActive;
// Increments on each authoritative [ZF] end report (chat/console); helps spot duplicate emissions.
int g_iEndReportStamp;
// Set at the authoritative round_end so the delayed report matches that instant, not the epilogue.
bool g_bRoundStatsFrozen;
// Survival stats clear waits until delayed end report is delivered.
bool g_bDeferSurvivalClearAfterEndReport;
// Fire/world tank damage closed into released slots — kept for end Tank % line.
int g_iRoundTankFireEffective;
int g_iRoundTankEnvEffective;
// Common deaths not added to a survivor row. Logged at wipe; the report number stays the credited sum.
int g_iCommonSkippedNoAttacker;
int g_iCommonSkippedNotSurvivor;
int g_iCommonSkippedFrozen;
// Engine time of the last passed "restart game" vote; 0.0 = none pending. The round_end that
// follows is an interruption, not a finished match: no report, no METRIC block, no recap.
float g_fRestartVotePassedAt;

enum struct ZMR_RoundPlayerStats
{
	char steamId[MAX_AUTHID_LENGTH];
	int damageDealtInfected;
	int damageDealtFF;
	int damageTaken;
	int damageTakenFromSurvivor[MAXPLAYERS + 1];
	int damageTakenFromInfected;
	int damageTakenFromFall;
	int damageTakenFromWorld;
	int siKills;
	int tankKills;
	int tankDamageEffective;
	int siClassDamage[ZMR_SI_CLASS_COUNT];
	int siClassKills[ZMR_SI_CLASS_COUNT];
	int commonKills;
	int commonHeadshotKills;
	int commonDamageDealt;
	int commonHeadshotDamage;
	int healReceivedFrom[MAXPLAYERS + 1];
	int reviveReceivedFrom[MAXPLAYERS + 1];
	int medkitSelf;
	int medkitOther;
	int pillsUsed;
	int adrenalineUsed;
	int defibOther;
	int reviveGiven;
	int reviveReceived;
	int incapCount;
	int deathCount;
	int grabSmoker;
	int grabJockey;
	int grabHunter;
	int grabCharger;
	int grabBoomer;
	int defenseFreed;
	int defenseShoves;
	int defenseDeadstop;
	int defenseSkeet;
	int meleeSiDamage;
	int meleeCommonDamage;
}

ZMR_RoundPlayerStats g_RoundStats[MAXPLAYERS + 1];

bool g_bHunterLunging[MAXPLAYERS + 1];
int g_iLastShoveAttackerOnHunter[MAXPLAYERS + 1];
float g_fLastShoveTimeOnHunter[MAXPLAYERS + 1];

enum struct ZMR_TankInstanceStats
{
	int spawnSeq;
	int tankClient;
	int maxHp;
	int zTankHealthCvar;
	int damageEffective[MAXPLAYERS + 1];
	int damageRaw[MAXPLAYERS + 1];
	int totalEffective;
	int damageRockEffective;
	int damageRockRaw;
	int damageMeleeEffective;
	int damageMeleeRaw;
	int damageFireEffective;
	int damageFireRaw;
	int damageFireLitByEffective[MAXPLAYERS + 1];
	int damageFireLitByRaw[MAXPLAYERS + 1];
	int damageEnvEffective;
	int damageEnvRaw;
	int damageSiCommonEffective;
	int damageSiCommonRaw;
	int damageSiTankEffective;
	int damageSiTankRaw;
	int damageSiClassEffective[ZMR_SI_CLASS_COUNT];
	int damageSiClassRaw[ZMR_SI_CLASS_COUNT];
	int damageOtherEffective;
	int damageOtherRaw;
	int killerClient;
	bool closed;
}

ZMR_TankInstanceStats g_TankInstances[ZMR_MAX_TANK_TRACKING_SLOTS];
int g_iTankInstanceCount;

public Plugin myinfo =
{
	name = "Zombie Foundry Match Report",
	author = "Zombie Foundry",
	description = "Per-round match statistics collector (MVP)",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	if (!ZF_IsCoreLoaded())
	{
		SetFailState("Zombie Foundry Core (zf_core.smx) is required. Load zf_core first.");
	}

	g_cvEnabled = CreateConVar("zf_mr_enabled", "1",
		"Master switch for per-round stat collection (1=on, 0=off).",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDebugAutoDump = CreateConVar("zf_mr_debug_auto_dump", "1",
		"1=at round_end (deferred), write full round metrics to SourceMod log as [zf_mr] METRIC lines (no chat).",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDebugRoundEnd = CreateConVar("zf_mr_debug_round_end", "0",
		"1=at round_end, print the round stats table in chat to every survivor (test aid).",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDebugEvents = CreateConVar("zf_mr_debug_events", "0",
		"1=LogMessage round/survival boundaries and player_hurt/death to the SourceMod log.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDebugBoundaries = CreateConVar("zf_mr_debug_boundaries", "0",
		"1=LogMessage BOUNDARY markers for round/Survival edges; chat BOUNDARY only if zf_mr_debug_trace_chat=0.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDebugTraceChat = CreateConVar("zf_mr_debug_trace_chat", "0",
		"1=compact colored trace in chat for in-game humans (HH:MM:SS msg); file uses [zf_mr] S/P prefixes.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDebugClock = CreateConVar("zf_mr_debug_clock", "0",
		"1=debug wall clock HUD (best-effort) + optional chat pings if zf_mr_debug_clock_chat_fallback=1.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDebugClockChatFallback = CreateConVar("zf_mr_debug_clock_chat_fallback", "0",
		"With zf_mr_debug_clock 1: 1=optional cyan HH:MM:SS clock in chat (60s, join, surv_start); 0=off (default).",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvResetOnSurvivalStart = CreateConVar("zf_mr_reset_on_survival_start", "1",
		"Survival: 1=reset counters on survival_round_start (timed attempt); 0=reset only on round_start (legacy).",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvTankReportOnDeath = CreateConVar("zf_mr_tank_report_on_death", "1",
		"1=on each tracked tank death, print a compact damage table in chat to all human players (Survival-friendly).",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDevAllowPause = CreateConVar("zf_mr_dev_allow_pause", "0",
		"1=set sv_pausable 1 on map load so host can pause to inspect logs during metric tests.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvReportOpenOnRoundEnd = CreateConVar("zf_mr_report_open_on_round_end", "0",
		"1=when the recap page is ready within 20s of the end report, open it for human survivors (needs zf_mr_report_url). 0=chat notice only; !recap always works.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvReportOpenDelay = CreateConVar("zf_mr_report_open_delay", "10",
		"Seconds after the end of the match before the recap page opens (or the chat notice), so the game's own end screen stays visible. 0=as soon as it is ready.",
		FCVAR_NOTIFY, true, 0.0, true, 60.0);
	g_cvReportUrl = CreateConVar("zf_mr_report_url", "",
		"HTTP URL of the recap FOLDER, with trailing slash; the plugin opens <url><match>.html (full address max 191 chars). Empty=disabled.",
		FCVAR_NOTIFY);
	g_cvReportTitle = CreateConVar("zf_mr_report_title", "Zombie Foundry Match Report",
		"Title bar for the report MOTD panel.",
		FCVAR_NOTIFY);
	g_cvReportChat = CreateConVar("zf_mr_report_chat", "1",
		"1=at authoritative round_end, print compact match summary in chat to human survivors.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvReportConsole = CreateConVar("zf_mr_report_console", "1",
		"1=at authoritative round_end, print full match table to human survivor consoles.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	LoadTranslations("zf_match_report.phrases");

	g_hDebugClockHudSync = CreateHudSynchronizer();
	g_cvDebugClock.AddChangeHook(ZMR_OnDebugClockChanged);
	g_cvDebugClockChatFallback.AddChangeHook(ZMR_OnDebugClockChanged);

	AutoExecConfig(true, "zf_match_report");

	g_hZTankHealthCvar = FindConVar("z_tank_health");

	LogMessage("[zf_mr] loaded plugin version %s", PLUGIN_VERSION);

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("round_end_message", Event_RoundEndMessage, EventHookMode_PostNoCopy);
	HookEvent("survival_round_start", Event_SurvivalRoundStart, EventHookMode_PostNoCopy);
	HookEvent("mission_lost", Event_MissionLost, EventHookMode_PostNoCopy);
	HookEvent("finale_win", Event_FinaleWin, EventHookMode_PostNoCopy);
	HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
	HookEvent("infected_death", Event_InfectedDeath, EventHookMode_Post);
	HookEvent("infected_hurt", Event_InfectedHurt, EventHookMode_Post);
	HookEvent("heal_success", Event_HealSuccess, EventHookMode_Post);
	HookEvent("pills_used", Event_PillsUsed, EventHookMode_Post);
	HookEvent("adrenaline_used", Event_AdrenalineUsed, EventHookMode_Post);
	HookEvent("defibrillator_used", Event_DefibrillatorUsed, EventHookMode_Post);
	HookEvent("revive_success", Event_ReviveSuccess, EventHookMode_Post);
	HookEvent("player_incapacitated_start", Event_PlayerIncapStart, EventHookMode_Post);
	HookEvent("tongue_grab", Event_TongueGrab, EventHookMode_Post);
	HookEvent("tongue_pull_stopped", Event_TonguePullStopped, EventHookMode_Post);
	HookEvent("jockey_ride", Event_JockeyRide, EventHookMode_Post);
	HookEvent("lunge_pounce", Event_LungePounce, EventHookMode_Post);
	HookEvent("lunge_shove", Event_LungeShove, EventHookMode_Post);
	HookEvent("charger_carry_start", Event_ChargerCarryStart, EventHookMode_Post);
	HookEvent("charger_pummel_start", Event_ChargerPummelStart, EventHookMode_Post);
	HookEvent("player_now_it", Event_PlayerNowIt, EventHookMode_Post);
	HookEvent("player_shoved", Event_PlayerShoved, EventHookMode_Post);
	HookEvent("jockey_ride_end", Event_JockeyRideEnd, EventHookMode_Post);
	HookEvent("pounce_stopped", Event_PounceStopped, EventHookMode_Post);
	HookEvent("charger_carry_end", Event_ChargerCarryEnd, EventHookMode_Post);

	UserMsg votePass = GetUserMessageId("VotePass");
	if (votePass != INVALID_MESSAGE_ID && GetUserMessageType() == UM_BitBuf)
	{
		HookUserMessage(votePass, ZMR_OnVotePass);
	}
	else
	{
		LogError("[zf_mr] VotePass user message not hookable — restart votes will still produce a report");
	}

	RegAdminCmd("sm_mr_chatglyphs", Cmd_MrChatGlyphs, ADMFLAG_GENERIC,
		"Dev: print proportional-font reference rows in chat for width mapping.");
	RegAdminCmd("sm_mr_caratteri", Cmd_MrChatGlyphs, ADMFLAG_GENERIC,
		"Same as sm_mr_chatglyphs: test lines in chat for the character widths.");
	RegAdminCmd("sm_mr_version", Cmd_MrVersion, ADMFLAG_GENERIC,
		"Print match-report plugin version (build id for deploy checks).");
	RegAdminCmd("sm_mr_report", Cmd_Recap, ADMFLAG_GENERIC,
		"Same as sm_recap: open the recap page of the last finished match.");
	RegAdminCmd("sm_mr_dump", Cmd_MrDump, ADMFLAG_GENERIC,
		"Print collected round stats for the current round.");

	ZMR_Recap_RegisterCommands();

	ZMR_ResetRound();

	if (g_iDebugClockAnchorUnix == 0)
	{
		g_iDebugClockAnchorUnix = GetTime();
	}

	ZMR_UpdateDebugClockTimer();
}

public void OnPluginEnd()
{
	ZMR_StopDebugClockTimer();
	ZMR_StopDebugClockChatFallbackTimer();
	if (g_hDebugClockHudSync != null)
	{
		ZMR_ClearDebugClockHudAll();
		delete g_hDebugClockHudSync;
		g_hDebugClockHudSync = null;
	}
}

public void OnClientDisconnect(int client)
{
	if (g_hDebugClockHudSync != null)
	{
		ClearSyncHud(client, g_hDebugClockHudSync);
	}
}

public void OnClientPutInServer(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	if (g_cvDebugClock != null && g_cvDebugClock.BoolValue && ZMR_DebugClockChatActive())
	{
		ZMR_DebugClockChatPingClient(client, true);
	}

	if (g_cvDebugTraceChat == null || !g_cvDebugTraceChat.BoolValue)
	{
		return;
	}

	char name[MAX_NAME_LENGTH];
	if (!GetClientName(client, name, sizeof(name)))
	{
		name[0] = '\0';
	}

	char shortName[32];
	ZMR_TruncateNameForChat(name, shortName, sizeof(shortName), 27);

	char shortMsg[48];
	Format(shortMsg, sizeof(shortMsg), "join %s", shortName);
	ZMR_LogTraceFile(true, "join client=%d name=%s", client, name);
	ZMR_TraceChat(true, shortMsg);
}

// TIMER_FLAG_NO_MAPCHANGE timers die with the map; forget the handle so round_start does not
// wait for a dump that will never fire (the 3 s Survival window makes this reachable).
public void OnMapEnd()
{
	g_hRoundEndChatDumpTimer = null;
	g_bEndChatSequenceActive = false;
}

public void OnMapStart()
{
	g_bSurvivalTimedRoundBegun = false;
	g_iMapStartUnix = GetTime();
	g_iDebugClockAnchorUnix = g_iMapStartUnix;

	if (g_cvDebugBoundaries.BoolValue)
	{
		ZMR_LogBoundaryEvent("map_start", "engine_map_loaded", -1, -1, "", -1.0);
	}

	if (g_cvDebugTraceChat.BoolValue)
	{
		ZMR_LogTraceFile(true, "map_start engine_map_loaded");
		ZMR_TraceChat(true, "map_start");
		RequestFrame(ZMR_Frame_PluginMapReadyTrace);
	}

	ZMR_UpdateDebugClockTimer();
}

public void OnConfigsExecuted()
{
	ZMR_UpdateDebugClockTimer();
	ZMR_ApplyDevAllowPause();

	if (ZMR_DebugClockChatActive())
	{
		ZMR_DebugClockChatPingAll(false);
	}

	if (g_cvDebugTraceChat != null && g_cvDebugTraceChat.BoolValue)
	{
		ZMR_LogTraceFile(true, "map_ready configs_executed");
		ZMR_TraceChat(true, "map_ready");
	}
}

void ZMR_Frame_PluginMapReadyTrace()
{
	if (g_cvDebugTraceChat == null || !g_cvDebugTraceChat.BoolValue)
	{
		return;
	}

	ZMR_LogTraceFile(false, "map_ready collectors armed");
	ZMR_TraceChat(false, "map_ready");
}

void ZMR_OnDebugClockChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ZMR_UpdateDebugClockTimer();
}

void ZMR_UpdateDebugClockTimer()
{
	ZMR_StopDebugClockTimer();
	ZMR_StopDebugClockChatFallbackTimer();

	if (g_cvDebugClock == null || !g_cvDebugClock.BoolValue)
	{
		ZMR_ClearDebugClockHudAll();
		return;
	}

	g_hDebugClockTimer = CreateTimer(ZMR_DEBUG_CLOCK_HUD_INTERVAL, Timer_DebugClockHud,
		_, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	Timer_DebugClockHud(null);

	if (ZMR_DebugClockChatActive())
	{
		g_hDebugClockChatFallbackTimer = CreateTimer(ZMR_DEBUG_CLOCK_CHAT_FALLBACK_INTERVAL,
			Timer_DebugClockChatFallback, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
}

bool ZMR_DebugClockChatActive()
{
	return g_cvDebugClock != null && g_cvDebugClock.BoolValue
		&& g_cvDebugClockChatFallback != null && g_cvDebugClockChatFallback.BoolValue;
}

void ZMR_FormatWallClock(char[] wallClock, int wallClockLen)
{
	FormatTime(wallClock, wallClockLen, "%H:%M:%S");
}

void ZMR_DebugClockChatPingClient(int client, bool joinLine)
{
	if (!ZMR_IsHumanInGame(client))
	{
		return;
	}

	char wallClock[16];
	ZMR_FormatWallClock(wallClock, sizeof(wallClock));
	ZMR_LogDebugClock(wallClock);

	char line[48];
	if (joinLine)
	{
		Format(line, sizeof(line), "%sclock %s", ZMR_TRACE_COLOR_PLUGIN, wallClock);
	}
	else
	{
		Format(line, sizeof(line), "%s%s clock", ZMR_TRACE_COLOR_PLUGIN, wallClock);
	}

	PrintToChat(client, "%s", line);
}

void ZMR_DebugClockChatPingAll(bool joinLine)
{
	if (!ZMR_DebugClockChatActive())
	{
		return;
	}

	char wallClock[16];
	ZMR_FormatWallClock(wallClock, sizeof(wallClock));
	ZMR_LogDebugClock(wallClock);

	char line[48];
	if (joinLine)
	{
		Format(line, sizeof(line), "%sclock %s", ZMR_TRACE_COLOR_PLUGIN, wallClock);
	}
	else
	{
		Format(line, sizeof(line), "%s%s clock", ZMR_TRACE_COLOR_PLUGIN, wallClock);
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!ZMR_IsHumanInGame(client))
		{
			continue;
		}

		PrintToChat(client, "%s", line);
	}
}

void ZMR_LogDebugClock(const char[] wallClock)
{
	LogMessage("[zf_mr] clock %s", wallClock);
}

void ZMR_StopDebugClockTimer()
{
	if (g_hDebugClockTimer != null)
	{
		delete g_hDebugClockTimer;
		g_hDebugClockTimer = null;
	}
}

void ZMR_StopDebugClockChatFallbackTimer()
{
	if (g_hDebugClockChatFallbackTimer != null)
	{
		delete g_hDebugClockChatFallbackTimer;
		g_hDebugClockChatFallbackTimer = null;
	}
}

void ZMR_ClearDebugClockHudAll()
{
	if (g_hDebugClockHudSync == null)
	{
		return;
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			ClearSyncHud(client, g_hDebugClockHudSync);
		}
	}
}

public Action Timer_DebugClockHud(Handle timer)
{
	if (g_cvDebugClock == null || !g_cvDebugClock.BoolValue || g_hDebugClockHudSync == null)
	{
		return Plugin_Stop;
	}

	char wallClock[16];
	FormatTime(wallClock, sizeof(wallClock), "%H:%M:%S");

	int elapsed = GetTime() - g_iDebugClockAnchorUnix;
	if (elapsed < 0)
	{
		elapsed = 0;
	}

	char hudLine[40];
	Format(hudLine, sizeof(hudLine), "%s\n+ %02d:%02d", wallClock, elapsed / 60, elapsed % 60);

	SetHudTextParams(-1.0, 0.08, 1.5, 255, 255, 255, 255, 0, 0.0, 0.0, 0.0);

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!ZMR_IsHumanInGame(client))
		{
			continue;
		}

		ShowSyncHudText(client, g_hDebugClockHudSync, hudLine);
	}

	return Plugin_Continue;
}

public Action Timer_DebugClockChatFallback(Handle timer)
{
	if (!ZMR_DebugClockChatActive())
	{
		return Plugin_Stop;
	}

	ZMR_DebugClockChatPingAll(false);
	return Plugin_Continue;
}

bool ZMR_IsHumanInGame(int client)
{
	return IsClientInGame(client) && !IsFakeClient(client);
}

bool ZMR_ReportUrlConfigured()
{
	char url[ZMR_REPORT_URL_MAX];
	g_cvReportUrl.GetString(url, sizeof(url));
	TrimString(url);
	return url[0] != '\0';
}

public void L4D_OnSpawnTank_Post(int client, const float vecPos[3], const float vecAng[3])
{
	if (g_bRoundStatsFrozen)
	{
		return;
	}

	g_iTanksSpawnedThisRound++;

	if (g_cvDebugTraceChat != null && g_cvDebugTraceChat.BoolValue)
	{
		char shortMsg[48];
		Format(shortMsg, sizeof(shortMsg), "tk_spawn #%d", g_iTanksSpawnedThisRound);
		ZMR_LogTraceFile(true, "tank_spawn #%d client=%d", g_iTanksSpawnedThisRound, client);
		ZMR_TraceChat(true, shortMsg);
	}

	if (!g_cvEnabled.BoolValue)
	{
		return;
	}

	ZMR_RegisterTankSpawn(client);
}

// L4D2 bitbuf VotePass: team (byte), details (string), param1 (string).
public Action ZMR_OnVotePass(UserMsg msg_id, BfRead msg, const int[] players, int playersNum,
	bool reliable, bool init)
{
	msg.ReadByte();
	char details[64];
	msg.ReadString(details, sizeof(details));

	LogMessage("[zf_mr] vote passed: %s", details);

	if (StrEqual(details, ZMR_VOTE_PASSED_RESTART_CHAPTER, false)
		|| StrEqual(details, ZMR_VOTE_PASSED_RESTART_GAME, false))
	{
		g_fRestartVotePassedAt = GetEngineTime();
	}

	return Plugin_Continue;
}

// The restart follows the vote within a couple of seconds; the window only guards against a
// vote whose restart never came, so a later real wipe is not swallowed.
bool ZMR_RestartVotePending()
{
	return g_fRestartVotePassedAt > 0.0
		&& GetEngineTime() - g_fRestartVotePassedAt < ZMR_RESTART_VOTE_WINDOW_SEC;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	// The restart is done: both round_end of the restart have been skipped by now.
	g_fRestartVotePassedAt = 0.0;

	bool survivalBoundary = ZMR_UseSurvivalRoundStartBoundary();

	char action[64];
	if (!survivalBoundary)
	{
		strcopy(action, sizeof(action), "reset_stats");
	}
	else if (g_hRoundEndChatDumpTimer != null)
	{
		strcopy(action, sizeof(action), "defer_reset_round_end_pending");
	}
	else if (g_bSurvivalTimedRoundBegun)
	{
		strcopy(action, sizeof(action), "reset_post_wipe_restart");
	}
	else
	{
		strcopy(action, sizeof(action), "skip_reset_wait_survival_round_start");
	}

	if (g_cvDebugBoundaries.BoolValue)
	{
		ZMR_LogBoundaryEvent("round_start", action, -1, -1, "", -1.0);
	}

	if (g_cvDebugTraceChat.BoolValue)
	{
		char shortMsg[40];
		ZMR_FormatRoundStartTraceShort(action, shortMsg, sizeof(shortMsg));
		ZMR_LogTraceFile(true, "round_start action=%s", action);
		ZMR_TraceChat(true, shortMsg);
	}

	if (g_cvDebugEvents.BoolValue)
	{
		char mode[32] = "?";
		ConVar cvMode = FindConVar("mp_gamemode");
		if (cvMode != null)
		{
			cvMode.GetString(mode, sizeof(mode));
		}

		if (survivalBoundary)
		{
			if (g_hRoundEndChatDumpTimer != null)
			{
				LogMessage("[zf_mr] round_start (mp_gamemode=%s) — reset deferred (round_end handler pending)", mode);
			}
			else if (g_bSurvivalTimedRoundBegun)
			{
				LogMessage("[zf_mr] round_start (mp_gamemode=%s) — resetting stats (post-wipe restart)", mode);
			}
			else
			{
				LogMessage("[zf_mr] round_start (mp_gamemode=%s) — reset skipped (wait for survival_round_start)", mode);
			}
		}
		else
		{
		LogMessage("[zf_mr] round_start (mp_gamemode=%s) — resetting round stats", mode);
		}
	}

	if (!survivalBoundary)
	{
		ZMR_ResetRoundWithTrace("round_start");
		return;
	}

	if (g_hRoundEndChatDumpTimer != null)
	{
		return;
	}

	if (g_bSurvivalTimedRoundBegun)
	{
		ZMR_ResetRoundWithTrace("post_wipe_restart", false);
	}
}

public void Event_SurvivalRoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bSurvivalTimedRoundBegun = true;
	g_iDebugClockAnchorUnix = GetTime();
	g_bAutoRoundEndChatDumpSentThisRound = false;

	if (ZMR_DebugClockChatActive())
	{
		ZMR_DebugClockChatPingAll(false);
	}

	if (!ZMR_UseSurvivalRoundStartBoundary())
	{
		if (g_cvDebugBoundaries.BoolValue)
		{
			ZMR_LogBoundaryEvent("survival_round_start", "no_reset_legacy_cvar", -1, -1, "", -1.0);
		}

		if (g_cvDebugEvents.BoolValue)
		{
			LogMessage("[zf_mr] survival_round_start — no stat reset (zf_mr_reset_on_survival_start=0)");
		}

		return;
	}

	if (g_cvDebugBoundaries.BoolValue)
	{
		ZMR_LogBoundaryEvent("survival_round_start", "reset_timed_attempt_BEGIN", -1, -1, "", -1.0);
	}

	if (g_cvDebugTraceChat.BoolValue)
	{
		ZMR_LogTraceFile(true, "survival_round_start timed_attempt_BEGIN");
		ZMR_TraceChat(true, "surv_start");
	}

	if (g_cvDebugEvents.BoolValue)
	{
		LogMessage("[zf_mr] survival_round_start — resetting round stats (timed Survival attempt)");
	}

	ZMR_ResetRoundWithTrace("survival_round_start");
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	if (g_cvDebugBoundaries.BoolValue)
	{
		char msg[96];
		event.GetString("message", msg, sizeof(msg));
		ZMR_LogBoundaryEvent("round_end",
			"timed_attempt_END",
			event.GetInt("winner"),
			event.GetInt("reason"),
			msg,
			event.GetFloat("time"));
	}

	if (g_cvDebugTraceChat.BoolValue)
	{
		int reason = event.GetInt("reason");
		float endTime = event.GetFloat("time");
		char shortMsg[40];
		Format(shortMsg, sizeof(shortMsg), "re r=%d t=%.0fs", reason, endTime);
		ZMR_LogTraceFile(true, "round_end winner=%d reason=%d time=%.2f",
			event.GetInt("winner"), reason, endTime);
		ZMR_TraceChat(true, shortMsg);
	}

	if (g_cvDebugEvents.BoolValue)
	{
		char msg[96];
		event.GetString("message", msg, sizeof(msg));
		LogMessage("[zf_mr] round_end winner=%d reason=%d msg=%s",
			event.GetInt("winner"),
			event.GetInt("reason"),
			msg);
	}

	if (!g_cvEnabled.BoolValue)
	{
		return;
	}

	if (ZMR_RestartVotePending())
	{
		LogMessage("[zf_mr] round_end reason=%d after restart vote — match interrupted, no report",
			event.GetInt("reason"));
		return;
	}

	bool autoDump = g_cvDebugAutoDump != null && g_cvDebugAutoDump.BoolValue;
	bool chatDump = g_cvDebugRoundEnd.BoolValue;
	bool survivalBoundary = ZMR_UseSurvivalRoundStartBoundary();

	bool endReport = (g_cvReportChat != null && g_cvReportChat.BoolValue)
		|| (g_cvReportConsole != null && g_cvReportConsole.BoolValue);

	if (!chatDump && !autoDump && !survivalBoundary && !endReport)
	{
		return;
	}

	int reason = event.GetInt("reason");

	if (survivalBoundary)
	{
		// Survival wipe: authoritative summary on reason=14; reason=0 is post-restart epilogo (duplicate).
		if (reason == 0)
		{
			// Restart right after the end, without the end screen: the match was interrupted
			// (admin restart, plugin, tool). Drop the pending report; round_start resets stats.
			if (g_hRoundEndChatDumpTimer != null)
			{
				ZMR_CancelDeferredRoundEndChatDump();
				g_bEndChatSequenceActive = false;
				LogMessage("[zf_mr] round_end reason=0 within %.0fs of the end — match interrupted, no report",
					ZMR_SURVIVAL_END_DECIDE_SEC);
				return;
			}

			if (g_cvDebugEvents.BoolValue)
			{
				LogMessage("[zf_mr] round_end reason=0 survival epilogo — skip deferred summary");
			}

			return;
		}

		if (g_bAutoRoundEndChatDumpSentThisRound)
		{
			if (g_cvDebugEvents.BoolValue)
			{
				LogMessage("[zf_mr] round_end reason=%d — summary already sent this attempt", reason);
			}

			return;
		}
	}

	g_bEndChatSequenceActive = true;
	g_bRoundStatsFrozen = true;
	ZMR_CancelPendingTankDeathChats();
	ZMR_ScheduleDeferredRoundEndChatDump();
}

public void Event_RoundEndMessage(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvDebugBoundaries.BoolValue)
	{
		return;
	}

	char msg[96];
	event.GetString("message", msg, sizeof(msg));
	ZMR_LogBoundaryEvent("round_end_message",
		"",
		event.GetInt("winner"),
		event.GetInt("reason"),
		msg,
		-1.0);
}

public void Event_MissionLost(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvDebugBoundaries.BoolValue)
	{
		return;
	}

	ZMR_LogBoundaryEvent("mission_lost", "survivors_failed", -1, -1, "", -1.0);
}

public void Event_FinaleWin(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvDebugBoundaries.BoolValue)
	{
		return;
	}

	ZMR_LogBoundaryEvent("finale_win", "survivors_won_finale", -1, -1, "", -1.0);
}

bool ZMR_PlayerHurtIsFallDamage(Event event)
{
	return (event.GetInt("type") & ZMR_DMGTYPE_FALL) != 0;
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	int damage = event.GetInt("dmg_health");

	if (damage <= 0)
	{
		return;
	}

	if (g_cvDebugEvents.BoolValue)
	{
		ZMR_LogHurt(event, victim, attacker, damage);
	}

	if (victim > 0 && victim <= MaxClients && IsClientInGame(victim))
	{
		ZMR_EnsureSteamId(victim);

		if (ZMR_IsSurvivor(victim))
		{
			g_RoundStats[victim].damageTaken += damage;

			if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker)
				&& ZMR_IsSurvivor(attacker))
			{
				if (attacker != victim)
				{
					g_RoundStats[victim].damageTakenFromSurvivor[attacker] += damage;
				}
			}
			else if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker)
				&& ZMR_IsInfectedPlayer(attacker))
			{
				g_RoundStats[victim].damageTakenFromInfected += damage;
			}
			else if (ZMR_PlayerHurtIsFallDamage(event))
			{
				g_RoundStats[victim].damageTakenFromFall += damage;
			}
			else
			{
				g_RoundStats[victim].damageTakenFromWorld += damage;
			}
		}

		if (ZMR_IsInfectedPlayer(victim))
		{
			L4D2ZombieClassType zclass = L4D2_GetPlayerZombieClass(victim);
			if (zclass == L4D2ZombieClass_Tank)
			{
				char weapon[32];
				event.GetString("weapon", weapon, sizeof(weapon));

				if (g_cvDebugEvents.BoolValue)
				{
					ZMR_LogTankHurt(victim, attacker, damage, weapon);
				}

				ZMR_RecordTankHurt(victim, attacker, damage, weapon, event.GetInt("type"));
			}
		}
	}

	if (attacker <= 0 || attacker > MaxClients || !IsClientInGame(attacker))
	{
		return;
	}

	if (!ZMR_IsSurvivor(attacker))
	{
		return;
	}

	ZMR_EnsureSteamId(attacker);

	if (ZMR_IsInfectedPlayer(victim))
	{
		g_RoundStats[attacker].damageDealtInfected += damage;

		L4D2ZombieClassType hurtClass = L4D2_GetPlayerZombieClass(victim);
		int siIdx = ZMR_SiClassToIndex(hurtClass);
		if (siIdx >= 0)
		{
			g_RoundStats[attacker].siClassDamage[siIdx] += damage;
		}

		char weapon[32];
		event.GetString("weapon", weapon, sizeof(weapon));
		if (weapon[0] == '\0')
		{
			ZMR_GetActiveSurvivorWeaponName(attacker, weapon, sizeof(weapon));
		}

		if (ZMR_IsMeleeWeapon(weapon) && hurtClass != L4D2ZombieClass_Tank)
		{
			g_RoundStats[attacker].meleeSiDamage += damage;
		}
	}
	else if (ZMR_IsSurvivor(victim) && victim != attacker)
	{
		g_RoundStats[attacker].damageDealtFF += damage;
	}
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue)
	{
		return;
	}

	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	if (g_cvDebugEvents.BoolValue)
	{
		ZMR_LogDeath(victim, attacker);
	}

	// Tank death: always finalize attribution (even after freeze). Chat is deferred and
	// cancelled if the authoritative end-report sequence has started / is starting.
	if (victim > 0 && victim <= MaxClients && IsClientInGame(victim)
		&& L4D_GetClientTeam(victim) == L4DTeam_Infected
		&& L4D2_GetPlayerZombieClass(victim) == L4D2ZombieClass_Tank)
	{
		ZMR_CloseTankInstanceOnDeath(victim, attacker);

		if (g_cvDebugTraceChat.BoolValue)
		{
			char shortMsg[40];
			Format(shortMsg, sizeof(shortMsg), "tk_dead #%d", g_iTanksSpawnedThisRound);
			ZMR_LogTraceFile(true, "tank_death #%d victim=%d attacker=%d",
				g_iTanksSpawnedThisRound, victim, attacker);
			ZMR_TraceChat(true, shortMsg);
		}
	}

	if (g_bRoundStatsFrozen)
	{
		return;
	}

	if (victim > 0 && victim <= MaxClients && IsClientInGame(victim))
	{
		if (ZMR_IsSurvivor(victim))
		{
			ZMR_EnsureSteamId(victim);
			g_RoundStats[victim].deathCount++;
		}

		if (L4D_GetClientTeam(victim) == L4DTeam_Infected)
		{
			L4D2ZombieClassType zclass = L4D2_GetPlayerZombieClass(victim);
			if (zclass == L4D2ZombieClass_Hunter)
			{
				if (g_bHunterLunging[victim]
					&& attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker)
					&& ZMR_IsSurvivor(attacker))
				{
					ZMR_EnsureSteamId(attacker);
					g_RoundStats[attacker].defenseSkeet++;
				}

				g_bHunterLunging[victim] = false;
				g_iLastShoveAttackerOnHunter[victim] = 0;
			}
		}
	}

	if (attacker <= 0 || attacker > MaxClients || !IsClientInGame(attacker))
	{
		return;
	}

	if (!ZMR_IsSurvivor(attacker))
	{
		return;
	}

	ZMR_EnsureSteamId(attacker);

	if (!ZMR_IsInfectedPlayer(victim))
	{
		return;
	}

	L4D2ZombieClassType zclass = L4D2_GetPlayerZombieClass(victim);
	if (zclass == L4D2ZombieClass_Tank)
	{
		g_RoundStats[attacker].tankKills++;
	}
	else if (ZMR_IsSpecialInfectedClass(zclass))
	{
		g_RoundStats[attacker].siKills++;

		int siIdx = ZMR_SiClassToIndex(zclass);
		if (siIdx >= 0)
		{
			g_RoundStats[attacker].siClassKills[siIdx]++;
		}
	}
}

public void Event_InfectedHurt(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (attacker <= 0 || attacker > MaxClients || !IsClientInGame(attacker))
	{
		return;
	}

	if (!ZMR_IsSurvivor(attacker))
	{
		return;
	}

	int amount = event.GetInt("amount");
	if (amount <= 0)
	{
		return;
	}

	ZMR_EnsureSteamId(attacker);
	g_RoundStats[attacker].commonDamageDealt += amount;

	if (event.GetInt("hitgroup") == ZMR_HITGROUP_HEAD)
	{
		g_RoundStats[attacker].commonHeadshotDamage += amount;
	}

	char weapon[32];
	event.GetString("weapon", weapon, sizeof(weapon));
	if (weapon[0] == '\0')
	{
		ZMR_GetActiveSurvivorWeaponName(attacker, weapon, sizeof(weapon));
	}

	if (ZMR_IsMeleeWeapon(weapon))
	{
		g_RoundStats[attacker].meleeCommonDamage += amount;
	}
}

public void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue)
	{
		return;
	}

	bool boss = event.GetBool("boss");

	if (g_bRoundStatsFrozen)
	{
		if (!boss)
		{
			g_iCommonSkippedFrozen++;
		}

		return;
	}

	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (attacker <= 0 || attacker > MaxClients || !IsClientInGame(attacker))
	{
		if (!boss)
		{
			g_iCommonSkippedNoAttacker++;
		}

		return;
	}

	if (!ZMR_IsSurvivor(attacker))
	{
		if (!boss)
		{
			g_iCommonSkippedNotSurvivor++;
		}

		return;
	}

	ZMR_EnsureSteamId(attacker);

	if (event.GetBool("boss"))
	{
		// Witch NPC (SI player bots use player_death).
		if (ZMR_IsSurvivalGameMode())
		{
			return;
		}

	g_RoundStats[attacker].siKills++;

		int witchIdx = ZMR_SiClassToIndex(L4D2ZombieClass_Witch);
		if (witchIdx >= 0)
		{
			g_RoundStats[attacker].siClassKills[witchIdx]++;
		}

		if (g_cvDebugEvents.BoolValue)
		{
			LogMessage("[zf_mr] infected_death att=%d boss=1 headshot=%d",
				attacker, event.GetBool("headshot") ? 1 : 0);
		}

		return;
	}

	g_RoundStats[attacker].commonKills++;

	if (event.GetBool("headshot"))
	{
		g_RoundStats[attacker].commonHeadshotKills++;
	}

	if (g_cvDebugEvents.BoolValue)
	{
		LogMessage("[zf_mr] infected_death att=%d common=1 headshot=%d",
			attacker, event.GetBool("headshot") ? 1 : 0);
	}
}

int ZMR_ClientFromEventUserField(Event event, const char[] key)
{
	return GetClientOfUserId(event.GetInt(key));
}

void ZMR_RecordGrabOnSurvivor(int victim, int grabField)
{
	if (victim <= 0 || victim > MaxClients || !IsClientInGame(victim) || !ZMR_IsSurvivor(victim))
	{
		return;
	}

	ZMR_EnsureSteamId(victim);

	switch (grabField)
	{
		case 0:
		{
			g_RoundStats[victim].grabSmoker++;
			return;
		}
		case 1:
		{
			g_RoundStats[victim].grabJockey++;
			return;
		}
		case 2:
		{
			g_RoundStats[victim].grabHunter++;
			return;
		}
		case 3:
		{
			g_RoundStats[victim].grabCharger++;
			return;
		}
		case 4:
		{
			g_RoundStats[victim].grabBoomer++;
		}
	}
}

public void Event_HealSuccess(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int healer = ZMR_ClientFromEventUserField(event, "userid");
	int healed = ZMR_ClientFromEventUserField(event, "subject");

	if (healer <= 0 || healed <= 0 || !ZMR_IsSurvivor(healer) || !ZMR_IsSurvivor(healed))
	{
		return;
	}

	ZMR_EnsureSteamId(healer);
	ZMR_EnsureSteamId(healed);

	if (healer == healed)
	{
		g_RoundStats[healer].medkitSelf++;
	}
	else
	{
		g_RoundStats[healer].medkitOther++;
		g_RoundStats[healed].healReceivedFrom[healer]++;
	}
}

public void Event_PillsUsed(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int client = ZMR_ClientFromEventUserField(event, "userid");
	if (client <= 0 || !ZMR_IsSurvivor(client))
	{
		return;
	}

	ZMR_EnsureSteamId(client);
	g_RoundStats[client].pillsUsed++;
}

public void Event_AdrenalineUsed(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int client = ZMR_ClientFromEventUserField(event, "userid");
	if (client <= 0 || !ZMR_IsSurvivor(client))
	{
		return;
	}

	ZMR_EnsureSteamId(client);
	g_RoundStats[client].adrenalineUsed++;
}

public void Event_DefibrillatorUsed(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int user = ZMR_ClientFromEventUserField(event, "userid");
	int target = ZMR_ClientFromEventUserField(event, "subject");

	if (user <= 0 || !ZMR_IsSurvivor(user))
	{
		return;
	}

	ZMR_EnsureSteamId(user);

	if (target > 0 && target != user && ZMR_IsSurvivor(target))
	{
		g_RoundStats[user].defibOther++;
	}
}

public void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int revived = ZMR_ClientFromEventUserField(event, "userid");
	int helper = ZMR_ClientFromEventUserField(event, "subject");

	if (revived <= 0 || helper <= 0 || !ZMR_IsSurvivor(revived) || !ZMR_IsSurvivor(helper))
	{
		return;
	}

	ZMR_EnsureSteamId(revived);
	ZMR_EnsureSteamId(helper);

	g_RoundStats[revived].reviveReceived++;
	g_RoundStats[helper].reviveGiven++;
	g_RoundStats[revived].reviveReceivedFrom[helper]++;
}

public void Event_PlayerIncapStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int victim = ZMR_ClientFromEventUserField(event, "userid");
	if (victim <= 0 || !ZMR_IsSurvivor(victim))
	{
		return;
	}

	ZMR_EnsureSteamId(victim);
	g_RoundStats[victim].incapCount++;
}

public void Event_TongueGrab(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int victim = ZMR_ClientFromEventUserField(event, "userid");
	ZMR_RecordGrabOnSurvivor(victim, 0);
}

public void Event_TonguePullStopped(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int rescuer = ZMR_ClientFromEventUserField(event, "attacker");
	int victim = ZMR_ClientFromEventUserField(event, "victim");

	if (victim <= 0)
	{
		victim = ZMR_ClientFromEventUserField(event, "userid");
	}

	if (rescuer <= 0 || rescuer == victim || !ZMR_IsSurvivor(rescuer))
	{
		return;
	}

	if (victim <= 0 || !ZMR_IsSurvivor(victim))
	{
		return;
	}

	ZMR_EnsureSteamId(rescuer);
	g_RoundStats[rescuer].defenseFreed++;
}

public void Event_JockeyRide(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int victim = ZMR_ClientFromEventUserField(event, "victim");
	if (victim <= 0)
	{
		victim = ZMR_ClientFromEventUserField(event, "userid");
	}

	ZMR_RecordGrabOnSurvivor(victim, 1);
}

public void Event_LungePounce(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int hunter = ZMR_ClientFromEventUserField(event, "userid");
	if (hunter > 0 && hunter <= MaxClients && IsClientInGame(hunter)
		&& ZMR_IsInfectedPlayer(hunter)
		&& L4D2_GetPlayerZombieClass(hunter) == L4D2ZombieClass_Hunter)
	{
		g_bHunterLunging[hunter] = true;
	}

	int victim = ZMR_ClientFromEventUserField(event, "victim");
	ZMR_RecordGrabOnSurvivor(victim, 2);
}

public void Event_LungeShove(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int hunter = ZMR_ClientFromEventUserField(event, "userid");
	if (hunter <= 0 || hunter > MaxClients)
	{
		return;
	}

	int rescuer = g_iLastShoveAttackerOnHunter[hunter];
	if (rescuer > 0 && rescuer <= MaxClients && IsClientInGame(rescuer) && ZMR_IsSurvivor(rescuer)
		&& (GetGameTime() - g_fLastShoveTimeOnHunter[hunter]) <= ZMR_HUNTER_SHOVE_CORRELATE_SEC)
	{
		ZMR_EnsureSteamId(rescuer);
		g_RoundStats[rescuer].defenseDeadstop++;
	}

	g_bHunterLunging[hunter] = false;
}

public void Event_ChargerCarryStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int victim = ZMR_ClientFromEventUserField(event, "userid");
	ZMR_RecordGrabOnSurvivor(victim, 3);
}

public void Event_ChargerPummelStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int victim = ZMR_ClientFromEventUserField(event, "userid");
	if (victim <= 0)
	{
		victim = ZMR_ClientFromEventUserField(event, "victim");
	}

	ZMR_RecordGrabOnSurvivor(victim, 3);
}

public void Event_PlayerNowIt(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int victim = ZMR_ClientFromEventUserField(event, "userid");
	ZMR_RecordGrabOnSurvivor(victim, 4);
}

void ZMR_CreditDefenseFreed(int rescuer, int victim)
{
	if (rescuer <= 0 || rescuer == victim || !ZMR_IsSurvivor(rescuer))
	{
		return;
	}

	if (victim <= 0 || !ZMR_IsSurvivor(victim))
	{
		return;
	}

	ZMR_EnsureSteamId(rescuer);
	g_RoundStats[rescuer].defenseFreed++;
}

public void Event_JockeyRideEnd(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int rescuer = ZMR_ClientFromEventUserField(event, "attacker");
	int victim = ZMR_ClientFromEventUserField(event, "victim");
	ZMR_CreditDefenseFreed(rescuer, victim);
}

public void Event_PounceStopped(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int rescuer = ZMR_ClientFromEventUserField(event, "attacker");
	int victim = ZMR_ClientFromEventUserField(event, "victim");

	if (victim <= 0)
	{
		victim = ZMR_ClientFromEventUserField(event, "userid");
	}

	ZMR_CreditDefenseFreed(rescuer, victim);
}

public void Event_ChargerCarryEnd(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int rescuer = ZMR_ClientFromEventUserField(event, "attacker");
	int victim = ZMR_ClientFromEventUserField(event, "victim");

	if (victim <= 0)
	{
		victim = ZMR_ClientFromEventUserField(event, "userid");
	}

	ZMR_CreditDefenseFreed(rescuer, victim);
}

public void Event_PlayerShoved(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return;
	}

	int victim = ZMR_ClientFromEventUserField(event, "userid");
	int attacker = ZMR_ClientFromEventUserField(event, "attacker");

	if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker) && ZMR_IsSurvivor(attacker))
	{
		ZMR_EnsureSteamId(attacker);
		g_RoundStats[attacker].defenseShoves++;
	}

	if (victim > 0 && victim <= MaxClients && IsClientInGame(victim)
		&& ZMR_IsInfectedPlayer(victim)
		&& L4D2_GetPlayerZombieClass(victim) == L4D2ZombieClass_Hunter
		&& attacker > 0)
	{
		g_iLastShoveAttackerOnHunter[victim] = attacker;
		g_fLastShoveTimeOnHunter[victim] = GetGameTime();
	}
}

public Action Cmd_MrVersion(int client, int args)
{
	ReplyToCommand(client, "[zf_mr] match-report version %s", PLUGIN_VERSION);
	return Plugin_Handled;
}

public Action Cmd_MrChatGlyphs(int client, int args)
{
	if (client <= 0 || !ZMR_IsHumanInGame(client))
	{
		ReplyToCommand(client, "[zf_mr] sm_mr_chatglyphs: run from a connected human client.");
		return Plugin_Handled;
	}

	PrintToChat(client, "[zf_mr] chatglyphs BETA — screenshot each block (20 glyphs + |)");
	ZMR_PrintChatGlyphRow(client, "i", "i");
	ZMR_PrintChatGlyphRow(client, "l", "l");
	ZMR_PrintChatGlyphRow(client, "t", "t");
	ZMR_PrintChatGlyphRow(client, "f", "f");
	ZMR_PrintChatGlyphRow(client, "r", "r");
	ZMR_PrintChatGlyphRow(client, "a", "a");
	ZMR_PrintChatGlyphRow(client, "m", "m");
	ZMR_PrintChatGlyphRow(client, "w", "w");
	ZMR_PrintChatGlyphRow(client, "A", "A");
	ZMR_PrintChatGlyphRow(client, "M", "M");
	ZMR_PrintChatGlyphRow(client, "W", "W");
	ZMR_PrintChatGlyphRow(client, "0", "0");
	ZMR_PrintChatGlyphRow(client, "1", "1");
	ZMR_PrintChatGlyphRow(client, "8", "8");
	ZMR_PrintChatGlyphRow(client, ".", ".");
	ZMR_PrintChatGlyphRow(client, ":", ":");
	ZMR_PrintChatGlyphRow(client, "%", "%");
	ZMR_PrintChatGlyphRow(client, "|", "|");
	ZMR_PrintChatGlyphRow(client, "-", "-");
	ZMR_PrintChatGlyphRow(client, "#", "#");
	ZMR_PrintChatGlyphRow(client, "sp", " ");
	ZMR_PrintChatGlyphRow(client, "dot", "\xC2\xB7");
	PrintToChat(client, "[zf_mr] chatglyphs done — measure glyph run vs |");
	return Plugin_Handled;
}

void ZMR_PrintChatGlyphRow(int client, const char[] tag, const char[] glyph)
{
	char run[96];
	run[0] = '\0';
	for (int i = 0; i < 20; i++)
	{
		StrCat(run, sizeof(run), glyph);
	}

	PrintToChat(client, "%s %s|", tag, run);
}

public Action Cmd_MrDump(int client, int args)
{
	if (!g_cvEnabled.BoolValue)
	{
		ReplyToCommand(client, "[zf_mr] Collection disabled (zf_mr_enabled=0).");
		return Plugin_Handled;
	}

	int recipient = client;
	if (recipient == 0)
	{
		recipient = 1;
	}

	ZMR_DumpToChat(recipient);
	ZMR_DumpMetricsToLog("sm_mr_dump");
	return Plugin_Handled;
}

void ZMR_ResetRound(bool resetDeliveryFlags = true)
{
	g_bRoundStatsFrozen = false;
	g_iTanksSpawnedThisRound = 0;
	for (int t = 0; t < g_iTankInstanceCount; t++)
	{
		ZMR_ResetTankInstanceStats(t);
	}

	g_iTankInstanceCount = 0;
	g_iRoundTankFireEffective = 0;
	g_iRoundTankEnvEffective = 0;
	g_iCommonSkippedNoAttacker = 0;
	g_iCommonSkippedNotSurvivor = 0;
	g_iCommonSkippedFrozen = 0;

	if (resetDeliveryFlags)
	{
		g_bAutoRoundEndChatDumpSentThisRound = false;
		g_bEndChatSequenceActive = false;
		ZMR_CancelDeferredRoundEndChatDump();
		ZMR_CancelPendingTankDeathChats();
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		g_RoundStats[i].steamId[0] = '\0';
		g_RoundStats[i].damageDealtInfected = 0;
		g_RoundStats[i].damageDealtFF = 0;
		g_RoundStats[i].damageTaken = 0;
		g_RoundStats[i].damageTakenFromInfected = 0;
		g_RoundStats[i].damageTakenFromFall = 0;
		g_RoundStats[i].damageTakenFromWorld = 0;

		for (int s = 1; s <= MaxClients; s++)
		{
			g_RoundStats[i].damageTakenFromSurvivor[s] = 0;
			g_RoundStats[i].healReceivedFrom[s] = 0;
			g_RoundStats[i].reviveReceivedFrom[s] = 0;
		}

		g_RoundStats[i].siKills = 0;
		g_RoundStats[i].tankKills = 0;
		g_RoundStats[i].tankDamageEffective = 0;

		for (int c = 0; c < ZMR_SI_CLASS_COUNT; c++)
		{
			g_RoundStats[i].siClassDamage[c] = 0;
			g_RoundStats[i].siClassKills[c] = 0;
		}

		g_RoundStats[i].commonKills = 0;
		g_RoundStats[i].commonHeadshotKills = 0;
		g_RoundStats[i].commonDamageDealt = 0;
		g_RoundStats[i].commonHeadshotDamage = 0;
		g_RoundStats[i].medkitSelf = 0;
		g_RoundStats[i].medkitOther = 0;
		g_RoundStats[i].pillsUsed = 0;
		g_RoundStats[i].adrenalineUsed = 0;
		g_RoundStats[i].defibOther = 0;
		g_RoundStats[i].reviveGiven = 0;
		g_RoundStats[i].reviveReceived = 0;
		g_RoundStats[i].incapCount = 0;
		g_RoundStats[i].deathCount = 0;
		g_RoundStats[i].grabSmoker = 0;
		g_RoundStats[i].grabJockey = 0;
		g_RoundStats[i].grabHunter = 0;
		g_RoundStats[i].grabCharger = 0;
		g_RoundStats[i].grabBoomer = 0;
		g_RoundStats[i].defenseFreed = 0;
		g_RoundStats[i].defenseShoves = 0;
		g_RoundStats[i].defenseDeadstop = 0;
		g_RoundStats[i].defenseSkeet = 0;
		g_RoundStats[i].meleeSiDamage = 0;
		g_RoundStats[i].meleeCommonDamage = 0;

		g_bHunterLunging[i] = false;
		g_iLastShoveAttackerOnHunter[i] = 0;
		g_fLastShoveTimeOnHunter[i] = 0.0;

		if (IsClientInGame(i))
		{
			ZMR_EnsureSteamId(i);
		}
	}
}

void ZMR_EnsureSteamId(int client)
{
	if (g_RoundStats[client].steamId[0] != '\0')
	{
		return;
	}

	if (!GetClientAuthId(client, AuthId_Steam2, g_RoundStats[client].steamId, MAX_AUTHID_LENGTH))
	{
		strcopy(g_RoundStats[client].steamId, sizeof(ZMR_RoundPlayerStats::steamId), "UNKNOWN");
	}
}

void ZMR_CancelDeferredRoundEndChatDump()
{
	if (g_hRoundEndChatDumpTimer != null)
	{
		KillTimer(g_hRoundEndChatDumpTimer);
		g_hRoundEndChatDumpTimer = null;
	}
}

void ZMR_CancelPendingTankDeathChats()
{
	for (int i = 0; i < ZMR_MAX_TANK_TRACKING_SLOTS; i++)
	{
		if (g_hPendingTankDeathChatTimer[i] != null)
		{
			KillTimer(g_hPendingTankDeathChatTimer[i]);
			g_hPendingTankDeathChatTimer[i] = null;
		}
	}
}

bool ZMR_ShouldSuppressTankDeathChat()
{
	return g_bEndChatSequenceActive
		|| g_bRoundStatsFrozen
		|| g_bAutoRoundEndChatDumpSentThisRound;
}

void ZMR_ScheduleDeferredRoundEndChatDump()
{
	if (g_bAutoRoundEndChatDumpSentThisRound)
	{
		if (g_cvDebugBoundaries.BoolValue)
		{
			ZMR_LogBoundaryEvent("round_end_deferred", "chat_dump_skipped_already_sent",
				-1, -1, "", -1.0);
		}

		if (g_cvDebugEvents.BoolValue)
		{
			LogMessage("[zf_mr] round_end chat dump skipped (already sent this round)");
		}

		return;
	}

	ZMR_CancelDeferredRoundEndChatDump();

	bool deferChat = g_cvDebugRoundEnd.BoolValue
		|| (g_cvReportChat != null && g_cvReportChat.BoolValue)
		|| (g_cvReportConsole != null && g_cvReportConsole.BoolValue);
	if (deferChat)
	{
		g_bEndChatSequenceActive = true;
	}

	float deferSec = ZMR_UseSurvivalRoundStartBoundary()
		? ZMR_SURVIVAL_END_DECIDE_SEC : ZMR_ROUND_END_DUMP_DEFER_SEC;
	g_hRoundEndChatDumpTimer = CreateTimer(deferSec,
		Timer_DeferredRoundEndChatDump, 0, TIMER_FLAG_NO_MAPCHANGE);

	if (g_cvDebugTraceChat.BoolValue)
	{
		ZMR_LogTraceFile(false, "defer_timer scheduled %.1fs", deferSec);
		ZMR_TraceChat(false, "defer sched");
	}
}

void ZMR_DumpToChatAllSurvivors()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!ZMR_IsSurvivor(client))
		{
			continue;
		}

		ZMR_DumpToChat(client);
	}
}

public Action Timer_DeferredRoundEndChatDump(Handle timer, any data)
{
	g_hRoundEndChatDumpTimer = null;

	if (g_cvDebugTraceChat.BoolValue)
	{
		ZMR_LogTraceFile(false, "defer_timer fired");
		ZMR_TraceChat(false, "defer fired");
	}

	if (!g_cvEnabled.BoolValue)
	{
		g_bEndChatSequenceActive = false;
		return Plugin_Stop;
	}

	bool survivalBoundary = ZMR_UseSurvivalRoundStartBoundary();
	bool doChatDump = g_cvDebugRoundEnd.BoolValue;
	bool doLogDump = g_cvDebugAutoDump != null && g_cvDebugAutoDump.BoolValue;
	bool doReportMotd = g_cvReportOpenOnRoundEnd != null && g_cvReportOpenOnRoundEnd.BoolValue
		&& ZMR_ReportUrlConfigured();
	bool doEndReport = (g_cvReportChat != null && g_cvReportChat.BoolValue)
		|| (g_cvReportConsole != null && g_cvReportConsole.BoolValue);

	if (!doChatDump && !doLogDump && !survivalBoundary && !doReportMotd && !doEndReport)
	{
		g_bEndChatSequenceActive = false;
		return Plugin_Stop;
	}

	if (!g_bAutoRoundEndChatDumpSentThisRound)
	{
		// One number per finished match, taken here so it marks only the authoritative dump.
		int matchId = ZMR_Recap_NewMatchId();

		if (doLogDump)
		{
			ZMR_DumpMetricsToLog("round_end", matchId);
		}

		if (doChatDump)
		{
			ZMR_DumpToChatAllSurvivors();
		}

		if (doEndReport)
		{
			g_iEndReportStamp++;
			g_bDeferSurvivalClearAfterEndReport = survivalBoundary;
			bool wantConsole = g_cvReportConsole != null && g_cvReportConsole.BoolValue;
			bool wantChat = g_cvReportChat != null && g_cvReportChat.BoolValue;
			if (wantChat)
			{
				LogMessage("[zf_mr] end_report stamp=%d chat in %.2fs then console +%.2fs plugin=%s defer_clear=%d",
					g_iEndReportStamp, ZMR_END_REPORT_CHAT_DELAY_SEC,
					wantConsole ? ZMR_END_REPORT_CONSOLE_AFTER_CHAT_SEC : 0.0, PLUGIN_VERSION,
					g_bDeferSurvivalClearAfterEndReport ? 1 : 0);
				// Chat first — console only after BroadcastChat returns (later timer).
				CreateTimer(ZMR_END_REPORT_CHAT_DELAY_SEC, Timer_DelayedEndReportChat,
					g_iEndReportStamp, TIMER_FLAG_NO_MAPCHANGE);
			}
			else
			{
				LogMessage("[zf_mr] end_report stamp=%d console-only in %.2fs plugin=%s defer_clear=%d",
					g_iEndReportStamp, ZMR_END_REPORT_CHAT_DELAY_SEC, PLUGIN_VERSION,
					g_bDeferSurvivalClearAfterEndReport ? 1 : 0);
				CreateTimer(ZMR_END_REPORT_CHAT_DELAY_SEC, Timer_DelayedEndReportConsole,
					g_iEndReportStamp, TIMER_FLAG_NO_MAPCHANGE);
			}
		}
		else
		{
			g_bEndChatSequenceActive = false;
			// No chat/console report to wait for.
			ZMR_Recap_StartWatch();
		}

		if (doLogDump || doChatDump || doReportMotd || doEndReport)
		{
			g_bAutoRoundEndChatDumpSentThisRound = true;
		}
	}

	if (survivalBoundary && !g_bDeferSurvivalClearAfterEndReport)
	{
		if (g_cvDebugBoundaries.BoolValue)
		{
			ZMR_LogBoundaryEvent("round_end_deferred", "clear_stats_next_survival_attempt",
				-1, -1, "", -1.0);
		}

		if (g_cvDebugEvents.BoolValue)
		{
			LogMessage("[zf_mr] round_end deferred — clearing stats for next Survival attempt");
		}

		ZMR_ResetRoundWithTrace("round_end_deferred", false);
	}

	if (!doEndReport)
	{
		g_bEndChatSequenceActive = false;
	}

	return Plugin_Stop;
}

public Action Timer_DelayedEndReportChat(Handle timer, any stamp)
{
	if (!g_cvEnabled.BoolValue)
	{
		g_bEndChatSequenceActive = false;
		return Plugin_Stop;
	}

	LogMessage("[zf_mr] end_report stamp=%d delivering chat (console follows)", stamp);
	ZMR_EndReport_BroadcastChat(stamp);

	bool wantConsole = g_cvReportConsole != null && g_cvReportConsole.BoolValue;
	if (wantConsole)
	{
		CreateTimer(ZMR_END_REPORT_CONSOLE_AFTER_CHAT_SEC, Timer_DelayedEndReportConsole,
			stamp, TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		ZMR_EndReport_FinishDelivery();
	}

	return Plugin_Stop;
}

public Action Timer_DelayedEndReportConsole(Handle timer, any stamp)
{
	if (!g_cvEnabled.BoolValue)
	{
		g_bEndChatSequenceActive = false;
		return Plugin_Stop;
	}

	LogMessage("[zf_mr] end_report stamp=%d delivering console", stamp);
	ZMR_EndReport_BroadcastConsole(stamp);
	ZMR_EndReport_FinishDelivery();
	return Plugin_Stop;
}

void ZMR_EndReport_FinishDelivery()
{
	int credited = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client))
		{
			continue;
		}

		credited += g_RoundStats[client].commonKills;
	}

	LogMessage("[zf_mr] common_gap credited=%d skipped_no_att=%d skipped_not_surv=%d skipped_frozen=%d",
		credited, g_iCommonSkippedNoAttacker, g_iCommonSkippedNotSurvivor, g_iCommonSkippedFrozen);

	if (g_bDeferSurvivalClearAfterEndReport)
	{
		g_bDeferSurvivalClearAfterEndReport = false;
		if (g_cvDebugEvents.BoolValue)
		{
			LogMessage("[zf_mr] round_end deferred — clearing stats after end report");
		}

		ZMR_ResetRoundWithTrace("round_end_deferred_after_end_report", false);
	}

	ZMR_Recap_StartWatch();

	// Keep g_bEndChatSequenceActive until the next round reset so a late wipe
	// tank_death cannot print a mini-report after the final [ZF]/console block.
}

bool ZMR_UseSurvivalRoundStartBoundary()
{
	if (!g_cvResetOnSurvivalStart.BoolValue)
	{
		return false;
	}

	return ZMR_IsSurvivalGameMode();
}

bool ZMR_IsSurvivalGameMode()
{
	ConVar cvMode = FindConVar("mp_gamemode");
	if (cvMode == null)
	{
		return false;
	}

	char mode[32];
	cvMode.GetString(mode, sizeof(mode));
	return StrContains(mode, "survival", false) != -1;
}

void ZMR_GetGameModeSnippet(char[] mode, int modeLen)
{
	mode[0] = '\0';
	ConVar cvMode = FindConVar("mp_gamemode");
	if (cvMode != null)
	{
		cvMode.GetString(mode, modeLen);
	}

	if (mode[0] == '\0')
	{
		strcopy(mode, modeLen, "?");
	}
}

void ZMR_LogBoundaryEvent(const char[] eventName, const char[] action, int winner, int reason,
	const char[] msg, float endTime)
{
	char mode[32];
	ZMR_GetGameModeSnippet(mode, sizeof(mode));

	char line[384];
	if (winner >= 0 || reason >= 0)
	{
		if (endTime >= 0.0)
		{
			Format(line, sizeof(line),
				"event=%s action=%s mp_gamemode=%s winner=%d reason=%d time=%.2f msg=%s",
				eventName, action, mode, winner, reason, endTime, msg);
		}
		else
		{
			Format(line, sizeof(line),
				"event=%s action=%s mp_gamemode=%s winner=%d reason=%d msg=%s",
				eventName, action, mode, winner, reason, msg);
		}
	}
	else if (action[0] != '\0')
	{
		Format(line, sizeof(line), "event=%s action=%s mp_gamemode=%s", eventName, action, mode);
	}
	else
	{
		Format(line, sizeof(line), "event=%s mp_gamemode=%s", eventName, mode);
	}

	char ts[12];
	FormatTime(ts, sizeof(ts), "%H:%M:%S");

	LogMessage("[%s] [zf_mr] BOUNDARY %s", ts, line);

	if (g_cvDebugTraceChat == null || !g_cvDebugTraceChat.BoolValue)
	{
		ZMR_ChatBoundaryAllSurvivors(ts, line);
	}
}

void ZMR_ResetRoundWithTrace(const char[] reason, bool resetDeliveryFlags = true)
{
	if (g_cvDebugTraceChat != null && g_cvDebugTraceChat.BoolValue)
	{
		char shortMsg[40];
		Format(shortMsg, sizeof(shortMsg), "reset %s", reason);
		if (strlen(shortMsg) > 32)
		{
			shortMsg[32] = '\0';
		}

		ZMR_LogTraceFile(false, "reset_stats reason=%s", reason);
		ZMR_TraceChat(false, shortMsg);
	}

	ZMR_ResetRound(resetDeliveryFlags);
}

void ZMR_FormatRoundStartTraceShort(const char[] action, char[] dest, int destLen)
{
	if (StrEqual(action, "reset_stats"))
	{
		strcopy(dest, destLen, "rs reset");
	}
	else if (StrEqual(action, "defer_reset_round_end_pending"))
	{
		strcopy(dest, destLen, "rs defer");
	}
	else if (StrEqual(action, "reset_post_wipe_restart"))
	{
		strcopy(dest, destLen, "rs wipe");
	}
	else if (StrEqual(action, "skip_reset_wait_survival_round_start"))
	{
		strcopy(dest, destLen, "rs wait_surv");
	}
	else if (action[0] != '\0')
	{
		Format(dest, destLen, "rs %s", action);
	}
	else
	{
		strcopy(dest, destLen, "round_start");
	}
}

void ZMR_LogTraceFile(bool isServer, const char[] fmt, any ...)
{
	char detail[384];
	VFormat(detail, sizeof(detail), fmt, 3);
	LogMessage("[zf_mr] %s %s", isServer ? "S" : "P", detail);
}

void ZMR_TruncateToVisibleMax(char[] s, int maxlen, int maxVisible)
{
	#pragma unused maxlen
	int len = strlen(s);
	if (len == 0)
	{
		return;
	}

	int vis = 0;
	int cut = len;

	for (int i = 0; i < len; i++)
	{
		if (s[i] > 31)
		{
			vis++;
			if (vis > maxVisible)
			{
				cut = i;
				break;
			}
		}
	}

	if (cut < len)
	{
		s[cut] = '\0';
	}
}

void ZMR_TraceChat(bool isServer, const char[] shortMsg)
{
	if (g_cvDebugTraceChat == null || !g_cvDebugTraceChat.BoolValue)
	{
		return;
	}

	char ts[12];
	FormatTime(ts, sizeof(ts), "%H:%M:%S");

	char body[64];
	Format(body, sizeof(body), "%s %s", ts, shortMsg);
	ZMR_TruncateToVisibleMax(body, sizeof(body), ZMR_TRACE_VISIBLE_MAX);

	char line[96];
	Format(line, sizeof(line), "%s%s",
		isServer ? ZMR_TRACE_COLOR_SERVER : ZMR_TRACE_COLOR_PLUGIN, body);

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!ZMR_IsHumanInGame(client))
		{
			continue;
		}

		PrintToChat(client, "%s", line);
	}
}

void ZMR_ChatBoundaryAllSurvivors(const char[] ts, const char[] line)
{
	char chatLine[400];
	Format(chatLine, sizeof(chatLine), "[%s] %s BOUNDARY %s", ts, ZMR_CHAT_TAG, line);

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!ZMR_IsSurvivor(client))
		{
			continue;
		}

		PrintToChat(client, "%s", chatLine);
	}
}

void ZMR_TruncateNameForChat(const char[] src, char[] dest, int destLen, int maxChars)
{
	int slen = strlen(src);
	if (slen <= maxChars)
	{
		strcopy(dest, destLen, src);
		return;
	}

	if (maxChars >= 3)
	{
		for (int i = 0; i < maxChars - 2; i++)
		{
			dest[i] = src[i];
		}

		dest[maxChars - 2] = '.';
		dest[maxChars - 1] = '.';
		dest[maxChars] = '\0';
		return;
	}

	Format(dest, destLen, "%.*s", maxChars, src);
}

void ZMR_PrintPlainChat(int client, const char[] line)
{
	PrintToChat(client, "%s", line);
}

int ZMR_IntDigitCount(int value)
{
	if (value == 0)
	{
		return 1;
	}

	if (value < 0)
	{
		value = -value;
	}

	int digits = 0;
	while (value > 0)
	{
		digits++;
		value /= 10;
	}

	return digits;
}

int ZMR_MaxInt(int a, int b)
{
	return a > b ? a : b;
}

void ZMR_PadStringRight(const char[] src, char[] dest, int destLen, int totalWidth)
{
	strcopy(dest, destLen, src);
	int len = strlen(dest);

	while (len < totalWidth && len + 1 < destLen)
	{
		dest[len++] = ' ';
	}

	dest[len] = '\0';
}

// Guessed Verdana-like widths for L4D2 chat (space = ZMR_CHAT_SPACE_PX). Dev-correct via sm_mr_chatglyphs.
int ZMR_ChatGlyphWidth(int codepoint)
{
	if (codepoint == ' ')
	{
		return ZMR_CHAT_SPACE_PX;
	}

	// Thin glyphs (Verdana Bold chat)
	if (codepoint == 'i' || codepoint == 'l' || codepoint == 'I'
		|| codepoint == '.' || codepoint == ',' || codepoint == ':'
		|| codepoint == ';' || codepoint == '!' || codepoint == '|'
		|| codepoint == '\'' || codepoint == '`')
	{
		return 3;
	}

	if (codepoint == 't' || codepoint == 'f' || codepoint == 'j'
		|| codepoint == '-')
	{
		return 4;
	}

	// 'r' is wider than t/f in Verdana Bold chat (Ellis vs Coach drift).
	if (codepoint == 'r' || codepoint == '*')
	{
		return 5;
	}

	if (codepoint == 'm' || codepoint == 'w' || codepoint == '%')
	{
		return 11;
	}

	if (codepoint == 'M' || codepoint == 'W' || codepoint == '@')
	{
		return 13;
	}

	// Middle dot U+00B7
	if (codepoint == 0x00B7)
	{
		return 5;
	}

	if (codepoint >= '0' && codepoint <= '9')
	{
		return 8;
	}

	// Wide capitals pulled from tank-death screenshot (Rochelle / Coach / Ellis / Fire).
	if (codepoint == 'B' || codepoint == 'C' || codepoint == 'D' || codepoint == 'E'
		|| codepoint == 'F' || codepoint == 'G' || codepoint == 'H' || codepoint == 'N'
		|| codepoint == 'O' || codepoint == 'Q' || codepoint == 'R' || codepoint == 'U')
	{
		return 9;
	}

	if (codepoint >= 'A' && codepoint <= 'Z')
	{
		return 8;
	}

	// Typical lowercase slightly wider than prior 7 — short names were under-padded vs Rochelle.
	if (codepoint >= 'a' && codepoint <= 'z')
	{
		return 8;
	}

	if (codepoint == '#' || codepoint == '+' || codepoint == '='
		|| codepoint == '?' || codepoint == '/' || codepoint == '\\'
		|| codepoint == '(' || codepoint == ')' || codepoint == '['
		|| codepoint == ']' || codepoint == '{' || codepoint == '}')
	{
		return 8;
	}

	// Unknown / wide UTF-8 fallback
	return 8;
}

// Advances index over one UTF-8 codepoint; returns width in px.
int ZMR_ChatConsumeGlyphWidth(const char[] s, int &index)
{
	int b = s[index] & 0xFF;
	if (b == 0)
	{
		return 0;
	}

	if (b < 0x80)
	{
		index++;
		return ZMR_ChatGlyphWidth(b);
	}

	int cp = 0;
	int need = 0;
	if ((b & 0xE0) == 0xC0)
	{
		cp = b & 0x1F;
		need = 1;
	}
	else if ((b & 0xF0) == 0xE0)
	{
		cp = b & 0x0F;
		need = 2;
	}
	else if ((b & 0xF8) == 0xF0)
	{
		cp = b & 0x07;
		need = 3;
	}
	else
	{
		index++;
		return 8;
	}

	index++;
	for (int n = 0; n < need; n++)
	{
		int c = s[index] & 0xFF;
		if (c == 0 || (c & 0xC0) != 0x80)
		{
			break;
		}

		cp = (cp << 6) | (c & 0x3F);
		index++;
	}

	return ZMR_ChatGlyphWidth(cp);
}

int ZMR_ChatStringWidth(const char[] s)
{
	int width = 0;
	int i = 0;
	while (s[i] != '\0')
	{
		width += ZMR_ChatConsumeGlyphWidth(s, i);
	}

	return width;
}

// Hard truncate to targetPx — no ellipsis dots.
void ZMR_ChatTruncateToWidth(const char[] src, char[] dest, int destLen, int targetPx)
{
	dest[0] = '\0';
	if (destLen <= 1 || targetPx <= 0)
	{
		return;
	}

	int width = 0;
	int srcIdx = 0;
	int destIdx = 0;

	while (src[srcIdx] != '\0' && destIdx + 1 < destLen)
	{
		int start = srcIdx;
		int glyphW = ZMR_ChatConsumeGlyphWidth(src, srcIdx);
		if (glyphW <= 0)
		{
			break;
		}

		if (width + glyphW > targetPx)
		{
			break;
		}

		for (int k = start; k < srcIdx && destIdx + 1 < destLen; k++)
		{
			dest[destIdx++] = src[k];
		}

		width += glyphW;
	}

	dest[destIdx] = '\0';
}

// Pad with normal spaces to targetPx. Never exceed target (no nearest-space overshoot).
void ZMR_ChatPadToWidth(const char[] src, char[] dest, int destLen, int targetPx)
{
	char trimmed[128];
	ZMR_ChatTruncateToWidth(src, trimmed, sizeof(trimmed), targetPx);
	strcopy(dest, destLen, trimmed);

	int width = ZMR_ChatStringWidth(dest);
	int len = strlen(dest);
	while (width + ZMR_CHAT_SPACE_PX <= targetPx && len + 1 < destLen)
	{
		dest[len++] = ' ';
		dest[len] = '\0';
		width += ZMR_CHAT_SPACE_PX;
	}
}

// Left-pad (spaces before text) so right edges of short fields line up (percent / damage).
void ZMR_ChatPadLeftToWidth(const char[] src, char[] dest, int destLen, int targetPx)
{
	char trimmed[128];
	ZMR_ChatTruncateToWidth(src, trimmed, sizeof(trimmed), targetPx);

	int width = ZMR_ChatStringWidth(trimmed);
	int spaces = 0;
	while (width + (spaces + 1) * ZMR_CHAT_SPACE_PX <= targetPx)
	{
		spaces++;
	}

	dest[0] = '\0';
	int len = 0;
	for (int i = 0; i < spaces && len + 1 < destLen; i++)
	{
		dest[len++] = ' ';
	}

	dest[len] = '\0';
	StrCat(dest, destLen, trimmed);
}

void ZMR_IntToPaddedString(int value, char[] dest, int destLen, int width)
{
	char num[16];
	IntToString(value, num, sizeof(num));
	int nlen = strlen(num);
	int pad = width - nlen;

	dest[0] = '\0';
	for (int i = 0; i < pad; i++)
	{
		StrCat(dest, destLen, " ");
	}

	StrCat(dest, destLen, num);
}

int ZMR_StatSegmentWidth(const char[] label, int numWidth)
{
	return strlen(label) + 1 + numWidth + ZMR_CHAT_STAT_TRAIL_SPACES;
}

void ZMR_FormatStatSegment(const char[] label, int value, int numWidth, char[] dest, int destLen)
{
	char num[16];
	char segment[32];
	int colW = ZMR_StatSegmentWidth(label, numWidth);

	ZMR_IntToPaddedString(value, num, sizeof(num), numWidth);
	Format(segment, sizeof(segment), "%s %s", label, num);
	ZMR_PadStringRight(segment, dest, destLen, colW);
}

// Integer math only — SourcePawn PrintToChat must not rely on %.1f in the final line.
int ZMR_EffectiveToPctTenths(int eff, int maxHp)
{
	if (maxHp <= 0 || eff <= 0)
	{
		return 0;
	}

	int pct10 = (eff * ZMR_TANK_CHAT_PCT_TOTAL_TENTHS + maxHp / 2) / maxHp;
	if (pct10 < 0)
	{
		pct10 = 0;
	}

	return pct10;
}

void ZMR_FormatPctTenths(int pct10, char[] dest, int destLen)
{
	if (pct10 < 0)
	{
		pct10 = 0;
	}

	int whole = pct10 / 10;
	int tenth = pct10 % 10;

	if (tenth == 0)
	{
		Format(dest, destLen, "%d%%", whole);
	}
	else
	{
		Format(dest, destLen, "%d.%d%%", whole, tenth);
	}
}

void ZMR_TankChatPushSurvivorRow(ZMR_TankChatRow[] rows, int &rowCount, const char[] label, int eff, int maxHp)
{
	if (rowCount >= ZMR_TANK_CHAT_MAX_ROWS)
	{
		return;
	}

	rows[rowCount].eff = eff;
	rows[rowCount].pct10 = ZMR_EffectiveToPctTenths(eff, maxHp);
	strcopy(rows[rowCount].label, sizeof(rows[rowCount].label), label);
	rowCount++;
}

void ZMR_TankChatTryPushRow(ZMR_TankChatRow[] rows, int &rowCount, const char[] label, int eff, int maxHp)
{
	if (rowCount >= ZMR_TANK_CHAT_MAX_ROWS || eff <= 0)
	{
		return;
	}

	if (ZMR_TankExtraRowOmitFromChat(eff, maxHp))
	{
		return;
	}

	rows[rowCount].eff = eff;
	rows[rowCount].pct10 = ZMR_EffectiveToPctTenths(eff, maxHp);
	strcopy(rows[rowCount].label, sizeof(rows[rowCount].label), label);
	rowCount++;
}

int ZMR_TankChatPredominantRowIndex(ZMR_TankChatRow[] rows, int rowCount)
{
	int predIdx = 0;
	int predEff = rows[0].eff;

	for (int i = 1; i < rowCount; i++)
	{
		if (rows[i].eff > predEff)
		{
			predEff = rows[i].eff;
			predIdx = i;
		}
	}

	return predIdx;
}

// Chat display only: omitted rows (e.g. env <=1%) leave a gap vs max_hp; roll gap + % rounding onto predominant row.
void ZMR_TankChatFinalizeDisplayRows(ZMR_TankChatRow[] rows, int rowCount, int maxHp)
{
	if (rowCount <= 0 || maxHp <= 0)
	{
		return;
	}

	int predIdx = ZMR_TankChatPredominantRowIndex(rows, rowCount);
	int sumEff = 0;

	for (int i = 0; i < rowCount; i++)
	{
		sumEff += rows[i].eff;
	}

	int gapHp = maxHp - sumEff;
	if (gapHp != 0)
	{
		rows[predIdx].eff += gapHp;

		if (rows[predIdx].eff < 0)
		{
			rows[predIdx].eff = 0;
		}
	}

	int sumPct10 = 0;

	for (int i = 0; i < rowCount; i++)
	{
		rows[i].pct10 = ZMR_EffectiveToPctTenths(rows[i].eff, maxHp);
		sumPct10 += rows[i].pct10;
	}

	int deltaPct10 = ZMR_TANK_CHAT_PCT_TOTAL_TENTHS - sumPct10;
	rows[predIdx].pct10 += deltaPct10;

	if (rows[predIdx].pct10 < 0)
	{
		rows[predIdx].pct10 = 0;
	}
}

int ZMR_EstimatePlayerLineWidth(int nameWidth, int wSI, int wFF, int wTk, int wKSI, int wKTk)
{
	// name | seg | seg | seg | seg | seg  (five " | " after name)
	return nameWidth + 3 + wSI + 3 + wFF + 3 + wTk + 3 + wKSI + 3 + wKTk;
}

int ZMR_FindOpenTankInstanceByClient(int tankClient)
{
	for (int i = 0; i < g_iTankInstanceCount; i++)
	{
		if (g_TankInstances[i].tankClient == tankClient && !g_TankInstances[i].closed)
		{
			return i;
		}
	}

	return -1;
}

int ZMR_ComputeTankEffectiveDamage(int tankClient, int dmgHealth, int spawnMaxHp)
{
	if (dmgHealth <= 0)
	{
		return 0;
	}

	int healthAfter = GetEntProp(tankClient, Prop_Send, "m_iHealth");
	if (healthAfter < 0)
	{
		healthAfter = 0;
	}

	int healthBefore = healthAfter + dmgHealth;
	if (healthBefore < 0)
	{
		healthBefore = 0;
	}

	if (spawnMaxHp > 0 && healthBefore > spawnMaxHp)
	{
		healthBefore = spawnMaxHp;
	}

	int effective = dmgHealth;
	if (effective > healthBefore)
	{
		effective = healthBefore;
	}

	return effective;
}

void ZMR_SanitizeNameForLog(const char[] src, char[] dest, int destLen)
{
	int outIdx = 0;
	for (int i = 0; src[i] != '\0' && outIdx < destLen - 1; i++)
	{
		int c = src[i];
		if (c == '\n' || c == '\r')
		{
			continue;
		}

		if (c == ',')
		{
			dest[outIdx++] = '_';
			continue;
		}

		dest[outIdx++] = c;
	}

	dest[outIdx] = '\0';
}

// Admin spawns (e.g. ALL4DEAD) may not fire L4D_OnSpawnTank_Post; register on first hurt/death.
bool ZMR_TryLazyRegisterTank(int tankClient)
{
	if (!g_cvEnabled.BoolValue || g_bRoundStatsFrozen)
	{
		return false;
	}

	if (tankClient <= 0 || tankClient > MaxClients || !IsClientInGame(tankClient))
	{
		return false;
	}

	if (!IsPlayerAlive(tankClient) || !ZMR_IsInfectedPlayer(tankClient))
	{
		return false;
	}

	if (L4D2_GetPlayerZombieClass(tankClient) != L4D2ZombieClass_Tank)
	{
		return false;
	}

	if (ZMR_FindOpenTankInstanceByClient(tankClient) >= 0)
	{
		return true;
	}

	g_iTanksSpawnedThisRound++;
	LogMessage("[zf_mr] tank lazy_register seq=%d client=%d (no L4D_OnSpawnTank_Post)",
		g_iTanksSpawnedThisRound, tankClient);
	ZMR_RegisterTankSpawn(tankClient);
	return ZMR_FindOpenTankInstanceByClient(tankClient) >= 0;
}

void ZMR_ResetTankInstanceStats(int idx)
{
	g_TankInstances[idx].spawnSeq = 0;
	g_TankInstances[idx].tankClient = 0;
	g_TankInstances[idx].maxHp = 0;
	g_TankInstances[idx].zTankHealthCvar = 0;
	g_TankInstances[idx].killerClient = 0;
	g_TankInstances[idx].totalEffective = 0;
	g_TankInstances[idx].damageRockEffective = 0;
	g_TankInstances[idx].damageRockRaw = 0;
	g_TankInstances[idx].damageMeleeEffective = 0;
	g_TankInstances[idx].damageMeleeRaw = 0;
	g_TankInstances[idx].damageFireEffective = 0;
	g_TankInstances[idx].damageFireRaw = 0;
	g_TankInstances[idx].damageEnvEffective = 0;
	g_TankInstances[idx].damageEnvRaw = 0;
	g_TankInstances[idx].damageSiCommonEffective = 0;
	g_TankInstances[idx].damageSiCommonRaw = 0;
	g_TankInstances[idx].damageSiTankEffective = 0;
	g_TankInstances[idx].damageSiTankRaw = 0;
	g_TankInstances[idx].damageOtherEffective = 0;
	g_TankInstances[idx].damageOtherRaw = 0;

	for (int c = 0; c < ZMR_SI_CLASS_COUNT; c++)
	{
		g_TankInstances[idx].damageSiClassEffective[c] = 0;
		g_TankInstances[idx].damageSiClassRaw[c] = 0;
	}

	g_TankInstances[idx].closed = false;

	for (int slot = 0; slot <= MaxClients; slot++)
	{
		g_TankInstances[idx].damageEffective[slot] = 0;
		g_TankInstances[idx].damageRaw[slot] = 0;
		g_TankInstances[idx].damageFireLitByEffective[slot] = 0;
		g_TankInstances[idx].damageFireLitByRaw[slot] = 0;
	}
}

// Returns slot index for a newly spawned alive tank, or -1 if too many slots in use.
int ZMR_AllocateTankInstanceSlot()
{
	for (int i = 0; i < g_iTankInstanceCount; i++)
	{
		if (g_TankInstances[i].spawnSeq == 0)
		{
			return i;
		}
	}

	if (g_iTankInstanceCount < ZMR_MAX_TANK_TRACKING_SLOTS)
	{
		int idx = g_iTankInstanceCount;
		g_iTankInstanceCount++;
		ZMR_ResetTankInstanceStats(idx);
		return idx;
	}

	return -1;
}

void ZMR_RegisterTankSpawn(int tankClient)
{
	int idx = ZMR_AllocateTankInstanceSlot();
	if (idx < 0)
	{
		LogMessage("[zf_mr] METRIC tank_tracking_overflow seq=%d client=%d (max %d alive)",
			g_iTanksSpawnedThisRound, tankClient, ZMR_MAX_TANK_TRACKING_SLOTS);
		return;
	}

	int maxHp = 0;
	if (tankClient > 0 && tankClient <= MaxClients && IsClientInGame(tankClient))
	{
		maxHp = GetEntProp(tankClient, Prop_Send, "m_iMaxHealth");
	}

	int zTankCvar = -1;
	if (g_hZTankHealthCvar != null)
	{
		zTankCvar = g_hZTankHealthCvar.IntValue;
	}

	g_TankInstances[idx].spawnSeq = g_iTanksSpawnedThisRound;
	g_TankInstances[idx].tankClient = tankClient;
	g_TankInstances[idx].maxHp = maxHp;
	g_TankInstances[idx].zTankHealthCvar = zTankCvar;
	g_TankInstances[idx].killerClient = 0;
	g_TankInstances[idx].closed = false;

	LogMessage("[zf_mr] METRIC tank #%d spawn client=%d max_hp=%d z_tank_health=%d",
		g_iTanksSpawnedThisRound, tankClient, maxHp, zTankCvar);
}

void ZMR_ApplyDevAllowPause()
{
	if (g_cvDevAllowPause == null || !g_cvDevAllowPause.BoolValue)
	{
		return;
	}

	ConVar cvPause = FindConVar("sv_pausable");
	if (cvPause != null)
	{
		cvPause.SetInt(1, true);
		LogMessage("[zf_mr] dev_allow_pause: sv_pausable set to 1 (host can pause to inspect logs)");
	}
}

void ZMR_SiClassBdKey(int classIndex, char[] dest, int destLen)
{
	switch (classIndex)
	{
		case 0: strcopy(dest, destLen, "si_smoker");
		case 1: strcopy(dest, destLen, "si_boomer");
		case 2: strcopy(dest, destLen, "si_hunter");
		case 3: strcopy(dest, destLen, "si_spitter");
		case 4: strcopy(dest, destLen, "si_jockey");
		case 5: strcopy(dest, destLen, "si_charger");
		case 6: strcopy(dest, destLen, "si_witch");
		default: strcopy(dest, destLen, "si_unknown");
	}
}

void ZMR_DamageCategoryLogLabel(int category, int siClassIndex, char[] dest, int destLen)
{
	switch (category)
	{
		case ZMR_DMG_CAT_TANK_ROCK: strcopy(dest, destLen, "tank_rock");
		case ZMR_DMG_CAT_TANK_MELEE: strcopy(dest, destLen, "tank_melee");
		case ZMR_DMG_CAT_FIRE: strcopy(dest, destLen, "fire");
		case ZMR_DMG_CAT_ENV: strcopy(dest, destLen, "env");
		case ZMR_DMG_CAT_SI_COMMON: strcopy(dest, destLen, "si_common");
		case ZMR_DMG_CAT_SI_TANK: strcopy(dest, destLen, "si_tank");
		case ZMR_DMG_CAT_SI_CLASS: ZMR_SiClassBdKey(siClassIndex, dest, destLen);
		case ZMR_DMG_CAT_OTHER: strcopy(dest, destLen, "other");
		default: strcopy(dest, destLen, "?");
	}
}

// Real burn only (molotov, gas-can flame, incendiary ticks). Explosions → survivor or env/other.
bool ZMR_IsTankFireWeapon(const char[] weapon)
{
	return StrEqual(weapon, "inferno", false) || StrEqual(weapon, "entityflame", false);
}

int ZMR_ClassifyTankDamage(int attackerClient, const char[] weapon, int &siClassIndex)
{
	siClassIndex = -1;

	if (attackerClient <= 0 || attackerClient > MaxClients || !IsClientInGame(attackerClient))
	{
		if (ZMR_IsTankFireWeapon(weapon))
		{
			return ZMR_DMG_CAT_FIRE;
		}

		return ZMR_DMG_CAT_ENV;
	}

	if (StrEqual(weapon, "tank_rock", false))
	{
		return ZMR_DMG_CAT_TANK_ROCK;
	}

	if (StrEqual(weapon, "tank_claw", false)
		&& ZMR_IsInfectedPlayer(attackerClient)
		&& L4D2_GetPlayerZombieClass(attackerClient) == L4D2ZombieClass_Tank)
	{
		return ZMR_DMG_CAT_TANK_MELEE;
	}

	if (ZMR_IsTankFireWeapon(weapon))
	{
		return ZMR_DMG_CAT_FIRE;
	}

	if (ZMR_IsSurvivor(attackerClient))
	{
		return ZMR_DMG_SURVIVOR_SLOT;
	}

	if (ZMR_IsInfectedPlayer(attackerClient))
	{
		L4D2ZombieClassType zclass = L4D2_GetPlayerZombieClass(attackerClient);
		int siIdx = ZMR_SiClassToIndex(zclass);

		if (siIdx >= 0)
		{
			siClassIndex = siIdx;
			return ZMR_DMG_CAT_SI_CLASS;
		}

		if (zclass == L4D2ZombieClass_Tank)
		{
			return ZMR_DMG_CAT_SI_TANK;
		}

		return ZMR_DMG_CAT_SI_COMMON;
	}

	return ZMR_DMG_CAT_OTHER;
}

void ZMR_GetActiveSurvivorWeaponName(int client, char[] weapon, int weaponLen)
{
	weapon[0] = '\0';

	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
	{
		return;
	}

	int ent = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (ent == -1)
	{
		return;
	}

	char cls[64];
	if (!GetEntityClassname(ent, cls, sizeof(cls)))
	{
		return;
	}

	if (StrContains(cls, "weapon_", false) == 0)
	{
		strcopy(weapon, weaponLen, cls[7]);
	}
	else
	{
		strcopy(weapon, weaponLen, cls);
	}
}

bool ZMR_IsMeleeWeapon(const char[] weapon)
{
	if (weapon[0] == '\0')
	{
		return false;
	}

	if (StrEqual(weapon, "melee", false)
		|| StrEqual(weapon, "crowbar", false)
		|| StrEqual(weapon, "cricket_bat", false)
		|| StrEqual(weapon, "frying_pan", false)
		|| StrEqual(weapon, "golfclub", false)
		|| StrEqual(weapon, "katana", false)
		|| StrEqual(weapon, "machete", false)
		|| StrEqual(weapon, "pitchfork", false)
		|| StrEqual(weapon, "shovel", false)
		|| StrEqual(weapon, "knife", false)
		|| StrEqual(weapon, "tonfa", false)
		|| StrEqual(weapon, "baseball_bat", false)
		|| StrEqual(weapon, "fireaxe", false)
		|| StrEqual(weapon, "chainsaw", false)
		|| StrEqual(weapon, "ub_chainsaw", false)
		|| StrEqual(weapon, "electric_guitar", false))
	{
		return true;
	}

	return false;
}

bool ZMR_IsSurvivorWeaponFinisherNoise(const char[] weapon)
{
	return StrEqual(weapon, "melee", false)
		|| StrEqual(weapon, "pistol", false)
		|| StrEqual(weapon, "rifle", false)
		|| StrEqual(weapon, "smg", false)
		|| StrEqual(weapon, "shotgun", false)
		|| StrEqual(weapon, "sniper", false)
		|| StrEqual(weapon, "hunting_rifle", false)
		|| StrEqual(weapon, "first_aid_kit", false);
}

bool ZMR_IsTankPhantomHurt(int attackerClient, int rawDamage, int spawnMaxHp, int hurtType, const char[] weapon)
{
	if (attackerClient <= 0 || attackerClient > MaxClients || !IsClientInGame(attackerClient))
	{
		return false;
	}

	if (!ZMR_IsSurvivor(attackerClient))
	{
		return false;
	}

	if (spawnMaxHp > 0 && rawDamage >= spawnMaxHp)
	{
		return true;
	}

	if (rawDamage >= 5000)
	{
		return true;
	}

	if (rawDamage == 1 && (hurtType & ZMR_DMGTYPE_SCRIPT) != 0 && ZMR_IsSurvivorWeaponFinisherNoise(weapon))
	{
		return true;
	}

	return false;
}

int ZMR_TankFireLitTopSlot(int idx)
{
	int bestSlot = 0;
	int bestEff = 0;

	for (int slot = 1; slot <= MaxClients; slot++)
	{
		if (g_TankInstances[idx].damageFireLitByEffective[slot] > bestEff)
		{
			bestEff = g_TankInstances[idx].damageFireLitByEffective[slot];
			bestSlot = slot;
		}
	}

	return bestSlot;
}

void ZMR_TankFinalizeAttribution(int idx)
{
	int maxHp = g_TankInstances[idx].maxHp;
	if (maxHp <= 0)
	{
		return;
	}

	int gap = maxHp - g_TankInstances[idx].totalEffective;
	if (gap <= 0)
	{
		return;
	}

	if (g_TankInstances[idx].damageFireEffective > 0)
	{
		g_TankInstances[idx].damageFireEffective += gap;

		int litSlot = ZMR_TankFireLitTopSlot(idx);
		if (litSlot > 0)
		{
			g_TankInstances[idx].damageFireLitByEffective[litSlot] += gap;
		}
	}
	else if (g_TankInstances[idx].damageEnvEffective > 0)
	{
		g_TankInstances[idx].damageEnvEffective += gap;
	}
	else if (g_TankInstances[idx].damageRockEffective > 0)
	{
		g_TankInstances[idx].damageRockEffective += gap;
	}
	else if (g_TankInstances[idx].damageMeleeEffective > 0)
	{
		g_TankInstances[idx].damageMeleeEffective += gap;
	}
	else
	{
		int topSlot = 0;
		int topEff = 0;

		for (int slot = 1; slot <= MaxClients; slot++)
		{
			if (g_TankInstances[idx].damageEffective[slot] > topEff)
			{
				topEff = g_TankInstances[idx].damageEffective[slot];
				topSlot = slot;
			}
		}

		if (topSlot > 0)
		{
			g_TankInstances[idx].damageEffective[topSlot] += gap;
		}
		else
		{
			g_TankInstances[idx].damageOtherEffective += gap;
		}
	}

	g_TankInstances[idx].totalEffective += gap;

	if (g_cvDebugEvents.BoolValue)
	{
		LogMessage("[zf_mr] tank #%d attrib_gap +%d (total_eff=%d max_hp=%d)",
			g_TankInstances[idx].spawnSeq,
			gap,
			g_TankInstances[idx].totalEffective,
			maxHp);
	}
}

void ZMR_AccumulateTankCategory(int idx, int category, int siClassIndex, int effectiveDamage, int rawDamage)
{
	switch (category)
	{
		case ZMR_DMG_CAT_TANK_ROCK:
		{
			g_TankInstances[idx].damageRockEffective += effectiveDamage;
			if (rawDamage != effectiveDamage)
			{
				g_TankInstances[idx].damageRockRaw += rawDamage;
			}
		}
		case ZMR_DMG_CAT_TANK_MELEE:
		{
			g_TankInstances[idx].damageMeleeEffective += effectiveDamage;
			if (rawDamage != effectiveDamage)
			{
				g_TankInstances[idx].damageMeleeRaw += rawDamage;
			}
		}
		case ZMR_DMG_CAT_FIRE:
		{
			g_TankInstances[idx].damageFireEffective += effectiveDamage;
			if (rawDamage != effectiveDamage)
			{
				g_TankInstances[idx].damageFireRaw += rawDamage;
			}
		}
		case ZMR_DMG_CAT_ENV:
		{
			g_TankInstances[idx].damageEnvEffective += effectiveDamage;
			if (rawDamage != effectiveDamage)
			{
				g_TankInstances[idx].damageEnvRaw += rawDamage;
			}
		}
		case ZMR_DMG_CAT_SI_COMMON:
		{
			g_TankInstances[idx].damageSiCommonEffective += effectiveDamage;
			if (rawDamage != effectiveDamage)
			{
				g_TankInstances[idx].damageSiCommonRaw += rawDamage;
			}
		}
		case ZMR_DMG_CAT_SI_TANK:
		{
			g_TankInstances[idx].damageSiTankEffective += effectiveDamage;
			if (rawDamage != effectiveDamage)
			{
				g_TankInstances[idx].damageSiTankRaw += rawDamage;
			}
		}
		case ZMR_DMG_CAT_SI_CLASS:
		{
			if (siClassIndex >= 0 && siClassIndex < ZMR_SI_CLASS_COUNT)
			{
				g_TankInstances[idx].damageSiClassEffective[siClassIndex] += effectiveDamage;
				if (rawDamage != effectiveDamage)
				{
					g_TankInstances[idx].damageSiClassRaw[siClassIndex] += rawDamage;
				}
			}
		}
		case ZMR_DMG_CAT_OTHER:
		{
			g_TankInstances[idx].damageOtherEffective += effectiveDamage;
			if (rawDamage != effectiveDamage)
			{
				g_TankInstances[idx].damageOtherRaw += rawDamage;
			}
		}
	}
}

void ZMR_RecordTankHurt(int tankClient, int attackerClient, int rawDamage, const char[] weapon, int hurtType)
{
	if (ZMR_FindOpenTankInstanceByClient(tankClient) < 0)
	{
		ZMR_TryLazyRegisterTank(tankClient);
	}

	int idx = ZMR_FindOpenTankInstanceByClient(tankClient);
	if (idx < 0 || g_TankInstances[idx].closed || !IsPlayerAlive(tankClient) || rawDamage <= 0)
	{
		return;
	}

	int maxHp = g_TankInstances[idx].maxHp;

	if (ZMR_IsTankPhantomHurt(attackerClient, rawDamage, maxHp, hurtType, weapon))
	{
		if (g_cvDebugEvents.BoolValue)
		{
			LogMessage("[zf_mr] tank #%d phantom_hurt skip att=%d dmg=%d type=%d weapon=%s",
				g_TankInstances[idx].spawnSeq,
				attackerClient,
				rawDamage,
				hurtType,
				weapon);
		}

		return;
	}

	int remaining = maxHp - g_TankInstances[idx].totalEffective;
	if (maxHp > 0 && remaining <= 0)
	{
		return;
	}

	int effectiveDamage = ZMR_ComputeTankEffectiveDamage(tankClient, rawDamage, maxHp);
	if (maxHp > 0 && effectiveDamage > remaining)
	{
		effectiveDamage = remaining;
	}

	if (effectiveDamage <= 0)
	{
		return;
	}

	int siClassIndex = -1;
	int category = ZMR_ClassifyTankDamage(attackerClient, weapon, siClassIndex);

	if (category == ZMR_DMG_SURVIVOR_SLOT)
	{
		g_TankInstances[idx].damageEffective[attackerClient] += effectiveDamage;
		g_RoundStats[attackerClient].tankDamageEffective += effectiveDamage;

		if (rawDamage != effectiveDamage)
		{
			g_TankInstances[idx].damageRaw[attackerClient] += rawDamage;
		}
	}
	else
	{
		ZMR_AccumulateTankCategory(idx, category, siClassIndex, effectiveDamage, rawDamage);

		if (category == ZMR_DMG_CAT_FIRE
			&& attackerClient > 0 && attackerClient <= MaxClients && IsClientInGame(attackerClient)
			&& ZMR_IsSurvivor(attackerClient))
		{
			g_TankInstances[idx].damageFireLitByEffective[attackerClient] += effectiveDamage;

			if (rawDamage != effectiveDamage)
			{
				g_TankInstances[idx].damageFireLitByRaw[attackerClient] += rawDamage;
			}
		}

		if (g_cvDebugEvents.BoolValue)
		{
			char catLabel[32];
			ZMR_DamageCategoryLogLabel(category, siClassIndex, catLabel, sizeof(catLabel));
			LogMessage("[zf_mr] TANK_SRC %s tank #%d client=%d eff=%d att_client=%d weapon=%s",
				catLabel,
				g_TankInstances[idx].spawnSeq,
				tankClient,
				effectiveDamage,
				attackerClient,
				weapon);
		}
	}

	g_TankInstances[idx].totalEffective += effectiveDamage;
}

bool ZMR_TankExtraRowOmitFromChat(int eff, int maxHp)
{
	if (maxHp <= 0)
	{
		return false;
	}

	float pct = (eff * 100.0) / float(maxHp);
	return pct <= ZMR_TANK_EXTRA_CHAT_OMIT_PCT;
}

bool ZMR_TankHasAnyCategoryDamage(int idx)
{
	if (g_TankInstances[idx].damageRockEffective > 0
		|| g_TankInstances[idx].damageMeleeEffective > 0
		|| g_TankInstances[idx].damageFireEffective > 0
		|| g_TankInstances[idx].damageEnvEffective > 0
		|| g_TankInstances[idx].damageSiCommonEffective > 0
		|| g_TankInstances[idx].damageSiTankEffective > 0
		|| g_TankInstances[idx].damageOtherEffective > 0)
	{
		return true;
	}

	for (int c = 0; c < ZMR_SI_CLASS_COUNT; c++)
	{
		if (g_TankInstances[idx].damageSiClassEffective[c] > 0)
		{
			return true;
		}
	}

	return false;
}

int ZMR_TankChatZombiesEffective(int idx)
{
	int sum = g_TankInstances[idx].damageMeleeEffective
		+ g_TankInstances[idx].damageEnvEffective
		+ g_TankInstances[idx].damageSiCommonEffective
		+ g_TankInstances[idx].damageSiTankEffective
		+ g_TankInstances[idx].damageOtherEffective;

	for (int c = 0; c < ZMR_SI_CLASS_COUNT; c++)
	{
		sum += g_TankInstances[idx].damageSiClassEffective[c];
	}

	return sum;
}

void ZMR_AppendTankDamagePiece(char[] dest, int destLen, const char[] label, int eff, int raw, int maxHp, bool &first)
{
	if (eff <= 0)
	{
		return;
	}

	float pct = 0.0;
	if (maxHp > 0)
	{
		pct = (eff * 100.0) / float(maxHp);
	}

	char piece[96];
	if (raw != eff)
	{
		Format(piece, sizeof(piece), "%s%s:eff=%d,pct=%.1f,raw=%d",
			first ? "" : ",", label, eff, pct, raw);
	}
	else
	{
		Format(piece, sizeof(piece), "%s%s:eff=%d,pct=%.1f",
			first ? "" : ",", label, eff, pct);
	}

	StrCat(dest, destLen, piece);
	first = false;
}

void ZMR_FormatTankDamageTable(int idx, char[] dest, int destLen)
{
	dest[0] = '\0';
	bool first = true;
	int maxHp = g_TankInstances[idx].maxHp;
	int pairs[MAXPLAYERS + 1];
	int pairCount = 0;

	for (int slot = 1; slot <= MaxClients; slot++)
	{
		if (g_TankInstances[idx].damageEffective[slot] > 0)
		{
			pairs[pairCount++] = slot;
		}
	}

	for (int i = 1; i < pairCount; i++)
	{
		int key = pairs[i];
		int j = i - 1;
		while (j >= 0
			&& g_TankInstances[idx].damageEffective[pairs[j]]
				< g_TankInstances[idx].damageEffective[key])
		{
			pairs[j + 1] = pairs[j];
			j--;
		}

		pairs[j + 1] = key;
	}

	for (int i = 0; i < pairCount; i++)
	{
		int slot = pairs[i];
		char rawName[MAX_NAME_LENGTH];
		char safeName[64];
		GetClientName(slot, rawName, sizeof(rawName));
		ZMR_SanitizeNameForLog(rawName, safeName, sizeof(safeName));
		if (safeName[0] == '\0')
		{
			Format(safeName, sizeof(safeName), "slot%d", slot);
		}

		ZMR_AppendTankDamagePiece(dest, destLen, safeName,
			g_TankInstances[idx].damageEffective[slot],
			g_TankInstances[idx].damageRaw[slot], maxHp, first);
	}

	ZMR_AppendTankDamagePiece(dest, destLen, "tank_rock",
		g_TankInstances[idx].damageRockEffective,
		g_TankInstances[idx].damageRockRaw, maxHp, first);
	ZMR_AppendTankDamagePiece(dest, destLen, "tank_melee",
		g_TankInstances[idx].damageMeleeEffective,
		g_TankInstances[idx].damageMeleeRaw, maxHp, first);
	ZMR_AppendTankDamagePiece(dest, destLen, "fire",
		g_TankInstances[idx].damageFireEffective,
		g_TankInstances[idx].damageFireRaw, maxHp, first);
	ZMR_AppendTankDamagePiece(dest, destLen, "env",
		g_TankInstances[idx].damageEnvEffective,
		g_TankInstances[idx].damageEnvRaw, maxHp, first);

	for (int c = 0; c < ZMR_SI_CLASS_COUNT; c++)
	{
		char siKey[24];
		ZMR_SiClassBdKey(c, siKey, sizeof(siKey));
		ZMR_AppendTankDamagePiece(dest, destLen, siKey,
			g_TankInstances[idx].damageSiClassEffective[c],
			g_TankInstances[idx].damageSiClassRaw[c], maxHp, first);
	}

	ZMR_AppendTankDamagePiece(dest, destLen, "si_common",
		g_TankInstances[idx].damageSiCommonEffective,
		g_TankInstances[idx].damageSiCommonRaw, maxHp, first);
	ZMR_AppendTankDamagePiece(dest, destLen, "si_tank",
		g_TankInstances[idx].damageSiTankEffective,
		g_TankInstances[idx].damageSiTankRaw, maxHp, first);
	ZMR_AppendTankDamagePiece(dest, destLen, "other",
		g_TankInstances[idx].damageOtherEffective,
		g_TankInstances[idx].damageOtherRaw, maxHp, first);

	if (dest[0] == '\0')
	{
		strcopy(dest, destLen, "-");
	}
}

bool ZMR_TankHasFireLitBreakdown(int idx)
{
	for (int slot = 1; slot <= MaxClients; slot++)
	{
		if (g_TankInstances[idx].damageFireLitByEffective[slot] > 0)
		{
			return true;
		}
	}

	return false;
}

void ZMR_FormatTankFireLitBreakdown(int idx, char[] dest, int destLen)
{
	dest[0] = '\0';
	int pairs[MAXPLAYERS + 1];
	int pairCount = 0;

	for (int slot = 1; slot <= MaxClients; slot++)
	{
		if (g_TankInstances[idx].damageFireLitByEffective[slot] > 0)
		{
			pairs[pairCount++] = slot;
		}
	}

	for (int i = 1; i < pairCount; i++)
	{
		int key = pairs[i];
		int j = i - 1;
		while (j >= 0
			&& g_TankInstances[idx].damageFireLitByEffective[pairs[j]]
				< g_TankInstances[idx].damageFireLitByEffective[key])
		{
			pairs[j + 1] = pairs[j];
			j--;
		}

		pairs[j + 1] = key;
	}

	for (int i = 0; i < pairCount; i++)
	{
		int slot = pairs[i];
		char rawName[MAX_NAME_LENGTH];
		char safeName[64];
		char part[80];

		GetClientName(slot, rawName, sizeof(rawName));
		ZMR_SanitizeNameForLog(rawName, safeName, sizeof(safeName));
		if (safeName[0] == '\0')
		{
			Format(safeName, sizeof(safeName), "slot%d", slot);
		}

		Format(part, sizeof(part), "%s%s:%d",
			dest[0] == '\0' ? "" : ",",
			safeName,
			g_TankInstances[idx].damageFireLitByEffective[slot]);
		StrCat(dest, destLen, part);
	}
}

void ZMR_LogTankFireLitMetric(int idx)
{
	if (!ZMR_TankHasFireLitBreakdown(idx))
	{
		return;
	}

	char breakdown[384];
	ZMR_FormatTankFireLitBreakdown(idx, breakdown, sizeof(breakdown));
	LogMessage("[zf_mr] METRIC tank #%d fire_lit | %s",
		g_TankInstances[idx].spawnSeq, breakdown);
}

void ZMR_LogTankDeathMetric(int idx)
{
	int killer = g_TankInstances[idx].killerClient;
	int creditSlot = 0;

	if (killer > 0 && killer <= MaxClients && IsClientInGame(killer) && ZMR_IsSurvivor(killer))
	{
		creditSlot = killer;
	}

	char table[384];
	ZMR_FormatTankDamageTable(idx, table, sizeof(table));

	LogMessage("[zf_mr] METRIC tank #%d dead client=%d max_hp=%d killer=%d credit_slot=%d bd=%s",
		g_TankInstances[idx].spawnSeq,
		g_TankInstances[idx].tankClient,
		g_TankInstances[idx].maxHp,
		killer,
		creditSlot,
		table);
	ZMR_LogTankFireLitMetric(idx);
}

void ZMR_DumpTankInstancesToLog()
{
	if (g_iTankInstanceCount <= 0)
	{
		return;
	}

	for (int i = 0; i < g_iTankInstanceCount; i++)
	{
		if (g_TankInstances[i].spawnSeq == 0)
		{
			continue;
		}

		char table[384];
		ZMR_FormatTankDamageTable(i, table, sizeof(table));

		LogMessage("[zf_mr] METRIC tank #%d inst client=%d max_hp=%d z_tank_health=%d closed=%d killer=%d bd=%s",
			g_TankInstances[i].spawnSeq,
			g_TankInstances[i].tankClient,
			g_TankInstances[i].maxHp,
			g_TankInstances[i].zTankHealthCvar,
			g_TankInstances[i].closed ? 1 : 0,
			g_TankInstances[i].killerClient,
			table);
		ZMR_LogTankFireLitMetric(i);
	}
}

void ZMR_CloseTankInstanceOnDeath(int tankClient, int killerClient)
{
	if (ZMR_FindOpenTankInstanceByClient(tankClient) < 0)
	{
		ZMR_TryLazyRegisterTank(tankClient);
	}

	int idx = ZMR_FindOpenTankInstanceByClient(tankClient);
	if (idx < 0)
	{
		return;
	}

	g_TankInstances[idx].closed = true;
	g_TankInstances[idx].killerClient = killerClient;
	ZMR_TankFinalizeAttribution(idx);
	ZMR_LogTankDeathMetric(idx);

	// Keep fire/world for the end Tank % line even if a slot is later recycled.
	g_iRoundTankFireEffective += g_TankInstances[idx].damageFireEffective;
	g_iRoundTankEnvEffective += g_TankInstances[idx].damageEnvEffective;
	LogMessage("[zf_mr] tank #%d fire_round_acc +%d total_fire=%d env_acc +%d total_env=%d",
		g_TankInstances[idx].spawnSeq,
		g_TankInstances[idx].damageFireEffective,
		g_iRoundTankFireEffective,
		g_TankInstances[idx].damageEnvEffective,
		g_iRoundTankEnvEffective);

	if (g_cvEnabled.BoolValue
		&& g_cvTankReportOnDeath != null
		&& g_cvTankReportOnDeath.BoolValue)
	{
		ZMR_BroadcastTankDeathChat(idx);
	}

	// Keep the closed slot until round reset so end Tank % / METRIC still see fire/world.
	// (Previously Release zeroed the only remaining copy when round totals were missed.)
}

void ZMR_BroadcastTankDeathChat(int idx)
{
	if (idx < 0 || idx >= ZMR_MAX_TANK_TRACKING_SLOTS)
	{
		return;
	}

	// Wipe / end-report already running: never schedule, never flush later.
	if (ZMR_ShouldSuppressTankDeathChat())
	{
		LogMessage("[zf_mr] tank_death chat suppressed (end sequence) slot=%d seq=%d",
			idx, g_TankInstances[idx].spawnSeq);
		return;
	}

	if (g_hPendingTankDeathChatTimer[idx] != null)
	{
		KillTimer(g_hPendingTankDeathChatTimer[idx]);
		g_hPendingTankDeathChatTimer[idx] = null;
	}

	// Brief defer so round_end in the same moment can cancel wipe-tank chat.
	g_hPendingTankDeathChatTimer[idx] = CreateTimer(ZMR_TANK_DEATH_CHAT_DEFER_SEC,
		Timer_DeferredTankDeathChat, idx, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_DeferredTankDeathChat(Handle timer, any idx)
{
	if (idx < 0 || idx >= ZMR_MAX_TANK_TRACKING_SLOTS)
	{
		return Plugin_Stop;
	}

	g_hPendingTankDeathChatTimer[idx] = null;

	if (ZMR_ShouldSuppressTankDeathChat())
	{
		LogMessage("[zf_mr] tank_death chat cancelled (end sequence after defer) slot=%d seq=%d",
			idx, g_TankInstances[idx].spawnSeq);
		return Plugin_Stop;
	}

	ZMR_PrintTankDeathChatAll(idx);
	return Plugin_Stop;
}

void ZMR_PrintTankDeathChatAll(int idx)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!ZMR_IsHumanInGame(client))
		{
			continue;
		}

		ZMR_DumpTankDeathToChat(client, idx);
	}
}

void ZMR_DumpTankDeathToChat(int recipient, int idx)
{
	if (recipient <= 0 || recipient > MaxClients || !IsClientInGame(recipient))
	{
		return;
	}

	int killer = g_TankInstances[idx].killerClient;
	int creditSlot = 0;

	if (killer > 0 && killer <= MaxClients && IsClientInGame(killer) && ZMR_IsSurvivor(killer))
	{
		creditSlot = killer;
	}

	char creditLabel[MAX_NAME_LENGTH];
	if (creditSlot > 0)
	{
		GetClientName(creditSlot, creditLabel, sizeof(creditLabel));
	}
	else
	{
		strcopy(creditLabel, sizeof(creditLabel), "-");
	}

	char headerLine[128];
	ZMR_PrintPlainChat(recipient, ZMR_TANK_DEATH_CHAT_SEPARATOR);
	Format(headerLine, sizeof(headerLine), "tank #%d dead | credit: %s",
		g_TankInstances[idx].spawnSeq, creditLabel);
	ZMR_PrintPlainChat(recipient, headerLine);

	int maxHp = g_TankInstances[idx].maxHp;
	int pairs[MAXPLAYERS + 1];
	int pairCount = 0;

	for (int slot = 1; slot <= MaxClients; slot++)
	{
		if (!ZMR_IsSurvivor(slot))
		{
			continue;
		}

		pairs[pairCount++] = slot;
	}

	for (int i = 1; i < pairCount; i++)
	{
		int key = pairs[i];
		int j = i - 1;
		while (j >= 0
			&& g_TankInstances[idx].damageEffective[pairs[j]]
				< g_TankInstances[idx].damageEffective[key])
		{
			pairs[j + 1] = pairs[j];
			j--;
		}

		pairs[j + 1] = key;
	}

	bool anyRow = pairCount > 0 || ZMR_TankHasAnyCategoryDamage(idx);

	if (!anyRow)
	{
		ZMR_PrintPlainChat(recipient, "(no damage attributed this tank)");
		ZMR_PrintPlainChat(recipient, ZMR_TANK_DEATH_CHAT_SEPARATOR);
		return;
	}

	ZMR_TankChatRow chatRows[ZMR_TANK_CHAT_MAX_ROWS];
	int chatRowCount = 0;
	char chatName[64];

	for (int i = 0; i < pairCount; i++)
	{
		char rawName[MAX_NAME_LENGTH];
		GetClientName(pairs[i], rawName, sizeof(rawName));
		// Soft-cap only — pad target is max measured width of this block, not a fixed px.
		ZMR_ChatTruncateToWidth(rawName, chatName, sizeof(chatName), ZMR_TANK_DEATH_CHAT_NAME_CAP_PX);
		ZMR_TankChatPushSurvivorRow(chatRows, chatRowCount, chatName,
			g_TankInstances[idx].damageEffective[pairs[i]], maxHp);
	}

	int chatZombiesEff = ZMR_TankChatZombiesEffective(idx);

	ZMR_TankChatTryPushRow(chatRows, chatRowCount, ZMR_TANK_CHAT_LABEL_ROCK,
		g_TankInstances[idx].damageRockEffective, maxHp);
	ZMR_TankChatTryPushRow(chatRows, chatRowCount, ZMR_TANK_CHAT_LABEL_ZOMBIES,
		chatZombiesEff, maxHp);
	ZMR_TankChatTryPushRow(chatRows, chatRowCount, ZMR_TANK_CHAT_LABEL_FIRE,
		g_TankInstances[idx].damageFireEffective, maxHp);

	ZMR_TankChatFinalizeDisplayRows(chatRows, chatRowCount, maxHp);

	// One pass: measure column maxima for THIS block, then pad once (no fixed targets).
	int maxNamePx = 0;
	int maxPctPx = 0;
	int maxDmgPx = 0;
	char pctBuf[16];
	char dmgBuf[16];

	for (int i = 0; i < chatRowCount; i++)
	{
		int namePx = ZMR_ChatStringWidth(chatRows[i].label);
		ZMR_FormatPctTenths(chatRows[i].pct10, pctBuf, sizeof(pctBuf));
		IntToString(chatRows[i].eff, dmgBuf, sizeof(dmgBuf));
		int pctPx = ZMR_ChatStringWidth(pctBuf);
		int dmgPx = ZMR_ChatStringWidth(dmgBuf);
		if (namePx > maxNamePx)
		{
			maxNamePx = namePx;
		}

		if (pctPx > maxPctPx)
		{
			maxPctPx = pctPx;
		}

		if (dmgPx > maxDmgPx)
		{
			maxDmgPx = dmgPx;
		}
	}

	for (int i = 0; i < chatRowCount; i++)
	{
		ZMR_PrintTankDeathChatRow(recipient, chatRows[i].label, chatRows[i].eff, chatRows[i].pct10,
			maxNamePx, maxPctPx, maxDmgPx);
	}

	ZMR_PrintPlainChat(recipient, ZMR_TANK_DEATH_CHAT_SEPARATOR);
}

void ZMR_PrintTankDeathChatRow(int recipient, const char[] label, int eff, int pct10,
	int nameColPx, int maxPctPx, int maxDmgPx)
{
	char nameCol[96];
	char pctScratch[16];
	char pctCol[48];
	char dmgScratch[16];
	char dmgCol[48];
	char line[256];

	// label already truncated; pad only (right name, left numbers).
	ZMR_ChatPadToWidth(label, nameCol, sizeof(nameCol), nameColPx);
	ZMR_FormatPctTenths(pct10, pctScratch, sizeof(pctScratch));
	ZMR_ChatPadLeftToWidth(pctScratch, pctCol, sizeof(pctCol), maxPctPx);
	IntToString(eff, dmgScratch, sizeof(dmgScratch));
	ZMR_ChatPadLeftToWidth(dmgScratch, dmgCol, sizeof(dmgCol), maxDmgPx);
	Format(line, sizeof(line), "%s | %s : %s", nameCol, pctCol, dmgCol);
	ZMR_PrintPlainChat(recipient, line);
}

// matchId > 0 only on the authoritative end-of-match dump: header gets match=<n> and the
// block closes with "METRIC end match=<n>" (the Report service's "block complete" signal).
// Manual dumps carry neither, so the service ignores them.
void ZMR_DumpMetricsToLog(const char[] trigger, int matchId = 0)
{
	LogMessage("%s", ZMR_METRIC_DUMP_SEPARATOR);
	if (matchId > 0)
	{
		LogMessage("[zf_mr] METRIC round v%s | tanks:%d | schema:%d | trigger=%s | match=%d",
			PLUGIN_VERSION, g_iTanksSpawnedThisRound, ZMR_SCHEMA_VERSION, trigger, matchId);
	}
	else
	{
		LogMessage("[zf_mr] METRIC round v%s | tanks:%d | schema:%d | trigger=%s",
			PLUGIN_VERSION, g_iTanksSpawnedThisRound, ZMR_SCHEMA_VERSION, trigger);
	}

	int maxNameW = 0;
	int maxSI = 1;
	int maxFF = 1;
	int maxTk = 1;
	int maxKSI = 1;
	int maxKTk = 1;
	bool any = false;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client))
		{
			continue;
		}

		ZMR_EnsureSteamId(client);

		if (!ZMR_PlayerHasStats(client))
		{
			continue;
		}

		any = true;
		char rawName[MAX_NAME_LENGTH];
		char chatName[ZMR_CHAT_NAME_MAX + 1];

		GetClientName(client, rawName, sizeof(rawName));
		ZMR_TruncateNameForChat(rawName, chatName, sizeof(chatName), ZMR_CHAT_NAME_MAX);

		int nameLen = strlen(chatName);
		if (nameLen > maxNameW)
		{
			maxNameW = nameLen;
		}

		maxSI = ZMR_MaxInt(maxSI, ZMR_IntDigitCount(g_RoundStats[client].damageDealtInfected));
		maxFF = ZMR_MaxInt(maxFF, ZMR_IntDigitCount(g_RoundStats[client].damageDealtFF));
		maxTk = ZMR_MaxInt(maxTk, ZMR_IntDigitCount(g_RoundStats[client].damageTaken));
		maxKSI = ZMR_MaxInt(maxKSI, ZMR_IntDigitCount(g_RoundStats[client].siKills));
		maxKTk = ZMR_MaxInt(maxKTk, ZMR_IntDigitCount(g_RoundStats[client].tankKills));
	}

	if (!any)
	{
		LogMessage("[zf_mr] METRIC (no survivor stats this round)");
		ZMR_LogMetricEnd(matchId);
		LogMessage("%s", ZMR_METRIC_DUMP_SEPARATOR);
		return;
	}

	int nameCap = ZMR_ChatNameCapForLine(maxSI, maxFF, maxTk, maxKSI, maxKTk);
	if (nameCap < 1)
	{
		nameCap = 1;
	}

	maxNameW = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client) || !ZMR_PlayerHasStats(client))
		{
			continue;
		}

		char rawName[MAX_NAME_LENGTH];
		char chatName[ZMR_CHAT_NAME_MAX + 1];
		GetClientName(client, rawName, sizeof(rawName));
		ZMR_TruncateNameForChat(rawName, chatName, sizeof(chatName), nameCap);
		int nameLen = strlen(chatName);
		if (nameLen > maxNameW)
		{
			maxNameW = nameLen;
		}
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client))
		{
			continue;
		}

		if (!ZMR_PlayerHasStats(client))
		{
			continue;
		}

		char rawName[MAX_NAME_LENGTH];
		char chatName[ZMR_CHAT_NAME_MAX + 1];
		char nameCol[ZMR_CHAT_NAME_MAX + 1];
		char siCol[16];
		char ffCol[16];
		char tkCol[16];
		char ksiCol[16];
		char ktkCol[16];
		char line[256];

		GetClientName(client, rawName, sizeof(rawName));
		ZMR_TruncateNameForChat(rawName, chatName, sizeof(chatName), nameCap > 0 ? nameCap : ZMR_CHAT_NAME_MAX);
		ZMR_PadStringRight(chatName, nameCol, sizeof(nameCol), maxNameW);

		ZMR_FormatStatSegment(ZMR_STAT_LABEL_SI, g_RoundStats[client].damageDealtInfected, maxSI, siCol, sizeof(siCol));
		ZMR_FormatStatSegment(ZMR_STAT_LABEL_FF, g_RoundStats[client].damageDealtFF, maxFF, ffCol, sizeof(ffCol));
		ZMR_FormatStatSegment(ZMR_STAT_LABEL_DMG_TAKEN, g_RoundStats[client].damageTaken, maxTk, tkCol, sizeof(tkCol));
		ZMR_FormatStatSegment(ZMR_STAT_LABEL_KILL_SI, g_RoundStats[client].siKills, maxKSI, ksiCol, sizeof(ksiCol));
		ZMR_FormatStatSegment(ZMR_STAT_LABEL_KILL_TANK, g_RoundStats[client].tankKills, maxKTk, ktkCol, sizeof(ktkCol));

		Format(line, sizeof(line), "%s | %s | %s | %s | %s | %s",
			nameCol, siCol, ffCol, tkCol, ksiCol, ktkCol);
		LogMessage("[zf_mr] METRIC %s | steam=%s", line, g_RoundStats[client].steamId);

		if (ZMR_PlayerHasSiClassStats(client))
		{
			char siBreakdown[384];
			ZMR_FormatSiClassBreakdown(client, siBreakdown, sizeof(siBreakdown));
			LogMessage("[zf_mr] METRIC %s si | %s", chatName, siBreakdown);
		}

		if (ZMR_PlayerHasTakenBreakdown(client))
		{
			char takenBreakdown[384];
			ZMR_FormatTakenBreakdown(client, takenBreakdown, sizeof(takenBreakdown));
			LogMessage("[zf_mr] METRIC %s taken | %s", chatName, takenBreakdown);
		}

		if (ZMR_PlayerHasCommonStats(client))
		{
			LogMessage("[zf_mr] METRIC %s commons | kills:%d,hs_kills:%d,dmg:%d,hs_dmg:%d",
				chatName,
				g_RoundStats[client].commonKills,
				g_RoundStats[client].commonHeadshotKills,
				g_RoundStats[client].commonDamageDealt,
				g_RoundStats[client].commonHeadshotDamage);
		}

		if (ZMR_PlayerHasCureStats(client))
		{
			LogMessage("[zf_mr] METRIC %s cure | medkit_self:%d,medkit_other:%d,pills:%d,adren:%d,defib:%d,revive_given:%d,revive_recv:%d,incap:%d,death:%d",
				chatName,
				g_RoundStats[client].medkitSelf,
				g_RoundStats[client].medkitOther,
				g_RoundStats[client].pillsUsed,
				g_RoundStats[client].adrenalineUsed,
				g_RoundStats[client].defibOther,
				g_RoundStats[client].reviveGiven,
				g_RoundStats[client].reviveReceived,
				g_RoundStats[client].incapCount,
				g_RoundStats[client].deathCount);
		}

		if (ZMR_PlayerHasHealReceivedBreakdown(client))
		{
			char healBy[384];
			ZMR_FormatPartnerCountBreakdown(client, "healReceivedFrom", healBy, sizeof(healBy));
			LogMessage("[zf_mr] METRIC %s healed_by | %s", chatName, healBy);
		}

		if (ZMR_PlayerHasReviveReceivedBreakdown(client))
		{
			char revivedBy[384];
			ZMR_FormatPartnerCountBreakdown(client, "reviveReceivedFrom", revivedBy, sizeof(revivedBy));
			LogMessage("[zf_mr] METRIC %s revived_by | %s", chatName, revivedBy);
		}

		if (ZMR_PlayerHasGrabStats(client))
		{
			LogMessage("[zf_mr] METRIC %s grabbed | smoker:%d,jockey:%d,hunter:%d,charger:%d,boomer:%d",
				chatName,
				g_RoundStats[client].grabSmoker,
				g_RoundStats[client].grabJockey,
				g_RoundStats[client].grabHunter,
				g_RoundStats[client].grabCharger,
				g_RoundStats[client].grabBoomer);
		}

		if (ZMR_PlayerHasDefenseStats(client))
		{
			LogMessage("[zf_mr] METRIC %s defense | freed:%d,shoves:%d,deadstop:%d,skeet:%d",
				chatName,
				g_RoundStats[client].defenseFreed,
				g_RoundStats[client].defenseShoves,
				g_RoundStats[client].defenseDeadstop,
				g_RoundStats[client].defenseSkeet);
		}

		if (ZMR_PlayerHasMeleeStats(client))
		{
			LogMessage("[zf_mr] METRIC %s melee | si_dmg:%d,common_dmg:%d",
				chatName,
				g_RoundStats[client].meleeSiDamage,
				g_RoundStats[client].meleeCommonDamage);
		}
	}

	ZMR_DumpSiClassTeamTotalsToLog();
	ZMR_DumpCommonTeamTotalsToLog();
	ZMR_DumpCureTeamTotalsToLog();
	ZMR_DumpGrabTeamTotalsToLog();
	ZMR_DumpDefenseTeamTotalsToLog();
	ZMR_DumpMeleeTeamTotalsToLog();

	ZMR_DumpTankInstancesToLog();

	ZMR_LogMetricEnd(matchId);
	LogMessage("%s", ZMR_METRIC_DUMP_SEPARATOR);
}

void ZMR_LogMetricEnd(int matchId)
{
	if (matchId > 0)
	{
		LogMessage("[zf_mr] METRIC end match=%d", matchId);
	}
}

int ZMR_ChatNameCapForLine(int maxSI, int maxFF, int maxTk, int maxKSI, int maxKTk)
{
	int wSI = ZMR_StatSegmentWidth(ZMR_STAT_LABEL_SI, maxSI);
	int wFF = ZMR_StatSegmentWidth(ZMR_STAT_LABEL_FF, maxFF);
	int wTk = ZMR_StatSegmentWidth(ZMR_STAT_LABEL_DMG_TAKEN, maxTk);
	int wKSI = ZMR_StatSegmentWidth(ZMR_STAT_LABEL_KILL_SI, maxKSI);
	int wKTk = ZMR_StatSegmentWidth(ZMR_STAT_LABEL_KILL_TANK, maxKTk);
	int fixed = ZMR_EstimatePlayerLineWidth(0, wSI, wFF, wTk, wKSI, wKTk);

	if (fixed >= ZMR_CHAT_LINE_MAX)
	{
		return 0;
	}

	int cap = ZMR_CHAT_LINE_MAX - fixed;
	if (cap > ZMR_CHAT_NAME_MAX)
	{
		cap = ZMR_CHAT_NAME_MAX;
	}

	return cap;
}

void ZMR_DumpToChat(int recipient)
{
	if (recipient <= 0 || recipient > MaxClients || !IsClientInGame(recipient))
	{
		return;
	}

	PrintToChat(recipient, "%s", ZMR_CHAT_DUMP_SEPARATOR);
	PrintToChat(recipient, "%s round v%s | tanks:%d | schema:%d",
		ZMR_CHAT_TAG, PLUGIN_VERSION, g_iTanksSpawnedThisRound, ZMR_SCHEMA_VERSION);

	int maxNameW = 0;
	int maxSI = 1;
	int maxFF = 1;
	int maxTk = 1;
	int maxKSI = 1;
	int maxKTk = 1;
	bool any = false;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client))
		{
			continue;
		}

		ZMR_EnsureSteamId(client);

		if (!ZMR_PlayerHasStats(client))
		{
			continue;
		}

		any = true;
		char rawName[MAX_NAME_LENGTH];
		char chatName[ZMR_CHAT_NAME_MAX + 1];

		GetClientName(client, rawName, sizeof(rawName));
		ZMR_TruncateNameForChat(rawName, chatName, sizeof(chatName), ZMR_CHAT_NAME_MAX);

		int nameLen = strlen(chatName);
		if (nameLen > maxNameW)
		{
			maxNameW = nameLen;
		}

		maxSI = ZMR_MaxInt(maxSI, ZMR_IntDigitCount(g_RoundStats[client].damageDealtInfected));
		maxFF = ZMR_MaxInt(maxFF, ZMR_IntDigitCount(g_RoundStats[client].damageDealtFF));
		maxTk = ZMR_MaxInt(maxTk, ZMR_IntDigitCount(g_RoundStats[client].damageTaken));
		maxKSI = ZMR_MaxInt(maxKSI, ZMR_IntDigitCount(g_RoundStats[client].siKills));
		maxKTk = ZMR_MaxInt(maxKTk, ZMR_IntDigitCount(g_RoundStats[client].tankKills));
	}

	if (!any)
	{
		PrintToChat(recipient, "%s (no survivor stats this round)", ZMR_CHAT_TAG);
		return;
	}

	int nameCap = ZMR_ChatNameCapForLine(maxSI, maxFF, maxTk, maxKSI, maxKTk);
	if (nameCap < 1)
	{
		nameCap = 1;
	}

	maxNameW = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client) || !ZMR_PlayerHasStats(client))
		{
			continue;
		}

		char rawName[MAX_NAME_LENGTH];
		char chatName[ZMR_CHAT_NAME_MAX + 1];
		GetClientName(client, rawName, sizeof(rawName));
		ZMR_TruncateNameForChat(rawName, chatName, sizeof(chatName), nameCap);
		int nameLen = strlen(chatName);
		if (nameLen > maxNameW)
		{
			maxNameW = nameLen;
		}
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client))
		{
			continue;
		}

		if (!ZMR_PlayerHasStats(client))
		{
			continue;
		}

		char rawName[MAX_NAME_LENGTH];
		char chatName[ZMR_CHAT_NAME_MAX + 1];
		char nameCol[ZMR_CHAT_NAME_MAX + 1];
		char siCol[16];
		char ffCol[16];
		char tkCol[16];
		char ksiCol[16];
		char ktkCol[16];
		char line[256];

		GetClientName(client, rawName, sizeof(rawName));
		ZMR_TruncateNameForChat(rawName, chatName, sizeof(chatName), nameCap > 0 ? nameCap : ZMR_CHAT_NAME_MAX);
		ZMR_PadStringRight(chatName, nameCol, sizeof(nameCol), maxNameW);

		ZMR_FormatStatSegment(ZMR_STAT_LABEL_SI, g_RoundStats[client].damageDealtInfected, maxSI, siCol, sizeof(siCol));
		ZMR_FormatStatSegment(ZMR_STAT_LABEL_FF, g_RoundStats[client].damageDealtFF, maxFF, ffCol, sizeof(ffCol));
		ZMR_FormatStatSegment(ZMR_STAT_LABEL_DMG_TAKEN, g_RoundStats[client].damageTaken, maxTk, tkCol, sizeof(tkCol));
		ZMR_FormatStatSegment(ZMR_STAT_LABEL_KILL_SI, g_RoundStats[client].siKills, maxKSI, ksiCol, sizeof(ksiCol));
		ZMR_FormatStatSegment(ZMR_STAT_LABEL_KILL_TANK, g_RoundStats[client].tankKills, maxKTk, ktkCol, sizeof(ktkCol));

		Format(line, sizeof(line), "%s | %s | %s | %s | %s | %s",
			nameCol, siCol, ffCol, tkCol, ksiCol, ktkCol);
		PrintToChat(recipient, "%s", line);
	}

	PrintToChat(recipient, "%s", ZMR_CHAT_DUMP_SEPARATOR);
}

bool ZMR_PlayerHasStats(int client)
{
	return g_RoundStats[client].damageDealtInfected > 0
		|| g_RoundStats[client].damageDealtFF > 0
		|| g_RoundStats[client].damageTaken > 0
		|| g_RoundStats[client].siKills > 0
		|| g_RoundStats[client].tankKills > 0
		|| ZMR_PlayerHasCommonStats(client)
		|| ZMR_PlayerHasCureStats(client)
		|| ZMR_PlayerHasGrabStats(client)
		|| ZMR_PlayerHasDefenseStats(client)
		|| ZMR_PlayerHasMeleeStats(client);
}

bool ZMR_PlayerHasCureStats(int client)
{
	return g_RoundStats[client].medkitSelf > 0
		|| g_RoundStats[client].medkitOther > 0
		|| g_RoundStats[client].pillsUsed > 0
		|| g_RoundStats[client].adrenalineUsed > 0
		|| g_RoundStats[client].defibOther > 0
		|| g_RoundStats[client].reviveGiven > 0
		|| g_RoundStats[client].reviveReceived > 0
		|| g_RoundStats[client].incapCount > 0
		|| g_RoundStats[client].deathCount > 0;
}

bool ZMR_PlayerHasGrabStats(int client)
{
	return g_RoundStats[client].grabSmoker > 0
		|| g_RoundStats[client].grabJockey > 0
		|| g_RoundStats[client].grabHunter > 0
		|| g_RoundStats[client].grabCharger > 0
		|| g_RoundStats[client].grabBoomer > 0;
}

bool ZMR_PlayerHasDefenseStats(int client)
{
	return g_RoundStats[client].defenseFreed > 0
		|| g_RoundStats[client].defenseShoves > 0
		|| g_RoundStats[client].defenseDeadstop > 0
		|| g_RoundStats[client].defenseSkeet > 0;
}

bool ZMR_PlayerHasMeleeStats(int client)
{
	return g_RoundStats[client].meleeSiDamage > 0
		|| g_RoundStats[client].meleeCommonDamage > 0;
}

bool ZMR_PlayerHasHealReceivedBreakdown(int client)
{
	for (int s = 1; s <= MaxClients; s++)
	{
		if (g_RoundStats[client].healReceivedFrom[s] > 0)
		{
			return true;
		}
	}

	return false;
}

bool ZMR_PlayerHasReviveReceivedBreakdown(int client)
{
	for (int s = 1; s <= MaxClients; s++)
	{
		if (g_RoundStats[client].reviveReceivedFrom[s] > 0)
		{
			return true;
		}
	}

	return false;
}

void ZMR_FormatPartnerCountBreakdown(int client, const char[] field, char[] dest, int destLen)
{
	dest[0] = '\0';

	for (int s = 1; s <= MaxClients; s++)
	{
		int count;
		if (StrEqual(field, "healReceivedFrom", false))
		{
			count = g_RoundStats[client].healReceivedFrom[s];
		}
		else
		{
			count = g_RoundStats[client].reviveReceivedFrom[s];
		}

		if (count <= 0)
		{
			continue;
		}

		char rawName[MAX_NAME_LENGTH];
		char safeName[64];
		char part[80];

		if (!IsClientInGame(s))
		{
			Format(safeName, sizeof(safeName), "slot%d", s);
		}
		else
		{
			GetClientName(s, rawName, sizeof(rawName));
			ZMR_SanitizeNameForLog(rawName, safeName, sizeof(safeName));
		}

		if (safeName[0] == '\0')
		{
			Format(safeName, sizeof(safeName), "slot%d", s);
		}

		Format(part, sizeof(part), "%s%s:%d",
			dest[0] == '\0' ? "" : ",", safeName, count);
		StrCat(dest, destLen, part);
	}
}

bool ZMR_PlayerHasCommonStats(int client)
{
	return g_RoundStats[client].commonKills > 0
		|| g_RoundStats[client].commonHeadshotKills > 0
		|| g_RoundStats[client].commonDamageDealt > 0
		|| g_RoundStats[client].commonHeadshotDamage > 0;
}

bool ZMR_IsSurvivor(int client)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
	{
		return false;
	}

	return L4D_GetClientTeam(client) == L4DTeam_Survivor;
}

bool ZMR_IsInfectedPlayer(int client)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
	{
		return false;
	}

	return L4D_GetClientTeam(client) == L4DTeam_Infected;
}

bool ZMR_IsSpecialInfectedClass(L4D2ZombieClassType zclass)
{
	return ZMR_SiClassToIndex(zclass) >= 0;
}

int ZMR_SiClassToIndex(L4D2ZombieClassType zclass)
{
	switch (zclass)
	{
		case L4D2ZombieClass_Smoker:
		{
			return 0;
		}
		case L4D2ZombieClass_Boomer:
		{
			return 1;
		}
		case L4D2ZombieClass_Hunter:
		{
			return 2;
		}
		case L4D2ZombieClass_Spitter:
		{
			return 3;
		}
		case L4D2ZombieClass_Jockey:
		{
			return 4;
		}
		case L4D2ZombieClass_Charger:
		{
			return 5;
		}
		case L4D2ZombieClass_Witch:
		{
			if (ZMR_IsSurvivalGameMode())
			{
				return -1;
			}

			return 6;
		}
	}

	return -1;
}

void ZMR_SiClassLabel(int classIndex, char[] dest, int destLen)
{
	switch (classIndex)
	{
		case 0: strcopy(dest, destLen, "Smoker");
		case 1: strcopy(dest, destLen, "Boomer");
		case 2: strcopy(dest, destLen, "Hunter");
		case 3: strcopy(dest, destLen, "Spitter");
		case 4: strcopy(dest, destLen, "Jockey");
		case 5: strcopy(dest, destLen, "Charger");
		case 6: strcopy(dest, destLen, "Witch");
		default: strcopy(dest, destLen, "?");
	}
}

bool ZMR_PlayerHasSiClassStats(int client)
{
	for (int c = 0; c < ZMR_SI_CLASS_COUNT; c++)
	{
		if (g_RoundStats[client].siClassDamage[c] > 0 || g_RoundStats[client].siClassKills[c] > 0)
		{
			return true;
		}
	}

	return false;
}

bool ZMR_PlayerHasTakenBreakdown(int client)
{
	if (g_RoundStats[client].damageTakenFromInfected > 0
		|| g_RoundStats[client].damageTakenFromFall > 0
		|| g_RoundStats[client].damageTakenFromWorld > 0)
	{
		return true;
	}

	for (int s = 1; s <= MaxClients; s++)
	{
		if (g_RoundStats[client].damageTakenFromSurvivor[s] > 0)
		{
			return true;
		}
	}

	return false;
}

void ZMR_FormatTakenBreakdown(int client, char[] dest, int destLen)
{
	dest[0] = '\0';
	int pairs[MAXPLAYERS + 1];
	int pairCount = 0;

	for (int s = 1; s <= MaxClients; s++)
	{
		if (g_RoundStats[client].damageTakenFromSurvivor[s] > 0)
		{
			pairs[pairCount++] = s;
		}
	}

	for (int i = 1; i < pairCount; i++)
	{
		int key = pairs[i];
		int j = i - 1;
		while (j >= 0
			&& g_RoundStats[client].damageTakenFromSurvivor[pairs[j]]
				< g_RoundStats[client].damageTakenFromSurvivor[key])
		{
			pairs[j + 1] = pairs[j];
			j--;
		}

		pairs[j + 1] = key;
	}

	for (int i = 0; i < pairCount; i++)
	{
		int slot = pairs[i];
		char rawName[MAX_NAME_LENGTH];
		char safeName[64];
		char part[80];

		GetClientName(slot, rawName, sizeof(rawName));
		ZMR_SanitizeNameForLog(rawName, safeName, sizeof(safeName));
		if (safeName[0] == '\0')
		{
			Format(safeName, sizeof(safeName), "slot%d", slot);
		}

		Format(part, sizeof(part), "%s%s:%d",
			dest[0] == '\0' ? "" : ",",
			safeName,
			g_RoundStats[client].damageTakenFromSurvivor[slot]);
		StrCat(dest, destLen, part);
	}

	if (g_RoundStats[client].damageTakenFromInfected > 0)
	{
		char part[48];
		Format(part, sizeof(part), "%sInfected:%d",
			dest[0] == '\0' ? "" : ",", g_RoundStats[client].damageTakenFromInfected);
		StrCat(dest, destLen, part);
	}

	if (g_RoundStats[client].damageTakenFromFall > 0)
	{
		char part[48];
		Format(part, sizeof(part), "%sFall:%d",
			dest[0] == '\0' ? "" : ",", g_RoundStats[client].damageTakenFromFall);
		StrCat(dest, destLen, part);
	}

	if (g_RoundStats[client].damageTakenFromWorld > 0)
	{
		char part[48];
		Format(part, sizeof(part), "%sWorld:%d",
			dest[0] == '\0' ? "" : ",", g_RoundStats[client].damageTakenFromWorld);
		StrCat(dest, destLen, part);
	}
}

void ZMR_FormatSiClassBreakdown(int client, char[] dest, int destLen)
{
	dest[0] = '\0';

	for (int c = 0; c < ZMR_SI_CLASS_COUNT; c++)
	{
		if (c == 6 && ZMR_IsSurvivalGameMode())
		{
			continue;
		}

		int dmg = g_RoundStats[client].siClassDamage[c];
		int kills = g_RoundStats[client].siClassKills[c];

		if (dmg <= 0 && kills <= 0)
		{
			continue;
		}

		char label[12];
		char part[48];
		ZMR_SiClassLabel(c, label, sizeof(label));
		Format(part, sizeof(part), "%s%s:%d/%d", dest[0] == '\0' ? "" : ",", label, dmg, kills);
		StrCat(dest, destLen, part);
	}
}

void ZMR_DumpSiClassTeamTotalsToLog()
{
	int teamDamage[ZMR_SI_CLASS_COUNT];
	int teamKills[ZMR_SI_CLASS_COUNT];
	bool any = false;

	for (int c = 0; c < ZMR_SI_CLASS_COUNT; c++)
	{
		teamDamage[c] = 0;
		teamKills[c] = 0;
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client))
		{
			continue;
		}

		for (int c = 0; c < ZMR_SI_CLASS_COUNT; c++)
		{
			if (c == 6 && ZMR_IsSurvivalGameMode())
			{
				continue;
			}

			if (g_RoundStats[client].siClassDamage[c] > 0 || g_RoundStats[client].siClassKills[c] > 0)
			{
				any = true;
			}

			teamDamage[c] += g_RoundStats[client].siClassDamage[c];
			teamKills[c] += g_RoundStats[client].siClassKills[c];
		}
	}

	if (!any)
	{
		return;
	}

	char breakdown[384];
	breakdown[0] = '\0';

	for (int c = 0; c < ZMR_SI_CLASS_COUNT; c++)
	{
		if (c == 6 && ZMR_IsSurvivalGameMode())
		{
			continue;
		}

		if (teamDamage[c] <= 0 && teamKills[c] <= 0)
		{
			continue;
		}

		char label[12];
		char part[48];
		ZMR_SiClassLabel(c, label, sizeof(label));
		Format(part, sizeof(part), "%s%s:%d/%d", breakdown[0] == '\0' ? "" : ",", label, teamDamage[c], teamKills[c]);
		StrCat(breakdown, sizeof(breakdown), part);
	}

	LogMessage("[zf_mr] METRIC si_team | %s", breakdown);
}

void ZMR_DumpCommonTeamTotalsToLog()
{
	int teamKills;
	int teamHsKills;
	int teamDmg;
	int teamHsDmg;

	teamKills = 0;
	teamHsKills = 0;
	teamDmg = 0;
	teamHsDmg = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client))
		{
			continue;
		}

		teamKills += g_RoundStats[client].commonKills;
		teamHsKills += g_RoundStats[client].commonHeadshotKills;
		teamDmg += g_RoundStats[client].commonDamageDealt;
		teamHsDmg += g_RoundStats[client].commonHeadshotDamage;
	}

	if (teamKills <= 0 && teamHsKills <= 0 && teamDmg <= 0 && teamHsDmg <= 0)
	{
		return;
	}

	LogMessage("[zf_mr] METRIC commons_team | kills:%d,hs_kills:%d,dmg:%d,hs_dmg:%d",
		teamKills, teamHsKills, teamDmg, teamHsDmg);
}

void ZMR_DumpCureTeamTotalsToLog()
{
	int medSelf;
	int medOther;
	int pills;
	int adren;
	int defib;
	int revGiven;
	int revRecv;
	int incap;
	int deaths;

	medSelf = 0;
	medOther = 0;
	pills = 0;
	adren = 0;
	defib = 0;
	revGiven = 0;
	revRecv = 0;
	incap = 0;
	deaths = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client))
		{
			continue;
		}

		medSelf += g_RoundStats[client].medkitSelf;
		medOther += g_RoundStats[client].medkitOther;
		pills += g_RoundStats[client].pillsUsed;
		adren += g_RoundStats[client].adrenalineUsed;
		defib += g_RoundStats[client].defibOther;
		revGiven += g_RoundStats[client].reviveGiven;
		revRecv += g_RoundStats[client].reviveReceived;
		incap += g_RoundStats[client].incapCount;
		deaths += g_RoundStats[client].deathCount;
	}

	if (medSelf <= 0 && medOther <= 0 && pills <= 0 && adren <= 0 && defib <= 0
		&& revGiven <= 0 && revRecv <= 0 && incap <= 0 && deaths <= 0)
	{
		return;
	}

	LogMessage("[zf_mr] METRIC cure_team | medkit_self:%d,medkit_other:%d,pills:%d,adren:%d,defib:%d,revive_given:%d,revive_recv:%d,incap:%d,death:%d",
		medSelf, medOther, pills, adren, defib, revGiven, revRecv, incap, deaths);
}

void ZMR_DumpGrabTeamTotalsToLog()
{
	int smoker;
	int jockey;
	int hunter;
	int charger;
	int boomer;

	smoker = 0;
	jockey = 0;
	hunter = 0;
	charger = 0;
	boomer = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client))
		{
			continue;
		}

		smoker += g_RoundStats[client].grabSmoker;
		jockey += g_RoundStats[client].grabJockey;
		hunter += g_RoundStats[client].grabHunter;
		charger += g_RoundStats[client].grabCharger;
		boomer += g_RoundStats[client].grabBoomer;
	}

	if (smoker <= 0 && jockey <= 0 && hunter <= 0 && charger <= 0 && boomer <= 0)
	{
		return;
	}

	LogMessage("[zf_mr] METRIC grabbed_team | smoker:%d,jockey:%d,hunter:%d,charger:%d,boomer:%d",
		smoker, jockey, hunter, charger, boomer);
}

void ZMR_DumpDefenseTeamTotalsToLog()
{
	int freed;
	int shoves;
	int deadstop;
	int skeet;

	freed = 0;
	shoves = 0;
	deadstop = 0;
	skeet = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client))
		{
			continue;
		}

		freed += g_RoundStats[client].defenseFreed;
		shoves += g_RoundStats[client].defenseShoves;
		deadstop += g_RoundStats[client].defenseDeadstop;
		skeet += g_RoundStats[client].defenseSkeet;
	}

	if (freed <= 0 && shoves <= 0 && deadstop <= 0 && skeet <= 0)
	{
		return;
	}

	LogMessage("[zf_mr] METRIC defense_team | freed:%d,shoves:%d,deadstop:%d,skeet:%d",
		freed, shoves, deadstop, skeet);
}

void ZMR_DumpMeleeTeamTotalsToLog()
{
	int siDmg;
	int commonDmg;

	siDmg = 0;
	commonDmg = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client))
		{
			continue;
		}

		siDmg += g_RoundStats[client].meleeSiDamage;
		commonDmg += g_RoundStats[client].meleeCommonDamage;
	}

	if (siDmg <= 0 && commonDmg <= 0)
	{
		return;
	}

	LogMessage("[zf_mr] METRIC melee_team | si_dmg:%d,common_dmg:%d", siDmg, commonDmg);
}

void ZMR_LogTankHurt(int victim, int attacker, int damage, const char[] weapon)
{
	char vName[MAX_NAME_LENGTH];
	char aName[MAX_NAME_LENGTH];
	char zClass[24];

	if (victim > 0 && victim <= MaxClients && IsClientInGame(victim))
	{
		GetClientName(victim, vName, sizeof(vName));
	}
	else
	{
		strcopy(vName, sizeof(vName), "(none)");
	}

	if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker))
	{
		GetClientName(attacker, aName, sizeof(aName));
	}
	else
	{
		strcopy(aName, sizeof(aName), "(world)");
	}

	if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker) && ZMR_IsInfectedPlayer(attacker))
	{
		Format(zClass, sizeof(zClass), "%d", view_as<int>(L4D2_GetPlayerZombieClass(attacker)));
	}
	else
	{
		strcopy(zClass, sizeof(zClass), "-");
	}

	LogMessage("[zf_mr] tank_hurt att=%d(%s) zclass=%s vic=%d(%s) dmg=%d weapon=%s",
		attacker, aName, zClass, victim, vName, damage, weapon);
}

void ZMR_LogHurt(Event event, int victim, int attacker, int damage)
{
	char vName[MAX_NAME_LENGTH];
	char aName[MAX_NAME_LENGTH];
	char weapon[32];
	int dtype = event.GetInt("type");

	event.GetString("weapon", weapon, sizeof(weapon));

	if (victim > 0 && victim <= MaxClients && IsClientInGame(victim))
	{
		GetClientName(victim, vName, sizeof(vName));
	}
	else
	{
		strcopy(vName, sizeof(vName), "(none)");
	}

	if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker))
	{
		GetClientName(attacker, aName, sizeof(aName));
	}
	else
	{
		strcopy(aName, sizeof(aName), "(world)");
	}

	LogMessage("[zf_mr] player_hurt att=%d(%s) vic=%d(%s) dmg=%d type=%d weapon=%s%s",
		attacker, aName, victim, vName, damage, dtype, weapon,
		ZMR_PlayerHurtIsFallDamage(event) ? " fall" : "");
}

void ZMR_LogDeath(int victim, int attacker)
{
	char vName[MAX_NAME_LENGTH];
	char aName[MAX_NAME_LENGTH];

	if (victim > 0 && victim <= MaxClients && IsClientInGame(victim))
	{
		GetClientName(victim, vName, sizeof(vName));
	}
	else
	{
		strcopy(vName, sizeof(vName), "(none)");
	}

	if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker))
	{
		GetClientName(attacker, aName, sizeof(aName));
	}
	else
	{
		strcopy(aName, sizeof(aName), "(world)");
	}

	LogMessage("[zf_mr] player_death att=%d(%s) vic=%d(%s)",
		attacker, aName, victim, vName);
}

#include "zf_match_report_endreport.inc"
#include "zf_match_report_recap.inc"

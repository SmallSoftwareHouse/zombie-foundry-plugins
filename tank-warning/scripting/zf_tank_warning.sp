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
 * Zombie Foundry — Tank Warning
 *
 * Written from scratch, from the memory of a plugin seen long ago and never found again,
 * without ever having access to its code.
 *
 * Warns the survivors (audio only) when a Tank throws a rock: aim (windup)
 * and release (launch).
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <zf_core>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "0.2.30"

#define PREF_ENABLED  "zf_tw_enabled"
#define PREF_VOLUME   "zf_tw_volume"

// Stock: sempre udibile su ogni client L4D2 (nessun download).
#define SOUND_STOCK_DEFAULT "ambient/alarms/klaxon1.wav"

#define SOUND_WINDUP_REL_DEFAULT "zombiefoundry/zf_tank_rock_alert.mp3"
#define SOUND_LAUNCH_REL_DEFAULT "zombiefoundry/zf_tank_rock_throw.mp3"
#define SOUND_BEEP_TEST_PATH  "sound/zombiefoundry/zf_beepclear.wav"
#define SOUNDSCRIPT_PATH      "scripts/game_sounds_custom.txt"

enum ZTW_AlarmPhase
{
	ZTW_Phase_Aim = 0,
	ZTW_Phase_Launch,
	ZTW_Phase_COUNT
}

ConVar g_cvEnabled;
ConVar g_cvAimAngle;
ConVar g_cvPollInterval;
ConVar g_cvCustomSound;
ConVar g_cvStockSound;
ConVar g_cvStockRepeat;
ConVar g_cvStockInterval;
ConVar g_cvStockLength;
ConVar g_cvStockPitch;
ConVar g_cvLaunchAlarm;
char g_sStock[PLATFORM_MAX_PATH] = SOUND_STOCK_DEFAULT;
ConVar g_cvCustomStar;
ConVar g_cvSoundWindup;
ConVar g_cvSoundLaunch;

bool g_bPrefsReady;
char g_sWindupRel[PLATFORM_MAX_PATH];
char g_sLaunchRel[PLATFORM_MAX_PATH];
bool g_bWindupPrecached;
bool g_bLaunchPrecached;
int g_iActiveTank = -1;
int g_iActiveRock = -1;
int g_iAimWarnClient = -1;
Handle g_hAimTimer = null;
bool g_bAlarmPlayed[MAXPLAYERS + 1][ZTW_Phase_COUNT];

public Plugin myinfo =
{
	name = "Zombie Foundry Tank Warning",
	author = "Zombie Foundry",
	description = "Audio warnings when a tank aims and throws a rock",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	if (!ZF_IsCoreLoaded())
	{
		SetFailState("Zombie Foundry Core (zf_core.smx) is required. Load zf_core first.");
	}

	g_cvEnabled = CreateConVar("zf_tw_enabled", "1",
		"Master server toggle for tank rock aim warnings (1=on, 0=off).",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvAimAngle = CreateConVar("zf_tw_aim_angle", "22.0",
		"Half-angle (degrees) of the tank aim cone used to pick a target survivor.",
		FCVAR_NOTIFY, true, 5.0, true, 60.0);
	g_cvPollInterval = CreateConVar("zf_tw_poll_interval", "0.12",
		"How often (seconds) to re-check tank aim during rock windup.",
		FCVAR_NOTIFY, true, 0.05, true, 0.5);
	g_cvCustomSound = CreateConVar("zf_tw_custom_sound", "0",
		"0=stock L4D2 sound zf_tw_stock_sound (everyone hears it, default). 1=custom files: WARNING not everyone hears them (clients with limited cl_downloadfilter never download them).",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvStockSound = CreateConVar("zf_tw_stock_sound", SOUND_STOCK_DEFAULT,
		"Stock L4D2 sound (path under sound/, already in the game) used when zf_tw_custom_sound=0.",
		FCVAR_NOTIFY);
	g_cvStockRepeat = CreateConVar("zf_tw_stock_repeat", "3",
		"How many times the stock sound is played per alarm (overlapping if interval < sound length).",
		FCVAR_NOTIFY, true, 1.0, true, 6.0);
	g_cvStockInterval = CreateConVar("zf_tw_stock_interval", "1.02",
		"Seconds between stock sound repeats.",
		FCVAR_NOTIFY, true, 0.05, true, 2.0);
	g_cvStockLength = CreateConVar("zf_tw_stock_length", "0",
		"Cut each alarm after this many seconds from the last repeat (0 = play to the end).",
		FCVAR_NOTIFY, true, 0.0, true, 5.0);
	g_cvStockPitch = CreateConVar("zf_tw_stock_pitch", "100",
		"Pitch of the stock sound (100 = normal).",
		FCVAR_NOTIFY, true, 50.0, true, 200.0);
	g_cvLaunchAlarm = CreateConVar("zf_tw_launch_alarm", "0",
		"1=also play the alarm (same sound as aim) when the rock is released, 0=aim alarm only (default).",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvCustomStar = CreateConVar("zf_tw_custom_star", "0",
		"Plan B: 1=prefix emit path with '*' to force streaming, 0=raw path (default). Precache stays raw either way. Toggle to test without recompiling.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvSoundWindup = CreateConVar("zf_tw_sound_windup", SOUND_WINDUP_REL_DEFAULT,
		"Relative sound path for windup/aim alarm (under sound/). Empty uses built-in default MP3.",
		FCVAR_NOTIFY);
	g_cvSoundLaunch = CreateConVar("zf_tw_sound_launch", SOUND_LAUNCH_REL_DEFAULT,
		"Relative sound path for rock release alarm. Empty = same as zf_tw_sound_windup.",
		FCVAR_NOTIFY);

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);

	RegAdminCmd("sm_zf_testsound", Cmd_TestSound, ADMFLAG_GENERIC,
		"Play the tank warning windup sound to yourself to test the audio (no tank needed).");

	if (ZF_IsCoreLoaded())
	{
		ZTW_RegisterPrefs();
	}

	ZTW_RegisterDownloads();
}

void ZTW_NormalizeRelSoundPath(const char[] input, char[] out, int maxlen)
{
	strcopy(out, maxlen, input);
	TrimString(out);
	if (out[0] == '\0')
	{
		strcopy(out, maxlen, SOUND_WINDUP_REL_DEFAULT);
		return;
	}

	if (StrContains(out, "sound/", false) == 0 || StrContains(out, "sound\\", false) == 0)
	{
		strcopy(out, maxlen, out[6]);
	}
}

void ZTW_GetWindupRelPath(char[] out, int maxlen)
{
	char raw[PLATFORM_MAX_PATH];
	g_cvSoundWindup.GetString(raw, sizeof(raw));
	ZTW_NormalizeRelSoundPath(raw, out, maxlen);
}

void ZTW_GetLaunchRelPath(char[] out, int maxlen)
{
	char raw[PLATFORM_MAX_PATH];
	g_cvSoundLaunch.GetString(raw, sizeof(raw));
	TrimString(raw);
	if (raw[0] == '\0')
	{
		ZTW_GetWindupRelPath(out, maxlen);
		return;
	}

	ZTW_NormalizeRelSoundPath(raw, out, maxlen);
}

void ZTW_RelPathToDownloadPath(const char[] relPath, char[] out, int maxlen)
{
	Format(out, maxlen, "sound/%s", relPath);
}

bool ZTW_IsRelPathPrecached(const char[] relPath)
{
	if (StrEqual(relPath, g_sWindupRel, false))
	{
		return g_bWindupPrecached;
	}
	if (StrEqual(relPath, g_sLaunchRel, false))
	{
		return g_bLaunchPrecached;
	}
	return false;
}

public Action Cmd_TestSound(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client))
	{
		ReplyToCommand(client, "[zf] sm_zf_testsound must be run in-game.");
		return Plugin_Handled;
	}

	float volume = 0.85;
	if (g_bPrefsReady)
	{
		volume = ZF_GetClientPrefFloat(client, PREF_VOLUME, 0.85);
		if (volume < 0.0)
		{
			volume = 0.0;
		}
		else if (volume > 1.0)
		{
			volume = 1.0;
		}
	}

	if (volume < 0.01)
	{
		volume = 0.85;
	}

	char windupRel[PLATFORM_MAX_PATH];
	ZTW_GetWindupRelPath(windupRel, sizeof(windupRel));
	char downloadPath[PLATFORM_MAX_PATH];
	ZTW_RelPathToDownloadPath(windupRel, downloadPath, sizeof(downloadPath));

	bool wantCustom = g_cvCustomSound.BoolValue && FileExists(downloadPath, true);
	bool customReady = wantCustom && ZTW_IsRelPathPrecached(windupRel);

	ZTW_PlayWarningSound(client, volume, ZTW_Phase_Aim);

	if (wantCustom && !customReady)
	{
		ReplyToCommand(client, "[zf] Custom sound NOT precached for this map: played the stock '%s'. Run 'changelevel <map>' once (a plugin reload is NOT enough), then test again.", g_sStock);
	}
	else if (customReady)
	{
		char emitPath[PLATFORM_MAX_PATH];
		ZTW_GetCustomEmitPath(windupRel, emitPath, sizeof(emitPath));
		ReplyToCommand(client, "[zf] Played windup sound: %s (zf_tw_custom_sound=1, zf_tw_custom_star=%d). Launch path: zf_tw_sound_launch (empty = windup).",
			emitPath, g_cvCustomStar.BoolValue);
	}
	else
	{
		ReplyToCommand(client, "[zf] Played tank warning sound: %s (zf_tw_custom_sound=%d).",
			g_sStock, g_cvCustomSound.BoolValue);
	}
	return Plugin_Handled;
}

public void ZF_OnCoreReady()
{
	ZTW_RegisterPrefs();
}

void ZTW_RegisterPrefs()
{
	if (g_bPrefsReady)
	{
		return;
	}

	if (!ZF_RegisterClientPref(PREF_ENABLED, "Tank warning alerts", CookieAccess_Public, "1")
		|| !ZF_RegisterClientPref(PREF_VOLUME, "Tank warning volume (0-1)", CookieAccess_Public, "0.85"))
	{
		LogError("[zf_tank_warning] Failed to register one or more ClientPrefs via zf_core.");
		return;
	}

	g_bPrefsReady = true;
}

public void OnMapStart()
{
	ZTW_RegisterDownloads();
	ZTW_PrecacheStock();
	ZTW_PrecacheConfiguredSounds();
	ZTW_EndThrowCycle();
}

void ZTW_PrecacheOneRelPath(const char[] relPath, bool &precachedFlag)
{
	precachedFlag = false;

	char downloadPath[PLATFORM_MAX_PATH];
	ZTW_RelPathToDownloadPath(relPath, downloadPath, sizeof(downloadPath));

	if (!FileExists(downloadPath, true))
	{
		LogError("[zf_tank_warning] Missing server sound file: %s (path skipped).", downloadPath);
		return;
	}

	precachedFlag = PrecacheSound(relPath, true);
	if (precachedFlag)
	{
		LogMessage("[zf_tank_warning] Custom sound precached (%s).", relPath);
	}
	else
	{
		LogError("[zf_tank_warning] PrecacheSound failed for %s; falling back to stock when needed.", relPath);
	}
}

void ZTW_PrecacheConfiguredSounds()
{
	g_bWindupPrecached = false;
	g_bLaunchPrecached = false;

	ZTW_GetWindupRelPath(g_sWindupRel, sizeof(g_sWindupRel));
	ZTW_GetLaunchRelPath(g_sLaunchRel, sizeof(g_sLaunchRel));

	ZTW_PrecacheOneRelPath(g_sWindupRel, g_bWindupPrecached);

	if (StrEqual(g_sLaunchRel, g_sWindupRel, false))
	{
		g_bLaunchPrecached = g_bWindupPrecached;
	}
	else
	{
		ZTW_PrecacheOneRelPath(g_sLaunchRel, g_bLaunchPrecached);
	}
}

void ZTW_GetCustomEmitPath(const char[] relPath, char[] out, int maxlen)
{
	if (g_cvCustomStar.BoolValue)
	{
		Format(out, maxlen, "*%s", relPath);
	}
	else
	{
		strcopy(out, maxlen, relPath);
	}
}

void ZTW_RegisterDownloads()
{
	char windupRel[PLATFORM_MAX_PATH];
	char launchRel[PLATFORM_MAX_PATH];
	ZTW_GetWindupRelPath(windupRel, sizeof(windupRel));
	ZTW_GetLaunchRelPath(launchRel, sizeof(launchRel));

	char downloadPath[PLATFORM_MAX_PATH];

	ZTW_RelPathToDownloadPath(windupRel, downloadPath, sizeof(downloadPath));
	if (FileExists(downloadPath, true))
	{
		AddFileToDownloadsTable(downloadPath);
	}
	else
	{
		LogError("[zf_tank_warning] Missing server sound file: %s", downloadPath);
	}

	if (!StrEqual(windupRel, launchRel, false))
	{
		ZTW_RelPathToDownloadPath(launchRel, downloadPath, sizeof(downloadPath));
		if (FileExists(downloadPath, true))
		{
			AddFileToDownloadsTable(downloadPath);
		}
		else
		{
			LogError("[zf_tank_warning] Missing server sound file: %s", downloadPath);
		}
	}

	if (FileExists(SOUND_BEEP_TEST_PATH, true))
	{
		AddFileToDownloadsTable(SOUND_BEEP_TEST_PATH);
	}

	if (FileExists(SOUNDSCRIPT_PATH, true))
	{
		AddFileToDownloadsTable(SOUNDSCRIPT_PATH);
	}
}

void ZTW_PlayWarningSound(int client, float volume, ZTW_AlarmPhase phase)
{
	if (volume < 0.5)
	{
		volume = 0.5;
	}
	else if (volume > 1.0)
	{
		volume = 1.0;
	}

	char relPath[PLATFORM_MAX_PATH];
	if (phase == ZTW_Phase_Launch)
	{
		ZTW_GetLaunchRelPath(relPath, sizeof(relPath));
	}
	else
	{
		ZTW_GetWindupRelPath(relPath, sizeof(relPath));
	}

	if (g_cvCustomSound.BoolValue && ZTW_IsRelPathPrecached(relPath))
	{
		char emitPath[PLATFORM_MAX_PATH];
		ZTW_GetCustomEmitPath(relPath, emitPath, sizeof(emitPath));
		EmitSoundToClient(client, emitPath, SOUND_FROM_PLAYER, SNDCHAN_STATIC,
			SNDLEVEL_NONE, SND_NOFLAGS, volume, SNDPITCH_NORMAL);
	}
	else
	{
		ZTW_PlayStockSequence(client, volume, phase);
	}
}

void ZTW_PlayStockSequence(int client, float volume, ZTW_AlarmPhase phase)
{
	int pitch = g_cvStockPitch.IntValue;
	int repeat = g_cvStockRepeat.IntValue;
	float interval = g_cvStockInterval.FloatValue;
	int userid = GetClientUserId(client);

	ZTW_EmitStock(client, volume, pitch);
	for (int i = 1; i < repeat; i++)
	{
		DataPack pack;
		CreateDataTimer(interval * float(i), Timer_StockRepeat, pack, TIMER_FLAG_NO_MAPCHANGE);
		pack.WriteCell(userid);
		pack.WriteFloat(volume);
		pack.WriteCell(pitch);
	}

	float length = g_cvStockLength.FloatValue;
	if (length > 0.0)
	{
		CreateTimer(interval * float(repeat - 1) + length, Timer_StockStop, userid, TIMER_FLAG_NO_MAPCHANGE);
	}
}

void ZTW_EmitStock(int client, float volume, int pitch)
{
	// SNDCHAN_AUTO: le ripetizioni si accavallano invece di interrompersi.
	EmitSoundToClient(client, g_sStock, SOUND_FROM_PLAYER, SNDCHAN_AUTO,
		SNDLEVEL_NONE, SND_NOFLAGS, volume, pitch);
}

public Action Timer_StockRepeat(Handle timer, DataPack pack)
{
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	float volume = pack.ReadFloat();
	int pitch = pack.ReadCell();
	if (client > 0 && IsClientInGame(client))
	{
		ZTW_EmitStock(client, volume, pitch);
	}
	return Plugin_Stop;
}

public Action Timer_StockStop(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client))
	{
		StopSound(client, SNDCHAN_AUTO, g_sStock);
	}
	return Plugin_Stop;
}

public void OnMapEnd()
{
	ZTW_EndThrowCycle();
}

public void OnClientDisconnect(int client)
{
	ZTW_ResetClientAlarms(client);
	if (client == g_iAimWarnClient)
	{
		g_iAimWarnClient = -1;
	}

	if (client == g_iActiveTank)
	{
		ZTW_EndThrowCycle();
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (!g_cvEnabled.BoolValue)
	{
		return;
	}

	if (StrEqual(classname, "tank_rock", false))
	{
		g_iActiveRock = entity;
		ZTW_EnsureAimTimer();
	}
}

public Action L4D_OnCThrowActivate(int ability)
{
	if (!g_cvEnabled.BoolValue || ability <= 0 || !IsValidEntity(ability))
	{
		return Plugin_Continue;
	}

	int tank = ZTW_FindTankByAbility(ability);
	if (tank == -1)
	{
		tank = ZTW_FindAnyTank();
	}

	if (tank != -1)
	{
		g_iActiveTank = tank;
		ZTW_EnsureAimTimer();
	}

	return Plugin_Continue;
}

public void L4D_TankRock_OnRelease_Post(int tank, int rock, const float vecPos[3],
	const float vecAng[3], const float vecVel[3], const float vecRot[3])
{
	if (!g_cvEnabled.BoolValue)
	{
		return;
	}

	g_iActiveRock = rock;

	int launchClient = g_iAimWarnClient;
	if (launchClient == -1 || !ZTW_IsLiveSurvivor(launchClient))
	{
		launchClient = ZTW_FindAimTarget(tank, vecAng);
	}

	if (launchClient != -1)
	{
		if (g_cvLaunchAlarm.BoolValue)
		{
			ZTW_TryPlayAlarm(launchClient, ZTW_Phase_Launch);
		}
	}

	ZTW_StopAimMonitoring();
}

public void L4D_TankRock_OnDetonate(int tank, int rock)
{
	if (!g_cvEnabled.BoolValue)
	{
		return;
	}

	if (g_iActiveRock != -1 && rock != g_iActiveRock)
	{
		return;
	}

	ZTW_EndThrowCycle();
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	ZTW_EndThrowCycle();
	return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	ZTW_EndThrowCycle();
	return Plugin_Continue;
}

void ZTW_EnsureAimTimer()
{
	if (g_hAimTimer != null)
	{
		return;
	}

	float interval = g_cvPollInterval.FloatValue;
	if (interval < 0.05)
	{
		interval = 0.05;
	}

	g_hAimTimer = CreateTimer(interval, Timer_CheckAim, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_CheckAim(Handle timer)
{
	if (!g_cvEnabled.BoolValue)
	{
		ZTW_EndThrowCycle();
		return Plugin_Stop;
	}

	if (g_iActiveTank <= 0 || !ZTW_IsLiveTank(g_iActiveTank))
	{
		if (g_iActiveRock <= 0 || !IsValidEntity(g_iActiveRock))
		{
			ZTW_EndThrowCycle();
			return Plugin_Stop;
		}

		g_iActiveTank = ZTW_FindAnyTank();
		if (g_iActiveTank == -1)
		{
			ZTW_EndThrowCycle();
			return Plugin_Stop;
		}
	}

	float tankAngles[3];
	GetClientEyeAngles(g_iActiveTank, tankAngles);

	int target = ZTW_FindAimTarget(g_iActiveTank, tankAngles);
	if (target != -1)
	{
		g_iAimWarnClient = target;
		ZTW_TryPlayAlarm(target, ZTW_Phase_Aim);
	}

	return Plugin_Continue;
}

void ZTW_ResetClientAlarms(int client)
{
	for (int phase = 0; phase < view_as<int>(ZTW_Phase_COUNT); phase++)
	{
		g_bAlarmPlayed[client][phase] = false;
	}
}

void ZTW_ResetAllAlarms()
{
	for (int client = 1; client <= MAXPLAYERS; client++)
	{
		ZTW_ResetClientAlarms(client);
	}
}

void ZTW_StopAimMonitoring()
{
	g_iActiveTank = -1;

	if (g_hAimTimer != null)
	{
		delete g_hAimTimer;
		g_hAimTimer = null;
	}
}

void ZTW_EndThrowCycle()
{
	g_iAimWarnClient = -1;
	g_iActiveRock = -1;
	ZTW_StopAimMonitoring();
	ZTW_ResetAllAlarms();
}

void ZTW_TryPlayAlarm(int client, ZTW_AlarmPhase phase)
{
	if (!ZTW_IsLiveSurvivor(client) || !g_bPrefsReady)
	{
		return;
	}

	if (!ZF_GetClientPrefInt(client, PREF_ENABLED, 1))
	{
		return;
	}

	if (g_bAlarmPlayed[client][phase])
	{
		return;
	}

	float volume = ZF_GetClientPrefFloat(client, PREF_VOLUME, 0.85);
	if (volume < 0.0)
	{
		volume = 0.0;
	}
	else if (volume > 1.0)
	{
		volume = 1.0;
	}

	if (volume <= 0.01)
	{
		g_bAlarmPlayed[client][phase] = true;
		return;
	}

	ZTW_PlayWarningSound(client, volume, phase);
	g_bAlarmPlayed[client][phase] = true;
}

int ZTW_FindTankByAbility(int ability)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!ZTW_IsLiveTank(client))
		{
			continue;
		}

		if (GetEntPropEnt(client, Prop_Send, "m_customAbility") == ability)
		{
			return client;
		}
	}

	return -1;
}

int ZTW_FindAnyTank()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (ZTW_IsLiveTank(client))
		{
			return client;
		}
	}

	return -1;
}

bool ZTW_IsLiveTank(int client)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return false;
	}

	if (L4D_GetClientTeam(client) != L4DTeam_Infected)
	{
		return false;
	}

	return L4D2_GetPlayerZombieClass(client) == L4D2ZombieClass_Tank;
}

bool ZTW_IsLiveSurvivor(int client)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return false;
	}

	return L4D_GetClientTeam(client) == L4DTeam_Survivor;
}

int ZTW_FindAimTarget(int tank, const float tankAngles[3])
{
	if (!ZTW_IsLiveTank(tank))
	{
		return -1;
	}

	float tankEye[3];
	float tankForward[3];
	GetClientEyePosition(tank, tankEye);
	GetAngleVectors(tankAngles, tankForward, NULL_VECTOR, NULL_VECTOR);

	float cosThreshold = Cosine(DegToRad(g_cvAimAngle.FloatValue));
	int bestTarget = -1;
	float bestDist = 0.0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!ZTW_IsLiveSurvivor(client))
		{
			continue;
		}

		float targetPos[3];
		GetClientAbsOrigin(client, targetPos);
		targetPos[2] += 45.0;

		float toTarget[3];
		SubtractVectors(targetPos, tankEye, toTarget);

		float dist = NormalizeVector(toTarget, toTarget);
		if (dist <= 1.0)
		{
			continue;
		}

		float dot = GetVectorDotProduct(tankForward, toTarget);
		if (dot < cosThreshold)
		{
			continue;
		}

		if (bestTarget == -1 || dist < bestDist)
		{
			bestTarget = client;
			bestDist = dist;
		}
	}

	return bestTarget;
}

void ZTW_PrecacheStock()
{
	char raw[PLATFORM_MAX_PATH];
	g_cvStockSound.GetString(raw, sizeof(raw));
	TrimString(raw);
	if (StrContains(raw, "sound/", false) == 0 || StrContains(raw, "sound\\", false) == 0)
	{
		strcopy(g_sStock, sizeof(g_sStock), raw[6]);
	}
	else if (raw[0] != '\0')
	{
		strcopy(g_sStock, sizeof(g_sStock), raw);
	}
	else
	{
		strcopy(g_sStock, sizeof(g_sStock), SOUND_STOCK_DEFAULT);
	}
	PrecacheSound(g_sStock, true);
}

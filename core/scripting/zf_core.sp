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
 * Zombie Foundry Core — shared framework for custom SourceMod plugins.
 *
 * Exposes ClientPrefs helpers for dependent plugins. MOTD/HTML and DBI
 * wrappers are planned for later sessions.
 *
 * Dependent plugins should #include <zf_core>, hook ZF_OnCoreReady, or check
 * LibraryExists("zf_core").
 */

#include <sourcemod>
#include <clientprefs>

#pragma semicolon 1
#pragma newdecls required

#define ZF_CORE_VERSION "0.2.0"
#define ZF_CORE_LIBRARY "zf_core"

public Plugin myinfo =
{
	name = "Zombie Foundry Core",
	author = "Zombie Foundry",
	description = "Shared framework for ZF custom plugins (MOTD, prefs, storage)",
	version = ZF_CORE_VERSION,
	url = ""
};

GlobalForward g_fwdCoreReady = null;
StringMap g_CookieRegistry = null;
StringMap g_CookieDefaults = null;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("ZF_RegisterClientPref", Native_RegisterClientPref);
	CreateNative("ZF_GetClientPrefString", Native_GetClientPrefString);
	CreateNative("ZF_SetClientPrefString", Native_SetClientPrefString);
	CreateNative("ZF_GetClientPrefInt", Native_GetClientPrefInt);
	CreateNative("ZF_SetClientPrefInt", Native_SetClientPrefInt);
	CreateNative("ZF_GetClientPrefFloat", Native_GetClientPrefFloat);
	CreateNative("ZF_SetClientPrefFloat", Native_SetClientPrefFloat);

	RegPluginLibrary(ZF_CORE_LIBRARY);
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_fwdCoreReady = CreateGlobalForward("ZF_OnCoreReady", ET_Ignore);
	g_CookieRegistry = new StringMap();
	g_CookieDefaults = new StringMap();

	ZF_FireCoreReady();
}

public void OnPluginEnd()
{
	delete g_CookieRegistry;
	delete g_CookieDefaults;
}

/**
 * Called when Core is loaded and ready for dependent plugins.
 * Params: none
 */
void ZF_FireCoreReady()
{
	Call_StartForward(g_fwdCoreReady);
	Call_Finish();
}

bool ZF_IsValidClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}

bool ZF_GetRegisteredCookie(const char[] key, Cookie &cookie)
{
	if (g_CookieRegistry.GetValue(key, cookie))
	{
		return true;
	}

	cookie = FindClientCookie(key);
	return cookie != null;
}

bool ZF_GetDefaultValue(const char[] key, char[] buffer, int maxlen)
{
	if (g_CookieDefaults.GetString(key, buffer, maxlen) && buffer[0] != '\0')
	{
		return true;
	}

	buffer[0] = '\0';
	return false;
}

void ZF_ReadCookieString(int client, Cookie cookie, const char[] key, const char[] fallback, char[] buffer, int maxlen)
{
	cookie.Get(client, buffer, maxlen);

	if (buffer[0] != '\0')
	{
		return;
	}

	if (ZF_GetDefaultValue(key, buffer, maxlen) && buffer[0] != '\0')
	{
		return;
	}

	strcopy(buffer, maxlen, fallback);
}

public int Native_RegisterClientPref(Handle plugin, int numParams)
{
	char key[COOKIE_MAX_NAME_LENGTH + 1];
	GetNativeString(1, key, sizeof(key));

	if (key[0] == '\0')
	{
		return false;
	}

	char description[COOKIE_MAX_DESCRIPTION_LENGTH + 1];
	GetNativeString(2, description, sizeof(description));

	CookieAccess access = GetNativeCell(3);

	char defaultValue[256];
	GetNativeString(4, defaultValue, sizeof(defaultValue));

	Cookie cookie;
	if (g_CookieRegistry.GetValue(key, cookie))
	{
		g_CookieDefaults.SetString(key, defaultValue);
		return true;
	}

	cookie = RegClientCookie(key, description, access);
	if (cookie == null)
	{
		return false;
	}

	g_CookieRegistry.SetValue(key, cookie);
	g_CookieDefaults.SetString(key, defaultValue);
	return true;
}

public int Native_GetClientPrefString(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);

	char key[COOKIE_MAX_NAME_LENGTH + 1];
	GetNativeString(2, key, sizeof(key));

	int maxlen = GetNativeCell(4);

	char fallback[256];
	GetNativeString(5, fallback, sizeof(fallback));

	if (!ZF_IsValidClient(client))
	{
		return false;
	}

	Cookie cookie;
	if (!ZF_GetRegisteredCookie(key, cookie))
	{
		SetNativeString(3, fallback, maxlen);
		return false;
	}

	char buffer[256];
	ZF_ReadCookieString(client, cookie, key, fallback, buffer, sizeof(buffer));
	SetNativeString(3, buffer, maxlen);
	return true;
}

public int Native_SetClientPrefString(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);

	char key[COOKIE_MAX_NAME_LENGTH + 1];
	GetNativeString(2, key, sizeof(key));

	char value[256];
	GetNativeString(3, value, sizeof(value));

	if (!ZF_IsValidClient(client))
	{
		return false;
	}

	Cookie cookie;
	if (!ZF_GetRegisteredCookie(key, cookie))
	{
		return false;
	}

	cookie.Set(client, value);
	return true;
}

public int Native_GetClientPrefInt(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);

	char key[COOKIE_MAX_NAME_LENGTH + 1];
	GetNativeString(2, key, sizeof(key));

	int fallback = GetNativeCell(3);

	if (!ZF_IsValidClient(client))
	{
		return fallback;
	}

	Cookie cookie;
	if (!ZF_GetRegisteredCookie(key, cookie))
	{
		return fallback;
	}

	char buffer[32];
	ZF_ReadCookieString(client, cookie, key, "", buffer, sizeof(buffer));

	if (buffer[0] == '\0')
	{
		return fallback;
	}

	int value;
	if (!StringToIntEx(buffer, value))
	{
		return fallback;
	}

	return value;
}

public int Native_SetClientPrefInt(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);

	char key[COOKIE_MAX_NAME_LENGTH + 1];
	GetNativeString(2, key, sizeof(key));

	int value = GetNativeCell(3);

	if (!ZF_IsValidClient(client))
	{
		return false;
	}

	Cookie cookie;
	if (!ZF_GetRegisteredCookie(key, cookie))
	{
		return false;
	}

	cookie.SetInt(client, value);
	return true;
}

public int Native_GetClientPrefFloat(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);

	char key[COOKIE_MAX_NAME_LENGTH + 1];
	GetNativeString(2, key, sizeof(key));

	float fallback = view_as<float>(GetNativeCell(3));

	if (!ZF_IsValidClient(client))
	{
		return view_as<int>(fallback);
	}

	Cookie cookie;
	if (!ZF_GetRegisteredCookie(key, cookie))
	{
		return view_as<int>(fallback);
	}

	char buffer[32];
	ZF_ReadCookieString(client, cookie, key, "", buffer, sizeof(buffer));

	if (buffer[0] == '\0')
	{
		return view_as<int>(fallback);
	}

	float value;
	if (!StringToFloatEx(buffer, value))
	{
		return view_as<int>(fallback);
	}

	return view_as<int>(value);
}

public int Native_SetClientPrefFloat(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);

	char key[COOKIE_MAX_NAME_LENGTH + 1];
	GetNativeString(2, key, sizeof(key));

	float value = view_as<float>(GetNativeCell(3));

	if (!ZF_IsValidClient(client))
	{
		return false;
	}

	Cookie cookie;
	if (!ZF_GetRegisteredCookie(key, cookie))
	{
		return false;
	}

	cookie.SetFloat(client, value);
	return true;
}

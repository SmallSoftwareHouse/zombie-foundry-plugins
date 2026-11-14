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
 * Zombie Foundry Core — public API for dependent SourceMod plugins.
 *
 * Include this file, ensure zf_core.smx is loaded, then hook ZF_OnCoreReady or
 * call ZF_IsCoreLoaded() before using natives.
 *
 * Example (child plugin):
 *
 *   #include <zf_core>
 *
 *   #define PREF_TANK_WARN "zf_tank_warning_enabled"
 *
 *   public void OnPluginStart()
 *   {
 *       if (!ZF_IsCoreLoaded())
 *           SetFailState("Zombie Foundry Core (zf_core) is required.");
 *   }
 *
 *   public void ZF_OnCoreReady()
 *   {
 *       ZF_RegisterClientPref(PREF_TANK_WARN, "Tank warning alerts", CookieAccess_Public, "1");
 *   }
 *
 *   void OnTankAim(int client)
 *   {
 *       if (!ZF_GetClientPrefInt(client, PREF_TANK_WARN, 1))
 *           return;
 *       // ...
 *   }
 */

#if defined _zf_core_included
 #endinput
#endif
#define _zf_core_included

#include <sourcemod>
#include <clientprefs>

#define ZF_CORE_LIBRARY "zf_core"

/**
 * Called when Core has registered its library and natives.
 * Hook this forward to register ClientPrefs or run other setup that
 * depends on ZF_RegisterClientPref.
 */
forward void ZF_OnCoreReady();

/**
 * Returns true if the zf_core plugin library is loaded.
 */
stock bool ZF_IsCoreLoaded()
{
	return LibraryExists(ZF_CORE_LIBRARY);
}

/**
 * Register a ClientPrefs cookie through Core (idempotent per key).
 *
 * @param key           Unique cookie name (max 30 chars per SourceMod).
 * @param description   Human-readable description for SM cookie menus.
 * @param access        CookieAccess level (Public / Protected / Private).
 * @param defaultValue  Value returned by getters when the cookie is unset.
 * @return              True on success, false if key is empty or registration failed.
 */
native bool ZF_RegisterClientPref(const char[] key, const char[] description, CookieAccess access, const char[] defaultValue = "");

/**
 * Read a string preference. Falls back to the registered default, then to
 * defaultValue if the cookie was never registered with Core.
 */
native bool ZF_GetClientPrefString(int client, const char[] key, char[] buffer, int maxlen, const char[] defaultValue = "");

/**
 * Write a string preference.
 */
native bool ZF_SetClientPrefString(int client, const char[] key, const char[] value);

/**
 * Read an integer preference.
 */
native int ZF_GetClientPrefInt(int client, const char[] key, int defaultValue = 0);

/**
 * Write an integer preference.
 */
native bool ZF_SetClientPrefInt(int client, const char[] key, int value);

/**
 * Read a float preference.
 */
native float ZF_GetClientPrefFloat(int client, const char[] key, float defaultValue = 0.0);

/**
 * Write a float preference.
 */
native bool ZF_SetClientPrefFloat(int client, const char[] key, float value);

public SharedPlugin __pl_zf_core =
{
	name = "zf_core",
	file = "zf_core.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_zf_core_SetNTVOptional()
{
	MarkNativeAsOptional("ZF_RegisterClientPref");
	MarkNativeAsOptional("ZF_GetClientPrefString");
	MarkNativeAsOptional("ZF_SetClientPrefString");
	MarkNativeAsOptional("ZF_GetClientPrefInt");
	MarkNativeAsOptional("ZF_SetClientPrefInt");
	MarkNativeAsOptional("ZF_GetClientPrefFloat");
	MarkNativeAsOptional("ZF_SetClientPrefFloat");
}
#endif

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
 * Zombie Foundry — Stripper Map Editor
 *
 * Moves the map's items in game and writes the layout for Stripper:Source: editor entry and exit,
 * Stripper dump and object list, grab and release, steps (with a see-through copy visible only to
 * the editor), per-author undo and redo, saves, and publishing into the plugin's zone of
 * addons/stripper/maps/<map>.cfg.
 *
 * Access: the owner, plus the SteamIDs in addons/zombiefoundry/authorized.txt (one per line,
 * STEAM_1:0:123 or [U:1:123]), a list written by the tool. Every editor action goes to the SourceMod
 * log (lines starting with "[editor]").
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#undef REQUIRE_PLUGIN
#include <adminmenu>

#define PLUGIN_VERSION "0.63.1"
// Zombie Foundry folder on the server: addons/zombiefoundry, next to sourcemod. The paths are
// relative to addons/sourcemod, hence the "../". The published file goes into stripper/maps.
#define DATA_FOLDER  "../zombiefoundry/stripper-map-editor"
#define FILE_AUTHORIZED "../zombiefoundry/authorized.txt"
#define FILE_OWNER "../zombiefoundry/owner.txt"
#define FILE_REQUESTS "../zombiefoundry/access-requests.txt"
#define DUMP_FOLDER  "addons/stripper/dumps"
#define MAPS_FOLDER "addons/stripper/maps"
#define HEADER_BEGIN "// ===== Published with Stripper Map Editor (Zombie Foundry) ====="
#define HEADER_END   "// ============================================================"
#define ZONE_BEGIN "// ---- BEGIN Stripper Map Editor: plugin zone, do not edit by hand ----"
#define ZONE_END   "// ---- END Stripper Map Editor ----"
#define BLOCK_MAX 4096
#define UNITS_TO_METRES 0.01905

#define DIST_MIN  32.0
#define DIST_MAX  1024.0
#define DIST_STEP 8.0

public Plugin myinfo =
{
	name        = "Zombie Foundry - Stripper Map Editor",
	author      = "Zombie Foundry",
	description = "Moves the map objects and writes the Stripper file",
	version     = PLUGIN_VERSION,
	url         = ""
};

// Cooperative mode: several people in the editor together, each with their own state. Who is
// inside: g_bInEditor; an object chosen by one is locked for the others (InUsoDa).
#define MAX_EDITORS 4
// Coloured marks of the cooperative mode
bool g_bCoopMarks = true;
bool  g_bInEditor[MAXPLAYERS + 1];
int   g_iStart;                        // when the server started (seconds since 1970)
bool  g_bCooperative = false;          // server setting: the owner changes it
int   g_iLastActor;                 // who acted last (HUD panel, file headers)
int g_iMarkYellow[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
int g_iMarkRed[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
int g_iMarkOf[MAXPLAYERS + 1] = { -1, ... };      // object that editor's marks are on
int g_iMarkOwner[2049];
StringMap g_smGroup;                  // entref -> collision group before it became untouchable
StringMap g_smDropping;                    // hammerid -> who is dropping it (locked for the others too)
StringMap g_smSignal;                 // hammerid -> number of that object's last signal: only that one counts
StringMap g_smLeft;        // Steam2 -> when they left the server while in the editor
StringMap g_smLeftTemp;    // Steam2 -> had temporary access
bool  g_bAwaitingName[MAXPLAYERS + 1];  // waiting in chat for the name of the save
float g_fStart[MAXPLAYERS + 1][3];                // where the editor was on entering
MoveType g_mtStart[MAXPLAYERS + 1];

// Objects read from the dump: one row per object
ArrayList g_aHammer;                 // int: hammerid (0 = missing)
ArrayList g_aKind;                   // string: readable name
ArrayList g_aModel;                // string: model to show
ArrayList g_aOrigin;                // float[3]: position in the current map (from the dump)
ArrayList g_aAngLoaded;                // float[3]: rotation in the current map
ArrayList g_aReal;                   // float[3]: real original position (never deleted)
ArrayList g_aAngReal;                // float[3]: real original rotation
ArrayList g_aBlock;                 // string: dump lines without origin and angles
ArrayList g_aPos;                    // float[3]: current position in the editor
ArrayList g_aAng;                    // float[3]: current rotation
ArrayList g_aCopy;                  // int: entref of the ghost (INVALID_ENT_REFERENCE)
ArrayList g_aEnt;                    // int: entref of the real object in the map
ArrayList g_aSurvival;               // bool: targetname weapons_survival
int g_iChosen[MAXPLAYERS + 1] = { -1, ... };                  // index of the selected object

// Return points: one row per move, with the state BEFORE the move { hammerid, pos[3], ang[3] }.
// Undo removes the last row and puts that state back.
ArrayList g_aHistory;
ArrayList g_aRedo;                  // undone moves that can be redone { hammerid, pos[3], ang[3], author }
float g_fRedoPos[3], g_fRedoAng[3];
ArrayList g_aSnapPos;                // float[3]: positions at the last personal save or autosave
ArrayList g_aSnapAng;
int g_iMovesSnapshot;                // history length at the last "Save my work" or autosave
int g_iAutosaveMin;                  // autosave every N minutes (0 = off); server setting
int g_iLastAutosave;
char g_sEditorId[MAXPLAYERS + 1][32];                // SteamID64 of the editor: goes into the file headers
char g_sEditorName[MAXPLAYERS + 1][64];
int g_iMovesSaved;                 // history length at the last Save
float g_fBeforePos[MAXPLAYERS + 1][3], g_fBeforeAng[MAXPLAYERS + 1][3];  // state when grabbing

bool  g_bNoclipAtGrab[MAXPLAYERS + 1];                // how noclip was when the object was grabbed
bool  g_bGrabbed[MAXPLAYERS + 1] = { false, ... };          // the copy follows the view
int   g_iPreview[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };  // floor projection of the object in hand
int   g_iBeam[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };     // column of light between object and projection
int   g_iAnchorA[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };   // invisible points it is attached to (top, floor)
int   g_iAnchorB[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
float g_vCentre[MAXPLAYERS + 1][3];                 // from the origin to the object's centre, in world coordinates
float g_fNextBeam[MAXPLAYERS + 1];
bool  g_bNoclip[MAXPLAYERS + 1] = { false, ... };
bool  g_bFineMove[MAXPLAYERS + 1];                       // fine move: WASD moves the object
bool  g_bFineMoved[MAXPLAYERS + 1];                  // there is a fine move not recorded yet
float g_fFineYaw[MAXPLAYERS + 1];                    // fixed axes of the fine move
bool  g_bWallAligned[MAXPLAYERS + 1];              // the fixed axes come from a wall, not from the map
bool  g_bWallChoice[MAXPLAYERS + 1];                 // choosing the wall by looking at it
bool  g_bLeftBeforeWall[MAXPLAYERS + 1], g_bRightBeforeWall[MAXPLAYERS + 1];
float g_fNextWall[MAXPLAYERS + 1];
bool  g_bRotate[MAXPLAYERS + 1];                      // rotation: the mouse rotates the object
bool  g_bPaused[MAXPLAYERS + 1];                      // pause of fine move/rotation: the editor walks freely
int   g_iListPage[MAXPLAYERS + 1];               // list page the object was chosen from
bool  g_bFromList[MAXPLAYERS + 1];                   // the object was chosen from the list (not by looking)
int   g_iDropsRunning;              // physics copies currently falling
ArrayList g_aFilled[MAXPLAYERS + 1];  // hammerids already added to the current pile, per editor
int   g_iPose[MAXPLAYERS + 1] = { -1, ... };                  // last standard pose chosen (-1 none)
static const char POSE_NAMES[][] = { "pose_flat", "pose_flat_inv", "pose_side", "pose_side_other", "pose_upright", "pose_upright_inv" };
float g_fNoMenu[MAXPLAYERS + 1];                  // how long the editor has had no menu on screen
int   g_iMenuOpen[MAXPLAYERS + 1];                 // 2 = object menu open (its title updates by itself)
char  g_sLastTitle[MAXPLAYERS + 1][384];
bool  g_bCombo[MAXPLAYERS + 1];                      // "Move and rotate": WASD moves, mouse rotates
bool  g_bCrossTurn[MAXPLAYERS + 1];                 // in "Move and rotate" cross and circle take turns
bool  g_bJumpBefore[MAXPLAYERS + 1];
int   g_iLevelModel;
bool  g_bRotateMoved[MAXPLAYERS + 1];                 // there is a rotation not recorded yet
int   g_iAxis[MAXPLAYERS + 1] = { 1, ... };                   // active axis: 0 pitch, 1 yaw, 2 roll
float g_fRotateDirection[MAXPLAYERS + 1] = { 1.0, ... };           // direction of the last rotation (for snapping)
bool  g_bLeftBefore[MAXPLAYERS + 1], g_bRightBefore[MAXPLAYERS + 1];
float g_fNextLevel[MAXPLAYERS + 1];
float g_fFlashUntil[MAXPLAYERS + 1];                  // until when the level flashes
bool  g_bFlashStrong[MAXPLAYERS + 1];                 // flash at 90 degrees
float g_vAxis[MAXPLAYERS + 1][3];                    // rotation pivot, fixed in the world
float g_vU[MAXPLAYERS + 1][3], g_vW[MAXPLAYERS + 1][3];              // plane of the circle (perpendicular to the pivot)
float g_fTurn[MAXPLAYERS + 1];                       // angle on the pivot (for steps and flashes)
#define VIEW_ROTATION 2.0          // object degrees per degree of view
#define WHEEL_STEP 16.0         // units per mouse wheel step

bool  g_bHud;
bool  g_bRuler;
bool  g_bExplosions;                 // test: explosives can explode (off on every entry)
int   g_iBlocked[MAXPLAYERS + 1] = { -1, ... };                // object looked at that does not move in faithful mode
bool  g_bDestroyed;                  // a map object exploded: the reset reloads the map
int   g_iLooked[MAXPLAYERS + 1] = { -1, ... };              // object lit because it is looked at
float g_fNextLook[MAXPLAYERS + 1];
bool  g_bUseBefore[MAXPLAYERS + 1];                      // material of the line to the floor
int   g_iSpeed[MAXPLAYERS + 1] = { 2, ... };               // index into VELOCITA (starts at normal)
float g_fDistance[MAXPLAYERS + 1] = { 128.0, ... };

static const float STEPS[] = { 1.0, 5.0, 10.0, 50.0 };
int g_iStep[MAXPLAYERS + 1] = { 1, ... };                    // index into PASSI (starts at 5)

// Player settings: the bottom hints can be switched off; the choice stays saved (cookie) from one
// game to the next.
bool   g_bHintOff[MAXPLAYERS + 1];
bool   g_bPanelOff[MAXPLAYERS + 1];
Cookie g_ckHint;
Cookie g_ckPanel;
// Editor language chosen in the settings: 0 = the game's, 1 = English, 2 = Italian. Only that
// player's SourceMod language changes.
int    g_iLanguage[MAXPLAYERS + 1];
int    g_iSettingsPage[MAXPLAYERS + 1];   // settings section: 0 index, 1 work, 2 appearance, 3 server
int    g_iGameLanguage[MAXPLAYERS + 1] = { -1, ... };
Cookie g_ckLanguage;
int  g_iRawButtons[MAXPLAYERS + 1];
bool g_bRedoHintShown[MAXPLAYERS + 1];
char g_sWalkKey[MAXPLAYERS + 1][16];
bool g_bReserved;                    // server reserved during the map maintenance (see StartPanel)
static const char LANGUAGE_NAMES[][] = { "", "Deutsch", "English", "Español", "Français", "Italiano", "Русский" };
static const char LANGUAGE_CODES[][] = { "", "de", "en", "es", "fr", "it", "ru" };

// Map mode: faithful = only the objects the game lets move can be moved, dropped ones fall with
// physics, and on entry the objects not part of the map are removed; free = everything moves. It
// applies to the whole server.
bool g_bFreeMode = false;
bool g_bEditorOpen = true;           // the owner can close the editor to everyone else
// The editor's own chat triggers, single keys on most keyboards (no Shift, unlike "!"): "-", "." and
// ",", all always accepted, as SourceMod's "!" and "/". Inside the command "-" and "_" both work.
static const char TRIGGERS[] = "-.,";
#define FILE_SETTINGS "../zombiefoundry/stripper-map-editor/settings.txt"

void LoadServerSettings()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), FILE_SETTINGS);
	KeyValues kv = new KeyValues("Settings");
	if (kv.ImportFromFile(sPath))
	{
		char sMode[16];
		kv.GetString("mode", sMode, sizeof(sMode), "faithful");
		g_bFreeMode = StrEqual(sMode, "free");
		g_iAutosaveMin = kv.GetNum("autosave", 0);
		g_bEditorOpen = kv.GetNum("editor_open", 1) != 0;
		g_bCooperative = kv.GetNum("cooperative", 0) != 0;
		// The cooperative mode starts off on every server start. The start is told by when the process
		// started: reloading the plugin or changing map does not switch it off.
		int started = GetTime() - RoundToFloor(GetEngineTime());
		int saved = kv.GetNum("start", 0);
		if (saved == 0)               // first time with this version: only the start is noted
		{
			g_iStart = started;
			delete kv;
			SaveServerSettings();
			return;
		}
		if (started - saved > 60 || saved - started > 60)
		{
			if (g_bCooperative)
				LogMessage("[editor] server restarted: cooperative mode off");
			g_bCooperative = false;
			g_iStart = started;
			delete kv;
			SaveServerSettings();
			return;
		}
		g_iStart = saved;
	}
	else
		g_iStart = GetTime() - RoundToFloor(GetEngineTime());
	delete kv;
}

void SaveServerSettings()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), FILE_SETTINGS);
	KeyValues kv = new KeyValues("Settings");
	kv.SetString("mode", g_bFreeMode ? "free" : "faithful");
	kv.SetNum("autosave", g_iAutosaveMin);
	kv.SetNum("editor_open", g_bEditorOpen ? 1 : 0);
	kv.SetNum("cooperative", g_bCooperative ? 1 : 0);
	kv.SetNum("start", g_iStart);
	kv.ExportToFile(sPath);
	delete kv;
}

// In faithful mode only these types move; in free mode all
bool IsMovable(int i)
{
	if (g_bFreeMode)
		return true;
	char sKey[64];
	g_aKind.GetString(i, sKey, sizeof(sKey));
	static const char FAITHFUL_TYPES[][] = { "type_medkit", "type_pills", "type_adrenaline", "type_defib", "type_molotov",
		"type_pipebomb", "type_bile", "type_ammo_incendiary", "type_ammo_explosive", "type_gascan", "type_propane",
		"type_oxygen", "type_fireworks" };
	for (int k = 0; k < sizeof(FAITHFUL_TYPES); k++)
		if (StrEqual(sKey, FAITHFUL_TYPES[k]))
			return true;
	return false;
}

// Faithful mode: the objects dropped on the floor that are not part of the map are removed (for
// example medkits left by bots): game items without "_spawn" that nobody holds. Weapons, gas cans
// and the like are not touched: they can belong to the map.
int CleanMap(int client)
{
	static const char TO_REMOVE[][] = { "weapon_first_aid_kit", "weapon_pain_pills", "weapon_adrenaline",
		"weapon_defibrillator", "weapon_molotov", "weapon_pipe_bomb", "weapon_vomitjar",
		"weapon_upgradepack_incendiary", "weapon_upgradepack_explosive" };
	int n = 0;
	for (int k = 0; k < sizeof(TO_REMOVE); k++)
	{
		int e = -1;
		while ((e = FindEntityByClassname(e, TO_REMOVE[k])) != -1)
		{
			if (GetEntPropEnt(e, Prop_Data, "m_hOwnerEntity") != -1)
				continue;
			RemoveEntity(e);
			n++;
		}
	}
	if (n > 0)
	{
		LogEditor(client, "map cleanup: removed %d objects not part of the map", n);
		Chat(client, "cleanup_done", n);
	}
	return n;
}

void ApplyLanguage(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
		return;
	if (g_iGameLanguage[client] == -1)
		g_iGameLanguage[client] = GetClientLanguage(client);
	int l = (g_iLanguage[client] == 0) ? g_iGameLanguage[client] : GetLanguageByCode(LANGUAGE_CODES[g_iLanguage[client]]);
	if (l != -1)
		SetClientLanguage(client, l);
}

// ---------------------------------------------------------------- translations
// The phrases are in translations/zf_stripper_map_editor.phrases.txt. Tr writes the phrase in the
// player's language (client 0 = the server's language); the real keys in the hints (%+use% and so
// on) are filled in by the game. The HUD panel is the same for everyone and uses the language of
// whoever acted last in the editor.
void Tr(char[] out, int len, int client, const char[] key, any ...)
{
	#pragma unused key
	SetGlobalTransTarget(client);
	VFormat(out, len, "%t", 4);
}

// Chat message with the [ZF] prefix: Chat(client, "key", parameters...)
void Chat(int client, const char[] key, any ...)
{
	#pragma unused key
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
		return;
	char sText[320];
	SetGlobalTransTarget(client);
	VFormat(sText, sizeof(sText), "[ZF] %t", 2);
	PrintToChat(client, "%s", sText);
}

void ChatAll(const char[] key)
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && !IsFakeClient(i))
			Chat(i, key);
}

// Bottom hint, skipped if the player switched hints off: Hint(client, "key", ...)
void Hint(int client, const char[] key, any ...)
{
	#pragma unused key
	if (client < 1 || client > MaxClients || g_bHintOff[client])
		return;
	char sText[512];
	SetGlobalTransTarget(client);
	VFormat(sText, sizeof(sText), "%t", 2);
	PrintHintText(client, "%s", sText);
}

// Menu log: every menu that opens and every key pressed go to the SourceMod log, to follow the steps
// from one menu to another without screenshots.
float g_fLastChoice[MAXPLAYERS + 1];               // when a menu key was pressed
float g_fMainMenuTime[MAXPLAYERS + 1];          // when the main menu opened

void LogChoice(Menu m, int client, int item, const char[] name)
{
	g_fLastChoice[client] = GetGameTime();
	char sInfo[32], sText[128];
	m.GetItem(item, sInfo, sizeof(sInfo), _, sText, sizeof(sText));
	LogMessage("[editor] [menu] %N: %s, key %d = %s (%s)", client, name, item + 1, sText, sInfo);
}

// Translated menu item
void MenuEntry(Menu m, int client, const char[] info, const char[] key, int style = ITEMDRAW_DEFAULT)
{
	char sText[128];
	Tr(sText, sizeof(sText), client, key);
	m.AddItem(info, sText, style);
}

// Like Hint, but with a text already translated
void HintRaw(int client, const char[] text)
{
	if (client < 1 || client > MaxClients || g_bHintOff[client])
		return;
	PrintHintText(client, "%s", text);
}

public void OnClientCookiesCached(int client)
{
	char sVal[8];
	g_ckHint.Get(client, sVal, sizeof(sVal));
	g_bHintOff[client] = StrEqual(sVal, "0");
	g_ckPanel.Get(client, sVal, sizeof(sVal));
	g_bPanelOff[client] = StrEqual(sVal, "0");
	g_ckLanguage.Get(client, sVal, sizeof(sVal));
	// the cookie holds the language code ("de", "en"...); "1" and "2" are the values before 0.62 (en, it)
	if (StrEqual(sVal, "1"))
		strcopy(sVal, sizeof(sVal), "en");
	else if (StrEqual(sVal, "2"))
		strcopy(sVal, sizeof(sVal), "it");
	g_iLanguage[client] = 0;
	for (int i = 1; i < sizeof(LANGUAGE_CODES); i++)
		if (sVal[0] != '\0' && StrEqual(sVal, LANGUAGE_CODES[i]))
			g_iLanguage[client] = i;
	if (g_iLanguage[client] != 0)
		ApplyLanguage(client);
}

public void OnPluginStart()
{
	LoadTranslations("zf_stripper_map_editor.phrases");
	LoadServerSettings();
	ReadReentry();
	HookEvent("player_hurt", Event_Damage);
	HookEvent("player_disconnect", Event_Disconnect);
	// Team log: to understand a player who came back as a spectator after a map change
	HookEvent("player_team", Event_Team);
	HookEvent("player_bot_replace", Event_Idle);      // a player goes idle: a bot takes their place
	HookEvent("bot_player_replace", Event_Resume);      // the player takes their survivor back
	CreateTimer(20.0, Timer_Autosave, _, TIMER_REPEAT);
	AddCommandListener(Cmd_ChatName, "say");
	AddCommandListener(Cmd_ChatName, "say_team");
	g_ckHint = new Cookie("zf_sme_hints", "Suggerimenti in basso dello Stripper Map Editor", CookieAccess_Protected);
	g_ckLanguage = new Cookie("zf_sme_language", "Lingua dello Stripper Map Editor", CookieAccess_Protected);
	g_ckPanel = new Cookie("zf_sme_panel", "Pannello in alto dello Stripper Map Editor", CookieAccess_Protected);
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && AreClientCookiesCached(i))
			OnClientCookiesCached(i);
	RegAdminCmd("sm_zf_sme", Cmd_Edit, 0, "Enters the Stripper Map Editor");
	RegAdminCmd("sm_zf_sme_exit", Cmd_Exit, 0, "Leaves the Stripper Map Editor (asks for confirmation)");
	RegAdminCmd("sm_zf-sme", Cmd_Edit, 0, "Enters the Stripper Map Editor");
	RegAdminCmd("sm_zf-sme-exit", Cmd_Exit, 0, "Leaves the Stripper Map Editor (asks for confirmation)");
	AddCommandListener(Listener_Say, "say");
	AddCommandListener(Listener_Say, "say_team");
	RegAdminCmd("sm_zf_sme_grab", Cmd_Grab, 0, "Grabs the selected object");
	RegAdminCmd("sm_zf_sme_drop", Cmd_Drop, 0, "Releases the object where it is");
	RegAdminCmd("sm_zf_sme_step", Cmd_Step, 0, "Changes the step size");
	RegAdminCmd("sm_zf_sme_noclip", Cmd_Noclip, 0, "Switches noclip on / off in the editor");
	RegAdminCmd("sm_zf_sme_speed", Cmd_Speed, 0, "Changes the speed in the editor (slow, medium, normal)");
	RegAdminCmd("sm_zf_sme_hud", Cmd_HudTest, 0, "Help panel test (VScript HUD): on/off");
	RegAdminCmd("sm_zf_sme_righello", Cmd_Ruler, 0, "Ruler to measure the HUD space: on/off");
	RegAdminCmd("sm_zf_sme_x_up", Cmd_Nudge, 0);
	RegAdminCmd("sm_zf_sme_x_down", Cmd_Nudge, 0);
	RegAdminCmd("sm_zf_sme_y_up", Cmd_Nudge, 0);
	RegAdminCmd("sm_zf_sme_y_down", Cmd_Nudge, 0);
	RegAdminCmd("sm_zf_sme_z_up", Cmd_Nudge, 0);
	RegAdminCmd("sm_zf_sme_z_down", Cmd_Nudge, 0);
	RegAdminCmd("sm_zf_sme_pitch_up", Cmd_Nudge, 0);
	RegAdminCmd("sm_zf_sme_pitch_down", Cmd_Nudge, 0);
	RegAdminCmd("sm_zf_sme_yaw_up", Cmd_Nudge, 0);
	RegAdminCmd("sm_zf_sme_yaw_down", Cmd_Nudge, 0);
	RegAdminCmd("sm_zf_sme_roll_up", Cmd_Nudge, 0);
	RegAdminCmd("sm_zf_sme_roll_down", Cmd_Nudge, 0);

	g_aHammer   = new ArrayList();
	g_aKind     = new ArrayList(ByteCountToCells(64));
	g_aModel  = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	g_aOrigin  = new ArrayList(3);
	g_aSnapPos  = new ArrayList(3);
	g_aSnapAng  = new ArrayList(3);
	g_aAngLoaded  = new ArrayList(3);
	g_aPos      = new ArrayList(3);
	g_aAng      = new ArrayList(3);
	g_aCopy    = new ArrayList();
	g_aEnt      = new ArrayList();
	g_aSurvival = new ArrayList();
	g_aReal     = new ArrayList(3);
	g_aAngReal  = new ArrayList(3);
	g_aBlock   = new ArrayList(ByteCountToCells(BLOCK_MAX));
	g_aHistory  = new ArrayList(8);
	for (int c = 0; c <= MaxClients; c++)
		g_aFilled[c] = new ArrayList();
	g_smSignal = new StringMap();
	g_smLeft = new StringMap();
	g_smLeftTemp = new StringMap();
	g_smGroup = new StringMap();
	g_smDropping = new StringMap();
	g_aRedo    = new ArrayList(8);
	CreateTimer(0.3, Timer_Title, _, TIMER_REPEAT);

	char sFolder[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sFolder, sizeof(sFolder), DATA_FOLDER);
	CreateFolders(sFolder);
}

// ---------------------------------------------------------------- SourceMod admin menu
// "Zombie Foundry Tuner" category with the "Stripper Map Editor" item, as in the tool.

TopMenu g_tmAdmin;

public void OnAllPluginsLoaded()
{
	TopMenu tm;
	if (LibraryExists("adminmenu") && (tm = GetAdminTopMenu()) != null)
		OnAdminMenuReady(tm);
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "adminmenu"))
		g_tmAdmin = null;
}

public void OnAdminMenuReady(Handle h)
{
	TopMenu tm = TopMenu.FromHandle(h);
	if (tm == g_tmAdmin)
		return;
	g_tmAdmin = tm;
	TopMenuObject cat = tm.AddCategory("zf_tuner", Admin_Category);
	tm.AddItem("zf_stripper_map_editor", Admin_Item, cat, "sm_zf_sme", 0);
}

public void Admin_Category(TopMenu tm, TopMenuAction a, TopMenuObject id, int client, char[] buf, int len)
{
	if (a == TopMenuAction_DisplayTitle || a == TopMenuAction_DisplayOption)
		strcopy(buf, len, "Zombie Foundry Tuner");
}

public void Admin_Item(TopMenu tm, TopMenuAction a, TopMenuObject id, int client, char[] buf, int len)
{
	if (a == TopMenuAction_DisplayOption)
		{ char sExit[24]; sExit[0] = '\0'; if (InEditor(client)) Tr(sExit, sizeof(sExit), client, "admin_item_exit"); FormatEx(buf, len, "Zombie Foundry Stripper Map Editor%s", sExit); }
	else if (a == TopMenuAction_SelectOption)
	{
		if (InEditor(client)) AskExit(client);   // the item says "(exit)" while inside
		else Cmd_Edit(client, 0);
	}
}

// ---------------------------------------------------------------- who is in the editor
// In the editor the player stands still in the menus and the plugin removes keys: the game thinks
// they are idle and puts a bot in their place. While someone is in the editor the idle time is
// raised; when the last one leaves it goes back to how it was.
float g_fAfkOriginal = -1.0;
bool  g_bReloading;              // the map is already about to reload (Publish and reload)

static const char CVAR_DIRECTOR[][] = { "director_no_mobs", "director_no_specials", "director_no_bosses", "z_common_limit" };
static const int  STILL_VALUE[] = { 1, 1, 1, 0 };
int  g_iDirectorOriginal[4];
bool g_bDirectorStopped;

void StopDirector(bool stop)
{
	if (stop == g_bDirectorStopped)
		return;
	for (int k = 0; k < sizeof(CVAR_DIRECTOR); k++)
	{
		ConVar cv = FindConVar(CVAR_DIRECTOR[k]);
		if (cv == null)
			continue;
		if (stop)
		{
			g_iDirectorOriginal[k] = cv.IntValue;
			cv.IntValue = STILL_VALUE[k];
		}
		else
			cv.IntValue = g_iDirectorOriginal[k];
	}
	g_bDirectorStopped = stop;
	LogMessage("[editor] director %s", stop ? "off (no infected while editing)" : "on again");
}

// In the editor mode (zfstrippermapeditor) nobody ever goes idle
public Action Timer_EditorIdle(Handle t)
{
	if (EditorMode())
	{
		SuspendIdle(true);
		StopDirector(true);
	}
	return Plugin_Stop;
}

void SuspendIdle(bool suspend)
{
	ConVar cv = FindConVar("director_afk_timeout");
	if (cv == null)
		return;
	if (suspend && g_fAfkOriginal < 0.0)
	{
		g_fAfkOriginal = cv.FloatValue;
		cv.FloatValue = 999999.0;
		LogMessage("[editor] idle timeout suspended (director_afk_timeout was %.0f)", g_fAfkOriginal);
	}
	else if (!suspend && g_fAfkOriginal >= 0.0)
	{
		cv.FloatValue = g_fAfkOriginal;
		LogMessage("[editor] idle timeout restored (director_afk_timeout %.0f)", g_fAfkOriginal);
		g_fAfkOriginal = -1.0;
	}
}

bool InEditor(int c)
{
	return c >= 1 && c <= MaxClients && g_bInEditor[c];
}

int EditorCount()
{
	int n = 0;
	for (int c = 1; c <= MaxClients; c++)
		if (g_bInEditor[c])
			n++;
	return n;
}

int FirstEditor()
{
	for (int c = 1; c <= MaxClients; c++)
		if (g_bInEditor[c])
			return c;
	return 0;
}

// Who acted last, if still inside; otherwise the first one there
int LastActor()
{
	return InEditor(g_iLastActor) ? g_iLastActor : FirstEditor();
}

// Room for another one: alone always; together only in cooperative mode and up to MAX_EDITORI
bool SeatFree()
{
	int n = EditorCount();
	return n == 0 || (g_bCooperative && n < MAX_EDITORS);
}

// Who chose object i (0 = nobody), except "except": an object belongs to one person only
int InUseBy(int i, int except = 0)
{
	if (i < 0)
		return 0;
	for (int c = 1; c <= MaxClients; c++)
		if (c != except && g_bInEditor[c] && g_iChosen[c] == i)
			return c;
	return 0;
}

int LookedAtBy(int i)
{
	for (int c = 1; c <= MaxClients; c++)
		if (g_bInEditor[c] && g_iLooked[c] == i)
			return c;
	return 0;
}

// There are other editors besides client: reset, load and reload are done only alone
bool OtherEditors(int client)
{
	for (int c = 1; c <= MaxClients; c++)
		if (c != client && g_bInEditor[c])
			return true;
	return false;
}

// Who holds object i, except "except": whoever chose it, or whoever is dropping it
int Holder(int i, int except = 0)
{
	int c = InUseBy(i, except);
	if (c != 0 || i < 0 || i >= g_aHammer.Length)
		return c;
	char sK[12];
	IntToString(g_aHammer.Get(i), sK, sizeof(sK));
	if (g_smDropping.GetValue(sK, c) && c != except)
		return c;
	return 0;
}

// Reset, load and reload with others inside: owner only. The others let go of the object in their
// hand and are told. Returns false if it cannot be done.
bool CanActOnMap(int client)
{
	if (!OtherEditors(client))
		return true;
	if (!IsOwner(client))
	{
		Chat(client, "only_alone");
		LogEditor(client, "[coop] refused: reset/load/reload with others inside, not the owner");
		return false;
	}
	LogEditor(client, "[coop] the owner changes the map with %d others inside", EditorCount() - 1);
	for (int c = 1; c <= MaxClients; c++)
		if (c != client && g_bInEditor[c])
		{
			if (g_iChosen[c] != -1)
				Deselect(c);      // closes grab, preview, fine move, rotation, pause and wall
			g_aFilled[c].Clear();
			Chat(c, "owner_changes_map", client);
			if (IsClientInGame(c))
				MenuMain(c);
		}
	return true;
}

// Reset, load and reload with others inside: owner only, for the others the items are grey
bool OwnerOnly(int client)
{
	return OtherEditors(client) && !IsOwner(client);
}

// The HUD panel is one for everyone (the game does not make one per player): it shows the owner's
// data if inside, otherwise those of whoever acted last
int HudSource()
{
	for (int c = 1; c <= MaxClients; c++)
		if (g_bInEditor[c] && IsClientInGame(c) && IsOwner(c))
			return c;
	return LastActor();
}

// Object i is in another editor's hand: says so and returns true
bool HeldByOthers(int client, int i)
{
	int other = Holder(i, client);
	if (other == 0)
		return false;
	char sKind[64];
	TypeName(i, client, sKind, sizeof(sKind));
	Hint(client, "hint_in_use", sKind, g_aHammer.Get(i), other);
	LogEditor(client, "[coop] refused #%d: in use by %N", g_aHammer.Get(i), other);
	return true;
}

public void OnPluginEnd()
{
	// Plugin unloaded or reloaded with someone in the editor: they are put back as they were
	// (movement, freeze, arms, speed), otherwise they stay locked.
	for (int c = 1; c <= MaxClients; c++)
	{
		if (!g_bInEditor[c])
			continue;
		if (IsClientInGame(c))
			UnlockPlayer(c);
		if (g_iChosen[c] != -1)
			Untouchable(g_iChosen[c], false);
	}
	SuspendIdle(false);
	StopDirector(false);
	RemoveCopies();
}

public void OnMapStart()
{
	if (!EditorMode())
		g_bReserved = false;           // the maintenance holds only in the editor mode
	g_iLevelModel = PrecacheModel("materials/sprites/laserbeam.vmt");
	for (int c = 0; c <= MaxClients; c++)
	{
		g_iPreview[c] = INVALID_ENT_REFERENCE;
		g_iBeam[c] = INVALID_ENT_REFERENCE;
		g_iAnchorA[c] = INVALID_ENT_REFERENCE;
		g_iAnchorB[c] = INVALID_ENT_REFERENCE;
		g_iMarkYellow[c] = INVALID_ENT_REFERENCE;
		g_iMarkRed[c] = INVALID_ENT_REFERENCE;
		g_iMarkOf[c] = -1;
		g_bInEditor[c] = false;
		g_bGrabbed[c] = false;
		g_aFilled[c].Clear();
		ResetTimes(c);
	}
	g_iLastActor = 0;
	SuspendIdle(false);   // map change with someone inside: the value goes back to how it was
	g_bReloading = false;
	StopDirector(false);        // new map: the director restarts (in editor mode it is switched off again at once)
	CreateTimer(1.0, Timer_EditorIdle, _, TIMER_FLAG_NO_MAPCHANGE);   // the mode is read after the start
	g_iMovesSaved = 0;
	g_smSignal.Clear();
	g_smGroup.Clear();
	g_smDropping.Clear();
	ClearList();          // the copies are already gone with the map change
	g_iDropsRunning = 0;
}

public void OnClientDisconnect(int client)
{
	g_bHintOff[client] = false;
	g_bPanelOff[client] = false;
	g_iLanguage[client] = 0;
	g_iGameLanguage[client] = -1;
	if (InEditor(client))
	{
		RememberExit(client);
		LogEditor(client, "disconnected: editor freed");
		LeaveEditor(client, true);         // the move in progress goes into the return points, the object is freed
	}
}

// ---------------------------------------------------------------- log

// Teams: 1 = spectators, 2 = survivors, 3 = infected
static const char TEAM_NAMES[][] = { "none", "spectators", "survivors", "infected" };

void TeamName(int team, char[] out, int len)
{
	strcopy(out, len, (team >= 0 && team <= 3) ? TEAM_NAMES[team] : "?");
}

public void Event_Team(Event event, const char[] name, bool dontBroadcast)
{
	int c = GetClientOfUserId(event.GetInt("userid"));
	if (c < 1 || IsFakeClient(c))
		return;
	char sFrom[16], sA[16];
	TeamName(event.GetInt("oldteam"), sFrom, sizeof(sFrom));
	TeamName(event.GetInt("team"), sA, sizeof(sA));
	LogMessage("[editor] [team] %N: from %s to %s%s%s", c, sFrom, sA,
		event.GetBool("disconnect") ? " (leaves the server)" : "", event.GetBool("isbot") ? " (bot)" : "");
}

public void Event_Idle(Event event, const char[] name, bool dontBroadcast)
{
	int c = GetClientOfUserId(event.GetInt("player"));
	if (c >= 1 && IsClientInGame(c) && !IsFakeClient(c))
		LogMessage("[editor] [team] %N idle: a bot took their survivor", c);
}

public void Event_Resume(Event event, const char[] name, bool dontBroadcast)
{
	int c = GetClientOfUserId(event.GetInt("player"));
	if (c >= 1 && IsClientInGame(c) && !IsFakeClient(c))
		LogMessage("[editor] [team] %N takes their survivor back", c);
}

public void OnClientPutInServer(int client)
{
	if (!IsFakeClient(client))
		LogMessage("[editor] [team] %N joins the server (team %d)", client, GetClientTeam(client));
}

// Disaster log: while someone is in the editor, the fire and explosion entities that spawn and the
// fire or explosion damage to survivors go to the SourceMod log, tagged [editor] and [disaster],
// with the editor's state at that moment.
void EditorState(char[] out, int len)
{
	char sObj[64], sOne[160];
	FormatEx(out, len, "cadute in corso=%d", g_iDropsRunning);
	for (int c = 1; c <= MaxClients; c++)
	{
		if (!g_bInEditor[c])
			continue;
		if (g_iChosen[c] != -1 && g_iChosen[c] < g_aHammer.Length)
			FormatEx(sObj, sizeof(sObj), "scelto #%d", g_aHammer.Get(g_iChosen[c]));
		else
			strcopy(sObj, sizeof(sObj), "no object chosen");
		FormatEx(sOne, sizeof(sOne), "; %N: %s, afferrato=%d, fine=%d, ruota=%d", c, sObj, g_bGrabbed[c], g_bFineMove[c], g_bRotate[c]);
		StrCat(out, len, sOne);
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (EditorCount() == 0)
		return;
	if (StrEqual(classname, "inferno") || StrEqual(classname, "env_explosion") || StrEqual(classname, "env_fire")
	 || StrEqual(classname, "molotov_projectile") || StrEqual(classname, "pipe_bomb_projectile")
	 || StrEqual(classname, "vomitjar_projectile") || StrEqual(classname, "fire_cracker_blast")
	 || StrEqual(classname, "prop_fuel_barrel"))
		RequestFrame(Frame_Disaster, EntIndexToEntRef(entity));
}

public void Frame_Disaster(int ref)
{
	int e = EntRefToEntIndex(ref);
	if (e <= MaxClients || !IsValidEntity(e) || EditorCount() == 0)
		return;
	char sClass[64], sState[200];
	GetEntityClassname(e, sClass, sizeof(sClass));
	float v[3];
	GetEntPropVector(e, Prop_Data, "m_vecAbsOrigin", v);
	EditorState(sState, sizeof(sState));
	LogMessage("[editor] [disaster] entity spawned %s (%d) at %.0f %.0f %.0f; %s", sClass, e, v[0], v[1], v[2], sState);
}

public void Event_Damage(Event event, const char[] name, bool dontBroadcast)
{
	if (EditorCount() == 0)
		return;
	int kind = event.GetInt("type");
	if (!(kind & (8 | 64)))                   // 8 = fire, 64 = explosion
		return;
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim < 1 || GetClientTeam(victim) != 2)
		return;
	char sWeapon[48], sState[200];
	event.GetString("weapon", sWeapon, sizeof(sWeapon));
	int att = GetClientOfUserId(event.GetInt("attacker"));
	EditorState(sState, sizeof(sState));
	LogMessage("[editor] [disaster] damage %d to %N (health %d) type=%d weapon=%s attacker=%N; %s",
		event.GetInt("dmg_health"), victim, event.GetInt("health"), kind, sWeapon, att > 0 ? att : 0, sState);
}

void LogEditor(int client, const char[] fmt, any ...)
{
	if (InEditor(client))
		g_iLastActor = client;
	char sText[256];
	VFormat(sText, sizeof(sText), fmt, 3);
	if (client > 0 && IsClientInGame(client))
		LogMessage("[editor] %N: %s", client, sText);
	else
		LogMessage("[editor] %s", sText);
}

// ---------------------------------------------------------------- entry / exit

public Action Cmd_Edit(int client, int args)
{
	if (client == 0 || !IsClientInGame(client))
	{
		ReplyToCommand(client, "%T", "only_in_game", LANG_SERVER);
		return Plugin_Handled;
	}
	if (InEditor(client))
	{
		char sLeave[32];
		CommandText(sLeave, sizeof(sLeave), true);
		Chat(client, "already_in_editor", sLeave);
		if (GetClientMenu(client) == MenuSource_None)   // a menu already on screen stays where it is
			MenuMain(client);
		return Plugin_Handled;
	}
	if (!IsAuthorized(client))
	{
		LogEditor(client, "refused: not authorized");
		Chat(client, "not_authorized");
		return Plugin_Handled;
	}
	if (!SeatFree())
	{
		LogEditor(client, "refused: editor already taken");
		if (g_bCooperative)
			Chat(client, "editor_full", MAX_EDITORS);
		else
			{ char sEditorName[64]; GetClientName(FirstEditor(), sEditorName, sizeof(sEditorName)); Chat(client, "editor_busy", sEditorName); }
		return Plugin_Handled;
	}
	if (SurvivalMode() && !EditorMode())
	{
		// Editor already open (without panel): whoever arrives simply joins. Only the owner can
		// choose to switch to the panel version, which reloads the map for everyone.
		if (EditorCount() > 0)
		{
			if (!IsOwner(client))
			{
				LogEditor(client, "joins the editor already open (no panel)");
				EnterEditor(client);
			}
			else
				MenuJoinOpen(client);
			return Plugin_Handled;
		}
		MenuConfirmReload(client, 0);
		return Plugin_Handled;
	}
	EnterEditor(client);
	return Plugin_Handled;
}

// The command as the messages show it
void CommandText(char[] out, int len, bool leave)
{
	strcopy(out, len, leave ? "-zf-sme-exit" : "-zf-sme");
}

// "-zf-sme" and "-zf-sme-exit" with any of the triggers, "-" or "_" inside, hidden from the chat
public Action Listener_Say(int client, const char[] command, int argc)
{
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Continue;
	char sText[64];
	GetCmdArgString(sText, sizeof(sText));
	StripQuotes(sText);
	TrimString(sText);
	if (sText[0] == '\0' || FindCharInString(TRIGGERS, sText[0]) == -1)
		return Plugin_Continue;
	char sCmd[32];
	strcopy(sCmd, sizeof(sCmd), sText[1]);
	ReplaceString(sCmd, sizeof(sCmd), "_", "-");
	bool enter = StrEqual(sCmd, "zf-sme", false);
	bool leave = StrEqual(sCmd, "zf-sme-exit", false);
	if (!enter && !leave)
		return Plugin_Continue;
	if (enter) Cmd_Edit(client, 0);
	else       Cmd_Exit(client, 0);
	return Plugin_Handled;
}

public Action Cmd_Exit(int client, int args)
{
	if (client == 0 || !IsClientInGame(client))
	{
		ReplyToCommand(client, "%T", "only_in_game", LANG_SERVER);
		return Plugin_Handled;
	}
	if (!InEditor(client))
	{
		char sEnter[32];
		CommandText(sEnter, sizeof(sEnter), false);
		Chat(client, "not_in_editor", sEnter);
		return Plugin_Handled;
	}
	AskExit(client);
	return Plugin_Handled;
}

// From Survival the server switches to "zfstrippermapeditor": the map reloads and whoever asked
// comes back into the editor by themselves. If the server lacks the mode's files, the game refuses
// the value and the editor is entered anyway.
// Who must come back into the editor after the map change. It is also written to a file (with the
// temporary access): if the plugin is replaced by a new version on the map change, memory is lost.
// The file is valid for two minutes.
#define FILE_REENTRY "../zombiefoundry/stripper-map-editor/reentry.txt"
ArrayList g_aReentry;
ArrayList g_aTemporary;

void WriteReentry()
{
	char sFolder[PLATFORM_MAX_PATH], sPath[PLATFORM_MAX_PATH], sId[32], sK[8];
	BuildPath(Path_SM, sFolder, sizeof(sFolder), DATA_FOLDER);
	CreateFolders(sFolder);
	BuildPath(Path_SM, sPath, sizeof(sPath), FILE_REENTRY);
	KeyValues kv = new KeyValues("Reentry");
	kv.SetNum("time", GetTime());
	kv.JumpToKey("reentry", true);
	for (int i = 0; g_aReentry != null && i < g_aReentry.Length; i++)
	{
		g_aReentry.GetString(i, sId, sizeof(sId));
		IntToString(i, sK, sizeof(sK));
		kv.SetString(sK, sId);
	}
	kv.Rewind();
	kv.JumpToKey("temporary", true);
	for (int i = 0; g_aTemporary != null && i < g_aTemporary.Length; i++)
	{
		g_aTemporary.GetString(i, sId, sizeof(sId));
		IntToString(i, sK, sizeof(sK));
		kv.SetString(sK, sId);
	}
	kv.Rewind();
	kv.ExportToFile(sPath);
	delete kv;
}

void ReadReentry()
{
	char sPath[PLATFORM_MAX_PATH], sId[32];
	BuildPath(Path_SM, sPath, sizeof(sPath), FILE_REENTRY);
	if (!FileExists(sPath))
		return;
	KeyValues kv = new KeyValues("Reentry");
	if (kv.ImportFromFile(sPath) && GetTime() - kv.GetNum("time", 0) <= 120)
	{
		if (g_aReentry == null)
			g_aReentry = new ArrayList(8);
		if (g_aTemporary == null)
			g_aTemporary = new ArrayList(8);
		if (kv.JumpToKey("reentry") && kv.GotoFirstSubKey(false))
		{
			do
			{
				kv.GetString(NULL_STRING, sId, sizeof(sId));
				g_aReentry.PushString(sId);
			} while (kv.GotoNextKey(false));
		}
		kv.Rewind();
		if (kv.JumpToKey("temporary") && kv.GotoFirstSubKey(false))
		{
			do
			{
				kv.GetString(NULL_STRING, sId, sizeof(sId));
				if (g_aTemporary.FindString(sId) == -1)
					g_aTemporary.PushString(sId);
			} while (kv.GotoNextKey(false));
		}
		LogMessage("[editor] reentry read from file: %d to bring back, %d temporary accesses", g_aReentry.Length, g_aTemporary.Length);
	}
	delete kv;
}

// Marks who will come back: who is in the editor and who asks for the switch; with the switch to
// the editor mode also whoever is connected and has the permission (the second player)
void MarkReentry(int requester, bool allAuthorized)
{
	if (g_aReentry == null)
		g_aReentry = new ArrayList(8);
	g_aReentry.Clear();
	for (int c = 1; c <= MaxClients; c++)
	{
		if (!IsClientInGame(c) || IsFakeClient(c))
			continue;
		if (c == requester || g_bInEditor[c] || (allAuthorized && IsAuthorized(c)))
		{
			char sId[32];
			if (GetClientAuthId(c, AuthId_Steam2, sId, sizeof(sId)))
				g_aReentry.PushString(sId);
		}
	}
	WriteReentry();
	LogMessage("[editor] reentry: %d players will come back into the editor after the map change", g_aReentry.Length);
}

// On a map change the players are disconnected BEFORE OnMapEnd fires: whoever leaves the server
// while in the editor is remembered for a few seconds, and comes back in if the map changes soon.

void RememberExit(int client)
{
	char sId[32];
	if (g_smLeft == null || !GetClientAuthId(client, AuthId_Steam2, sId, sizeof(sId)))
		return;
	g_smLeft.SetValue(sId, GetTime());
	if (HasTemporaryAccess(client))
		g_smLeftTemp.SetValue(sId, 1);
}

// Who has temporary access: noted as soon as they leave the server, because the access is removed
void RememberTemporary(int client)
{
	char sId[32];
	if (g_smLeftTemp != null && HasTemporaryAccess(client) && GetClientAuthId(client, AuthId_Steam2, sId, sizeof(sId)))
		g_smLeftTemp.SetValue(sId, 1);
}

// Any map change with someone in the editor (vote, command, next map): whoever is inside comes back
public void OnMapEnd()
{
	if (EditorCount() > 0)
		MarkReentry(0, false);
	if (g_smLeft == null)
		return;
	if (g_aReentry == null)
		g_aReentry = new ArrayList(8);
	if (g_aTemporary == null)
		g_aTemporary = new ArrayList(8);
	StringMapSnapshot sn = g_smLeft.Snapshot();
	for (int i = 0; i < sn.Length; i++)
	{
		char sId[32];
		int when, t;
		sn.GetKey(i, sId, sizeof(sId));
		g_smLeft.GetValue(sId, when);
		if (GetTime() - when > 5)
			continue;
		if (g_aReentry.FindString(sId) == -1)
			g_aReentry.PushString(sId);
		if (g_smLeftTemp.GetValue(sId, t) && g_aTemporary.FindString(sId) == -1)
			g_aTemporary.PushString(sId);
	}
	delete sn;
	if (g_aReentry.Length > 0)
	{
		WriteReentry();
		LogMessage("[editor] reentry after the map change: %d players", g_aReentry.Length);
	}
	g_smLeft.Clear();
	g_smLeftTemp.Clear();
}

bool SwitchToEditor(int client)
{
	ConVar cv = FindConVar("mp_gamemode");
	cv.SetString("zfstrippermapeditor");
	if (!EditorMode())
	{
		LogEditor(client, "zfstrippermapeditor not available: staying in survival");
		return false;
	}
	MarkReentry(client, true);
	LogEditor(client, "switch to zfstrippermapeditor");
	ChatAll("map_reloading_editor_mode");
	CreateTimer(3.0, Timer_ReloadMap);
	return true;
}

public Action Timer_ReloadMap(Handle t)
{
	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));
	ForceChangeLevel(sMap, "Stripper Map Editor: editor mode");
	return Plugin_Stop;
}

public void OnClientPostAdminCheck(int client)
{
	if (g_bReserved && EditorMode() && !IsFakeClient(client) && !IsAuthorized(client))
	{
		LogMessage("[editor] maintenance: refused %N", client);
		KickClient(client, "%T", "maint_kick", client);
		return;
	}
	if (g_aReentry == null || g_aReentry.Length == 0 || IsFakeClient(client))
		return;
	char sId[32], sExpected[32];
	GetClientAuthId(client, AuthId_Steam2, sId, sizeof(sId));
	for (int i = 0; i < g_aReentry.Length; i++)
	{
		g_aReentry.GetString(i, sExpected, sizeof(sExpected));
		if (StrEqual(sId[7], sExpected[7]))
		{
			g_aReentry.Erase(i);
			CreateTimer(5.0, Timer_ReenterEditor, GetClientUserId(client));
			return;
		}
	}
}

public Action Timer_ReenterEditor(Handle t, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client != 0 && IsClientInGame(client) && !InEditor(client) && SeatFree() && IsAuthorized(client))
		EnterEditor(client);
	return Plugin_Stop;
}

void EnterEditor(int client)
{
	bool first = (EditorCount() == 0);
	g_bInEditor[client] = true;
	g_bRedoHintShown[client] = false;   // the Walk+9 hint once per editor session
	SuspendIdle(true);
	StopDirector(true);
	g_iLastActor = client;
	g_aFilled[client].Clear();
	ResetTimes(client);
	if (!GetClientAuthId(client, AuthId_SteamID64, g_sEditorId[client], sizeof(g_sEditorId[])))
		g_sEditorId[client][0] = '\0';
	GetClientName(client, g_sEditorName[client], sizeof(g_sEditorName[]));
	if (first)
		g_iLastAutosave = GetTime();
	g_iChosen[client] = -1;
	g_bGrabbed[client] = false;
	GetClientAbsOrigin(client, g_fStart[client]);
	g_mtStart[client] = GetEntityMoveType(client);
	UnlockPlayer(client);             // in case something was left from an older version
	// The editor enters walking, at normal speed
	g_bNoclip[client] = false;
	g_iSpeed[client] = 2;
	SetEntityMoveType(client, MOVETYPE_WALK);
	ApplySpeed(client);
	// Arms and weapons hidden: no muzzle smoke and a free view of the object
	SetEntProp(client, Prop_Send, "m_bDrawViewmodel", 0);
	// Health bars hidden (8). Not 1 (weapons): in L4D2 it takes the crosshair away too, and the editor
	// needs it to aim; the inventory on the right stays. 64 removes the health bars but also the
	// SourceMod menu: not used.
	SetEntProp(client, Prop_Send, "m_iHideHUD", 8);
	SDKHook(client, SDKHook_OnTakeDamage, Hook_EditorDamage);   // no damage in the editor
	{
		char sTeam[16];
		TeamName(GetClientTeam(client), sTeam, sizeof(sTeam));
		LogEditor(client, "entered (%d in the editor, cooperative %s, team %s, %s)", EditorCount(), g_bCooperative ? "on" : "off",
			sTeam, IsPlayerAlive(client) ? "alive" : "not alive");
		if (GetClientTeam(client) != 2)
			Chat(client, "editor_spectator");
	}
	Chat(client, "welcome");
	for (int c = 1; c <= MaxClients; c++)
		if (c != client && g_bInEditor[c])
			Chat(c, "coop_joined", client);
	if (!g_bFreeMode && first)
		CleanMap(client);
	if (EditorMode() && HudSource() == client && !g_bPanelOff[client])
		EditorPanel(true);
	MenuMain(client);     // from the F10 menu the Tuner already leads here: no second step
	// List at once, so objects can also be chosen by looking
	if (g_aHammer.Length == 0)
	{
		ServerCommand("stripper_dump");
		CreateTimer(1.5, Timer_QuietDump, GetClientUserId(client));
	}
}

// The editor takes no damage: no falls (flying with noclip), no fire or explosions. Only fire and explosions are logged.
float g_fLastDamageLog;
public Action Hook_EditorDamage(int victim, int &attacker, int &inflictor, float &damage, int &kind)
{
	if (!InEditor(victim))
		return Plugin_Continue;
	float now = GetGameTime();
	if ((kind & (8 | 64)) && now > g_fLastDamageLog + 2.0)
	{
		g_fLastDamageLog = now;
		LogMessage("[editor] [disaster] damage %.0f blocked to %N (type %d, attacker %d)", damage, victim, kind, attacker);
	}
	return Plugin_Handled;
}

// Leaving the editor (menu, disconnect, kicked, editor closed): a single path, which can be called
// more than once. It frees the leaver's object; the last one out switches everything off.
void LeaveEditor(int client, bool disconnected = false)
{
	if (!InEditor(client))
		return;
	if (IsClientInGame(client))
		SDKUnhook(client, SDKHook_OnTakeDamage, Hook_EditorDamage);
	LogEditor(client, "left (%d remain)", EditorCount() - 1);
	int iHand = g_iChosen[client];
	if (disconnected && iHand != -1 && (g_bGrabbed[client] || g_bFineMoved[client] || g_bRotateMoved[client]))
	{
		// the half-made move does not count and does not go into the history: the object goes back where it was taken
		g_aPos.SetArray(iHand, g_fBeforePos[client]);
		g_aAng.SetArray(iHand, g_fBeforeAng[client]);
		g_bGrabbed[client] = false;
		g_bFineMoved[client] = false;
		g_bRotateMoved[client] = false;
		RemovePreview(client);
		UpdateCopy(iHand);
		GreyOriginal(iHand, IsMoved(iHand));
		LogEditor(client, "[coop] disconnected holding #%d: it goes back where it was at the start of the move", g_aHammer.Get(iHand));
	}
	ReleaseObject(client);
	UnlightLooked(client);
	RemovePreview(client);
	RemoveMarks(client);
	if (g_iChosen[client] != -1)
		Deselect(client);
	g_bInEditor[client] = false;
	g_iChosen[client] = -1;
	g_bGrabbed[client] = false;
	g_bAwaitingName[client] = false;
	g_aFilled[client].Clear();
	ResetTimes(client);
	if (EditorCount() == 0)
	{
		if (!EditorMode())
			SuspendIdle(false);
		ProtectExplosives(false);
		PanelOffIfOn();
		RemoveCopies();
	}
	else
		for (int c = 1; c <= MaxClients; c++)
			if (g_bInEditor[c])
				Chat(c, "coop_left", client);
	if (IsClientInGame(client))
	{
		UnlockPlayer(client);
		CancelClientMenu(client, true);     // the editor menu does not stay on screen (editor closed by the owner)
		ClearMenuOnScreen(client);
	}
	if (disconnected)
		return;
	if (EditorCount() == 0 && g_bDirectorStopped && !g_bReloading)
	{
		LogEditor(client, "last one out of the editor: the map reloads in Survival");
		for (int c = 1; c <= MaxClients; c++)
			if (IsClientInGame(c) && !IsFakeClient(c))
				Chat(c, "editor_closed_reload");
		if (EditorMode())
			FindConVar("mp_gamemode").SetString("survival");
		CreateTimer(3.0, Timer_ReloadMap);
	}
	if (IsClientInGame(client) && IsPlayerAlive(client))
	{
		// the player stays where they are: no return to the starting point
		SetEntityMoveType(client, g_mtStart[client] == MOVETYPE_NOCLIP ? MOVETYPE_WALK : g_mtStart[client]);
		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
	}
	Chat(client, "left_editor");
}

// ---------------------------------------------------------------- noclip and speed

// Speed of the editor (only theirs, not the other players')
static const float SPEEDS[] = { 0.25, 0.5, 1.0 };
static const char SPEED_NAMES[][] = { "speed_slow", "speed_medium", "speed_normal" };

void ApplySpeed(int client)
{
	if (!IsClientInGame(client))
		return;
	float f = InEditor(client) ? SPEEDS[g_iSpeed[client]] : 1.0;
	SetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue", f);
}

// With the object in hand the editor goes slowly, on release back to the chosen speed
void GrabSpeed(int client, bool grabbed)
{
	#pragma unused grabbed
	ApplySpeed(client);
}

void SetNoclip(int client, bool isOn)
{
	g_bNoclip[client] = isOn;
	SetEntityMoveType(client, isOn ? MOVETYPE_NOCLIP : MOVETYPE_WALK);
	g_iSpeed[client] = isOn ? 1 : 2;        // noclip: medium; on foot: normal
	ApplySpeed(client);
	LogEditor(client, "noclip %s", isOn ? "on" : "off");
	{ char sSt[24]; Tr(sSt, sizeof(sSt), client, isOn ? "state_on" : "state_off"); Hint(client, "noclip_state", sSt); }
}

void ChangeSpeed(int client)
{
	g_iSpeed[client] = (g_iSpeed[client] + 1) % sizeof(SPEEDS);
	ApplySpeed(client);
	LogEditor(client, "speed %s", SPEED_NAMES[g_iSpeed[client]]);
	{ char sV[24]; Tr(sV, sizeof(sV), client, SPEED_NAMES[g_iSpeed[client]]); Hint(client, "speed_state", sV); }
}

public Action Cmd_Noclip(int client, int args)
{
	if (InEditor(client))
		SetNoclip(client, !g_bNoclip[client]);
	return Plugin_Handled;
}

public Action Cmd_Speed(int client, int args)
{
	if (InEditor(client))
		ChangeSpeed(client);
	return Plugin_Handled;
}

// ---------------------------------------------------------------- owner and access
// Owner = whoever really has the "t" flag (Admin_Custom6) written in their admin profile (a "real"
// read: root alone is not enough); until the tool sets it, whoever is in owner.txt. Temporary access
// lives in memory per SteamID: it ends when the player really leaves the server (player_disconnect
// event, not the map change) or on restart.

bool IdInFile(const char[] path, const char[] id2)
{
	File f = OpenFile(path, "r");
	if (f == null)
		return false;
	char sLine[64];
	bool ok = false;
	while (!ok && f.ReadLine(sLine, sizeof(sLine)))
	{
		TrimString(sLine);
		if (sLine[0] == '\0' || sLine[0] == '/' || sLine[0] == '#')
			continue;
		if (strlen(sLine) > 8 && StrEqual(sLine[7], id2[7]))     // STEAM_0 and STEAM_1 are the same account
			ok = true;
	}
	delete f;
	return ok;
}

bool IsOwner(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return false;
	AdminId a = GetUserAdmin(client);
	if (a != INVALID_ADMIN_ID && GetAdminFlag(a, Admin_Custom6, Access_Real))
		return true;
	char sId[32], sPath2[PLATFORM_MAX_PATH];
	if (!GetClientAuthId(client, AuthId_Steam2, sId, sizeof(sId)))
		return false;
	BuildPath(Path_SM, sPath2, sizeof(sPath2), FILE_OWNER);
	return IdInFile(sPath2, sId);
}

int TemporaryIndex(const char[] id2)
{
	if (g_aTemporary == null)
		return -1;
	for (int i = 0; i < g_aTemporary.Length; i++)
	{
		char sId[32];
		g_aTemporary.GetString(i, sId, sizeof(sId));
		if (StrEqual(sId[7], id2[7]))
			return i;
	}
	return -1;
}

bool HasTemporaryAccess(int client)
{
	char sId[32];
	if (!GetClientAuthId(client, AuthId_Steam2, sId, sizeof(sId)))
		return false;
	return TemporaryIndex(sId) != -1;
}

void GiveTemporaryAccess(int client)
{
	char sId[32];
	if (!GetClientAuthId(client, AuthId_Steam2, sId, sizeof(sId)))
		return;
	if (g_aTemporary == null)
		g_aTemporary = new ArrayList(8);
	if (TemporaryIndex(sId) == -1)
		g_aTemporary.PushString(sId);
}

void RemoveTemporaryAccess(int client)
{
	char sId[32];
	if (!GetClientAuthId(client, AuthId_Steam2, sId, sizeof(sId)))
		return;
	int k = TemporaryIndex(sId);
	if (k != -1)
		g_aTemporary.Erase(k);
}

public void Event_Disconnect(Event event, const char[] name, bool dontBroadcast)
{
	int c = GetClientOfUserId(event.GetInt("userid"));
	if (c > 0)
	{
		if (InEditor(c))
			RememberExit(c);
		RememberTemporary(c);
		RemoveTemporaryAccess(c);
	}
}

// Request for the tool: permanent access (ADD) or to remove (REMOVE). The tool reads it and updates
// authorized.txt, which only the tool writes.
void WriteRequest(int client, int target, const char[] action)
{
	char sPath2[PLATFORM_MAX_PATH], sId[32], sName[64], sDate[32];
	BuildPath(Path_SM, sPath2, sizeof(sPath2), FILE_REQUESTS);
	GetClientAuthId(target, AuthId_Steam2, sId, sizeof(sId));
	GetClientName(target, sName, sizeof(sName));
	FormatTime(sDate, sizeof(sDate), "%Y-%m-%d %H:%M:%S", GetTime());
	File f = OpenFile(sPath2, "a");
	if (f == null)
	{
		LogError("[editor] cannot write %s", sPath2);
		return;
	}
	f.WriteLine("%s\t%s\t%s\t%s\tby %N", action, sId, sName, sDate, client);
	delete f;
	LogEditor(client, "request %s for %s (%s)", action, sName, sId);
}

bool IsAuthorized(int client)
{
	if (IsOwner(client))
		return true;
	if (!g_bEditorOpen)
		return false;
	if (HasTemporaryAccess(client))
		return true;
	return AuthorizedByFile(client);
}

bool AuthorizedByFile(int client)
{
	char sMine2[32], sMine3[32];
	if (!GetClientAuthId(client, AuthId_Steam2, sMine2, sizeof(sMine2))
	 || !GetClientAuthId(client, AuthId_Steam3, sMine3, sizeof(sMine3)))
		return false;

	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), FILE_AUTHORIZED);
	File f = OpenFile(sPath, "r");
	if (f == null)
	{
		LogMessage("Missing %s: nobody is authorized", sPath);
		return false;
	}
	char sLine[64];
	bool ok = false;
	while (!ok && f.ReadLine(sLine, sizeof(sLine)))
	{
		TrimString(sLine);
		if (sLine[0] == '\0' || sLine[0] == '/' || sLine[0] == '#')
			continue;
		// STEAM_0 and STEAM_1 are the same account
		if (StrEqual(sLine, sMine3) || (strlen(sLine) > 8 && StrEqual(sLine[7], sMine2[7])))
			ok = true;
	}
	delete f;
	return ok;
}

// ---------------------------------------------------------------- menus

void MenuTuner(int client)
{
	Menu m = new Menu(Menu_Tuner);
	m.SetTitle("Zombie Foundry Tuner");
	m.AddItem("sme", "Zombie Foundry Stripper Map Editor");
	m.Display(client, MENU_TIME_FOREVER);
}

public int Menu_Tuner(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
		LogChoice(m, client, item, "Tuner");
	if (a == MenuAction_Select)
		MenuMain(client);
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

// Noclip and speed: the same two items in the main menu and in the settings
void NoclipSpeedItems(Menu m, int client)
{
	char sState[32], sItem[64];
	Tr(sState, sizeof(sState), client, g_bNoclip[client] ? "state_on" : "state_off");
	Tr(sItem, sizeof(sItem), client, "item_noclip", sState);
	m.AddItem("noclip", sItem);
	Tr(sState, sizeof(sState), client, SPEED_NAMES[g_iSpeed[client]]);
	Tr(sItem, sizeof(sItem), client, "item_speed", sState);
	m.AddItem("speed", sItem);
}

ArrayList g_aLoadList;                 // paths of the saves shown in the Load menu
ArrayList g_aAuthors;                 // the authors who saved (for the filter)
int  g_iLoadPage[MAXPLAYERS + 1];
int  g_iLoadKind[MAXPLAYERS + 1];        // 0 = saves, 1 = autosave
int  g_iAuthorFilter[MAXPLAYERS + 1];      // 0 all, 1 only mine, 2... one author
int  g_iDateFilter[MAXPLAYERS + 1];        // 0 all, 1 hour, 2 today, 3 days, 4 week, 5 month
char g_sChosenLoad[MAXPLAYERS + 1][PLATFORM_MAX_PATH];

// "20261021-095139_bd_12_before_the_wall.txt": date-time, author, moved objects (-1 if the file is
// older), free name
int ParseSave(const char[] file, char[] ts, int tsLen, char[] author, int aLen, char[] name, int nLen)
{
	char sBase[PLATFORM_MAX_PATH], sRest[PLATFORM_MAX_PATH], sRest2[PLATFORM_MAX_PATH], sNum[16];
	strcopy(sBase, sizeof(sBase), file);
	int p = StrContains(sBase, ".txt");
	if (p != -1)
		sBase[p] = '\0';
	author[0] = '\0';
	name[0] = '\0';
	int a = FindCharInString(sBase, '_');
	if (a == -1)
	{
		strcopy(ts, tsLen, sBase);
		return -1;
	}
	strcopy(ts, (a + 1 < tsLen) ? a + 1 : tsLen, sBase);
	strcopy(sRest, sizeof(sRest), sBase[a + 1]);
	int b = FindCharInString(sRest, '_');
	if (b == -1)
	{
		strcopy(author, aLen, sRest);
		return -1;
	}
	strcopy(author, (b + 1 < aLen) ? b + 1 : aLen, sRest);
	strcopy(sRest2, sizeof(sRest2), sRest[b + 1]);
	int c = FindCharInString(sRest2, '_');
	if (c == -1)
		strcopy(sNum, sizeof(sNum), sRest2);
	else
	{
		strcopy(sNum, (c + 1 < sizeof(sNum)) ? c + 1 : sizeof(sNum), sRest2);
		strcopy(name, nLen, sRest2[c + 1]);
		ReplaceString(name, nLen, "_", " ");
	}
	for (int k = 0; sNum[k] != '\0'; k++)
		if (!IsCharNumeric(sNum[k]))
			return -1;
	return sNum[0] == '\0' ? -1 : StringToInt(sNum);
}

void CollectSaves(int client)
{
	if (g_aLoadList == null)
		g_aLoadList = new ArrayList(PLATFORM_MAX_PATH / 4 + 8);
	if (g_aAuthors == null)
		g_aAuthors = new ArrayList(32);
	g_aLoadList.Clear();
	g_aAuthors.Clear();
	char sMine[64], sDir[PLATFORM_MAX_PATH];
	CleanName(g_sEditorName[client], sMine, sizeof(sMine));
	MapFolder(sDir, sizeof(sDir), g_iLoadKind[client] == 1 ? "autosave" : "saves");
	ArrayList names = new ArrayList(PLATFORM_MAX_PATH / 4 + 8);
	DirectoryListing d = OpenDirectory(sDir);
	if (d != null)
	{
		char sName[PLATFORM_MAX_PATH];
		FileType kind;
		while (d.GetNext(sName, sizeof(sName), kind))
			if (kind == FileType_File && StrContains(sName, ".txt") != -1)
				names.PushString(sName);
		delete d;
	}
	names.Sort(Sort_Descending, Sort_String);
	// first the authors (for the filter), then the files that pass the filters
	char sTs[24], sAuth[64], sFree[64];
	for (int i = 0; i < names.Length; i++)
	{
		char sName[PLATFORM_MAX_PATH];
		names.GetString(i, sName, sizeof(sName));
		ParseSave(sName, sTs, sizeof(sTs), sAuth, sizeof(sAuth), sFree, sizeof(sFree));
		if (!StrEqual(sAuth, sMine) && g_aAuthors.FindString(sAuth) == -1)
			g_aAuthors.PushString(sAuth);
	}
	if (g_iAuthorFilter[client] >= 2 + g_aAuthors.Length)
		g_iAuthorFilter[client] = 0;
	char sThreshold[24];
	sThreshold[0] = '\0';
	static const int DATE_SECONDS[] = { 0, 3600, 0, 259200, 604800, 2592000 };
	if (g_iDateFilter[client] == 2)
		FormatTime(sThreshold, sizeof(sThreshold), "%Y%m%d-000000", GetTime());
	else if (g_iDateFilter[client] > 0)
		FormatTime(sThreshold, sizeof(sThreshold), "%Y%m%d-%H%M%S", GetTime() - DATE_SECONDS[g_iDateFilter[client]]);
	for (int i = 0; i < names.Length; i++)
	{
		char sName[PLATFORM_MAX_PATH], sFull[PLATFORM_MAX_PATH];
		names.GetString(i, sName, sizeof(sName));
		ParseSave(sName, sTs, sizeof(sTs), sAuth, sizeof(sAuth), sFree, sizeof(sFree));
		int fa = g_iAuthorFilter[client];
		if (fa == 1 && !StrEqual(sAuth, sMine))
			continue;
		if (fa >= 2)
		{
			char sA2[64];
			g_aAuthors.GetString(fa - 2, sA2, sizeof(sA2));
			if (!StrEqual(sAuth, sA2))
				continue;
		}
		if (sThreshold[0] != '\0' && strcmp(sTs, sThreshold) < 0)
			continue;
		Format(sFull, sizeof(sFull), "%s/%s", sDir, sName);
		g_aLoadList.PushString(sFull);
	}
	delete names;
}

// "21/10 09:51 · bd · 12 obj. · before the wall"
void SaveLabel(int client, const char[] path, char[] out, int len)
{
	int k = strlen(path) - 1;
	while (k > 0 && path[k - 1] != '/')
		k--;
	char sTs[24], sAuth[64], sFree[64], sDate[8], sNow[8], sExtra[128], sN[32];
	int n = ParseSave(path[k], sTs, sizeof(sTs), sAuth, sizeof(sAuth), sFree, sizeof(sFree));
	Format(sDate, sizeof(sDate), "%c%c/%c%c", sTs[6], sTs[7], sTs[4], sTs[5]);
	Format(sNow, sizeof(sNow), "%c%c:%c%c", sTs[9], sTs[10], sTs[11], sTs[12]);
	sExtra[0] = '\0';
	if (n >= 0)
	{
		Tr(sN, sizeof(sN), client, "load_objs", n);
		Format(sExtra, sizeof(sExtra), " · %s", sN);
	}
	if (sFree[0] != '\0')
		Format(sExtra, sizeof(sExtra), "%s · %s", sExtra, sFree);
	Tr(out, len, client, "load_item", sDate, sNow, sAuth, sExtra);
}

void MenuLoad(int client, int page)
{
	CollectSaves(client);
	int n = g_aLoadList.Length;
	int pages = (n + 4) / 5;
	if (pages < 1)
		pages = 1;
	if (page < 0)
		page = 0;
	if (page >= pages)
		page = pages - 1;
	g_iLoadPage[client] = page;
	Menu m = new Menu(Menu_Load);
	m.Pagination = MENU_NO_PAGINATION;
	m.ExitButton = false;
	m.ExitBackButton = false;
	{ char sT[64]; Tr(sT, sizeof(sT), client, g_iLoadKind[client] == 1 ? "load_title_auto" : "load_title", page + 1, pages); m.SetTitle("%s", sT); }
	for (int k = page * 5; k < n && k < page * 5 + 5; k++)
	{
		char sPath2[PLATFORM_MAX_PATH], sLabel[160], sInfo[12];
		g_aLoadList.GetString(k, sPath2, sizeof(sPath2));
		SaveLabel(client, sPath2, sLabel, sizeof(sLabel));
		IntToString(k, sInfo, sizeof(sInfo));
		m.AddItem(sInfo, sLabel);
	}
	while (m.ItemCount < 5)
		m.AddItem("_", "", ITEMDRAW_SPACER);
	MenuEntry(m, client, "before", "item_page_prev", page > 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	{
		char sF[64], sV[96];
		int fa = g_iAuthorFilter[client];
		if (fa == 0)
			Tr(sF, sizeof(sF), client, "load_filter_all");
		else if (fa == 1)
			Tr(sF, sizeof(sF), client, "load_filter_mine");
		else
			g_aAuthors.GetString(fa - 2, sF, sizeof(sF));
		Tr(sV, sizeof(sV), client, "load_author", sF);
		m.AddItem("author", sV);
		static const char DATE[][] = { "date_all", "date_hour", "date_today", "date_3days", "date_week", "date_month" };
		Tr(sF, sizeof(sF), client, DATE[g_iDateFilter[client]]);
		Tr(sV, sizeof(sV), client, "load_date", sF);
		m.AddItem("date", sV);
	}
	MenuEntry(m, client, "after", "item_page_next", page < pages - 1 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	MenuEntry(m, client, "zero", "item_back");
	m.Display(client, MENU_TIME_FOREVER);
	if (n == 0)
		Chat(client, "load_none");
}

public int Menu_Load(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
	{
		LogChoice(m, client, item, "Load");
		char s[24];
		m.GetItem(item, s, sizeof(s));
		if (StrEqual(s, "zero"))
		{
			MenuSave(client);
			return 0;
		}
		if (StrEqual(s, "author"))
		{
			g_iAuthorFilter[client] = (g_iAuthorFilter[client] + 1) % (2 + g_aAuthors.Length);
			MenuLoad(client, 0);
			return 0;
		}
		if (StrEqual(s, "date"))
		{
			g_iDateFilter[client] = (g_iDateFilter[client] + 1) % 6;
			MenuLoad(client, 0);
			return 0;
		}
		if (StrEqual(s, "before") || StrEqual(s, "after"))
		{
			MenuLoad(client, g_iLoadPage[client] + (StrEqual(s, "after") ? 1 : -1));
			return 0;
		}
		g_aLoadList.GetString(StringToInt(s), g_sChosenLoad[client], sizeof(g_sChosenLoad[]));
		MenuConfirmLoad(client);
	}
	else if (a == MenuAction_Cancel && item == MenuCancel_Exit && InEditor(client))
		MenuLoad(client, g_iLoadPage[client]);
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

void MenuConfirmLoad(int client)
{
	Menu m = new Menu(Menu_ConfirmLoad);
	{ char sT[160]; Tr(sT, sizeof(sT), client, "load_confirm_title"); m.SetTitle("%s", sT); }
	MenuEntry(m, client, "no", "load_no");
	MenuEntry(m, client, "yes", "load_yes");
	Zero(m, client, "item_back", false, false);
	m.Display(client, MENU_TIME_FOREVER);
}

public int Menu_ConfirmLoad(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
	{
		LogChoice(m, client, item, "ConfirmLoad");
		char s[24];
		m.GetItem(item, s, sizeof(s));
		if (StrEqual(s, "yes") && !CanActOnMap(client))
		{
			MenuMain(client);
			return 0;
		}
		if (StrEqual(s, "yes"))
		{
			ReleaseObject(client);
			if (g_iChosen[client] != -1)
				Deselect(client);
			SaveMyWork(client, false);               // first the current work is saved
			if (LoadStateFromFile(client, g_sChosenLoad[client], true))
			{
				char sLabel[128];
				SaveLabel(client, g_sChosenLoad[client], sLabel, sizeof(sLabel));
				LogEditor(client, "loaded the save %s", g_sChosenLoad[client]);
				Chat(client, "load_done", sLabel);
				WriteState();
			}
			else
				Chat(client, "load_failed");
			MenuMain(client);
			return 0;
		}
		MenuLoad(client, g_iLoadPage[client]);
	}
	else if (a == MenuAction_Cancel && item == MenuCancel_Exit && InEditor(client))
		MenuConfirmLoad(client);
	else if (a == MenuAction_End)
		delete m;
	return 0;
}


public Action Cmd_ChatName(int client, const char[] command, int argc)
{
	if (client < 1 || client > MaxClients || !g_bAwaitingName[client])
		return Plugin_Continue;
	char sText[128], sName[64];
	GetCmdArgString(sText, sizeof(sText));
	StripQuotes(sText);
	TrimString(sText);
	g_bAwaitingName[client] = false;
	if (StrEqual(sText, "-") || sText[0] == '\0')
		sName[0] = '\0';
	else
		FileName(sText, sName, sizeof(sName));
	SaveMyWork(client, false, sName);
	MenuSave(client);
	return Plugin_Handled;
}

int g_iTarget[MAXPLAYERS + 1];
bool g_bSeesPlayer[MAXPLAYERS + 1];      // has opened a player's menu
bool g_bTargetInside[MAXPLAYERS + 1];    // how the player was when the menu was drawn

void MenuPlayers(int client)
{
	Menu m = new Menu(Menu_Players);
	m.Pagination = MENU_NO_PAGINATION;
	m.ExitButton = false;
	m.ExitBackButton = false;
	{ char sT[48]; Tr(sT, sizeof(sT), client, "players_title"); m.SetTitle("%s", sT); }
	int n = 0;
	for (int i = 1; i <= MaxClients && n < 8; i++)
	{
		if (i == client || !IsClientInGame(i) || IsFakeClient(i))
			continue;
		char sName[64], sItem[96], sInfo[12], sTag[24];
		GetClientName(i, sName, sizeof(sName));
		sTag[0] = '\0';
		if (IsAuthorized(i))
			Tr(sTag, sizeof(sTag), client, "player_access_tag");
		Format(sItem, sizeof(sItem), "%s%s", sName, sTag);
		IntToString(GetClientUserId(i), sInfo, sizeof(sInfo));
		m.AddItem(sInfo, sItem);
		n++;
	}
	while (m.ItemCount < 9)
		m.AddItem("_", "", ITEMDRAW_SPACER);
	MenuEntry(m, client, "zero", "item_back");
	m.Display(client, MENU_TIME_FOREVER);
	if (n == 0)
		Chat(client, "players_none");
}

public int Menu_Players(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
	{
		LogChoice(m, client, item, "Players");
		char s[24];
		m.GetItem(item, s, sizeof(s));
		if (StrEqual(s, "zero"))
		{
			MenuSettings(client);
			return 0;
		}
		int b = GetClientOfUserId(StringToInt(s));
		if (b > 0)
		{
			g_iTarget[client] = StringToInt(s);
			MenuPlayer(client);
			return 0;
		}
		MenuPlayers(client);
	}
	else if (a == MenuAction_Cancel && item == MenuCancel_Exit && InEditor(client))
		MenuPlayers(client);
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

void MenuPlayer(int client)
{
	int b = GetClientOfUserId(g_iTarget[client]);
	if (b < 1 || !IsClientInGame(b))
	{
		MenuPlayers(client);
		return;
	}
	Menu m = new Menu(Menu_Player);
	m.Pagination = MENU_NO_PAGINATION;
	m.ExitButton = false;
	m.ExitBackButton = false;
	{ char sT[96], sN[64]; GetClientName(b, sN, sizeof(sN)); Tr(sT, sizeof(sT), client, "player_title", sN); m.SetTitle("%s", sT); }
	MenuEntry(m, client, "temp", HasTemporaryAccess(b) ? "act_temp_take" : "act_temp_give");
	MenuEntry(m, client, "perm", "act_perm");
	MenuEntry(m, client, "remove", "act_remove");
	MenuEntry(m, client, "kick", "act_kick", (InEditor(b)) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	while (m.ItemCount < 9)
		m.AddItem("_", "", ITEMDRAW_SPACER);
	MenuEntry(m, client, "zero", "item_back");
	m.Display(client, MENU_TIME_FOREVER);
	g_bSeesPlayer[client] = true;
	g_bTargetInside[client] = InEditor(b);
}

public int Menu_Player(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
	{
		LogChoice(m, client, item, "Player");
		g_bSeesPlayer[client] = false;
		char s[24];
		m.GetItem(item, s, sizeof(s));
		int b = GetClientOfUserId(g_iTarget[client]);
		if (StrEqual(s, "zero") || b < 1 || !IsClientInGame(b))
		{
			MenuPlayers(client);
			return 0;
		}
		char sN[64];
		GetClientName(b, sN, sizeof(sN));
		if (StrEqual(s, "temp"))
		{
			if (HasTemporaryAccess(b))
			{
				RemoveTemporaryAccess(b);
				if (InEditor(b) && !IsOwner(b))
					LeaveEditor(b);                     // without access nobody stays in the editor
				Chat(b, "access_removed");
				Chat(client, "removed_from", sN);
			}
			else
			{
				GiveTemporaryAccess(b);
				char sEnter[32];
				CommandText(sEnter, sizeof(sEnter), false);
				Chat(b, "access_granted", sEnter);
				Chat(client, "granted_to", sN);
			}
			LogEditor(client, "temporary access of %s: %s", sN, HasTemporaryAccess(b) ? "given" : "removed");
		}
		else if (StrEqual(s, "perm"))
		{
			WriteRequest(client, b, "ADD");
			Chat(client, "request_written", sN);
		}
		else if (StrEqual(s, "remove"))
		{
			RemoveTemporaryAccess(b);
			WriteRequest(client, b, "REMOVE");
			if (InEditor(b))
				LeaveEditor(b);
			Chat(b, "access_removed");
			Chat(client, "removed_from", sN);
		}
		else if (StrEqual(s, "kick") && InEditor(b))
		{
			LeaveEditor(b);
			Chat(b, "kicked_editor");
		}
		MenuPlayer(client);
	}
	else if (a == MenuAction_Cancel && item != MenuCancel_Interrupted)
	{
		g_bSeesPlayer[client] = false;
		if (item == MenuCancel_Exit && InEditor(client))
			MenuPlayer(client);
	}
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

void MenuSave(int client)
{
	Menu m = new Menu(Menu_Save);
	{ char sT[48]; Tr(sT, sizeof(sT), client, "save_title"); m.SetTitle("%s", sT); }
	char sItem[64], sA[32];
	int okMine = g_aHammer.Length > 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED;
	int okPublished = (g_aHammer.Length > 0 && Unpublished() > 0) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED;
	MenuEntry(m, client, "mine", "item_save_mine", okMine);
	Tr(sItem, sizeof(sItem), client, ToSave() == 0 ? "item_save_orig" : "item_save", Unpublished());
	m.AddItem("pub", sItem, okPublished);
	int okAlone = (g_aHammer.Length > 0 && !OwnerOnly(client)) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED;
	MenuEntry(m, client, "pubreload", Unpublished() > 0 ? "item_save_reload" : "item_reload_only", okAlone);
	AutosaveName(client, sA, sizeof(sA));
	Tr(sItem, sizeof(sItem), client, "item_autosave", sA);
	m.AddItem("auto", sItem);
	MenuEntry(m, client, "load", "item_load", okAlone);
	MenuEntry(m, client, "loadauto", "item_load_auto", okAlone);
	Zero(m, client, "item_back", false, false);
	m.Display(client, MENU_TIME_FOREVER);
}

public int Menu_Save(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
	{
		LogChoice(m, client, item, "Save");
		char s[24];
		m.GetItem(item, s, sizeof(s));
		if (StrEqual(s, "mine"))
		{
			g_bAwaitingName[client] = true;
			Chat(client, "save_name_prompt");
			{
				char sH[256];
				Tr(sH, sizeof(sH), client, "save_name_hint");
				PrintHintText(client, "%s", sH);   // even with hints off: without it, what to do is unclear
			}
			return 0;
		}
		else if (StrEqual(s, "pub"))
			SaveStripper(client);
		else if (StrEqual(s, "pubreload"))
		{
			MenuConfirmReload(client, 1);
			return 0;
		}
		else if (StrEqual(s, "auto"))
			CycleAutosave();
		else if (StrEqual(s, "load") || StrEqual(s, "loadauto"))
		{
			g_iLoadKind[client] = StrEqual(s, "loadauto") ? 1 : 0;
			g_iAuthorFilter[client] = 0;
			g_iDateFilter[client] = 0;
			MenuLoad(client, 0);
			return 0;
		}
		else if (StrEqual(s, "zero"))
		{
			MenuMain(client);
			return 0;
		}
		MenuSave(client);
	}
	else if (a == MenuAction_Cancel && item == MenuCancel_Exit && InEditor(client))
	{
		Chat(client, OwnerOnly(client) ? "only_alone" : "nothing_to_save");     // a key on a grey item
		MenuSave(client);
	}
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

void MenuMain(int client)
{
	g_fMainMenuTime[client] = GetGameTime();
	Menu m = new Menu(Menu_Main);
	if (Unpublished() > 0 && !g_bHud)
	{
		char sT[96];
		Tr(sT, sizeof(sT), client, "main_title_unsaved", Unpublished());
		m.SetTitle("%s", sT);
	}
	else
	{
		char sT[96];
		Tr(sT, sizeof(sT), client, "main_title");
		m.SetTitle("%s", sT);
	}
	MenuEntry(m, client, "sel", "item_select");
	NoclipSpeedItems(m, client);
	m.AddItem("_", "", ITEMDRAW_SPACER);
	MenuEntry(m, client, "reset", "item_reset_all", ((ToSave() > 0 || g_bDestroyed) && !OwnerOnly(client)) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	MenuEntry(m, client, "saveas", "item_save_menu");
	MenuEntry(m, client, "settings", "item_settings");
	Zero(m, client, "item_exit_editor");
	m.Display(client, MENU_TIME_FOREVER);
}

public int Menu_Main(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
		LogChoice(m, client, item, "Main");
	if (a == MenuAction_Select)
	{
		char s[24];
		m.GetItem(item, s, sizeof(s));
		if (StrEqual(s, "sel"))
		{
			if (g_aHammer.Length > 0)
				MenuList(client, 0);      // the dump is already there: do not lose the moves
			else
				RequestDump(client);
		}
		else if (StrEqual(s, "settings"))
		{
			g_iSettingsPage[client] = 0;           // from the main menus it always opens on page 1
			MenuSettings(client);
			return 0;
		}
		else if (StrEqual(s, "noclip"))
		{
			SetNoclip(client, !g_bNoclip[client]);
			MenuMain(client);
		}
		else if (StrEqual(s, "speed"))
		{
			ChangeSpeed(client);
			MenuMain(client);
		}
		else if (StrEqual(s, "undo"))
		{
			Undo(client, 0);
			MenuMain(client);
		}
		else if (StrEqual(s, "redo"))
		{
			Redo(client);
			MenuMain(client);
		}
		else if (StrEqual(s, "saveas"))
		{
			MenuSave(client);
			return 0;
		}
		else if (StrEqual(s, "reset"))
		{
			if (ToSave() == 0 && !g_bDestroyed)
			{
				Chat(client, "reset_nothing");
				MenuMain(client);
			}
			else
				MenuConfirmReset(client);
		}
		else if (StrEqual(s, "zero"))
			AskExit(client, true);
		else if (StrEqual(s, "eight"))
		{
			Redo(client);
			MenuMain(client);
		}
		else if (StrEqual(s, "nine"))
		{
			MenuNine(client);
			MenuMain(client);
		}
	}
	else if (a == MenuAction_Cancel && item == MenuCancel_ExitBack)
		{ if (g_tmAdmin != null) g_tmAdmin.Display(client, TopMenuPosition_LastCategory); else MenuTuner(client); }
	else if (a == MenuAction_Cancel && item == MenuCancel_Exit && InEditor(client))
	{
		LogMessage("[editor] [menu] %N: main menu closed without a choice (grey item?): opening it again", client);
		if (OwnerOnly(client))
			Chat(client, "only_alone");
		else if (ToSave() == 0 && !g_bDestroyed)
			Chat(client, "reset_nothing");     // usually the only white item is "Restore the whole map"
		MenuMain(client);
	}
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

// ---------------------------------------------------------------- dump and list

void RequestDump(int client)
{
	LogEditor(client, "asks for the dump");
	Chat(client, "reading_objects");
	ServerCommand("stripper_dump");
	CreateTimer(1.5, Timer_ReadDump, GetClientUserId(client));
}

public Action Timer_ReadDump(Handle t, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!InEditor(client))
		return Plugin_Stop;

	char sFile[PLATFORM_MAX_PATH];
	if (!LatestDump(sFile, sizeof(sFile)))
	{
		LogEditor(client, "dump not found in %s", DUMP_FOLDER);
		Chat(client, "dump_missing", DUMP_FOLDER);
		MenuMain(client);
		return Plugin_Stop;
	}
	int n = ReadDump(sFile);
	LogEditor(client, "dump %s: %d objects", sFile, n);
	LoadState(client);
	Chat(client, "objects_found", n);
	MenuList(client, 0);
	return Plugin_Stop;
}

public Action Timer_QuietDump(Handle t, int userid)
{
	int client = GetClientOfUserId(userid);
	char sFile[PLATFORM_MAX_PATH];
	if (InEditor(client) && g_aHammer.Length == 0 && LatestDump(sFile, sizeof(sFile)))
	{
		LogEditor(client, "dump %s: %d oggetti", sFile, ReadDump(sFile));
		LoadState(client);
	}
	return Plugin_Stop;
}

// The newest file of the current map in addons/stripper/dumps
bool LatestDump(char[] sOut, int len)
{
	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));

	DirectoryListing d = OpenDirectory(DUMP_FOLDER);
	if (d == null)
		return false;

	char sName[PLATFORM_MAX_PATH], sFull[PLATFORM_MAX_PATH];
	FileType kind;
	int iNewest = -1;
	while (d.GetNext(sName, sizeof(sName), kind))
	{
		if (kind != FileType_File || StrContains(sName, sMap, false) != 0)
			continue;
		Format(sFull, sizeof(sFull), "%s/%s", DUMP_FOLDER, sName);
		int time = GetFileTime(sFull, FileTime_LastChange);
		if (time > iNewest)
		{
			iNewest = time;
			strcopy(sOut, len, sFull);
		}
	}
	delete d;
	return iNewest != -1;
}

void ClearList()
{
	g_aHammer.Clear();
	g_aKind.Clear();
	g_aModel.Clear();
	g_aOrigin.Clear();
	g_aAngLoaded.Clear();
	g_aPos.Clear();
	g_aAng.Clear();
	g_aCopy.Clear();
	g_aEnt.Clear();
	g_bDestroyed = false;
	g_aSurvival.Clear();
	g_aReal.Clear();
	g_aAngReal.Clear();
	g_aBlock.Clear();
	g_aHistory.Clear();
	g_iMovesSaved = 0;          // if the return points file exists, it puts this back
	g_iMovesSnapshot = 0;
	for (int c = 0; c <= MaxClients; c++)
	{
		g_iChosen[c] = -1;
		g_iLooked[c] = -1;
	}
}

int ReadDump(const char[] sFile)
{
	RemoveCopies();
	ClearList();
	File f = OpenFile(sFile, "r");
	if (f == null)
		return 0;

	char sLine[512], sKey[64], sValue[256];
	char sClass[64], sModel[PLATFORM_MAX_PATH], sNameT[64];
	char sBlock[BLOCK_MAX];
	float vOrig[3], vAng[3];
	int hammer;
	bool inside = false;

	while (f.ReadLine(sLine, sizeof(sLine)))
	{
		TrimString(sLine);
		// In the dump the blocks are joined: "}{" on the same line
		if (sLine[0] == '}' && inside)
		{
			inside = false;
			AddIfObject(sClass, sModel, sNameT, vOrig, vAng, hammer, sBlock);
		}
		if (sLine[0] == '{' || (sLine[0] == '}' && sLine[1] == '{'))
		{
			inside = true;
			sClass[0] = sModel[0] = sNameT[0] = sBlock[0] = '\0';
			vOrig[0] = vOrig[1] = vOrig[2] = 0.0;
			vAng[0] = vAng[1] = vAng[2] = 0.0;
			hammer = 0;
		}
		else if (inside && sLine[0] == '"')
		{
			int p = BreakString(sLine, sKey, sizeof(sKey));
			if (p == -1)
				continue;
			BreakString(sLine[p], sValue, sizeof(sValue));
			if (StrEqual(sKey, "classname"))       strcopy(sClass, sizeof(sClass), sValue);
			else if (StrEqual(sKey, "model"))      strcopy(sModel, sizeof(sModel), sValue);
			else if (StrEqual(sKey, "targetname")) strcopy(sNameT, sizeof(sNameT), sValue);
			else if (StrEqual(sKey, "hammerid"))   hammer = StringToInt(sValue);
			else if (StrEqual(sKey, "origin"))     ReadVec3(sValue, vOrig);
			else if (StrEqual(sKey, "angles"))     ReadVec3(sValue, vAng);
			// The block is needed for add: every line except position and rotation
			if (!StrEqual(sKey, "origin") && !StrEqual(sKey, "angles"))
			{
				StrCat(sBlock, sizeof(sBlock), sLine);
				StrCat(sBlock, sizeof(sBlock), "\n");
			}
		}
	}
	delete f;
	return g_aHammer.Length;
}

void ReadVec3(const char[] s, float v[3])
{
	char parts[3][24];
	ExplodeString(s, " ", parts, 3, sizeof(parts[]));
	for (int i = 0; i < 3; i++)
		v[i] = StringToFloat(parts[i]);
}

void AddIfObject(const char[] sClass, const char[] sModel, const char[] sNameT, const float vOrig[3], const float vAng[3], int hammer, const char[] sBlock)
{
	char sKind[64];
	if (!ReadableName(sClass, sModel, sKind, sizeof(sKind)))
		return;

	// Only the objects of the current mode: in Survival those with targetname weapons_survival, in the
	// other modes the others.
	if (StrEqual(sNameT, "weapons_survival") != SurvivalMode())
		return;

	// The dump's "model" is not reliable for *_spawn objects: the game picks the model from the class (a
	// medkit can have ammo_stack.mdl).
	char sShow[PLATFORM_MAX_PATH];
	if (!ModelOfClass(sClass, sShow, sizeof(sShow)))
	{
		if (sModel[0] != '\0' && sModel[0] != '*')
			strcopy(sShow, sizeof(sShow), sModel);
		else
			strcopy(sShow, sizeof(sShow), "models/props_junk/gascan001a.mdl");
	}

	g_aHammer.Push(hammer);
	g_aKind.PushString(sKind);
	g_aModel.PushString(sShow);
	g_aOrigin.PushArray(vOrig);
	g_aAngLoaded.PushArray(vAng);
	g_aPos.PushArray(vOrig);
	g_aAng.PushArray(vAng);
	g_aCopy.Push(INVALID_ENT_REFERENCE);
	g_aEnt.Push(INVALID_ENT_REFERENCE);
	g_aSurvival.Push(StrEqual(sNameT, "weapons_survival"));
	g_aReal.PushArray(vOrig);
	g_aAngReal.PushArray(vAng);
	g_aBlock.PushString(sBlock);
}

// Real model of the objects the game creates from their class
bool ModelOfClass(const char[] c, char[] out, int len)
{
	if      (StrEqual(c, "weapon_first_aid_kit_spawn"))  strcopy(out, len, "models/w_models/weapons/w_eq_medkit.mdl");
	else if (StrEqual(c, "weapon_pain_pills_spawn"))     strcopy(out, len, "models/w_models/weapons/w_eq_painpills.mdl");
	else if (StrEqual(c, "weapon_adrenaline_spawn"))     strcopy(out, len, "models/w_models/weapons/w_eq_adrenaline.mdl");
	else if (StrEqual(c, "weapon_defibrillator_spawn"))  strcopy(out, len, "models/w_models/weapons/w_eq_defibrillator.mdl");
	else if (StrEqual(c, "weapon_molotov_spawn"))        strcopy(out, len, "models/w_models/weapons/w_eq_molotov.mdl");
	else if (StrEqual(c, "weapon_pipe_bomb_spawn"))      strcopy(out, len, "models/w_models/weapons/w_eq_pipebomb.mdl");
	else if (StrEqual(c, "weapon_vomitjar_spawn"))       strcopy(out, len, "models/w_models/weapons/w_eq_bile_flask.mdl");
	else if (StrEqual(c, "weapon_upgradepack_incendiary_spawn")) strcopy(out, len, "models/w_models/weapons/w_eq_incendiary_ammopack.mdl");
	else if (StrEqual(c, "weapon_upgradepack_explosive_spawn"))  strcopy(out, len, "models/w_models/weapons/w_eq_explosive_ammopack.mdl");
	else if (StrEqual(c, "weapon_ammo_spawn"))           strcopy(out, len, "models/props/terror/ammo_stack.mdl");
	else if (StrEqual(c, "weapon_grenade_launcher_spawn")) strcopy(out, len, "models/w_models/weapons/w_grenade_launcher.mdl");
	else
		return false;
	return true;
}

// Name of object i in the player's language: g_aTipo holds the phrase key (type_...), or the raw
// name for weapons without a phrase
void TypeName(int i, int client, char[] out, int len)
{
	char sKey[64];
	g_aKind.GetString(i, sKey, sizeof(sKey));
	if (StrContains(sKey, "type_") == 0)
		Tr(out, len, client, sKey);
	else
		strcopy(out, len, sKey);
}

bool ReadableName(const char[] c, const char[] m, char[] out, int len)
{
	if      (StrEqual(c, "weapon_first_aid_kit_spawn"))  strcopy(out, len, "type_medkit");
	else if (StrEqual(c, "weapon_pain_pills_spawn"))     strcopy(out, len, "type_pills");
	else if (StrEqual(c, "weapon_adrenaline_spawn"))     strcopy(out, len, "type_adrenaline");
	else if (StrEqual(c, "weapon_defibrillator_spawn"))  strcopy(out, len, "type_defib");
	else if (StrEqual(c, "weapon_molotov_spawn"))        strcopy(out, len, "type_molotov");
	else if (StrEqual(c, "weapon_pipe_bomb_spawn"))      strcopy(out, len, "type_pipebomb");
	else if (StrEqual(c, "weapon_vomitjar_spawn"))       strcopy(out, len, "type_bile");
	else if (StrEqual(c, "weapon_upgradepack_incendiary_spawn")) strcopy(out, len, "type_ammo_incendiary");
	else if (StrEqual(c, "weapon_upgradepack_explosive_spawn"))  strcopy(out, len, "type_ammo_explosive");
	else if (StrEqual(c, "weapon_grenade_launcher_spawn")) strcopy(out, len, "type_grenade_launcher");
	else if (StrEqual(c, "weapon_ammo_spawn"))           strcopy(out, len, "type_ammo");
	else if (StrEqual(c, "prop_physics") && StrContains(m, "gascan001a", false) != -1)         strcopy(out, len, "type_gascan");
	else if (StrEqual(c, "prop_physics") && StrContains(m, "propanecanister001a", false) != -1) strcopy(out, len, "type_propane");
	else if (StrEqual(c, "prop_physics") && StrContains(m, "oxygentank01", false) != -1)       strcopy(out, len, "type_oxygen");
	else if (StrEqual(c, "prop_physics") && StrContains(m, "explosive_box001", false) != -1)   strcopy(out, len, "type_fireworks");
	else if (StrContains(c, "weapon_") == 0 && StrContains(c, "_spawn") != -1)
	{
		// other weapons: weapon_xxx_spawn -> xxx
		strcopy(out, len, c[7]);
		int fine = StrContains(out, "_spawn");
		if (fine != -1)
			out[fine] = '\0';
	}
	else
		return false;
	return true;
}

void MenuList(int client, int first)
{
	int n = g_aHammer.Length;
	if (n == 0)
	{
		Chat(client, "no_movable");
		MenuMain(client);
		return;
	}

	// sorted by distance from the editor
	float vMine[3];
	GetClientAbsOrigin(client, vMine);
	ArrayList order = new ArrayList(2);
	float v[3];
	for (int i = 0; i < n; i++)
	{
		if (!IsMovable(i))
			continue;
		g_aPos.GetArray(i, v);
		int line = order.Push(GetVectorDistance(vMine, v));
		order.Set(line, i, 1);
	}
	order.Sort(Sort_Ascending, Sort_Float);
	n = order.Length;
	if (n == 0)
	{
		delete order;
		Chat(client, "no_movable");
		MenuMain(client);
		return;
	}

	int pages = (n + 5) / 6;
	if (first < 0) first = 0;
	if (first >= pages) first = pages - 1;
	g_iListPage[client] = first;
	Menu m = new Menu(Menu_List);
	{ char sT[96]; Tr(sT, sizeof(sT), client, "list_title", n, first + 1, pages); m.SetTitle("%s", sT); }
	char sKind[64], sItem[96], sInfo[12];
	for (int k = first * 6; k < n && k < first * 6 + 6; k++)
	{
		int i = order.Get(k, 1);
		float dist = view_as<float>(order.Get(k, 0)) * UNITS_TO_METRES;
		TypeName(i, client, sKind, sizeof(sKind));
		int h = g_aHammer.Get(i);
		if (h > 0)
			FormatEx(sItem, sizeof(sItem), "%s #%d — %.0f m%s%s", sKind, h, dist,
				g_aSurvival.Get(i) ? " [S]" : "", MovedFromReal(i) ? " *" : "");
		else
		{
			char sDist[16];
			FormatEx(sDist, sizeof(sDist), "%.0f", dist);
			Tr(sItem, sizeof(sItem), client, "list_no_hammer", sKind, sDist);
		}
		IntToString(i, sInfo, sizeof(sInfo));
		int other = Holder(i, client);
		if (other != 0)
		{
			char sWho[48];
			FormatEx(sWho, sizeof(sWho), " (%N)", other);
			StrCat(sItem, sizeof(sItem), sWho);
		}
		m.AddItem(sInfo, sItem, other != 0 ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	}
	delete order;
	while (m.ItemCount < 6)
		m.AddItem("_", "", ITEMDRAW_SPACER);
	MenuEntry(m, client, "before", "item_page_prev", first > 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	MenuEntry(m, client, "after", "item_page_next", first < pages - 1 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	Zero(m, client, "item_back", true, false);
	m.Display(client, MENU_TIME_FOREVER);
}

public int Menu_List(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
		LogChoice(m, client, item, "List");
	if (a == MenuAction_Select)
	{
		char s[24];
		m.GetItem(item, s, sizeof(s));
		if (StrEqual(s, "zero"))
		{
			MenuMain(client);
			return 0;
		}
		if (StrEqual(s, "nine"))
		{
			MenuNine(client);
			MenuList(client, g_iListPage[client]);
			return 0;
		}
		if (StrEqual(s, "before") || StrEqual(s, "after"))
		{
			MenuList(client, g_iListPage[client] + (StrEqual(s, "after") ? 1 : -1));
			return 0;
		}
		int i = StringToInt(s);
		if (g_aHammer.Get(i) <= 0)
		{
			LogEditor(client, "object without hammerid: cannot be selected");
			Chat(client, "no_hammerid");
			MenuList(client, g_iListPage[client]);
			return 0;
		}
		if (HeldByOthers(client, i))
		{
			MenuList(client, g_iListPage[client]);
			return 0;
		}
		SelectObject(client, i);
		g_bFromList[client] = true;
		// From the list the object comes straight into the hand, on the crosshair at a little over 2 m:
		// the editor is already standing where it should go
		Grab(client);
		g_fDistance[client] = 128.0;
		MenuObject(client);
	}
	else if (a == MenuAction_Cancel && item == MenuCancel_ExitBack)
		MenuMain(client);
	else if (a == MenuAction_Cancel && item == MenuCancel_Exit && InEditor(client))
	{
		Hint(client, "hint_list_in_use");     // a key on a grey item: an object in another editor's hand
		MenuList(client, g_iListPage[client]);
	}
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

void SelectObject(int client, int i)
{
	g_iPose[client] = -1;
	if (i != g_iChosen[client])
		g_aFilled[client].Clear();  // new object: new pile
	ReleaseObject(client);
	if (g_iChosen[client] != -1 && g_iChosen[client] != i && !IsMoved(g_iChosen[client]))
		RemoveCopy(g_iChosen[client]);
	if (g_iChosen[client] != -1)
	{
		SetOutline(g_iChosen[client], false);
		Untouchable(g_iChosen[client], false);
	}
	g_iChosen[client] = i;
	Untouchable(i, true);
	char sKind[64];
	TypeName(i, client, sKind, sizeof(sKind));
	LogEditor(client, "select %s #%d", sKind, g_aHammer.Get(i));
	CreateCopy(i);
	SetOutline(i, true);
}

void MenuObject(int client)
{
	char sTitle[384];
	MenuTitle(client, sTitle, sizeof(sTitle));
	strcopy(g_sLastTitle[client], sizeof(g_sLastTitle[]), sTitle);
	g_iMenuOpen[client] = 2;

	Menu m = new Menu(Menu_Object);
	m.SetTitle("%s", sTitle);
	// Fixed places: every item always has the same number; where an item does not exist in the current
	// mode, its place stays empty or holds that mode's item.
	//  1 Move   2 Move and rotate   3 Drop | Pause   4 Add | Wall | Pose
	//  5 Restore to the original   6 Stop the mode | Pose | Wrong object   7 Settings
	MenuEntry(m, client, "move", g_bGrabbed[client] ? "item_move_active" : "item_move");
	MenuEntry(m, client, "combo", g_bCombo[client] ? "item_combo_active" : "item_combo");
	// 3
	if (g_bFineMove[client] || g_bRotate[client])
		MenuEntry(m, client, "pause", g_bPaused[client] ? "item_resume" : "item_pause");
	else
		MenuEntry(m, client, "drop", "item_drop");
	// 4
	if (g_bFineMove[client])
		MenuEntry(m, client, "wall", g_bWallAligned[client] ? "item_align_map" : "item_align_wall");
	else if (g_bRotate[client])
	{
		char sPose[64];
		char sPoseName[48];
		Tr(sPoseName, sizeof(sPoseName), client, POSE_NAMES[(g_iPose[client] + 1) % 6]);
		Tr(sPose, sizeof(sPose), client, "item_next_pose", sPoseName);
		m.AddItem("flat", sPose);
	}
	else if (!g_bGrabbed[client])
	{
		char sFill[80];
		int available = AvailableForFill(client);
		if (available > 0)
			Tr(sFill, sizeof(sFill), client, "item_fill", available);
		else
			Tr(sFill, sizeof(sFill), client, "item_fill_none");
		m.AddItem("fill", sFill);
	}
	else
		m.AddItem("_", "", ITEMDRAW_SPACER);
	// 5
	MenuEntry(m, client, "orig", "item_restore", MovedFromReal(g_iChosen[client]) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	// 6
	if (g_bCombo[client])
	{
		if (g_bRotate[client])
		{
			char sPose2[64];
			char sPoseName2[48];
			Tr(sPoseName2, sizeof(sPoseName2), client, POSE_NAMES[(g_iPose[client] + 1) % 6]);
			Tr(sPose2, sizeof(sPose2), client, "item_next_pose", sPoseName2);
			m.AddItem("flat", sPose2);
		}
		else
			m.AddItem("_", "", ITEMDRAW_SPACER);
	}
	else if (g_bFineMove[client])
		MenuEntry(m, client, "fine", "item_fine_active");
	else if (g_bRotate[client])
		MenuEntry(m, client, "rot", "item_rot_active");
	else if (g_bGrabbed[client] && g_bFromList[client])
		MenuEntry(m, client, "wrong", "item_wrong");
	else
		m.AddItem("_", "", ITEMDRAW_SPACER);
	// Settings is always on 7, in every menu
	while (m.ItemCount < 6)
		m.AddItem("_", "", ITEMDRAW_SPACER);
	MenuEntry(m, client, "options", "item_settings");
	Zero(m, client, "item_back");
	m.Display(client, MENU_TIME_FOREVER);
}

// One Settings menu, the same wherever it is opened from. Every item always has its place: when it
// cannot be used it is grey, it does not disappear. No Undo/Redo here, so 8 and 9 stay free.
// Settings: an index and three one-page sections. Work = everyday things; Appearance = personal;
// Server = for everyone, owner only.
void MenuSettings(int client)
{
	Menu m = new Menu(Menu_Settings);
	int section = g_iSettingsPage[client];
	if (section == 3 && !IsOwner(client))
		section = g_iSettingsPage[client] = 0;
	char sItem[64], sSt[32], sT[96], sName[48];
	static const char SECTION_NAMES[][] = { "", "settings_sec_work", "settings_sec_look", "settings_sec_server" };
	if (section == 0)
		Tr(sT, sizeof(sT), client, "settings_title");
	else
	{
		Tr(sName, sizeof(sName), client, SECTION_NAMES[section]);
		Tr(sT, sizeof(sT), client, "settings_title_sec", sName);
	}
	m.SetTitle("%s", sT);
	if (section == 0)
	{
		MenuEntry(m, client, "sec1", "settings_sec_work");
		MenuEntry(m, client, "sec2", "settings_sec_look");
		if (IsOwner(client))
			MenuEntry(m, client, "sec3", "settings_sec_server");
	}
	else if (section == 1)
	{
		// work: the most used things
		int chosen = (g_iChosen[client] != -1) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED;
		NoclipSpeedItems(m, client);
		MenuEntry(m, client, "goto", "item_goto", chosen);
		MenuEntry(m, client, "list", (g_iChosen[client] != -1 && g_bFromList[client]) ? "item_back_list" : "item_other_list", chosen);
		MenuEntry(m, client, "fine", "item_fine", chosen);
		MenuEntry(m, client, "rot", "item_rot", chosen);
		// Test explosions: to see the effect without leaving the editor
		Tr(sSt, sizeof(sSt), client, g_bExplosions ? "state_on" : "state_off");
		Tr(sItem, sizeof(sItem), client, "item_explosions", sSt);
		m.AddItem("explode", sItem);
		MenuEntry(m, client, "boom", "item_explode_now", (g_bExplosions && g_iChosen[client] != -1 && IsExplosive(g_iChosen[client])) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	}
	else if (section == 2)
	{
		// appearance: personal, only for whoever chooses them
		Tr(sSt, sizeof(sSt), client, g_bHintOff[client] ? "state_hints_off" : "state_hints_on");
		Tr(sItem, sizeof(sItem), client, "item_hints", sSt);
		m.AddItem("hint", sItem);
		Tr(sSt, sizeof(sSt), client, g_bPanelOff[client] ? "state_off" : "state_on");
		Tr(sItem, sizeof(sItem), client, "item_panel", sSt);
		m.AddItem("panel", sItem);
		if (g_iLanguage[client] == 0)
			Tr(sSt, sizeof(sSt), client, "lang_auto");
		else
			strcopy(sSt, sizeof(sSt), LANGUAGE_NAMES[g_iLanguage[client]]);
		Tr(sItem, sizeof(sItem), client, "item_language", sSt);
		m.AddItem("language", sItem);
	}
	else
	{
		// server: for everyone, owner only
		Tr(sSt, sizeof(sSt), client, g_bFreeMode ? "map_mode_free" : "map_mode_faithful");
		Tr(sItem, sizeof(sItem), client, "item_map_mode", sSt);
		m.AddItem("mode", sItem);
		char sAuto[32];
		AutosaveName(client, sAuto, sizeof(sAuto));
		Tr(sItem, sizeof(sItem), client, "item_autosave", sAuto);
		m.AddItem("auto", sItem);
		Tr(sSt, sizeof(sSt), client, g_bEditorOpen ? "access_open" : "access_closed");
		Tr(sItem, sizeof(sItem), client, "item_editor_access", sSt);
		m.AddItem("access", sItem);
		MenuEntry(m, client, "players", "item_players");
		Tr(sSt, sizeof(sSt), client, g_bCooperative ? "state_on" : "state_off");
		Tr(sItem, sizeof(sItem), client, "item_coop", sSt);
		m.AddItem("coop", sItem);
		MenuEntry(m, client, "map", "item_change_map");
	}
	Zero(m, client, "item_back", false, false);
	m.Display(client, MENU_TIME_FOREVER);
}

// Language choice: every language written in its own language, the current one grey
void MenuLanguages(int client)
{
	Menu m = new Menu(Menu_Languages);
	char sItem[64], sSt[32], sNum[4];
	if (g_iLanguage[client] == 0)
		Tr(sSt, sizeof(sSt), client, "lang_auto");
	else
		strcopy(sSt, sizeof(sSt), LANGUAGE_NAMES[g_iLanguage[client]]);
	Tr(sItem, sizeof(sItem), client, "item_language", sSt);
	m.SetTitle("%s", sItem);
	for (int i = 0; i < sizeof(LANGUAGE_CODES); i++)
	{
		IntToString(i, sNum, sizeof(sNum));
		if (i == 0)
			Tr(sItem, sizeof(sItem), client, "lang_auto");
		else
			strcopy(sItem, sizeof(sItem), LANGUAGE_NAMES[i]);
		m.AddItem(sNum, sItem, (i == g_iLanguage[client]) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	}
	Zero(m, client, "item_back", false, false);
	m.Display(client, MENU_TIME_FOREVER);
}

public int Menu_Languages(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
	{
		LogChoice(m, client, item, "Languages");
		char s[24];
		m.GetItem(item, s, sizeof(s));
		if (!StrEqual(s, "zero"))
		{
			g_iLanguage[client] = StringToInt(s);
			if (AreClientCookiesCached(client))
				g_ckLanguage.Set(client, LANGUAGE_CODES[g_iLanguage[client]]);
			ApplyLanguage(client);
			if (InEditor(client) && g_bHud && HudSource() == client)
				EditorPanel(true);                  // the panel is rewritten in the new language
		}
		MenuSettings(client);
	}
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

// Compatibility: the old places that opened "Options" open the same menu
void MenuOptions(int client)
{
	MenuSettings(client);
}

public int Menu_Settings(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
		LogChoice(m, client, item, "Settings");
	if (a == MenuAction_Select)
	{
		char s[24];
		m.GetItem(item, s, sizeof(s));
		if (StrEqual(s, "noclip"))
			SetNoclip(client, !g_bNoclip[client]);
		else if (StrEqual(s, "speed"))
			ChangeSpeed(client);
		else if (StrEqual(s, "goto") && g_iChosen[client] != -1)
			GoToObject(client);
		else if (StrEqual(s, "fine") && g_iChosen[client] != -1)
		{
			FineStart(client);
			MenuObject(client);
			return 0;
		}
		else if (StrEqual(s, "rot") && g_iChosen[client] != -1)
		{
			RotateStart(client);
			MenuObject(client);
			return 0;
		}
		else if (StrEqual(s, "list") && g_iChosen[client] != -1)
		{
			Deselect(client);
			MenuList(client, 0);
			return 0;
		}
		else if (StrEqual(s, "hint"))
		{
			g_bHintOff[client] = !g_bHintOff[client];
			if (AreClientCookiesCached(client))
				g_ckHint.Set(client, g_bHintOff[client] ? "0" : "1");
		}
		else if (StrEqual(s, "sec1") || StrEqual(s, "sec2") || StrEqual(s, "sec3"))
			g_iSettingsPage[client] = s[3] - '0';
		else if (StrEqual(s, "auto") && IsOwner(client))
			CycleAutosave();
		else if (StrEqual(s, "mode") && IsOwner(client))
		{
			g_bFreeMode = !g_bFreeMode;
			SaveServerSettings();
			LogEditor(client, "map mode: %s", g_bFreeMode ? "free" : "faithful");
			char sM[32];
			for (int k = 1; k <= MaxClients; k++)
				if (IsClientInGame(k) && !IsFakeClient(k))
				{
					Tr(sM, sizeof(sM), k, g_bFreeMode ? "map_mode_free" : "map_mode_faithful");
					Chat(k, "map_mode_changed", sM);
				}
			if (!g_bFreeMode && g_iChosen[client] != -1 && !IsMovable(g_iChosen[client]))
			{
				Deselect(client);       // the chosen object no longer moves in faithful mode
				MenuSettings(client);
				return 0;
			}
		}
		else if (StrEqual(s, "explode"))
		{
			g_bExplosions = !g_bExplosions;
			ProtectExplosives(!g_bExplosions);
			LogEditor(client, "test explosions %s", g_bExplosions ? "on" : "off");
			if (g_bExplosions)
				Chat(client, "explosions_on");
		}
		else if (StrEqual(s, "boom") && g_bExplosions && g_iChosen[client] != -1)
		{
			int i = g_iChosen[client];
			Deselect(client);
			int e = RealOf(i);
			if (e > MaxClients)
			{
				LogEditor(client, "blows up #%d (test)", g_aHammer.Get(i));
				AcceptEntityInput(e, "Break");
			}
		}
		else if (StrEqual(s, "map") && IsOwner(client))
		{
			MenuCampaigns(client);
			return 0;
		}
		else if (StrEqual(s, "players") && IsOwner(client))
		{
			MenuPlayers(client);
			return 0;
		}
		else if (StrEqual(s, "coop") && IsOwner(client))
		{
			g_bCooperative = !g_bCooperative;
			SaveServerSettings();
			LogEditor(client, "cooperative: %s", g_bCooperative ? "on" : "off");
			Chat(client, g_bCooperative ? "coop_on" : "coop_off");
		}
		else if (StrEqual(s, "access") && IsOwner(client))
		{
			g_bEditorOpen = !g_bEditorOpen;
			SaveServerSettings();
			LogEditor(client, "editor access: %s", g_bEditorOpen ? "open" : "closed");
			if (g_bEditorOpen)
				for (int ap = 1; ap <= MaxClients; ap++)         // whoever has the permission is told
					if (ap != client && IsClientInGame(ap) && !IsFakeClient(ap) && !InEditor(ap) && IsAuthorized(ap))
						{
							char sEnter[32];
							CommandText(sEnter, sizeof(sEnter), false);
							Chat(ap, "editor_reopened", sEnter);
						}
			if (!g_bEditorOpen)
				for (int ex = 1; ex <= MaxClients; ex++)
					if (g_bInEditor[ex] && !IsOwner(ex))
					{
						LeaveEditor(ex);
						Chat(ex, "editor_closed");
					}
		}
		else if (StrEqual(s, "language"))
		{
			MenuLanguages(client);
			return 0;
		}
		else if (StrEqual(s, "panel"))
		{
			g_bPanelOff[client] = !g_bPanelOff[client];
			if (AreClientCookiesCached(client))
				g_ckPanel.Set(client, g_bPanelOff[client] ? "0" : "1");
			if (InEditor(client) && EditorMode() && HudSource() == client)
				EditorPanel(!g_bPanelOff[client]);
			else if (InEditor(client) && EditorMode())
				Chat(client, "panel_not_yours");
		}
		else if (StrEqual(s, "zero"))
		{
			if (g_iSettingsPage[client] != 0)
				g_iSettingsPage[client] = 0;           // from a section back to the index
			else
			{
				if (g_iChosen[client] != -1) MenuObject(client); else MenuMain(client);
				return 0;
			}
		}
		MenuSettings(client);
	}
	else if (a == MenuAction_Cancel && item == MenuCancel_ExitBack && g_iChosen[client] != -1)
		MenuObject(client);
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

bool SurvivalMode()
{
	char s[32];
	FindConVar("mp_gamemode").GetString(s, sizeof(s));
	return StrEqual(s, "survival", false) || StrEqual(s, "zfstrippermapeditor", false);
}

// The "zfstrippermapeditor" mutation (Survival with a mode script): only there the HUD shows
bool EditorMode()
{
	char s[32];
	FindConVar("mp_gamemode").GetString(s, sizeof(s));
	return StrEqual(s, "zfstrippermapeditor", false);
}

// Clears the selection: no outline, and the copy disappears if the object was not moved
void Deselect(int client)
{
	if (g_iChosen[client] == -1)
		return;
	ReleaseObject(client);
	SetOutline(g_iChosen[client], false);
	Untouchable(g_iChosen[client], false);
	if (!IsMoved(g_iChosen[client]))
		RemoveCopy(g_iChosen[client]);
	LogEditor(client, "deselect #%d", g_aHammer.Get(g_iChosen[client]));
	g_iChosen[client] = -1;
}

public int Menu_Object(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
		LogChoice(m, client, item, "Object");
	// really closed (not replaced by a new menu): no more updates
	if (a == MenuAction_Select || (a == MenuAction_Cancel && item != MenuCancel_Interrupted))
		g_iMenuOpen[client] = 0;
	if (a == MenuAction_Select)
	{
		char s[24];
		m.GetItem(item, s, sizeof(s));
		if (StrEqual(s, "move"))
		{
			if (g_bGrabbed[client]) ReleaseObject(client); else Grab(client);
			MenuObject(client);
		}
		else if (StrEqual(s, "fine"))
		{
			if (g_bFineMove[client]) FineStopMode(client); else FineStart(client);
			MenuObject(client);
		}
		else if (StrEqual(s, "combo"))
		{
			if (g_bCombo[client]) { FineStopMode(client); RotateStop(client); } else ComboStart(client);
			MenuObject(client);
		}
		else if (StrEqual(s, "zero"))
		{
			Deselect(client);
			MenuMain(client);
		}
		else if (StrEqual(s, "eight"))
		{
			Redo(client);
			if (g_iChosen[client] != -1) MenuObject(client); else MenuMain(client);
		}
		else if (StrEqual(s, "nine"))
		{
			MenuNine(client);
			if (g_iChosen[client] != -1) MenuObject(client); else MenuMain(client);
		}
		else if (StrEqual(s, "wrong"))
		{
			WrongObject(client);
			return 0;
		}
		else if (StrEqual(s, "fill"))
		{
			Fill(client);
			MenuObject(client);
		}
		else if (StrEqual(s, "drop"))
		{
			DropObject(client);
			MenuObject(client);
		}
		else if (StrEqual(s, "wall"))
		{
			if (g_bWallAligned[client]) AlignToMap(client); else StartWallChoice(client);
			MenuObject(client);
		}
		else if (StrEqual(s, "pause"))
		{
			PauseMode(client, !g_bPaused[client]);
			MenuObject(client);
		}
		else if (StrEqual(s, "flat"))
		{
			NextPose(client);
			MenuObject(client);
		}
		else if (StrEqual(s, "rot"))
		{
			if (g_bRotate[client]) RotateStop(client); else RotateStart(client);
			MenuObject(client);
		}
		else if (StrEqual(s, "undo"))
		{
			Undo(client, g_aHammer.Get(g_iChosen[client]));
			MenuObject(client);
		}
		else if (StrEqual(s, "orig"))
		{
			RestoreOriginal(client);
			MenuObject(client);
		}
		else if (StrEqual(s, "options"))
		{
			g_iSettingsPage[client] = 0;
			MenuOptions(client);
		}
		else
		{
			Deselect(client);
			MenuList(client, 0);
		}
	}
	else if (a == MenuAction_Cancel && item == MenuCancel_Exit && InEditor(client) && g_iChosen[client] != -1)
	{
		LogMessage("[editor] [menu] %N: object menu closed without a choice (grey item?): opening it again", client);
		MenuObject(client);
	}
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

// Moved from its real original place: that is where the ghost stays (comparing with the loaded map
// left ghosts on the saved places after a reset).
bool IsMoved(int i)
{
	return MovedFromReal(i);
}

// Different from the map loaded now: work not yet saved and reloaded
bool DifferentFromMap(int i)
{
	float a[3], b[3], ra[3], rb[3];
	g_aOrigin.GetArray(i, a);
	g_aPos.GetArray(i, b);
	g_aAngLoaded.GetArray(i, ra);
	g_aAng.GetArray(i, rb);
	return GetVectorDistance(a, b) > 0.05 || GetVectorDistance(ra, rb) > 0.05;
}

// ---------------------------------------------------------------- real object and ghost
// The REAL object is moved, in game. A grey see-through ghost stays at its former place, visible
// only to the editor. If the real object is gone (for example picked up), the ghost moves instead.

int CopyOf(int i)
{
	return EntRefToEntIndex(g_aCopy.Get(i));
}

// The map object, looked up once and then kept in memory
int RealOf(int i)
{
	int e = EntRefToEntIndex(g_aEnt.Get(i));
	if (e > MaxClients && IsValidEntity(e))
		return e;
	e = RealObject(g_aHammer.Get(i));
	g_aEnt.Set(i, e > MaxClients ? EntIndexToEntRef(e) : INVALID_ENT_REFERENCE);
	return e;
}

// What moves: the real object, or the ghost if the real one is gone
int Movable(int i)
{
	int e = RealOf(i);
	return e > MaxClients ? e : CopyOf(i);
}

void CreateCopy(int i)
{
	if (CopyOf(i) > MaxClients)
		return;
	bool hasReal = RealOf(i) > MaxClients;
	if (hasReal && !IsMoved(i))
		return;                    // the ghost is needed only if the object moved
	char sModel[PLATFORM_MAX_PATH];
	ModelOf(i, sModel, sizeof(sModel));
	if (!IsModelPrecached(sModel) && PrecacheModel(sModel) == 0)
	{
		LogMessage("[editor] model not available: %s", sModel);
		return;
	}
	int e = CreateEntityByName("prop_dynamic_override");
	if (e == -1)
		return;
	DispatchKeyValue(e, "model", sModel);
	DispatchKeyValue(e, "solid", "0");
	DispatchKeyValue(e, "rendermode", "1");
	DispatchKeyValue(e, "disableshadows", "1");
	DispatchSpawn(e);
	SetEntityRenderMode(e, RENDER_TRANSALPHA);
	if (hasReal)
		SetEntityRenderColor(e, 150, 150, 150, 90);    // ghost of the former place
	else
		SetEntityRenderColor(e, 120, 200, 255, 140);   // no real object: this one moves
	SDKHook(e, SDKHook_SetTransmit, Hook_EditorsOnly);

	float v[3], an[3];
	if (hasReal)
	{
		g_aReal.GetArray(i, v);
		g_aAngReal.GetArray(i, an);
	}
	else
	{
		g_aPos.GetArray(i, v);
		g_aAng.GetArray(i, an);
	}
	TeleportEntity(e, v, an, NULL_VECTOR);
	g_aCopy.Set(i, EntIndexToEntRef(e));
}

// Glows (L4D2 glow) of the selected object: yellow on the one that moves, light blue on the ghost
// of the former place.
#define COLOR_YELLOW  (255 + (200 << 8))
#define COLOR_LIGHTBLUE (80 + (180 << 8) + (255 << 16))

void SetOutline(int i, bool isOn)
{
	if (g_bCoopMarks && isOn && EditorCount() > 1 && InUseBy(i) != 0)
		isOn = false;          // in cooperative mode the outline of the object in hand comes from the marks (SegniCoop)
	int real = RealOf(i);
	if (real > MaxClients)
	{
		Aura(real, isOn, COLOR_YELLOW);
		Aura(CopyOf(i), isOn, COLOR_LIGHTBLUE);
	}
	else
		Aura(CopyOf(i), isOn, COLOR_YELLOW);
}

void Aura(int e, bool isOn, int colour)
{
	if (e <= MaxClients || !IsValidEntity(e) || !HasEntProp(e, Prop_Send, "m_iGlowType"))
		return;
	SetEntProp(e, Prop_Send, "m_iGlowType", isOn ? 3 : 0);
	SetEntProp(e, Prop_Send, "m_glowColorOverride", colour);
	SetEntProp(e, Prop_Send, "m_nGlowRange", 0);
}

// The map object with that hammerid (-1 if it is gone, for example picked up)
int RealObject(int hammer)
{
	int n = GetMaxEntities();
	for (int e = MaxClients + 1; e < n; e++)
	{
		if (IsValidEntity(e) && HasEntProp(e, Prop_Data, "m_iHammerID")
		 && GetEntProp(e, Prop_Data, "m_iHammerID") == hammer)
			return e;
	}
	return -1;
}

// Only the editor sees the ghost
public Action Hook_EditorsOnly(int entity, int client)
{
	return InEditor(client) ? Plugin_Continue : Plugin_Handled;
}

void RemoveCopy(int i)
{
	int e = CopyOf(i);
	if (e > MaxClients)
		RemoveEntity(e);
	g_aCopy.Set(i, INVALID_ENT_REFERENCE);
}

// On leaving the ghosts disappear; the real objects stay where they are until the map reloads
// (with a save they stay there afterwards too).
void RemoveCopies()
{
	for (int c = 1; c <= MaxClients; c++)
	{
		RemovePreview(c);
		RemoveMarks(c);
	}
	for (int i = 0; i < g_aCopy.Length; i++)
	{
		SetOutline(i, false);
		RemoveCopy(i);
	}
}

// Ghost at the former place only if the object moved
void GreyOriginal(int i, bool grey)
{
	if (RealOf(i) <= MaxClients)
		return;
	if (grey)
	{
		CreateCopy(i);
		if (InUseBy(i) != 0)
			Aura(CopyOf(i), true, COLOR_LIGHTBLUE);
	}
	else
		RemoveCopy(i);
}

// ---------------------------------------------------------------- cooperative marks
// The outline belongs to the object and is the same for everyone: with several editors the object
// in hand has no outline and on top of it there are two nearly invisible copies, a yellow one only
// its holder sees and a red one the others see, meaning "cannot be taken". Alone, nothing changes.
#define COLOR_RED (255 + (30 << 8) + (30 << 16))

// The game always sends an object with an outline to everyone (FL_EDICT_ALWAYS), so the filter does
// not count: the mark would show both colours. The flag is removed on every send.
void RemoveSendToAll(int entity)
{
	if (GetEdictFlags(entity) & FL_EDICT_ALWAYS)
		SetEdictFlags(entity, GetEdictFlags(entity) ^ FL_EDICT_ALWAYS);
}

public Action Hook_OwnerOnly(int entity, int client)
{
	RemoveSendToAll(entity);
	return client == g_iMarkOwner[entity] ? Plugin_Continue : Plugin_Handled;
}

// Column of light: only the holder. The send flag is not touched here: without it the column was
// drawn offset
public Action Hook_BeamOwner(int entity, int client)
{
	return client == g_iMarkOwner[entity] ? Plugin_Continue : Plugin_Handled;
}

public Action Hook_AllButOwner(int entity, int client)
{
	RemoveSendToAll(entity);
	return client != g_iMarkOwner[entity] ? Plugin_Continue : Plugin_Handled;
}

int CreateMark(int c, int i, int colour, bool ownerOnly)
{
	char sModel[PLATFORM_MAX_PATH];
	ModelOf(i, sModel, sizeof(sModel));
	if (!IsModelPrecached(sModel) && PrecacheModel(sModel) == 0)
		return INVALID_ENT_REFERENCE;
	int e = CreateEntityByName("prop_dynamic_override");
	if (e == -1)
		return INVALID_ENT_REFERENCE;
	DispatchKeyValue(e, "model", sModel);
	DispatchKeyValue(e, "solid", "0");
	DispatchKeyValue(e, "disableshadows", "1");
	DispatchSpawn(e);
	SetEntityRenderMode(e, RENDER_TRANSALPHA);
	SetEntityRenderColor(e, 255, 255, 255, 1);       // the body is invisible, the outline stays
	float v[3], an[3];
	g_aPos.GetArray(i, v);
	g_aAng.GetArray(i, an);
	TeleportEntity(e, v, an, NULL_VECTOR);
	Aura(e, true, colour);
	g_iMarkOwner[e] = c;
	RemoveSendToAll(e);
	SDKHook(e, SDKHook_SetTransmit, ownerOnly ? Hook_OwnerOnly : Hook_AllButOwner);
	return EntIndexToEntRef(e);
}

void RemoveMarks(int c)
{
	int e = EntRefToEntIndex(g_iMarkYellow[c]);
	if (e > MaxClients)
		RemoveEntity(e);
	e = EntRefToEntIndex(g_iMarkRed[c]);
	if (e > MaxClients)
		RemoveEntity(e);
	g_iMarkYellow[c] = INVALID_ENT_REFERENCE;
	g_iMarkRed[c] = INVALID_ENT_REFERENCE;
	g_iMarkOf[c] = -1;
}

// Lines up the marks with who holds what (from the title timer, every 0.3 s)
void CoopMarks()
{
	bool coop = g_bCoopMarks && EditorCount() > 1;
	for (int c = 1; c <= MaxClients; c++)
	{
		int i = (coop && g_bInEditor[c]) ? g_iChosen[c] : -1;
		if (i == g_iMarkOf[c] && (i == -1 || EntRefToEntIndex(g_iMarkRed[c]) > MaxClients))
			continue;
		int before = g_iMarkOf[c];
		RemoveMarks(c);
		if (before != -1 && before < g_aHammer.Length)
			SetOutline(before, InUseBy(before) != 0);       // alone, the normal yellow outline comes back
		if (i == -1)
			continue;
		g_iMarkYellow[c] = CreateMark(c, i, COLOR_YELLOW, true);
		g_iMarkRed[c] = CreateMark(c, i, COLOR_RED, false);
		g_iMarkOf[c] = i;
		SetOutline(i, true);
	}
}

// The marks follow the object when it moves
void MarksFollow(int i)
{
	float v[3], an[3];
	g_aPos.GetArray(i, v);
	g_aAng.GetArray(i, an);
	for (int c = 1; c <= MaxClients; c++)
	{
		if (g_iMarkOf[c] != i)
			continue;
		int e = EntRefToEntIndex(g_iMarkYellow[c]);
		if (e > MaxClients)
			TeleportEntity(e, v, an, NULL_VECTOR);
		e = EntRefToEntIndex(g_iMarkRed[c]);
		if (e > MaxClients)
			TeleportEntity(e, v, an, NULL_VECTOR);
	}
}

// Brings the object (real, or the ghost if missing) to the editor's position
void UpdateCopy(int i)
{
	int e = Movable(i);
	if (e <= MaxClients)
		return;
	float v[3], an[3];
	g_aPos.GetArray(i, v);
	g_aAng.GetArray(i, an);
	if (e == RealOf(i))
	{
		char sClass[32];
		GetEntityClassname(e, sClass, sizeof(sClass));
		if (StrEqual(sClass, "prop_physics"))
			AcceptEntityInput(e, "DisableMotion");   // stays where it is put
	}
	TeleportEntity(e, v, an, view_as<float>({0.0, 0.0, 0.0}));
	MarksFollow(i);
}

// ---------------------------------------------------------------- grab / release

void Grab(int client)
{
	if (g_iChosen[client] == -1)
	{
		Chat(client, "select_first");
		return;
	}
	FineStopMode(client);
	RotateStop(client);
	UnlightLooked(client);
	float eyes[3], view[3], v[3], an[3];
	GetClientEyePosition(client, eyes);
	GetClientEyeAngles(client, view);
	g_aPos.GetArray(g_iChosen[client], v);
	g_aAng.GetArray(g_iChosen[client], an);
	g_fBeforePos[client] = v;
	g_fBeforeAng[client] = an;
	g_fDistance[client] = GetVectorDistance(eyes, v);
	if (g_fDistance[client] < DIST_MIN) g_fDistance[client] = DIST_MIN;
	if (g_fDistance[client] > DIST_MAX) g_fDistance[client] = 128.0;
	g_bNoclipAtGrab[client] = g_bNoclip[client];
	g_bGrabbed[client] = true;
	GrabSpeed(client, true);
	LogEditor(client, "grab #%d", g_aHammer.Get(g_iChosen[client]));
	Hint(client, "hint_grab");
}

void ReleaseObject(int client)
{
	FineStopMode(client);
	RotateStop(client);
	if (!g_bGrabbed[client])
		return;
	g_bGrabbed[client] = false;
	RemovePreview(client);
	GrabSpeed(client, false);
	RestoreNoclip(client);
	float v[3];
	g_aPos.GetArray(g_iChosen[client], v);
	RestAt(g_iChosen[client], v);
	g_aPos.SetArray(g_iChosen[client], v);
	UpdateCopy(g_iChosen[client]);
	GreyOriginal(g_iChosen[client], IsMoved(g_iChosen[client]));
	LogEditor(client, "release #%d at %.1f %.1f %.1f", g_aHammer.Get(g_iChosen[client]), v[0], v[1], v[2]);
	float an[3];
	g_aAng.GetArray(g_iChosen[client], an);
	if (GetVectorDistance(v, g_fBeforePos[client]) > 0.01 || GetVectorDistance(an, g_fBeforeAng[client]) > 0.01)
		ReturnPoint(client, g_iChosen[client], g_fBeforePos[client], g_fBeforeAng[client]);
}

// ---------------------------------------------------------------- selecting by looking

#define LOOK_DISTANCE 800.0
#define LOOK_RADIUS   45.0
// The outline of the object looked at is magenta: white is the game's own, so they are not confused
#define COLOR_WHITE   (255 + (0 << 8) + (220 << 16))

// The list object nearest to the line of sight (within GUARDA_RAGGIO) lights up. The search uses the
// list positions, so it also works on the copies, which are not solid. Use pressed with no object
// looked at: the log says which one was nearest to the line of sight and how far, to understand
// why it cannot be taken.
void LogNearest(int client)
{
	float eyes[3], view[3], fwd[3], v[3], d[3];
	GetClientEyePosition(client, eyes);
	GetClientEyeAngles(client, view);
	GetAngleVectors(view, fwd, NULL_VECTOR, NULL_VECTOR);
	int best = -1;
	float bestDist = 100000.0, bestAlong = 0.0;
	for (int i = 0; i < g_aHammer.Length; i++)
	{
		if (g_aHammer.Get(i) <= 0 || !IsMovable(i))
			continue;
		g_aPos.GetArray(i, v);
		v[2] += 8.0;
		SubtractVectors(v, eyes, d);
		float along = GetVectorDotProduct(d, fwd);
		if (along < 0.0)
			continue;
		float dist = SquareRoot(GetVectorDotProduct(d, d) - along * along);
		if (dist < bestDist)
		{
			bestDist = dist;
			bestAlong = along;
			best = i;
		}
	}
	if (best == -1)
	{
		LogMessage("[editor]   no object in front of you");
		return;
	}
	char sKind[64];
	TypeName(best, client, sKind, sizeof(sKind));
	g_aPos.GetArray(best, v);
	LogMessage("[editor]   %N, nearest to the view: %s #%d at %.0f from the line of sight (limit %.0f), distance %.0f (limit %.0f), pos %.0f %.0f %.0f, eyes %.0f %.0f %.0f",
		client, sKind, g_aHammer.Get(best), bestDist, LOOK_RADIUS, bestAlong, LOOK_DISTANCE, v[0], v[1], v[2], eyes[0], eyes[1], eyes[2]);
}

// Fallback size of an object by type (half side, in units), when the game does not give the
// entity's bounds
float ObjectRadius(int i)
{
	char sK[64];
	g_aKind.GetString(i, sK, sizeof(sK));
	if (StrEqual(sK, "type_pills") || StrEqual(sK, "type_adrenaline") || StrEqual(sK, "type_molotov")
	 || StrEqual(sK, "type_pipebomb") || StrEqual(sK, "type_bile"))
		return 8.0;
	if (StrEqual(sK, "type_medkit") || StrEqual(sK, "type_defib"))
		return 12.0;
	if (StrEqual(sK, "type_gascan") || StrEqual(sK, "type_propane") || StrEqual(sK, "type_oxygen"))
		return 18.0;
	if (StrEqual(sK, "type_ammo_incendiary") || StrEqual(sK, "type_ammo_explosive") || StrEqual(sK, "type_ammo"))
		return 16.0;
	return 14.0;
}

// Does the ray from the eye hit the object's box? Box = the entity's real bounds, rotated like it;
// if the game does not give them (non-solid objects), a box of the type's size. Returns the hit
// distance, or -1.0 on a miss: only the object really under the crosshair is selected, with no
// margin.
float RayHitsObject(int i, const float eyes[3], const float dir[3])
{
	int e = Movable(i);
	float o[3], an[3], mn[3], mx[3];
	mn = NULL_VECTOR;
	mx = NULL_VECTOR;
	if (e > MaxClients && HasEntProp(e, Prop_Send, "m_vecMins") && HasEntProp(e, Prop_Send, "m_vecMaxs"))
	{
		GetEntPropVector(e, Prop_Data, "m_vecAbsOrigin", o);
		GetEntPropVector(e, Prop_Data, "m_angAbsRotation", an);
		GetEntPropVector(e, Prop_Send, "m_vecMins", mn);
		GetEntPropVector(e, Prop_Send, "m_vecMaxs", mx);
	}
	else
	{
		g_aPos.GetArray(i, o);
		g_aAng.GetArray(i, an);
	}
	if (GetVectorDistance(mn, mx) < 2.0)
	{
		float r = ObjectRadius(i);
		mn[0] = -r; mn[1] = -r; mn[2] = 0.0;
		mx[0] = r;  mx[1] = r;  mx[2] = r * 1.2;
	}
	for (int k = 0; k < 3; k++)
	{
		mn[k] -= 1.5;
		mx[k] += 1.5;
	}
	float fw[3], rt[3], up[3], w[3], p[3], d[3];
	GetAngleVectors(an, fw, rt, up);
	SubtractVectors(eyes, o, w);
	p[0] = GetVectorDotProduct(w, fw);  p[1] = -GetVectorDotProduct(w, rt);  p[2] = GetVectorDotProduct(w, up);
	d[0] = GetVectorDotProduct(dir, fw); d[1] = -GetVectorDotProduct(dir, rt); d[2] = GetVectorDotProduct(dir, up);
	float t0 = 0.0, t1 = 100000.0;
	for (int k = 0; k < 3; k++)
	{
		if (FloatAbs(d[k]) < 0.000001)
		{
			if (p[k] < mn[k] || p[k] > mx[k])
				return -1.0;
			continue;
		}
		float a = (mn[k] - p[k]) / d[k], b = (mx[k] - p[k]) / d[k];
		if (a > b) { float tmp = a; a = b; b = tmp; }
		if (a > t0) t0 = a;
		if (b < t1) t1 = b;
		if (t0 > t1)
			return -1.0;
	}
	return t0;
}

void Look(int client)
{
	float now = GetGameTime();
	if (now < g_fNextLook[client] || g_aHammer.Length == 0)
		return;
	g_fNextLook[client] = now + 0.1;

	float eyes[3], view[3], fwd[3];
	GetClientEyePosition(client, eyes);
	GetClientEyeAngles(client, view);
	GetAngleVectors(view, fwd, NULL_VECTOR, NULL_VECTOR);

	int chosen = -1;
	float chosenT = LOOK_DISTANCE;             // the hit nearest to the eye wins
	for (int i = 0; i < g_aHammer.Length; i++)
	{
		if (g_aHammer.Get(i) <= 0)
			continue;
		float t = RayHitsObject(i, eyes, fwd);
		if (t >= 0.0 && t < chosenT)
		{
			chosenT = t;
			chosen = i;
		}
	}
	int other = (chosen != -1) ? Holder(chosen, client) : 0;
	int best = (chosen != -1 && IsMovable(chosen) && other == 0) ? chosen : -1;
	int blocked = (chosen != -1 && (!IsMovable(chosen) || other != 0)) ? chosen : -1;
	if (best == g_iLooked[client] && blocked == g_iBlocked[client])
		return;
	UnlightLooked(client);
	g_iLooked[client] = best;
	g_iBlocked[client] = blocked;
	// Label next to the crosshair: always name and number. The bottom hint: how to take the object, or
	// why it cannot be taken. Without an object a neutral message: the old text does not stay and
// there is no empty box.
	if (blocked != -1)
	{
		char sKindB[64];
		TypeName(blocked, client, sKindB, sizeof(sKindB));
		Crosshair(true, sKindB, g_aHammer.Get(blocked));
		if (other != 0)
			Hint(client, "hint_in_use", sKindB, g_aHammer.Get(blocked), other);
		else
			Hint(client, "hint_locked_short");
	}
	else if (best == -1)
		Hint(client, "hint_idle");
	if (best != -1)
	{
		if (best != g_iChosen[client])
			Aura(Movable(best), true, COLOR_WHITE);   // white is for objects to choose; the chosen one stays yellow
		char sKind[64];
		TypeName(best, client, sKind, sizeof(sKind));
		Hint(client, "hint_look", sKind, g_aHammer.Get(best));
		Crosshair(true, sKind, g_aHammer.Get(best));
	}
}

// Crosshair and box of the object looked at: in the centre a text crosshair that becomes [ + ] when
// looking at an object, and below it a box with type and number, which appears and disappears by
// itself. Slot 2 = MID_TOP, 3 = MID_BOT; flags 512 = centred, 64 = no background.
void Crosshair(bool objIndex, const char[] sKind = "", int id = 0, const char[] sFreeText = "")
{
	if (!g_bHud)
		return;
	if (EditorCount() > 1)
		objIndex = false;
	char sCode[512], sText[128], sEsc[192];
	if (objIndex)
	{
		if (sFreeText[0] != '\0')
			strcopy(sText, sizeof(sText), sFreeText);
		else
			FormatEx(sText, sizeof(sText), "%s #%d", sKind, id);
		ForScript(sText, sEsc, sizeof(sEsc));
		int lines = 1;
		for (int k = 0; sText[k] != '\0'; k++)
			if (sText[k] == '\n')
				lines++;
		FormatEx(sCode, sizeof(sCode), "::ZFHud.Fields.mir.dataval = \"[ + ]\"; ::ZFHud.Fields.lab.flags = 256; ::ZFHud.Fields.lab.dataval = \"%s\"; HUDPlace(2, 0.4007, 0.4803, 0.20, 0.04); HUDPlace(3, 0.54, 0.485, 0.30, %.3f);", sEsc, 0.026 * lines + 0.016);
	}
	else
		strcopy(sCode, sizeof(sCode), "::ZFHud.Fields.mir.dataval = \"+\"; ::ZFHud.Fields.lab.dataval = \"\"; ::ZFHud.Fields.lab.flags = 16640; HUDPlace(2, 0.4007, 0.4803, 0.20, 0.04); HUDPlace(3, 0.54, 0.485, 0.26, 0.04);");
	Script(sCode);
}

void UnlightLooked(int client)
{
	Crosshair(false);
	if (g_iLooked[client] == -1 || g_iLooked[client] >= g_aHammer.Length)
	{
		g_iLooked[client] = -1;
		return;
	}
	if (g_iLooked[client] == g_iChosen[client])
		SetOutline(g_iChosen[client], true);       // the selected one turns yellow again, not off
	else
		Aura(Movable(g_iLooked[client]), false, 0);
	g_iLooked[client] = -1;
}

// On release the object goes down to the first solid surface below it
void RestOnFloor(float v[3])
{
	Handle tr = TR_TraceRayFilterEx(v, view_as<float>({90.0, 0.0, 0.0}), MASK_SOLID, RayType_Infinite, Filter_NoPlayersNorCopies);
	if (TR_DidHit(tr))
	{
		float fine[3];
		TR_GetEndPosition(fine, tr);
		v[2] = fine[2];
	}
	delete tr;
}

public bool Filter_NoPlayersNorCopies(int e, int mask)
{
	if (e >= 1 && e <= MaxClients)
		return false;
	for (int i = 0; i < g_aCopy.Length; i++)
		if (CopyOf(i) == e)
			return false;
	for (int c = 1; c <= MaxClients; c++)
	{
		if (!g_bInEditor[c])
			continue;
		if (g_iChosen[c] != -1 && e == Movable(g_iChosen[c]))
			return false;
		if (e == EntRefToEntIndex(g_iPreview[c]))
			return false;
	}
	return true;
}

void RestoreOriginal(int client)
{
	ReleaseObject(client);
	float v[3], an[3], pv[3], pa[3];
	g_aPos.GetArray(g_iChosen[client], pv);
	g_aAng.GetArray(g_iChosen[client], pa);
	g_aReal.GetArray(g_iChosen[client], v);
	g_aAngReal.GetArray(g_iChosen[client], an);
	g_aPos.SetArray(g_iChosen[client], v);
	g_aAng.SetArray(g_iChosen[client], an);
	CreateCopy(g_iChosen[client]);
	UpdateCopy(g_iChosen[client]);
	GreyOriginal(g_iChosen[client], IsMoved(g_iChosen[client]));
	ReturnPoint(client, g_iChosen[client], pv, pa);
	LogEditor(client, "restore to the original #%d", g_aHammer.Get(g_iChosen[client]));
}

public Action Cmd_Grab(int client, int args)
{
	if (InEditor(client))
	{
		Grab(client);
		if (g_bGrabbed[client]) MenuObject(client);
	}
	return Plugin_Handled;
}

public Action Cmd_Drop(int client, int args)
{
	if (InEditor(client) && g_bGrabbed[client])
	{
		ReleaseObject(client);
		MenuObject(client);
	}
	return Plugin_Handled;
}

// In the editor left and right click belong to the editor: no firing, no shove. Fixed keys (WASD,
// left and right click), modes chosen from the menu.
//  - move: the object rests on the surface looked at; left click brings it closer, right click
//    farther; the player moves;
//  - fine move: WASD moves the object on fixed axes (the world axes nearest to where the player
//    looked at the start), the player stays still.
#define DIST_SPEED 160.0          // units per second with a click held
#define FINE_SPEED 24.0           // units per second in fine move (medium speed)

// Map buttons and doors are blocked while the director is off: the radio or a door would start
// Survival with the tank waves, which the stopped director does not stop. It applies to every
// player, from entering the editor until the next map load.
float g_fBlockedWarning[MAXPLAYERS + 1];

bool UseBlocked(int client)
{
	int e = GetClientAimTarget(client, false);
	if (e <= MaxClients || !IsValidEntity(e))
		return false;
	char c[40];
	GetEntityClassname(e, c, sizeof(c));
	return StrContains(c, "func_button") == 0 || StrEqual(c, "func_rot_button") || StrEqual(c, "trigger_finale")
		|| StrEqual(c, "point_prop_use_target") || StrContains(c, "prop_door") == 0 || StrContains(c, "func_door") == 0;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3],
	int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	g_iRawButtons[client] = buttons;   // before the editor strips any: the 9 of the menus reads Walk here
	if (g_bDirectorStopped && (buttons & IN_USE) && !IsFakeClient(client) && UseBlocked(client))
	{
		buttons &= ~IN_USE;
		if (GetGameTime() > g_fBlockedWarning[client])
		{
			g_fBlockedWarning[client] = GetGameTime() + 2.0;
			PrintHintText(client, "%T", "hint_map_locked", client);
		}
	}
	if (!InEditor(client))
		return Plugin_Continue;

	// The weapon in hand cannot fire or shove: it blocks the client's prediction too
	int wpn = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (wpn > MaxClients && IsValidEntity(wpn))
	{
		float after = GetGameTime() + 0.5;
		SetEntPropFloat(wpn, Prop_Send, "m_flNextPrimaryAttack", after);
		SetEntPropFloat(wpn, Prop_Send, "m_flNextSecondaryAttack", after);
	}

	// Use: the press edge is computed here for every mode
	bool useKey = (buttons & IN_USE) != 0;
	bool usePressed = useKey && !g_bUseBefore[client];
	g_bUseBefore[client] = useKey;

	// Choosing the wall: the view is free, use or left click confirm
	if (g_bWallChoice[client])
		return WallChoice(client, buttons, vel, weapon, usePressed);

	// Undo and redo are in the menus (9 and 8), not on keys: in the editor R does nothing and does not
	// reload the weapon.
	bool reload = (buttons & IN_RELOAD) != 0;
	if (reload)
		buttons &= ~IN_RELOAD;

	// Use in a mode = confirm: the object stays there (released) and stays selected; another use picks
	// it up again
	if (usePressed && g_iChosen[client] != -1 && (g_bGrabbed[client] || g_bFineMove[client] || g_bRotate[client]))
	{
		// One behaviour in both modes: use puts the object down (on the floor, never floating); falling with
		// physics is item 3 of the menu.
		ReleaseObject(client);
		LogEditor(client, "confirmed with use #%d", g_aHammer.Get(g_iChosen[client]));
		Hint(client, "hint_placed");
		MenuObject(client);
		buttons &= ~IN_USE;
		return Plugin_Changed;
	}

	if (g_iChosen[client] != -1 && g_bGrabbed[client])
		return Coarse(client, buttons, weapon);
	// Jump: pause of fine move or rotation (walk around and resume)
	if (g_iChosen[client] != -1 && (g_bFineMove[client] || g_bRotate[client]))
	{
		bool jump = (buttons & IN_JUMP) != 0;
		if (jump && !g_bJumpBefore[client])
			PauseMode(client, !g_bPaused[client]);
		g_bJumpBefore[client] = jump;
		if (g_bPaused[client])
		{
			buttons &= ~(IN_JUMP | IN_ATTACK | IN_ATTACK2 | IN_USE);
			if (g_bFineMove[client])
				WasdCross(client, false);
			return Plugin_Changed;
		}
	}
	if (g_iChosen[client] != -1 && g_bCombo[client])
		return Combined(client, buttons, vel, weapon, mouse);
	if (g_iChosen[client] != -1 && g_bFineMove[client])
		return FineMove(client, buttons, vel, weapon);
	if (g_iChosen[client] != -1 && g_bRotate[client])
		return RotationMode(client, buttons, vel, weapon, mouse);

	Look(client);
	// Use grabs the object looked at (and uses nothing in the game)
	if (usePressed)
	{
		LogMessage("[editor] %N: use pressed, looked at %d (hammer %d)", client, g_iLooked[client],
			g_iLooked[client] != -1 ? g_aHammer.Get(g_iLooked[client]) : 0);
		if (g_iLooked[client] == -1)
			LogNearest(client);
	}
	if (usePressed && g_iLooked[client] == -1 && g_iBlocked[client] != -1 && !Holder(g_iBlocked[client], client))
	{
		char sKindB[64];
		TypeName(g_iBlocked[client], client, sKindB, sizeof(sKindB));
		Hint(client, "hint_locked", sKindB);
	}
	if (usePressed && g_iLooked[client] == -1 && g_iBlocked[client] != -1 && Holder(g_iBlocked[client], client))
		HeldByOthers(client, g_iBlocked[client]);
	if (usePressed && g_iLooked[client] != -1 && HeldByOthers(client, g_iLooked[client]))
		usePressed = false;
	if (usePressed && g_iLooked[client] != -1)
	{
		int i = g_iLooked[client];
		UnlightLooked(client);
		SelectObject(client, i);
		g_bFromList[client] = false;
		Grab(client);
		MenuObject(client);
	}
	if (buttons & (IN_ATTACK | IN_ATTACK2 | IN_USE))
	{
		buttons &= ~(IN_ATTACK | IN_ATTACK2 | IN_USE);
		return Plugin_Changed;
	}
	return Plugin_Continue;
}

// Jump while moving: switches noclip on or off, at medium speed, to carry the object far. It is not
// switched off inside a wall.
void JumpFly(int client)
{
	if (g_bNoclip[client])
	{
		float o[3], mn[3], mx[3];
		GetClientAbsOrigin(client, o);
		GetClientMins(client, mn);
		GetClientMaxs(client, mx);
		Handle tr = TR_TraceHullFilterEx(o, o, mn, mx, MASK_PLAYERSOLID, Filter_NoPlayersNorCopies);
		bool stuck = TR_DidHit(tr);
		delete tr;
		if (stuck)
		{
			Hint(client, "hint_stuck");
			return;
		}
	}
	SetNoclip(client, !g_bNoclip[client]);
}

// Put down or cancelled: noclip goes back to how it was before grabbing
void RestoreNoclip(int client)
{
	if (IsClientInGame(client) && g_bNoclip[client] != g_bNoclipAtGrab[client])
		SetNoclip(client, g_bNoclipAtGrab[client]);
}

Action Coarse(int client, int &buttons, int &weapon)
{
	bool jump = (buttons & IN_JUMP) != 0;
	if (jump && !g_bJumpBefore[client])
		JumpFly(client);
	g_bJumpBefore[client] = jump;
	buttons &= ~IN_JUMP;
	float dt = GetTickInterval();
	if (buttons & IN_ATTACK)  g_fDistance[client] -= DIST_SPEED * dt;
	if (buttons & IN_ATTACK2) g_fDistance[client] += DIST_SPEED * dt;
	if (g_fDistance[client] < DIST_MIN) g_fDistance[client] = DIST_MIN;
	if (g_fDistance[client] > DIST_MAX) g_fDistance[client] = DIST_MAX;

	// The point looked at, at the chosen distance (or the wall, if nearer)...
	float eyes[3], view[3], fwd[3], v[3];
	GetClientEyePosition(client, eyes);
	GetClientEyeAngles(client, view);
	GetAngleVectors(view, fwd, NULL_VECTOR, NULL_VECTOR);
	v = fwd;
	ScaleVector(v, g_fDistance[client]);
	AddVectors(eyes, v, v);
	Handle tr = TR_TraceRayFilterEx(eyes, v, MASK_SOLID, RayType_EndPoint, Filter_NoPlayersNorCopies);
	if (TR_DidHit(tr))
	{
		TR_GetEndPosition(v, tr);
		ScaleVector(fwd, 8.0);
		SubtractVectors(v, fwd, v);      // one step back from the wall
	}
	delete tr;
	// The object stays on the crosshair; on the floor its projection, where it will land on release
	float floor[3];
	floor = v;
	RestAt(g_iChosen[client], floor);
	Preview(client, g_iChosen[client], floor);
	UpdateBeam(client, v, floor);
	g_aPos.SetArray(g_iChosen[client], v);
	UpdateCopy(g_iChosen[client]);
	if (CopyOf(g_iChosen[client]) <= MaxClients)
		GreyOriginal(g_iChosen[client], IsMoved(g_iChosen[client]));
	InfoMove(client);

	weapon = 0;                 // with the object in hand the weapon does not change
	buttons &= ~(IN_ATTACK | IN_ATTACK2 | IN_USE);
	return Plugin_Changed;
}

void FineStart(int client)
{
	if (g_iChosen[client] == -1)
		return;
	ReleaseObject(client);
	float view[3];
	GetClientEyeAngles(client, view);
	// Fixed axes: the world axes nearest to where the player looks now
	g_fFineYaw[client] = float(RoundToNearest(view[1] / 90.0)) * 90.0;
	g_bWallAligned[client] = false;
	g_bFineMove[client] = true;
	g_bFineMoved[client] = false;
	g_bPaused[client] = false;
	g_bJumpBefore[client] = true;
	// Character still for the client's prediction too: no jerking back and forth. The view stays free
	// and the keys still reach the plugin.
	SetEntityMoveType(client, MOVETYPE_NONE);
	TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
	LogEditor(client, "fine move #%d (axes at %.0f degrees)", g_aHammer.Get(g_iChosen[client]), g_fFineYaw[client]);
	Hint(client, "hint_fine");
}

void FineStopMode(int client)
{
	g_bCombo[client] = false;
	g_bWallChoice[client] = false;
	if (!g_bFineMove[client])
		return;
	if (g_bFineMoved[client])
		FineRecord(client);
	g_bFineMove[client] = false;
	g_bPaused[client] = false;
	if (IsClientInGame(client))
		SetEntityMoveType(client, g_bNoclip[client] ? MOVETYPE_NOCLIP : MOVETYPE_WALK);
	LogEditor(client, "end of fine move");
}

// One fine move = from the press until the keys are released
void FineRecord(int client)
{
	g_bFineMoved[client] = false;
	float v[3], an[3];
	g_aPos.GetArray(g_iChosen[client], v);
	g_aAng.GetArray(g_iChosen[client], an);
	if (GetVectorDistance(v, g_fBeforePos[client]) > 0.01 || GetVectorDistance(an, g_fBeforeAng[client]) > 0.01)
		ReturnPoint(client, g_iChosen[client], g_fBeforePos[client], g_fBeforeAng[client]);
}

Action FineMove(int client, int &buttons, float vel[3], int &weapon)
{
	float f = 0.0, r = 0.0;
	if (buttons & IN_FORWARD)   f += 1.0;
	if (buttons & IN_BACK)      f -= 1.0;
	if (buttons & IN_MOVERIGHT) r += 1.0;
	if (buttons & IN_MOVELEFT)  r -= 1.0;

	if (f != 0.0 || r != 0.0)
	{
		float v[3];
		g_aPos.GetArray(g_iChosen[client], v);
		if (!g_bFineMoved[client])
		{
			g_fBeforePos[client] = v;
			g_aAng.GetArray(g_iChosen[client], g_fBeforeAng[client]);
			g_bFineMoved[client] = true;
		}
		float step = FINE_SPEED * SPEEDS[g_iSpeed[client]] * 2.0 * GetTickInterval();
		float c = Cosine(DegToRad(g_fFineYaw[client])), sn = Sine(DegToRad(g_fFineYaw[client]));
		v[0] += (c * f + sn * r) * step;
		v[1] += (sn * f - c * r) * step;
		// rests on its lowest point, as in rotation
		RestAt(g_iChosen[client], v);
		g_aPos.SetArray(g_iChosen[client], v);
		UpdateCopy(g_iChosen[client]);
		if (CopyOf(g_iChosen[client]) <= MaxClients)
			GreyOriginal(g_iChosen[client], IsMoved(g_iChosen[client]));
	}
	else if (g_bFineMoved[client])
		FineRecord(client);
	WasdCross(client, f != 0.0 || r != 0.0);
	if (!g_bCombo[client])
		InfoFineMove(client);

	// The character stays still: the movement keys are removed (the view stays free)
	buttons &= ~(IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT | IN_JUMP | IN_DUCK
		| IN_ATTACK | IN_ATTACK2 | IN_USE);
	vel[0] = vel[1] = vel[2] = 0.0;
	weapon = 0;
	return Plugin_Changed;
}

// ---------------------------------------------------------------- steps

public Action Cmd_Step(int client, int args)
{
	if (!InEditor(client))
		return Plugin_Handled;
	g_iStep[client] = (g_iStep[client] + 1) % sizeof(STEPS);
	LogEditor(client, "step %.0f", STEPS[g_iStep[client]]);
	{ char sP[16]; FormatEx(sP, sizeof(sP), "%.0f", STEPS[g_iStep[client]]); Hint(client, "hint_step", sP); }
	if (g_iChosen[client] != -1)
		MenuObject(client);
	return Plugin_Handled;
}

public Action Cmd_Nudge(int client, int args)
{
	if (!InEditor(client))
		return Plugin_Handled;
	if (g_iChosen[client] == -1)
	{
		Chat(client, "select_first");
		return Plugin_Handled;
	}
	ReleaseObject(client);      // the steps work on the still object

	char sCmd[48];
	GetCmdArg(0, sCmd, sizeof(sCmd));
	// sm_zf_sme_<axis>_<up|down>: the axis starts after the 10 characters of "sm_zf_sme_"
	char sRest[32];
	strcopy(sRest, sizeof(sRest), sCmd[10]);
	float sign = StrContains(sRest, "_up") != -1 ? 1.0 : -1.0;
	float p = STEPS[g_iStep[client]] * sign;

	float v[3], an[3], pv[3], pa[3];
	g_aPos.GetArray(g_iChosen[client], v);
	g_aAng.GetArray(g_iChosen[client], an);
	pv = v;
	pa = an;
	if      (StrContains(sRest, "x_") == 0)     v[0] += p;
	else if (StrContains(sRest, "y_") == 0)     v[1] += p;
	else if (StrContains(sRest, "z_") == 0)     v[2] += p;
	else if (StrContains(sRest, "pitch_") == 0) an[0] = NormalizeAngle(an[0] + p);
	else if (StrContains(sRest, "yaw_") == 0)   an[1] = NormalizeAngle(an[1] + p);
	else if (StrContains(sRest, "roll_") == 0)  an[2] = NormalizeAngle(an[2] + p);
	g_aPos.SetArray(g_iChosen[client], v);
	g_aAng.SetArray(g_iChosen[client], an);
	CreateCopy(g_iChosen[client]);
	UpdateCopy(g_iChosen[client]);
	GreyOriginal(g_iChosen[client], IsMoved(g_iChosen[client]));
	LogEditor(client, "%s #%d", sRest, g_aHammer.Get(g_iChosen[client]));
	ReturnPoint(client, g_iChosen[client], pv, pa);
	return Plugin_Handled;
}

float NormalizeAngle(float a)
{
	while (a >= 360.0) a -= 360.0;
	while (a < 0.0)    a += 360.0;
	return a;
}

// ---------------------------------------------------------------- return points and undo

// Different from the real original position: it is what ends up in the Stripper file
bool MovedFromReal(int i)
{
	float a[3], b[3], ra[3], rb[3];
	g_aReal.GetArray(i, a);
	g_aPos.GetArray(i, b);
	g_aAngReal.GetArray(i, ra);
	g_aAng.GetArray(i, rb);
	return GetVectorDistance(a, b) > 0.01 || GetVectorDistance(ra, rb) > 0.01;
}

int ToSave()
{
	int n = 0;
	for (int i = 0; i < g_aHammer.Length; i++)
		if (g_aHammer.Get(i) > 0 && MovedFromReal(i))
			n++;
	return n;
}

// Undo and redo per author: everyone undoes and redoes only their own moves. The author is the
// Steam account, so it still holds after a reconnection; 0 = lines of older files.
int AuthorOf(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return 0;
	return GetSteamAccountID(client);
}

bool ByAuthor(ArrayList a, int r, int author)
{
	int who = a.Get(r, 7);
	return author == 0 || who == 0 || who == author;
}

int CountMoves(ArrayList a, int client)
{
	int author = AuthorOf(client), n = 0;
	for (int r = 0; r < a.Length; r++)
		if (ByAuthor(a, r, author))
			n++;
	return n;
}

// Records the state before a move and updates the return points file
void ReturnPoint(int client, int i, const float fromPos2[3], const float fromAng[3])
{
	int author = AuthorOf(client);
	for (int k = g_aRedo.Length - 1; k >= 0; k--)       // new move: nothing left to redo, for whoever made it
		if (ByAuthor(g_aRedo, k, author))
			g_aRedo.Erase(k);
	any r[8];
	r[7] = author;
	r[0] = g_aHammer.Get(i);
	for (int k = 0; k < 3; k++)
	{
		r[1 + k] = fromPos2[k];
		r[4 + k] = fromAng[k];
	}
	g_aHistory.PushArray(r);
	WriteState();
}

// Last history line of that author (of one object, or of all with hammer 0)
int LastMove(int hammer, int author)
{
	for (int r = g_aHistory.Length - 1; r >= 0; r--)
		if ((hammer == 0 || g_aHistory.Get(r, 0) == hammer) && ByAuthor(g_aHistory, r, author))
			return r;
	return -1;
}

// After an undo or a redo the object lights up for three seconds, even through walls, and the
// message says how far it is and in which direction from where the player looks: so what happened
// shows even when looking elsewhere.
#define COLOR_SIGNAL (40 + (255 << 8) + (120 << 16))
int g_iSignal;                      // running number of the signals

void Signal(int client, int i, const char[] verb, const char[] sKind)
{
	float eyes[3], view[3], v[3], d[3];
	GetClientEyePosition(client, eyes);
	GetClientEyeAngles(client, view);
	g_aPos.GetArray(i, v);
	SubtractVectors(v, eyes, d);
	float metres = GetVectorLength(d) * UNITS_TO_METRES;
	float diff = RadToDeg(ArcTangent2(d[1], d[0])) - view[1];
	diff = NormalizeAngle(diff);
	char sWhere[48], sAlt[24], sVerb[32], sMetres[16];
	if (metres < 1.0)
		Tr(sWhere, sizeof(sWhere), client, "dir_near");
	else if (FloatAbs(diff) < 30.0)
		Tr(sWhere, sizeof(sWhere), client, "dir_front");
	else if (FloatAbs(diff) > 150.0)
		Tr(sWhere, sizeof(sWhere), client, "dir_behind");
	else
		Tr(sWhere, sizeof(sWhere), client, diff > 0.0 ? "dir_left" : "dir_right");
	sAlt[0] = '\0';
	if (d[2] > 60.0)
		Tr(sAlt, sizeof(sAlt), client, "alt_up");
	else if (d[2] < -60.0)
		Tr(sAlt, sizeof(sAlt), client, "alt_down");
	Tr(sVerb, sizeof(sVerb), client, verb);
	FormatEx(sMetres, sizeof(sMetres), "%.0f", metres);
	Hint(client, "hint_signal", sVerb, sKind, g_aHammer.Get(i), sMetres, sWhere, sAlt);
	Aura(Movable(i), true, COLOR_SIGNAL);
	g_iSignal++;
	{ char sK[12]; IntToString(g_aHammer.Get(i), sK, sizeof(sK)); g_smSignal.SetValue(sK, g_iSignal); }
	DataPack dp;
	CreateDataTimer(3.0, Timer_SignalOff, dp);
	dp.WriteCell(g_iSignal);
	dp.WriteCell(g_aHammer.Get(i));
}

public Action Timer_SignalOff(Handle t, DataPack dp)
{
	dp.Reset();
	int gen = dp.ReadCell();
	int hammer = dp.ReadCell();
	int last;
	{ char sK[12]; IntToString(hammer, sK, sizeof(sK)); if (!g_smSignal.GetValue(sK, last) || last != gen) return Plugin_Stop; }
	int i = g_aHammer.FindValue(hammer);
	if (i == -1)
		return Plugin_Stop;
	if (InUseBy(i) != 0)
		SetOutline(i, true);               // the selected one turns yellow again
	else if (LookedAtBy(i) != 0)
		Aura(Movable(i), true, COLOR_WHITE);
	else
		Aura(Movable(i), false, 0);
	return Plugin_Stop;
}

// hammer 0: undoes the last move of all; otherwise the last one of that object
void Undo(int client, int hammer)
{
	// The editor stays in its current mode: only the move in progress is closed, so it can be undone
	if (g_bFineMoved[client])
		FineRecord(client);
	if (g_bRotateMoved[client])
		RotateRecord(client);
	int r = LastMove(hammer, AuthorOf(client));
	if (r == -1)
	{
		Chat(client, "nothing_to_undo");
		return;
	}
	any line[8];
	g_aHistory.GetArray(r, line);
	if (HeldByOthers(client, g_aHammer.FindValue(line[0])))
		return;
	g_aHistory.Erase(r);

	int i = g_aHammer.FindValue(line[0]);
	if (i == -1)
	{
		WriteState();
		return;
	}
	if (g_bGrabbed[client] && i == g_iChosen[client])
	{
		g_bGrabbed[client] = false;          // undo wins over the move in progress
		RemovePreview(client);
		GrabSpeed(client, false);
		RestoreNoclip(client);
	}
	float v[3], an[3];
	for (int k = 0; k < 3; k++)
	{
		v[k] = line[1 + k];
		an[k] = line[4 + k];
	}
	g_aPos.GetArray(i, g_fRedoPos);
	g_aAng.GetArray(i, g_fRedoAng);
	g_aPos.SetArray(i, v);
	g_aAng.SetArray(i, an);
	UpdateCopy(i);
	GreyOriginal(i, IsMoved(i));
	if (g_bRotate[client] && i == g_iChosen[client])
		FixAxis(client);                    // circle and degrees restart from the restored pose
	{
		// for redo: how it was before undoing
		any redoIt[8];
		redoIt[0] = line[0];
		redoIt[7] = AuthorOf(client);
		for (int k = 0; k < 3; k++)
		{
			redoIt[1 + k] = g_fRedoPos[k];
			redoIt[4 + k] = g_fRedoAng[k];
		}
		g_aRedo.PushArray(redoIt);
	}
	char sKind[64];
	TypeName(i, client, sKind, sizeof(sKind));
	LogEditor(client, "undo #%d (%d moves left)", line[0], g_aHistory.Length);
	Signal(client, i, "verb_undone", sKind);
	WriteState();
}

// ---------------------------------------------------------------- return points file
// <map>/work.txt, KeyValues:
//   originals { "<hammerid>" { origin angles } }  real position, never deleted
//   current   { "<hammerid>" { origin angles } }  where it is now in the editor
//   history   { "1" { hammer origin angles } ... }  state before each move

// The folders of a map: addons/zombiefoundry/stripper-map-editor/<map>/ with work.txt (the running
// state), saves/, autosave/ and published/. Every file has in its header who made it (name and
// SteamID), so it can be filtered by author.
void CreateFolders(const char[] path)
{
	char sPartial[PLATFORM_MAX_PATH];
	for (int i = 0; path[i] != '\0'; i++)
	{
		if (path[i] == '/' && i > 0)
		{
			strcopy(sPartial, i + 1, path);
			if (!DirExists(sPartial))
				CreateDirectory(sPartial, 511);
		}
	}
	if (!DirExists(path))
		CreateDirectory(path, 511);
}

void MapFolder(char[] out, int len, const char[] below = "")
{
	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));
	if (below[0] != '\0')
		BuildPath(Path_SM, out, len, "%s/%s/%s", DATA_FOLDER, sMap, below);
	else
		BuildPath(Path_SM, out, len, "%s/%s", DATA_FOLDER, sMap);
}

void StatePath(char[] out, int len)
{
	char sFolder[PLATFORM_MAX_PATH];
	MapFolder(sFolder, sizeof(sFolder));
	CreateFolders(sFolder);
	Format(out, len, "%s/work.txt", sFolder);
}

// Name fit for a file: letters and digits only
void CleanName(const char[] name, char[] out, int len)
{
	int q = 0;
	for (int k = 0; name[k] != '\0' && q < len - 1; k++)
		if (IsCharAlpha(name[k]) || IsCharNumeric(name[k]))
			out[q++] = name[k];
	out[q] = '\0';
	if (q == 0)
		strcopy(out, len, "x");
}

bool CopyFileTo(const char[] fromPos, const char[] a)
{
	File f = OpenFile(fromPos, "r");
	if (f == null)
		return false;
	File g = OpenFile(a, "w");
	if (g == null)
	{
		delete f;
		return false;
	}
	char sLine[2048];
	while (f.ReadLine(sLine, sizeof(sLine)))
		g.WriteString(sLine, false);
	delete f;
	delete g;
	return true;
}

// Keeps only the last "most" files of a folder (the names are date and time: the oldest come
// first)
void PruneVersions(const char[] folder, int most)
{
	DirectoryListing d = OpenDirectory(folder);
	if (d == null)
		return;
	ArrayList names = new ArrayList(PLATFORM_MAX_PATH / 4);
	char sName[PLATFORM_MAX_PATH];
	FileType kind;
	while (d.GetNext(sName, sizeof(sName), kind))
		if (kind == FileType_File)
			names.PushString(sName);
	delete d;
	names.Sort(Sort_Ascending, Sort_String);
	while (names.Length > most)
	{
		char sFull[PLATFORM_MAX_PATH];
		names.GetString(0, sName, sizeof(sName));
		Format(sFull, sizeof(sFull), "%s/%s", folder, sName);
		DeleteFile(sFull);
		names.Erase(0);
	}
	delete names;
}

// "Unsaved" = moves after the last personal save or autosave ("unpublished" is NonSalvate(),
// against the server's file)
void LogState(int client, const char[] when)
{
	int sp = 0, np = 0;
	for (int i = 0; i < g_aHammer.Length; i++)
	{
		if (g_aHammer.Get(i) <= 0)
			continue;
		if (MovedFromReal(i))
			sp++;
		if (DifferentFromMap(i))
		{
			np++;
			float a[3], b[3], ra[3], rb[3];
			g_aOrigin.GetArray(i, a);  g_aPos.GetArray(i, b);
			g_aAngLoaded.GetArray(i, ra); g_aAng.GetArray(i, rb);
			LogMessage("[editor] [state] different from the server file #%d: server %.3f %.3f %.3f / %.3f %.3f %.3f, now %.3f %.3f %.3f / %.3f %.3f %.3f",
				g_aHammer.Get(i), a[0], a[1], a[2], ra[0], ra[1], ra[2], b[0], b[1], b[2], rb[0], rb[1], rb[2]);
		}
	}
	LogEditor(client, "[state] %s: moved from real=%d, unpublished=%d", when, sp, np);
}

void FixSnapshot()
{
	g_aSnapPos.Clear();
	g_aSnapAng.Clear();
	float v[3];
	for (int i = 0; i < g_aHammer.Length; i++)
	{
		g_aPos.GetArray(i, v);
		g_aSnapPos.PushArray(v);
		g_aAng.GetArray(i, v);
		g_aSnapAng.PushArray(v);
	}
}

int Unsaved()
{
	if (g_aSnapPos.Length != g_aHammer.Length)
		return 0;
	int n = 0;
	float a[3], b[3], ra[3], rb[3];
	for (int i = 0; i < g_aHammer.Length; i++)
	{
		if (g_aHammer.Get(i) <= 0)
			continue;
		g_aSnapPos.GetArray(i, a);  g_aPos.GetArray(i, b);
		g_aSnapAng.GetArray(i, ra); g_aAng.GetArray(i, rb);
		if (GetVectorDistance(a, b) > 0.05 || GetVectorDistance(ra, rb) > 0.05)
			n++;
	}
	return n;
}

#define MAX_VERSIONS 100

// Name fit for a file, from any text: letters, digits and accented letters; spaces become "_";
// 24 characters at most
void FileName(const char[] name, char[] out, int len)
{
	int q = 0;
	bool lastSpace = true;
	for (int k = 0; name[k] != '\0' && q < len - 1 && q < 24; k++)
	{
		int c = name[k];
		if (c < 0)
			c += 256;
		if (IsCharAlpha(name[k]) || IsCharNumeric(name[k]) || c >= 128)
		{
			out[q++] = name[k];
			lastSpace = false;
		}
		else if ((name[k] == ' ' || name[k] == '_' || name[k] == '-') && !lastSpace)
		{
			out[q++] = '_';
			lastSpace = true;
		}
	}
	while (q > 0 && out[q - 1] == '_')
		q--;
	out[q] = '\0';
}

void SaveMyWork(int client, bool automatic, const char[] saveName = "")
{
	if (g_aHammer.Length == 0)
		return;
	g_iMovesSnapshot = g_aHistory.Length;
	FixSnapshot();
	WriteState();
	char sWork[PLATFORM_MAX_PATH], sFolder[PLATFORM_MAX_PATH], sCopy[PLATFORM_MAX_PATH], sNow[32], sAuthor[64];
	StatePath(sWork, sizeof(sWork));
	MapFolder(sFolder, sizeof(sFolder), automatic ? "autosave" : "saves");
	CreateFolders(sFolder);
	FormatTime(sNow, sizeof(sNow), "%Y%m%d-%H%M%S", GetTime());
	CleanName(g_sEditorName[client], sAuthor, sizeof(sAuthor));
	if (saveName[0] != '\0')
		Format(sCopy, sizeof(sCopy), "%s/%s_%s_%d_%s.txt", sFolder, sNow, sAuthor, ToSave(), saveName);
	else
		Format(sCopy, sizeof(sCopy), "%s/%s_%s_%d.txt", sFolder, sNow, sAuthor, ToSave());
	if (!CopyFileTo(sWork, sCopy))
	{
		LogError("[editor] cannot copy %s to %s", sWork, sCopy);
		return;
	}
	PruneVersions(sFolder, MAX_VERSIONS);
	g_iLastAutosave = GetTime();
	LogEditor(client, "%s: %s", automatic ? "autosave" : "personal save", sCopy);
	if (automatic)
		Chat(client, "autosaved");
	else
		Chat(client, "saved_mine", sCopy[FindCharInString(sCopy, '/', true) + 1]);   // the file name, as it is saved
}

public Action Timer_Autosave(Handle t)
{
	int author = LastActor();
	if (author == 0 || g_iAutosaveMin <= 0 || g_aHammer.Length == 0)
		return Plugin_Continue;
	if (GetTime() - g_iLastAutosave < g_iAutosaveMin * 60)
		return Plugin_Continue;
	if (Unsaved() == 0)
	{
		g_iLastAutosave = GetTime();
		return Plugin_Continue;
	}
	SaveMyWork(author, true);
	return Plugin_Continue;
}

// Autosave: off, 2, 5 or 10 minutes (server setting)
void CycleAutosave()
{
	g_iAutosaveMin = (g_iAutosaveMin == 0) ? 2 : (g_iAutosaveMin == 2) ? 5 : (g_iAutosaveMin == 5) ? 10 : 0;
	g_iLastAutosave = GetTime();
	SaveServerSettings();
}

void AutosaveName(int client, char[] out, int len)
{
	if (g_iAutosaveMin == 0)
		Tr(out, len, client, "autosave_off");
	else
		Tr(out, len, client, "autosave_every", g_iAutosaveMin);
}


bool InHistory(int hammer)
{
	for (int r = 0; r < g_aHistory.Length; r++)
		if (g_aHistory.Get(r, 0) == hammer)
			return true;
	return false;
}

void WriteState()
{
	if (g_aHammer.Length == 0)
		return;
	char sMap[64], sKey[16], sPath[PLATFORM_MAX_PATH];
	GetCurrentMap(sMap, sizeof(sMap));
	StatePath(sPath, sizeof(sPath));

	KeyValues kv = new KeyValues("zf_stripper_map_editor");
	kv.SetString("map", sMap);
	kv.SetNum("moves_saved", g_iMovesSaved);
	kv.SetNum("moves_snapshot", g_iMovesSnapshot);
	int author = LastActor();
	kv.SetString("author", g_sEditorName[author]);
	kv.SetString("steamid", g_sEditorId[author]);
	{
		char sDate[32];
		FormatTime(sDate, sizeof(sDate), "%Y-%m-%d %H:%M:%S", GetTime());
		kv.SetString("date", sDate);
	}
	kv.SetString("plugin", PLUGIN_VERSION);
	float v[3], an[3], o[3];
	for (int i = 0; i < g_aHammer.Length; i++)
	{
		int h = g_aHammer.Get(i);
		if (h <= 0)
			continue;
		g_aReal.GetArray(i, v);
		g_aOrigin.GetArray(i, o);
		bool touched = MovedFromReal(i) || IsMoved(i) || InHistory(h)
			|| GetVectorDistance(v, o) > 0.01;
		if (!touched)
			continue;
		IntToString(h, sKey, sizeof(sKey));
		g_aAngReal.GetArray(i, an);
		kv.JumpToKey("originals", true);
		kv.JumpToKey(sKey, true);
		kv.SetVector("origin", v);
		kv.SetVector("angles", an);
		kv.Rewind();
		g_aPos.GetArray(i, v);
		g_aAng.GetArray(i, an);
		kv.JumpToKey("current", true);
		kv.JumpToKey(sKey, true);
		kv.SetVector("origin", v);
		kv.SetVector("angles", an);
		kv.Rewind();
	}
	any line[8];
	for (int r = 0; r < g_aHistory.Length; r++)
	{
		g_aHistory.GetArray(r, line);
		for (int k = 0; k < 3; k++)
		{
			v[k] = line[1 + k];
			an[k] = line[4 + k];
		}
		IntToString(r + 1, sKey, sizeof(sKey));
		kv.JumpToKey("history", true);
		kv.JumpToKey(sKey, true);
		kv.SetNum("hammer", line[0]);
		kv.SetNum("author", line[7]);
		kv.SetVector("origin", v);
		kv.SetVector("angles", an);
		kv.Rewind();
	}
	if (!kv.ExportToFile(sPath))
		LogError("[editor] cannot write %s", sPath);
	delete kv;
}

// After the dump: takes back the real originals, the unsaved positions and the history
void LoadState(int client)
{
	LoadStateFromFile(client, "", false);
}

// empty percorsoDato = the usual work file; azzera = every object goes back to its original first
// (when loading a save from the menu)
bool LoadStateFromFile(int client, const char[] givenPath, bool reset)
{
	char sPath[PLATFORM_MAX_PATH];
	if (givenPath[0] != '\0')
		strcopy(sPath, sizeof(sPath), givenPath);
	else
		StatePath(sPath, sizeof(sPath));
	if (!FileExists(sPath))
	{
		FixSnapshot();
		return false;
	}
	KeyValues kv = new KeyValues("zf_stripper_map_editor");
	if (!kv.ImportFromFile(sPath))
	{
		delete kv;
		LogError("[editor] return points file unreadable: %s", sPath);
		return false;
	}
	if (reset)
	{
		float va[3], aa[3];
		for (int i = 0; i < g_aHammer.Length; i++)
		{
			g_aReal.GetArray(i, va);  g_aAngReal.GetArray(i, aa);
			g_aPos.SetArray(i, va);   g_aAng.SetArray(i, aa);
		}
		g_aRedo.Clear();
	}
	char sKey[16];
	float v[3], an[3];
	int nOrig = 0, nAtt = 0;
	g_iMovesSaved = kv.GetNum("moves_saved", -1);   // -1: file of an older version
	g_iMovesSnapshot = kv.GetNum("moves_snapshot", -1);
	if (kv.JumpToKey("originals") && kv.GotoFirstSubKey())
	{
		do
		{
			kv.GetSectionName(sKey, sizeof(sKey));
			int i = g_aHammer.FindValue(StringToInt(sKey));
			if (i == -1)
				continue;
			kv.GetVector("origin", v);
			kv.GetVector("angles", an);
			g_aReal.SetArray(i, v);
			g_aAngReal.SetArray(i, an);
			nOrig++;
		} while (kv.GotoNextKey());
	}
	kv.Rewind();
	if (kv.JumpToKey("current") && kv.GotoFirstSubKey())
	{
		do
		{
			kv.GetSectionName(sKey, sizeof(sKey));
			int i = g_aHammer.FindValue(StringToInt(sKey));
			if (i == -1)
				continue;
			kv.GetVector("origin", v);
			kv.GetVector("angles", an);
			g_aPos.SetArray(i, v);
			g_aAng.SetArray(i, an);
			nAtt++;
		} while (kv.GotoNextKey());
	}
	kv.Rewind();
	g_aHistory.Clear();
	if (kv.JumpToKey("history") && kv.GotoFirstSubKey())
	{
		any line[8];
		do
		{
			line[0] = kv.GetNum("hammer");
			line[7] = kv.GetNum("author", 0);
			kv.GetVector("origin", v);
			kv.GetVector("angles", an);
			for (int k = 0; k < 3; k++)
			{
				line[1 + k] = v[k];
				line[4 + k] = an[k];
			}
			g_aHistory.PushArray(line);
		} while (kv.GotoNextKey());
	}
	delete kv;

	if (g_iMovesSaved < 0)
		g_iMovesSaved = g_aHistory.Length;      // older version: everything counts as saved
	if (g_iMovesSnapshot < 0)
		g_iMovesSnapshot = g_aHistory.Length;
	// Objects with work not saved yet show again as they were left (those already saved and reloaded
	// are in place already: no ghost)
	for (int i = 0; i < g_aHammer.Length; i++)
	{
		if (reset)
		{
			UpdateCopy(i);
			GreyOriginal(i, MovedFromReal(i));
			continue;
		}
		if (!DifferentFromMap(i))
			continue;
		UpdateCopy(i);
		GreyOriginal(i, true);
	}
	LogEditor(client, "return points: %d originals, %d positions, %d moves", nOrig, nAtt, g_aHistory.Length);
	g_bExplosions = false;
	FixSnapshot();
	ProtectExplosives(true);
	if (Unpublished() > 0 && !reset)
		Chat(client, "unsaved_reminder", Unpublished());
	LogState(client, "after reading");
	if (!reset && InEditor(client) && g_iChosen[client] == -1 && g_fMainMenuTime[client] >= g_fLastChoice[client])
		MenuMain(client);        // updates the items that depend on the state just read
	return true;
}

// ---------------------------------------------------------------- saving to the Stripper file
// addons/stripper/maps/<map>.cfg: the zone between ZONA_INIZIO and ZONA_FINE belongs to the
// plugin and is rewritten on every save; the rest of the file is not touched. For every moved
// object: filter by hammerid, then add with the dump block and the new position.

bool SaveStripper(int client)
{
	ReleaseObject(client);
	if (g_aHammer.Length == 0)
	{
		Chat(client, "read_objects_first");
		return false;
	}
	char sMap[64], sPath[PLATFORM_MAX_PATH], sTemp[PLATFORM_MAX_PATH];
	GetCurrentMap(sMap, sizeof(sMap));
	if (!DirExists(MAPS_FOLDER))
		CreateDirectory(MAPS_FOLDER, 511);
	FormatEx(sPath, sizeof(sPath), "%s/%s.cfg", MAPS_FOLDER, sMap);
	FormatEx(sTemp, sizeof(sTemp), "%s/%s.cfg.zf_tmp", MAPS_FOLDER, sMap);

	File out = OpenFile(sTemp, "w");
	if (out == null)
	{
		LogEditor(client, "cannot write %s", sTemp);
		Chat(client, "cannot_write", MAPS_FOLDER);
		return false;
	}

	// 0. header: who, when, with what (comments: Stripper ignores them)
	{
		char sAuthor[64], sSteam[32], sDate[32];
		GetClientName(client, sAuthor, sizeof(sAuthor));
		if (!GetClientAuthId(client, AuthId_Steam2, sSteam, sizeof(sSteam)))
			strcopy(sSteam, sizeof(sSteam), "?");
		FormatTime(sDate, sizeof(sDate), "%Y-%m-%d %H:%M:%S", GetTime());
		char sWorkDir[PLATFORM_MAX_PATH];
		Format(sWorkDir, sizeof(sWorkDir), "addons/zombiefoundry/stripper-map-editor/%s", sMap);
		out.WriteLine(HEADER_BEGIN);
		char sLine1[160], sModeF[32];
		Tr(sLine1, sizeof(sLine1), client, "file_published_by", sAuthor, sSteam);
		out.WriteLine("// %s", sLine1);
		Tr(sLine1, sizeof(sLine1), client, "file_date", sDate);
		out.WriteLine("// %s", sLine1);
		Tr(sModeF, sizeof(sModeF), client, g_bFreeMode ? "map_mode_free" : "map_mode_faithful");
		Tr(sLine1, sizeof(sLine1), client, "file_map_info", sMap, PLUGIN_VERSION, sModeF, ToSave());
		out.WriteLine("// %s", sLine1);
		Tr(sLine1, sizeof(sLine1), client, "file_work", sWorkDir);
		out.WriteLine("// %s", sLine1);
		out.WriteLine(HEADER_END);
	}

	// 1. the lines written by hand stay as they were
	File old = OpenFile(sPath, "r");
	if (old != null)
	{
		char sLine[1024];
		bool zone = false, header = false;
		while (old.ReadLine(sLine, sizeof(sLine)))
		{
			if (StrContains(sLine, HEADER_BEGIN) == 0) { header = true;  continue; }
			if (header)
			{
				if (StrContains(sLine, HEADER_END) == 0)
					header = false;
				continue;
			}
			if (StrContains(sLine, ZONE_BEGIN) == 0) { zone = true;  continue; }
			if (StrContains(sLine, ZONE_END) == 0)     { zone = false; continue; }
			if (zone)
				continue;
			out.WriteString(sLine, false);
			int l = strlen(sLine);
			if (l > 0 && sLine[l - 1] != '\n')
				out.WriteString("\n", false);
		}
		delete old;
	}

	// 2. the plugin's zone
	out.WriteLine(ZONE_BEGIN);
	char sBlock[BLOCK_MAX];
	float v[3], an[3];
	int n = 0;
	for (int i = 0; i < g_aHammer.Length; i++)
	{
		int h = g_aHammer.Get(i);
		if (h <= 0 || !MovedFromReal(i))
			continue;
		g_aPos.GetArray(i, v);
		g_aAng.GetArray(i, an);
		g_aBlock.GetString(i, sBlock, sizeof(sBlock));
		out.WriteLine("filter:");          // Stripper removes with filter: ("delete:" does not exist)
		out.WriteLine("{");
		out.WriteLine("\"hammerid\" \"%d\"", h);
		out.WriteLine("}");
		out.WriteLine("add:");
		out.WriteLine("{");
		out.WriteString(sBlock, false);
		out.WriteLine("\"origin\" \"%.3f %.3f %.3f\"", v[0], v[1], v[2]);
		out.WriteLine("\"angles\" \"%.3f %.3f %.3f\"", an[0], an[1], an[2]);
		out.WriteLine("}");
		n++;
	}
	out.WriteLine(ZONE_END);
	delete out;

	if (FileExists(sPath))
		DeleteFile(sPath);
	if (!RenameFile(sPath, sTemp))
	{
		LogEditor(client, "cannot rename %s", sTemp);
		Chat(client, "save_failed", MAPS_FOLDER);
		return false;
	}
	g_iMovesSaved = g_aHistory.Length;
	for (int i = 0; i < g_aHammer.Length; i++)
	{
		float pp[3], pa[3];
		g_aPos.GetArray(i, pp);
		g_aAng.GetArray(i, pa);
		g_aOrigin.SetArray(i, pp);
		g_aAngLoaded.SetArray(i, pa);
	}
	WriteState();
	// archive: a copy of every published version, with date and author in the name
	{
		char sArchive[PLATFORM_MAX_PATH], sNowA[32], sName[64], sClean[64];
		MapFolder(sArchive, sizeof(sArchive), "published");
		CreateFolders(sArchive);
		FormatTime(sNowA, sizeof(sNowA), "%Y%m%d-%H%M%S", GetTime());
		GetClientName(client, sName, sizeof(sName));
		int q = 0;
		for (int k = 0; sName[k] != '\0' && q < sizeof(sClean) - 1; k++)
			if (IsCharAlpha(sName[k]) || IsCharNumeric(sName[k]))
				sClean[q++] = sName[k];
		sClean[q] = '\0';
		char sFile[PLATFORM_MAX_PATH];
		Format(sFile, sizeof(sFile), "%s/%s_%s.cfg", sArchive, sNowA, sClean);
		CopyFileTo(sPath, sFile);
	}
	LogEditor(client, "published %s: %d objects moved", sPath, n);
	Chat(client, "saved", n, sPath);
	for (int c = 1; c <= MaxClients; c++)           // whoever works together is told
		if (c != client && g_bInEditor[c])
			Chat(c, "coop_published", client, n);
	return true;
}

// Stripper applies the file only when the map loads
// ---------------------------------------------------------------- change of map (owner only)
// Settings, page 3: campaign, then chapter, then confirmation. Whoever is in the editor comes back
// by itself (SegnaRientro) and the work is already in the work file (ScriviStato on every move).
static const char CAMPAIGNS[][] = { "Dead Center", "Dark Carnival", "Swamp Fever", "Hard Rain", "The Parish", "The Passing",
	"The Sacrifice", "No Mercy", "Crash Course", "Death Toll", "Dead Air", "Blood Harvest", "Cold Stream", "The Last Stand" };
static const char CHAPTERS[][] = {
	"c1m1_hotel,c1m2_streets,c1m3_mall,c1m4_atrium",
	"c2m1_highway,c2m2_fairgrounds,c2m3_coaster,c2m4_barns,c2m5_concert",
	"c3m1_plankcountry,c3m2_swamp,c3m3_shantytown,c3m4_plantation",
	"c4m1_milltown_a,c4m2_sugarmill_a,c4m3_sugarmill_b,c4m4_milltown_b,c4m5_milltown_escape",
	"c5m1_waterfront,c5m2_park,c5m3_cemetery,c5m4_quarter,c5m5_bridge",
	"c6m1_riverbank,c6m2_bedlam,c6m3_port",
	"c7m1_docks,c7m2_barge,c7m3_port",
	"c8m1_apartment,c8m2_subway,c8m3_sewers,c8m4_interior,c8m5_rooftop",
	"c9m1_alleys,c9m2_lots",
	"c10m1_caves,c10m2_drainage,c10m3_ranchhouse,c10m4_mainstreet,c10m5_houseboat",
	"c11m1_greenhouse,c11m2_offices,c11m3_garage,c11m4_terminal,c11m5_runway",
	"c12m1_hilltop,c12m2_traintunnel,c12m3_bridge,c12m4_barn,c12m5_cornfield",
	"c13m1_alpinecreek,c13m2_southpinestream,c13m3_memorialbridge,c13m4_cutthroatcreek",
	"c14m1_junkyard,c14m2_lighthouse" };
int  g_iChosenCampaign[MAXPLAYERS + 1];
char g_sChosenMap[MAXPLAYERS + 1][64];

void MenuCampaigns(int client)
{
	Menu m = new Menu(Menu_Campaigns);
	{ char sT[96]; Tr(sT, sizeof(sT), client, "map_pick_campaign"); m.SetTitle("%s", sT); }
	char sK[8];
	for (int i = 0; i < sizeof(CAMPAIGNS); i++)
	{
		IntToString(i, sK, sizeof(sK));
		m.AddItem(sK, CAMPAIGNS[i]);
	}
	m.ExitBackButton = true;
	m.Display(client, MENU_TIME_FOREVER);
}

public int Menu_Campaigns(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
	{
		char s[24];
		m.GetItem(item, s, sizeof(s));
		g_iChosenCampaign[client] = StringToInt(s);
		MenuChapters(client);
	}
	else if (a == MenuAction_Cancel && item == MenuCancel_ExitBack)
		MenuSettings(client);
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

void MenuChapters(int client)
{
	int c = g_iChosenCampaign[client];
	Menu m = new Menu(Menu_Chapters);
	{ char sT[128]; Tr(sT, sizeof(sT), client, "map_pick_chapter", CAMPAIGNS[c]); m.SetTitle("%s", sT); }
	char sMaps[8][40];
	int n = ExplodeString(CHAPTERS[c], ",", sMaps, sizeof(sMaps), sizeof(sMaps[]));
	for (int i = 0; i < n; i++)
		m.AddItem(sMaps[i], sMaps[i], IsMapValid(sMaps[i]) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	m.ExitBackButton = true;
	m.Display(client, MENU_TIME_FOREVER);
}

public int Menu_Chapters(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
	{
		m.GetItem(item, g_sChosenMap[client], sizeof(g_sChosenMap[]));
		MenuConfirmMap(client);
	}
	else if (a == MenuAction_Cancel && item == MenuCancel_ExitBack)
		MenuCampaigns(client);
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

void MenuConfirmMap(int client)
{
	Menu m = new Menu(Menu_ConfirmMap);
	char sT[256];
	Tr(sT, sizeof(sT), client, "map_confirm_title", g_sChosenMap[client], HumanPlayerCount());
	m.SetTitle("%s", sT);
	MenuEntry(m, client, "no", "reload_no");
	MenuEntry(m, client, "yes", "map_change_yes");
	Zero(m, client, "item_back", false, false);
	m.Display(client, MENU_TIME_FOREVER);
}

public int Menu_ConfirmMap(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
	{
		LogChoice(m, client, item, "ConfirmMap");
		char s[24];
		m.GetItem(item, s, sizeof(s));
		if (StrEqual(s, "yes") && IsOwner(client) && IsMapValid(g_sChosenMap[client]))
		{
			ChangeMap(client, g_sChosenMap[client]);
			return 0;
		}
		MenuChapters(client);
	}
	else if (a == MenuAction_Cancel && item == MenuCancel_Exit && InEditor(client))
		MenuChapters(client);
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

void ChangeMap(int client, const char[] mapName)
{
	LogEditor(client, "[coop] changes the map to %s", mapName);
	WriteState();                  // the work is already in its file: this refreshes the last move
	MarkReentry(client, false);
	for (int c = 1; c <= MaxClients; c++)
		if (IsClientInGame(c) && !IsFakeClient(c))
			Chat(c, "map_changing", mapName);
	DataPack dp;
	CreateDataTimer(3.0, Timer_ChangeMap, dp, TIMER_FLAG_NO_MAPCHANGE);
	dp.WriteString(mapName);
}

public Action Timer_ChangeMap(Handle t, DataPack dp)
{
	char sMap[64];
	dp.Reset();
	dp.ReadString(sMap, sizeof(sMap));
	ForceChangeLevel(sMap, "Stripper Map Editor: change of map");
	return Plugin_Stop;
}

// Server reserved during the map maintenance: whoever has no editor access cannot join while the
// editor mode is on; it opens again by itself when the map goes back to Survival.
int CountOthers(int client)
{
	int n = 0;
	for (int c = 1; c <= MaxClients; c++)
		if (c != client && IsClientInGame(c) && !IsFakeClient(c))
			n++;
	return n;
}

int CountWithoutAccess(int client)
{
	int n = 0;
	for (int c = 1; c <= MaxClients; c++)
		if (c != client && IsClientInGame(c) && !IsFakeClient(c) && !IsAuthorized(c))
			n++;
	return n;
}

// Names of the human players (all but "excluded", or only those in the editor), comma separated
void PlayerNames(int excluded, bool editorsOnly, char[] out, int len)
{
	out[0] = '\0';
	char sName[MAX_NAME_LENGTH];
	for (int c = 1; c <= MaxClients; c++)
	{
		if (c == excluded || !IsClientInGame(c) || IsFakeClient(c) || (editorsOnly && !InEditor(c)))
			continue;
		GetClientName(c, sName, sizeof(sName));
		if (out[0] != '\0')
			StrCat(out, len, ", ");
		if (strlen(out) + strlen(sName) + 4 >= len)
		{
			StrCat(out, len, "...");
			return;
		}
		StrCat(out, len, sName);
	}
}

// The owner arrives with the editor already open without panel: joining changes nothing,
// switching to the panel reloads the map for everyone
void MenuJoinOpen(int client)
{
	Menu m = new Menu(Menu_JoinOpen);
	char sNames[160], sT[320];
	PlayerNames(client, true, sNames, sizeof(sNames));
	Tr(sT, sizeof(sT), client, "join_open_title", sNames);
	m.SetTitle("%s", sT);
	MenuEntry(m, client, "join", "join_open_join");
	MenuEntry(m, client, "panel", "join_open_panel");
	Zero(m, client, "item_back", false, false);
	m.Display(client, MENU_TIME_FOREVER);
}

public int Menu_JoinOpen(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
	{
		LogChoice(m, client, item, "JoinOpen");
		char s[24];
		m.GetItem(item, s, sizeof(s));
		if (StrEqual(s, "join"))
		{
			if (!InEditor(client) && SeatFree() && IsAuthorized(client))
				EnterEditor(client);
		}
		else if (StrEqual(s, "panel"))
			MenuConfirmPanel(client);
	}
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

// Confirmation before switching to the panel with other players in the server: keep them or send them away
void MenuConfirmPanel(int client)
{
	Menu m = new Menu(Menu_ConfirmPanel);
	char sNames[160], sT[400];
	PlayerNames(client, false, sNames, sizeof(sNames));
	Tr(sT, sizeof(sT), client, "panel_warn_title", CountOthers(client), sNames);
	m.SetTitle("%s", sT);
	MenuEntry(m, client, "no", "panel_warn_no");
	MenuEntry(m, client, "keep", "panel_warn_keep");
	MenuEntry(m, client, "away", "panel_warn_kick", CountWithoutAccess(client) > 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	Zero(m, client, "item_back", false, false);
	m.Display(client, MENU_TIME_FOREVER);
}

public int Menu_ConfirmPanel(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
	{
		LogChoice(m, client, item, "ConfirmPanel");
		char s[24];
		m.GetItem(item, s, sizeof(s));
		if (StrEqual(s, "keep"))
			StartPanel(client, false);
		else if (StrEqual(s, "away"))
			StartPanel(client, true);
	}
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

// Switches to the editor mode with the panel; with "reserved" it first disconnects whoever has no access
void StartPanel(int client, bool reserved)
{
	if (reserved)
	{
		g_bReserved = true;
		char sId[32];
		for (int c = 1; c <= MaxClients; c++)
		{
			if (c == client || !IsClientInGame(c) || IsFakeClient(c) || IsAuthorized(c))
				continue;
			GetClientAuthId(c, AuthId_Steam2, sId, sizeof(sId));
			LogEditor(client, "maintenance: disconnected %N (%s)", c, sId);
			KickClient(c, "%T", "maint_kick", c);
		}
	}
	if (!SwitchToEditor(client))
	{
		g_bReserved = false;
		if (!InEditor(client) && SeatFree() && IsAuthorized(client))
			EnterEditor(client);
	}
}

// Confirmation before reloading the map: it reloads everything for everyone.
// type 0 = entering the editor from the normal game, 1 = "Publish and reload", 2 = "Publish and reload" while leaving
int g_iReloadConfirm[MAXPLAYERS + 1];

void MenuConfirmReload(int client, int kind)
{
	g_iReloadConfirm[client] = kind;
	Menu m = new Menu(Menu_ConfirmReload);
	char sT[256];
	Tr(sT, sizeof(sT), client, kind == 0 ? "reload_title_editor" : "reload_title", HumanPlayerCount());
	m.SetTitle("%s", sT);
	if (kind == 0)
	{
		MenuEntry(m, client, "yes", "start_with_hud");
		MenuEntry(m, client, "without", "start_without_hud");
	}
	else
	{
		MenuEntry(m, client, "no", "reload_no");
		MenuEntry(m, client, "yes", "reload_yes");
	}
	Zero(m, client, "item_back", false, false);
	m.Display(client, MENU_TIME_FOREVER);
}

int HumanPlayerCount()
{
	int n = 0;
	for (int c = 1; c <= MaxClients; c++)
		if (IsClientInGame(c) && !IsFakeClient(c))
			n++;
	return n;
}

public int Menu_ConfirmReload(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
	{
		LogChoice(m, client, item, "ConfirmReload");
		char s[24];
		m.GetItem(item, s, sizeof(s));
		int kind = g_iReloadConfirm[client];
		if (StrEqual(s, "without") && kind == 0)
		{
			LogEditor(client, "editor without panel: no reload");
			if (SeatFree() && IsAuthorized(client))
				EnterEditor(client);
			return 0;
		}
		if (StrEqual(s, "yes"))
		{
			if (kind == 0)
			{
				if (CountOthers(client) > 0)
					MenuConfirmPanel(client);
				else
					StartPanel(client, false);
			}
			else if (Unpublished() == 0 || SaveStripper(client))
				ReloadEditorMap(client);
			else
				MenuMain(client);
			return 0;
		}
		if (kind == 1)
			MenuSave(client);
		else if (kind == 2)
			AskExit(client);
	}
	else if (a == MenuAction_Cancel && item == MenuCancel_Exit && InEditor(client))
	{
		if (g_iReloadConfirm[client] == 1)
			MenuSave(client);
		else if (g_iReloadConfirm[client] == 2)
			AskExit(client);
		else
			MenuConfirmReload(client, 0);
	}
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

void ReloadEditorMap(int client)
{
	if (!CanActOnMap(client))
		return;
	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));
	LogEditor(client, "reloads the map %s", sMap);
	MarkReentry(client, false);
	g_bReloading = true;          // "Publish and reload": no second reload into Survival on leaving
	ChatAll("map_reloading_3s");
	LeaveEditor(client);
	DataPack dp;
	CreateDataTimer(3.0, Timer_Reload, dp);
	dp.WriteString(sMap);
}

public Action Timer_Reload(Handle t, DataPack dp)
{
	char sMap[64];
	dp.Reset();
	dp.ReadString(sMap, sizeof(sMap));
	ServerCommand("changelevel %s", sMap);
	return Plugin_Stop;
}

// ---------------------------------------------------------------- projection and beam
// The object in hand sits on the crosshair. On the floor there is its projection: the same object,
// solid, with a green glow. From the object's outer edge a faint column of light goes down to the
// projection: narrow seen from the side, wide seen from the front. Only the editor sees it.

#define COLOR_GREEN   (40 + (255 << 8) + (120 << 16))

void Preview(int client, int i, const float floor[3])
{
	int e = EntRefToEntIndex(g_iPreview[client]);
	if (e <= MaxClients)
	{
		char sModel[PLATFORM_MAX_PATH];
		ModelOf(i, sModel, sizeof(sModel));
		if (!IsModelPrecached(sModel) && PrecacheModel(sModel) == 0)
			return;
		e = CreateEntityByName("prop_dynamic_override");
		if (e == -1)
			return;
		DispatchKeyValue(e, "model", sModel);
		DispatchKeyValue(e, "solid", "0");
		DispatchKeyValue(e, "disableshadows", "1");
		DispatchSpawn(e);
		SDKHook(e, SDKHook_SetTransmit, Hook_EditorsOnly);
		Aura(e, true, COLOR_GREEN);
		g_iPreview[client] = EntIndexToEntRef(e);
	}
	float an[3];
	g_aAng.GetArray(i, an);
	TeleportEntity(e, floor, an, NULL_VECTOR);
}

void RemovePreview(int client)
{
	int r = EntRefToEntIndex(g_iBeam[client]);
	if (r > MaxClients)
		RemoveEntity(r);
	g_iBeam[client] = INVALID_ENT_REFERENCE;
	r = EntRefToEntIndex(g_iAnchorA[client]);
	if (r > MaxClients)
		RemoveEntity(r);
	g_iAnchorA[client] = INVALID_ENT_REFERENCE;
	r = EntRefToEntIndex(g_iAnchorB[client]);
	if (r > MaxClients)
		RemoveEntity(r);
	g_iAnchorB[client] = INVALID_ENT_REFERENCE;
	int e = EntRefToEntIndex(g_iPreview[client]);
	if (e > MaxClients)
		RemoveEntity(e);
	g_iPreview[client] = INVALID_ENT_REFERENCE;
}

// Outer edge of the object seen from above: the 8 corners of its box, rotated, and their outline
// (convex hull).
void UpdateBeam(int client, const float top[3], const float bottom[3])
{
	int a = EntRefToEntIndex(g_iAnchorA[client]), b = EntRefToEntIndex(g_iAnchorB[client]);
	float qa[3], qb[3];
	AddVectors(top, g_vCentre[client], qa);      // the column goes through the object's centre, not its origin
	AddVectors(bottom, g_vCentre[client], qb);
	if (a > MaxClients)
		TeleportEntity(a, qa, NULL_VECTOR, NULL_VECTOR);
	if (b > MaxClients)
		TeleportEntity(b, qb, NULL_VECTOR, NULL_VECTOR);
	float now = GetGameTime();
	if (now < g_fNextBeam[client] || g_iChosen[client] == -1)
		return;
	g_fNextBeam[client] = now + 0.1;
	float jump = top[2] - bottom[2];
	if (jump < 4.0)
		return;

	// The box is taken from the projection: it is the bare model, more faithful than the box of the
	// game item (wider for the *_spawn ones)
	int e = EntRefToEntIndex(g_iPreview[client]);
	if (e <= MaxClients)
		e = Movable(g_iChosen[client]);
	if (e <= MaxClients)
		return;
	float mn[3], mx[3], an[3], av[3], dx[3], up[3];
	GetEntPropVector(e, Prop_Send, "m_vecMins", mn);
	GetEntPropVector(e, Prop_Send, "m_vecMaxs", mx);
	if (GetVectorDistance(mn, mx) < 1.0)
	{
		mn = view_as<float>({ -6.0, -6.0, 0.0 });   // unknown box: a small cube
		mx = view_as<float>({ 6.0, 6.0, 8.0 });
	}
	g_aAng.GetArray(g_iChosen[client], an);
	GetAngleVectors(an, av, dx, up);
	{
		// centre of the box from the origin, rotated like the object: for the propane tank the origin is not at the centre
		float cx = (mn[0] + mx[0]) * 0.5, cy = (mn[1] + mx[1]) * 0.5, cz = (mn[2] + mx[2]) * 0.5;
		for (int k = 0; k < 3; k++)
			g_vCentre[client][k] = av[k] * cx - dx[k] * cy + up[k] * cz;
	}

	float px[8], py[8], zMin = 99999.0;
	for (int c = 0; c < 8; c++)
	{
		float lx = (c & 1) ? mx[0] : mn[0];
		float ly = (c & 2) ? mx[1] : mn[1];
		float lz = (c & 4) ? mx[2] : mn[2];
		// in Source the local y axis points left, the "right" vector right
		px[c] = av[0] * lx - dx[0] * ly + up[0] * lz;
		py[c] = av[1] * lx - dx[1] * ly + up[1] * lz;
		float pz = av[2] * lx - dx[2] * ly + up[2] * lz;
		if (pz < zMin) zMin = pz;
	}

	// convex hull (gift wrapping) on the 8 points
	int turn[8], n = 0;
	int first = 0;
	for (int c = 1; c < 8; c++)
		if (px[c] < px[first] || (px[c] == px[first] && py[c] < py[first]))
			first = c;
	int p = first;
	do
	{
		turn[n++] = p;
		int q = (p + 1) % 8;
		for (int r = 0; r < 8; r++)
		{
			float cr = (px[q] - px[p]) * (py[r] - py[p]) - (py[q] - py[p]) * (px[r] - px[p]);
			if (cr < 0.0)
				q = r;
		}
		p = q;
	} while (p != first && n < 8);

	// Width seen from here: the box measured across the view
	float eyes[3], view[3], side[3];
	GetClientEyePosition(client, eyes);
	SubtractVectors(top, eyes, view);
	view[2] = 0.0;
	NormalizeVector(view, view);
	side[0] = -view[1];
	side[1] = view[0];
	float lMin = 99999.0, lMax = -99999.0;
	for (int k = 0; k < n; k++)
	{
		float l = px[turn[k]] * side[0] + py[turn[k]] * side[1];
		if (l < lMin) lMin = l;
		if (l > lMax) lMax = l;
	}
	// the texture edge is blurred: a little narrower, so it does not spill over
	float wide = (lMax - lMin) * 0.55;
	if (wide < 2.0) wide = 2.0;

	// The column of light is attached to the two objects: the game draws it and follows them without
	// lag. Only its width is updated here.
	BeamOf(client, qa, qb, wide);
}

// env_beam between the object in hand and its projection (only the editor sees it)
// Invisible point (the column attaches to it): it stays exactly where it is put, unlike a model's
// origin, which for the propane tank is not its centre
int CreateAnchor(const float where[3])
{
	int e = CreateEntityByName("prop_dynamic_override");
	if (e == -1)
		return INVALID_ENT_REFERENCE;
	DispatchKeyValue(e, "model", "models/props_junk/popcan01a.mdl");
	DispatchKeyValue(e, "solid", "0");
	DispatchKeyValue(e, "disableshadows", "1");
	DispatchSpawn(e);
	SetEntityRenderMode(e, RENDER_NONE);
	TeleportEntity(e, where, NULL_VECTOR, NULL_VECTOR);
	return EntIndexToEntRef(e);
}

void BeamOf(int client, const float top[3], const float bottom[3], float wide)
{
	int e = EntRefToEntIndex(g_iBeam[client]);
	if (e <= MaxClients)
	{
		if (!IsModelPrecached("models/props_junk/popcan01a.mdl"))
			PrecacheModel("models/props_junk/popcan01a.mdl");
		g_iAnchorA[client] = CreateAnchor(top);
		g_iAnchorB[client] = CreateAnchor(bottom);
		int fromPos = EntRefToEntIndex(g_iAnchorA[client]), a = EntRefToEntIndex(g_iAnchorB[client]);
		if (fromPos <= MaxClients || a <= MaxClients)
			return;
		e = CreateEntityByName("env_beam");
		if (e == -1)
			return;
		DispatchKeyValue(e, "texture", "sprites/laserbeam.vmt");
		DispatchKeyValue(e, "rendercolor", "26 24 19");     // light adds the colour: dark = faint
		DispatchKeyValue(e, "renderamt", "9");           // faint: see-through
		DispatchKeyValue(e, "life", "0");
		DispatchKeyValue(e, "NoiseAmplitude", "0");
		DispatchSpawn(e);
		SetEntityModel(e, "sprites/laserbeam.vmt");
		SetEntityRenderColor(e, 26, 24, 19, 9);
		SetEntPropEnt(e, Prop_Send, "m_hAttachEntity", fromPos, 0);
		SetEntPropEnt(e, Prop_Send, "m_hAttachEntity", a, 1);
		SetEntProp(e, Prop_Send, "m_nNumBeamEnts", 2);
		SetEntProp(e, Prop_Send, "m_nBeamType", 2);       // BEAM_ENTS
		g_iMarkOwner[e] = client;
		SDKHook(e, SDKHook_SetTransmit, Hook_BeamOwner);   // computed from the owner's view: to others it would look crooked
		AcceptEntityInput(e, "TurnOn");
		g_iBeam[client] = EntIndexToEntRef(e);
	}
	SetEntPropFloat(e, Prop_Send, "m_fWidth", wide);
	SetEntPropFloat(e, Prop_Send, "m_fEndWidth", wide);
}

// ---------------------------------------------------------------- rotation
// One axis at a time. The mouse rotates the object on the active axis, left click changes axis,
// right click snaps to the next 15-degree step in the turning direction. A coloured level shows the
// axis (red pitch, green yaw, blue roll) and flashes every 15 degrees, stronger at 90. The
// character stays still.

#define ROTATE_SENSITIVITY 0.15       // degrees per mouse unit
#define ROTATE_SNAP      15.0
#define ROTATE_KEYS       40.0       // degrees per second with A/D
static const char AXIS_NAMES[][] = { "axis_pitch", "axis_yaw", "axis_roll" };

void RotateStart(int client)
{
	if (g_iChosen[client] == -1)
		return;
	ReleaseObject(client);              // closes move and fine move
	g_bRotate[client] = true;
	g_bRotateMoved[client] = false;
	g_bPaused[client] = false;
	g_bJumpBefore[client] = true;
	FixAxis(client);
	g_bLeftBefore[client] = g_bRightBefore[client] = true;   // the click that chose the item does not count
	SetEntityMoveType(client, MOVETYPE_NONE);
	TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
	// FL_FROZEN keeps the view still too, also in the client's prediction; the mouse still reaches the
	// plugin (mouse[]).
	SetEntityFlags(client, GetEntityFlags(client) | FL_FROZEN);
	LogEditor(client, "rotation #%d, axis %s", g_aHammer.Get(g_iChosen[client]), AXIS_NAMES[g_iAxis[client]]);
	InfoRotation(client);
}

void RotateStop(int client)
{
	g_bCombo[client] = false;
	if (!g_bRotate[client])
		return;
	if (g_bRotateMoved[client])
		RotateRecord(client);
	g_bRotate[client] = false;
	g_bPaused[client] = false;
	if (IsClientInGame(client))
	{
		SetEntityFlags(client, GetEntityFlags(client) & ~FL_FROZEN);
		SetEntityMoveType(client, g_bNoclip[client] ? MOVETYPE_NOCLIP : MOVETYPE_WALK);
	}
	LogEditor(client, "end of rotation");
}

void RotateRecord(int client)
{
	g_bRotateMoved[client] = false;
	float v[3], an[3];
	g_aPos.GetArray(g_iChosen[client], v);
	g_aAng.GetArray(g_iChosen[client], an);
	if (GetVectorDistance(v, g_fBeforePos[client]) > 0.01 || GetVectorDistance(an, g_fBeforeAng[client]) > 0.01)
		ReturnPoint(client, g_iChosen[client], g_fBeforePos[client], g_fBeforeAng[client]);
}

// The box is sent again only when the text changes (or every 2 s): sending it continuously restarts
// the animation and it stays empty for a moment.
char  g_sLastInfo[MAXPLAYERS + 1][192];
float g_fNextInfo[MAXPLAYERS + 1];
void InfoRotation(int client)
{
	if (g_fTurn[client] != g_fTurn[client])      // NaN: should not happen, but must not break the box
		g_fTurn[client] = 0.0;
	char sText[192], sAxis[48], sDegrees[16], sHelp[64];
	Tr(sAxis, sizeof(sAxis), client, AXIS_NAMES[g_iAxis[client]]);
	FormatEx(sDegrees, sizeof(sDegrees), "%.0f", NormalizeAngle(float(RoundToNearest(g_fTurn[client]))));
	Tr(sHelp, sizeof(sHelp), client, g_bCombo[client] ? "box_rot_help_combo" : "box_rot_help");
	Tr(sText, sizeof(sText), client, "box_rotation", sAxis, sDegrees, sHelp);
	float now = GetGameTime();
	if (StrEqual(sText, g_sLastInfo[client]) && now < g_fNextInfo[client])
		return;
	strcopy(g_sLastInfo[client], sizeof(g_sLastInfo[]), sText);
	g_fNextInfo[client] = now + 2.0;
	HintRaw(client, sText);
}

void BeforeRotating(int client)
{
	if (g_bRotateMoved[client])
		return;
	g_aPos.GetArray(g_iChosen[client], g_fBeforePos[client]);
	g_aAng.GetArray(g_iChosen[client], g_fBeforeAng[client]);
	g_bRotateMoved[client] = true;
}

Action RotationMode(int client, int &buttons, float vel[3], int &weapon, int mouse[2])
{
	bool leftClick = (buttons & IN_ATTACK) != 0;
	bool rightClick = (buttons & IN_ATTACK2) != 0;
	float an[3];
	g_aAng.GetArray(g_iChosen[client], an);
	bool changed = false;

	// Left click: next axis (the rotation made so far becomes a move)
	if (leftClick && !g_bLeftBefore[client])
	{
		if (g_bRotateMoved[client])
			RotateRecord(client);
		g_iAxis[client] = (g_iAxis[client] + 1) % 3;
		FixAxis(client);
		LogEditor(client, "axis %s", AXIS_NAMES[g_iAxis[client]]);
		g_fNextLevel[client] = 0.0;
		InfoRotation(client);
	}

	// Mouse (or A/D): continuous rotation on the active axis
	float delta = float(mouse[0]) * ROTATE_SENSITIVITY;
	if (buttons & IN_MOVERIGHT) delta += ROTATE_KEYS * GetTickInterval();
	if (buttons & IN_MOVELEFT)  delta -= ROTATE_KEYS * GetTickInterval();
	if (delta != 0.0)
	{
		BeforeRotating(client);
		float before = g_fTurn[client];
		g_fRotateDirection[client] = delta > 0.0 ? 1.0 : -1.0;
		g_fTurn[client] += delta;
		RotateAround(client, an, delta);
		Flash(client, before, g_fTurn[client], delta);
		changed = true;
	}

	// Right click: snap to the next 15-degree step, in the turning direction
	if (rightClick && !g_bRightBefore[client])
	{
		BeforeRotating(client);
		float before = g_fTurn[client];
		float steps = before / ROTATE_SNAP;
		float after;
		if (g_fRotateDirection[client] > 0.0)
			after = float(RoundToFloor(steps + 0.001) + 1) * ROTATE_SNAP;
		else
			after = float(RoundToCeil(steps - 0.001) - 1) * ROTATE_SNAP;
		RotateAround(client, an, after - before);
		g_fTurn[client] = after;
		Flash(client, before, g_fTurn[client], after - before);
		RotateRecord(client);           // the snap is a move by itself
		changed = true;
	}
	g_bLeftBefore[client] = leftClick;
	g_bRightBefore[client] = rightClick;

	if (changed)
	{
		g_aAng.SetArray(g_iChosen[client], an);
		RestRotated(g_iChosen[client]);
		UpdateCopy(g_iChosen[client]);
		if (CopyOf(g_iChosen[client]) <= MaxClients)
			GreyOriginal(g_iChosen[client], IsMoved(g_iChosen[client]));
	}
	Level(client);

	buttons &= ~(IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT | IN_JUMP | IN_DUCK
		| IN_ATTACK | IN_ATTACK2 | IN_USE);
	vel[0] = vel[1] = vel[2] = 0.0;
	weapon = 0;
	return Plugin_Changed;
}

// Passing a multiple of 15 degrees the level flashes; stronger at 90
void Flash(int client, float before, float after, float delta)
{
	float a = before, b = before + delta;
	if (a > b) { float t = a; a = b; b = t; }
	// the first multiple of 15 strictly after a, up to b included
	float m = float(RoundToFloor(a / ROTATE_SNAP) + 1) * ROTATE_SNAP;
	if (FloatAbs(after - float(RoundToNearest(after / ROTATE_SNAP)) * ROTATE_SNAP) < 0.01)
		m = float(RoundToNearest(after / ROTATE_SNAP)) * ROTATE_SNAP;
	if (m > b + 0.01)
		return;
	g_fFlashUntil[client] = GetGameTime() + 0.25;
	g_bFlashStrong[client] = FloatAbs(NormalizeAngle(m) - float(RoundToNearest(NormalizeAngle(m) / 90.0)) * 90.0) < 0.01;
	g_fNextLevel[client] = 0.0;
}

// Level: a circle around the object, on the plane it rotates in (perpendicular to the active axis),
// in the axis colour, with a hand that turns with the object. It flashes every 15 degrees, stronger
// at 90. The plane does not change while rotating: only the hand moves. Only the editor sees it.
#define CIRCLE_RADIUS 22.0
#define CIRCLE_SIDES   16
void Level(int client)
{
	float now = GetGameTime();
	if (now < g_fNextLevel[client] || (g_bCombo[client] && g_bCrossTurn[client]))
		return;
	g_fNextLevel[client] = now + 0.1;

	float v[3], an[3], av[3], dx[3], up[3], u[3], w[3], hand[3];
	g_aPos.GetArray(g_iChosen[client], v);
	g_aAng.GetArray(g_iChosen[client], an);
	GetAngleVectors(an, av, dx, up);
	v[2] += 6.0;                                   // about half way up the object
	u = g_vU[client];
	w = g_vW[client];
	// hand: the object's direction (forward, or up for roll) flattened onto the plane
	if (g_iAxis[client] == 2) hand = up; else hand = av;
	float onPivot = GetVectorDotProduct(hand, g_vAxis[client]);
	for (int c = 0; c < 3; c++)
		hand[c] -= g_vAxis[client][c] * onPivot;
	NormalizeVector(hand, hand);

	int colour[4];
	if (g_iAxis[client] == 0)      colour = { 255, 60, 60, 170 };
	else if (g_iAxis[client] == 1) colour = { 60, 255, 60, 170 };
	else                   colour = { 70, 120, 255, 170 };
	float wide = 0.6, radius = CIRCLE_RADIUS;
	if (now < g_fFlashUntil[client])
	{
		wide = g_bFlashStrong[client] ? 2.5 : 1.5;
		radius = g_bFlashStrong[client] ? CIRCLE_RADIUS + 6.0 : CIRCLE_RADIUS + 3.0;
		if (g_bFlashStrong[client])
			colour = { 255, 255, 255, 255 };
	}
	float a[3], b[3];
	for (int k = 0; k < CIRCLE_SIDES; k++)
	{
		float t0 = 2.0 * FLOAT_PI * float(k) / float(CIRCLE_SIDES);
		float t1 = 2.0 * FLOAT_PI * float(k + 1) / float(CIRCLE_SIDES);
		for (int c = 0; c < 3; c++)
		{
			a[c] = v[c] + (u[c] * Cosine(t0) + w[c] * Sine(t0)) * radius;
			b[c] = v[c] + (u[c] * Cosine(t1) + w[c] * Sine(t1)) * radius;
		}
		TE_SetupBeamPoints(a, b, g_iLevelModel, 0, 0, 0, 0.2, wide, wide, 0, 0.0, colour, 0);
		TE_SendToClient(client);
	}
	// hand: from the centre to the circle, in the object's direction
	for (int c = 0; c < 3; c++)
		b[c] = v[c] + hand[c] * radius;
	TE_SetupBeamPoints(v, b, g_iLevelModel, 0, 0, 0, 0.2, wide + 0.6, wide + 0.6, 0, 0.0, colour, 0);
	TE_SendToClient(client);
	InfoRotation(client);
}

// The model to show: the real game object's, if there is one (always right); otherwise the one
// deduced from the class or the dump.
void ModelOf(int i, char[] out, int len)
{
	int e = RealOf(i);
	if (e > MaxClients)
	{
		GetEntPropString(e, Prop_Data, "m_ModelName", out, len);
		if (out[0] != ' ' && out[0] != '*')
			return;
	}
	g_aModel.GetString(i, out, len);
}

// ---------------------------------------------------------------- WASD cross
// In fine move, on the floor around the object, four arrows along the fixed axes with the key's
// letter at the end, so where the object will go is known before pressing. Letters drawn with lines
// (L4D2 cannot write text in the world). Only the editor sees it.

#define CROSS_ARM 36.0
#define CROSS_LETTER 10.0
float g_fNextCross[MAXPLAYERS + 1];

// Every line lasts 0.35 s and is redrawn every 0.1 s: they overlap and stay lit without flashing.
// Letter strokes in a 0..1 square (x to the right, y forward)
static const float LETTER_W[][4] = { {0.0,1.0, 0.25,0.0}, {0.25,0.0, 0.5,0.6}, {0.5,0.6, 0.75,0.0}, {0.75,0.0, 1.0,1.0} };
static const float LETTER_A[][4] = { {0.0,0.0, 0.5,1.0}, {0.5,1.0, 1.0,0.0}, {0.25,0.5, 0.75,0.5} };
static const float LETTER_S[][4] = { {1.0,1.0, 0.0,1.0}, {0.0,1.0, 0.0,0.5}, {0.0,0.5, 1.0,0.5}, {1.0,0.5, 1.0,0.0}, {1.0,0.0, 0.0,0.0} };
static const float LETTER_D[][4] = { {0.0,0.0, 0.0,1.0}, {0.0,1.0, 0.6,1.0}, {0.6,1.0, 1.0,0.7}, {1.0,0.7, 1.0,0.3}, {1.0,0.3, 0.6,0.0}, {0.6,0.0, 0.0,0.0} };

// When still: redrawn every 0.1 s with 0.2 s lines (steady, no flashing). While moving it is not
// drawn: it would double. It comes back as soon as the keys are released.
float g_fLineLife = 0.35;
bool  g_bCrossMoving[MAXPLAYERS + 1];

void WasdCross(int client, bool moves)
{
	float now = GetGameTime();
	if (client <= 0 || (g_bCombo[client] && !g_bCrossTurn[client]))
		return;
	if (moves)
	{
		// while moving the cross is not drawn (it would double): it comes back when it stops
		g_bCrossMoving[client] = true;
		return;
	}
	else
	{
		// as soon as it stops it is redrawn at once, then at a slow pace
		if (now < g_fNextCross[client] && !g_bCrossMoving[client])
			return;
		// when still the cross does not change: it is redrawn rarely with long lines, leaving room for
		// the circle (effects limit per update)
		g_fLineLife = 0.7;
		g_fNextCross[client] = now + 0.6;
	}
	g_bCrossMoving[client] = moves;

	float o[3];
	g_aPos.GetArray(g_iChosen[client], o);
	o[2] += 1.5;
	float c = Cosine(DegToRad(g_fFineYaw[client])), sn = Sine(DegToRad(g_fFineYaw[client]));
	float av[3], dx[3];
	av[0] = c;   av[1] = sn;  av[2] = 0.0;     // W
	dx[0] = sn;  dx[1] = -c;  dx[2] = 0.0;     // D

	int yellow[4] = { 255, 220, 60, 80 };     // W / S
	int lightBlue[4] = { 80, 200, 255, 80 };    // A / D
	Arrow(client, o, av, yellow);
	Arrow(client, o, dx, lightBlue);
	float minus[3];
	minus = av; NegateVector(minus);
	Arrow(client, o, minus, yellow);
	minus = dx; NegateVector(minus);
	Arrow(client, o, minus, lightBlue);

	// Letters at the end of the arrows, readable looking towards W
	float where[3];
	PointAt(o, av, CROSS_ARM + CROSS_LETTER, where);
	Letter(client, where, dx, av, LETTER_W, sizeof(LETTER_W), yellow);
	PointAt(o, av, -(CROSS_ARM + CROSS_LETTER), where);
	Letter(client, where, dx, av, LETTER_S, sizeof(LETTER_S), yellow);
	PointAt(o, dx, CROSS_ARM + CROSS_LETTER, where);
	Letter(client, where, dx, av, LETTER_D, sizeof(LETTER_D), lightBlue);
	PointAt(o, dx, -(CROSS_ARM + CROSS_LETTER), where);
	Letter(client, where, dx, av, LETTER_A, sizeof(LETTER_A), lightBlue);
}

void PointAt(const float o[3], const float dir[3], float d, float out[3])
{
	for (int k = 0; k < 3; k++)
		out[k] = o[k] + dir[k] * d;
}

void Line(int client, const float a[3], const float b[3], const int colour[4], float wide)
{
	TE_SetupBeamPoints(a, b, g_iLevelModel, 0, 0, 0, g_fLineLife, wide, wide, 0, 0.0, colour, 0);
	TE_SendToClient(client);
}

// Arm from the object towards dir, with a V tip
void Arrow(int client, const float o[3], const float dir[3], const int colour[4])
{
	float a[3], b[3], p1[3], p2[3], side[3];
	PointAt(o, dir, 10.0, a);                // does not start inside the object
	PointAt(o, dir, CROSS_ARM, b);
	Line(client, a, b, colour, 0.4);
	side[0] = -dir[1]; side[1] = dir[0]; side[2] = 0.0;
	for (int k = 0; k < 3; k++)
	{
		p1[k] = b[k] - dir[k] * 6.0 + side[k] * 4.0;
		p2[k] = b[k] - dir[k] * 6.0 - side[k] * 4.0;
	}
	Line(client, b, p1, colour, 0.4);
	Line(client, b, p2, colour, 0.4);
}

void Letter(int client, const float centre[3], const float dx[3], const float av[3],
	const float[][] strokes, int n, const int colour[4])
{
	float a[3], b[3];
	for (int t = 0; t < n; t++)
	{
		for (int k = 0; k < 3; k++)
		{
			a[k] = centre[k] + dx[k] * (strokes[t][0] - 0.5) * CROSS_LETTER + av[k] * (strokes[t][1] - 0.5) * CROSS_LETTER;
			b[k] = centre[k] + dx[k] * (strokes[t][2] - 0.5) * CROSS_LETTER + av[k] * (strokes[t][3] - 0.5) * CROSS_LETTER;
		}
		Line(client, a, b, colour, 0.35);
	}
}

// ---------------------------------------------------------------- rotation pivot
// The object turns like a wheel nailed to the centre of the circle. The pivot is fixed when the
// axis is chosen (the object's axis at that moment) and stays still in the world; every rotation
// turns the object's vectors around the pivot and then derives the angles for the game.

void FixAxis(int client)
{
	float an[3], av[3], dx[3], up[3];
	g_aAng.GetArray(g_iChosen[client], an);
	GetAngleVectors(an, av, dx, up);
	if (g_iAxis[client] == 0)      { g_vAxis[client] = dx; g_vU[client] = av; g_vW[client] = up; }   // pitch
	else if (g_iAxis[client] == 1) { g_vAxis[client] = up; g_vU[client] = av; g_vW[client] = dx; }   // yaw
	else                   { g_vAxis[client] = av; g_vU[client] = dx; g_vW[client] = up; }   // roll
	g_fTurn[client] = (g_iAxis[client] == 1) ? an[1] : TurnFromFlat(client, an);
}

// v rotated by degrees around axis k (unit length), Rodrigues' formula
void RotateVector(float v[3], const float k[3], float degrees)
{
	float r = DegToRad(degrees), c = Cosine(r), sn = Sine(r);
	float kxv[3];
	GetVectorCrossProduct(k, v, kxv);
	float kv = GetVectorDotProduct(k, v);
	for (int i = 0; i < 3; i++)
		v[i] = v[i] * c + kxv[i] * sn + k[i] * kv * (1.0 - c);
}

void RotateAround(int client, float an[3], float degrees)
{
	float av[3], dx[3], up[3];
	GetAngleVectors(an, av, dx, up);
	RotateVector(av, g_vAxis[client], degrees);
	RotateVector(up, g_vAxis[client], degrees);
	AnglesFromVectors(av, up, an);
}

// Source angles from "forward" and "up": pitch and yaw from forward, roll from up
void AnglesFromVectors(const float av[3], const float up[3], float an[3])
{
	GetVectorAngles(av, an);
	float base[3], r0[3], u0[3], f0[3];
	base[0] = an[0]; base[1] = an[1]; base[2] = 0.0;
	GetAngleVectors(base, f0, r0, u0);
	an[2] = NormalizeAngle(RadToDeg(ArcTangent2(GetVectorDotProduct(up, r0), GetVectorDotProduct(up, u0))));
	an[0] = NormalizeAngle(an[0]);
	an[1] = NormalizeAngle(an[1]);
}

// ---------------------------------------------------------------- flat pose
// The zero of the rotation is the object lying flat: the thinnest side of its box vertical and the
// longest horizontal, in the direction it points now. The model's own zero (as drawn) is often
// askew. The Stripper file always gets the game's real angles: this zero only helps orientation.

// Model box (from the projection or the object)
bool Bounds(int i, float mn[3], float mx[3])
{
	int who = InUseBy(i);
	int e = who ? EntRefToEntIndex(g_iPreview[who]) : -1;
	if (e <= MaxClients)
		e = Movable(i);
	if (e <= MaxClients)
		return false;
	GetEntPropVector(e, Prop_Send, "m_vecMins", mn);
	GetEntPropVector(e, Prop_Send, "m_vecMaxs", mx);
	return GetVectorDistance(mn, mx) >= 1.0;
}

// The local axes in world coordinates: 0 = x (forward), 1 = y (left), 2 = z (up)
void LocalAxes(const float an[3], float axes[3][3])
{
	float av[3], dx[3], up[3];
	GetAngleVectors(an, av, dx, up);
	for (int c = 0; c < 3; c++)
	{
		axes[0][c] = av[c];
		axes[1][c] = -dx[c];
		axes[2][c] = up[c];
	}
}

// Angles of the flat pose, with the current direction of the long side
bool FlatPose(int i, const float an[3], float out[3])
{
	return StandardPose(i, an, 0, out);
}

// The six standard poses of an object, from its box: any side can be at the bottom. 0/1 = flat
// (shortest side vertical, upright or upside down), 2/3 = on its side (middle side), 4/5 = upright
// (longest side). The long side that stays horizontal points where it pointed before.

bool StandardPose(int i, const float an[3], int which, float out[3])
{
	float mn[3], mx[3];
	if (!Bounds(i, mn, mx))
		return false;
	float d[3];
	for (int c = 0; c < 3; c++)
		d[c] = mx[c] - mn[c];
	// axes sorted from the shortest to the longest
	int ord[3] = { 0, 1, 2 };
	for (int x = 0; x < 2; x++)
		for (int y = 0; y < 2 - x; y++)
			if (d[ord[y]] > d[ord[y + 1]])
			{
				int t = ord[y]; ord[y] = ord[y + 1]; ord[y + 1] = t;
			}
	int vertical = ord[which / 2];
	float direction = (which % 2 == 0) ? 1.0 : -1.0;    // upright or upside down
	// horizontal: the longest of the other two
	int along = (which / 2 == 2) ? ord[1] : ord[2];
	int third = 3 - vertical - along;

	float axes[3][3];
	LocalAxes(an, axes);
	float h[3];
	h[0] = axes[along][0];
	h[1] = axes[along][1];
	h[2] = 0.0;
	if (GetVectorLength(h) < 0.01)
	{
		h[0] = Cosine(DegToRad(an[1]));
		h[1] = Sine(DegToRad(an[1]));
	}
	NormalizeVector(h, h);

	float newAxes[3][3];
	for (int c = 0; c < 3; c++)
	{
		newAxes[vertical][c] = (c == 2) ? direction : 0.0;
		newAxes[along][c] = h[c];
	}
	// third axis: right-handed triple (x × y = z)
	float a[3], b[3], t[3];
	if (third == 0)      { a = newAxes[1]; b = newAxes[2]; }   // x = y × z
	else if (third == 1) { a = newAxes[2]; b = newAxes[0]; }   // y = z × x
	else                 { a = newAxes[0]; b = newAxes[1]; }   // z = x × y
	GetVectorCrossProduct(a, b, t);
	newAxes[third] = t;

	AnglesFromVectors(newAxes[0], newAxes[2], out);
	return true;
}

// Degrees on the pivot between the flat pose and the current pose (for pitch and roll)
float TurnFromFlat(int client, const float an[3])
{
	float flat[3];
	if (!FlatPose(g_iChosen[client], an, flat))
		return an[g_iAxis[client]];
	float av[3], dx[3], up[3], floorZ[3], pdx[3], psu[3], a[3], b[3];
	GetAngleVectors(an, av, dx, up);
	GetAngleVectors(flat, floorZ, pdx, psu);
	if (g_iAxis[client] == 2) { a = psu; b = up; } else { a = floorZ; b = av; }
	float sa = GetVectorDotProduct(a, g_vAxis[client]), sb = GetVectorDotProduct(b, g_vAxis[client]);
	for (int c = 0; c < 3; c++)
	{
		a[c] -= g_vAxis[client][c] * sa;
		b[c] -= g_vAxis[client][c] * sb;
	}
	if (GetVectorLength(a) < 0.01 || GetVectorLength(b) < 0.01)
		return 0.0;
	NormalizeVector(a, a);
	NormalizeVector(b, b);
	float x[3];
	GetVectorCrossProduct(a, b, x);
	return RadToDeg(ArcTangent2(GetVectorDotProduct(x, g_vAxis[client]), GetVectorDotProduct(a, b)));
}

// "Next pose": flat -> on its side -> upright -> flat...
void NextPose(int client)
{
	if (g_iChosen[client] == -1)
		return;
	float an[3], newOne[3];
	g_aAng.GetArray(g_iChosen[client], an);
	int which = (g_iPose[client] + 1) % 6;
	if (!StandardPose(g_iChosen[client], an, which, newOne))
	{
		Chat(client, "no_size");
		return;
	}
	g_iPose[client] = which;
	if (g_bRotateMoved[client])
		RotateRecord(client);
	BeforeRotating(client);
	g_aAng.SetArray(g_iChosen[client], newOne);
	RestRotated(g_iChosen[client]);
	UpdateCopy(g_iChosen[client]);
	if (CopyOf(g_iChosen[client]) <= MaxClients)
		GreyOriginal(g_iChosen[client], IsMoved(g_iChosen[client]));
	RotateRecord(client);
	if (g_bRotate[client])
		FixAxis(client);
	LogEditor(client, "pose %s #%d: %.0f %.0f %.0f", POSE_NAMES[which], g_aHammer.Get(g_iChosen[client]), newOne[0], newOne[1], newOne[2]);
	{ char sP[48]; Tr(sP, sizeof(sP), client, POSE_NAMES[which]); Hint(client, "hint_pose", sP); }
}

// Undoes everything the editor does to the player
void UnlockPlayer(int client)
{
	SetEntityFlags(client, GetEntityFlags(client) & ~FL_FROZEN);
	if (GetEntityMoveType(client) == MOVETYPE_NONE || GetEntityMoveType(client) == MOVETYPE_NOCLIP)
		SetEntityMoveType(client, MOVETYPE_WALK);
	SetEntProp(client, Prop_Send, "m_bDrawViewmodel", 1);
	SetEntProp(client, Prop_Send, "m_iHideHUD", 0);
	SetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue", 1.0);
}

// ---------------------------------------------------------------- pause
// During fine move and rotation the editor can pause (Jump or menu) to walk around and look at the
// object from elsewhere; Jump again resumes exactly where it was (same mode, same axis). The
// object stays still while paused.
void PauseMode(int client, bool active)
{
	if (active == g_bPaused[client])
		return;
	g_bPaused[client] = active;
	if (active)
	{
		if (g_bFineMoved[client])  FineRecord(client);
		if (g_bRotateMoved[client]) RotateRecord(client);
		SetEntityFlags(client, GetEntityFlags(client) & ~FL_FROZEN);
		SetEntityMoveType(client, g_bNoclip[client] ? MOVETYPE_NOCLIP : MOVETYPE_WALK);
		LogEditor(client, "pause");
		Hint(client, "hint_pause");
	}
	else
	{
		SetEntityMoveType(client, MOVETYPE_NONE);
		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
		if (g_bRotate[client])
		{
			SetEntityFlags(client, GetEntityFlags(client) | FL_FROZEN);
			g_sLastInfo[client][0] = '\0';
			InfoRotation(client);
		}
		else
			Hint(client, "hint_fine_short");
		LogEditor(client, "resume");
	}
	MenuObject(client);
}

// ---------------------------------------------------------------- resting while rotating
// While rotating, the object rests like a real one on a table: the lowest point of its rotated box
// touches the surface below. It neither sinks into the floor nor floats. Side walls are not checked.
void RestRotated(int i)
{
	float v[3];
	g_aPos.GetArray(i, v);
	RestAt(i, v);
	g_aPos.SetArray(i, v);
}

// Moves v to the height at which object i, with its current rotation, touches the surface below
// with its lowest point (the rotated box). Used by moving, the floor projection, release and
// rotation.
void RestAt(int i, float v[3])
{
	float mn[3], mx[3], an[3], av[3], dx[3], up[3];
	if (!Bounds(i, mn, mx))
	{
		RestOnFloor(v);
		return;
	}
	g_aAng.GetArray(i, an);
	GetAngleVectors(an, av, dx, up);
	float zMin = 99999.0, zMax = -99999.0;
	for (int c = 0; c < 8; c++)
	{
		float lx = (c & 1) ? mx[0] : mn[0];
		float ly = (c & 2) ? mx[1] : mn[1];
		float lz = (c & 4) ? mx[2] : mn[2];
		float z = av[2] * lx - dx[2] * ly + up[2] * lz;
		if (z < zMin) zMin = z;
		if (z > zMax) zMax = z;
	}
	// the surface under the object's centre
	float fromPos[3];
	fromPos = v;
	fromPos[2] += (zMax > 8.0 ? zMax : 8.0);
	Handle tr = TR_TraceRayFilterEx(fromPos, view_as<float>({90.0, 0.0, 0.0}), MASK_SOLID, RayType_Infinite, Filter_NoPlayersNorCopies);
	if (TR_DidHit(tr))
	{
		float floor[3];
		TR_GetEndPosition(floor, tr);
		v[2] = floor[2] - zMin;
	}
	delete tr;
}

// ---------------------------------------------------------------- move and rotate
// Fine move and rotation together: WASD moves the object on the fixed axes (cross on the floor),
// the mouse rotates it on the active axis (circle and hand), left click changes axis, right click
// snaps by 15 degrees. The view stays still, Jump pauses. Here A and D move: only the mouse rotates.
void ComboStart(int client)
{
	if (g_iChosen[client] == -1)
		return;
	FineStart(client);            // closes everything else and sets up WASD
	g_bRotate[client] = true;
	g_bRotateMoved[client] = false;
	g_bLeftBefore[client] = g_bRightBefore[client] = true;
	FixAxis(client);
	SetEntityFlags(client, GetEntityFlags(client) | FL_FROZEN);
	g_bCombo[client] = true;
	g_sLastInfo[client][0] = '\0';
	LogEditor(client, "move and rotate #%d", g_aHammer.Get(g_iChosen[client]));
	Hint(client, "hint_combo");
}

Action Combined(int client, int &buttons, float vel[3], int &weapon, int mouse[2])
{
	// The game sends at most about 32 effects per update: cross and circle together are more and the
	// circle got lost, so they are drawn in turns.
	g_bCrossTurn[client] = !g_bCrossTurn[client];
	int originals = buttons;
	FineMove(client, buttons, vel, weapon);    // WASD: movement (clears the movement keys)
	// rotation gets the clicks but not A/D, which move here
	int forRotation = originals & ~(IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT);
	RotationMode(client, forRotation, vel, weapon, mouse);
	buttons = forRotation;            // already cleaned by the rotation
	return Plugin_Changed;
}

// ---------------------------------------------------------------- map reset
// Every object goes back to its real map position. Each object brought back is a move (it can be
// undone). The Stripper file changes only on Save.
void MenuConfirmReset(int client)
{
	Menu m = new Menu(Menu_ConfirmReset);
	{ char sT[192]; Tr(sT, sizeof(sT), client, "confirm_reset_title", ToSave()); m.SetTitle("%s", sT); }
	MenuEntry(m, client, "no", "confirm_no");
	MenuEntry(m, client, "yes", "confirm_yes_reset");
	Zero(m, client, "item_back", false);
	m.Display(client, MENU_TIME_FOREVER);
}

public int Menu_ConfirmReset(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
		LogChoice(m, client, item, "ConfirmReset");
	if (a == MenuAction_Select)
	{
		char s[24];
		m.GetItem(item, s, sizeof(s));
		if (StrEqual(s, "yes"))
			ResetMap(client);
		MenuMain(client);
	}
	else if (a == MenuAction_Cancel && item == MenuCancel_Exit)
		MenuMain(client);
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

void ResetMap(int client)
{
	if (!CanActOnMap(client))
		return;
	ReleaseObject(client);
	if (g_iChosen[client] != -1)
		Deselect(client);
	int n = 0;
	float pv[3], pa[3], v[3], an[3];
	for (int i = 0; i < g_aHammer.Length; i++)
	{
		if (g_aHammer.Get(i) <= 0 || !MovedFromReal(i))
			continue;
		g_aPos.GetArray(i, pv);
		g_aAng.GetArray(i, pa);
		g_aReal.GetArray(i, v);
		g_aAngReal.GetArray(i, an);
		g_aPos.SetArray(i, v);
		g_aAng.SetArray(i, an);
		UpdateCopy(i);
		GreyOriginal(i, IsMoved(i));
		ReturnPoint(client, i, pv, pa);
		n++;
	}
	LogEditor(client, "map reset: %d objects back to the original", n);
	Chat(client, "reverted_n", n);
	// A destroyed (exploded) map object comes back only by reloading the map; the restored positions
	// are already in the return points.
	if (g_bDestroyed)
	{
		int lost = 0;
		for (int i = 0; i < g_aHammer.Length; i++)
			if (g_aHammer.Get(i) > 0 && RealOf(i) <= MaxClients && CopyOf(i) <= MaxClients)
				lost++;
		Chat(client, "reset_reload", lost > 0 ? lost : 1);
		WriteState();
		ReloadEditorMap(client);
	}
}

// ---------------------------------------------------------------- take me there
// The editor lands a little behind the object, on the side it came from, already facing it. A wall
// behind stops it earlier.
#define GOTO_DISTANCE 90.0
#define GOTO_HEIGHT  40.0

void GoToObject(int client)
{
	float obj[3], mine[3], dir[3], where[3];
	g_aPos.GetArray(g_iChosen[client], obj);
	GetClientAbsOrigin(client, mine);
	SubtractVectors(mine, obj, dir);
	dir[2] = 0.0;
	if (GetVectorLength(dir) < 1.0)
		dir[0] = 1.0;
	NormalizeVector(dir, dir);

	float centre[3];
	centre = obj;
	centre[2] += 8.0;
	for (int c = 0; c < 3; c++)
		where[c] = centre[c] + dir[c] * GOTO_DISTANCE;
	where[2] += GOTO_HEIGHT;
	// not inside a wall: stop before the obstacle
	Handle tr = TR_TraceRayFilterEx(centre, where, MASK_PLAYERSOLID, RayType_EndPoint, Filter_NoPlayersNorCopies);
	if (TR_DidHit(tr))
	{
		TR_GetEndPosition(where, tr);
		float back[3];
		SubtractVectors(centre, where, back);
		NormalizeVector(back, back);
		ScaleVector(back, 20.0);
		AddVectors(where, back, where);
	}
	delete tr;

	// view towards the object (the eyes are about 64 units above the feet)
	float eyes[3], direction[3], ang[3];
	eyes = where;
	eyes[2] += 64.0;
	SubtractVectors(centre, eyes, direction);
	GetVectorAngles(direction, ang);
	ang[2] = 0.0;
	TeleportEntity(client, where, ang, view_as<float>({0.0, 0.0, 0.0}));
	LogEditor(client, "near #%d", g_aHammer.Get(g_iChosen[client]));
}

// ---------------------------------------------------------------- unsaved changes
// Leaving with unsaved changes asks what to do; the main menu shows them in its title; coming back
// in, the chat says so.
// "Unsaved" = moves made (or undone) after the last Save.
// "Unpublished" = objects that differ from the server's file (what Stripper applied when the map
// loaded, or the last publishing).
int Unpublished()
{
	int n = 0;
	for (int i = 0; i < g_aHammer.Length; i++)
		if (g_aHammer.Get(i) > 0 && DifferentFromMap(i))
			n++;
	return n;
}

void AskExit(int client, bool alwaysAsk = false)
{
	ReleaseObject(client);
	Menu m = new Menu(Menu_AskExit);
	#pragma unused alwaysAsk                                // the confirmation is always asked
	bool reload = (EditorCount() == 1 && g_bDirectorStopped);   // the last one out reloads the map
	if (Unpublished() == 0)
	{
		// always confirm: leaving can reload the map for everyone
		{ char sT[160]; Tr(sT, sizeof(sT), client, reload ? "exit_title_reload" : "exit_title"); m.SetTitle("%s", sT); }
		MenuEntry(m, client, "exit", "exit_yes");
	}
	else
	{
		{ char sT[64]; Tr(sT, sizeof(sT), client, "exit_unsaved_title", Unpublished()); m.SetTitle("%s", sT); }
		MenuEntry(m, client, "save", "exit_save");
		MenuEntry(m, client, "reload", "item_save_reload");
		MenuEntry(m, client, "exit", "exit_nosave");
	}
	Zero(m, client, "item_back", false);
	m.Display(client, MENU_TIME_FOREVER);
}

int g_iExitChoice[MAXPLAYERS + 1];        // 1 = publish and exit, 2 = exit without publishing

void MenuConfirmExit(int client)
{
	Menu m = new Menu(Menu_ConfirmExit);
	char sT[192];
	Tr(sT, sizeof(sT), client, (EditorCount() == 1 && g_bDirectorStopped) ? "exit_title_reload" : "exit_title");
	m.SetTitle("%s", sT);
	MenuEntry(m, client, "yes", g_iExitChoice[client] == 1 ? "exit_save" : "exit_yes");
	MenuEntry(m, client, "no", "reload_no");
	Zero(m, client, "item_back", false, false);
	m.Display(client, MENU_TIME_FOREVER);
}

// In L4D2 a closed menu stays drawn until something else arrives: an empty panel for one second clears it
public int Menu_Empty(Menu m, MenuAction a, int client, int item)
{
	return 0;
}

void ClearMenuOnScreen(int client)
{
	Panel p = new Panel();
	p.SetTitle(" ");
	p.Send(client, Menu_Empty, 1);
	delete p;
}

public int Menu_ConfirmExit(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
	{
		LogChoice(m, client, item, "ConfirmExit");
		char s[24];
		m.GetItem(item, s, sizeof(s));
		if (!StrEqual(s, "yes"))
		{
			AskExit(client);
			return 0;
		}
		if (g_iExitChoice[client] == 1)
		{
			if (SaveStripper(client))
				LeaveEditor(client);
			else
				MenuMain(client);
		}
		else
		{
			LogEditor(client, "left with %d unsaved changes", Unpublished());
			LeaveEditor(client);
		}
	}
	else if (a == MenuAction_Cancel && item == MenuCancel_Exit && InEditor(client))
		AskExit(client);
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

public int Menu_AskExit(Menu m, MenuAction a, int client, int item)
{
	if (a == MenuAction_Select)
		LogChoice(m, client, item, "AskExit");
	if (a == MenuAction_Select)
	{
		char s[24];
		m.GetItem(item, s, sizeof(s));
		if (StrEqual(s, "save") || (StrEqual(s, "exit") && Unpublished() > 0))
		{
			g_iExitChoice[client] = StrEqual(s, "save") ? 1 : 2;
			MenuConfirmExit(client);
			return 0;
		}
		else if (StrEqual(s, "reload"))
		{
			MenuConfirmReload(client, 2);
			return 0;
		}
		else if (StrEqual(s, "exit"))
		{
			LogEditor(client, "left with %d unsaved changes", Unpublished());
			LeaveEditor(client);
		}
		else
			MenuMain(client);
	}
	else if (a == MenuAction_Cancel && item == MenuCancel_Exit)
		MenuMain(client);      // 0 = stay in the editor
	else if (a == MenuAction_End)
		delete m;
	return 0;
}

// All times are game times, which restart from zero on every map: without resetting them, after a
// reload they stay "in the future" and things stop (for example selecting by looking).
void ResetTimes(int client)
{
	g_fNextLook[client] = 0.0;
	g_fNextBeam[client] = 0.0;
	g_fNextLevel[client] = 0.0;
	g_fFlashUntil[client] = 0.0;
	g_fNextCross[client] = 0.0;
	g_fNextInfo[client] = 0.0;
	g_sLastInfo[client][0] = '\0';
	g_bCrossMoving[client] = false;
	g_bWallChoice[client] = false;
	g_bFineMove[client] = g_bFineMoved[client] = g_bRotate[client] = g_bRotateMoved[client] = g_bCombo[client] = g_bPaused[client] = false;
}

// ---------------------------------------------------------------- drop
// Medkits, weapons, ammo and the like have no physics and stay as saved, even in an impossible
// balance. "Drop" makes a copy with physics in the same pose, lets it fall until it stops and puts
// the real object there. It is a move (it can be undone).
#define DROP_MAX 5.0               // seconds at most

void DropObject(int client)
{
	if (g_iChosen[client] == -1)
		return;
	float v[3], an[3];
	// In hand it falls from where it is: Release would put it on the floor
	bool inHand = g_bGrabbed[client];
	g_aPos.GetArray(g_iChosen[client], v);
	if (inHand)
	{
		ReleaseObject(client);
		g_aPos.SetArray(g_iChosen[client], v);
		UpdateCopy(g_iChosen[client]);
	}
	g_aAng.GetArray(g_iChosen[client], an);
	StartDrop(client, g_iChosen[client], v, an);
}

// Drops object i from (da, an): a copy with physics falls, and when it stops the real object goes
// there. Several drops can run at once. For *_spawn objects the copy is the game item
// (weapon_first_aid_kit and so on), which always has physics when it falls; for the others a
// prop_physics with the same model (a prop with the medkit model spawned without physics).
bool StartDrop(int client, int i, const float fromPos[3], const float an[3])
{
	char sModel[PLATFORM_MAX_PATH];
	ModelOf(i, sModel, sizeof(sModel));
	if (!IsModelPrecached(sModel))
		PrecacheModel(sModel);
	char sClass[64];
	int real0 = RealOf(i);
	if (real0 > MaxClients)
		GetEntityClassname(real0, sClass, sizeof(sClass));
	int fine = StrContains(sClass, "_spawn");
	bool wpn = StrContains(sClass, "weapon_") == 0 && fine > 0;
	LogEditor(client, "drop started #%d (class %s, %s)", g_aHammer.Get(i), sClass, wpn ? "game item" : "copia prop_physics");
	int e;
	if (wpn)
	{
		sClass[fine] = '\0';
		e = CreateEntityByName(sClass);
	}
	else
		e = CreateEntityByName("prop_physics_override");
	if (e == -1)
		return false;
	if (!wpn)
	{
		DispatchKeyValue(e, "model", sModel);
		DispatchKeyValue(e, "spawnflags", "4");      // no pick-up with the use key
	}
	DispatchKeyValueVector(e, "origin", fromPos);
	DispatchKeyValueVector(e, "angles", an);
	if (!DispatchSpawn(e))
	{
		if (IsValidEntity(e))
			RemoveEntity(e);
		Chat(client, "cannot_create_copy");
		return false;
	}
	SetEntityCollisionGroup(e, 1);   // debris: does not hit the players
	if (HasEntProp(e, Prop_Data, "m_takedamage"))
		SetEntProp(e, Prop_Data, "m_takedamage", 0);   // the falling copy does not explode
	SDKHook(e, SDKHook_SetTransmit, Hook_EditorsOnly);
	// the real object disappears while the copy falls (the copy is what falls)
	int group = 0;
	int real = Movable(i);
	if (real > MaxClients)
	{
		SetEntityRenderMode(real, RENDER_TRANSALPHA);
		SetEntityRenderColor(real, 255, 255, 255, 0);
		// debris too, otherwise the copy spawning on the same spot hits it
		group = GetEntProp(real, Prop_Send, "m_CollisionGroup");
		SetEntityCollisionGroup(real, 1);
	}
	TeleportEntity(e, NULL_VECTOR, NULL_VECTOR, view_as<float>({0.0, 0.0, -1.0}));

	float pv[3], pa[3];
	g_aPos.GetArray(i, pv);
	g_aAng.GetArray(i, pa);
	DataPack dp;
	CreateDataTimer(0.1, Timer_Drop, dp, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	dp.WriteCell(GetClientUserId(client));
	dp.WriteCell(EntIndexToEntRef(e));
	dp.WriteCell(g_aHammer.Get(i));
	dp.WriteCell(group);
	dp.WriteFloat(GetGameTime() + DROP_MAX);
	for (int c = 0; c < 3; c++) dp.WriteFloat(pv[c]);   // state before, for undo
	for (int c = 0; c < 3; c++) dp.WriteFloat(pa[c]);
	dp.WriteFloat(0.0);                                  // since when it has been still (0 = moving)
	g_iDropsRunning++;
	{ char sK[12]; IntToString(g_aHammer.Get(i), sK, sizeof(sK)); g_smDropping.SetValue(sK, client); }
	LogEditor(client, "drop #%d", g_aHammer.Get(i));
	return true;
}

public Action Timer_Drop(Handle t, DataPack dp)
{
	dp.Reset();
	int userid = dp.ReadCell();
	int e = EntRefToEntIndex(dp.ReadCell());
	int hammer = dp.ReadCell();
	int group = dp.ReadCell();
	float expiry = dp.ReadFloat();
	float pv[3], pa[3];
	for (int c = 0; c < 3; c++) pv[c] = dp.ReadFloat();
	for (int c = 0; c < 3; c++) pa[c] = dp.ReadFloat();
	DataPackPos stillPos = dp.Position;
	float stop = dp.ReadFloat();

	int i = g_aHammer.FindValue(hammer);
	int client = GetClientOfUserId(userid);
	if (e <= MaxClients || i == -1)
	{
		// the copy is gone: the object becomes visible as it was
		if (i != -1)
			ReappearAfterDrop(i, group);
		if (client > 0)
			Chat(client, "copy_vanished");
		g_iDropsRunning--;
	{ char sK[12]; IntToString(hammer, sK, sizeof(sK)); g_smDropping.Remove(sK); }
		return Plugin_Stop;
	}
	float vel[3];
	GetEntPropVector(e, Prop_Data, "m_vecAbsVelocity", vel);
	float now = GetGameTime();
	if (GetVectorLength(vel) < 1.0)
	{
		if (stop == 0.0)
		{
			dp.Position = stillPos;
			dp.WriteFloat(now);
			stop = now;
		}
	}
	else if (stop != 0.0)
	{
		dp.Position = stillPos;
		dp.WriteFloat(0.0);
		stop = 0.0;
	}
	if (!(stop != 0.0 && now - stop >= 0.4) && now < expiry)
		return Plugin_Continue;

	// still: the real object goes where the copy stopped
	float v[3], an[3];
	GetEntPropVector(e, Prop_Data, "m_vecAbsOrigin", v);
	GetEntPropVector(e, Prop_Data, "m_angAbsRotation", an);
	RemoveEntity(e);
	for (int c = 0; c < 3; c++)
		an[c] = NormalizeAngle(an[c]);
	g_aPos.SetArray(i, v);
	g_aAng.SetArray(i, an);
	ReappearAfterDrop(i, group);
	UpdateCopy(i);
	GreyOriginal(i, IsMoved(i));
	if (InUseBy(i) != 0)
		SetOutline(i, true);
	ReturnPoint(client, i, pv, pa);
	g_iDropsRunning--;
	{ char sK[12]; IntToString(hammer, sK, sizeof(sK)); g_smDropping.Remove(sK); }
	if (client > 0)
	{
		LogEditor(client, "dropped #%d at %.1f %.1f %.1f", hammer, v[0], v[1], v[2]);
		if (InEditor(client) && g_iChosen[client] != -1 && g_iDropsRunning == 0)
			MenuObject(client);
	}
	return Plugin_Stop;
}

void ReappearAfterDrop(int i, int group)
{
	int real = Movable(i);
	if (real <= MaxClients)
		return;
	SetEntityRenderMode(real, RENDER_NORMAL);
	SetEntityRenderColor(real, 255, 255, 255, 255);
	// the selected object stays untouchable while selected
	SetEntityCollisionGroup(real, (InUseBy(i) != 0) ? 1 : group);
}

// ---------------------------------------------------------------- panel test
// Small test: three fixed boxes at the top right with the VScript HUD. The code runs through the
// RunScriptCode input on a logic_script of the plugin (no sv_cheats). Known limit: every player
// sees this HUD. Outside mutations the HUD_... names do not exist, so numbers are used
// (8 = HUD_FAR_RIGHT, 4 = HUD_RIGHT_TOP, 5 = HUD_RIGHT_BOT; 256 = align left, 64 = no background).
int  g_iScript = INVALID_ENT_REFERENCE;

void Script(const char[] code)
{
	int e = EntRefToEntIndex(g_iScript);
	if (e <= MaxClients)
	{
		e = CreateEntityByName("logic_script");
		if (e == -1)
			return;
		DispatchKeyValue(e, "targetname", "zf_stripper_map_editor_script");
		DispatchSpawn(e);
		g_iScript = EntIndexToEntRef(e);
	}
	SetVariantString(code);
	AcceptEntityInput(e, "RunScriptCode");
}

public Action Cmd_HudTest(int client, int args)
{
	EditorPanel(!g_bHud);
	ReplyToCommand(client, "[ZF] Panel %s.", g_bHud ? "on" : "off");
	return Plugin_Handled;
}

// Ruler: one box at the top, as wide as the 4:3 area and beyond, with numbered digits to count the
// space actually visible.
public Action Cmd_Ruler(int client, int args)
{
	g_bRuler = !g_bRuler;
	if (g_bRuler)
	{
		char r1[160], r2[160];
		r1[0] = '\0';
		r2[0] = '\0';
		for (int d = 1; d <= 12; d++)
		{
			StrCat(r1, sizeof(r1), "1234567890");
			char sDec[16];
			FormatEx(sDec, sizeof(sDec), "--------%2d", d * 10);
			StrCat(r2, sizeof(r2), sDec);
		}
		char sCode[700];
		FormatEx(sCode, sizeof(sCode), "HUDSetLayout({ Fields = { r = { slot = 4, flags = 256, dataval = \"%s\\n%s\\nMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM\\niiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii\" } } }); HUDPlace(4, 0.0, 0.02, 1.3, 0.14);", r1, r2);
		Script(sCode);
	}
	else if (g_bHud)
		EditorPanel(true);
	else
		Script("HUDSetLayout({ Fields = {} });");
	ReplyToCommand(client, "[ZF] Ruler %s.", g_bRuler ? "on" : "off");
	return Plugin_Handled;
}

// Switched on entering the editor (only in zfstrippermapeditor) and off leaving.
// Three boxes at the top: general, context, info. Positions with HUDPlace (x, y, width, height as
// fractions of the screen); the height follows the number of lines, so the text is not cut. The
// fractions apply to the 4:3 area at the centre of the screen and past 1.0 the text is cut (x = 0 is
// the left edge of that area; about 80 digits fit).
#define HUD_COL_W 0.485
#define HUD_COL2  0.50
// Designed for Full HD and up. The text is always about 28 pixels per line whatever the
// resolution, while the boxes are screen fractions: at 1080 lines one line is 0.026. Below Full HD
// the text is cut.
#define HUD_LINE  0.026
char g_sHud[3][256];

void EditorPanel(bool isOn)
{
	g_bHud = isOn;
	if (g_bHud)
	{
		for (int k = 0; k < 3; k++)
			g_sHud[k][0] = '\0';
		// slot: 4 = RIGHT_TOP, 5 = RIGHT_BOT, 8 = FAR_RIGHT; flags 256 = align left
		Script("::ZFHud <- { Fields = { "
			... "gen = { slot = 4, flags = 256, dataval = \"\" }, "
			... "ctx = { slot = 5, flags = 256, dataval = \"\" }, "
			... "inf = { slot = 8, flags = 256, dataval = \"\" }, "
			... "lab = { slot = 3, flags = 256, dataval = \"\" }, "
			... "mir = { slot = 2, flags = 576, dataval = \"\" } } }; "
			... "HUDSetLayout(::ZFHud);");
		UpdatePanel();
		Crosshair(false);
	}
	else
		Script("HUDSetLayout({ Fields = {} });");
	LogMessage("[editor] panel %s", g_bHud ? "on" : "off");
}

int CountLines(const char[] t)
{
	int n = 1;
	for (int i = 0; t[i] != '\0'; i++)
		if (t[i] == '\n')
			n++;
	return n;
}

// Text inside a Squirrel string: backslashes, quotes and newlines escaped
void ForScript(const char[] t, char[] out, int len)
{
	strcopy(out, len, t);
	ReplaceString(out, len, "\\", "\\\\");
	ReplaceString(out, len, "\"", "\\\"");
	ReplaceString(out, len, "\n", "\\n");
}

// Panel 3: the chosen object. The two distances have clear names, so they are not taken for two
// measures of the same thing: "from original" = from where it was at first, "from you" = from the
// player's eyes to the object's current position, in metres.
float DistanceFromYou(int client, int i)
{
	float eyes[3], pos[3];
	GetClientEyePosition(client, eyes);
	g_aPos.GetArray(i, pos);
	return GetVectorDistance(eyes, pos) * UNITS_TO_METRES;
}

void ObjectText(int client, char[] out, int len)
{
	int c = client;
	char sKind[64], sPose[48], sOrig[64], sFromYou[16];
	TypeName(g_iChosen[client], c, sKind, sizeof(sKind));
	PoseName(g_iChosen[client], sPose, sizeof(sPose), c);
	float real[3], pos[3];
	g_aReal.GetArray(g_iChosen[client], real);
	g_aPos.GetArray(g_iChosen[client], pos);
	if (MovedFromReal(g_iChosen[client]))
	{
		char sM[16];
		FormatEx(sM, sizeof(sM), "%.1f", GetVectorDistance(real, pos) * UNITS_TO_METRES);
		Tr(sOrig, sizeof(sOrig), c, "pan_from_orig", sM);
	}
	else
		Tr(sOrig, sizeof(sOrig), c, "pan_in_place");
	FormatEx(sFromYou, sizeof(sFromYou), "%.1f", DistanceFromYou(c, g_iChosen[client]));
	Tr(out, len, c, "pan_object", sKind, g_aHammer.Get(g_iChosen[client]), sOrig, sFromYou, sPose);
}

// Panel 2: the current mode and keys, action and key separated by a colon, no long sentences.
void ContextText(int client, char[] out, int len)
{
	int c = client;
	char sAxis[48];
	Tr(sAxis, sizeof(sAxis), c, AXIS_NAMES[g_iAxis[client]]);
	if (g_iChosen[client] == -1)
	{
		Tr(out, len, c, "pan_ctx_none");
		return;
	}
	if (g_bGrabbed[client])
		Tr(out, len, c, "pan_ctx_move");
	else if (g_bCombo[client])
		Tr(out, len, c, "pan_ctx_combo", sAxis);
	else if (g_bFineMove[client])
		Tr(out, len, c, "pan_ctx_fine");
	else if (g_bRotate[client])
		Tr(out, len, c, "pan_ctx_rot", sAxis);
	else
		Tr(out, len, c, "pan_ctx_still");
	if (g_bPaused[client])
	{
		char sR[48];
		Tr(sR, sizeof(sR), c, "pan_ctx_resume");
		StrCat(out, len, sR);
	}
}

// Updates the three boxes, only when the text changed
void UpdatePanel()
{
	int client = HudSource();
	if (!g_bHud || g_bRuler || client == 0)
		return;
	char t[3][256], sMap[48];
	GetCurrentMap(sMap, sizeof(sMap));
	// column 1: general (title, map, mode, state, undo/redo, saves)
	char sState[32];
	Tr(sState, sizeof(sState), client, g_bNoclip[client] ? "state_noclip" : "state_walking");
	char sMapMode[32];
	Tr(sMapMode, sizeof(sMapMode), client, g_bFreeMode ? "map_mode_free" : "map_mode_faithful");
	Tr(t[0], 256, client, "pan_general", sMap, sMapMode, sState, CountMoves(g_aHistory, client), CountMoves(g_aRedo, client), Unsaved(), Unpublished(), ToSave());
	if (g_iChosen[client] == -1)
	{
		ContextText(client, t[1], 256);
		Tr(t[2], 256, client, "pan_no_object");
	}
	else
	{
		ContextText(client, t[1], 256);
		ObjectText(client, t[2], 256);
	}

	bool changed = false;
	for (int k = 0; k < 3; k++)
		if (!StrEqual(t[k], g_sHud[k]))
			changed = true;
	if (!changed)
		return;

	static const char OBJECT_NAMES[3][] = { "gen", "ctx", "inf" };
	static const int SLOT[3] = { 4, 5, 8 };
	// Three columns side by side, all as tall as the longest: they look like one panel. x starts a
	// little inside because at 0.0 the border is cut.
	int lines = 1;
	for (int k = 0; k < 3; k++)
		if (CountLines(t[k]) > lines)
			lines = CountLines(t[k]);
	float h = HUD_LINE * lines + 0.03;
	// The text sits at the centre of its box: the shorter columns get empty lines, so all three start
	// on the same top line
	char sFull[300];
	char sCode[1600], sEsc[400], sPiece[520];
	sCode[0] = '\0';
	for (int k = 0; k < 3; k++)
	{
		strcopy(g_sHud[k], 256, t[k]);
		strcopy(sFull, sizeof(sFull), t[k]);
		for (int r = CountLines(t[k]); r < lines; r++)
			StrCat(sFull, sizeof(sFull), "\n ");
		ForScript(sFull, sEsc, sizeof(sEsc));
		FormatEx(sPiece, sizeof(sPiece), "::ZFHud.Fields.%s.dataval = \"%s\"; HUDPlace(%d, %.3f, 0.020, 0.314, %.3f); ",
			OBJECT_NAMES[k], sEsc, SLOT[k], 0.012 + 0.328 * k, h);
		StrCat(sCode, sizeof(sCode), sPiece);
	}
	Script(sCode);
}

// ---------------------------------------------------------------- menu title
// In Survival the script HUD does not show, so the general part goes into the object menu title,
// which updates by itself when it changes (mode, axis, pause, unsaved changes). Fast-changing data
// (degrees) stays in the bottom box. With the HUD panel on one line with object and mode is
// enough (the rest is in the panel); without it (Survival, panel off) the full title stays.
void MenuTitle(int client, char[] out, int len)
{
	char sFull[384];
	ObjectTitle(client, sFull, sizeof(sFull));
	if (!g_bHud)
	{
		strcopy(out, len, sFull);
		return;
	}
	char lines[7][128], sObject[128];
	int n = ExplodeString(sFull, "\n", lines, sizeof(lines), sizeof(lines[]));
	if (n < 3)
	{
		strcopy(out, len, sFull);
		return;
	}
	int pos = SplitString(lines[1], " · ", sObject, sizeof(sObject));
	if (pos == -1)
		strcopy(sObject, sizeof(sObject), lines[1]);
	FormatEx(out, len, "ZF Stripper Map Editor\n%s · %s", sObject, lines[2]);
	if (g_bPaused[client])
	{
		char sP[32];
		Tr(sP, sizeof(sP), client, "title_paused");
		StrCat(out, len, sP);
	}
}

void ObjectTitle(int client, char[] out, int len)
{
	int c = client;
	char sKind[64], sMode[96], sKeys[128], sExtra[64], sAxis[48], sWall[32];
	TypeName(g_iChosen[client], c, sKind, sizeof(sKind));
	Tr(sAxis, sizeof(sAxis), c, AXIS_NAMES[g_iAxis[client]]);
	sWall[0] = '\0';
	if (g_bWallAligned[client])
		Tr(sWall, sizeof(sWall), c, "wall_axes");
	if (g_bGrabbed[client])
	{
		Tr(sMode, sizeof(sMode), c, "mode_move");
		Tr(sKeys, sizeof(sKeys), c, "keys_move");
	}
	else if (g_bCombo[client])
	{
		Tr(sMode, sizeof(sMode), c, "mode_combo", sAxis, sWall);
		Tr(sKeys, sizeof(sKeys), c, "keys_combo");
	}
	else if (g_bFineMove[client])
	{
		Tr(sMode, sizeof(sMode), c, "mode_fine", sWall);
		Tr(sKeys, sizeof(sKeys), c, "keys_fine");
	}
	else if (g_bRotate[client])
	{
		Tr(sMode, sizeof(sMode), c, "mode_rot", sAxis);
		Tr(sKeys, sizeof(sKeys), c, "keys_rot");
	}
	else
	{
		Tr(sMode, sizeof(sMode), c, "mode_still");
		Tr(sKeys, sizeof(sKeys), c, "keys_still");
	}
	if (g_bPaused[client])
		Tr(sExtra, sizeof(sExtra), c, "title_paused_line");
	else
		sExtra[0] = '\0';
	int n = Unpublished();
	char sUnsaved[48];
	if (n > 0)
		Tr(sUnsaved, sizeof(sUnsaved), c, "title_unsaved", n);
	else
		sUnsaved[0] = '\0';

	// object: number, distance from its original place, pose
	char sObject[128], sPose[48];
	PoseName(g_iChosen[client], sPose, sizeof(sPose), c);
	float a[3], b[3];
	g_aReal.GetArray(g_iChosen[client], a);
	g_aPos.GetArray(g_iChosen[client], b);
	float m = GetVectorDistance(a, b) * UNITS_TO_METRES;
	if (MovedFromReal(g_iChosen[client]))
		FormatEx(sObject, sizeof(sObject), "%s #%d · %.1f m · %s", sKind, g_aHammer.Get(g_iChosen[client]), m, sPose);
	else
		Tr(sObject, sizeof(sObject), c, "title_obj_in_place", sKind, g_aHammer.Get(g_iChosen[client]), sPose);

	// state: on foot/noclip, moved objects, unsaved changes
	char sState[128], sOnFoot[32];
	Tr(sOnFoot, sizeof(sOnFoot), c, g_bNoclip[client] ? "state_noclip" : "state_walking");
	Tr(sState, sizeof(sState), c, "title_state", sOnFoot, ToSave(), sUnsaved);

	FormatEx(out, len, "ZF Stripper Map Editor\n%s\n%s\n%s%s\n%s",
		sObject, sMode, sKeys, sExtra, sState);
}

// For the HUD panel: context box (mode and keys) and info box (object and state). The pieces
// come from the menu title, so they say the same thing.
public Action Timer_Title(Handle t)
{
	// Editor on but no menu on screen (closed by a vote, by another plugin...): it opens again, so
	// nobody is ever in the editor without a menu.
	UpdatePanel();
	CoopMarks();
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!g_bInEditor[client] || !IsClientInGame(client))
			continue;
		if (GetClientMenu(client) == MenuSource_None)
		{
			g_fNoMenu[client] += 0.3;
			if (g_fNoMenu[client] >= 1.0)
			{
				g_fNoMenu[client] = 0.0;
				if (g_iChosen[client] != -1) MenuObject(client); else MenuMain(client);
				continue;
			}
		}
		else
			g_fNoMenu[client] = 0.0;
		if (g_bSeesPlayer[client] && GetClientMenu(client) != MenuSource_None)
		{
			int b = GetClientOfUserId(g_iTarget[client]);
			if (b > 0 && IsClientInGame(b) && InEditor(b) != g_bTargetInside[client])
				MenuPlayer(client);              // the player joined or left: the "Kick" item changes
		}
		if (g_iMenuOpen[client] != 2 || g_iChosen[client] == -1)
			continue;
		char sTitle[384];
		MenuTitle(client, sTitle, sizeof(sTitle));
		if (!StrEqual(sTitle, g_sLastTitle[client]))
			MenuObject(client);
	}
	return Plugin_Continue;
}

// The test HUD panel (mutations only) goes off on leaving, if it was on
void PanelOffIfOn()
{
	if (g_bHud)
		EditorPanel(false);
}

// ---------------------------------------------------------------- live information

// The standard pose the object is in (with its direction), or "rotated"
void PoseName(int i, char[] out, int len, int client)
{
	float an[3], p[3], av[3], dx[3], up[3], floorZ[3], pdx[3], psu[3];
	g_aAng.GetArray(i, an);
	GetAngleVectors(an, av, dx, up);
	for (int q = 0; q < 6; q++)
	{
		if (!StandardPose(i, an, q, p))
			break;
		GetAngleVectors(p, floorZ, pdx, psu);
		// same pose if "up" matches and so does the horizontal direction
		if (GetVectorDotProduct(up, psu) > 0.999 && GetVectorDotProduct(av, floorZ) > 0.999)
		{
			Tr(out, len, client, POSE_NAMES[q]);
			return;
		}
	}
	Tr(out, len, client, "pose_rotated");
}

// Bottom box: sent again only when the text changes (or every 2 s)
char  g_sLastBox[MAXPLAYERS + 1][192];
float g_fNextBox[MAXPLAYERS + 1];
void BottomBox(int client, const char[] text)
{
	float now = GetGameTime();
	if (StrEqual(text, g_sLastBox[client]) && now < g_fNextBox[client])
		return;
	strcopy(g_sLastBox[client], sizeof(g_sLastBox[]), text);
	g_fNextBox[client] = now + 2.0;
	HintRaw(client, text);
}

// Move: distance of the object from the editor
void InfoMove(int client)
{
	char t[160], sM[16];
	FormatEx(sM, sizeof(sM), "%.1f", DistanceFromYou(client, g_iChosen[client]));
	Tr(t, sizeof(t), client, "box_move", sM);
	BottomBox(client, t);
}

// Fine move: how far the object moved in this move, on the fixed axes
void InfoFineMove(int client)
{
	float v[3], d[3];
	g_aPos.GetArray(g_iChosen[client], v);
	SubtractVectors(v, g_fBeforePos[client], d);
	float c = Cosine(DegToRad(g_fFineYaw[client])), sn = Sine(DegToRad(g_fFineYaw[client]));
	float fwd = (d[0] * c + d[1] * sn) * UNITS_TO_METRES * 100.0;
	float right = (d[0] * sn - d[1] * c) * UNITS_TO_METRES * 100.0;
	char t[160];
	if (g_bFineMoved[client])
	{
		char sFwd[16], sDe[16];
		FormatEx(sFwd, sizeof(sFwd), "%+.0f", fwd);
		FormatEx(sDe, sizeof(sDe), "%+.0f", right);
		Tr(t, sizeof(t), client, "box_fine_moving", sFwd, sDe);
	}
	else
		Tr(t, sizeof(t), client, "box_fine_idle");
	BottomBox(client, t);
}

// ---------------------------------------------------------------- wall alignment
// A ray from the crosshair reads the normal of the surface looked at; from there W/S go towards and
// away from the wall, A/D slide along it. It works with a low wall too, as long as the crosshair is
// on it. The chosen point is highlighted for 3 seconds.
#define WALL_HIGHLIGHT 3.0

bool AlignToWall(int client)
{
	float eyes[3], view[3], fine[3], fwd[3], normal[3], point[3];
	GetClientEyePosition(client, eyes);
	GetClientEyeAngles(client, view);
	GetAngleVectors(view, fwd, NULL_VECTOR, NULL_VECTOR);
	for (int c = 0; c < 3; c++)
		fine[c] = eyes[c] + fwd[c] * 2000.0;
	Handle tr = TR_TraceRayFilterEx(eyes, fine, MASK_SOLID, RayType_EndPoint, Filter_NoPlayersNorCopies);
	bool hit = TR_DidHit(tr);
	if (hit)
	{
		TR_GetPlaneNormal(tr, normal);
		TR_GetEndPosition(point, tr);
	}
	delete tr;
	if (!hit)
	{
		Hint(client, "hint_wall_none");
		return false;
	}
	// must be a wall (nearly vertical), not the floor
	if (FloatAbs(normal[2]) > 0.7)
	{
		Hint(client, "hint_wall_floor");
		return false;
	}
	// W = towards the wall (against the normal), on the horizontal plane
	g_fFineYaw[client] = RadToDeg(ArcTangent2(-normal[1], -normal[0]));
	g_bWallAligned[client] = true;
	g_fNextCross[client] = 0.0;
	HighlightWall(client, point, normal);
	LogEditor(client, "aligned to the wall: axes at %.1f degrees", g_fFineYaw[client]);
	{ char sA[16]; FormatEx(sA, sizeof(sA), "%.0f", NormalizeAngle(g_fFineYaw[client])); Hint(client, "hint_wall_aligned", sA); }
	return true;
}

void AlignToMap(int client)
{
	float view[3];
	GetClientEyeAngles(client, view);
	g_fFineYaw[client] = float(RoundToNearest(view[1] / 90.0)) * 90.0;
	g_bWallAligned[client] = false;
	g_fNextCross[client] = 0.0;
	LogEditor(client, "map axes (%.0f degrees)", g_fFineYaw[client]);
	Hint(client, "hint_map_axes");
}

// An orange rectangle on the wall at the chosen point, and an arrow coming out of it
void HighlightWall(int client, const float point[3], const float normal[3], float duration = WALL_HIGHLIGHT)
{
	float along[3], up[3] = { 0.0, 0.0, 1.0 };
	GetVectorCrossProduct(normal, up, along);      // direction along the wall
	NormalizeVector(along, along);
	float p[3];
	for (int c = 0; c < 3; c++)
		p[c] = point[c] + normal[c] * 1.0;          // just in front of the wall
	float a[3], b[3], cc[3], d[3], n[3];
	for (int c = 0; c < 3; c++)
	{
		a[c] = p[c] - along[c] * 40.0 - up[c] * 12.0;
		b[c] = p[c] + along[c] * 40.0 - up[c] * 12.0;
		cc[c] = p[c] + along[c] * 40.0 + up[c] * 12.0;
		d[c] = p[c] - along[c] * 40.0 + up[c] * 12.0;
		n[c] = p[c] + normal[c] * 24.0;
	}
	int colour[4] = { 255, 150, 40, 220 };
	float pts[5][3];
	pts[0] = a; pts[1] = b; pts[2] = cc; pts[3] = d; pts[4] = a;
	for (int k = 0; k < 4; k++)
	{
		TE_SetupBeamPoints(pts[k], pts[k + 1], g_iLevelModel, 0, 0, 0, duration, 1.0, 1.0, 0, 0.0, colour, 0);
		TE_SendToClient(client);
	}
	TE_SetupBeamPoints(p, n, g_iLevelModel, 0, 0, 0, duration, 1.0, 1.0, 0, 0.0, colour, 0);
	TE_SendToClient(client);
}

// ---------------------------------------------------------------- untouchable object
// While an object is selected it does not stop against characters (a bot in the way blocked it
// and the cross and circle kept going). Collision group "debris": it hits the world, not players.


// Gas cans, propane tanks and fireworks do not explode while someone is in the editor (a hit can
// blow one up, and a reset does not bring it back).
bool IsExplosive(int i)
{
	char sKey[64];
	g_aKind.GetString(i, sKey, sizeof(sKey));
	return StrEqual(sKey, "type_gascan") || StrEqual(sKey, "type_propane")
		|| StrEqual(sKey, "type_oxygen") || StrEqual(sKey, "type_fireworks");
}

void ProtectExplosives(bool protect)
{
	for (int i = 0; i < g_aHammer.Length; i++)
	{
		if (!IsExplosive(i))
			continue;
		int e = RealOf(i);
		if (e > MaxClients && HasEntProp(e, Prop_Data, "m_takedamage"))
			SetEntProp(e, Prop_Data, "m_takedamage", protect ? 0 : 2);
	}
}

// Map objects destroyed during the session (exploded): the reset reloads the map
public void OnEntityDestroyed(int entity)
{
	if (EditorCount() == 0 || g_aEnt == null || entity <= MaxClients)
		return;
	int ref = EntIndexToEntRef(entity);
	for (int i = 0; i < g_aEnt.Length; i++)
		if (g_aEnt.Get(i) == ref)
		{
			g_bDestroyed = true;
			LogMessage("[editor] [disaster] map object destroyed #%d", g_aHammer.Get(i));
			return;
		}
}
void Untouchable(int i, bool si)
{
	int e = RealOf(i);
	if (e <= MaxClients || !HasEntProp(e, Prop_Send, "m_CollisionGroup"))
		return;
	char sK[16];
	IntToString(EntIndexToEntRef(e), sK, sizeof(sK));
	int group;
	if (si)
	{
		if (!g_smGroup.GetValue(sK, group))
			g_smGroup.SetValue(sK, GetEntProp(e, Prop_Send, "m_CollisionGroup"));
		SetEntityCollisionGroup(e, 1);
		// No "not solid" flag: the engine wrote thousands of "in solid list" lines
	}
	else if (g_smGroup.GetValue(sK, group))
	{
		SetEntityCollisionGroup(e, group);
		g_smGroup.Remove(sK);
	}
}

// ---------------------------------------------------------------- choosing the wall
// "Align to the wall" frees the view; the wall under the crosshair is highlighted while looking;
// use or left click confirm, right click cancels.
void StartWallChoice(int client)
{
	g_bWallChoice[client] = true;
	g_bLeftBeforeWall[client] = g_bRightBeforeWall[client] = true;     // the click that chose the item does not count
	g_fNextWall[client] = 0.0;
	SetEntityFlags(client, GetEntityFlags(client) & ~FL_FROZEN);   // free view
	LogEditor(client, "wall choice");
	Hint(client, "hint_wall_pick");
}

void EndWallChoice(int client)
{
	g_bWallChoice[client] = false;
	if (g_bRotate[client] && !g_bPaused[client])
		SetEntityFlags(client, GetEntityFlags(client) | FL_FROZEN);
	g_fNextCross[client] = 0.0;
	MenuObject(client);
}

Action WallChoice(int client, int &buttons, float vel[3], int &weapon, bool usePressed)
{
	bool sx = (buttons & IN_ATTACK) != 0, dx = (buttons & IN_ATTACK2) != 0;
	bool confirm = usePressed || (sx && !g_bLeftBeforeWall[client]);
	bool undoIt = dx && !g_bRightBeforeWall[client];
	g_bLeftBeforeWall[client] = sx;
	g_bRightBeforeWall[client] = dx;

	if (confirm)
	{
		if (AlignToWall(client))
			EndWallChoice(client);
	}
	else if (undoIt)
	{
		LogEditor(client, "wall choice cancelled");
		Hint(client, "hint_wall_cancelled");
		EndWallChoice(client);
	}
	else
	{
		// preview: the wall under the crosshair, updated while looking
		float now = GetGameTime();
		if (now >= g_fNextWall[client])
		{
			g_fNextWall[client] = now + 0.15;
			float eyes[3], view[3], fwd[3], fine[3], normal[3], point[3];
			GetClientEyePosition(client, eyes);
			GetClientEyeAngles(client, view);
			GetAngleVectors(view, fwd, NULL_VECTOR, NULL_VECTOR);
			for (int c = 0; c < 3; c++)
				fine[c] = eyes[c] + fwd[c] * 2000.0;
			Handle tr = TR_TraceRayFilterEx(eyes, fine, MASK_SOLID, RayType_EndPoint, Filter_NoPlayersNorCopies);
			bool hit = TR_DidHit(tr);
			if (hit)
			{
				TR_GetPlaneNormal(tr, normal);
				TR_GetEndPosition(point, tr);
			}
			delete tr;
			if (hit && FloatAbs(normal[2]) <= 0.7)
			{
				HighlightWall(client, point, normal, 0.2);
				{ char sB[160]; Tr(sB, sizeof(sB), client, "box_wall_ok"); BottomBox(client, sB); }
			}
			else
				{ char sB[160]; Tr(sB, sizeof(sB), client, "box_not_wall"); BottomBox(client, sB); }
		}
	}

	// the character stays still, the keys do not reach the game
	buttons &= ~(IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT | IN_JUMP | IN_DUCK
		| IN_ATTACK | IN_ATTACK2 | IN_USE);
	vel[0] = vel[1] = vel[2] = 0.0;
	weapon = 0;
	return Plugin_Changed;
}

// ---------------------------------------------------------------- quick fill
// From the first object put in place, every click takes another object of the same type (the
// nearest not used yet), spawns it a little above and drops it with physics: it makes a natural
// little pile. Every object added is a move.

bool UsableForFill(int client, int k)
{
	if (k == g_iChosen[client] || Holder(k) != 0 || g_aHammer.Get(k) <= 0 || g_aFilled[client].FindValue(g_aHammer.Get(k)) != -1)
		return false;
	char a[64], b[64];
	g_aKind.GetString(k, a, sizeof(a));
	g_aKind.GetString(g_iChosen[client], b, sizeof(b));
	return StrEqual(a, b);
}

int AvailableForFill(int client)
{
	if (g_iChosen[client] == -1)
		return 0;
	int n = 0;
	for (int k = 0; k < g_aHammer.Length; k++)
		if (UsableForFill(client, k))
			n++;
	return n;
}

void Fill(int client)
{
	if (g_iChosen[client] == -1)
		return;
	float centre[3], v[3];
	g_aPos.GetArray(g_iChosen[client], centre);
	int best = -1;
	float bestDist = 0.0;
	for (int k = 0; k < g_aHammer.Length; k++)
	{
		if (!UsableForFill(client, k))
			continue;
		g_aPos.GetArray(k, v);
		float d = GetVectorDistance(centre, v);
		if (best == -1 || d < bestDist)
		{
			best = k;
			bestDist = d;
		}
	}
	if (best == -1)
	{
		Hint(client, "hint_no_others");
		return;
	}
	// a little above the first, slightly offset and randomly turned: falling, they scatter
	int n = g_aFilled[client].Length;
	float fromPos[3], an[3];
	fromPos[0] = centre[0] + GetRandomFloat(-6.0, 6.0);
	fromPos[1] = centre[1] + GetRandomFloat(-6.0, 6.0);
	fromPos[2] = centre[2] + 18.0 + 10.0 * float(n);
	an[0] = 0.0;
	an[1] = GetRandomFloat(0.0, 360.0);
	an[2] = 0.0;
	if (StartDrop(client, best, fromPos, an))
	{
		g_aFilled[client].Push(g_aHammer.Get(best));
		char sKind[64];
		TypeName(best, client, sKind, sizeof(sKind));
		LogEditor(client, "fill: %s #%d in the pile (%d)", sKind, g_aHammer.Get(best), n + 1);
	}
}

// ---------------------------------------------------------------- wrong object
// The wrong object was taken from the list: it goes back exactly where it was, without counting
// as a move, and the list opens again on the same page.
void WrongObject(int client)
{
	if (g_iChosen[client] == -1)
		return;
	if (g_bGrabbed[client])
	{
		g_bGrabbed[client] = false;
		RemovePreview(client);
		GrabSpeed(client, false);
		g_aPos.SetArray(g_iChosen[client], g_fBeforePos[client]);
		g_aAng.SetArray(g_iChosen[client], g_fBeforeAng[client]);
		UpdateCopy(g_iChosen[client]);
		GreyOriginal(g_iChosen[client], IsMoved(g_iChosen[client]));
	}
	LogEditor(client, "wrong object #%d: put back in its place", g_aHammer.Get(g_iChosen[client]));
	Deselect(client);
	MenuList(client, g_iListPage[client]);
}

// ---------------------------------------------------------------- redo
// Walk (Shift) + Reload (R), or "Redo" in the menu: brings back the last undone move. A new move
// clears the stack.
void Redo(int client)
{
	int r = -1;
	for (int k = g_aRedo.Length - 1; k >= 0 && r == -1; k--)
		if (ByAuthor(g_aRedo, k, AuthorOf(client)))
			r = k;
	if (r == -1)
	{
		Hint(client, "hint_nothing_redo");
		return;
	}
	any line[8];
	g_aRedo.GetArray(r, line);
	if (HeldByOthers(client, g_aHammer.FindValue(line[0])))
		return;
	g_aRedo.Erase(r);
	int i = g_aHammer.FindValue(line[0]);
	if (i == -1)
		return;
	// the current state goes back into the history, so it can be undone again
	any historyLen[8];
	float v[3], an[3];
	g_aPos.GetArray(i, v);
	g_aAng.GetArray(i, an);
	historyLen[0] = line[0];
	historyLen[7] = AuthorOf(client);
	for (int k = 0; k < 3; k++)
	{
		historyLen[1 + k] = v[k];
		historyLen[4 + k] = an[k];
		v[k] = line[1 + k];
		an[k] = line[4 + k];
	}
	g_aHistory.PushArray(historyLen);
	g_aPos.SetArray(i, v);
	g_aAng.SetArray(i, an);
	UpdateCopy(i);
	GreyOriginal(i, IsMoved(i));
	if (g_bRotate[client] && i == g_iChosen[client])
		FixAxis(client);
	char sKind[64];
	TypeName(i, client, sKind, sizeof(sKind));
	LogEditor(client, "redo #%d (%d to redo)", line[0], g_aRedo.Length);
	Signal(client, i, "verb_redone", sKind);
	WriteState();
}

// ---------------------------------------------------------------- 9 of the menus: undo, Walk+9 redo
// A menu cannot show the player's own keys (the client does not replace binding placeholders there),
// so it names the game action; the bottom hint, which the client does fill in, shows the real key.
// g_sWalkKey is the key name when the tool knows it (owner playing on the server's PC; to do), empty
// otherwise.

void WalkKeyName(int client, char[] out, int len)
{
	if (g_sWalkKey[client][0] != '\0')
		strcopy(out, len, g_sWalkKey[client]);
	else
		Tr(out, len, client, "key_walk");
}

// ---------------------------------------------------------------- the 0 of the menus
// In every menu 0 = Back (to the menu above), like the parent folder in a file browser; in the
// main menu 0 = Exit the editor, with a confirmation. The plugin writes the 0 itself: a menu without
// pages has 10 places (1-9 and 0); empty places are empty lines, so the box always has the same
// height.
void Zero(Menu m, int client, const char[] key, bool undoIt = true, bool redoStack = true)
{
	m.Pagination = MENU_NO_PAGINATION;
	m.ExitButton = false;
	m.ExitBackButton = false;
	#pragma unused redoStack
	// 8 stays free: redo is Walk+9. 9 = undo, the same in every action menu; empty in confirmations
	while (m.ItemCount < 8)
		m.AddItem("_", "", ITEMDRAW_SPACER);
	if (undoIt)
	{
		char sKey[16], sItem[96];
		WalkKeyName(client, sKey, sizeof(sKey));
		Tr(sItem, sizeof(sItem), client, "item_undo_redo", sKey);
		m.AddItem("nine", sItem);
	}
	else if (m.ItemCount < 9)
		m.AddItem("_", "", ITEMDRAW_SPACER);
	MenuEntry(m, client, "zero", key);
	char sTitle[192];
	m.GetTitle(sTitle, sizeof(sTitle));
	ReplaceString(sTitle, sizeof(sTitle), "\n", " / ");
	LogMessage("[editor] [menu] opened for %N: %s", client, sTitle);
}

// The 9 of the menus: undo, or redo while Walk is held. The first time in a session the bottom hint
// shows the player's real Walk key.
void MenuNine(int client)
{
	if (g_iRawButtons[client] & IN_SPEED)
		Redo(client);
	else
		Undo(client, 0);
	if (!g_bRedoHintShown[client])
	{
		g_bRedoHintShown[client] = true;
		Hint(client, "hint_redo_key");
	}
}

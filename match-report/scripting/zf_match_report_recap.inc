// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zombie Foundry
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. This program is distributed in the hope that it
// will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details: LICENSE
// file next to this source, or <https://www.gnu.org/licenses/>.

#if defined _zf_mr_recap_included
#endinput
#endif
#define _zf_mr_recap_included

// Match recap page (0.1.75). The page is built outside the game by the Report service, which
// reads the METRIC block from the log and then writes the match number into the ready file.
// The plugin only reads that file and opens <zf_mr_report_url><match>.html — it never builds
// pages, never writes or deletes the ready file, never puts stats in the URL.

// Relative to addons/sourcemod. One line: the number of the last match whose page is ready.
#define ZMR_RECAP_READY_FILE "data/zf_match_report/ready.txt"
// After the end report: look once a second; inside this window the panel opens by itself.
#define ZMR_RECAP_OPEN_WINDOW_SEC 20
// Past the window the next attempt may already be running: no panel, only one chat notice.
#define ZMR_RECAP_LATE_WINDOW_SEC 120
#define ZMR_RECAP_LATE_INTERVAL_SEC 5

// Last finished match (unix seconds at its authoritative dump). 0 = none since plugin load.
// Not cleared by round resets: !recap must still work during the next attempt.
int g_iRecapMatchId;
Handle g_hRecapWatchTimer = null;
int g_iRecapWatchElapsed;

void ZMR_Recap_RegisterCommands()
{
	RegConsoleCmd("sm_recap", Cmd_Recap, "Open the recap page of the last finished match.");
	RegConsoleCmd("sm_zfrecap", Cmd_Recap, "Same as sm_recap (spare name).");
}

// Unique per server: two matches ending in the same second get consecutive numbers.
int ZMR_Recap_NewMatchId()
{
	int id = GetTime();
	if (id <= g_iRecapMatchId)
	{
		id = g_iRecapMatchId + 1;
	}

	g_iRecapMatchId = id;
	return id;
}

// Missing, empty or unreadable file = not ready (0).
int ZMR_Recap_ReadReadyId()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), ZMR_RECAP_READY_FILE);

	File file = OpenFile(path, "r");
	if (file == null)
	{
		return 0;
	}

	char line[32];
	bool ok = file.ReadLine(line, sizeof(line));
	delete file;

	if (!ok)
	{
		return 0;
	}

	// Tolerate a UTF-8 BOM left by the writer.
	int start = 0;
	if (line[0] == '\xEF' && line[1] == '\xBB' && line[2] == '\xBF')
	{
		start = 3;
	}

	TrimString(line[start]);

	if (line[start] == '\0')
	{
		return 0;
	}

	for (int i = start; line[i] != '\0'; i++)
	{
		if (!IsCharNumeric(line[i]))
		{
			return 0;
		}
	}

	return StringToInt(line[start]);
}

// zf_mr_report_url is the recap FOLDER. False if empty or if the full address would not fit
// the MOTD panel limit.
bool ZMR_Recap_BuildUrl(int matchId, char[] url, int urlLen)
{
	char base[ZMR_REPORT_URL_MAX];
	g_cvReportUrl.GetString(base, sizeof(base));
	TrimString(base);

	int len = strlen(base);
	if (len == 0)
	{
		return false;
	}

	char full[ZMR_REPORT_URL_MAX + 32];
	Format(full, sizeof(full), "%s%s%d.html", base, base[len - 1] == '/' ? "" : "/", matchId);

	if (strlen(full) >= ZMR_REPORT_URL_MAX)
	{
		return false;
	}

	strcopy(url, urlLen, full);
	return true;
}

bool ZMR_Recap_OpenForClient(int client, int matchId)
{
	if (!ZMR_IsHumanInGame(client))
	{
		return false;
	}

	char url[ZMR_REPORT_URL_MAX];
	if (!ZMR_Recap_BuildUrl(matchId, url, sizeof(url)))
	{
		return false;
	}

	char title[64];
	g_cvReportTitle.GetString(title, sizeof(title));
	TrimString(title);

	if (title[0] == '\0')
	{
		strcopy(title, sizeof(title), "Match Report");
	}

	ShowMOTDPanel(client, title, url, MOTDPANEL_TYPE_URL);

	if (g_cvDebugEvents.BoolValue)
	{
		LogMessage("[zf_mr] recap_motd client=%d url=%s", client, url);
	}

	return true;
}

void ZMR_Recap_OpenForHumanSurvivors(int matchId)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!ZMR_IsHumanInGame(client) || !ZMR_IsSurvivor(client))
		{
			continue;
		}

		ZMR_Recap_OpenForClient(client, matchId);
	}
}

// Each player reads it in their own language; unknown languages fall back to English.
void ZMR_Recap_ChatPhrase(int client, const char[] phrase)
{
	char text[160];
	Format(text, sizeof(text), "%T", phrase, client);
	PrintToChat(client, "\x03%s\x01 %s", ZMR_END_CHAT_TAG, text);
}

void ZMR_Recap_NotifyReadyAll()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!ZMR_IsHumanInGame(client))
		{
			continue;
		}

		ZMR_Recap_ChatPhrase(client, "ZMR_Recap_Ready");
	}
}

void ZMR_Recap_StopWatch()
{
	if (g_hRecapWatchTimer != null)
	{
		KillTimer(g_hRecapWatchTimer);
		g_hRecapWatchTimer = null;
	}
}

// Called once the chat/console end report is delivered. A newer match replaces the old watch.
void ZMR_Recap_StartWatch()
{
	ZMR_Recap_StopWatch();

	if (g_iRecapMatchId == 0)
	{
		return;
	}

	char url[ZMR_REPORT_URL_MAX];
	if (!ZMR_Recap_BuildUrl(g_iRecapMatchId, url, sizeof(url)))
	{
		// Empty ConVar = feature off, silently. Anything else is a misconfiguration.
		if (ZMR_ReportUrlConfigured())
		{
			LogMessage("[zf_mr] recap match=%d not watched: zf_mr_report_url + file name exceeds %d chars",
				g_iRecapMatchId, ZMR_REPORT_URL_MAX - 1);
		}

		return;
	}

	g_iRecapWatchElapsed = 0;
	// No TIMER_FLAG_NO_MAPCHANGE: the late notice is still useful after a map change.
	g_hRecapWatchTimer = CreateTimer(1.0, Timer_RecapWatch, g_iRecapMatchId, TIMER_REPEAT);
	LogMessage("[zf_mr] recap match=%d watching ready file", g_iRecapMatchId);
}

public Action Timer_RecapWatch(Handle timer, any matchId)
{
	// The match id is the unix time of the end dump: the delay counts from the end of the
	// match, and the open window starts only after it.
	if (GetTime() < matchId + g_cvReportOpenDelay.IntValue)
	{
		return Plugin_Continue;
	}

	g_iRecapWatchElapsed++;

	bool late = g_iRecapWatchElapsed > ZMR_RECAP_OPEN_WINDOW_SEC;
	bool lookNow = !late
		|| (g_iRecapWatchElapsed - ZMR_RECAP_OPEN_WINDOW_SEC) % ZMR_RECAP_LATE_INTERVAL_SEC == 0;

	if (lookNow && ZMR_Recap_ReadReadyId() == matchId)
	{
		bool open = !late && g_cvReportOpenOnRoundEnd.BoolValue;
		if (open)
		{
			ZMR_Recap_OpenForHumanSurvivors(matchId);
		}
		else
		{
			ZMR_Recap_NotifyReadyAll();
		}

		LogMessage("[zf_mr] recap match=%d ready after %ds — %s (%ds after the end, delay %ds)",
			matchId, g_iRecapWatchElapsed, open ? "panel opened" : "chat notice",
			GetTime() - matchId, g_cvReportOpenDelay.IntValue);
		g_hRecapWatchTimer = null;
		return Plugin_Stop;
	}

	if (g_iRecapWatchElapsed >= ZMR_RECAP_OPEN_WINDOW_SEC + ZMR_RECAP_LATE_WINDOW_SEC)
	{
		LogMessage("[zf_mr] recap match=%d not ready after %ds — stop watching",
			matchId, g_iRecapWatchElapsed);
		g_hRecapWatchTimer = null;
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

// Shared by sm_recap / sm_zfrecap (everyone) and sm_mr_report (admin).
public Action Cmd_Recap(int client, int args)
{
	if (client <= 0 || !ZMR_IsHumanInGame(client))
	{
		ReplyToCommand(client, "[zf_mr] recap: run from a connected human client.");
		return Plugin_Handled;
	}

	if (g_iRecapMatchId == 0
		|| ZMR_Recap_ReadReadyId() != g_iRecapMatchId
		|| !ZMR_Recap_OpenForClient(client, g_iRecapMatchId))
	{
		ZMR_Recap_ChatPhrase(client, "ZMR_Recap_NotReady");
	}

	return Plugin_Handled;
}

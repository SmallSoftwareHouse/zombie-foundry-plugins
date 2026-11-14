// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zombie Foundry
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. This program is distributed in the hope that it
// will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details: LICENSE
// file next to this source, or <https://www.gnu.org/licenses/>.

#if defined _zf_mr_endreport_included
#endinput
#endif
#define _zf_mr_endreport_included

#define ZMR_END_CHAT_TAG "[ZF]"
#define ZMR_END_CHAT_NAME_WIDTH 10
#define ZMR_END_CHAT_MAX_ROWS 8
#define ZMR_END_CHAT_LINE_MAX 220

enum struct ZMR_EndReportPlayerRow
{
	int client;
	int tankDmg;
	int siKills;
	int tankKills;
	int ffDealt;
}

void ZMR_FormatGroupedInt(int value, char[] dest, int destLen, bool dotThousands)
{
	if (value < 0)
	{
		value = -value;
	}

	char raw[16];
	IntToString(value, raw, sizeof(raw));
	int len = strlen(raw);
	if (len <= 3)
	{
		strcopy(dest, destLen, raw);
		return;
	}

	char sep[2];
	sep[0] = dotThousands ? '.' : ',';
	sep[1] = '\0';

	dest[0] = '\0';
	int group = (len - 1) % 3;
	int i = 0;
	while (i < len)
	{
		if (dest[0] != '\0')
		{
			StrCat(dest, destLen, sep);
		}

		int take = (i == 0) ? group + 1 : 3;
		char chunk[4];
		for (int c = 0; c < take; c++)
		{
			chunk[c] = raw[i + c];
		}

		chunk[take] = '\0';
		StrCat(dest, destLen, chunk);
		i += take;
	}
}

void ZMR_FormatCompactStatCount(int value, char[] dest, int destLen)
{
	if (value < 0)
	{
		value = 0;
	}

	if (value < 10000)
	{
		IntToString(value, dest, destLen);
		return;
	}

	int thousands = value / 1000;
	int tenths = (value % 1000) / 100;
	if (tenths <= 0)
	{
		Format(dest, destLen, "%dk", thousands);
	}
	else
	{
		Format(dest, destLen, "%d.%dk", thousands, tenths);
	}
}

bool ZMR_EndReport_UseDotThousands()
{
	char lang[8];
	GetLanguageInfo(GetServerLanguage(), lang, sizeof(lang));
	return StrEqual(lang, "it", false) || StrEqual(lang, "de", false)
		|| StrEqual(lang, "es", false) || StrEqual(lang, "fr", false);
}

int ZMR_EndReport_FfTaken(int client)
{
	int total = 0;

	for (int s = 1; s <= MaxClients; s++)
	{
		if (s == client || !IsClientInGame(s) || !ZMR_IsSurvivor(s))
		{
			continue;
		}

		total += g_RoundStats[client].damageTakenFromSurvivor[s];
	}

	return total;
}

void ZMR_EndReport_GatherPlayers(ZMR_EndReportPlayerRow[] rows, int &rowCount)
{
	rowCount = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client) || !ZMR_PlayerHasStats(client))
		{
			continue;
		}

		rows[rowCount].client = client;
		rows[rowCount].tankDmg = g_RoundStats[client].tankDamageEffective;
		rows[rowCount].siKills = g_RoundStats[client].siKills;
		rows[rowCount].tankKills = g_RoundStats[client].tankKills;
		rows[rowCount].ffDealt = g_RoundStats[client].damageDealtFF;
		rowCount++;
	}
}

void ZMR_EndReport_SortClientsByTankDmg(int[] clients, int clientCount)
{
	for (int i = 0; i < clientCount - 1; i++)
	{
		for (int j = i + 1; j < clientCount; j++)
		{
			int dmgI = g_RoundStats[clients[i]].tankDamageEffective;
			int dmgJ = g_RoundStats[clients[j]].tankDamageEffective;

			if (dmgJ > dmgI || (dmgJ == dmgI && clients[j] < clients[i]))
			{
				int tmp = clients[i];
				clients[i] = clients[j];
				clients[j] = tmp;
			}
		}
	}
}

void ZMR_EndReport_FormatChatName(int client, char[] dest, int destLen)
{
	char raw[MAX_NAME_LENGTH];
	char cut[ZMR_END_CHAT_NAME_WIDTH + 4];
	GetClientName(client, raw, sizeof(raw));
	ZMR_TruncateNameForChat(raw, cut, sizeof(cut), ZMR_END_CHAT_NAME_WIDTH);
	ZMR_PadStringRight(cut, dest, destLen, ZMR_END_CHAT_NAME_WIDTH);
}

void ZMR_EndReport_TeamHeaderTotals(int &siKills, int &commonsKills, int &tankKills)
{
	siKills = 0;
	commonsKills = 0;
	tankKills = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client))
		{
			continue;
		}

		siKills += g_RoundStats[client].siKills;
		commonsKills += g_RoundStats[client].commonKills;
		tankKills += g_RoundStats[client].tankKills;
	}
}

bool ZMR_EndReport_ClientPrefersItalian(int client)
{
	char code[8];
	int lang = GetClientLanguage(client);
	if (lang < 0)
	{
		lang = GetServerLanguage();
	}

	GetLanguageInfo(lang, code, sizeof(code));
	return StrEqual(code, "it", false);
}

void ZMR_EndReport_PrintChatToRecipient(int recipient, int stamp)
{
	if (recipient <= 0 || !ZMR_IsHumanInGame(recipient))
	{
		return;
	}

	int teamSiKills;
	int teamCommons;
	int teamTankKills;
	ZMR_EndReport_TeamHeaderTotals(teamSiKills, teamCommons, teamTankKills);

	char title[96];
	char statsLine[128];
	char tBuf[12];
	char siBuf[12];
	char cBuf[12];
	ZMR_FormatCompactStatCount(teamTankKills, tBuf, sizeof(tBuf));
	ZMR_FormatCompactStatCount(teamSiKills, siBuf, sizeof(siBuf));
	ZMR_FormatCompactStatCount(teamCommons, cBuf, sizeof(cBuf));

	if (ZMR_EndReport_ClientPrefersItalian(recipient))
	{
		Format(title, sizeof(title), "Report partita [#%d] BETA", stamp);
	}
	else
	{
		Format(title, sizeof(title), "Match report [#%d] BETA", stamp);
	}

	Format(statsLine, sizeof(statsLine), "Tank %s \xC2\xB7 Special infected %s \xC2\xB7 Common %s",
		tBuf, siBuf, cBuf);
	Format(title, sizeof(title), "\x03%s %s\x01", ZMR_END_CHAT_TAG, title);
	Format(statsLine, sizeof(statsLine), "\x03%s %s\x01", ZMR_END_CHAT_TAG, statsLine);
	PrintToChat(recipient, "%s", title);
	PrintToChat(recipient, "%s", statsLine);

	ZMR_EndReportPlayerRow rows[MAXPLAYERS];
	int rowCount = 0;
	ZMR_EndReport_GatherPlayers(rows, rowCount);

	bool many = rowCount > ZMR_END_CHAT_MAX_ROWS;
	int show = many ? ZMR_END_CHAT_MAX_ROWS : rowCount;
	bool dot = ZMR_EndReport_UseDotThousands();

	int order[MAXPLAYERS];
	int orderCount = 0;

	if (many)
	{
		int allClients[MAXPLAYERS];
		int allCount = 0;

		for (int r = 0; r < rowCount; r++)
		{
			allClients[allCount++] = rows[r].client;
		}

		ZMR_EndReport_SortClientsByTankDmg(allClients, allCount);

		for (int i = 0; i < show; i++)
		{
			order[i] = allClients[i];
		}

		orderCount = show;
	}
	else
	{
		for (int c = 1; c <= MaxClients; c++)
		{
			if (!IsClientInGame(c) || !ZMR_IsSurvivor(c) || !ZMR_PlayerHasStats(c))
			{
				continue;
			}

			order[orderCount++] = c;
		}
	}

	for (int i = 0; i < orderCount; i++)
	{
		int client = order[i];
		char nameCol[96];
		ZMR_EndReport_FormatChatName(client, nameCol, sizeof(nameCol));

		int siKills = g_RoundStats[client].siKills;
		int tankKills = g_RoundStats[client].tankKills;
		int ffDealt = g_RoundStats[client].damageDealtFF;
		int tankDmg = g_RoundStats[client].tankDamageEffective;

		char tankBuf[16];
		ZMR_FormatGroupedInt(tankDmg, tankBuf, sizeof(tankBuf), dot);

		char rowText[160];
		Format(rowText, sizeof(rowText), "%T", "ZMR_End_Chat_Row", LANG_SERVER,
			nameCol, siKills, tankBuf, tankKills, ffDealt);

		if (client == recipient)
		{
			Format(rowText, sizeof(rowText), "\x05%s %s\x01", ZMR_END_CHAT_TAG, rowText);
		}
		else
		{
			Format(rowText, sizeof(rowText), "\x01%s %s", ZMR_END_CHAT_TAG, rowText);
		}

		PrintToChat(recipient, "%s", rowText);
	}

	if (many)
	{
		char more[96];
		Format(more, sizeof(more), "%T", "ZMR_End_Chat_Others", LANG_SERVER, rowCount - show);
		Format(more, sizeof(more), "\x01%s %s", ZMR_END_CHAT_TAG, more);
		PrintToChat(recipient, "%s", more);
	}

	char full[64];
	if (ZMR_EndReport_ClientPrefersItalian(recipient))
	{
		strcopy(full, sizeof(full), "Report completo in console");
	}
	else
	{
		strcopy(full, sizeof(full), "Full report in console");
	}

	char hint[160];
	Format(hint, sizeof(hint), "\x03%s \x04End report\x01 · %s", ZMR_END_CHAT_TAG, full);
	PrintToChat(recipient, "%s", hint);
}

void ZMR_EndReport_TankTeamBreakdown(char[] survLine, int survLen, char[] firePct, int fireLen, char[] envPct, int envLen)
{
	survLine[0] = '\0';
	int totalSurvEff = 0;
	// Prefer live instance buckets (closed slots kept until round reset). Round totals are a
	// floor in case a slot was recycled early.
	int instFire = 0;
	int instEnv = 0;

	for (int i = 0; i < g_iTankInstanceCount; i++)
	{
		if (g_TankInstances[i].spawnSeq == 0)
		{
			continue;
		}

		instFire += g_TankInstances[i].damageFireEffective;
		instEnv += g_TankInstances[i].damageEnvEffective;
	}

	int totalFire = instFire;
	int totalEnv = instEnv;
	if (g_iRoundTankFireEffective > totalFire)
	{
		totalFire = g_iRoundTankFireEffective;
	}

	if (g_iRoundTankEnvEffective > totalEnv)
	{
		totalEnv = g_iRoundTankEnvEffective;
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!ZMR_IsSurvivor(client))
		{
			continue;
		}

		totalSurvEff += g_RoundStats[client].tankDamageEffective;
	}

	int grand = totalSurvEff + totalFire + totalEnv;
	if (grand <= 0)
	{
		grand = totalSurvEff;
	}

	LogMessage("[zf_mr] end_report tank_pct surv=%d fire=%d (inst=%d round=%d) env=%d (inst=%d round=%d) grand=%d",
		totalSurvEff,
		totalFire, instFire, g_iRoundTankFireEffective,
		totalEnv, instEnv, g_iRoundTankEnvEffective,
		grand);

	int clients[MAXPLAYERS];
	int clientCount = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!ZMR_IsSurvivor(client))
		{
			continue;
		}

		clients[clientCount++] = client;
	}

	ZMR_EndReport_SortClientsByTankDmg(clients, clientCount);

	if (clientCount <= 0 && totalSurvEff <= 0)
	{
		strcopy(survLine, survLen, "—");
		Format(firePct, fireLen, "0%%");
		Format(envPct, envLen, "0%%");
		return;
	}

	int denom = grand > 0 ? grand : totalSurvEff;

	for (int i = 0; i < clientCount; i++)
	{
		int client = clients[i];

		char raw[MAX_NAME_LENGTH];
		char safe[32];
		GetClientName(client, raw, sizeof(raw));
		ZMR_SanitizeNameForLog(raw, safe, sizeof(safe));

		int pct10 = ZMR_EffectiveToPctTenths(g_RoundStats[client].tankDamageEffective, denom);
		char pctBuf[12];
		ZMR_FormatPctTenths(pct10, pctBuf, sizeof(pctBuf));

		char part[48];
		Format(part, sizeof(part), "%s%s %s",
			survLine[0] == '\0' ? "" : " · ", safe, pctBuf);
		StrCat(survLine, survLen, part);
	}

	int fire10 = ZMR_EffectiveToPctTenths(totalFire, denom);
	int env10 = ZMR_EffectiveToPctTenths(totalEnv, denom);
	ZMR_FormatPctTenths(fire10, firePct, fireLen);
	ZMR_FormatPctTenths(env10, envPct, envLen);
}

#define ZMR_END_CON_WIDTH 101
#define ZMR_COL_NAME 14
#define ZMR_COL_DMG_SI 10
#define ZMR_COL_KILL_SI 10
#define ZMR_COL_KILL_TK 10
#define ZMR_COL_DMG_TK 12
#define ZMR_COL_COMMON 10
#define ZMR_COL_HS 11
#define ZMR_COL_FF 8

void ZMR_EndReport_RepeatChar(char[] dest, int destLen, int ch, int count)
{
	int n = count;
	if (n >= destLen)
	{
		n = destLen - 1;
	}

	for (int i = 0; i < n; i++)
	{
		dest[i] = ch;
	}

	dest[n] = '\0';
}

void ZMR_EndReport_CenterLine(const char[] text, char[] dest, int destLen, int width)
{
	int len = strlen(text);
	int left = 0;
	if (len < width)
	{
		left = (width - len) / 2;
	}

	dest[0] = '\0';
	for (int i = 0; i < left && strlen(dest) + 1 < destLen; i++)
	{
		StrCat(dest, destLen, " ");
	}

	StrCat(dest, destLen, text);

	int cur = strlen(dest);
	while (cur < width && cur + 1 < destLen)
	{
		dest[cur++] = ' ';
	}

	dest[cur] = '\0';
}

void ZMR_EndReport_Cell(const char[] src, char[] dest, int destLen, int width, bool leftAlign)
{
	char clipped[48];
	strcopy(clipped, sizeof(clipped), src);
	if (strlen(clipped) > width)
	{
		clipped[width] = '\0';
	}

	int nlen = strlen(clipped);
	int pad = width - nlen;
	dest[0] = '\0';

	if (!leftAlign)
	{
		for (int i = 0; i < pad && strlen(dest) + 1 < destLen; i++)
		{
			StrCat(dest, destLen, " ");
		}
	}

	StrCat(dest, destLen, clipped);

	if (leftAlign)
	{
		int cur = strlen(dest);
		while (cur < width && cur + 1 < destLen)
		{
			dest[cur++] = ' ';
		}

		dest[cur] = '\0';
	}
}

void ZMR_EndReport_ConsoleRow(const char[] name, const char[] dmgSi, const char[] killSi,
	const char[] killTk, const char[] dmgTank, const char[] common, const char[] headshot,
	const char[] ffPlus, const char[] ffMinus, char[] dest, int destLen)
{
	char c0[16];
	char c1[16];
	char c2[16];
	char c3[16];
	char c4[16];
	char c5[16];
	char c6[16];
	char c7[12];
	char c8[12];

	ZMR_EndReport_Cell(name, c0, sizeof(c0), ZMR_COL_NAME, true);
	ZMR_EndReport_Cell(dmgSi, c1, sizeof(c1), ZMR_COL_DMG_SI, false);
	ZMR_EndReport_Cell(killSi, c2, sizeof(c2), ZMR_COL_KILL_SI, false);
	ZMR_EndReport_Cell(killTk, c3, sizeof(c3), ZMR_COL_KILL_TK, false);
	ZMR_EndReport_Cell(dmgTank, c4, sizeof(c4), ZMR_COL_DMG_TK, false);
	ZMR_EndReport_Cell(common, c5, sizeof(c5), ZMR_COL_COMMON, false);
	ZMR_EndReport_Cell(headshot, c6, sizeof(c6), ZMR_COL_HS, false);
	ZMR_EndReport_Cell(ffPlus, c7, sizeof(c7), ZMR_COL_FF, false);
	ZMR_EndReport_Cell(ffMinus, c8, sizeof(c8), ZMR_COL_FF, false);

	Format(dest, destLen, "%s %s %s %s %s %s %s %s %s",
		c0, c1, c2, c3, c4, c5, c6, c7, c8);
}

void ZMR_EndReport_GroupedCell(int value, char[] dest, int destLen, int width, bool dot)
{
	char raw[24];
	ZMR_FormatGroupedInt(value, raw, sizeof(raw), dot);
	ZMR_EndReport_Cell(raw, dest, destLen, width, false);
}

void ZMR_EndReport_PrintConsoleToRecipient(int recipient, int stamp)
{
	if (recipient <= 0 || !ZMR_IsHumanInGame(recipient))
	{
		return;
	}

	bool dot = ZMR_EndReport_UseDotThousands();

	char bar[ZMR_END_CON_WIDTH + 4];
	char dash[ZMR_END_CON_WIDTH + 4];
	char line[256];
	char title[96];
	ZMR_EndReport_RepeatChar(bar, sizeof(bar), '=', ZMR_END_CON_WIDTH);
	ZMR_EndReport_RepeatChar(dash, sizeof(dash), '-', ZMR_END_CON_WIDTH);

	PrintToConsole(recipient, "%s", bar);
	Format(title, sizeof(title), "ZOMBIE FOUNDRY  MATCH REPORT #%d  BETA", stamp);
	ZMR_EndReport_CenterLine(title, line, sizeof(line), ZMR_END_CON_WIDTH);
	PrintToConsole(recipient, "%s", line);
	PrintToConsole(recipient, "%s", bar);

	char mode[32];
	ZMR_GetGameModeSnippet(mode, sizeof(mode));
	if (mode[0] >= 'a' && mode[0] <= 'z')
	{
		mode[0] = mode[0] - 32;
	}

	Format(title, sizeof(title), "%s   plugin %s", mode, PLUGIN_VERSION);
	ZMR_EndReport_CenterLine(title, line, sizeof(line), ZMR_END_CON_WIDTH);
	PrintToConsole(recipient, "%s", line);
	PrintToConsole(recipient, "%s", dash);

	ZMR_EndReport_ConsoleRow("Name", "Dmg SI", "Kill SI", "Kill Tk", "Dmg Tank",
		"Common", "Headshot", "FF+", "FF-", line, sizeof(line));
	PrintToConsole(recipient, "%s", line);
	PrintToConsole(recipient, "%s", dash);

	int totSi;
	int totKsi;
	int totKt;
	int totTankDmg;
	int totCom;
	int totHs;
	int totFfPlus;
	int totFfMinus;
	totSi = totKsi = totKt = totTankDmg = totCom = totHs = totFfPlus = totFfMinus = 0;

	char nSi[16];
	char nKsi[16];
	char nKt[16];
	char nTank[16];
	char nCom[16];
	char nHs[16];
	char nFfP[12];
	char nFfM[12];

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client) || !ZMR_PlayerHasStats(client))
		{
			continue;
		}

		char raw[MAX_NAME_LENGTH];
		char cut[16];
		char nameCol[20];
		GetClientName(client, raw, sizeof(raw));

		if (client == recipient)
		{
			ZMR_TruncateNameForChat(raw, cut, sizeof(cut), 12);
			Format(nameCol, sizeof(nameCol), "> %s", cut);
		}
		else
		{
			ZMR_TruncateNameForChat(raw, cut, sizeof(cut), ZMR_COL_NAME);
			strcopy(nameCol, sizeof(nameCol), cut);
		}

		int ffMinus = ZMR_EndReport_FfTaken(client);
		int hs = g_RoundStats[client].commonHeadshotKills;
		int tankDmg = g_RoundStats[client].tankDamageEffective;

		ZMR_EndReport_GroupedCell(g_RoundStats[client].damageDealtInfected, nSi, sizeof(nSi), ZMR_COL_DMG_SI, dot);
		ZMR_EndReport_GroupedCell(g_RoundStats[client].siKills, nKsi, sizeof(nKsi), ZMR_COL_KILL_SI, dot);
		ZMR_EndReport_GroupedCell(g_RoundStats[client].tankKills, nKt, sizeof(nKt), ZMR_COL_KILL_TK, dot);
		ZMR_EndReport_GroupedCell(tankDmg, nTank, sizeof(nTank), ZMR_COL_DMG_TK, dot);
		ZMR_EndReport_GroupedCell(g_RoundStats[client].commonKills, nCom, sizeof(nCom), ZMR_COL_COMMON, dot);
		ZMR_EndReport_GroupedCell(hs, nHs, sizeof(nHs), ZMR_COL_HS, dot);
		ZMR_EndReport_GroupedCell(g_RoundStats[client].damageDealtFF, nFfP, sizeof(nFfP), ZMR_COL_FF, dot);
		ZMR_EndReport_GroupedCell(ffMinus, nFfM, sizeof(nFfM), ZMR_COL_FF, dot);

		ZMR_EndReport_ConsoleRow(nameCol, nSi, nKsi, nKt, nTank, nCom, nHs, nFfP, nFfM, line, sizeof(line));
		PrintToConsole(recipient, "%s", line);

		totSi += g_RoundStats[client].damageDealtInfected;
		totKsi += g_RoundStats[client].siKills;
		totKt += g_RoundStats[client].tankKills;
		totTankDmg += tankDmg;
		totCom += g_RoundStats[client].commonKills;
		totHs += hs;
		totFfPlus += g_RoundStats[client].damageDealtFF;
		totFfMinus += ffMinus;
	}

	ZMR_EndReport_GroupedCell(totSi, nSi, sizeof(nSi), ZMR_COL_DMG_SI, dot);
	ZMR_EndReport_GroupedCell(totKsi, nKsi, sizeof(nKsi), ZMR_COL_KILL_SI, dot);
	ZMR_EndReport_GroupedCell(totKt, nKt, sizeof(nKt), ZMR_COL_KILL_TK, dot);
	ZMR_EndReport_GroupedCell(totTankDmg, nTank, sizeof(nTank), ZMR_COL_DMG_TK, dot);
	ZMR_EndReport_GroupedCell(totCom, nCom, sizeof(nCom), ZMR_COL_COMMON, dot);
	ZMR_EndReport_GroupedCell(totHs, nHs, sizeof(nHs), ZMR_COL_HS, dot);
	ZMR_EndReport_GroupedCell(totFfPlus, nFfP, sizeof(nFfP), ZMR_COL_FF, dot);
	ZMR_EndReport_GroupedCell(totFfMinus, nFfM, sizeof(nFfM), ZMR_COL_FF, dot);
	ZMR_EndReport_ConsoleRow("TOTAL", nSi, nKsi, nKt, nTank, nCom, nHs, nFfP, nFfM, line, sizeof(line));
	PrintToConsole(recipient, "%s", dash);
	PrintToConsole(recipient, "%s", line);
	PrintToConsole(recipient, "%s", dash);

	int pills;
	int adren;
	int medkits;
	int incap;
	int deaths;
	int grabH;
	int grabJ;
	int grabB;
	int grabS;
	int grabC;
	int shoves;
	int skeet;
	int deadstop;
	int freed;
	pills = adren = medkits = incap = deaths = 0;
	grabH = grabJ = grabB = grabS = grabC = 0;
	shoves = skeet = deadstop = freed = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !ZMR_IsSurvivor(client))
		{
			continue;
		}

		pills += g_RoundStats[client].pillsUsed;
		adren += g_RoundStats[client].adrenalineUsed;
		medkits += g_RoundStats[client].medkitSelf + g_RoundStats[client].medkitOther;
		incap += g_RoundStats[client].incapCount;
		deaths += g_RoundStats[client].deathCount;
		grabH += g_RoundStats[client].grabHunter;
		grabJ += g_RoundStats[client].grabJockey;
		grabB += g_RoundStats[client].grabBoomer;
		grabS += g_RoundStats[client].grabSmoker;
		grabC += g_RoundStats[client].grabCharger;
		shoves += g_RoundStats[client].defenseShoves;
		skeet += g_RoundStats[client].defenseSkeet;
		deadstop += g_RoundStats[client].defenseDeadstop;
		freed += g_RoundStats[client].defenseFreed;
	}

	PrintToConsole(recipient, "SUPPORT");
	PrintToConsole(recipient, "%s", dash);

	// First label is one phrase ("Cure pills"), not two columns. Later fields share a column.
	Format(line, sizeof(line), "%-15s %2d   %-11s %2d   %-11s %2d   %-11s %2d   %-11s %2d",
		"Cure pills", pills, "adrenaline", adren, "medkits", medkits, "downed", incap, "deaths", deaths);
	PrintToConsole(recipient, "%s", line);

	Format(line, sizeof(line), "%-15s %2d   %-11s %2d   %-11s %2d   %-11s %2d   %-11s %2d",
		"Grabs Hunter", grabH, "Jockey", grabJ, "Boomer", grabB, "Smoker", grabS, "Charger", grabC);
	PrintToConsole(recipient, "%s", line);

	Format(line, sizeof(line), "%-15s %2d   %-11s %2d   %-11s %2d   %-11s %2d",
		"Defense shoves", shoves, "skeet", skeet, "deadstop", deadstop, "freed", freed);
	PrintToConsole(recipient, "%s", line);
	PrintToConsole(recipient, "%s", dash);

	char survPct[256];
	char firePct[16];
	char envPct[16];
	ZMR_EndReport_TankTeamBreakdown(survPct, sizeof(survPct), firePct, sizeof(firePct), envPct, sizeof(envPct));

	Format(line, sizeof(line), "Tank %%    %s     fire %s    world %s", survPct, firePct, envPct);
	PrintToConsole(recipient, "%s", line);

	PrintToConsole(recipient, "%s", bar);
	Format(title, sizeof(title), "END REPORT #%d", stamp);
	ZMR_EndReport_CenterLine(title, line, sizeof(line), ZMR_END_CON_WIDTH);
	PrintToConsole(recipient, "%s", line);
	PrintToConsole(recipient, "%s", bar);
}

void ZMR_EndReport_BroadcastChat(int stamp)
{
	bool any = false;

	for (int c = 1; c <= MaxClients; c++)
	{
		if (IsClientInGame(c) && ZMR_IsSurvivor(c) && ZMR_PlayerHasStats(c))
		{
			any = true;
			break;
		}
	}

	if (!any)
	{
		LogMessage("[zf_mr] end_report stamp=%d chat skipped (no survivor stats in memory)", stamp);
		return;
	}

	if (g_cvReportChat == null || !g_cvReportChat.BoolValue)
	{
		return;
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!ZMR_IsHumanInGame(client))
		{
			continue;
		}

		ZMR_EndReport_PrintChatToRecipient(client, stamp);
	}
}

void ZMR_EndReport_BroadcastConsole(int stamp)
{
	bool any = false;

	for (int c = 1; c <= MaxClients; c++)
	{
		if (IsClientInGame(c) && ZMR_IsSurvivor(c) && ZMR_PlayerHasStats(c))
		{
			any = true;
			break;
		}
	}

	if (!any)
	{
		LogMessage("[zf_mr] end_report stamp=%d console skipped (no survivor stats in memory)", stamp);
		return;
	}

	if (g_cvReportConsole == null || !g_cvReportConsole.BoolValue)
	{
		return;
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!ZMR_IsHumanInGame(client))
		{
			continue;
		}

		ZMR_EndReport_PrintConsoleToRecipient(client, stamp);
	}
}

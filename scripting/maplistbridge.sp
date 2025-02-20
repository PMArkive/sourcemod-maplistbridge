#include <sourcemod>

#include <feedback2> // https://github.com/TF2Maps/sourcemod-feedbackround
#include <discord> // https://forums.alliedmods.net/showthread.php?t=292663

#pragma semicolon 1
#pragma newdecls required

#define DATABASE_NAME "maplist"
#define QUERY_GET_MAP_DATA "SELECT discord_user_id, url, notes FROM maps WHERE map='%s' AND status='pending' LIMIT 1"
#define QUERY_SET_MAP_PLAYED  "UPDATE maps SET status='played', played=now() WHERE map='%s' AND status='pending'"

#define WEBHOOK_NAME "maplistbridge"
#define WEBHOOK_DATA "{\"username\": \"Mecha Engineer\", \"content\": \"<@%s> %s is currently being played on https://bot.tf2maps.net/%s with %d players.\"}"

public Plugin myinfo = {
	name = "Map List Bridge",
	author = "Mr. Burguers",
	description = "Operations related to the map list",
	version = "1.5",
	url = "https://tf2maps.net/home/"
};

Database g_hConn;

ConVar g_hCVarServerIP;
ConVar g_hCVarMinPlayers;

ConVar g_hTVEnabled;

char g_sMapName[64];
char g_sDiscordID[64];
char g_sMapURL[236];
bool g_bHasNotes;
char g_sMapNotes[250];

bool g_bDataLoaded;
bool g_bMapRemoved;

public void OnPluginStart() {
	g_hCVarServerIP = CreateConVar("maplistbridge_ip", "unknown", "Server redirection page on the bot URL.", 0);
	g_hCVarMinPlayers = CreateConVar("maplistbridge_players", "4", "Minimum players to consider the map as played.", 0, true, 1.0, true, 32.0);

	g_hTVEnabled = FindConVar("tv_enable");

	RegConsoleCmd("sm_notes", CommandNotes, "Show this map's bot notes");

	HookEvent("teamplay_round_start", OnRoundStart, EventHookMode_PostNoCopy);
	HookEvent("player_team", CheckMap, EventHookMode_PostNoCopy);

	ConnectToDatabase();
}

public void OnPluginEnd() {
	UnhookEvent("teamplay_round_start", OnRoundStart, EventHookMode_PostNoCopy);
	UnhookEvent("player_team", CheckMap, EventHookMode_PostNoCopy);

	DisconnectFromDatabase();
}

public void OnMapStart() {
	g_bDataLoaded = false;
	g_bMapRemoved = false;
	GetCurrentMap(g_sMapName, sizeof(g_sMapName));
	if (g_hConn != null || ConnectToDatabase()) {
		RetrieveMapData();
	}
}

void RetrieveMapData() {
	char sQuery[1024];
	g_hConn.Format(sQuery, sizeof(sQuery), QUERY_GET_MAP_DATA, g_sMapName);
	g_hConn.Query(OnMapDataRetrieved, sQuery);
}

void OnMapDataRetrieved(Database db, DBResultSet results, const char[] error, any data) {
	if (results == null) {
		LogError("MapListBridge SQL error - %s", error);
		return;
	}
	if (!results.FetchRow()) {
		// Map is not in the list
		return;
	}

	results.FetchString(0, g_sDiscordID, sizeof(g_sDiscordID));
	results.FetchString(1, g_sMapURL, sizeof(g_sMapURL));
	g_bHasNotes = false;
	if (!results.IsFieldNull(2)) {
		int iCopied = results.FetchString(2, g_sMapNotes, sizeof(g_sMapNotes));
		if (iCopied > 0) {
			g_bHasNotes = true;
			PutEllipsis(g_sMapNotes, sizeof(g_sMapNotes), iCopied);
		}
	}

	g_bDataLoaded = true;
}

Action CommandNotes(int client, int args) {
	if (client) {
		if (!g_bDataLoaded) {
			PrintToChat(client, "\x04No map notes\x01, this map is not in the map list.");
		} else if (!g_bHasNotes) {
			PrintToChat(client, "\x04No map notes\x01 were provided for this map.");
		} else {
			PrintToChat(client, "\x01------- \x04Map Notes \x01-------");
			PrintToChat(client, "%s", g_sMapNotes);
			PrintToChat(client, "-------------------------");
		}
	}

	return Plugin_Handled;
}

void OnRoundStart(Event event, const char[] name, bool dontBroadcast) {
	// In case the feedback round plugin hooks the event after this plugin does
	// Wait a frame so it consistently sets FB2_IsFbRoundActive
	RequestFrame(SendNotes);
}

void SendNotes() {
	if (!g_bDataLoaded) {
		return;
	}

	PrintToChatAll("\x04Map Thread\x01: %s", g_sMapURL);

	if (g_bHasNotes) {
		// Feedback round has its own chat and center text notifications
		// Don't show notes in chat, only center text and only after a delay
		if (FB2_IsFbRoundActive()) {
			CreateTimer(11.0, SendCenterNotes, _, TIMER_FLAG_NO_MAPCHANGE);
			return;
		}

		PrintToChatAll("\x01------- \x04Map Notes \x01-------");
		PrintToChatAll("%s", g_sMapNotes);
		PrintToChatAll("-------------------------");

		// Delay to prevent player respawns sometimes clearing this text
		CreateTimer(0.2, SendCenterNotes, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

void SendCenterNotes(Handle timer) {
	char sCenterMapNotes[219];
	int iCopied = strcopy(sCenterMapNotes, sizeof(sCenterMapNotes), g_sMapNotes);
	PutEllipsis(sCenterMapNotes, sizeof(sCenterMapNotes), iCopied);

	// Add line breaks after periods or in long lines
	int i = 0;
	char c;
	bool bWasDot = false;
	int iLineSize = 0;
	for (; c = sCenterMapNotes[i]; ++i, ++iLineSize) {
		if (c == '.') {
			bWasDot = true;
		} else {
			if (c == ' ' && (bWasDot || iLineSize >= 50)) {
				sCenterMapNotes[i] = '\n';
				iLineSize = 0;
			}
			bWasDot = false;
		}
	}

	// Center position, 10 seconds, white color, no fade
	SetHudTextParams(-1.0, -1.0, 10.0, 255, 255, 255, 255, 0, _, 0.0, 0.0);
	for (int client = 1; client <= MaxClients; client++) {
		if (IsClientInGame(client)) {
			ShowHudText(client, -1, "%s", sCenterMapNotes);
		}
	}
}

void CheckMap(Event event, const char[] name, bool dontBroadcast) {
	if (!g_bDataLoaded || g_bMapRemoved) {
		return;
	}

	int iConnectedPlayers = GetConnectedPlayers();
	int iPlayersNeeded = g_hCVarMinPlayers.IntValue;
	if (iConnectedPlayers >= iPlayersNeeded) {
		g_bMapRemoved = true;

		// Make snapshot of data to prevent map change race condition
		DataPack hData = new DataPack();
		hData.WriteString(g_sMapName);
		hData.WriteString(g_sDiscordID);
		hData.WriteCell(iConnectedPlayers);
		hData.Reset();

		char sQuery[1024];
		g_hConn.Format(sQuery, sizeof(sQuery), QUERY_SET_MAP_PLAYED, g_sMapName);
		g_hConn.Query(OnMapRemovedFromQueue, sQuery, hData);
	}
}

void OnMapRemovedFromQueue(Database db, DBResultSet results, const char[] error, DataPack data) {
	if (results == null) {
		LogError("MapListBridge SQL error - %s", error);
		g_bMapRemoved = false;
		delete data;
		return;
	}

	SendDiscordMessage(data);
}

void SendDiscordMessage(DataPack data) {
	char sServerIP[64];
	g_hCVarServerIP.GetString(sServerIP, sizeof(sServerIP));

	char sMapName[64];
	data.ReadString(sMapName, sizeof(sMapName));
	char sDiscordID[64];
	data.ReadString(sDiscordID, sizeof(sDiscordID));
	int iConnectedPlayers = data.ReadCell();
	delete data;

	char sBody[1024];
	Format(sBody, sizeof(sBody), WEBHOOK_DATA, sDiscordID, sMapName, sServerIP, iConnectedPlayers);

	Discord_SendMessage(WEBHOOK_NAME, sBody);
}

// ---------- Utility functions ---------- //

void PutEllipsis(char[] sBuffer, int iBufferSize, int iLength) {
	if (iLength == iBufferSize - 1) {
		strcopy(sBuffer[iBufferSize - 6], 6, "(...)");
	}
}

int GetConnectedPlayers() {
	int iPlayerCount = GetClientCount(false); // Do count connecting clients
	if (g_hTVEnabled.BoolValue) {
		iPlayerCount--;
	}

	return iPlayerCount;
}

bool ConnectToDatabase() {
	char sError[256];
	g_hConn = SQL_Connect(DATABASE_NAME, true, sError, sizeof(sError));

	if (g_hConn == null) {
		LogError("Failed to connect - %s", sError);
		return false;
	} else {
		LogMessage("Connected to database");
		return true;
	}
}

void DisconnectFromDatabase() {
	delete g_hConn;
}

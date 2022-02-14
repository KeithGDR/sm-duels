/*****************************/
//Pragma
#pragma semicolon 1
#pragma newdecls required

/*****************************/
//Defines
#define PLUGIN_NAME "[SM] Duels"
#define PLUGIN_DESCRIPTION "An open source dueling system for Source Engine games."
#define PLUGIN_VERSION "1.0.0"

#define NO_ARENA -1

#define CHALLENGER 0
#define OPPONENT 1

#define STATE_NONE 0
#define STATE_STARTING 1
#define STATE_ROUND_ACTIVE 2
#define STATE_ROUND_ENDING 3
#define STATE_ROUND_STARTING 4

/*****************************/
//Includes
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>

/*****************************/
//ConVars

ConVar convar_Default_Score;

/*****************************/
//Globals

char g_CurrentMap[64];

enum struct Arena
{
	//config
	char name[MAX_NAME_LENGTH];

	float origin1[3];
	float origin2[3];

	float angles1[3];
	float angles2[3];

	//cache
	int index;

	int players[2];
	int scores[2];
	
	int state;
	int ticks;
	Handle timer;

	void Add(int index, const char[] name, float origin1[3], float origin2[3], float angles1[3], float angles2[3])
	{
		this.index = index;
		strcopy(this.name, MAX_NAME_LENGTH, name);

		for (int i = 0; i < 3; i++)
		{
			this.origin1[i] = origin1[i];
			this.origin2[i] = origin2[i];
			this.angles1[i] = angles1[i];
			this.angles2[i] = angles2[i];
		}
	}

	void Reset()
	{
		for (int i = 0; i < 2; i++)
		{
			this.players[i] = 0;
			this.scores[i] = 0;
		}

		this.state = STATE_NONE;
		this.ticks = 0;
		StopTimer(this.timer);
	}

	void Clear()
	{
		this.index = 0;
		this.name[0] = '\0';
		
		for (int i = 0; i < 3; i++)
		{
			this.origin1[i] = 0.0;
			this.origin2[i] = 0.0;
			this.angles1[i] = 0.0;
			this.angles2[i] = 0.0;
		}
	}

	void RespawnPlayers()
	{
		if (!IsPlayerAlive(this.players[CHALLENGER]))
			CS_RespawnPlayer(this.players[CHALLENGER]);
		
		if (!IsPlayerAlive(this.players[OPPONENT]))
			CS_RespawnPlayer(this.players[OPPONENT]);
	}

	void SpawnPlayers()
	{
		float origin[3]; float angles[3];

		for (int i = 0; i < 3; i++)
		{
			origin[i] = this.origin1[i];
			angles[i] = this.angles1[i];
		}
		
		TeleportEntity(this.players[CHALLENGER], origin, angles, view_as<float>({0.0, 0.0, 0.0}));

		for (int i = 0; i < 3; i++)
		{
			origin[i] = this.origin2[i];
			angles[i] = this.angles2[i];
		}

		TeleportEntity(this.players[OPPONENT], origin, angles, view_as<float>({0.0, 0.0, 0.0}));
	}

	void FreezePlayers(bool status)
	{
		SetEntityMoveType(this.players[CHALLENGER], status ? MOVETYPE_NONE : MOVETYPE_WALK);
		SetEntityMoveType(this.players[OPPONENT], status ? MOVETYPE_NONE : MOVETYPE_WALK);
	}

	void CeaseFire(bool status)
	{
		if (status)
		{
			SDKHook(this.players[CHALLENGER], SDKHook_PreThink, OnCeaseFire);
			SDKHook(this.players[OPPONENT], SDKHook_PreThink, OnCeaseFire);
		}
		else
		{
			SDKUnhook(this.players[CHALLENGER], SDKHook_PreThink, OnCeaseFire);
			SDKUnhook(this.players[OPPONENT], SDKHook_PreThink, OnCeaseFire);
		}
	}

	void StartTimer()
	{
		StopTimer(this.timer);
		this.timer = CreateTimer(1.0, Timer_ArenaTick, this.index, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}

	void StopTimer()
	{
		StopTimer(this.timer);
	}

	void PrintMessage(const char[] format, any ...)
	{
		char sBuffer[255];
		VFormat(sBuffer, sizeof(sBuffer), format, 2);

		char sTicks[64];
		IntToString(this.ticks, sTicks, sizeof(sTicks));

		ReplaceString(sBuffer, sizeof(sBuffer), "{TICKS}", sTicks);

		PrintHintText(this.players[CHALLENGER], sBuffer);
		PrintHintText(this.players[OPPONENT], sBuffer);
	}
}

Arena g_Arena[256];
int g_TotalArenas;
Arena g_CreateArena[MAXPLAYERS + 1];

bool g_IsChangingName[MAXPLAYERS + 1];

/*****************************/
//Plugin Info
public Plugin myinfo = 
{
	name = PLUGIN_NAME, 
	author = "Drixevel", 
	description = PLUGIN_DESCRIPTION, 
	version = PLUGIN_VERSION, 
	url = "https://drixevel.dev/"
};

public void OnPluginStart()
{
	convar_Default_Score = CreateConVar("sm_duels_default_score", "5", "What should the default score be for duels if arena's aren't specified?", FCVAR_NOTIFY, true, 1.0);

	RegConsoleCmd("sm_duel", Command_Duel, "Send duel requests to others.");

	RegAdminCmd("sm_createarena", Command_CreateArena, ADMFLAG_SLAY, "Create an arena on the current map.");
	RegAdminCmd("sm_listarenas", Command_ListArenas, ADMFLAG_SLAY, "List current arenas by name.");

	HookEvent("player_death", Event_OnPlayerDeath);
}

public void OnMapStart()
{
	GetCurrentMap(g_CurrentMap, sizeof(g_CurrentMap));
	GetMapDisplayName(g_CurrentMap, g_CurrentMap, sizeof(g_CurrentMap));
	ParseArenas();
}

public void OnConfigsExecuted()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "data/arenas/");

	if (!DirExists(sPath))
		CreateDirectory(sPath, 511);
}

public Action Command_CreateArena(int client, int args)
{
	g_CreateArena[client].Clear();
	OpenCreateArenaMenu(client);

	return Plugin_Handled;
}

void OpenCreateArenaMenu(int client)
{
	Menu menu = new Menu(MenuHandler_CreateArena);
	menu.SetTitle("Create an Arena:");

	char sDisplay[256];

	menu.AddItem("create", "Create Arena");

	char name[MAX_NAME_LENGTH];
	strcopy(name, sizeof(name), g_CreateArena[client].name);

	FormatEx(sDisplay, sizeof(sDisplay), "Name: %s", strlen(name) > 0 ? name : "<unset>");
	menu.AddItem("name", sDisplay);

	FormatEx(sDisplay, sizeof(sDisplay), "Player1 Spawn: %.0f/%.0f/%.0f", g_CreateArena[client].origin1[0], g_CreateArena[client].origin1[1], g_CreateArena[client].origin1[2]);
	menu.AddItem("player1", sDisplay);

	FormatEx(sDisplay, sizeof(sDisplay), "Player1 Spawn: %.0f/%.0f/%.0f", g_CreateArena[client].origin2[0], g_CreateArena[client].origin2[1], g_CreateArena[client].origin2[2]);
	menu.AddItem("player2", sDisplay);

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_CreateArena(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sInfo[32];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			if (StrEqual(sInfo, "create", false))
				CreateArena(param1);
			else if (StrEqual(sInfo, "name", false))
			{
				g_IsChangingName[param1] = true;
				PrintToChat(param1, "Please type in the name of the new arena:");
			}
			else if (StrEqual(sInfo, "player1", false))
			{
				float origin[3];
				GetClientAbsOrigin(param1, origin);

				float angles[3];
				GetClientAbsAngles(param1, angles);

				for (int i = 0; i < 3; i++)
				{
					g_CreateArena[param1].origin1[i] = origin[i];
					g_CreateArena[param1].angles1[i] = angles[i];
				}

				OpenCreateArenaMenu(param1);
			}
			else if (StrEqual(sInfo, "player2", false))
			{
				float origin[3];
				GetClientAbsOrigin(param1, origin);

				float angles[3];
				GetClientAbsAngles(param1, angles);

				for (int i = 0; i < 3; i++)
				{
					g_CreateArena[param1].origin2[i] = origin[i];
					g_CreateArena[param1].angles2[i] = angles[i];
				}

				OpenCreateArenaMenu(param1);
			}
		}

		case MenuAction_End:
			delete menu;
	}
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	if (g_IsChangingName[client])
	{
		char sName[MAX_NAME_LENGTH];
		strcopy(sName, sizeof(sName), sArgs);
		TrimString(sName);

		strcopy(g_CreateArena[client].name, MAX_NAME_LENGTH, sName);
		g_IsChangingName[client] = false;
		OpenCreateArenaMenu(client);

		return Plugin_Stop;
	}

	return Plugin_Continue;
}

void CreateArena(int client)
{
	char name[MAX_NAME_LENGTH];
	strcopy(name, sizeof(name), g_CreateArena[client].name);

	float origin1[3];
	float origin2[3];
	float angles1[3];
	float angles2[3];

	for (int i = 0; i < 2; i++)
	{
		origin1[i] = g_CreateArena[client].origin1[i];
		origin2[i] = g_CreateArena[client].origin2[i];
		angles1[i] = g_CreateArena[client].angles1[i];
		angles2[i] = g_CreateArena[client].angles2[i];
	}

	PrintToChat(client, "Arena %s has been created, assigned to the ID: %i", name, g_TotalArenas);

	g_Arena[g_TotalArenas].Add(g_TotalArenas, name, origin1, origin2, angles1, angles2);
	g_TotalArenas++;

	g_CreateArena[client].Clear();

	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "data/arenas/%s.cfg", g_CurrentMap);

	KeyValues kv = new KeyValues("arenas");
	kv.ImportFromFile(sPath);
	kv.JumpToKey(name, true);
	kv.SetVector("origin1", origin1);
	kv.SetVector("origin2", origin2);
	kv.SetVector("angles1", angles1);
	kv.SetVector("angles2", angles2);
	kv.Rewind();
	kv.ExportToFile(sPath);
	delete kv;
}

void ParseArenas()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "data/arenas/%s.cfg", g_CurrentMap);

	KeyValues kv = new KeyValues("arenas");
	if (kv.ImportFromFile(sPath) && kv.GotoFirstSubKey())
	{
		g_TotalArenas = 0;
		
		char name[64]; float origin1[3]; float origin2[3]; float angles1[3]; float angles2[3];

		do
		{
			kv.GetSectionName(name, sizeof(name));
			kv.GetVector("origin1", origin1);
			kv.GetVector("origin2", origin2);
			kv.GetVector("angles1", angles1);
			kv.GetVector("angles2", angles2);

			g_Arena[g_TotalArenas].Add(g_TotalArenas, name, origin1, origin2, angles1, angles2);
			g_TotalArenas++;
		}
		while (kv.GotoNextKey());
	}

	delete kv;
	LogMessage("Parsed %i arenas for map: %s", g_TotalArenas, g_CurrentMap);
}

public Action Command_ListArenas(int client, int args)
{
	OpenListArenasMenu(client);
	return Plugin_Handled;
}

void OpenListArenasMenu(int client)
{
	Menu menu = new Menu(MenuHandler_ListArenas);
	menu.SetTitle("Arenas for %s:", g_CurrentMap);

	for (int i = 0; i < g_TotalArenas; i++)
		menu.AddItem("", g_Arena[i].name);

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ListArenas(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{

		}

		case MenuAction_End:
			delete menu;
	}
}

public Action Command_Duel(int client, int args)
{
	OpenDuelsMenu(client);
	return Plugin_Handled;
}

void OpenDuelsMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Duels);
	menu.SetTitle("[SM] Duels");

	menu.AddItem("send", "Send Request");

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Duels(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sInfo[32];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			if (StrEqual(sInfo, "send", false))
				OpenPlayersMenu(param1);
		}

		case MenuAction_End:
			delete menu;
	}
}

void OpenPlayersMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Players);
	menu.SetTitle("Choose a player:");

	char sID[16]; char sName[MAX_NAME_LENGTH]; int draw;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsClientSourceTV(i))
			continue;
		
		draw = ITEMDRAW_DEFAULT;

		if (GetPlayerArena(i) != NO_ARENA)
			draw = ITEMDRAW_DISABLED;
		
		IntToString(GetClientUserId(i), sID, sizeof(sID));
		GetClientName(i, sName, sizeof(sName));
		menu.AddItem(sID, sName, draw);
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Players(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sInfo[32]; char sName[MAX_NAME_LENGTH];
			menu.GetItem(param2, sInfo, sizeof(sInfo), _, sName, sizeof(sName));

			int target = GetClientOfUserId(StringToInt(sInfo));

			if (target < 1)
			{
				PrintToChat(param1, "%s is no longer available, please try again.", sName);
				OpenPlayersMenu(param1);
				return;
			}

			SendDuelRequest(target, param1);
		}

		case MenuAction_Cancel:
			if (param2 == MenuCancel_ExitBack)
				OpenDuelsMenu(param1);
			
		case MenuAction_End:
			delete menu;
	}
}

void SendDuelRequest(int client, int challenger)
{
	if (IsFakeClient(client))
	{
		ChooseArena(challenger, client);
		return;
	}

	Menu menu = new Menu(MenuHandler_DuelRequest);
	menu.SetTitle("%N has challenged you to a duel:", challenger);

	menu.AddItem("yes", "Yes");
	menu.AddItem("no", "No");

	PushMenuInt(menu, "challenger", GetClientUserId(challenger));

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_DuelRequest(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sInfo[32];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			int challenger = GetClientOfUserId(GetMenuInt(menu, "challenger"));

			if (challenger < 1)
			{
				PrintToChat(param1, "Challenger is no longer available.");
				OpenPlayersMenu(param1);
				return;
			}

			if (StrEqual(sInfo, "yes", false))
				ChooseArena(challenger, param1);
			else
			{
				PrintToChat(challenger, "%N has declined your duel request.", param1);
				PrintToChat(param1, "You have declined %N's request.", challenger);
			}
		}

		case MenuAction_Cancel:
			if (param2 == MenuCancel_ExitBack)
				OpenDuelsMenu(param1);
			
		case MenuAction_End:
			delete menu;
	}
}

stock bool PushMenuInt(Menu menu, const char[] id, int value)
{
	if (menu == null || strlen(id) == 0)
		return false;
	
	char sBuffer[128];
	IntToString(value, sBuffer, sizeof(sBuffer));
	return menu.AddItem(id, sBuffer, ITEMDRAW_IGNORE);
}

stock int GetMenuInt(Menu menu, const char[] id, int defaultvalue = 0)
{
	if (menu == null || strlen(id) == 0)
		return defaultvalue;
	
	char info[128]; char data[128];
	for (int i = 0; i < menu.ItemCount; i++)
		if (menu.GetItem(i, info, sizeof(info), _, data, sizeof(data)) && StrEqual(info, id))
			return StringToInt(data);
	
	return defaultvalue;
}

stock bool StopTimer(Handle& timer)
{
	if (timer != null)
	{
		KillTimer(timer);
		timer = null;
		return true;
	}
	
	return false;
}

void ChooseArena(int client, int target)
{
	Menu menu = new Menu(MenuHandler_PickArena);
	menu.SetTitle("Choose an arena:");

	char sID[16];
	for (int i = 0; i < g_TotalArenas; i++)
	{
		IntToString(i, sID, sizeof(sID));
		menu.AddItem(sID, g_Arena[i].name);
	}

	PushMenuInt(menu, "target", GetClientUserId(target));

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_PickArena(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sID[16];
			menu.GetItem(param2, sID, sizeof(sID));

			int arena = StringToInt(sID);
			int target = GetClientOfUserId(GetMenuInt(menu, "target"));

			if (target < 1)
			{
				PrintToChat(param1, "Target is no longer available.");
				OpenDuelsMenu(param1);
				return;
			}

			StartDuel(param1, target, arena);
		}

		case MenuAction_End:
			delete menu;
	}
}

void StartDuel(int client, int target, int arena)
{
	g_Arena[arena].Reset();

	g_Arena[arena].players[CHALLENGER] = client;
	g_Arena[arena].players[OPPONENT] = target;

	g_Arena[arena].state = STATE_STARTING;
	g_Arena[arena].ticks = 6;

	g_Arena[arena].FreezePlayers(true);
	g_Arena[arena].CeaseFire(true);
	g_Arena[arena].SpawnPlayers();
	g_Arena[arena].StartTimer();
}

public Action Timer_ArenaTick(Handle timer, int arena)
{
	g_Arena[arena].ticks--;

	switch (g_Arena[arena].state)
	{
		case STATE_NONE:
		{

		}

		case STATE_STARTING:
		{
			if (g_Arena[arena].ticks > 0)
			{
				g_Arena[arena].PrintMessage("Match starting in... {TICKS}");
			}
			else
			{
				g_Arena[arena].ticks = 60;
				g_Arena[arena].state = STATE_ROUND_ACTIVE;
				g_Arena[arena].FreezePlayers(false);
				g_Arena[arena].CeaseFire(false);
			}
		}

		case STATE_ROUND_ACTIVE:
		{
			g_Arena[arena].PrintMessage("Round Time: {TICKS}");
		}

		case STATE_ROUND_ENDING:
		{
			if (g_Arena[arena].ticks > 0)
				g_Arena[arena].PrintMessage("Next round in... {TICKS}");
			else
			{
				g_Arena[arena].ticks = 6;
				g_Arena[arena].state = STATE_ROUND_STARTING;
				g_Arena[arena].RespawnPlayers();
				g_Arena[arena].SpawnPlayers();
				g_Arena[arena].FreezePlayers(true);
				g_Arena[arena].CeaseFire(true);
			}
		}

		case STATE_ROUND_STARTING:
		{
			if (g_Arena[arena].ticks > 0)
				g_Arena[arena].PrintMessage("Round starting in... {TICKS}");
			else
			{
				g_Arena[arena].ticks = 60;
				g_Arena[arena].state = STATE_ROUND_ACTIVE;
				g_Arena[arena].FreezePlayers(false);
				g_Arena[arena].CeaseFire(false);
			}
		}
	}

	return Plugin_Continue;
}

int GetPlayerArena(int client)
{
	for (int i = 0; i < g_TotalArenas; i++)
		if (g_Arena[i].players[CHALLENGER] == client || g_Arena[i].players[OPPONENT] == client)
			return i;
	
	return NO_ARENA;
}

public void Event_OnPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	int arena = GetPlayerArena(client);

	if (arena == GetPlayerArena(attacker) && g_Arena[arena].state == STATE_ROUND_ACTIVE)
	{
		int winner = g_Arena[arena].players[CHALLENGER] == attacker ? g_Arena[arena].players[CHALLENGER] : g_Arena[arena].players[OPPONENT];
		g_Arena[arena].scores[winner]++;

		if (g_Arena[arena].scores[winner] >= convar_Default_Score.IntValue)
			EndDuel(arena, winner);
		else
		{
			g_Arena[arena].ticks = 15;
			g_Arena[arena].state = STATE_ROUND_ENDING;
			//g_Arena[arena].PrintMessage("%N has won the round.", attacker);
		}
	}
}

void EndDuel(int arena, int winner)
{
	PrintToChatAll("%N has won a duel.", winner);
	g_Arena[arena].Reset();
}

public Action OnCeaseFire(int client)
{
	int weapon = -1;
	float time = GetGameTime();

	weapon = -1;
	if ((weapon = GetPlayerWeaponSlot(client, 0)) != -1)
		SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", time + 1);
	
	weapon = -1;
	if ((weapon = GetPlayerWeaponSlot(client, 1)) != -1)
		SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", time + 1);
}
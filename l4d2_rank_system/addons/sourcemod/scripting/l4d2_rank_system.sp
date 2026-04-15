#include <sourcemod>
#include <sdktools>

// --- 联动 Native 声明 ---
native bool IsInReady(); // 来自 readyup.sp

// --- Skill Detect Forward 声明 ---
forward void OnSkeet(int survivor, int hunter);
forward void OnTongueCut(int survivor, int smoker);
forward void OnChargerLevel(int survivor, int charger); 
forward void OnTankRockSkeeted(int survivor, int tank);
forward void OnHunterHighPounce(int hunter, int victim, int actualDamage, float calculatedDamage, float height, bool bReportedHigh, bool bPlayerIncapped);
forward void OnDeathCharge(int charger, int victim, float height, float distance, bool wasCarried);
forward void OnSpecialClear(int clearer, int pinner, int pinvictim, int zombieClass, float timeA, float timeB, bool withShove);

#define PLUGIN_VERSION "12.9"

public Plugin myinfo =
{
    name = "L4D2 Rank System",
    author = "YuKi",
    description = "求生之路2 MySQL积分排名插件",
    version = PLUGIN_VERSION,
    url = "https://github.com/JKYuKicyan/l4d2_rank_system"
};

Database g_hDatabase = null;
int g_iPlayerPoints[MAXPLAYERS + 1], g_iRank[MAXPLAYERS + 1];
bool g_bShowTag[MAXPLAYERS + 1] = {true, ...};
int g_iPendingPoints[MAXPLAYERS + 1], g_iSpitterDmg[MAXPLAYERS + 1], g_iVomitCount[MAXPLAYERS + 1];
char g_sPendingReason[MAXPLAYERS + 1][64];
Handle g_hPointTimer[MAXPLAYERS + 1];

ConVar cv_MinPlayers, cv_KillWitch, cv_Revive, cv_FF, cv_KillTeammate, cv_Incap, cv_Death, cv_Alarm;
ConVar cv_Skeet, cv_Cut, cv_Level, cv_DeathCharge, cv_DP, cv_RockSkeet, cv_Spitter30, cv_Vomit4, cv_KillSurvivor, cv_IncapSurvivor, cv_TankRockHit, cv_FastClear;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int max) {
    MarkNativeAsOptional("IsInReady");
    return APLRes_Success;
}

public void OnPluginStart() {
    RegConsoleCmd("sm_rank", Command_Rank);
    RegConsoleCmd("sm_rankall", Command_RankAll);
    RegConsoleCmd("sm_ranktop", Command_RankTop);

    cv_MinPlayers = CreateConVar("l4d2_rank_min_players", "1", "开启积分最少玩家数");
    cv_Skeet = CreateConVar("l4d2_points_skeet", "25", "空爆Hunter");
    cv_Cut = CreateConVar("l4d2_points_cut", "20", "砍断舌头");
    cv_Level = CreateConVar("l4d2_points_level", "30", "近战截停/击倒冲锋Charger");
    cv_FastClear = CreateConVar("l4d2_points_fast_clear", "20", "迅速解救奖励");
    cv_RockSkeet = CreateConVar("l4d2_points_rock_skeet", "15", "击碎坦克石头");
    cv_KillWitch = CreateConVar("l4d2_rank_points_witch", "50", "击杀Witch");
    cv_Revive = CreateConVar("l4d2_rank_points_revive", "15", "救起队友");
    cv_KillSurvivor = CreateConVar("l4d2_points_kill_survivor", "50", "特感击杀");
    cv_IncapSurvivor = CreateConVar("l4d2_points_incap_survivor", "20", "特感击倒");
    cv_TankRockHit = CreateConVar("l4d2_points_tank_rock_hit", "15", "石头砸中");
    cv_DeathCharge = CreateConVar("l4d2_points_death_charge", "100", "Charger秒杀");
    cv_DP = CreateConVar("l4d2_points_dp", "25", "完美突袭");
    cv_Spitter30 = CreateConVar("l4d2_points_spitter30", "20", "酸液30伤");
    cv_Vomit4 = CreateConVar("l4d2_points_vomit4", "50", "Boomer喷4人");
    cv_FF = CreateConVar("l4d2_rank_points_ff", "-1", "友伤扣分");
    cv_KillTeammate = CreateConVar("l4d2_rank_points_kill_team", "-100", "杀队友");
    cv_Incap = CreateConVar("l4d2_rank_points_incap", "-10", "自己倒地");
    cv_Death = CreateConVar("l4d2_rank_points_death", "-20", "自己死亡");
    cv_Alarm = CreateConVar("l4d2_rank_points_alarm", "-50", "触发警报车");

    AutoExecConfig(true, "l4d2_rank_system");

    HookEvent("player_hurt", Event_PlayerHurt);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_incapacitated", Event_PlayerIncap);
    HookEvent("player_now_it", Event_PlayerNowIt);
    HookEvent("round_start", Event_RoundStart);
    HookEvent("witch_killed", Event_WitchKilled);
    HookEvent("revive_success", Event_ReviveSuccess);
    HookEventEx("infected_chased", Event_InfectedChased);

    Database.Connect(OnDatabaseConnect, SQL_CheckConfig("l4d2_rank") ? "l4d2_rank" : "storage-local");
}

bool IsRankAllowed() {
    if (GetFeatureStatus(FeatureType_Native, "IsInReady") == FeatureStatus_Available) {
        if (IsInReady()) return false; 
    }
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) if (IsClientInGame(i) && !IsFakeClient(i)) count++;
    return (count >= cv_MinPlayers.IntValue);
}

void AddPoints(int client, int amount, const char[] reason) {
    if (!IsRankAllowed()) return;
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client)) return;
    
    g_iPendingPoints[client] += amount;
    strcopy(g_sPendingReason[client], 64, reason);
    if (g_hPointTimer[client] != null) KillTimer(g_hPointTimer[client]);
    g_hPointTimer[client] = CreateTimer(0.8, Timer_ShowPoints, GetClientUserId(client));
}

// ======================== 修改部分：旁观者不显示前缀 ========================
public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs) {
    if (client <= 0 || !IsClientInGame(client)) return Plugin_Continue;
    if (sArgs[0] == '!' || sArgs[0] == '/' || sArgs[1] == '!' || sArgs[1] == '/') return Plugin_Continue;
    
    // 【修改】增加判定：如果玩家在旁观者阵营（Team 1），直接跳过
    int team = GetClientTeam(client);
    if (team == 1) return Plugin_Continue;

    if (!g_bShowTag[client] || g_iRank[client] <= 0) return Plugin_Continue;
    
    char name[64], message[256], tag[32];
    GetClientName(client, name, sizeof(name));
    bool isTeamChat = (StrContains(command, "say_team") != -1);
    
    if (team == 2) strcopy(tag, sizeof(tag), "生还者");
    else if (team == 3) strcopy(tag, sizeof(tag), "感染者");

    if (isTeamChat) {
        Format(message, sizeof(message), "\x01\x04[%d]\x03(%s) %s\x01 : %s", g_iRank[client], tag, name, sArgs);
    } else {
        Format(message, sizeof(message), "\x01\x04[%d] \x03%s\x01 : %s", g_iRank[client], name, sArgs);
    }
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            if (isTeamChat && GetClientTeam(i) != team) continue;
            SendCustomSayText2(client, i, message);
        }
    }
    return Plugin_Handled; 
}

void SendCustomSayText2(int author, int target, const char[] message) {
    int clients[1]; clients[0] = target;
    Handle hBuffer = StartMessageEx(GetUserMessageId("SayText2"), clients, 1, USERMSG_RELIABLE|USERMSG_BLOCKHOOKS);
    if (hBuffer != null) {
        if (GetFeatureStatus(FeatureType_Capability, "Protobuf") == FeatureStatus_Available) {
            PbSetInt(hBuffer, "ent_idx", author);
            PbSetBool(hBuffer, "chat", true);
            PbSetString(hBuffer, "msg_name", message);
            for(int i=0; i<4; i++) PbAddString(hBuffer, "params", "");
        } else {
            BfWriteByte(hBuffer, author);
            BfWriteByte(hBuffer, true);
            BfWriteString(hBuffer, message);
        }
        EndMessage();
    }
}

// ======================== 其余代码保持不变 ========================
public void OnChargerLevel(int s, int c) { AddPoints(s, cv_Level.IntValue, "击倒冲锋Charger"); }
public void OnSkeet(int s, int h) { AddPoints(s, cv_Skeet.IntValue, "空爆Hunter"); }
public void OnTongueCut(int s, int sm) { AddPoints(s, cv_Cut.IntValue, "断舌"); }
public void OnTankRockSkeeted(int s, int t) { AddPoints(s, cv_RockSkeet.IntValue, "击碎石头"); }
public void OnDeathCharge(int c, int v, float h, float d, bool w) { AddPoints(c, cv_DeathCharge.IntValue, "Charger秒杀"); }
public void OnHunterHighPounce(int h, int v, int ad, float cd, float hi, bool rh, bool pi) { 
    if(ad >= 25) AddPoints(h, cv_DP.IntValue, "完美突袭"); 
}
public void OnSpecialClear(int clearer, int pinner, int pinvictim, int zombieClass, float timeA, float timeB, bool withShove) {
    if (clearer > 0 && clearer != pinvictim && timeA < 1.0) {
        AddPoints(clearer, cv_FastClear.IntValue, "迅速解救队友");
    }
}

public void Event_InfectedChased(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && GetClientTeam(client) == 2) AddPoints(client, cv_Alarm.IntValue, "触发警报车");
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast) {
    int v = GetClientOfUserId(event.GetInt("userid")), a = GetClientOfUserId(event.GetInt("attacker"));
    if (v <= 0 || a <= 0 || !IsClientInGame(a)) return;
    char wp[64]; event.GetString("weapon", wp, sizeof(wp));

    if (GetClientTeam(v) == 2 && GetClientTeam(a) == 2 && v != a) AddPoints(a, cv_FF.IntValue, "友军伤害");
    if (GetClientTeam(a) == 3) {
        if (StrEqual(wp, "spitter_acid")) {
            g_iSpitterDmg[a] += event.GetInt("dmg_health");
            if (g_iSpitterDmg[a] >= 30) { AddPoints(a, cv_Spitter30.IntValue, "酸液(30伤)"); g_iSpitterDmg[a] = 0; }
        } else if (StrEqual(wp, "tank_rock") && GetClientTeam(v) == 2) AddPoints(a, cv_TankRockHit.IntValue, "石头砸中");
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    int v = GetClientOfUserId(event.GetInt("userid")), a = GetClientOfUserId(event.GetInt("attacker"));
    if (v > 0 && GetClientTeam(v) == 2) {
        AddPoints(v, cv_Death.IntValue, "死亡");
        if (a > 0 && IsClientInGame(a)) {
            if (GetClientTeam(a) == 3) AddPoints(a, cv_KillSurvivor.IntValue, "杀死生还者");
            else if (a != v) AddPoints(a, cv_KillTeammate.IntValue, "杀害队友");
        }
    }
}

public void Event_PlayerIncap(Event event, const char[] name, bool dontBroadcast) {
    int v = GetClientOfUserId(event.GetInt("userid")), a = GetClientOfUserId(event.GetInt("attacker"));
    if (v > 0 && GetClientTeam(v) == 2) {
        AddPoints(v, cv_Incap.IntValue, "倒地");
        if (a > 0 && IsClientInGame(a) && GetClientTeam(a) == 3) AddPoints(a, cv_IncapSurvivor.IntValue, "击倒生还者");
    }
}

public void Event_PlayerNowIt(Event event, const char[] name, bool dontBroadcast) {
    int a = GetClientOfUserId(event.GetInt("attacker"));
    if (a > 0 && IsClientInGame(a) && GetClientTeam(a) == 3) {
        g_iVomitCount[a]++;
        if (g_iVomitCount[a] >= 4) { AddPoints(a, cv_Vomit4.IntValue, "一喷四奖励"); g_iVomitCount[a] = 0; }
    }
}

public void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast) { AddPoints(GetClientOfUserId(event.GetInt("userid")), cv_KillWitch.IntValue, "击杀Witch"); }
public void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast) { AddPoints(GetClientOfUserId(event.GetInt("userid")), cv_Revive.IntValue, "拉起队友"); }
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) { for (int i = 1; i <= MaxClients; i++) { g_iSpitterDmg[i] = 0; g_iVomitCount[i] = 0; } }

public Action Command_Rank(int client, int args) {
    if (client <= 0) return Plugin_Handled;
    Menu menu = new Menu(MenuHandler_Rank);
    menu.SetTitle("★ 积分: %d | 排名: %d ★", g_iPlayerPoints[client], g_iRank[client]);
    menu.AddItem("tag", g_bShowTag[client] ? "前缀: [开启]" : "前缀: [关闭]");
    menu.Display(client, 20);
    return Plugin_Handled;
}
public int MenuHandler_Rank(Menu menu, MenuAction action, int p1, int p2) { if (action == MenuAction_Select) { g_bShowTag[p1] = !g_bShowTag[p1]; UpdateDatabase(p1); Command_Rank(p1, 0); } else if (action == MenuAction_End) delete menu; return 0; }
public Action Command_RankAll(int client, int args) {
    Menu menu = new Menu(MenuHandler_Nothing);
    menu.SetTitle("★ 在线排名 ★");
    for (int i = 1; i <= MaxClients; i++) if (IsClientInGame(i) && !IsFakeClient(i)) {
        char n[32], f[64]; GetClientName(i, n, sizeof(n));
        Format(f, sizeof(f), "[%d] %d分 - %s", g_iRank[i], g_iPlayerPoints[i], n);
        menu.AddItem("p", f, ITEMDRAW_DISABLED);
    }
    menu.Display(client, 20);
    return Plugin_Handled;
}
public Action Command_RankTop(int client, int args) { if (g_hDatabase != null) g_hDatabase.Query(OnLoadTop10, "SELECT name, points FROM l4d2_rank_system ORDER BY points DESC LIMIT 10", GetClientUserId(client)); return Plugin_Handled; }
public void OnLoadTop10(Database db, DBResultSet results, const char[] error, any userid) {
    int client = GetClientOfUserId(userid);
    if (client <= 0 || results == null) return;
    Menu menu = new Menu(MenuHandler_Nothing);
    menu.SetTitle("★ 全服前十 ★");
    int r = 1;
    while (results.FetchRow()) { char n[32], f[64]; results.FetchString(0, n, sizeof(n)); Format(f, sizeof(f), "No.%d: %s (%d分)", r++, n, results.FetchInt(1)); menu.AddItem("t", f, ITEMDRAW_DISABLED); }
    menu.Display(client, 20);
}
public int MenuHandler_Nothing(Menu menu, MenuAction action, int p1, int p2) { if (action == MenuAction_End) delete menu; return 0; }

public Action Timer_ShowPoints(Handle timer, any userid) {
    int c = GetClientOfUserId(userid);
    if (c > 0) {
        int amt = g_iPendingPoints[c];
        PrintToChat(c, "\x01\x04[Rank]\x01 你因 \x05%s\x01 \x03%s%d\x01 分。", g_sPendingReason[c], (amt>0?"+":""), amt);
        g_iPlayerPoints[c] += amt;
        UpdateDatabase(c);
    }
    g_iPendingPoints[c] = 0; g_hPointTimer[c] = null;
    return Plugin_Stop;
}

void UpdateDatabase(int client) {
    if (g_hDatabase == null) return;
    char auth[32], q[256], name[64]; 
    if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth))) return; 
    GetClientName(client, name, sizeof(name));
    ReplaceString(name, sizeof(name), "'", "");
    Format(q, sizeof(q), "INSERT INTO l4d2_rank_system (steamid, name, points, show_tag) VALUES ('%s', '%s', %d, %d) ON DUPLICATE KEY UPDATE points=%d, name='%s', show_tag=%d", auth, name, g_iPlayerPoints[client], g_bShowTag[client]?1:0, g_iPlayerPoints[client], name, g_bShowTag[client]?1:0);
    g_hDatabase.Query(OnDefaultCallback, q);
    g_hDatabase.Query(OnRankUpdate, "SELECT steamid FROM l4d2_rank_system ORDER BY points DESC");
}
public void OnDatabaseConnect(Database db, const char[] error, any data) { if (db != null) { g_hDatabase = db; g_hDatabase.Query(OnDefaultCallback, "CREATE TABLE IF NOT EXISTS l4d2_rank_system (steamid VARCHAR(32) PRIMARY KEY, name VARCHAR(64), points INT DEFAULT 0, show_tag INT DEFAULT 1)"); } }
public void OnRankUpdate(Database db, DBResultSet results, const char[] error, any data) {
    if (results == null) return;
    int r = 1; char sid[32], auth[32];
    while (results.FetchRow()) { results.FetchString(0, sid, sizeof(sid)); for (int i = 1; i <= MaxClients; i++) if (IsClientInGame(i)) { GetClientAuthId(i, AuthId_Steam2, auth, sizeof(auth)); if (StrEqual(auth, sid)) g_iRank[i] = r; } r++; }
}
public void OnDefaultCallback(Database db, DBResultSet results, const char[] error, any data) { if (error[0] != '\0') LogError("%s", error); }
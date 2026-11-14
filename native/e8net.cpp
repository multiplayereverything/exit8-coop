// e8net.dll - network side of Exit 8 Together.
//
// The UE4SS Lua mod cannot open sockets and UE4SS does not export the Lua C API, so this DLL is loaded with
// package.loadlib(path, "*") (link only, no Lua calls) and starts its own thread from DllMain. Lua and this DLL talk
// through numbered files in <mod>/ipc:
//   Lua  -> DLL : out.<n>  (lines; "!cmd ..." lines are commands, everything else is payload for the peers)
//   DLL  -> Lua : in.<n>   (lines; "#event ..." lines are transport events, everything else is peer payload)
// Each file is written to a .tmp name and renamed, so a reader never sees half a file. Both sides read strictly in
// sequence, so ordering is preserved.
//
// Transports: LAN/direct TCP (default port 27080) and Steam (lobby + ISteamNetworkingMessages through the game's own
// steam_api64.dll, SDK 1.53). Host-authoritative star: clients talk only to the host; the host relays payload from a
// client to the other clients.
#define WIN32_LEAN_AND_MEAN
#define _WINSOCK_DEPRECATED_NO_WARNINGS
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>
#include <deque>
#include <mutex>
#include <atomic>
#include <sstream>

#pragma comment(lib, "ws2_32.lib")

namespace {

const int kMaxPlayers = 4;
const uint32_t kMaxFrame = 1u << 20;        // 1 MB per frame
const size_t kMaxQueueBytes = 4u << 20;     // per-connection outbound limit (by size, not count)
const DWORD kKeepaliveMs = 1000;
const DWORD kTimeoutMs = 30000;             // host stalls during loads; don't drop early (Baldi 0.9.0 lesson)

std::wstring g_modDir, g_ipcDir;
std::atomic<bool> g_quit{false};
FILE* g_log = nullptr;                       // process-scoped
std::mutex g_logMu;

void Log(const char* fmt, ...) {
    std::lock_guard<std::mutex> lk(g_logMu);
    if (!g_log) return;
    SYSTEMTIME t; GetLocalTime(&t);
    fprintf(g_log, "%02d:%02d:%02d.%03d ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    va_list ap; va_start(ap, fmt); vfprintf(g_log, fmt, ap); va_end(ap);
    fputc('\n', g_log); fflush(g_log);
}

// ---------------------------------------------------------------- IPC files
int g_inSeq = 0, g_outSeq = 0;

std::wstring IpcPath(const wchar_t* prefix, int n) {
    wchar_t b[64]; swprintf(b, 64, L"%s.%d", prefix, n);
    return g_ipcDir + L"\\" + b;
}

void ClearIpc() {
    CreateDirectoryW(g_ipcDir.c_str(), nullptr);
    WIN32_FIND_DATAW fd; HANDLE h = FindFirstFileW((g_ipcDir + L"\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) DeleteFileW((g_ipcDir + L"\\" + fd.cFileName).c_str());
    } while (FindNextFileW(h, &fd));
    FindClose(h);
}

std::string g_inPending;                     // lines waiting to be flushed to Lua (net thread only)
void ToLua(const std::string& line) { g_inPending += line; g_inPending += '\n'; }

void FlushToLua() {
    if (g_inPending.empty()) return;
    int n = g_inSeq + 1;
    std::wstring tmp = IpcPath(L"in", n) + L".tmp", fin = IpcPath(L"in", n);
    HANDLE h = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;   // retry next tick
    DWORD w = 0; WriteFile(h, g_inPending.data(), (DWORD)g_inPending.size(), &w, nullptr); CloseHandle(h);
    if (!MoveFileExW(tmp.c_str(), fin.c_str(), MOVEFILE_REPLACE_EXISTING)) { DeleteFileW(tmp.c_str()); return; }
    g_inSeq = n; g_inPending.clear();
}

bool ReadFromLua(std::string& out) {
    std::wstring p = IpcPath(L"out", g_outSeq + 1);
    HANDLE h = CreateFileW(p.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER sz; GetFileSizeEx(h, &sz);
    out.resize((size_t)sz.QuadPart);
    DWORD r = 0; if (sz.QuadPart) ReadFile(h, &out[0], (DWORD)sz.QuadPart, &r, nullptr);
    CloseHandle(h); DeleteFileW(p.c_str());
    g_outSeq++;
    return true;
}

std::vector<std::string> Split(const std::string& s, char sep) {
    std::vector<std::string> v; std::string cur;
    for (char c : s) { if (c == sep) { v.push_back(cur); cur.clear(); } else if (c != '\r') cur += c; }
    if (!cur.empty()) v.push_back(cur);
    return v;
}

// ---------------------------------------------------------------- Steam flat API (SDK 1.53)
#pragma pack(push, 8)
struct SteamNetworkingIdentity { int32_t type; int32_t cbSize; union { uint64_t steamID64; char pad[128]; }; };
struct SteamNetworkingMessage_t { void* data; int32_t cbSize; uint32_t conn; SteamNetworkingIdentity peer; };
struct LobbyCreated_t { int32_t result; uint64_t lobby; };
struct LobbyEnter_t { uint64_t lobby; uint32_t perms; bool locked; uint32_t response; };
struct FriendGameInfo_t { uint64_t gameID; uint32_t gameIP; uint16_t gamePort; uint16_t queryPort; uint64_t lobby; };
#pragma pack(pop)

struct Steam {
    HMODULE dll = nullptr;
    void* user = nullptr; void* mm = nullptr; void* msgs = nullptr; void* utils = nullptr; void* friends = nullptr;
    int32_t (*GetHSteamUser)() = nullptr;
    uint64_t (*GetSteamID)(void*) = nullptr;
    uint64_t (*CreateLobby)(void*, int, int) = nullptr;
    uint64_t (*JoinLobby)(void*, uint64_t) = nullptr;
    void (*LeaveLobby)(void*, uint64_t) = nullptr;
    uint64_t (*GetLobbyOwner)(void*, uint64_t) = nullptr;
    bool (*SetLobbyData)(void*, uint64_t, const char*, const char*) = nullptr;
    int (*GetNumLobbyMembers)(void*, uint64_t) = nullptr;
    uint64_t (*GetLobbyMemberByIndex)(void*, uint64_t, int) = nullptr;
    int (*SendMessageToUser)(void*, const SteamNetworkingIdentity*, const void*, uint32_t, int, int) = nullptr;
    int (*ReceiveMessagesOnChannel)(void*, int, SteamNetworkingMessage_t**, int) = nullptr;
    bool (*AcceptSessionWithUser)(void*, const SteamNetworkingIdentity*) = nullptr;
    bool (*CloseSessionWithUser)(void*, const SteamNetworkingIdentity*) = nullptr;
    void (*MsgRelease)(SteamNetworkingMessage_t*) = nullptr;
    bool (*IsAPICallCompleted)(void*, uint64_t, bool*) = nullptr;
    bool (*GetAPICallResult)(void*, uint64_t, void*, int, int, bool*) = nullptr;
    const char* (*GetPersonaName)(void*) = nullptr;
    void* netutils = nullptr;
    void (*InitRelayNetworkAccess)(void*) = nullptr;
    int (*GetFriendCount)(void*, int) = nullptr;
    uint64_t (*GetFriendByIndex)(void*, int, int) = nullptr;
    bool (*GetFriendGamePlayed)(void*, uint64_t, FriendGameInfo_t*) = nullptr;
    uint32_t (*GetAppID)(void*) = nullptr;

    bool Load() {
        dll = GetModuleHandleW(L"steam_api64.dll");
        if (!dll) { Log("steam: steam_api64.dll not loaded in this process"); return false; }
#define E8_GET(field, name) field = reinterpret_cast<decltype(field)>(GetProcAddress(dll, name)); if (!field) { Log("steam: missing %s", name); return false; }
        E8_GET(GetHSteamUser, "SteamAPI_GetHSteamUser");
        if (GetHSteamUser() == 0) { Log("steam: SteamAPI not initialised by the game"); return false; }
        void* (*acc)();
        E8_GET(acc, "SteamAPI_SteamUser_v021"); user = acc();
        E8_GET(acc, "SteamAPI_SteamMatchmaking_v009"); mm = acc();
        E8_GET(acc, "SteamAPI_SteamNetworkingMessages_SteamAPI_v002"); msgs = acc();
        E8_GET(acc, "SteamAPI_SteamUtils_v010"); utils = acc();
        E8_GET(acc, "SteamAPI_SteamFriends_v017"); friends = acc();
        E8_GET(GetSteamID, "SteamAPI_ISteamUser_GetSteamID");
        E8_GET(CreateLobby, "SteamAPI_ISteamMatchmaking_CreateLobby");
        E8_GET(JoinLobby, "SteamAPI_ISteamMatchmaking_JoinLobby");
        E8_GET(LeaveLobby, "SteamAPI_ISteamMatchmaking_LeaveLobby");
        E8_GET(GetLobbyOwner, "SteamAPI_ISteamMatchmaking_GetLobbyOwner");
        E8_GET(SetLobbyData, "SteamAPI_ISteamMatchmaking_SetLobbyData");
        E8_GET(GetNumLobbyMembers, "SteamAPI_ISteamMatchmaking_GetNumLobbyMembers");
        E8_GET(GetLobbyMemberByIndex, "SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex");
        E8_GET(SendMessageToUser, "SteamAPI_ISteamNetworkingMessages_SendMessageToUser");
        E8_GET(ReceiveMessagesOnChannel, "SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel");
        E8_GET(AcceptSessionWithUser, "SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser");
        E8_GET(CloseSessionWithUser, "SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser");
        E8_GET(MsgRelease, "SteamAPI_SteamNetworkingMessage_t_Release");
        E8_GET(IsAPICallCompleted, "SteamAPI_ISteamUtils_IsAPICallCompleted");
        E8_GET(GetAPICallResult, "SteamAPI_ISteamUtils_GetAPICallResult");
        E8_GET(GetPersonaName, "SteamAPI_ISteamFriends_GetPersonaName");
        E8_GET(acc, "SteamAPI_SteamNetworkingUtils_SteamAPI_v004"); netutils = acc();
        E8_GET(InitRelayNetworkAccess, "SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess");
        E8_GET(GetFriendCount, "SteamAPI_ISteamFriends_GetFriendCount");
        E8_GET(GetFriendByIndex, "SteamAPI_ISteamFriends_GetFriendByIndex");
        E8_GET(GetFriendGamePlayed, "SteamAPI_ISteamFriends_GetFriendGamePlayed");
        E8_GET(GetAppID, "SteamAPI_ISteamUtils_GetAppID");
#undef E8_GET
        if (!user || !mm || !msgs || !utils || !friends) { Log("steam: interface accessor returned null"); return false; }
        if (netutils) InitRelayNetworkAccess(netutils);   // start talking to Valve's relays now, not on the first send
        Log("steam: ready, my id %llu, app %u", (unsigned long long)GetSteamID(user), GetAppID(utils));
        return true;
    }
    static SteamNetworkingIdentity Id(uint64_t sid) { SteamNetworkingIdentity i{}; i.type = 16; i.cbSize = 8; i.steamID64 = sid; return i; }
};
Steam g_steam;                               // process-scoped
// The host receives on one channel and clients on another. Over two accounts this is just tidy; on one Steam account
// (two lab copies) it is what makes loopback work, because both processes read the same user's message queue.
const int kHostChannel = 8;
const int kClientChannel = 9;
const int kSendReliable = 8;                 // k_nSteamNetworkingSend_Reliable

// ---------------------------------------------------------------- peers
struct Peer {
    int id = 0;                              // 1 = host, 2..4 = clients
    SOCKET s = INVALID_SOCKET;               // TCP
    uint64_t steamId = 0;                    // Steam
    std::string rx;                          // TCP receive buffer
    std::string tx;                          // TCP send buffer
    std::deque<std::pair<DWORD, std::string>> delayed;   // lab lag emulation: (due tick, framed bytes), in order
    DWORD lastRx = 0, lastTx = 0;
    bool welcomed = false;
    std::string name;
};

enum class Mode { None, LanHost, LanClient, SteamHost, SteamClient };
Mode g_mode = Mode::None;
SOCKET g_listen = INVALID_SOCKET;
std::vector<Peer> g_peers;                   // host: clients; client: one entry, the host
int g_myId = 0;
std::string g_proto, g_ver, g_name;
uint64_t g_lobby = 0, g_lobbyCall = 0;
int g_lobbyCallKind = 0;                     // 1 create, 2 join
DWORD g_lastLobbyScan = 0;
DWORD g_autoJoinUntil = 0;                   // client "auto" join: search friends' lobbies until this tick
DWORD g_selfTestUntil = 0;                   // "!steamselftest": send to our own identity, read it back (one process)
std::string g_selfTestToken;
const int kSelfTestChannel = 7;
DWORD g_lagMs = 0, g_jitterMs = 0;           // lab lag emulation on outgoing TCP frames (env, read at load)

void SetNonBlocking(SOCKET s) { u_long one = 1; ioctlsocket(s, FIONBIO, &one); int nd = 1; setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (char*)&nd, sizeof nd); }

void SendFrame(Peer& p, const std::string& payload) {
    if (g_mode == Mode::SteamHost || g_mode == Mode::SteamClient) {
        if (!p.steamId) return;
        SteamNetworkingIdentity id = Steam::Id(p.steamId);
        int ch = (g_mode == Mode::SteamHost) ? kClientChannel : kHostChannel;
        int r = g_steam.SendMessageToUser(g_steam.msgs, &id, payload.data(), (uint32_t)payload.size(), kSendReliable, ch);
        if (r != 1) Log("steam send to %llu failed: %d", (unsigned long long)p.steamId, r);
        p.lastTx = GetTickCount();
        return;
    }
    if (p.tx.size() > kMaxQueueBytes) { Log("peer %d send queue over limit, dropping link", p.id); closesocket(p.s); p.s = INVALID_SOCKET; return; }
    uint32_t n = (uint32_t)payload.size();
    std::string framed(reinterpret_cast<const char*>(&n), 4);
    framed += payload;
    p.lastTx = GetTickCount();
    if (g_lagMs > 0) {
        // lab only (E8T_LAG_MS / E8T_JITTER_MS): hold each frame for lag + random jitter, never reordering (TCP)
        DWORD due = GetTickCount() + g_lagMs + (g_jitterMs ? (DWORD)(rand() % (g_jitterMs + 1)) : 0);
        if (!p.delayed.empty() && due < p.delayed.back().first) due = p.delayed.back().first;
        p.delayed.emplace_back(due, std::move(framed));
        return;
    }
    p.tx += framed;
}

void ReleaseDelayed(Peer& p) {
    DWORD now = GetTickCount();
    while (!p.delayed.empty() && (int)(now - p.delayed.front().first) >= 0) { p.tx += p.delayed.front().second; p.delayed.pop_front(); }
}

void Status() {
    std::ostringstream o;
    const char* m = g_mode == Mode::None ? "none" : g_mode == Mode::LanHost ? "lan-host" : g_mode == Mode::LanClient ? "lan-client"
                  : g_mode == Mode::SteamHost ? "steam-host" : "steam-client";
    o << "#status mode=" << m << " id=" << g_myId << " peers=";
    int n = 0; for (auto& p : g_peers) if (p.welcomed) { o << (n++ ? "," : "") << p.id; }
    if (!n) o << "-";
    if (g_lobby) o << " lobby=" << g_lobby;
    ToLua(o.str());
}

void DropPeer(size_t i, const char* why) {
    Peer& p = g_peers[i];
    Log("peer %d dropped: %s", p.id, why);
    if (p.welcomed) ToLua("#peer_left " + std::to_string(p.id) + " " + why);
    if (p.s != INVALID_SOCKET) closesocket(p.s);
    if (p.steamId && g_steam.msgs) { auto id = Steam::Id(p.steamId); g_steam.CloseSessionWithUser(g_steam.msgs, &id); }
    bool wasHost = (g_mode == Mode::LanClient || g_mode == Mode::SteamClient);
    g_peers.erase(g_peers.begin() + i);
    if (wasHost) { ToLua(std::string("#disconnected ") + why); g_myId = 0; }
    Status();
}

int NextClientId() {
    for (int id = 2; id <= kMaxPlayers; id++) {
        bool used = false; for (auto& p : g_peers) if (p.id == id && p.welcomed) used = true;
        if (!used) return id;
    }
    return 0;
}

// Handle one complete frame from peer index i. Returns false if the peer was removed.
bool OnFrame(size_t i, const std::string& f) {
    Peer& p = g_peers[i];
    p.lastRx = GetTickCount();
    if (f.empty()) return true;              // keepalive
    bool host = (g_mode == Mode::LanHost || g_mode == Mode::SteamHost);
    if (!p.welcomed) {
        auto parts = Split(f, '|');
        if (host) {
            if (parts.size() < 4 || parts[0] != "HELLO") { DropPeer(i, "bad-hello"); return false; }
            if (parts[1] != g_proto || parts[2] != g_ver) {
                SendFrame(p, "REJECT|version: host has " + g_ver + " (protocol " + g_proto + "), you have " + parts[2] + " (protocol " + parts[1] + ")");
                Log("rejecting peer: version %s/%s", parts[2].c_str(), parts[1].c_str());
                // id -1: PumpTcp drops it once the reject is flushed; Steam sends at once
                p.welcomed = false; p.id = -1;
                return true;
            }
            int id = NextClientId();
            if (!id) { SendFrame(p, "REJECT|The game is full (" + std::to_string(kMaxPlayers) + " players)"); p.id = -1; return true; }
            p.id = id; p.welcomed = true; p.name = parts[3];
            SendFrame(p, "WELCOME|" + std::to_string(id) + "|" + g_name);
            ToLua("#peer_join " + std::to_string(id) + " " + p.name);
            Status();
            return true;
        }
        if (parts.size() >= 3 && parts[0] == "WELCOME") {
            p.welcomed = true; p.id = 1; p.name = parts[2]; g_myId = atoi(parts[1].c_str());
            ToLua("#connected " + parts[1] + " " + p.name);
            ToLua("#peer_join 1 " + p.name);
            Status();
            return true;
        }
        if (parts.size() >= 2 && parts[0] == "REJECT") { ToLua("#rejected " + parts[1]); DropPeer(i, "rejected"); return false; }
        DropPeer(i, "bad-welcome"); return false;
    }
    ToLua(f.back() == '\n' ? f.substr(0, f.size() - 1) : f);
    if (host) for (auto& q : g_peers) if (&q != &p && q.welcomed) SendFrame(q, f);  // relay to the other clients
    return true;
}

void Broadcast(const std::string& payload) { for (auto& p : g_peers) if (p.welcomed) SendFrame(p, payload); }

void StopAll() {
    for (size_t i = g_peers.size(); i-- > 0;) DropPeer(i, "stopped");
    if (g_listen != INVALID_SOCKET) { closesocket(g_listen); g_listen = INVALID_SOCKET; }
    if (g_lobby && g_steam.mm) g_steam.LeaveLobby(g_steam.mm, g_lobby);
    g_lobby = 0; g_lobbyCall = 0; g_autoJoinUntil = 0; g_mode = Mode::None; g_myId = 0;
    Status();
}

void Command(const std::string& line) {
    auto a = Split(line.substr(1), ' ');
    if (a.empty()) return;
    Log("cmd: %s", line.c_str());
    auto arg = [&](size_t k, const char* d) { return k < a.size() ? a[k] : std::string(d); };
    if (a[0] == "stop") { StopAll(); return; }
    if (a[0] == "steamselftest") {
        // Checks our Steam flat-API use in one process: SendMessageToUser to our own identity on a spare channel, then
        // ReceiveMessagesOnChannel must return the same bytes with our own SteamID in the message's peer identity
        // (proves the SteamNetworkingIdentity / SteamNetworkingMessage_t layouts we declared match SDK 1.53).
        if (!g_steam.msgs && !g_steam.Load()) { ToLua("#steamselftest fail steam-unavailable"); return; }
        g_selfTestToken = "E8SELFTEST" + std::to_string(GetTickCount());
        uint64_t me = g_steam.GetSteamID(g_steam.user);
        auto id = Steam::Id(me);
        int r = g_steam.SendMessageToUser(g_steam.msgs, &id, g_selfTestToken.data(), (uint32_t)g_selfTestToken.size(), kSendReliable, kSelfTestChannel);
        Log("steam selftest: send to self -> %d", r);
        if (r != 1) { ToLua("#steamselftest fail send-result " + std::to_string(r)); return; }
        g_selfTestUntil = GetTickCount() + 10000;
        return;
    }
    // !host lan <port> <proto> <ver> <name> | !host steam - <proto> <ver> <name>
    // !join lan <addr> <port> <proto> <ver> <name> | !join steam <lobbyid> - <proto> <ver> <name>
    if (a[0] == "host" || a[0] == "join") {
        StopAll();
        bool join = a[0] == "join";
        size_t k = join ? 4 : 3;
        g_proto = arg(k, "0"); g_ver = arg(k + 1, "0"); g_name = arg(k + 2, "player");
        if (arg(1, "") == "lan") {
            if (!join) {
                int port = atoi(arg(2, "27080").c_str());
                g_listen = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
                BOOL ex = TRUE; setsockopt(g_listen, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (char*)&ex, sizeof ex);
                sockaddr_in sa{}; sa.sin_family = AF_INET; sa.sin_port = htons((u_short)port); sa.sin_addr.s_addr = INADDR_ANY;
                if (bind(g_listen, (sockaddr*)&sa, sizeof sa) != 0 || listen(g_listen, 8) != 0) {
                    ToLua("#error host-bind-failed port " + std::to_string(port) + " (" + std::to_string(WSAGetLastError()) + ")");
                    closesocket(g_listen); g_listen = INVALID_SOCKET; return;
                }
                SetNonBlocking(g_listen);
                g_mode = Mode::LanHost; g_myId = 1;
                ToLua("#hosting lan " + std::to_string(port));
            } else {
                std::string addr = arg(2, "127.0.0.1"); int port = atoi(arg(3, "27080").c_str());
                addrinfo hints{}, *res = nullptr; hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
                if (getaddrinfo(addr.c_str(), std::to_string(port).c_str(), &hints, &res) != 0 || !res) { ToLua("#error bad-address " + addr); return; }
                SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
                DWORD to = 5000; setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (char*)&to, sizeof to);
                int r = connect(s, res->ai_addr, (int)res->ai_addrlen); freeaddrinfo(res);  // blocking connect on the net thread only
                if (r != 0) { ToLua("#error connect-failed " + addr + ":" + std::to_string(port)); closesocket(s); return; }
                SetNonBlocking(s);
                Peer p; p.s = s; p.lastRx = p.lastTx = GetTickCount(); g_peers.push_back(p);
                g_mode = Mode::LanClient;
                SendFrame(g_peers.back(), "HELLO|" + g_proto + "|" + g_ver + "|" + g_name);
            }
            Status();
            return;
        }
        if (arg(1, "") == "steam") {
            if (!g_steam.msgs && !g_steam.Load()) { ToLua("#error steam-unavailable"); return; }
            if (!join) { g_lobbyCall = g_steam.CreateLobby(g_steam.mm, 1 /*friends only*/, kMaxPlayers); g_lobbyCallKind = 1; g_mode = Mode::SteamHost; g_myId = 1; }
            else {
                uint64_t lobby = _strtoui64(arg(2, "0").c_str(), nullptr, 10);
                g_mode = Mode::SteamClient;
                if (lobby) { g_lobbyCall = g_steam.JoinLobby(g_steam.mm, lobby); g_lobbyCallKind = 2; }
                else { g_autoJoinUntil = GetTickCount() + 120000; ToLua("#searching steam friends"); }   // "auto": find a friend hosting
            }
            Status();
            return;
        }
        ToLua("#error unknown-transport " + arg(1, "?"));
        return;
    }
    ToLua("#error unknown-command " + a[0]);
}

// Client with no lobby id: join the first Steam friend who is in an Exit 8 lobby (friends-only lobbies don't show in
// lobby search, but a friend's current lobby is visible through GetFriendGamePlayed).
uint64_t FindFriendLobby() {
    uint32_t app = g_steam.GetAppID(g_steam.utils);
    const int kFriendFlagImmediate = 4;
    int n = g_steam.GetFriendCount(g_steam.friends, kFriendFlagImmediate);
    for (int i = 0; i < n; i++) {
        uint64_t f = g_steam.GetFriendByIndex(g_steam.friends, i, kFriendFlagImmediate);
        FriendGameInfo_t gi{};
        if (g_steam.GetFriendGamePlayed(g_steam.friends, f, &gi) && (uint32_t)(gi.gameID & 0xFFFFFF) == app && gi.lobby) {
            Log("steam: friend %llu is in lobby %llu", (unsigned long long)f, (unsigned long long)gi.lobby);
            return gi.lobby;
        }
    }
    return 0;
}

void PumpSelfTest() {
    if (!g_selfTestUntil) return;
    SteamNetworkingMessage_t* m[4];
    int n = g_steam.ReceiveMessagesOnChannel(g_steam.msgs, kSelfTestChannel, m, 4);
    for (int k = 0; k < n; k++) {
        std::string got((const char*)m[k]->data, (size_t)m[k]->cbSize);
        uint64_t from = m[k]->peer.steamID64;
        int type = m[k]->peer.type;
        g_steam.MsgRelease(m[k]);
        uint64_t me = g_steam.GetSteamID(g_steam.user);
        bool ok = got == g_selfTestToken && from == me && type == 16;
        Log("steam selftest: got %zu bytes, peer type %d id %llu (me %llu) -> %s", got.size(), type, (unsigned long long)from,
            (unsigned long long)me, ok ? "ok" : "MISMATCH");
        ToLua(std::string("#steamselftest ") + (ok ? "ok" : "fail mismatch") + " bytes=" + std::to_string(got.size()) +
              " peer_type=" + std::to_string(type) + " peer_is_me=" + (from == me ? "1" : "0"));
        g_selfTestUntil = 0;
        return;
    }
    if (GetTickCount() > g_selfTestUntil) { ToLua("#steamselftest fail timeout"); g_selfTestUntil = 0; }
}

void PumpSteam() {
    if (g_steam.msgs) PumpSelfTest();
    if (g_mode != Mode::SteamHost && g_mode != Mode::SteamClient) return;
    DWORD now = GetTickCount();
    if (g_mode == Mode::SteamClient && !g_lobby && !g_lobbyCall && g_autoJoinUntil) {
        if (now > g_autoJoinUntil) { g_autoJoinUntil = 0; ToLua("#error no-friend-hosting (no Steam friend is in an Exit 8 Together lobby)"); g_mode = Mode::None; Status(); return; }
        if (now - g_lastLobbyScan > 2000) {
            g_lastLobbyScan = now;
            uint64_t lobby = FindFriendLobby();
            if (lobby) { g_autoJoinUntil = 0; g_lobbyCall = g_steam.JoinLobby(g_steam.mm, lobby); g_lobbyCallKind = 2; }
        }
    }
    if (g_lobbyCall) {
        bool failed = false;
        if (g_steam.IsAPICallCompleted(g_steam.utils, g_lobbyCall, &failed)) {
            if (g_lobbyCallKind == 1) {
                LobbyCreated_t r{}; g_steam.GetAPICallResult(g_steam.utils, g_lobbyCall, &r, sizeof r, 513, &failed);
                if (failed || r.result != 1) { ToLua("#error lobby-create-failed " + std::to_string(r.result)); g_mode = Mode::None; }
                else { g_lobby = r.lobby; g_steam.SetLobbyData(g_steam.mm, g_lobby, "e8t_ver", g_ver.c_str()); ToLua("#hosting steam " + std::to_string(g_lobby)); }
            } else {
                LobbyEnter_t r{}; g_steam.GetAPICallResult(g_steam.utils, g_lobbyCall, &r, sizeof r, 504, &failed);
                if (failed || r.response != 1) { ToLua("#error lobby-join-failed " + std::to_string(r.response)); g_mode = Mode::None; }
                else {
                    g_lobby = r.lobby;
                    Peer p; p.steamId = g_steam.GetLobbyOwner(g_steam.mm, g_lobby); p.lastRx = p.lastTx = now; g_peers.push_back(p);
                    ToLua("#joined steam " + std::to_string(g_lobby) + " owner " + std::to_string(p.steamId) +
                          (p.steamId == g_steam.GetSteamID(g_steam.user) ? " same-account" : ""));
                    auto id = Steam::Id(p.steamId); g_steam.AcceptSessionWithUser(g_steam.msgs, &id);
                    SendFrame(g_peers.back(), "HELLO|" + g_proto + "|" + g_ver + "|" + g_name);
                }
            }
            g_lobbyCall = 0;
            Status();
        }
    }
    // Host: pre-accept every lobby member (only lobby members may connect).
    if (g_mode == Mode::SteamHost && g_lobby && now - g_lastLobbyScan > 1000) {
        g_lastLobbyScan = now;
        int n = g_steam.GetNumLobbyMembers(g_steam.mm, g_lobby);
        for (int k = 0; k < n; k++) {
            uint64_t m = g_steam.GetLobbyMemberByIndex(g_steam.mm, g_lobby, k);
            if (m == g_steam.GetSteamID(g_steam.user)) continue;
            auto id = Steam::Id(m); g_steam.AcceptSessionWithUser(g_steam.msgs, &id);
        }
    }
    SteamNetworkingMessage_t* msgs[32];
    int n;
    int rxChannel = (g_mode == Mode::SteamHost) ? kHostChannel : kClientChannel;
    while ((n = g_steam.ReceiveMessagesOnChannel(g_steam.msgs, rxChannel, msgs, 32)) > 0) {
        for (int k = 0; k < n; k++) {
            uint64_t from = msgs[k]->peer.steamID64;
            std::string f((const char*)msgs[k]->data, (size_t)msgs[k]->cbSize);
            g_steam.MsgRelease(msgs[k]);
            size_t idx = g_peers.size();
            for (size_t j = 0; j < g_peers.size(); j++) if (g_peers[j].steamId == from) idx = j;
            if (idx == g_peers.size()) {
                if (g_mode != Mode::SteamHost) continue;
                bool member = false; int mc = g_steam.GetNumLobbyMembers(g_steam.mm, g_lobby);
                for (int j = 0; j < mc; j++) if (g_steam.GetLobbyMemberByIndex(g_steam.mm, g_lobby, j) == from) member = true;
                if (!member) { Log("ignoring steam message from non-member %llu", (unsigned long long)from); continue; }
                Peer p; p.steamId = from; p.lastRx = p.lastTx = now; g_peers.push_back(p);
            }
            OnFrame(idx, f);
        }
    }
}

void PumpTcp() {
    if (g_mode == Mode::LanHost && g_listen != INVALID_SOCKET) {
        for (;;) {
            SOCKET c = accept(g_listen, nullptr, nullptr);
            if (c == INVALID_SOCKET) break;
            SetNonBlocking(c);
            Peer p; p.s = c; p.lastRx = p.lastTx = GetTickCount(); g_peers.push_back(p);
            Log("accepted a TCP connection");
        }
    }
    if (g_mode != Mode::LanHost && g_mode != Mode::LanClient) return;
    for (size_t i = 0; i < g_peers.size();) {
        Peer& p = g_peers[i];
        bool gone = false;
        ReleaseDelayed(p);
        while (!p.tx.empty()) {
            int w = send(p.s, p.tx.data(), (int)p.tx.size(), 0);
            if (w > 0) p.tx.erase(0, (size_t)w);
            else { if (WSAGetLastError() != WSAEWOULDBLOCK) gone = true; break; }
        }
        if (p.id == -1 && p.tx.empty() && p.delayed.empty()) gone = true;   // rejected peer, reply flushed
        char buf[16384];
        while (!gone) {
            int r = recv(p.s, buf, sizeof buf, 0);
            if (r > 0) { p.rx.append(buf, (size_t)r); continue; }
            if (r == 0 || WSAGetLastError() != WSAEWOULDBLOCK) gone = true;
            break;
        }
        bool removed = false;
        while (p.rx.size() >= 4) {               // parse what arrived even if the link closed after it
            uint32_t n; memcpy(&n, p.rx.data(), 4);
            if (n > kMaxFrame) { gone = true; p.rx.clear(); break; }
            if (p.rx.size() < 4 + n) break;
            std::string f = p.rx.substr(4, n); p.rx.erase(0, 4 + n);
            if (!OnFrame(i, f)) { removed = true; break; }
        }
        if (removed) continue;
        if (gone) { DropPeer(i, "closed"); continue; }
        i++;
    }
}

void Keepalive() {
    DWORD now = GetTickCount();
    for (size_t i = 0; i < g_peers.size();) {
        Peer& p = g_peers[i];
        if (now - p.lastRx > kTimeoutMs) { DropPeer(i, "timeout"); continue; }
        if (p.id == -1 && p.s == INVALID_SOCKET) { DropPeer(i, "rejected"); continue; }  // Steam: reject already sent
        if (p.welcomed && now - p.lastTx > kKeepaliveMs) SendFrame(p, std::string());
        i++;
    }
}

DWORD WINAPI NetThread(LPVOID) {
    WSADATA w; WSAStartup(MAKEWORD(2, 2), &w);
    Log("net thread up");
    DWORD lastStatus = 0;
    while (!g_quit) {
        std::string batch;
        while (ReadFromLua(batch)) {
            std::string payload;
            for (auto& line : Split(batch, '\n')) {
                if (line.empty()) continue;
                if (line[0] == '!') Command(line); else { payload += line; payload += '\n'; }
            }
            if (!payload.empty()) Broadcast(payload);
        }
        PumpTcp();
        PumpSteam();
        Keepalive();
        DWORD now = GetTickCount();
        if (now - lastStatus > 2000) { lastStatus = now; Status(); }
        FlushToLua();
        Sleep(10);
    }
    WSACleanup();
    return 0;
}

}  // namespace

BOOL APIENTRY DllMain(HMODULE mod, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(mod);
        wchar_t p[MAX_PATH]; GetModuleFileNameW(mod, p, MAX_PATH);
        std::wstring s(p);
        s = s.substr(0, s.find_last_of(L"\\/"));          // ...\Mods\Exit8Together\native
        g_modDir = s.substr(0, s.find_last_of(L"\\/"));    // ...\Mods\Exit8Together
        g_ipcDir = g_modDir + L"\\ipc";
        ClearIpc();
        _wfopen_s(&g_log, (g_modDir + L"\\e8net.log").c_str(), L"w");
        wchar_t ev[32];
        if (GetEnvironmentVariableW(L"E8T_LAG_MS", ev, 32)) g_lagMs = (DWORD)_wtoi(ev);
        if (GetEnvironmentVariableW(L"E8T_JITTER_MS", ev, 32)) g_jitterMs = (DWORD)_wtoi(ev);
        srand(GetTickCount());
        Log("e8net loaded%s", g_lagMs ? " (lab lag emulation on)" : "");
        HANDLE t = CreateThread(nullptr, 0, NetThread, nullptr, 0, nullptr);
        if (t) CloseHandle(t);
    } else if (reason == DLL_PROCESS_DETACH) {
        g_quit = true;
    }
    return TRUE;
}

// Exported so loadlib(path, "e8net_version") can also be used as a presence check.
extern "C" __declspec(dllexport) int e8net_version() { return 1; }

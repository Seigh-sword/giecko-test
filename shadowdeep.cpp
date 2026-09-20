// ============================================================================
//  SHADOWDEEP
//  A single-file roguelike dungeon crawler written in C++17.
//
//  Compile:  g++ -O2 -std=c++17 -o shadowdeep shadowdeep.cpp
//  Run:      ./shadowdeep [--seed N]
//
//  Controls:
//    Arrow keys / hjkl / yubn  - Move (into a monster to attack)
//    g  - pick up item                  i - inventory
//    q  - quaff a potion                r - read a scroll
//    >  - descend stairs                z / .  - wait one turn
//    ?  - help                          Q / Ctrl-D - quit
// ============================================================================

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <queue>
#include <random>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include <unistd.h>
#include <termios.h>
#include <sys/ioctl.h>

// ============================================================================
// SECTION 1 - CONSTANTS
// ============================================================================

namespace sd {

// -- Dungeon viewport size ---------------------------------------------------
constexpr int MAP_W       = 72;
constexpr int MAP_H       = 22;

// -- Gameplay tuning ---------------------------------------------------------
constexpr int FOV_RADIUS  = 9;
constexpr int MAX_DEPTH   = 10;
constexpr int MSG_LINES   = 4;
constexpr int INV_MAX     = 22;
constexpr long long BASE_TURN_ENERGY = 100;

// -- Screen layout -----------------------------------------------------------
constexpr int MAP_COL      = 2;
constexpr int ROW_TITLE    = 0;
constexpr int ROW_STATUS   = 1;
constexpr int ROW_MAP      = 3;
constexpr int ROW_MSG      = ROW_MAP + MAP_H + 1;
constexpr int ROW_HINT     = ROW_MSG + MSG_LINES + 1;
constexpr int TOTAL_ROWS   = ROW_HINT + 2;
constexpr int HINT_COL     = 2;
constexpr int WARN_COLS    = MAP_W + MAP_COL + 4;
constexpr int WARN_ROWS    = TOTAL_ROWS + 2;

// -- Special key codes (positive so they don't collide with chars) -----------
constexpr int KEY_UP       = 1001;
constexpr int KEY_DOWN     = 1002;
constexpr int KEY_LEFT     = 1003;
constexpr int KEY_RIGHT    = 1004;
constexpr int KEY_ESCAPE   = 1005;
constexpr int KEY_NONE     = -1;

// ============================================================================
// SECTION 2 - RANDOM NUMBER GENERATION
// ============================================================================

class RNG {
public:
    RNG() { engine.seed((uint32_t)std::chrono::steady_clock::now().time_since_epoch().count()); }
    explicit RNG(uint32_t seed) { engine.seed(seed); }

    int  range(int lo, int hi) {
        if (hi < lo) std::swap(lo, hi);
        std::uniform_int_distribution<int> d(lo, hi);
        return d(engine);
    }
    int  roll(int sides)     { return range(1, sides); }
    int  roll(int n, int s)  { int t = 0; for (int i=0;i<n;++i) t += range(1,s); return t; }
    bool chance(int percent) { return range(1, 100) <= percent; }
    bool flip()              { return range(0,1) == 1; }
    uint32_t seedValue()     { return (uint32_t)engine(); }

    template<class T>
    const T& pick(const std::vector<T>& v) {
        return v[range(0, (int)v.size() - 1)];
    }

private:
    std::mt19937 engine;
};

// ============================================================================
// SECTION 3 - TERMINAL CONTROL
// ============================================================================

class Terminal {
public:
    Terminal()  = default;
    ~Terminal() { restore(); }

    Terminal(const Terminal&) = delete;
    Terminal& operator=(const Terminal&) = delete;

    // Enter "raw" mode: no echo, no line buffering, no signals.
    void enterRaw() {
        if (raw) return;
        if (!isatty(STDIN_FILENO)) return;

        if (tcgetattr(STDIN_FILENO, &orig) != 0) return;
        struct termios t = orig;
        t.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
        t.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
        t.c_cflag |= CS8;
        t.c_cc[VMIN]  = 0;
        t.c_cc[VTIME] = 0;
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &t);
        raw = true;

        // Hide cursor, clear screen, disable line wrap interactions.
        std::fputs("\033[?25l\033[2J", stdout);
        std::fflush(stdout);
    }

    void restore() {
        if (raw) {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig);
            raw = false;
        }
        std::fputs("\033[?25h\033[0m\033[2J\033[H", stdout);
        std::fflush(stdout);
    }

    // Non-blocking read. Returns KEY_NONE if nothing available.
    int pollKey() {
        unsigned char c;
        if (read(STDIN_FILENO, &c, 1) != 1) return KEY_NONE;

        if (c != 27) return (int)c;

        // Possible escape sequence. Give the terminal a moment to deliver
        // the rest of the bytes.
        struct timespec ts{0, 15 * 1000 * 1000};
        nanosleep(&ts, nullptr);

        unsigned char buf[2];
        int n = (int)read(STDIN_FILENO, buf, 2);
        if (n >= 1 && buf[0] == '[') {
            if (n == 2) {
                switch (buf[1]) {
                    case 'A': return KEY_UP;
                    case 'B': return KEY_DOWN;
                    case 'C': return KEY_RIGHT;
                    case 'D': return KEY_LEFT;
                    default : return KEY_ESCAPE;
                }
            }
            return KEY_ESCAPE;
        }
        return KEY_ESCAPE;
    }

    // Blocking read (used for menu screens).
    int waitKey() {
        for (;;) {
            int k = pollKey();
            if (k != KEY_NONE) return k;
            struct timespec ts{0, 5 * 1000 * 1000};
            nanosleep(&ts, nullptr);
        }
    }

    bool sizeOk() const {
        struct winsize ws;
        if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) != 0) return true;
        return ws.ws_col >= WARN_COLS && ws.ws_row >= WARN_ROWS;
    }

private:
    struct termios orig{};
    bool raw = false;
};

// ============================================================================
// SECTION 4 - COLORS
// ============================================================================

enum class Color : int {
    Default,
    Black, Red, Green, Yellow, Blue, Magenta, Cyan, White,
    Gray,   // bright black
    BrightRed, BrightGreen, BrightYellow,
    BrightBlue, BrightMagenta, BrightCyan, BrightWhite,
    DarkRed, DarkGreen, DarkYellow, DarkBlue,
    Brown, Olive, Gold, Crimson, Steel
};

inline const char* colorCode(Color c) {
    switch (c) {
        case Color::Default:       return "\033[39m";
        case Color::Black:         return "\033[30m";
        case Color::Red:           return "\033[31m";
        case Color::Green:         return "\033[32m";
        case Color::Yellow:        return "\033[33m";
        case Color::Blue:          return "\033[34m";
        case Color::Magenta:       return "\033[35m";
        case Color::Cyan:          return "\033[36m";
        case Color::White:         return "\033[37m";
        case Color::Gray:          return "\033[90m";
        case Color::BrightRed:     return "\033[91m";
        case Color::BrightGreen:   return "\033[92m";
        case Color::BrightYellow:  return "\033[93m";
        case Color::BrightBlue:    return "\033[94m";
        case Color::BrightMagenta: return "\033[95m";
        case Color::BrightCyan:    return "\033[96m";
        case Color::BrightWhite:   return "\033[97m";
        case Color::DarkRed:       return "\033[2;31m";
        case Color::DarkGreen:     return "\033[2;32m";
        case Color::DarkYellow:    return "\033[2;33m";
        case Color::DarkBlue:      return "\033[2;34m";
        case Color::Brown:         return "\033[38;5;130m";
        case Color::Olive:         return "\033[38;5;100m";
        case Color::Gold:          return "\033[38;5;220m";
        case Color::Crimson:       return "\033[38;5;160m";
        case Color::Steel:         return "\033[38;5;246m";
    }
    return "\033[0m";
}

inline const char* RESET() { return "\033[0m"; }
inline const char* BOLD()  { return "\033[1m"; }
inline const char* DIM()   { return "\033[2m"; }

// ============================================================================
// SECTION 5 - BASIC GEOMETRY
// ============================================================================

struct Vec2 {
    int x = 0, y = 0;
    Vec2() = default;
    Vec2(int x_, int y_) : x(x_), y(y_) {}

    Vec2  operator+(const Vec2& o) const { return {x + o.x, y + o.y}; }
    Vec2  operator-(const Vec2& o) const { return {x - o.x, y - o.y}; }
    Vec2  operator*(int k)         const { return {x * k, y * k}; }
    Vec2& operator+=(const Vec2& o)      { x += o.x; y += o.y; return *this; }

    bool operator==(const Vec2& o) const { return x == o.x && y == o.y; }
    bool operator!=(const Vec2& o) const { return !(*this == o); }
    bool operator< (const Vec2& o) const {
        return y != o.y ? y < o.y : x < o.x;
    }

    int chebyshev(const Vec2& o) const {
        return std::max(std::abs(x - o.x), std::abs(y - o.y));
    }
    int manhattan(const Vec2& o) const {
        return std::abs(x - o.x) + std::abs(y - o.y);
    }
    int lengthSq() const { return x * x + y * y; }
    int sign(int v) { return (v > 0) - (v < 0); }
    Vec2 normalizedStep() const {
        return { (x > 0) - (x < 0), (y > 0) - (y < 0) };
    }
};

const Vec2 DIRS8[8] = {
    {-1,-1}, { 0,-1}, { 1,-1},
    {-1, 0},          { 1, 0},
    {-1, 1}, { 0, 1}, { 1, 1}
};

const Vec2 DIRS4[4] = { { 0,-1}, { 1, 0}, { 0, 1}, {-1, 0} };

// ============================================================================
// SECTION 6 - TILES, RECT, DUNGEON
// ============================================================================

enum class Tile : uint8_t {
    Wall,
    Floor,
    Corridor,
    Door,
    StairsDown,
    StairsUp,
    Rubble
};

struct Rect {
    int x = 0, y = 0, w = 0, h = 0;

    int  centerX() const { return x + w / 2; }
    int  centerY() const { return y + h / 2; }
    Vec2 center()  const { return { x + w / 2, y + h / 2 }; }

    bool contains(Vec2 p) const {
        return p.x >= x && p.x < x + w && p.y >= y && p.y < y + h;
    }
    bool intersects(const Rect& o, int pad = 0) const {
        return !(x + w + pad <= o.x ||
                 o.x + o.w + pad <= x ||
                 y + h + pad <= o.y ||
                 o.y + o.h + pad <= y);
    }
};

// ---------------------------------------------------------------------------
// The map: static geometry here, dynamic entities live in the Game class.
// ---------------------------------------------------------------------------
class Dungeon {
public:
    Tile tiles[MAP_H][MAP_W];
    bool explored[MAP_H][MAP_W];
    bool visible [MAP_H][MAP_W];

    std::vector<Rect> rooms;
    Vec2 startPos{-1, -1};
    Vec2 stairsDownPos{-1, -1};
    Vec2 stairsUpPos{-1, -1};
    int  depth = 1;

    Dungeon() { clear(); }

    void clear() {
        for (int y = 0; y < MAP_H; ++y) {
            for (int x = 0; x < MAP_W; ++x) {
                tiles   [y][x] = Tile::Wall;
                explored[y][x] = false;
                visible [y][x] = false;
            }
        }
        rooms.clear();
        startPos = stairsDownPos = stairsUpPos = {-1, -1};
    }

    bool inBounds(int x, int y) const {
        return x >= 0 && x < MAP_W && y >= 0 && y < MAP_H;
    }
    bool inBounds(Vec2 p)  const { return inBounds(p.x, p.y); }

    Tile at(int x, int y) const { return tiles[y][x]; }
    Tile at(Vec2 p)       const { return tiles[p.y][p.x]; }

    void set(int x, int y, Tile t) { tiles[y][x] = t; }
    void set(Vec2 p, Tile t)       { tiles[p.y][p.x] = t; }

    // Hard walls block sight. Doors block sight but not movement.
    bool blocksSight(int x, int y) const {
        Tile t = tiles[y][x];
        return t == Tile::Wall || t == Tile::Rubble;
    }
    bool blocksSight(Vec2 p) const { return blocksSight(p.x, p.y); }

    bool blocksMove(int x, int y) const {
        return tiles[y][x] == Tile::Wall;
    }
    bool blocksMove(Vec2 p) const { return blocksMove(p.x, p.y); }

    bool isWalkable(int x, int y) const { return !blocksMove(x, y); }
    bool isWalkable(Vec2 p)       const { return !blocksMove(p); }

    // ---- generation --------------------------------------------------------
    void generate(int d, RNG& rng);
    void computeFOV(Vec2 origin);

private:
    void carveH(int x1, int x2, int y);
    void carveV(int y1, int y2, int x);
    void raycast(Vec2 from, Vec2 to);
    void connectRooms(Rect& a, Rect& b, RNG& rng);
    void placeDoors(RNG& rng);
};

// ---------------------------------------------------------------------------
void Dungeon::carveH(int x1, int x2, int y) {
    if (x1 > x2) std::swap(x1, x2);
    for (int x = x1; x <= x2; ++x)
        if (inBounds(x, y) && tiles[y][x] == Tile::Wall)
            tiles[y][x] = Tile::Corridor;
}

void Dungeon::carveV(int y1, int y2, int x) {
    if (y1 > y2) std::swap(y1, y2);
    for (int y = y1; y <= y2; ++y)
        if (inBounds(x, y) && tiles[y][x] == Tile::Wall)
            tiles[y][x] = Tile::Corridor;
}

// ---------------------------------------------------------------------------
void Dungeon::connectRooms(Rect& a, Rect& b, RNG& rng) {
    Vec2 p = a.center();
    Vec2 q = b.center();

    bool horizontalFirst = rng.flip();
    if (horizontalFirst) {
        carveH(p.x, q.x, p.y);
        carveV(p.y, q.y, q.x);
    } else {
        carveV(p.y, q.y, p.x);
        carveH(p.x, q.x, q.y);
    }
}

// ---------------------------------------------------------------------------
void Dungeon::placeDoors(RNG& rng) {
    // A door is a corridor cell that has exactly two opposite corridor
    // neighbours, and at least one adjacent "floor" cell (a room).
    for (int y = 1; y < MAP_H - 1; ++y) {
        for (int x = 1; x < MAP_W - 1; ++x) {
            if (tiles[y][x] != Tile::Corridor) continue;
            if (!rng.chance(18)) continue;

            int horiz = 0, vert = 0;
            if (tiles[y][x-1] == Tile::Corridor) horiz++;
            if (tiles[y][x+1] == Tile::Corridor) horiz++;
            if (tiles[y-1][x] == Tile::Corridor) vert++;
            if (tiles[y+1][x] == Tile::Corridor) vert++;

            bool isPassage = (horiz == 2 && vert == 0) ||
                             (vert == 2 && horiz == 0);
            if (!isPassage) continue;

            bool touchesRoom = false;
            for (auto& d : DIRS4) {
                int nx = x + d.x, ny = y + d.y;
                if (inBounds(nx, ny) && tiles[ny][nx] == Tile::Floor)
                    touchesRoom = true;
            }
            if (touchesRoom) tiles[y][x] = Tile::Door;
        }
    }
}

// ---------------------------------------------------------------------------
void Dungeon::generate(int d, RNG& rng) {
    clear();
    depth = d;

    // --- Room selection -----------------------------------------------------
    int targetRooms = 9 + rng.range(0, 6) + depth / 3;
    int maxAttempts = targetRooms * 25;

    for (int i = 0; i < maxAttempts && (int)rooms.size() < targetRooms; ++i) {
        int w = rng.range(5, 13);
        int h = rng.range(3, 7);
        if (w > MAP_W - 4) w = MAP_W - 4;
        if (h > MAP_H - 4) h = MAP_H - 4;

        int x = rng.range(1, MAP_W - w - 2);
        int y = rng.range(1, MAP_H - h - 2);

        Rect candidate{x, y, w, h};
        bool ok = true;
        for (auto& other : rooms) {
            if (candidate.intersects(other, 1)) { ok = false; break; }
        }
        if (ok) rooms.push_back(candidate);
    }

    // --- Carve the rooms ----------------------------------------------------
    for (auto& r : rooms) {
        for (int y = r.y; y < r.y + r.h; ++y)
            for (int x = r.x; x < r.x + r.w; ++x)
                tiles[y][x] = Tile::Floor;
    }

    // --- Connect rooms (chain + a few extras for loops) ---------------------
    for (size_t i = 1; i < rooms.size(); ++i)
        connectRooms(rooms[i - 1], rooms[i], rng);

    int extras = 2 + rng.range(0, 3);
    for (int k = 0; k < extras && rooms.size() > 3; ++k) {
        int i = rng.range(0, (int)rooms.size() - 1);
        int j = rng.range(0, (int)rooms.size() - 1);
        if (i == j) continue;
        connectRooms(rooms[i], rooms[j], rng);
    }

    // --- Corridor rubble for flavour ----------------------------------------
    int rubbleCount = rng.range(3, 8);
    for (int i = 0; i < rubbleCount; ++i) {
        int x = rng.range(1, MAP_W - 2);
        int y = rng.range(1, MAP_H - 2);
        if (tiles[y][x] == Tile::Corridor || tiles[y][x] == Tile::Floor)
            if (rng.chance(30)) tiles[y][x] = Tile::Rubble;
    }

    // --- Doors --------------------------------------------------------------
    placeDoors(rng);

    // --- Stairs -------------------------------------------------------------
    if (rooms.empty()) {
        // Fallback: a small open space so the game doesn't crash.
        Rect r{2, 2, 8, 6};
        rooms.push_back(r);
        for (int y = r.y; y < r.y + r.h; ++y)
            for (int x = r.x; x < r.x + r.w; ++x)
                tiles[y][x] = Tile::Floor;
    }

    startPos    = rooms.front().center();
    stairsUpPos = startPos;
    stairsDownPos = rooms.back().center();

    // Make sure start != stairs down
    if (rooms.size() == 1) stairsDownPos = { startPos.x + 1, startPos.y };

    set(startPos, Tile::Floor);
    if (d > 1) set(stairsUpPos, Tile::StairsUp);
    set(stairsDownPos, Tile::StairsDown);

    computeFOV(startPos);
}

// ---------------------------------------------------------------------------
// Bresenham-based per-cell visibility. Simple and accurate enough.
// ---------------------------------------------------------------------------
void Dungeon::raycast(Vec2 from, Vec2 to) {
    int x0 = from.x, y0 = from.y;
    int x1 = to.x,   y1 = to.y;

    int dx = std::abs(x1 - x0);
    int dy = -std::abs(y1 - y0);
    int sx = x0 < x1 ? 1 : -1;
    int sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;

    int x = x0, y = y0;
    bool first = true;

    for (;;) {
        if (inBounds(x, y)) {
            visible [y][x] = true;
            explored[y][x] = true;
        }
        if (x == x1 && y == y1) break;

        // Stop the ray on a sight-blocking tile (but mark it as seen first).
        if (!first && inBounds(x, y) && blocksSight(x, y)) break;
        first = false;

        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x += sx; }
        if (e2 <= dx) { err += dx; y += sy; }
    }
}

void Dungeon::computeFOV(Vec2 origin) {
    for (int y = 0; y < MAP_H; ++y)
        for (int x = 0; x < MAP_W; ++x)
            visible[y][x] = false;

    if (!inBounds(origin)) return;

    visible [origin.y][origin.x] = true;
    explored[origin.y][origin.x] = true;

    int r2 = FOV_RADIUS * FOV_RADIUS;
    for (int dy = -FOV_RADIUS; dy <= FOV_RADIUS; ++dy) {
        for (int dx = -FOV_RADIUS; dx <= FOV_RADIUS; ++dx) {
            if (dx * dx + dy * dy > r2) continue;
            raycast(origin, { origin.x + dx, origin.y + dy });
        }
    }
}

// ============================================================================
// SECTION 7 - ITEM DEFINITIONS
// ============================================================================

enum class ItemKind {
    None,
    PotionHeal,
    PotionStrength,
    PotionSpeed,
    PotionRejuvenate,
    Weapon,
    Armor,
    Gold,
    Food,
    ScrollLightning,
    ScrollFireball,
    ScrollTeleport,
    ScrollMagicMap,
    Amulet
};

struct ItemDef {
    ItemKind    kind;
    const char* baseName;
    char        glyph;
    Color       color;
    int         minDepth;
    int         maxDepth;
    int         power;      // weapon damage / armor def / heal / gold hint
    bool        identified; // always true – we pick "flavours" from the depth
};

static const ItemDef ITEM_DEFS[] = {
    // Potions
    { ItemKind::PotionHeal,       "healing potion",         '!', Color::BrightRed,     0, 10,  18, true },
    { ItemKind::PotionStrength,   "potion of strength",     '!', Color::BrightMagenta, 3, 10,   1, true },
    { ItemKind::PotionSpeed,      "potion of haste",        '!', Color::BrightCyan,    4, 10,  60, true },
    { ItemKind::PotionRejuvenate, "potion of rejuvenation", '!', Color::BrightYellow,  6, 10, 100, true },
    // Weapons
    { ItemKind::Weapon,           "dagger",                 '/', Color::Steel,         0,  4,   2, true },
    { ItemKind::Weapon,           "short sword",            '/', Color::Steel,         2, 10,   4, true },
    { ItemKind::Weapon,           "battle axe",             '/', Color::Steel,         4, 10,   6, true },
    { ItemKind::Weapon,           "runed greatsword",       '/', Color::BrightCyan,    6, 10,   9, true },
    // Armor
    { ItemKind::Armor,            "leather armour",         '[', Color::Brown,         0,  4,   1, true },
    { ItemKind::Armor,            "chain mail",             '[', Color::Steel,         3, 10,   3, true },
    { ItemKind::Armor,            "plate armour",           '[', Color::BrightWhite,   5, 10,   5, true },
    { ItemKind::Armor,            "dragon scale mail",      '[', Color::BrightRed,     7, 10,   8, true },
    // Gold – the value is rolled when spawned.
    { ItemKind::Gold,             "pile of gold",           '$', Color::Gold,          0, 10,   0, true },
    // Food
    { ItemKind::Food,             "ration of food",         '%', Color::Brown,         0, 10,   8, true },
    // Scrolls
    { ItemKind::ScrollLightning,  "scroll of lightning",    '?', Color::BrightYellow,  1, 10,  18, true },
    { ItemKind::ScrollFireball,   "scroll of fireball",     '?', Color::BrightRed,     3, 10,  30, true },
    { ItemKind::ScrollTeleport,   "scroll of teleport",     '?', Color::BrightMagenta, 2, 10,   0, true },
    { ItemKind::ScrollMagicMap,   "scroll of magic mapping",'?', Color::BrightCyan,    2, 10,   0, true },
    // The Amulet – the win condition.
    { ItemKind::Amulet,           "Amulet of Shadowdeep",   '"', Color::Gold,         10, 10,   0, true },
};

constexpr int NUM_ITEM_DEFS = sizeof(ITEM_DEFS) / sizeof(ITEM_DEFS[0]);

// ============================================================================
// SECTION 8 - MONSTER DEFINITIONS
// ============================================================================

struct MonsterDef {
    const char* name;
    char        glyph;
    Color       color;
    int         hpBase;
    int         hpRoll;    // hp = hpBase + rng.range(0,hpRoll)
    int         atk;
    int         def;
    int         xp;
    int         minDepth;
    int         maxDepth;
    const char* attackVerb;
    const char* deathMsg;
    int         speed;     // energy per turn; 100 = average
    bool        erratic;   // moves randomly instead of pursuing
};

static const MonsterDef MONSTER_DEFS[] = {
    { "giant rat",       'r', Color::Brown,         4,   2,  2,  0,   3,  1, 4, "bites",         "The giant rat dies.",            100, false },
    { "cave bat",        'b', Color::Gray,          3,   2,  2,  0,   4,  1, 5, "bites",         "The cave bat falls still.",      150, true  },
    { "kobold",          'k', Color::Olive,         7,   3,  3,  0,   6,  1, 5, "stabs",         "The kobold collapses.",          100, false },
    { "goblin",          'g', Color::DarkGreen,    11,   4,  4,  1,  10,  2, 6, "slashes",       "The goblin drops dead.",         100, false },
    { "giant spider",    'x', Color::Magenta,       9,   3,  4,  0,  12,  2, 6, "bites",         "The spider curls up and dies.",  110, false },
    { "skeleton",        's', Color::BrightWhite,  16,   5,  5,  2,  18,  3, 7, "claws",         "The skeleton crumbles to dust.", 100, false },
    { "zombie",          'z', Color::DarkGreen,    22,   8,  6,  1,  22,  3, 8, "smashes",       "The zombie collapses.",           70, false },
    { "orc",             'o', Color::Green,        26,   8,  7,  3,  30,  4, 9, "hacks",         "The orc falls with a howl.",     100, false },
    { "ogre",            'O', Color::Brown,        40,  10, 10,  4,  48,  5, 9, "crushes",       "The ogre topples like a tree.",   80, false },
    { "wraith",          'w', Color::BrightCyan,   30,   6, 11,  5,  60,  6, 10,"drains",        "The wraith fades into mist.",    120, false },
    { "vampire",         'V', Color::BrightRed,    46,  10, 12,  5,  85,  6, 10,"bites",         "The vampire recoils and melts.", 110, false },
    { "troll",           'T', Color::DarkGreen,    65,  15, 14,  7, 110,  7, 10,"rends",         "The troll slumps, defeated.",     80, false },
    { "demon",           'd', Color::BrightRed,    80,  15, 17,  9, 160,  8, 10,"claws",         "The demon is banished!",         100, false },
    // The final boss.
    { "ancient dragon",  'D', Color::BrightYellow,240,  40, 26, 13, 800, 10, 10,"incinerates",   "The dragon crashes down dead!",   90, false },
};

constexpr int NUM_MONSTER_DEFS = sizeof(MONSTER_DEFS) / sizeof(MONSTER_DEFS[0]);

// ============================================================================
// SECTION 9 - ENTITIES
// ============================================================================

struct Item {
    ItemKind    kind   = ItemKind::None;
    std::string name;
    char        glyph  = '?';
    Color       color  = Color::Default;
    int         power  = 0;      // weapon dmg / armour def / heal amount / gold charge
    Vec2        pos;
};

struct Monster {
    std::string name;
    char        glyph  = '?';
    Color       color  = Color::Default;
    Vec2        pos;
    int         hp     = 1;
    int         maxHp  = 1;
    int         atk    = 1;
    int         def    = 0;
    int         xp     = 1;
    int         speed  = 100;
    int         energy = 0;
    std::string attackVerb = "hits";
    std::string deathMsg   = "dies.";
    bool        alive   = true;
    bool        aware   = false;
    bool        erratic = false;
    bool        boss    = false;
};

struct Player {
    Vec2 pos;
    int  hp         = 30;
    int  maxHp      = 30;
    int  baseAtk    = 4;
    int  baseDef    = 0;
    int  strength   = 0;   // bonus from PotionStrength
    int  level      = 1;
    int  xp         = 0;
    int  xpNext     = 15;
    int  gold       = 0;
    int  energy     = 0;   // for haste
    int  speed      = 100;
    long long turns = 0;

    // Equipment – kept separate from the inventory vector.
    std::string weaponName = "bare fists";
    int         weaponPower = 0;
    std::string armorName  = "no armour";
    int         armorPower = 0;

    bool hasAmulet = false;

    // The pack.
    std::vector<Item> inventory;

    int attackPower()  const { return baseAtk + weaponPower + strength; }
    int defensePower() const { return baseDef + armorPower; }
    int xpNeeded()     const { return xpNext; }

    void gainXP(int amount) {
        xp += amount;
        while (xp >= xpNext) {
            xp -= xpNext;
            level++;
            maxHp += 6;
            hp = maxHp;
            baseAtk += 1;
            xpNext = (int)(xpNext * 1.65) + 10;
        }
    }
};

// ============================================================================
// SECTION 10 - SCREEN CELL & RENDER BUFFER
// ============================================================================

struct Cell {
    char  ch   = ' ';
    Color fg   = Color::Default;
    bool  bold = false;
};

// ============================================================================
// SECTION 11 - THE GAME
// ============================================================================

class Game {
public:
    Game();
    int  run(int argc, char** argv);

private:
    // ---- core state --------------------------------------------------------
    Terminal  term;
    mutable RNG       rng;
    Dungeon   dungeon;
    Player    player;

    std::vector<Monster> monsters;
    std::vector<Item>    groundItems;

    struct Message { std::string text; Color color; bool bold = false; };
    std::vector<Message> messageLog;

    int      depth      = 1;
    bool     running    = true;
    bool     playerDead = false;
    bool     playerWon  = false;
    int      totalMonstersKilled = 0;
    long long totalGoldEarned    = 0;
    long long startTimeMs        = 0;

    // ---- render buffer -----------------------------------------------------
    Cell screen[TOTAL_ROWS][MAP_W + 2 * MAP_COL + 4];

    // ---- menu state --------------------------------------------------------
    bool showingHelp      = false;
    bool showingInventory = false;
    int  invCursor        = 0;
    std::string pendingMenuMessage;

    // ---- lifecycle ---------------------------------------------------------
    void startNewGame();
    void newLevel(int newDepth);
    void mainLoop();

    // ---- turns -------------------------------------------------------------
    bool processPlayerAction();
    void endPlayerTurn();
    void takeMonsterTurns();

    // ---- player actions ----------------------------------------------------
    bool movePlayer(int dx, int dy);
    void waitTurn();
    void tryPickup();
    void descendStairs();
    void quaffPotionFromInventory(int idx);
    void readScrollFromInventory(int idx);
    void dropItemFromInventory(int idx);
    bool useInventoryItem(int idx);

    // ---- combat ------------------------------------------------------------
    void playerAttack(Monster& m);
    void monsterAttack(Monster& m);
    void killMonster(Monster& m);
    void damagePlayer(int dmg, Monster* source);
    void healPlayer(int amount);

    // ---- monster AI --------------------------------------------------------
    Monster makeMonster(int defIndex, Vec2 pos);
    void    spawnMonsters();
    void    updateMonster(Monster& m);
    bool    monsterSeesPlayer(const Monster& m) const;
    bool    monsterMoveStep(Monster& m, Vec2 target);
    void    monsterWander(Monster& m);

    // ---- items -------------------------------------------------------------
    Item makeItem(const ItemDef& def, Vec2 pos);
    Item randomItemForDepth(int d, Vec2 pos);
    Item amuletItem(Vec2 pos);
    void spawnItems();
    void pickupItemAt(Vec2 pos);

    // ---- helpers -----------------------------------------------------------
    bool     tileOccupied(Vec2 p) const;
    Monster* monsterAt(Vec2 p);
    Item*    groundItemAt(Vec2 p);
    Vec2     randomFloorCell(RNG& r);
    Vec2     randomFloorFarFrom(Vec2 origin, int minDist);
    bool     adjacent(Vec2 a, Vec2 b) const;
    int      rollWeaponDamage() const;

    // ---- messages ----------------------------------------------------------
    void clearMessages();
    void msg(const std::string& s);
    void msg(const std::string& s, Color c);
    void msg(const std::string& s, Color c, bool bold);
    void msgPlayerHit(const Monster& m, int dmg);
    void msgMonsterHit(const Monster& m, int dmg);

    // ---- rendering ---------------------------------------------------------
    void render();
    void clearScreenBuffer();
    void blit();
    void put(int row, int col, char ch, Color c, bool bold = false);
    void putStr(int row, int col, const std::string& s, Color c, bool bold = false);

    void renderTitle();
    void renderStatus();
    void renderMap();
    void renderMessages();
    void renderHint();
    void renderInventoryOverlay();
    void renderHelpOverlay();
    void renderGameOverOverlay();

    // ---- menus -------------------------------------------------------------
    void runHelpScreen();
    void runInventoryScreen();
    void runDeathScreen();
    void runWinScreen();

    // ---- misc --------------------------------------------------------------
    void  sleepMs(int ms);
    long long nowMs() const;
    std::string formatTime(long long ms) const;
    void  bannerText();
};

// ---------------------------------------------------------------------------
//  Game::Game
// ---------------------------------------------------------------------------
Game::Game() {
    clearScreenBuffer();
}

// ---------------------------------------------------------------------------
//  Timing helpers
// ---------------------------------------------------------------------------
long long Game::nowMs() const {
    return (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

void Game::sleepMs(int ms) {
    struct timespec ts;
    ts.tv_sec  = ms / 1000;
    ts.tv_nsec = (long)((ms % 1000) * 1000000);
    nanosleep(&ts, nullptr);
}

std::string Game::formatTime(long long ms) const {
    long long totalSec = ms / 1000;
    long long min = totalSec / 60;
    long long sec = totalSec % 60;
    char buf[64];
    std::snprintf(buf, sizeof buf, "%lldm %02llds", min, sec);
    return buf;
}

// ---------------------------------------------------------------------------
//  Game::run
// ---------------------------------------------------------------------------
int Game::run(int argc, char** argv) {
    uint32_t seed = 0;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--seed") == 0 && i + 1 < argc)
            seed = (uint32_t)std::strtoul(argv[++i], nullptr, 10);
        else if (std::strcmp(argv[i], "--help") == 0) {
            std::printf("SHADOWDEEP - a terminal roguelike.\n"
                        "Usage: %s [--seed N]\n", argv[0]);
            return 0;
        }
    }

    if (seed) rng = RNG(seed);

    term.enterRaw();
    if (!term.sizeOk()) {
        term.restore();
        std::fprintf(stderr,
            "Please resize your terminal to at least %d columns x %d rows.\n",
            WARN_COLS, WARN_ROWS);
        return 1;
    }

    bannerText();
    startNewGame();
    mainLoop();

    if (playerDead) runDeathScreen();
    else if (playerWon) runWinScreen();

    return 0;
}

// ---------------------------------------------------------------------------
//  Banner
// ---------------------------------------------------------------------------
void Game::bannerText() {
    term.enterRaw();
    std::fputs("\033[2J\033[H", stdout);
    std::printf(
        "\033[1;33m"
        "   ███████╗██╗  ██╗ █████╗ ██████╗  ██████╗ ██╗    ██╗\n"
        "   ██╔════╝██║  ██║██╔══██╗██╔══██╗██╔═══██╗██║    ██║\n"
        "   ███████╗███████║███████║██║  ██║██║   ██║██║ █╗ ██║\n"
        "   ╚════██║██╔══██║██╔══██║██║  ██║██║   ██║██║███╗██║\n"
        "   ███████║██║  ██║██║  ██║██████╔╝╚██████╔╝╚███╔███╔╝\n"
        "   ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝  ╚═════╝  ╚══╝╚══╝ \n"
        "\033[1;32m"
        "               D E E P   ·   a roguelike\n\033[0m"
        "\n"
        "   \033[1;37mDescend 10 levels of the Shadowdeep.\033[0m\n"
        "   \033[1;37mRecover the Amulet. Slay what guards it.\033[0m\n"
        "\n"
        "   \033[90mControls:\033[0m\n"
        "     \033[1;33mArrows / hjkl\033[0m   move  (walk into a monster to attack)\n"
        "     \033[1;33mg\033[0m pick up   \033[1;33mi\033[0m inventory   \033[1;33mq\033[0m quaff   \033[1;33mr\033[0m read\n"
        "     \033[1;33m>\033[0m descend   \033[1;33mz\033[0m wait   \033[1;33m?\033[0m help   \033[1;33mQ\033[0m quit\n"
        "\n"
        "   \033[1;36mPress any key to begin...\033[0m");
    std::fflush(stdout);
    term.waitKey();
}

// ---------------------------------------------------------------------------
//  startNewGame - initialise everything for a fresh run.
// ---------------------------------------------------------------------------
void Game::startNewGame() {
    player = Player{};
    monsters.clear();
    groundItems.clear();
    depth = 1;
    playerDead = false;
    playerWon  = false;
    totalMonstersKilled = 0;
    totalGoldEarned     = 0;
    startTimeMs = nowMs();
    clearMessages();

    // Starter kit.
    Item dagger = makeItem(ITEM_DEFS[4], player.pos);   // dagger
    dagger.name = "dagger";
    dagger.kind = ItemKind::Weapon;
    dagger.power = 2;
    player.inventory.push_back(dagger);
    player.weaponName  = "dagger";
    player.weaponPower = 2;

    Item potion = makeItem(ITEM_DEFS[0], player.pos);
    player.inventory.push_back(potion);
    player.inventory.push_back(potion);

    newLevel(1);

    msg("Welcome to the Shadowdeep.", Color::BrightYellow);
    msg("Find the Amulet on level 10 and escape.", Color::BrightYellow);
}

// ---------------------------------------------------------------------------
//  newLevel - generate fresh dungeon, place player/monsters/items.
// ---------------------------------------------------------------------------
void Game::newLevel(int newDepth) {
    depth = newDepth;
    dungeon.generate(depth, rng);
    player.pos = dungeon.startPos;
    player.energy = 0;
    player.turns++;
    dungeon.computeFOV(player.pos);
    monsters.clear();
    groundItems.clear();

    spawnMonsters();
    spawnItems();
}

// ---------------------------------------------------------------------------
//  MAIN LOOP
// ---------------------------------------------------------------------------
void Game::mainLoop() {
    // Keep the terminal responsive but don't burn CPU.
    while (running && !playerDead && !playerWon) {
        render();

        int k = term.pollKey();
        if (k == KEY_NONE) {
            sleepMs(10);
            continue;
        }

        // ---- quit ---------------------------------------------------------
        if (k == 'Q' || k == 4 /* Ctrl-D */) {
            running = false;
            break;
        }

        // ---- help overlay -------------------------------------------------
        if (k == '?') {
            runHelpScreen();
            continue;
        }

        // ---- inventory overlay --------------------------------------------
        if (k == 'i' || k == 'I') {
            runInventoryScreen();
            continue;
        }

        // ---- movement & actions -------------------------------------------
        bool tookTurn = false;
        switch (k) {
            case KEY_UP:    case 'k': tookTurn = movePlayer( 0, -1); break;
            case KEY_DOWN:  case 'j': tookTurn = movePlayer( 0,  1); break;
            case KEY_LEFT:  case 'h': tookTurn = movePlayer(-1,  0); break;
            case KEY_RIGHT: case 'l': tookTurn = movePlayer( 1,  0); break;
            case 'y': tookTurn = movePlayer(-1, -1); break;
            case 'u': tookTurn = movePlayer( 1, -1); break;
            case 'b': tookTurn = movePlayer(-1,  1); break;
            case 'n': tookTurn = movePlayer( 1,  1); break;

            case 'g': case ',': tryPickup();   tookTurn = true;  break;
            case '>': descendStairs();         tookTurn = false; break;
            case 'z': case '.': waitTurn();    tookTurn = true;  break;

            case 'q': {
                // Quaff the first potion found in the pack.
                for (size_t i = 0; i < player.inventory.size(); ++i) {
                    auto kd = player.inventory[i].kind;
                    if (kd == ItemKind::PotionHeal ||
                        kd == ItemKind::PotionStrength ||
                        kd == ItemKind::PotionSpeed ||
                        kd == ItemKind::PotionRejuvenate) {
                        quaffPotionFromInventory((int)i);
                        tookTurn = true;
                        break;
                    }
                }
                if (!tookTurn) msg("You have no potions to quaff.", Color::Gray);
                break;
            }
            case 'r': {
                for (size_t i = 0; i < player.inventory.size(); ++i) {
                    auto kd = player.inventory[i].kind;
                    if (kd == ItemKind::ScrollLightning ||
                        kd == ItemKind::ScrollFireball ||
                        kd == ItemKind::ScrollTeleport ||
                        kd == ItemKind::ScrollMagicMap) {
                        readScrollFromInventory((int)i);
                        tookTurn = true;
                        break;
                    }
                }
                if (!tookTurn) msg("You have no scrolls to read.", Color::Gray);
                break;
            }

            default:
                break;
        }

        if (tookTurn && !playerDead && !playerWon)
            endPlayerTurn();
    }
}

// ---------------------------------------------------------------------------
//  Turn bookkeeping
// ---------------------------------------------------------------------------
void Game::endPlayerTurn() {
    player.turns++;
    dungeon.computeFOV(player.pos);
    takeMonsterTurns();
    if (player.hp <= 0 && !playerDead) {
        playerDead = true;
    }
}

// ---------------------------------------------------------------------------
void Game::takeMonsterTurns() {
    for (auto& m : monsters) {
        if (!m.alive) continue;
        m.energy += m.speed;
        while (m.energy >= 100 && m.alive && !playerDead) {
            m.energy -= 100;
            updateMonster(m);
        }
    }
}

// ---------------------------------------------------------------------------
//  Player movement / attack
// ---------------------------------------------------------------------------
bool Game::movePlayer(int dx, int dy) {
    Vec2 target = player.pos + Vec2(dx, dy);

    if (!dungeon.inBounds(target)) return false;

    // Attack any monster occupying the target square.
    Monster* m = monsterAt(target);
    if (m) {
        playerAttack(*m);
        return true;
    }

    if (dungeon.blocksMove(target)) {
        // Bumping a wall is not a turn.
        return false;
    }

    // Rubble is passable but slows movement: 50% chance of an extra wait.
    bool rubbleSlow = (dungeon.at(target) == Tile::Rubble) && rng.chance(50);

    player.pos = target;

    // Auto-pickup gold.
    for (auto& item : groundItems) {
        if (item.kind == ItemKind::Gold && item.pos == player.pos) {
            player.gold += item.power;
            totalGoldEarned += item.power;
            std::ostringstream ss;
            ss << "You pick up " << item.power << " gold.";
            msg(ss.str(), Color::Gold);
            item.kind = ItemKind::None; // mark for removal
        }
    }
    groundItems.erase(
        std::remove_if(groundItems.begin(), groundItems.end(),
                       [](const Item& i){ return i.kind == ItemKind::None; }),
        groundItems.end());

    if (rubbleSlow) {
        msg("You stumble over loose rubble.", Color::Gray);
    }

    return true;
}

void Game::waitTurn() {
    // Doing nothing. Recover a tiny bit of hp if very weak.
    if (player.hp < player.maxHp && rng.chance(15))
        healPlayer(1);
}

void Game::tryPickup() {
    Item* it = groundItemAt(player.pos);
    if (!it) {
        msg("There is nothing here to pick up.", Color::Gray);
        return;
    }
    if ((int)player.inventory.size() >= INV_MAX) {
        msg("Your pack is full.", Color::Red);
        return;
    }
    if (it->kind == ItemKind::Amulet) {
        player.hasAmulet = true;
        msg("You grasp the Amulet of Shadowdeep! Its cold light sears your hand.",
            Color::BrightYellow);
        msg("NOW RETURN TO THE SURFACE.", Color::Gold);
    } else {
        std::ostringstream ss;
        ss << "You pick up " << it->name << ".";
        msg(ss.str(), it->color);
    }
    player.inventory.push_back(*it);
    it->kind = ItemKind::None;
    groundItems.erase(
        std::remove_if(groundItems.begin(), groundItems.end(),
                       [](const Item& i){ return i.kind == ItemKind::None; }),
        groundItems.end());
}

void Game::descendStairs() {
    if (dungeon.at(player.pos) != Tile::StairsDown) {
        msg("There are no stairs here.", Color::Gray);
        return;
    }
    if (player.hasAmulet && depth == MAX_DEPTH) {
        playerWon = true;
        return;
    }
    if (depth >= MAX_DEPTH) {
        msg("There are no more stairs to descend. You have reached the bottom.",
            Color::Gray);
        return;
    }
    depth++;
    newLevel(depth);
    std::ostringstream ss;
    ss << "You descend to level " << depth << ".";
    msg(ss.str(), Color::BrightYellow);
    if (depth == MAX_DEPTH)
        msg("A vast heat washes over you. Something enormous stirs nearby...",
            Color::BrightRed, /*bold*/ true);
}

// ---------------------------------------------------------------------------
//  Player combat
// ---------------------------------------------------------------------------
int Game::rollWeaponDamage() const {
    int base = player.attackPower();
    int dmg  = rng.range(std::max(1, base - 1), base + 2);
    if (rng.chance(15)) dmg *= 2; // critical hit
    return dmg;
}

void Game::playerAttack(Monster& m) {
    int dmg = rollWeaponDamage() - m.def;
    bool crit = (dmg > player.attackPower() + 2);
    if (dmg < 1) dmg = 1;

    m.hp -= dmg;
    m.aware = true;

    std::ostringstream ss;
    ss << "You hit the " << m.name << " for " << dmg << " damage";
    if (crit) ss << " (critical!)";
    ss << ".";
    msg(ss.str(), crit ? Color::BrightYellow : Color::White);

    if (m.hp <= 0) killMonster(m);
}

void Game::killMonster(Monster& m) {
    m.alive = false;
    totalMonstersKilled++;

    msg(m.deathMsg, Color::Green);
    msg("You gain " + std::to_string(m.xp) + " XP.", Color::Gray);

    int oldLevel = player.level;
    player.gainXP(m.xp);
    if (player.level > oldLevel) {
        std::ostringstream ss;
        ss << "You feel stronger! Welcome to level " << player.level << ".";
        msg(ss.str(), Color::BrightYellow);
    }

    // Occasionally drop loot.
    int dropChance = 20;
    if (m.boss) dropChance = 100;
    if (rng.chance(dropChance)) {
        Item it = randomItemForDepth(depth, m.pos);
        groundItems.push_back(it);
        msg("The " + m.name + " was carrying " + it.name + "!",
            Color::BrightMagenta);
    } else if (rng.chance(30)) {
        Item gold = makeItem(ITEM_DEFS[12], m.pos);
        gold.power = rng.range(2, 6 + depth * 2);
        groundItems.push_back(gold);
    }
}

void Game::monsterAttack(Monster& m) {
    // Player defense reduces incoming damage. There is always at least 1.
    int dmg = rng.range(1, m.atk) - player.defensePower();
    if (dmg < 1) dmg = 1;

    std::ostringstream ss;
    ss << "The " << m.name << " " << m.attackVerb << " you for "
       << dmg << " damage!";
    msg(ss.str(), Color::Red);

    damagePlayer(dmg, &m);
}

void Game::damagePlayer(int dmg, Monster* src) {
    player.hp -= dmg;
    if (player.hp <= 0) {
        player.hp = 0;
        playerDead = true;
        std::ostringstream ss;
        if (src) ss << "You are slain by the " << src->name << "!";
        else     ss << "You die.";
        msg(ss.str(), Color::BrightRed);
    }
}

void Game::healPlayer(int amount) {
    player.hp += amount;
    if (player.hp > player.maxHp) player.hp = player.maxHp;
}

// ---------------------------------------------------------------------------
//  Monster construction
// ---------------------------------------------------------------------------
Monster Game::makeMonster(int defIndex, Vec2 pos) {
    const MonsterDef& d = MONSTER_DEFS[defIndex];
    Monster m;
    m.name        = d.name;
    m.glyph       = d.glyph;
    m.color       = d.color;
    m.pos         = pos;
    m.hp          = d.hpBase + rng.range(0, d.hpRoll);
    m.maxHp       = m.hp;
    m.atk         = d.atk;
    m.def         = d.def;
    m.xp          = d.xp;
    m.speed       = d.speed;
    m.attackVerb  = d.attackVerb;
    m.deathMsg    = d.deathMsg;
    m.erratic     = d.erratic;
    m.boss        = (std::strcmp(d.name, "ancient dragon") == 0);
    return m;
}

void Game::spawnMonsters() {
    int baseCount = 5 + depth + rng.range(0, 4);
    int placed    = 0;
    int maxIter   = baseCount * 40;

    std::vector<int> eligible;
    for (int i = 0; i < NUM_MONSTER_DEFS; ++i) {
        const auto& d = MONSTER_DEFS[i];
        if (depth >= d.minDepth && depth <= d.maxDepth) {
            // The dragon only appears on level 10 and only once.
            if (d.minDepth == 10 && d.maxDepth == 10) {
                if (depth == MAX_DEPTH) eligible.push_back(i);
            } else {
                eligible.push_back(i);
            }
        }
    }
    if (eligible.empty()) return;

    // Weight selection toward lower-tier monsters at shallow depths.
    auto chooseDef = [&]() -> int {
        // Just pick uniformly from eligible; simple and OK.
        return eligible[rng.range(0, (int)eligible.size() - 1)];
    };

    bool bossSpawned = false;

    for (int i = 0; i < maxIter && placed < baseCount; ++i) {
        Vec2 p = randomFloorCell(rng);
        if (p.manhattan(dungeon.startPos) < 8) continue;   // give player room
        if (tileOccupied(p)) continue;

        int defIdx = chooseDef();
        bool isBoss = (MONSTER_DEFS[defIdx].minDepth == MAX_DEPTH &&
                       MONSTER_DEFS[defIdx].maxDepth == MAX_DEPTH);
        if (isBoss) {
            if (bossSpawned) continue;
            bossSpawned = true;
        }
        monsters.push_back(makeMonster(defIdx, p));
        placed++;
    }

    // Last level: always ensure the dragon shows up.
    if (depth == MAX_DEPTH && !bossSpawned) {
        for (int i = 0; i < NUM_MONSTER_DEFS; ++i) {
            if (std::strcmp(MONSTER_DEFS[i].name, "ancient dragon") == 0) {
                Vec2 p = dungeon.stairsDownPos;
                // Any free cell close to stairs.
                for (auto& d : DIRS8) {
                    Vec2 q = p + d;
                    if (dungeon.inBounds(q) && dungeon.isWalkable(q) &&
                        !tileOccupied(q)) {
                        monsters.push_back(makeMonster(i, q));
                        break;
                    }
                }
                break;
            }
        }
    }
}

// ---------------------------------------------------------------------------
//  Monster AI
// ---------------------------------------------------------------------------
bool Game::monsterSeesPlayer(const Monster& m) const {
    if (m.pos.manhattan(player.pos) > 12) return false;

    // Bresenham (copy of Dungeon::raycast, but with the Dungeon visible-by-side)
    int x0 = m.pos.x, y0 = m.pos.y;
    int x1 = player.pos.x, y1 = player.pos.y;
    int dx = std::abs(x1 - x0);
    int dy = -std::abs(y1 - y0);
    int sx = x0 < x1 ? 1 : -1;
    int sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    int x = x0, y = y0;

    for (;;) {
        if (x == x1 && y == y1) return true;
        if (!(x == x0 && y == y0) && dungeon.blocksSight(x, y)) return false;

        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x += sx; }
        if (e2 <= dx) { err += dx; y += sy; }
    }
}

bool Game::monsterMoveStep(Monster& m, Vec2 target) {
    // Greedy: pick the adjacent free square closest to the target.
    Vec2 best = m.pos;
    int  bestDist = m.pos.manhattan(target);

    for (auto& d : DIRS8) {
        Vec2 p = m.pos + d;
        if (!dungeon.inBounds(p)) continue;
        if (dungeon.blocksMove(p)) continue;
        if (p == player.pos) continue;             // can't walk into the player
        if (tileOccupied(p)) continue;
        int dist = p.manhattan(target);
        if (dist < bestDist) {
            bestDist = dist;
            best = p;
        }
    }
    if (best == m.pos) return false;
    m.pos = best;
    return true;
}

void Game::monsterWander(Monster& m) {
    for (int attempt = 0; attempt < 4; ++attempt) {
        Vec2 d = DIRS4[rng.range(0, 3)];
        Vec2 p = m.pos + d;
        if (!dungeon.inBounds(p)) continue;
        if (dungeon.blocksMove(p)) continue;
        if (p == player.pos) continue;
        if (tileOccupied(p)) continue;
        m.pos = p;
        return;
    }
}

void Game::updateMonster(Monster& m) {
    if (!m.alive) return;

    // Awareness check.
    if (!m.aware && monsterSeesPlayer(m)) {
        m.aware = true;
        std::ostringstream ss;
        ss << "The " << m.name << " notices you!";
        msg(ss.str(), Color::Yellow);
    }

    // If adjacent, attack.
    if (adjacent(m.pos, player.pos)) {
        monsterAttack(m);
        return;
    }

    // Otherwise pursue or wander.
    if (m.aware && !m.erratic) {
        monsterMoveStep(m, player.pos);
    } else if (m.erratic) {
        // Bats: 50 % chance move toward player, else random.
        if (m.aware && rng.chance(50)) monsterMoveStep(m, player.pos);
        else                            monsterWander(m);
    } else {
        // Unaware – occasional random shuffle.
        if (rng.chance(25)) monsterWander(m);
    }
}

// ---------------------------------------------------------------------------
//  Items
// ---------------------------------------------------------------------------
Item Game::makeItem(const ItemDef& def, Vec2 pos) {
    Item it;
    it.kind  = def.kind;
    it.name  = def.baseName;
    it.glyph = def.glyph;
    it.color = def.color;
    it.power = def.power;
    it.pos   = pos;

    // Scale some things by depth.
    if (def.kind == ItemKind::Gold)
        it.power = rng.range(4, 8 + depth * 3);

    return it;
}

Item Game::amuletItem(Vec2 pos) {
    Item it;
    it.kind  = ItemKind::Amulet;
    it.name  = "Amulet of Shadowdeep";
    it.glyph = '"';
    it.color = Color::Gold;
    it.power = 0;
    it.pos   = pos;
    return it;
}

Item Game::randomItemForDepth(int d, Vec2 pos) {
    // Roll a category first.
    int roll = rng.range(1, 100);
    ItemKind want;

    if (roll <= 25)      want = ItemKind::PotionHeal;
    else if (roll <= 34) want = ItemKind::PotionStrength;
    else if (roll <= 39) want = ItemKind::PotionSpeed;
    else if (roll <= 41) want = ItemKind::PotionRejuvenate;
    else if (roll <= 55) want = ItemKind::Weapon;
    else if (roll <= 63) want = ItemKind::Armor;
    else if (roll <= 72) want = ItemKind::Food;
    else if (roll <= 81) want = ItemKind::ScrollLightning;
    else if (roll <= 88) want = ItemKind::ScrollFireball;
    else if (roll <= 92) want = ItemKind::ScrollTeleport;
    else if (roll <= 97) want = ItemKind::ScrollMagicMap;
    else                 want = ItemKind::Gold;

    // Gather matching defs whose depth window includes d.
    std::vector<int> matches;
    for (int i = 0; i < NUM_ITEM_DEFS; ++i) {
        const auto& def = ITEM_DEFS[i];
        if (def.kind != want) continue;
        if (d < def.minDepth || d > def.maxDepth) continue;
        matches.push_back(i);
    }
    if (matches.empty()) {
        // Fall back to a healing potion.
        for (int i = 0; i < NUM_ITEM_DEFS; ++i)
            if (ITEM_DEFS[i].kind == ItemKind::PotionHeal)
                return makeItem(ITEM_DEFS[i], pos);
    }
    return makeItem(ITEM_DEFS[matches[rng.range(0, (int)matches.size() - 1)]], pos);
}

void Game::spawnItems() {
    int count = 4 + rng.range(0, 5) + depth / 2;
    for (int i = 0; i < count; ++i) {
        Vec2 p = randomFloorCell(rng);
        if (tileOccupied(p)) continue;
        if (groundItemAt(p))  continue;
        if (p == dungeon.startPos || p == dungeon.stairsDownPos) continue;

        Item it = randomItemForDepth(depth, p);
        groundItems.push_back(it);
    }

    // On the deepest level, place the Amulet.
    if (depth == MAX_DEPTH && !player.hasAmulet) {
        Vec2 p = dungeon.stairsDownPos;
        // Put the amulet adjacent to the down-stairs cell.
        for (auto& d : DIRS8) {
            Vec2 q = p + d;
            if (dungeon.inBounds(q) && dungeon.isWalkable(q) &&
                !tileOccupied(q)) {
                groundItems.push_back(amuletItem(q));
                break;
            }
        }
    }
}

void Game::pickupItemAt(Vec2 pos) {
    // Handled inline in movePlayer; this function exists for clarity.
    (void)pos;
}

// ---------------------------------------------------------------------------
//  Using items
// ---------------------------------------------------------------------------
void Game::quaffPotionFromInventory(int idx) {
    if (idx < 0 || idx >= (int)player.inventory.size()) return;
    Item it = player.inventory[idx];
    player.inventory.erase(player.inventory.begin() + idx);

    switch (it.kind) {
        case ItemKind::PotionHeal: {
            int amount = it.power;
            healPlayer(amount);
            std::ostringstream ss;
            ss << "You feel better. (+" << amount << " HP)";
            msg(ss.str(), Color::Green);
            break;
        }
        case ItemKind::PotionStrength: {
            player.strength += 1;
            msg("You feel mightier! (+1 attack)", Color::BrightMagenta);
            break;
        }
        case ItemKind::PotionSpeed: {
            player.speed += 25;
            if (player.speed > 250) player.speed = 250;
            msg("The world slows around you. (haste)", Color::BrightCyan);
            break;
        }
        case ItemKind::PotionRejuvenate: {
            player.hp = player.maxHp;
            player.strength += 2;
            msg("Every wound closes. Power surges through you!",
                Color::BrightYellow);
            break;
        }
        default:
            break;
    }
}

void Game::readScrollFromInventory(int idx) {
    if (idx < 0 || idx >= (int)player.inventory.size()) return;
    Item it = player.inventory[idx];
    player.inventory.erase(player.inventory.begin() + idx);

    switch (it.kind) {
        case ItemKind::ScrollLightning: {
            // Hit strongest visible monster.
            Monster* best = nullptr;
            for (auto& m : monsters) {
                if (!m.alive) continue;
                if (!dungeon.visible[m.pos.y][m.pos.x]) continue;
                if (!best || m.hp > best->hp) best = &m;
            }
            if (!best) {
                msg("A bolt of lightning arcs into nothing.",
                    Color::BrightYellow);
                break;
            }
            int dmg = it.power + player.level * 2;
            best->hp -= dmg;
            best->aware = true;
            std::ostringstream ss;
            ss << "A bolt of lightning strikes the " << best->name
               << " for " << dmg << " damage!";
            msg(ss.str(), Color::BrightYellow);
            if (best->hp <= 0) killMonster(*best);
            else {
                // Blind it – it becomes aware.
            }
            break;
        }
        case ItemKind::ScrollFireball: {
            // Damage every visible monster.
            bool any = false;
            std::vector<Monster*> hits;
            for (auto& m : monsters)
                if (m.alive && dungeon.visible[m.pos.y][m.pos.x])
                    hits.push_back(&m);
            for (auto* m : hits) {
                int dmg = it.power + player.level * 2;
                m->hp -= dmg;
                m->aware = true;
                any = true;
                std::ostringstream ss;
                ss << "A ball of fire engulfs the " << m->name
                   << " for " << dmg << " damage!";
                msg(ss.str(), Color::BrightRed);
                if (m->hp <= 0) killMonster(*m);
            }
            if (!any) msg("The fireball fizzles harmlessly.", Color::Gray);
            break;
        }
        case ItemKind::ScrollTeleport: {
            Vec2 p;
            int tries = 0;
            do {
                p = randomFloorCell(rng);
            } while (tileOccupied(p) && ++tries < 200);
            player.pos = p;
            dungeon.computeFOV(player.pos);
            msg("You are wrenched through space!", Color::BrightMagenta);
            break;
        }
        case ItemKind::ScrollMagicMap: {
            for (int y = 0; y < MAP_H; ++y)
                for (int x = 0; x < MAP_W; ++x)
                    dungeon.explored[y][x] = true;
            msg("The map of this level unfolds in your mind.",
                Color::BrightCyan);
            break;
        }
        default:
            break;
    }
}

void Game::dropItemFromInventory(int idx) {
    if (idx < 0 || idx >= (int)player.inventory.size()) return;
    Item it = player.inventory[idx];
    player.inventory.erase(player.inventory.begin() + idx);
    it.pos = player.pos;
    groundItems.push_back(it);
    msg("You drop the " + it.name + ".", Color::Gray);
}

bool Game::useInventoryItem(int idx) {
    if (idx < 0 || idx >= (int)player.inventory.size()) return false;
    Item it = player.inventory[idx];

    switch (it.kind) {
        case ItemKind::PotionHeal:
        case ItemKind::PotionStrength:
        case ItemKind::PotionSpeed:
        case ItemKind::PotionRejuvenate:
            quaffPotionFromInventory(idx);
            return true;

        case ItemKind::ScrollLightning:
        case ItemKind::ScrollFireball:
        case ItemKind::ScrollTeleport:
        case ItemKind::ScrollMagicMap:
            readScrollFromInventory(idx);
            return true;

        case ItemKind::Weapon: {
            // Swap with current weapon.
            Item old {
                ItemKind::Weapon,
                player.weaponName == "bare fists" ? "no weapon" : player.weaponName,
                '/', Color::Steel, player.weaponPower, player.pos
            };
            std::string newName = it.name;
            int newPower = it.power;
            player.weaponName  = newName;
            player.weaponPower = newPower;
            player.inventory.erase(player.inventory.begin() + idx);
            if (old.power > 0) player.inventory.push_back(old);
            msg("You wield the " + newName + ".", Color::BrightCyan);
            return true;
        }
        case ItemKind::Armor: {
            Item old {
                ItemKind::Armor,
                player.armorName == "no armour" ? "no armour" : player.armorName,
                '[', Color::Brown, player.armorPower, player.pos
            };
            std::string newName = it.name;
            int newPower = it.power;
            player.armorName  = newName;
            player.armorPower = newPower;
            player.inventory.erase(player.inventory.begin() + idx);
            if (old.power > 0) player.inventory.push_back(old);
            msg("You don the " + newName + ".", Color::BrightCyan);
            return true;
        }
        case ItemKind::Food: {
            int heal = it.power;
            healPlayer(heal);
            player.inventory.erase(player.inventory.begin() + idx);
            std::ostringstream ss;
            ss << "You eat the " << it.name << ". (+" << heal << " HP)";
            msg(ss.str(), Color::Green);
            return true;
        }

        case ItemKind::Amulet:
            msg("The Amulet whispers: return to the surface!",
                Color::BrightYellow);
            return false;

        case ItemKind::Gold:
            msg("You put the gold in your purse.", Color::Gold);
            player.gold += it.power;
            totalGoldEarned += it.power;
            player.inventory.erase(player.inventory.begin() + idx);
            return true;

        default:
            return false;
    }
}

// ---------------------------------------------------------------------------
//  Small helpers
// ---------------------------------------------------------------------------
bool Game::adjacent(Vec2 a, Vec2 b) const {
    return std::abs(a.x - b.x) <= 1 && std::abs(a.y - b.y) <= 1 &&
           !(a.x == b.x && a.y == b.y);
}

Monster* Game::monsterAt(Vec2 p) {
    for (auto& m : monsters)
        if (m.alive && m.pos == p) return &m;
    return nullptr;
}

Item* Game::groundItemAt(Vec2 p) {
    for (auto& it : groundItems)
        if (it.kind != ItemKind::None && it.pos == p) return &it;
    return nullptr;
}

bool Game::tileOccupied(Vec2 p) const {
    for (auto& m : monsters)
        if (m.alive && m.pos == p) return true;
    return false;
}

Vec2 Game::randomFloorCell(RNG& r) {
    for (int i = 0; i < 2000; ++i) {
        int x = r.range(1, MAP_W - 2);
        int y = r.range(1, MAP_H - 2);
        if (dungeon.isWalkable(x, y)) return {x, y};
    }
    return dungeon.startPos;
}

Vec2 Game::randomFloorFarFrom(Vec2 origin, int minDist) {
    for (int i = 0; i < 4000; ++i) {
        Vec2 p = randomFloorCell(rng);
        if (p.manhattan(origin) >= minDist) return p;
    }
    return randomFloorCell(rng);
}

// ---------------------------------------------------------------------------
//  Messages
// ---------------------------------------------------------------------------
void Game::clearMessages() { messageLog.clear(); }

void Game::msg(const std::string& s) { msg(s, Color::Default); }

void Game::msg(const std::string& s, Color c) {
    messageLog.push_back({s, c, false});
    if ((int)messageLog.size() > 200)
        messageLog.erase(messageLog.begin(), messageLog.begin() + 100);
}

void Game::msg(const std::string& s, Color c, bool bold) {
    messageLog.push_back({s, c, bold});
    if ((int)messageLog.size() > 200)
        messageLog.erase(messageLog.begin(), messageLog.begin() + 100);
}

void Game::msgPlayerHit(const Monster& m, int dmg) {
    std::ostringstream ss;
    ss << "You hit the " << m.name << " for " << dmg << " damage.";
    msg(ss.str(), Color::White);
}

void Game::msgMonsterHit(const Monster& m, int dmg) {
    std::ostringstream ss;
    ss << "The " << m.name << " hits you for " << dmg << " damage!";
    msg(ss.str(), Color::Red);
}

// ============================================================================
// SECTION 12 - RENDERING
// ============================================================================

void Game::clearScreenBuffer() {
    for (int r = 0; r < TOTAL_ROWS; ++r)
        for (int c = 0; c < WARN_COLS; ++c)
            screen[r][c] = Cell{};
}

void Game::put(int row, int col, char ch, Color c, bool bold) {
    if (row < 0 || row >= TOTAL_ROWS) return;
    if (col < 0 || col >= WARN_COLS) return;
    screen[row][col].ch   = ch;
    screen[row][col].fg   = c;
    screen[row][col].bold = bold;
}

void Game::putStr(int row, int col, const std::string& s, Color c, bool bold) {
    for (size_t i = 0; i < s.size(); ++i)
        put(row, (int)(col + i), s[i], c, bold);
}

// ---------------------------------------------------------------------------
void Game::render() {
    clearScreenBuffer();

    renderTitle();
    renderStatus();
    renderMap();
    renderMessages();
    renderHint();

    if (showingInventory) renderInventoryOverlay();
    if (showingHelp)      renderHelpOverlay();

    blit();
}

// ---------------------------------------------------------------------------
void Game::renderTitle() {
    std::string title = "  ╔═══ SHADOWDEEP ═══╗  ";
    putStr(ROW_TITLE, MAP_COL, title, Color::BrightYellow, true);

    std::ostringstream ss;
    ss << "  Depth " << depth << "/" << MAX_DEPTH << "  ";
    putStr(ROW_TITLE, MAP_COL + (int)title.size() + 2, ss.str(),
           Color::BrightCyan, true);
}

// ---------------------------------------------------------------------------
void Game::renderStatus() {
    int col = MAP_COL;
    std::ostringstream ss;

    // HP bar
    int hp = std::max(0, player.hp);
    int barWidth = 18;
    int filled = (int)std::round((double)hp / player.maxHp * barWidth);
    Color hpColor = Color::BrightGreen;
    if (hp < player.maxHp / 3)      hpColor = Color::BrightRed;
    else if (hp < player.maxHp * 2 / 3) hpColor = Color::BrightYellow;

    putStr(ROW_STATUS, col, "HP ", Color::Gray, false);
    col += 3;
    putStr(ROW_STATUS, col, "[", Color::Gray); col++;
    for (int i = 0; i < barWidth; ++i)
        put(ROW_STATUS, col + i, i < filled ? '#' : ' ',
            i < filled ? hpColor : Color::DarkRed, true);
    col += barWidth;
    putStr(ROW_STATUS, col, "]", Color::Gray); col++;

    ss << " " << hp << "/" << player.maxHp;
    putStr(ROW_STATUS, col, ss.str(), hpColor, true);
    col += (int)ss.str().size() + 2;

    // Stats
    ss.str("");
    ss << "Lv " << player.level;
    putStr(ROW_STATUS, col, ss.str(), Color::BrightCyan, true);
    col += (int)ss.str().size() + 2;

    ss.str("");
    ss << "XP " << player.xp << "/" << player.xpNext;
    putStr(ROW_STATUS, col, ss.str(), Color::BrightCyan);
    col += (int)ss.str().size() + 2;

    ss.str("");
    ss << "Atk " << player.attackPower()
       << "  Def " << player.defensePower();
    putStr(ROW_STATUS, col, ss.str(), Color::White);
    col += (int)ss.str().size() + 2;

    ss.str("");
    ss << player.gold << "g";
    putStr(ROW_STATUS, col, ss.str(), Color::Gold, true);
}

// ---------------------------------------------------------------------------
void Game::renderMap() {
    static char buffer[MAP_H][MAP_W];
    static Color colors[MAP_H][MAP_W];
    static bool  bold[MAP_H][MAP_W];

    for (int y = 0; y < MAP_H; ++y)
        for (int x = 0; x < MAP_W; ++x) {
            buffer[y][x] = ' ';
            colors[y][x] = Color::Default;
            bold  [y][x] = false;
        }

    // --- Static terrain -----------------------------------------------------
    for (int y = 0; y < MAP_H; ++y) {
        for (int x = 0; x < MAP_W; ++x) {
            Tile t = dungeon.at(x, y);
            bool vis = dungeon.visible[y][x];
            bool exp = dungeon.explored[y][x];

            if (!exp && !vis) continue;

            char ch = ' ';
            Color c = Color::Default;

            if (!vis && exp) {
                // Dim "remembered" version.
                switch (t) {
                    case Tile::Wall:       ch = '#'; c = Color::DarkBlue; break;
                    case Tile::Floor:      ch = '.'; c = Color::Gray;      break;
                    case Tile::Corridor:   ch = '.'; c = Color::Gray;      break;
                    case Tile::Door:       ch = '+'; c = Color::DarkYellow;break;
                    case Tile::StairsDown: ch = '>'; c = Color::DarkYellow;break;
                    case Tile::StairsUp:   ch = '<'; c = Color::DarkYellow;break;
                    case Tile::Rubble:     ch = '*'; c = Color::DarkRed;   break;
                }
            } else {
                // Fully visible.
                switch (t) {
                    case Tile::Wall:       ch = '#'; c = Color::Steel;      break;
                    case Tile::Floor:      ch = '.'; c = Color::Gray;       break;
                    case Tile::Corridor:   ch = '.'; c = Color::Gray;       break;
                    case Tile::Door:       ch = '+'; c = Color::Brown;      break;
                    case Tile::StairsDown: ch = '>'; c = Color::BrightYellow;break;
                    case Tile::StairsUp:   ch = '<'; c = Color::BrightYellow;break;
                    case Tile::Rubble:     ch = '*'; c = Color::Red;        break;
                }
            }
            buffer[y][x] = ch;
            colors[y][x] = c;
        }
    }

    // --- Ground items -------------------------------------------------------
    for (auto& it : groundItems) {
        if (it.kind == ItemKind::None) continue;
        if (!dungeon.explored[it.pos.y][it.pos.x]) continue;
        buffer[it.pos.y][it.pos.x] = it.glyph;
        colors[it.pos.y][it.pos.x] = dungeon.visible[it.pos.y][it.pos.x]
                                    ? it.color : Color::DarkYellow;
        bold[it.pos.y][it.pos.x] = dungeon.visible[it.pos.y][it.pos.x];
    }

    // --- Monsters -----------------------------------------------------------
    for (auto& m : monsters) {
        if (!m.alive) continue;
        if (!dungeon.visible[m.pos.y][m.pos.x]) continue;
        buffer[m.pos.y][m.pos.x] = m.glyph;
        colors[m.pos.y][m.pos.x] = m.color;
        bold  [m.pos.y][m.pos.x] = true;
    }

    // --- Player -------------------------------------------------------------
    buffer[player.pos.y][player.pos.x] = '@';
    colors[player.pos.y][player.pos.x] = Color::BrightWhite;
    bold  [player.pos.y][player.pos.x] = true;

    // --- Copy the buffer into the screen ------------------------------------
    for (int y = 0; y < MAP_H; ++y)
        for (int x = 0; x < MAP_W; ++x)
            put(ROW_MAP + y, MAP_COL + x, buffer[y][x], colors[y][x],
                bold[y][x]);
}

// ---------------------------------------------------------------------------
void Game::renderMessages() {
    int start = std::max(0, (int)messageLog.size() - MSG_LINES);
    for (int i = 0; i < MSG_LINES; ++i) {
        int idx = start + i;
        int row = ROW_MSG + i;
        if (idx >= (int)messageLog.size()) break;
        putStr(row, MAP_COL, messageLog[idx].text,
               messageLog[idx].color, messageLog[idx].bold);
    }
}

// ---------------------------------------------------------------------------
void Game::renderHint() {
    putStr(ROW_HINT, MAP_COL,
           "move: hjkl/yubn/arrows   g:get  i:inv  q:quaff  r:read  "
           ">:down  z:wait  ?:help  Q:quit",
           Color::Gray, false);
}

// ---------------------------------------------------------------------------
void Game::renderInventoryOverlay() {
    int boxW = 44, boxH = std::min(INV_MAX + 6, TOTAL_ROWS - 4);
    int startRow = (TOTAL_ROWS - boxH) / 2;
    int startCol = (WARN_COLS - boxW) / 2;
    if (startCol < 0) startCol = 0;

    // Border
    put(startRow, startCol, '+', Color::BrightCyan, true);
    for (int i = 1; i < boxW - 1; ++i) put(startRow, startCol + i, '-',
                                          Color::BrightCyan, true);
    put(startRow, startCol + boxW - 1, '+', Color::BrightCyan, true);
    for (int r = 1; r < boxH - 1; ++r) {
        put(startRow + r, startCol, '|', Color::BrightCyan, true);
        put(startRow + r, startCol + boxW - 1, '|', Color::BrightCyan, true);
    }
    put(startRow + boxH - 1, startCol, '+', Color::BrightCyan, true);
    for (int i = 1; i < boxW - 1; ++i)
        put(startRow + boxH - 1, startCol + i, '-', Color::BrightCyan, true);
    put(startRow + boxH - 1, startCol + boxW - 1, '+',
        Color::BrightCyan, true);

    putStr(startRow, startCol + 2, " INVENTORY ", Color::BrightYellow, true);
    putStr(startRow + boxH - 1, startCol + 2,
           " Enter: use  x: drop  q/Esc: close ",
           Color::Gray, false);

    // Contents
    int row = startRow + 2;
    if (player.inventory.empty()) {
        putStr(row, startCol + 2, "(empty)", Color::Gray);
    } else {
        for (int i = 0; i < (int)player.inventory.size() && row < startRow + boxH - 1; ++i) {
            const Item& it = player.inventory[i];
            char letter = (char)('a' + i);
            std::ostringstream ss;
            ss << letter << ") " << it.name;

            Color c = it.color;
            bool sel = (i == invCursor);
            if (sel) {
                putStr(row, startCol + 1, ">",
                       Color::BrightWhite, true);
            }
            putStr(row, startCol + 2, ss.str(),
                   c, it.kind != ItemKind::Food && it.kind != ItemKind::Gold);
            ++row;
        }
    }

    // Show equipped gear at the bottom of the panel.
    int eqRow = startRow + boxH - 2;
    std::ostringstream eq;
    eq << "Weapon: " << player.weaponName << " (+" << player.weaponPower
       << ")   Armour: " << player.armorName << " (+" << player.armorPower
       << ")";
    putStr(eqRow, startCol + 2, eq.str(), Color::Steel, true);
}

// ---------------------------------------------------------------------------
void Game::renderHelpOverlay() {
    int boxW = 66, boxH = 22;
    if (boxW > WARN_COLS) boxW = WARN_COLS;
    if (boxH > TOTAL_ROWS) boxH = TOTAL_ROWS;
    int startRow = (TOTAL_ROWS - boxH) / 2;
    int startCol = (WARN_COLS - boxW) / 2;
    if (startCol < 0) startCol = 0;

    // Fill background with spaces.
    for (int r = 0; r < boxH; ++r)
        for (int c = 0; c < boxW; ++c)
            put(startRow + r, startCol + c, ' ', Color::Default);

    put(startRow, startCol, '+', Color::BrightYellow, true);
    for (int i = 1; i < boxW - 1; ++i)
        put(startRow, startCol + i, '-', Color::BrightYellow, true);
    put(startRow, startCol + boxW - 1, '+', Color::BrightYellow, true);
    for (int r = 1; r < boxH - 1; ++r) {
        put(startRow + r, startCol, '|', Color::BrightYellow, true);
        put(startRow + r, startCol + boxW - 1, '|', Color::BrightYellow, true);
    }
    put(startRow + boxH - 1, startCol, '+', Color::BrightYellow, true);
    for (int i = 1; i < boxW - 1; ++i)
        put(startRow + boxH - 1, startCol + i, '-', Color::BrightYellow, true);
    put(startRow + boxH - 1, startCol + boxW - 1, '+', Color::BrightYellow, true);

    int r = startRow + 1;
    int c = startCol + 2;

    auto line = [&](const std::string& text, Color col, bool b = false) {
        putStr(r, c, text, col, b);
        ++r;
    };

    line("SHADOWDEEP — quick reference", Color::BrightYellow, true);
    line("", Color::Default);
    line("Movement           hjkl, yubn, arrow keys", Color::White);
    line("Attack             walk into a monster", Color::White);
    line("Pick up            g", Color::White);
    line("Inventory          i        (Enter to use, x to drop)", Color::White);
    line("Quaff potion       q        (uses first potion in pack)", Color::White);
    line("Read scroll        r        (uses first scroll in pack)", Color::White);
    line("Descend stairs     >", Color::White);
    line("Wait a turn        z  or  .", Color::White);
    line("Quit               Q  or  Ctrl-D", Color::White);
    line("", Color::Default);
    line("Symbols", Color::BrightCyan, true);
    line("@ you    , monsters    $ gold    ! potion    ? scroll", Color::Gray);
    line("/ weapon   [ armour   % food    \"  Amulet of Shadowdeep", Color::Gray);
    line("# wall  . floor  + door  > stairs down  < stairs up", Color::Gray);
    line("", Color::Default);
    line("Goal: descend to level 10, seize the Amulet, and survive.", Color::BrightYellow);
    line("", Color::Default);
    line("Press any key to return to the dungeon.", Color::BrightCyan, true);
}

// ---------------------------------------------------------------------------
void Game::renderGameOverOverlay() {
    // Not used as an inline overlay; the death screen takes over.
}

// ---------------------------------------------------------------------------
void Game::blit() {
    std::string out;
    out.reserve(WARN_COLS * TOTAL_ROWS * 2);

    Color currentFg = Color::Default;
    bool  currentBold = false;

    out += "\033[H";

    for (int r = 0; r < TOTAL_ROWS; ++r) {
        for (int c = 0; c < WARN_COLS; ++c) {
            const Cell& cell = screen[r][c];
            if (cell.ch == ' ' && cell.fg == Color::Default && !cell.bold) {
                // Skip leading whitespace but keep the layout (need to advance).
                if (r < WARN_COLS && c == 0) {
                    // fall through and write the space
                } else {
                    out += ' ';
                    continue;
                }
            }
            if (cell.fg != currentFg) {
                out += colorCode(cell.fg);
                currentFg = cell.fg;
            }
            if (cell.bold != currentBold) {
                out += cell.bold ? BOLD() : RESET();
                // After RESET we need to re-apply the color.
                if (cell.bold) {
                    out += colorCode(cell.fg);
                } else {
                    out += colorCode(cell.fg);
                }
                currentBold = cell.bold;
            }
            out += cell.ch;
        }
        out += "\033[0m";
        currentFg = Color::Default;
        currentBold = false;
        if (r < TOTAL_ROWS - 1)
            out += "\r\n";
    }

    std::fwrite(out.data(), 1, out.size(), stdout);
    std::fflush(stdout);
}

// ============================================================================
// SECTION 13 - FULL-SCREEN MENUS
// ============================================================================

void Game::runHelpScreen() {
    showingHelp = true;
    render();
    term.waitKey();
    showingHelp = false;
    render();
}

// ---------------------------------------------------------------------------
void Game::runInventoryScreen() {
    showingInventory = true;

    for (;;) {
        if (invCursor >= (int)player.inventory.size())
            invCursor = std::max(0, (int)player.inventory.size() - 1);

        render();
        int k = term.waitKey();

        if (k == 'q' || k == 'i' || k == KEY_ESCAPE || k == 27) break;

        if (k == 'j' || k == KEY_DOWN) {
            if (invCursor + 1 < (int)player.inventory.size()) invCursor++;
        } else if (k == 'k' || k == KEY_UP) {
            if (invCursor > 0) invCursor--;
        } else if (k == '\r' || k == '\n') {
            if (useInventoryItem(invCursor)) break;
        } else if (k == 'x' || k == 'X') {
            dropItemFromInventory(invCursor);
        } else if (k >= 'a' && k <= 'z') {
            int idx = k - 'a';
            if (idx < (int)player.inventory.size()) {
                invCursor = idx;
                if (useInventoryItem(idx)) break;
            }
        }
    }

    showingInventory = false;
    render();
}

// ---------------------------------------------------------------------------
void Game::runDeathScreen() {
    term.restore();

    long long elapsed = nowMs() - startTimeMs;

    std::printf("\033[2J\033[H\033[1;31m");
    std::printf("   ╔══════════════════════════════════════════════════╗\n");
    std::printf("   ║                                                  ║\n");
    std::printf("   ║               Y O U   H A V E   D I E D          ║\n");
    std::printf("   ║                                                  ║\n");
    std::printf("   ╚══════════════════════════════════════════════════╝\n");
    std::printf("\033[0m\n");
    std::printf("   \033[1;37mFinal Statistics\033[0m\n");
    std::printf("   ─────────────────────────────────\n");
    std::printf("   Depth reached      : \033[1;33m%d\033[0m\n", depth);
    std::printf("   Character level    : \033[1;33m%d\033[0m\n", player.level);
    std::printf("   Monsters slain     : \033[1;33m%d\033[0m\n", totalMonstersKilled);
    std::printf("   Gold collected     : \033[1;33m%lld\033[0m\n", totalGoldEarned);
    std::printf("   Turns taken        : \033[1;33m%lld\033[0m\n", player.turns);
    std::printf("   Time played        : \033[1;33m%s\033[0m\n",
                formatTime(elapsed).c_str());
    std::printf("\n   The darkness swallows your last breath...\n");
    std::printf("   \033[90mPress any key to exit.\033[0m\n");
    std::fflush(stdout);

    term.enterRaw();
    term.waitKey();
    term.restore();
}

// ---------------------------------------------------------------------------
void Game::runWinScreen() {
    term.restore();

    long long elapsed = nowMs() - startTimeMs;

    std::printf("\033[2J\033[H\033[1;33m");
    std::printf("   ╔══════════════════════════════════════════════════╗\n");
    std::printf("   ║                                                  ║\n");
    std::printf("   ║           ★   V I C T O R Y   ★                  ║\n");
    std::printf("   ║                                                  ║\n");
    std::printf("   ║   You carry the Amulet of Shadowdeep into day.   ║\n");
    std::printf("   ║   The dark below is silent, and you are alive.   ║\n");
    std::printf("   ║                                                  ║\n");
    std::printf("   ╚══════════════════════════════════════════════════╝\n");
    std::printf("\033[0m\n");
    std::printf("   \033[1;37mFinal Statistics\033[0m\n");
    std::printf("   ─────────────────────────────────\n");
    std::printf("   Character level    : \033[1;33m%d\033[0m\n", player.level);
    std::printf("   Monsters slain     : \033[1;33m%d\033[0m\n", totalMonstersKilled);
    std::printf("   Gold collected     : \033[1;33m%lld\033[0m\n", totalGoldEarned);
    std::printf("   Turns taken        : \033[1;33m%lld\033[0m\n", player.turns);
    std::printf("   Time played        : \033[1;33m%s\033[0m\n",
                formatTime(elapsed).c_str());
    std::printf("\n   \033[90mPress any key to exit.\033[0m\n");
    std::fflush(stdout);

    term.enterRaw();
    term.waitKey();
    term.restore();
}

} // namespace sd

// ============================================================================
//  main
// ============================================================================
int main(int argc, char** argv) {
    sd::Game game;
    return game.run(argc, argv);
}
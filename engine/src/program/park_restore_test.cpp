// src/program/park_restore_test.cpp - the pure decision half of park-restore (STRATA_PARK_RESTORE=1):
// manifest grammar, candidate selection, the payload pre-screen, and the cache side effects a restore
// put inherits.  Pinned without a device, per PLAN-spill-restore.md §4 (the rules independent review #1
// corrected are the ones checked hardest here: the strict upper bound it PROVED via conversation_prefix,
// the depth prebound that replaced the old fixed 16 K tail, the grown-thread case that tail missed, and
// the silent supersede the restore must log because put() cannot).
#include "strata/program/park_restore.hpp"
#include "strata/core/conversation_cache.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace strata::program;

namespace {
int g_fail = 0;
void check(bool ok, const char* what) {
    std::printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok) ++g_fail;
}

// ---- manifest helpers ----
using park_restore::Header;
using park_restore::Line;

bool parse(const std::string& text, Header& h, std::vector<Line>& lines, std::string& why) {
    return park_restore::parse_manifest(text, h, lines, why);
}

const char* kGood = "strata-park 2\ntag abc0000000000def\nstages 3\n"
                    "conv c0000000000000001-100000 100000 1700000000\n"
                    "conv c0000000000000002-200000 200000 1700000100\n"
                    "end\n";

std::vector<int64_t> request_of(int64_t n) {
    std::vector<int64_t> r((size_t) n);
    for (int64_t i = 0; i < n; ++i) r[(size_t) i] = 1000 + i;   // any injective pattern
    return r;
}

// ---- payload builders: the exact byte order of put_payload / put_checkpoint (conversation_file.cpp) ----
void put64(std::vector<uint8_t>& b, int64_t v) {
    const size_t o = b.size();
    b.resize(o + 8);
    std::memcpy(b.data() + o, &v, 8);
}

// the payload's fixed front through the live checkpoint's ids (the only bytes the pre-screen reads)
std::vector<uint8_t> payload(const std::vector<int32_t>& ids, bool cvec, int table_n = 0) {
    std::vector<uint8_t> b;
    for (int i = 0; i < 18; ++i) put64(b, i);              // geometry
    put64(b, 0); put64(b, 99);                             // layer_lo, layer_hi
    put64(b, cvec ? 1 : 0);                                // cvec flag
    put64(b, table_n);                                     // stage table count
    for (int t = 0; t < table_n; ++t) for (int f = 0; f < 5; ++f) put64(b, f);
    put64(b, (int64_t) ids.size());                        // live ids: the first serialized object
    const size_t o = b.size();
    b.resize(o + ids.size() * sizeof(int32_t));
    std::memcpy(b.data() + o, ids.data(), ids.size() * sizeof(int32_t));
    return b;
}

park_restore::SelectParams params(int64_t request_len, int64_t floor_tokens, int64_t gain = 4096,
                                  int64_t now = 1700001000, int64_t max_age_s = 48 * 3600,
                                  size_t max_tries = 2) {
    park_restore::SelectParams p;
    p.request_len = request_len;
    p.floor_tokens = floor_tokens;
    p.gain = gain;
    p.now_unix = now;
    p.max_age_s = max_age_s;
    p.max_tries = max_tries;
    return p;
}

Line line(const char* name, uint64_t tokens, int64_t parked) {
    Line l;
    l.name = name;
    l.tokens = tokens;
    l.parked_unix = parked;
    return l;
}

strata::core::ConversationCheckpoint ck(std::vector<int32_t> ids) {
    strata::core::ConversationCheckpoint c;
    c.ids = std::move(ids);
    return c;
}

strata::core::SavedConversation image(std::vector<int32_t> live, std::vector<std::vector<int32_t>> cps,
                                      int64_t parked = 1700000000, const char* disk = "") {
    strata::core::SavedConversation s;
    s.live = ck(std::move(live));
    for (auto& v : cps) s.checkpoints.push_back(ck(std::move(v)));
    s.parked_unix = parked;
    s.disk_name = disk;
    return s;
}

bool has(const std::vector<const Line*>& picks, const std::string& name) {
    for (const auto* l : picks)
        if (l->name == name) return true;
    return false;
}
}  // namespace

int main() {
    std::printf("park_restore_test: manifest grammar, candidate selection, payload pre-screen, cache effects\n");

    // ---- 1. the grammar PARKLOAD, the stop-save and the spill all speak ----
    {
        Header h; std::vector<Line> lines; std::string why;
        check(parse(kGood, h, lines, why) && h.version == 2 && h.tag == "abc0000000000def" && h.stages == 3 &&
              lines.size() == 2 && lines[1].tokens == 200000 && lines[1].parked_unix == 1700000100,
              "good manifest parses (version, tag, stages, conv triples)");
        check(!parse("strata-park 3\ntag x\nstages 1\nend\n", h, lines, why), "format 3: refused, whole list ignored");
        check(!parse("strata-park 2\ntag x\nstages 1\nconv n 5 1\n", h, lines, why), "no end marker: refused");
        Header h2; std::vector<Line> l2; std::string w2;
        check(!parse("strata-park 2\ntag x\nstages 1\nconv ../etc/passwd 5 1\nend\n", h2, l2, w2),
              "a conv name that tries to leave the park folder: refused");
        check(!parse("not a manifest\n", h2, l2, w2), "foreign bytes: refused");
        check(!parse("strata-park 2\ntag x\nstages 1\nconv n 0 1\nend\n", h2, l2, w2), "zero-token line: refused");
    }

    // ---- 2. selection: the bounds review #1 corrected ----
    {
        const int64_t now = 1700001000, age = 48 * 3600;
        std::vector<Line> lines = {
            line("grown", 170000, now - 60),         // the headline case: 170 K on disk, thread grew to 300 K
            line("tooshallow", 3000, now - 60),      // below floor+gain: couldn't clear the take bar
            line("toolong", 300000, now - 60),       // tk == request_len: conversation_prefix would return 0
            line("longer", 450000, now - 60),        // tk > request_len: the exact-replay shape, accepted loss
            line("undated", 120000, 0),              // parked == 0: restoring it would put a never-aging entry
            line("aged", 250000, now - age - 1),     // one second past the age rule
            line("justyoung", 240000, now - age),    // exactly at it: kept (the boot rule is strict >)
        };
        const auto picks = park_restore::select(lines, params(300000, 100, 4096, now));
        check(picks.size() == 2 && picks[0]->name == "justyoung" && picks[1]->name == "grown",
              "grown-thread re-request (170 K of 300 K) IS selected - the old 16 K tail missed it; deepest first");
        check(!has(picks, "tooshallow") && !has(picks, "toolong") && !has(picks, "longer") &&
                  !has(picks, "undated") && !has(picks, "aged"),
              "shallow / at-or-beyond request / undated / aged: silent zero, never decline-stormed");
        std::vector<Line> many = {line("deep1", 280000, now), line("deep2", 260000, now - 1),
                                  line("deep3", 250000, now), line("deep4", 180000, now)};
        const auto m2 = park_restore::select(many, params(300000, 100, 4096, now));
        check(m2.size() == 2 && m2[0]->name == "deep1" && m2[1]->name == "deep2", "at most 2 tries, deepest first");
        std::vector<Line> tie = {line("older", 200000, now - 100), line("newer", 200000, now)};
        const auto t = park_restore::select(tie, params(300000, 100, 4096, now));
        check(t.size() == 2 && t[0]->name == "newer", "token-count ties break to the newer park");
        std::vector<Line> bar = {line("at", 4196, now), line("past", 4197, now)};   // floor 100 + gain 4096 = 4196
        const auto b = park_restore::select(bar, params(300000, 100, 4096, now));
        check(b.size() == 1 && b[0]->name == "past", "depth prebound boundary: tk == floor+gain is out, +1 is in");
        std::vector<Line> absurd = {line("big", (uint64_t) 1 << 63, now)};
        check(park_restore::select(absurd, params(300000, 100, 4096, now)).empty(), "an absurd token count is not a candidate");
    }

    // ---- 3. the payload pre-screen: it declines only what the full read would decline ----
    {
        const auto req = request_of(300000);
        const int64_t floor = 100, gain = 4096, bar = floor + gain;
        {   // the spilled conversation IS this thread's history: live ids == the prompt's first tk tokens
            std::vector<int32_t> ids((size_t) 170000);
            for (int64_t i = 0; i < 170000; ++i) ids[(size_t) i] = (int32_t) req[(size_t) i];
            const auto buf = payload(ids, true);
            const auto ps = park_restore::prescreen_payload(buf.data(), buf.size(), req, floor, gain, 170000, true);
            check(ps.verdict == park_restore::Verdict::pass && ps.common_prefix == 170000,
                  "full prefix (the re-requested thread): pass");
        }
        {   // a sibling thread: same-shaped file, first token already differs
            std::vector<int32_t> ids((size_t) 160000, 7);
            const auto buf = payload(ids, true);
            const auto ps = park_restore::prescreen_payload(buf.data(), buf.size(), req, floor, gain, 160000, true);
            check(ps.verdict == park_restore::Verdict::reject && std::string(ps.reason) == "pre-screen" &&
                      ps.common_prefix == 0,
                  "sibling divergence at token 0: declined in milliseconds, not after a 5 GB read");
        }
        {   // boundary: divergence exactly at the bar rejects, one past it passes (ambiguous -> read)
            std::vector<int32_t> ids((size_t) 100000, 9);
            for (int64_t i = 0; i < bar; ++i) ids[(size_t) i] = (int32_t) req[(size_t) i];
            auto buf = payload(ids, true);
            check(park_restore::prescreen_payload(buf.data(), buf.size(), req, floor, gain, 100000, true)
                      .verdict == park_restore::Verdict::reject,
                  "prefix == floor+gain exactly: decline (the post-read bar could not be cleared either)");
            ids[(size_t) bar] = (int32_t) req[(size_t) bar];
            buf = payload(ids, true);
            check(park_restore::prescreen_payload(buf.data(), buf.size(), req, floor, gain, 100000, true)
                      .verdict == park_restore::Verdict::pass,
                  "prefix one token past the bar: pass (a checkpoint there may still be serialized)");
        }
        {   // the N2 closure: a steering (cvec) change declines from the file's own flag, not from RAM
            std::vector<int32_t> ids((size_t) 170000, 1);
            const auto buf = payload(ids, false);
            const auto ps = park_restore::prescreen_payload(buf.data(), buf.size(), req, floor, gain, 170000, true);
            check(ps.verdict == park_restore::Verdict::reject && std::string(ps.reason) == "cvec",
                  "cvec flag differs from the request's: declined (best() filters by it anyway)");
        }
        {   // the manifest line does not describe this file's live ids
            std::vector<int32_t> ids((size_t) 170000, 1);
            const auto buf = payload(ids, true);
            const auto ps = park_restore::prescreen_payload(buf.data(), buf.size(), req, floor, gain, 169999, true);
            check(ps.verdict == park_restore::Verdict::reject && std::string(ps.reason) == "window" &&
                      ps.live_tokens == 170000,
                  "live ids != manifest tokens: the file's own bytes beat its label");
        }
        {   // distrust, never decline: a truncated buffer / garbage table / ids beyond the request
            std::vector<int32_t> ids((size_t) 100000, 1);
            auto buf = payload(ids, true);
            buf.resize(300);   // cut mid-ids
            check(park_restore::prescreen_payload(buf.data(), buf.size(), req, floor, gain, 100000, true)
                      .verdict == park_restore::Verdict::unknown,
                  "truncated prefix: unknown -> the full read stays the authority");
            auto big = payload(ids, true, 99);   // nonsense stage-table count
            check(park_restore::prescreen_payload(big.data(), big.size(), req, floor, gain, 100000, true)
                      .verdict == park_restore::Verdict::unknown,
                  "unrecognized stage table: unknown -> full read");
            const auto same = payload(ids, true);
            check(park_restore::prescreen_payload(same.data(), same.size(), request_of(100000), floor, gain, 100000, true)
                      .verdict == park_restore::Verdict::unknown,
                  "ids not shorter than the prompt (selector would have excluded): distrust, don't decline");
        }
        {   // agreement with the REAL prefix computation, on a {shallowest, deepest} truncated chain
            std::vector<int32_t> live_ids((size_t) 100000, 5);
            for (int64_t i = 0; i < 50; ++i) live_ids[(size_t) i] = (int32_t) req[(size_t) i];
            std::vector<int32_t> root(req.begin(), req.begin() + 10);
            std::vector<int32_t> turn40(req.begin(), req.begin() + 40);
            const std::vector<std::vector<int32_t>> chain = {root, turn40};   // checkpoints: prefixes of live (invariant)
            const auto buf = payload(live_ids, true);
            const int64_t m = park_restore::prescreen_payload(buf.data(), buf.size(), req, floor, gain, 100000, true)
                                  .common_prefix;
            check(m == 50, "pre-screen sees the divergence at 50 (live's own prefix)");
            int64_t best = strata::core::conversation_prefix(ck(live_ids), req, {});
            for (const auto& c : chain) best = std::max<int64_t>(best, strata::core::conversation_prefix(ck(c), req, {}));
            check(best == 40 && best <= m,
                  "the full chain's true match (40) never exceeds the pre-screen's m: a decline at m<=bar is provably safe");
            check(park_restore::prescreen_payload(buf.data(), buf.size(), req, floor, gain, 100000, true)
                      .verdict == park_restore::Verdict::reject,
                  "m=50 <= floor+gain=4196: declined, and the real match (40) could not clear the bar either");
        }
    }

    // ---- 4. what a restore's put() does to the cache (the effects the request path must log) ----
    {
        auto ids = [](int64_t n, int64_t base) {
            std::vector<int32_t> v((size_t) n);
            for (int64_t i = 0; i < n; ++i) v[(size_t) i] = (int32_t) (base + i);
            return v;
        };
        auto cat = [](std::vector<int32_t> a, const std::vector<int32_t>& b) {
            a.insert(a.end(), b.begin(), b.end());
            return a;
        };
        // M2: put() runs drop_superseded with no voice of its own, and #4420's protection lives in the
        // slot-park path, not in put(): a spilled conversation truncated to {root, deepest} that rides
        // back into the cache CAN silently drop an unrelated RAM entry whose deepest checkpoint is that
        // shared root.  The restore counts the delta around the put and names it (boot-load discipline);
        // this pin documents the behavior it must not be surprised by.
        const auto root = ids(10, 1);
        strata::core::ConversationCache cache(1u << 30, 8);
        cache.put(image(cat(root, ids(90, 1000)), {root}));                 // R: its deepest is the shared root
        check(cache.size() == 1, "fixture: one RAM entry whose deepest checkpoint is the shared root");
        const size_t su0 = cache.superseded();
        cache.put(image(cat(root, ids(50, 5000)), {root}));                 // the restored older generation, same root
        check(cache.size() == 1 && cache.superseded() == su0 + 1,
              "put of a {root}-chain image supersedes the unrelated entry holding that root (M2 - restore must log it)");
    }
    {
        auto ids = [](int64_t n, int64_t base) {
            std::vector<int32_t> v((size_t) n);
            for (int64_t i = 0; i < n; ++i) v[(size_t) i] = (int32_t) (base + i);
            return v;
        };
        // H4 parity: an entry the restore puts must look EXACTLY like a boot-loaded one to every other
        // consumer - the stop walk's evict protection and the keep-guard's age re-listing.
        strata::core::ConversationCache cache(1u << 30, 8);
        cache.put(image(ids(100, 100), {ids(10, 100)}));                    // no disk_name: only mid-run LRU may take it
        check(!strata::core::ConversationCache::saved_for_evict(cache.entries()[0]),
              "an entry without disk_name is not evictable to make room at the stop (its bytes exist nowhere)");
        cache.put(image(ids(100, 200), {ids(10, 200)}, 1700000000, "c000000000000abc-100"));
        check(strata::core::ConversationCache::saved_for_evict(cache.entries()[1]) &&
                  cache.entries()[1].parked_unix == 1700000000,
              "a restored/boot-loaded entry carries disk_name AND parked_unix: evictable, ageable - the keep-guard prunes it");
    }

    std::printf("%s\n", g_fail == 0 ? "ALL OK" : "FAILURES");
    return g_fail == 0 ? 0 : 1;
}

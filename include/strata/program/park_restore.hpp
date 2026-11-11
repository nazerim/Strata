// strata/program/park_restore.hpp - the pure decision half of park-restore (STRATA_PARK_RESTORE=1):
// which conversations the park manifest offers for this prompt, and what the first bytes of a stage
// file already say about one before its gigabytes are read.
//
// The serve loop's request path (generate.cpp, park_restore_fn) consults these when the conversation
// cache's match for a prompt does not reach past what the request already reuses - the fall-through
// that, until now, meant reading the whole thread cold while its spilled stage files waited on NVMe.
// Everything here is pure over the manifest text and a byte prefix, so park_restore_test.cpp pins the
// rules without a device: the window's bounds (PLAN-spill-restore.md §2, corrected by independent
// review #1), the age rules the boot load already speaks, and the pre-screen's promise that it only
// ever declines what a full read could only have declined too.
#ifndef STRATA_PROGRAM_PARK_RESTORE_HPP
#define STRATA_PROGRAM_PARK_RESTORE_HPP

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

namespace strata::program::park_restore {

// One "conv <name> <tokens> <parked>" line of the park manifest: the base name of the conversation's
// stage files, the length of the live ids it serialized, and when it was parked (unix seconds; 0 is
// an undated pre-v1.1 line - boot loading keeps those by ignoring age, restoring one would put an
// entry that never ages into the cache, so the selector does not).
struct Line {
    std::string name;
    uint64_t tokens = 0;
    int64_t parked_unix = 0;
};

struct Header {
    int version = 0;
    std::string tag = "";
    uint64_t stages = 0;
};

// The stop-save / spill grammar (generate.cpp): "strata-park 2", "tag <hex16>", "stages <n>", any
// number of "conv" triples, "end" - whitespace separated, the same reading PARKLOAD does at boot and
// the same refusal for anything malformed or any name that tries to leave the park folder ("/", "\",
// ":"). false means the caller must ignore the whole manifest, not just a line.
inline bool parse_manifest(const std::string& text, Header& h, std::vector<Line>& lines, std::string& why) {
    std::istringstream f(text);
    std::string magic, word;
    if (!(f >> magic) || magic != "strata-park") { why = "not a park manifest"; return false; }
    if (!(f >> h.version)) { why = "no version"; return false; }
    if (h.version != 2) { why = "is format " + std::to_string(h.version) + ", this engine reads 2"; return false; }
    if (!(f >> word) || word != "tag" || !(f >> h.tag)) { why = "no tag line"; return false; }
    if (!(f >> word) || word != "stages" || !(f >> h.stages)) { why = "no stages line"; return false; }
    while (f >> word) {
        if (word == "end") return true;
        Line e;
        if (word != "conv" || !(f >> e.name >> e.tokens >> e.parked_unix) ||
            e.name.find_first_of("/\\:") != std::string::npos || e.tokens == 0) {
            why = "malformed conv line";
            return false;
        }
        lines.push_back(std::move(e));
    }
    why = "no end marker";
    return false;
}

struct SelectParams {
    int64_t request_len = 0;    // the prompt's token count
    int64_t floor_tokens = 0;   // max(resume, slot_tokens): the reuse this request already has
    int64_t gain = 4096;        // STRATA_PARK_RESTORE_GAIN: how much deeper a candidate must be able to go
                                // than the floor to be worth a read (the bar the take condition applies)
    int64_t now_unix = 0;
    int64_t max_age_s = 0;      // the same age rule the boot load and the keep-guard speak; 0: never too old
    size_t max_tries = 2;       // STRATA_PARK_RESTORE_TRIES
};

// Young, dated, deeper than the floor by the gain, and SHORTER than the prompt - that last bound is
// not conservatism: conversation_prefix (conversation_cache.hpp) returns 0 for any state whose ids
// are not strictly shorter than the prompt (the last prompt token must be read to open the verify
// window), so a disk conversation at or beyond the request's length could only ever match at the root
// and decline - an exact replay or a cancelled tail is a documented cheap loss, not a missed restore.
// Survivors rank deepest first (newest park wins ties - the generations of one thread differ in their
// tail); at most max_tries, and the caller stops at the first success so an older generation on disk
// never re-reads over a fresher one it just put in the cache.
inline std::vector<const Line*> select(const std::vector<Line>& lines, const SelectParams& p) {
    std::vector<const Line*> out;
    for (const auto& l : lines) {
        if (l.parked_unix <= 0) continue;
        if (p.max_age_s > 0 && p.now_unix - l.parked_unix > p.max_age_s) continue;
        if (l.tokens > (uint64_t) INT64_MAX) continue;   // absurd line: not a candidate, not an int64 overflow either
        const int64_t tk = (int64_t) l.tokens;
        if (tk <= p.floor_tokens + p.gain) continue;     // couldn't clear the take bar even as a perfect prefix
        if (tk >= p.request_len) continue;               // the prefix rule above
        out.push_back(&l);
    }
    std::sort(out.begin(), out.end(), [](const Line* a, const Line* b) {
        return a->tokens != b->tokens ? a->tokens > b->tokens : a->parked_unix > b->parked_unix;
    });
    if (out.size() > p.max_tries) out.resize(p.max_tries);
    return out;
}

// The front of a session file's payload, pinned to format v2 (put_payload, src/core/conversation_file.cpp):
// geometry (18 int64), layer_lo, layer_hi, the cvec flag, the later-stage table (count + five int64 each),
// then the live checkpoint - whose FIRST object is its ids (a u64 count, then int32 tokens). The whole
// reachable prefix is small: max_context ids at 4 bytes each fit far inside the first MiBs, which is why
// a sibling's misfire can cost milliseconds instead of the 5-11 s a multi-GB read ends in.
constexpr size_t kFileHeaderBytes = 64, kFileTrailerBytes = 16;
constexpr uint32_t kFormatV2 = 2;
constexpr size_t kGeometryInt64 = 18;
constexpr size_t kFixedPayloadBytes = kGeometryInt64 * 8 + 8 + 8 + 8 + 8 + 64 * 40 + 8;  // through the ids count, with a stage table's headroom

enum class Verdict { pass, reject, unknown };

struct Prescreen {
    Verdict verdict = Verdict::pass;
    const char* reason = "";        // set on reject: the decline's name in the log line
    uint64_t live_tokens = 0;
    int64_t common_prefix = -1;     // leading live ids equal to the prompt's, once the ids were parsed
};

// `buf`/`len` cover the payload's first bytes (the file header itself is NOT in this buffer - the
// caller validated it as trusted bytes against this process's fingerprints first). A reject is only
// ever returned when the full read could only have declined the same candidate:
//   - the cvec flag differs from the request's: best() filters entries by it before matching at all,
//     exactly as it would a RAM-parked one (this is the N2 closure: a steering change declines here);
//   - the live ids count differs from the manifest's tokens: the line does not describe this file
//     (the H4 pre-read form of the post-read window check - the file's own bytes beat its label);
//   - the ids diverge from the prompt at m <= floor + gain: every checkpoint of a parked image
//     starts with the live ids (the cache's prefix-chain invariant, the same one the take path and
//     the spill's own naming trust), so no state serialized in this file can match the prompt past
//     m, and m already fails the bar the post-read check would apply.
// Anything the bytes cannot prove - truncated read, an absurd count, a version or layout this helper
// does not recognize - returns unknown, which is pass: the full read under the per-request byte cap
// stays the authority. (The agreement with the real prefix computation is pinned on constructed
// fixtures in park_restore_test.cpp, and a format drift only ever costs speed, never correctness.)
inline Prescreen prescreen_payload(const uint8_t* buf, size_t len, const std::vector<int64_t>& request,
                                   int64_t floor_tokens, int64_t gain, uint64_t manifest_tokens,
                                   bool want_cvec) {
    Prescreen ps;
    auto unknown = [&ps] { ps.verdict = Verdict::unknown; return ps; };
    auto i64_at = [&](size_t off, int64_t& v) {
        if (off + 8 > len) return false;
        std::memcpy(&v, buf + off, 8);
        return true;
    };
    size_t c = kGeometryInt64 * 8 + 8 + 8;   // past geometry, layer_lo, layer_hi
    int64_t cvec = 0;
    if (!i64_at(c, cvec)) return unknown();
    if ((cvec != 0) != want_cvec) { ps.verdict = Verdict::reject; ps.reason = "cvec"; return ps; }
    c += 8;
    int64_t table_n = 0;
    if (!i64_at(c, table_n) || table_n < 0 || (uint64_t) table_n > 64) return unknown();
    c += 8 + (size_t) table_n * 40;
    int64_t n_ids = 0;
    if (!i64_at(c, n_ids) || n_ids <= 0) return unknown();
    if ((uint64_t) n_ids != manifest_tokens) {
        ps.verdict = Verdict::reject;
        ps.reason = "window";
        ps.live_tokens = (uint64_t) n_ids;
        return ps;
    }
    if ((uint64_t) n_ids >= request.size()) return unknown();   // the window said shorter: distrust, don't decline
    c += 8;
    if (n_ids > (int64_t)((len >= c ? len - c : 0) / 4)) return unknown();   // the ids exceed this buffer
    int64_t m = 0;
    for (; m < n_ids; ++m) {
        int32_t t;
        std::memcpy(&t, buf + c + (size_t) m * 4, 4);
        if ((int64_t) t != request[(size_t) m]) break;
    }
    ps.common_prefix = m;
    ps.live_tokens = (uint64_t) n_ids;
    if (m <= floor_tokens + gain) { ps.verdict = Verdict::reject; ps.reason = "pre-screen"; return ps; }
    return ps;   // a real chance at a deep match: let the full read say so
}

}  // namespace strata::program::park_restore

#endif  // STRATA_PROGRAM_PARK_RESTORE_HPP

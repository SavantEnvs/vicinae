// libFuzzer harness over vicinae's fzf-style fuzzy matcher (src/lib/fuzzy), the code that scores
// every launcher query against every item. Exercises the ASCII fast path, the diacritic folding
// path, transliteration of non-Latin queries and the multi-word weighted scorer.
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>
#include "fuzzy/fzf.hpp"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size < 3) return -1;

  static const fzf::Matcher matchers[] = {fzf::Matcher{fzf::Scheme::Default}, fzf::Matcher{fzf::Scheme::Path},
                                          fzf::Matcher{fzf::Scheme::History}};
  const fzf::Matcher &matcher = matchers[data[0] % 3];
  const bool withPositions = data[0] & 0x80;

  // data[1] picks where the text ends and the pattern begins in the remaining bytes
  const char *body = reinterpret_cast<const char *>(data + 2);
  const size_t bodySize = size - 2;
  const size_t split = data[1] % (bodySize + 1);
  const std::string_view text{body, split};
  const std::string_view pattern{body + split, bodySize - split};

  const fzf::Result r = matcher.match(text, pattern, withPositions);
  if (r.matched() && withPositions) {
    volatile size_t n = r.positions.size();
    (void)n;
  }
  (void)matcher.match_folded(text, pattern, withPositions);

  const fzf::Query query{pattern, matcher};
  (void)matcher.score_query(text, query);

  const std::vector<fzf::WeightedString> fields{{text, 1.0f}, {pattern, 0.5f}};
  (void)matcher.score_query(fields, fzf::Query{text, matcher});
  return 0;
}

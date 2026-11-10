// libFuzzer harness over vicinae's freedesktop .desktop entry parser (src/lib/xdgpp), which the
// app scan runs on every .desktop file at startup and on refresh. Parses the input as a whole
// entry and reads back every accessor the launcher uses.
#include <cstddef>
#include <cstdint>
#include <string_view>
#include "xdgpp/desktop-entry/entry.hpp"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  const std::string_view text{reinterpret_cast<const char *>(data), size};

  // fixed locale so an input's result does not depend on the host's LANG
  const xdgpp::DesktopEntry entry = xdgpp::DesktopEntry::fromData(text, {.locale = xdgpp::Locale("en_US")});
  if (!entry.isValid()) return 0;

  volatile size_t sink = 0;
  sink += entry.name().size();
  sink += entry.genericName().value_or("").size();
  sink += entry.comment().value_or("").size();
  sink += entry.icon().value_or("").size();
  sink += entry.exec().value_or("").size();
  sink += entry.parseExec().size();
  sink += entry.parseExec({"file:///tmp/a b", "/tmp/c"}).size();
  sink += entry.keywords().size() + entry.categories().size() + entry.mimes().size();
  sink += entry.onlyShowIn().size() + entry.notShowIn().size();
  sink += entry.noDisplay() + entry.terminal() + entry.matchesCurrentDesktop();
  for (const auto &action : entry.actions()) {
    sink += action.name().size() + action.parseExec().size();
  }
  (void)sink;
  return 0;
}

/*
 * Local replacement for the MySQL Workbench header base/symbol-info.h.
 *
 * Workbench's version carries per-release keyword and reserved word tables.
 * Only the entry points used by MySQLBaseLexer.cpp are provided here, with
 * the following simplifications (see src/sql/antlr/README.md):
 *
 *   - isKeyword() accepts any non-empty name.
 *   - isReservedKeyword() accepts no name, so no keyword is reserved.
 *
 * Version gating in the grammar itself ({serverVersion >= N}? predicates) is
 * unaffected. Replace these with the real keyword tables before relying on
 * isIdentifier() or keyword classification.
 */

#pragma once

#include <string>

namespace base {

  // A MySQL server version, encoded like MySQLRecognizerCommon::serverVersion
  // (major * 10000 + minor * 100 + patch, e.g. 80400 for 8.4.0).
  struct MySQLVersion {
    long number = 0;

    bool operator<(const MySQLVersion &other) const { return number < other.number; }
    bool operator==(const MySQLVersion &other) const { return number == other.number; }
  };

  class MySQLSymbolInfo {
  public:
    static MySQLVersion numberToVersion(long number) {
      MySQLVersion version;
      version.number = number;
      return version;
    }

    // True if the name (lower case, without quotes) is a keyword of the given version.
    static bool isKeyword(const std::string &name, MySQLVersion version) {
      (void)version;
      return !name.empty();
    }

    // True if the name is a reserved word of the given version (cannot be an unquoted identifier).
    static bool isReservedKeyword(const std::string &name, MySQLVersion version) {
      (void)name;
      (void)version;
      return false;
    }
  };

} // namespace base

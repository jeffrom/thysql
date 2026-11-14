/*
 * Copyright (c) 2019, Oracle and/or its affiliates. All rights reserved.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License, version 2.0,
 * as published by the Free Software Foundation.
 *
 * This program is designed to work with certain software (including
 * but not limited to OpenSSL) that is licensed under separate terms, as
 * designated in a particular file or component or in included license
 * documentation.  The authors of MySQL hereby grant you an additional
 * permission to link the program and your derivative works with the
 * separately licensed software that they have either included with
 * the program or referenced in the documentation.
 * This program is distributed in the hope that it will be useful,  but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See
 * the GNU General Public License, version 2.0, for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA
 */

/*
 * thysql: modified from MySQL Workbench (library/base/symbol-info.cpp at dc3590db). Changes:
 *   - keyword_list84.h added; MySQL 8.4 (80400 and up) no longer maps to MySQL80.
 *   - Reserved keywords were collected into a local set and never stored, so
 *     isReservedKeyword() was always false. They are stored now.
 *   - Lookups upper-case the name, because the tables are upper case.
 *   - MySQL 8.4 has no function table of its own here; it uses the 8.0 one.
 */

#include "base/symbol-info.h"

#include <algorithm>
#include <cctype>
#include <map>
#include <set>

// The keyword tables (keyword_list*.h) are arrays of this type.
typedef struct {
  const char *word;
  int reserved;
} keyword_t;

#include "system-functions.h"

#include "keyword_list56.h"
#include "keyword_list57.h"
#include "keyword_list80.h"
#include "keyword_list84.h"

using namespace base;

//----------------------------------------------------------------------------------------------------------------------

static std::set<std::string> empty;

std::set<std::string> const& MySQLSymbolInfo::systemFunctionsForVersion(MySQLVersion version) {
  switch (version) {
    case MySQLVersion::MySQL56:
      return systemFunctions56;
    case MySQLVersion::MySQL57:
      return systemFunctions57;
    case MySQLVersion::MySQL80:
    case MySQLVersion::MySQL84:
      return systemFunctions80;

    default:
      return empty;
  }
}

//----------------------------------------------------------------------------------------------------------------------

namespace {

// Keyword and reserved word sets per version, filled from the keyword tables on first use.
struct KeywordSets {
  std::set<std::string> keywords;
  std::set<std::string> reserved;
};

template <size_t N>
void collect(const keyword_t (&table)[N], KeywordSets &sets) {
  for (const keyword_t &entry : table) {
    sets.keywords.insert(entry.word);
    if (entry.reserved != 0)
      sets.reserved.insert(entry.word);
  }
}

const KeywordSets &setsForVersion(MySQLVersion version) {
  static std::map<MySQLVersion, KeywordSets> cache;

  auto found = cache.find(version);
  if (found != cache.end())
    return found->second;

  KeywordSets sets;
  switch (version) {
    case MySQLVersion::MySQL56:
      collect(keyword_list56, sets);
      break;
    case MySQLVersion::MySQL57:
      collect(keyword_list57, sets);
      break;
    case MySQLVersion::MySQL80:
      collect(keyword_list80, sets);
      break;
    case MySQLVersion::MySQL84:
      collect(keyword_list84, sets);
      break;
    default:
      break;
  }
  return cache.emplace(version, std::move(sets)).first->second;
}

// Keyword tables are upper case, so names are folded before lookup.
std::string toUpper(std::string const& name) {
  std::string result = name;
  std::transform(result.begin(), result.end(), result.begin(), [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
  return result;
}

} // namespace

std::set<std::string> const& MySQLSymbolInfo::keywordsForVersion(MySQLVersion version) {
  return setsForVersion(version).keywords;
}

//----------------------------------------------------------------------------------------------------------------------

bool MySQLSymbolInfo::isReservedKeyword(std::string const& identifier, MySQLVersion version) {
  return setsForVersion(version).reserved.count(toUpper(identifier)) > 0;
}

//----------------------------------------------------------------------------------------------------------------------

/**
 * For both, reserved and non-reserved keywords.
 */
bool MySQLSymbolInfo::isKeyword(std::string const& identifier, MySQLVersion version) {
  return setsForVersion(version).keywords.count(toUpper(identifier)) > 0;
}

//----------------------------------------------------------------------------------------------------------------------

MySQLVersion MySQLSymbolInfo::numberToVersion(long version) {
  long major = version / 10000, minor = (version / 100) % 100;

  if (major < 5 || major > 8)
    return MySQLVersion::Unknown;

  if (major == 8)
    return minor >= 4 ? MySQLVersion::MySQL84 : MySQLVersion::MySQL80;

  if (major != 5)
    return MySQLVersion::Unknown;

  switch (minor) {
    case 6:
      return MySQLVersion::MySQL56;
    case 7:
      return MySQLVersion::MySQL57;
    default:
      return MySQLVersion::Unknown;
  }
}

//----------------------------------------------------------------------------------------------------------------------

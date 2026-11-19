// C shim over the ANTLR4 MySQL parser and antlr4-c3. See shim.h for the API and
// src/sql/antlr/README.md for the parser sources.

#include "shim.h"

#include <algorithm>
#include <cctype>
#include <memory>
#include <new>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "CodeCompletionCore.hpp"
#include "MySQLLexer.h"
#include "MySQLParser.h"
#include "MySQLRecognizerCommon.h"
#include "antlr4-runtime.h"

using namespace antlr4;
using parsers::MySQLLexer;
using parsers::MySQLParser;
using parsers::MySQLRecognizerCommon;

// The header's numbers must match the generated parser.
static_assert(static_cast<int>(MYSQL_RULE_QUERY) == static_cast<int>(MySQLParser::RuleQuery), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_COLUMN_INTERNAL_REF) == static_cast<int>(MySQLParser::RuleColumnInternalRef), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_COLUMN_REF) == static_cast<int>(MySQLParser::RuleColumnRef), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_TABLE_WILD) == static_cast<int>(MySQLParser::RuleTableWild), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_SCHEMA_REF) == static_cast<int>(MySQLParser::RuleSchemaRef), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_PROCEDURE_REF) == static_cast<int>(MySQLParser::RuleProcedureRef), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_FUNCTION_REF) == static_cast<int>(MySQLParser::RuleFunctionRef), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_TRIGGER_REF) == static_cast<int>(MySQLParser::RuleTriggerRef), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_VIEW_REF) == static_cast<int>(MySQLParser::RuleViewRef), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_TABLESPACE_REF) == static_cast<int>(MySQLParser::RuleTablespaceRef), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_LOGFILE_GROUP_REF) == static_cast<int>(MySQLParser::RuleLogfileGroupRef), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_EVENT_REF) == static_cast<int>(MySQLParser::RuleEventRef), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_ENGINE_REF) == static_cast<int>(MySQLParser::RuleEngineRef), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_SERVER_REF) == static_cast<int>(MySQLParser::RuleServerRef), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_FILTER_TABLE_REF) == static_cast<int>(MySQLParser::RuleFilterTableRef), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_TABLE_REF_WITH_WILDCARD) == static_cast<int>(MySQLParser::RuleTableRefWithWildcard), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_TABLE_REF) == static_cast<int>(MySQLParser::RuleTableRef), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_LABEL_REF) == static_cast<int>(MySQLParser::RuleLabelRef), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_CHARSET_NAME) == static_cast<int>(MySQLParser::RuleCharsetName), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_COLLATION_NAME) == static_cast<int>(MySQLParser::RuleCollationName), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_USER) == static_cast<int>(MySQLParser::RuleUser), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_USER_VARIABLE) == static_cast<int>(MySQLParser::RuleUserVariable), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_SYSTEM_VARIABLE) == static_cast<int>(MySQLParser::RuleSystemVariable), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_SET_SYSTEM_VARIABLE) == static_cast<int>(MySQLParser::RuleSetSystemVariable), "rule id");

static_assert(static_cast<int>(MYSQL_RULE_DELETE_STATEMENT) == static_cast<int>(MySQLParser::RuleDeleteStatement), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_INSERT_STATEMENT) == static_cast<int>(MySQLParser::RuleInsertStatement), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_INSERT_FROM_CONSTRUCTOR) == static_cast<int>(MySQLParser::RuleInsertFromConstructor), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_FIELDS) == static_cast<int>(MySQLParser::RuleFields), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_VALUE_LIST) == static_cast<int>(MySQLParser::RuleValueList), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_VALUES) == static_cast<int>(MySQLParser::RuleValues), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_QUERY_EXPRESSION_BODY) == static_cast<int>(MySQLParser::RuleQueryExpressionBody), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_QUERY_EXPRESSION_PARENS) == static_cast<int>(MySQLParser::RuleQueryExpressionParens), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_QUERY_SPECIFICATION) == static_cast<int>(MySQLParser::RuleQuerySpecification), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_SUBQUERY) == static_cast<int>(MySQLParser::RuleSubquery), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_COMMON_TABLE_EXPRESSION) == static_cast<int>(MySQLParser::RuleCommonTableExpression), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_SELECT_ITEM_LIST) == static_cast<int>(MySQLParser::RuleSelectItemList), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_SELECT_ITEM) == static_cast<int>(MySQLParser::RuleSelectItem), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_SELECT_ALIAS) == static_cast<int>(MySQLParser::RuleSelectAlias), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_SINGLE_TABLE) == static_cast<int>(MySQLParser::RuleSingleTable), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_DERIVED_TABLE) == static_cast<int>(MySQLParser::RuleDerivedTable), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_TABLE_ALIAS) == static_cast<int>(MySQLParser::RuleTableAlias), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_UPDATE_STATEMENT) == static_cast<int>(MySQLParser::RuleUpdateStatement), "rule id");
static_assert(static_cast<int>(MYSQL_RULE_IDENTIFIER) == static_cast<int>(MySQLParser::RuleIdentifier), "rule id");

static_assert(static_cast<int>(MYSQL_TOKEN_MULT_OPERATOR) == static_cast<int>(MySQLLexer::MULT_OPERATOR), "token type");
static_assert(static_cast<int>(MYSQL_TOKEN_DOT_SYMBOL) == static_cast<int>(MySQLLexer::DOT_SYMBOL), "token type");
static_assert(static_cast<int>(MYSQL_TOKEN_COMMA_SYMBOL) == static_cast<int>(MySQLLexer::COMMA_SYMBOL), "token type");
static_assert(static_cast<int>(MYSQL_TOKEN_OPEN_PAR_SYMBOL) == static_cast<int>(MySQLLexer::OPEN_PAR_SYMBOL), "token type");
static_assert(static_cast<int>(MYSQL_TOKEN_CLOSE_PAR_SYMBOL) == static_cast<int>(MySQLLexer::CLOSE_PAR_SYMBOL), "token type");

static_assert(static_cast<int>(MYSQL_MODE_ANSI_QUOTES) == static_cast<int>(MySQLRecognizerCommon::AnsiQuotes), "sql mode");
static_assert(static_cast<int>(MYSQL_MODE_HIGH_NOT_PRECEDENCE) == static_cast<int>(MySQLRecognizerCommon::HighNotPrecedence), "sql mode");
static_assert(static_cast<int>(MYSQL_MODE_PIPES_AS_CONCAT) == static_cast<int>(MySQLRecognizerCommon::PipesAsConcat), "sql mode");
static_assert(static_cast<int>(MYSQL_MODE_IGNORE_SPACE) == static_cast<int>(MySQLRecognizerCommon::IgnoreSpace), "sql mode");
static_assert(static_cast<int>(MYSQL_MODE_NO_BACKSLASH_ESCAPES) == static_cast<int>(MySQLRecognizerCommon::NoBackslashEscapes), "sql mode");

// The parser objects are created per call (they hold a reference to the input), so the
// state kept here is only the configuration and the buffers handed out to the caller.
struct mysql_parser {
  long server_version = 80400;
  unsigned sql_mode = 0;

  std::vector<std::string> error_messages;
  std::vector<mysql_parse_error> errors;

  std::vector<std::string> candidate_texts;
  std::vector<mysql_candidate> candidates;

  std::vector<mysql_tree_node> nodes;
  // The generated parser's rule names, copied on the first parse.
  std::vector<std::string> rule_names;
};

namespace {

// Input text as code points, plus the byte offset of every code point (and of the end).
struct DecodedText {
  std::u32string text;
  std::vector<size_t> byte_offset; // Size is text.size() + 1.

  size_t byteAt(size_t index) const { return byte_offset[std::min(index, text.size())]; }
};

// Decodes one UTF-8 sequence at p. Returns its length, or 0 if it is not valid UTF-8.
size_t decodeOne(const unsigned char *p, size_t available, char32_t &cp) {
  unsigned char c = p[0];
  if (c < 0x80) {
    cp = c;
    return 1;
  }

  size_t length;
  char32_t minimum;
  if ((c & 0xE0) == 0xC0) {
    length = 2;
    cp = c & 0x1F;
    minimum = 0x80;
  } else if ((c & 0xF0) == 0xE0) {
    length = 3;
    cp = c & 0x0F;
    minimum = 0x800;
  } else if ((c & 0xF8) == 0xF0) {
    length = 4;
    cp = c & 0x07;
    minimum = 0x10000;
  } else {
    return 0;
  }

  if (available < length)
    return 0;
  for (size_t i = 1; i < length; ++i) {
    if ((p[i] & 0xC0) != 0x80)
      return 0;
    cp = (cp << 6) | (p[i] & 0x3F);
  }
  if (cp < minimum || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
    return 0;
  return length;
}

// Encodes code points as UTF-8.
std::string encodeUtf8(std::u32string_view text) {
  std::string out;
  out.reserve(text.size());
  for (char32_t cp : text) {
    if (cp < 0x80) {
      out.push_back(static_cast<char>(cp));
    } else if (cp < 0x800) {
      out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
      out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
      out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
      out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
      out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
      out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
  }
  return out;
}

// Invalid bytes become U+FFFD and take one byte each, so offsets still map back to the input.
DecodedText decodeUtf8(const char *data, size_t length) {
  DecodedText out;
  out.text.reserve(length);
  out.byte_offset.reserve(length + 1);

  const unsigned char *bytes = reinterpret_cast<const unsigned char *>(data);
  size_t i = 0;
  while (i < length) {
    char32_t cp = 0;
    size_t n = decodeOne(bytes + i, length - i, cp);
    if (n == 0) {
      cp = 0xFFFD;
      n = 1;
    }
    out.text.push_back(cp);
    out.byte_offset.push_back(i);
    i += n;
  }
  out.byte_offset.push_back(length);
  return out;
}

// Input stream over already decoded text (ANTLRInputStream only decodes UTF-8 itself, and
// strictly, which would not match the offsets above).
class CodePointInput : public ANTLRInputStream {
public:
  explicit CodePointInput(const std::u32string &text) : ANTLRInputStream() { _data = text; }
};


// Stores the candidates in the parser object. Their text pointers are valid until the next call.
void storeCandidates(mysql_parser &parser, const std::vector<std::pair<int, int>> &kinds_and_ids,
                     const std::vector<std::string> &texts) {
  parser.candidate_texts = texts;
  parser.candidates.clear();
  for (size_t i = 0; i < kinds_and_ids.size(); ++i) {
    mysql_candidate candidate{};
    candidate.kind = kinds_and_ids[i].first;
    candidate.id = kinds_and_ids[i].second;
    candidate.text = parser.candidate_texts[i].c_str();
    parser.candidates.push_back(candidate);
  }
}

// Words that can end a completed identifier or keyword, so a caret right after one completes it.
bool endsWord(const std::string &text) {
  if (text.empty())
    return false;
  unsigned char last = static_cast<unsigned char>(text.back());
  return std::isalnum(last) || last == '_' || last == '$' || last == '`' || last >= 0x80;
}

// Keyword text of a token symbol, such as "SELECT" for SELECT_SYMBOL. Empty if the symbol is not a keyword.
std::string keywordForSymbol(std::string_view symbolic) {
  const std::string_view suffix = "_SYMBOL";
  if (symbolic.size() <= suffix.size() || symbolic.substr(symbolic.size() - suffix.size()) != suffix)
    return {};
  std::string keyword(symbolic.substr(0, symbolic.size() - suffix.size()));
  for (char &c : keyword)
    c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
  return keyword;
}

// Collects the syntax and lexer errors of one parse, in input order, with their messages.
class ErrorCollector : public BaseErrorListener {
public:
  explicit ErrorCollector(const DecodedText &text) : text_(text) {
    // Code point index of the first character of every line, to turn line and column into an offset.
    lineStarts_.push_back(0);
    for (size_t i = 0; i < text_.text.size(); ++i) {
      if (text_.text[i] == U'\n')
        lineStarts_.push_back(i + 1);
    }
  }

  void syntaxError(Recognizer *recognizer, Token *offending, size_t line, size_t column, const std::string &msg,
                   std::exception_ptr) override {
    (void)msg;
    Entry entry{};
    entry.error.line = static_cast<unsigned>(line);
    entry.error.column = static_cast<unsigned>(column);
    size_t n = text_.text.size();

    if (offending != nullptr) {
      // Parser error: the offending token. The end of input is an empty range at the end.
      if (offending->getType() == Token::EOF) {
        entry.error.start = entry.error.end = text_.byteAt(n);
        entry.message = "unexpected end of input";
      } else {
        entry.error.start = text_.byteAt(offending->getStartIndex());
        entry.error.end = std::max(entry.error.start, text_.byteAt(offending->getStopIndex() + 1));
        entry.message = "\"" + offending->getText() + "\" is not valid at this position";
      }
      if (auto *parser = dynamic_cast<Parser *>(recognizer)) {
        std::string expecting = describeExpected(*parser);
        if (!expecting.empty())
          entry.message += ", expecting " + expecting;
      }
    } else {
      // Lexer error. ANTLR gives the token start as line and column. The lexer's current
      // position is where it noticed the problem, so the error covers the text in between.
      size_t start = std::min(lineStart(line) + column, n);
      size_t current = 0;
      if (auto *lexer = dynamic_cast<Lexer *>(recognizer))
        current = lexer->getCharIndex();
      size_t end = std::min(std::max(current, start + 1), n);
      entry.error.start = text_.byteAt(start);
      entry.error.end = text_.byteAt(end);
      entry.message = start >= n ? "unexpected end of input"
                                 : "unrecognized text \"" + encodeUtf8(text_.text.substr(start, end - start)) + "\"";
    }
    entries_.push_back(std::move(entry));
  }

  size_t count() const { return entries_.size(); }

  // Sorts the errors by position (stable, so errors at one place keep the order they were found in)
  // and stores them in the parser object. The strings are owned by the parser object.
  void storeIn(mysql_parser &parser) {
    std::stable_sort(entries_.begin(), entries_.end(),
                     [](const Entry &a, const Entry &b) { return a.error.start < b.error.start; });
    parser.error_messages.clear();
    parser.errors.clear();
    for (const Entry &entry : entries_)
      parser.error_messages.push_back(entry.message);
    for (size_t i = 0; i < entries_.size(); ++i) {
      mysql_parse_error error = entries_[i].error;
      error.message = parser.error_messages[i].c_str();
      parser.errors.push_back(error);
    }
  }

private:
  struct Entry {
    mysql_parse_error error;
    std::string message;
  };

  // Names of the tokens the parser expected here: "an identifier", or a list of keywords.
  static std::string describeExpected(Parser &parser) {
    const dfa::Vocabulary &vocabulary = parser.getVocabulary();
    bool identifier = false;
    std::vector<std::string> keywords;
    for (ssize_t type : parser.getExpectedTokens().toList()) {
      if (type <= 0)
        continue;
      if (type == MySQLLexer::IDENTIFIER || type == MySQLLexer::BACK_TICK_QUOTED_ID) {
        identifier = true;
        continue;
      }
      std::string keyword = keywordForSymbol(vocabulary.getSymbolicName(static_cast<size_t>(type)));
      if (!keyword.empty())
        keywords.push_back(keyword);
    }

    if (identifier)
      return "an identifier";
    if (keywords.empty())
      return "";

    // Keep the list short; the first few are enough to point the user in the right direction.
    constexpr size_t kMaxListed = 6;
    std::string list;
    for (size_t i = 0; i < keywords.size() && i < kMaxListed; ++i) {
      if (i > 0)
        list += (i + 1 == keywords.size() || i + 1 == kMaxListed) ? " or " : ", ";
      list += keywords[i];
    }
    if (keywords.size() > kMaxListed)
      list += ", ...";
    return list;
  }

  // Code point index of the first character of a 1-based line.
  size_t lineStart(size_t line) const {
    return line >= 1 && line <= lineStarts_.size() ? lineStarts_[line - 1] : text_.text.size();
  }

  const DecodedText &text_;
  std::vector<size_t> lineStarts_;
  std::vector<Entry> entries_;
};

// Byte range of a token. EOF, and a token that error recovery made up (it has no place in the
// input), are an empty range: at the end of the input, or at `fallback`.
std::pair<size_t, size_t> tokenRange(const Token *token, const DecodedText &text, size_t fallback) {
  if (token == nullptr || token->getStartIndex() == INVALID_INDEX || token->getStopIndex() == INVALID_INDEX)
    return {fallback, fallback};
  if (token->getType() == Token::EOF) {
    size_t end = text.byteAt(text.text.size());
    return {end, end};
  }
  size_t start = text.byteAt(token->getStartIndex());
  size_t end = std::max(start, text.byteAt(token->getStopIndex() + 1));
  return {start, end};
}

// Stores the parse tree under `root` in the parser object, in preorder. The walk keeps its own
// stack, because expressions can nest deeply enough to overflow the C++ one.
void storeTree(mysql_parser &parser, tree::ParseTree *root, const DecodedText &text) {
  parser.nodes.clear();
  if (root == nullptr)
    return;

  struct Frame {
    tree::ParseTree *node;
    size_t index;
    size_t child;
  };
  std::vector<Frame> stack;
  size_t last_end = 0; // End of the last token stored, where a made-up token is put.

  auto push = [&](tree::ParseTree *node, size_t parent) {
    mysql_tree_node out{};
    out.parent = parent;
    if (auto *ctx = dynamic_cast<ParserRuleContext *>(node)) {
      out.rule = static_cast<int>(ctx->getRuleIndex());
      out.token = 0;
      auto first = tokenRange(ctx->start, text, last_end);
      out.start = out.end = first.first;
      if (ctx->stop != nullptr && ctx->start != nullptr && ctx->stop->getTokenIndex() >= ctx->start->getTokenIndex() &&
          ctx->stop->getStartIndex() != INVALID_INDEX) {
        auto last = tokenRange(ctx->stop, text, first.first);
        out.end = std::max(out.start, last.second);
      }
      if (ctx->exception != nullptr)
        out.flags |= MYSQL_NODE_ERROR;
    } else if (auto *terminal = dynamic_cast<tree::TerminalNode *>(node)) {
      Token *token = terminal->getSymbol();
      out.rule = -1;
      out.token = token != nullptr ? static_cast<int>(token->getType()) : 0;
      auto range = tokenRange(token, text, last_end);
      out.start = range.first;
      out.end = range.second;
      last_end = std::max(last_end, out.end);
      if (dynamic_cast<tree::ErrorNode *>(node) != nullptr)
        out.flags |= MYSQL_NODE_ERROR;
      if (token == nullptr || token->getStartIndex() == INVALID_INDEX)
        out.flags |= MYSQL_NODE_ERROR | MYSQL_NODE_MISSING;
    } else {
      return;
    }
    parser.nodes.push_back(out);
    stack.push_back(Frame{node, parser.nodes.size() - 1, 0});
  };

  push(root, static_cast<size_t>(-1));
  while (!stack.empty()) {
    Frame &top = stack.back();
    if (top.child < top.node->children.size()) {
      tree::ParseTree *child = top.node->children[top.child++];
      size_t parent = top.index;
      push(child, parent);
      continue;
    }
    parser.nodes[top.index].next = parser.nodes.size();
    stack.pop_back();
  }
}

// Configures a lexer or parser with the server version and SQL mode of the parser object.
template <typename RecognizerType>
void configure(RecognizerType &recognizer, const mysql_parser &parser) {
  recognizer.serverVersion = parser.server_version;
  recognizer.sqlMode = static_cast<MySQLRecognizerCommon::SqlMode>(parser.sql_mode);
}

// Parses the whole input with the query rule. Two stages: SLL with bail-out on the first error
// (fast, and the common case), then LL with error reporting if the first stage failed. The second
// stage starts over, so the errors it reports are the ones the caller gets. Lexer errors are
// found while the tokens are read, before either stage, and are reported in both cases.
void checkInput(mysql_parser &parser, const DecodedText &text, bool keep_tree) {
  CodePointInput input(text.text);
  MySQLLexer lexer(&input);
  configure(lexer, parser);

  ErrorCollector errors(text);
  lexer.removeErrorListeners();
  lexer.addErrorListener(&errors);

  CommonTokenStream tokens(&lexer);
  tokens.fill();

  MySQLParser recognizer(&tokens);
  configure(recognizer, parser);
  if (parser.rule_names.empty())
    parser.rule_names = recognizer.getRuleNames();
  recognizer.removeErrorListeners();
  recognizer.setErrorHandler(std::make_shared<BailErrorStrategy>());
  recognizer.getInterpreter<atn::ParserATNSimulator>()->setPredictionMode(atn::PredictionMode::SLL);

  parser.nodes.clear();
  bool clean = false;
  try {
    tree::ParseTree *root = recognizer.query();
    clean = true;
    if (keep_tree)
      storeTree(parser, root, text);
  } catch (const std::exception &) {
    clean = false;
  }

  if (!clean) {
    tokens.seek(0);
    recognizer.reset();
    recognizer.setErrorHandler(std::make_shared<DefaultErrorStrategy>());
    recognizer.getInterpreter<atn::ParserATNSimulator>()->setPredictionMode(atn::PredictionMode::LL);
    recognizer.addErrorListener(&errors);
    tree::ParseTree *root = recognizer.query();
    if (keep_tree)
      storeTree(parser, root, text);
  }

  errors.storeIn(parser);
}

// Completion candidates for the caret at code point `caret`, with antlr4-c3 configured as in
// MySQL Workbench's code completion (library/parsers/code-completion/mysql-code-completion.cpp).
void collectCandidates(mysql_parser &parser, const DecodedText &text, size_t caret) {
  CodePointInput input(text.text);
  MySQLLexer lexer(&input);
  configure(lexer, parser);
  lexer.removeErrorListeners();

  CommonTokenStream tokens(&lexer);
  tokens.fill();

  MySQLParser recognizer(&tokens);
  configure(recognizer, parser);
  recognizer.removeErrorListeners();

  // c3 completes the token at this index: it considers the tokens before it as typed. A word
  // that the caret touches is the one being completed, so it is the token at the index.
  // Otherwise the candidates are for the first token at or after the caret.
  const std::vector<Token *> all = tokens.getTokens();
  size_t caretIndex = all.empty() ? 0 : all.back()->getTokenIndex();
  for (Token *token : all) {
    if (token->getChannel() != Token::DEFAULT_CHANNEL || token->getType() == Token::EOF)
      continue;
    size_t start = token->getStartIndex();
    size_t end = token->getStopIndex() + 1;
    if ((start < caret && caret <= end && endsWord(token->getText())) || start >= caret) {
      caretIndex = token->getTokenIndex();
      break;
    }
  }

  c3::CodeCompletionCore core(&recognizer);
  core.ignoredTokens = {
    MySQLLexer::EOF,
    MySQLLexer::EQUAL_OPERATOR,
    MySQLLexer::ASSIGN_OPERATOR,
    MySQLLexer::NULL_SAFE_EQUAL_OPERATOR,
    MySQLLexer::GREATER_OR_EQUAL_OPERATOR,
    MySQLLexer::GREATER_THAN_OPERATOR,
    MySQLLexer::LESS_OR_EQUAL_OPERATOR,
    MySQLLexer::LESS_THAN_OPERATOR,
    MySQLLexer::NOT_EQUAL_OPERATOR,
    MySQLLexer::NOT_EQUAL2_OPERATOR,
    MySQLLexer::PLUS_OPERATOR,
    MySQLLexer::MINUS_OPERATOR,
    MySQLLexer::MULT_OPERATOR,
    MySQLLexer::DIV_OPERATOR,
    MySQLLexer::MOD_OPERATOR,
    MySQLLexer::LOGICAL_NOT_OPERATOR,
    MySQLLexer::BITWISE_NOT_OPERATOR,
    MySQLLexer::SHIFT_LEFT_OPERATOR,
    MySQLLexer::SHIFT_RIGHT_OPERATOR,
    MySQLLexer::LOGICAL_AND_OPERATOR,
    MySQLLexer::BITWISE_AND_OPERATOR,
    MySQLLexer::BITWISE_XOR_OPERATOR,
    MySQLLexer::LOGICAL_OR_OPERATOR,
    MySQLLexer::BITWISE_OR_OPERATOR,
    MySQLLexer::DOT_SYMBOL,
    MySQLLexer::COMMA_SYMBOL,
    MySQLLexer::SEMICOLON_SYMBOL,
    MySQLLexer::COLON_SYMBOL,
    MySQLLexer::OPEN_PAR_SYMBOL,
    MySQLLexer::CLOSE_PAR_SYMBOL,
    MySQLLexer::OPEN_CURLY_SYMBOL,
    MySQLLexer::CLOSE_CURLY_SYMBOL,
    MySQLLexer::UNDERLINE_SYMBOL,
    MySQLLexer::AT_SIGN_SYMBOL,
    MySQLLexer::AT_AT_SIGN_SYMBOL,
    MySQLLexer::NULL2_SYMBOL,
    MySQLLexer::PARAM_MARKER,
    MySQLLexer::CONCAT_PIPES_SYMBOL,
    MySQLLexer::AT_TEXT_SUFFIX,
    MySQLLexer::BACK_TICK_QUOTED_ID,
    MySQLLexer::SINGLE_QUOTED_TEXT,
    MySQLLexer::DOUBLE_QUOTED_TEXT,
    MySQLLexer::NCHAR_TEXT,
    MySQLLexer::UNDERSCORE_CHARSET,
    MySQLLexer::IDENTIFIER,
    MySQLLexer::INT_NUMBER,
    MySQLLexer::LONG_NUMBER,
    MySQLLexer::ULONGLONG_NUMBER,
    MySQLLexer::DECIMAL_NUMBER,
    MySQLLexer::BIN_NUMBER,
    MySQLLexer::HEX_NUMBER,
  };
  core.preferredRules = {
    MySQLParser::RuleSchemaRef,
    MySQLParser::RuleTableRef, MySQLParser::RuleTableRefWithWildcard, MySQLParser::RuleFilterTableRef,
    MySQLParser::RuleColumnRef, MySQLParser::RuleColumnInternalRef, MySQLParser::RuleTableWild,
    MySQLParser::RuleFunctionRef, MySQLParser::RuleFunctionCall, MySQLParser::RuleRuntimeFunctionCall,
    MySQLParser::RuleTriggerRef, MySQLParser::RuleViewRef, MySQLParser::RuleProcedureRef,
    MySQLParser::RuleLogfileGroupRef, MySQLParser::RuleTablespaceRef, MySQLParser::RuleEngineRef,
    MySQLParser::RuleCollationName, MySQLParser::RuleCharsetName, MySQLParser::RuleEventRef,
    MySQLParser::RuleServerRef, MySQLParser::RuleUser,
    MySQLParser::RuleUserVariable, MySQLParser::RuleSystemVariable, MySQLParser::RuleLabelRef,
    MySQLParser::RuleSetSystemVariable,
    // For better handling, but will be ignored.
    MySQLParser::RuleParameterName, MySQLParser::RuleProcedureName, MySQLParser::RuleIdentifier,
    MySQLParser::RuleLabelIdentifier,
  };

  c3::CandidatesCollection result = core.collectCandidates(caretIndex);

  const dfa::Vocabulary &vocabulary = recognizer.getVocabulary();
  const std::vector<std::string> &ruleNames = recognizer.getRuleNames();

  std::vector<std::pair<int, int>> kinds_and_ids;
  std::vector<std::string> texts;
  for (const auto &entry : result.tokens) {
    std::string keyword = keywordForSymbol(vocabulary.getSymbolicName(entry.first));
    if (keyword.empty())
      continue; // Operators and literals are not offered as text.
    kinds_and_ids.emplace_back(MYSQL_CANDIDATE_TOKEN, static_cast<int>(entry.first));
    texts.push_back(keyword);
  }
  for (const auto &entry : result.rules) {
    kinds_and_ids.emplace_back(MYSQL_CANDIDATE_RULE, static_cast<int>(entry.first));
    texts.push_back(entry.first < ruleNames.size() ? ruleNames[entry.first] : std::string());
  }
  storeCandidates(parser, kinds_and_ids, texts);
}

} // namespace

extern "C" {

mysql_parser *mysql_parser_new(unsigned server_version, unsigned sql_mode_flags) {
  mysql_parser *parser = new (std::nothrow) mysql_parser();
  if (parser == nullptr)
    return nullptr;
  parser->server_version = static_cast<long>(server_version);
  parser->sql_mode = sql_mode_flags;
  return parser;
}

void mysql_parser_free(mysql_parser *parser) { delete parser; }

void mysql_parser_set_version(mysql_parser *parser, unsigned server_version) {
  if (parser != nullptr)
    parser->server_version = static_cast<long>(server_version);
}

void mysql_parser_set_sql_mode(mysql_parser *parser, unsigned sql_mode_flags) {
  if (parser != nullptr)
    parser->sql_mode = sql_mode_flags;
}

// Parses `sql` for mysql_parser_check() and mysql_parser_parse().
static size_t parseInput(mysql_parser *parser, const char *sql, size_t len, bool keep_tree) {
  if (parser == nullptr)
    return 0;
  try {
    DecodedText text = decodeUtf8(sql != nullptr ? sql : "", sql != nullptr ? len : 0);
    checkInput(*parser, text, keep_tree);
    return parser->errors.size();
  } catch (...) {
    parser->nodes.clear();
    // Something inside the parser failed. Report it as one error over the whole input.
    parser->error_messages.assign(1, "internal parser error");
    parser->errors.assign(1, mysql_parse_error{0, len, 1, 0, nullptr});
    parser->errors[0].message = parser->error_messages[0].c_str();
    return 1;
  }
}

size_t mysql_parser_check(mysql_parser *parser, const char *sql, size_t len) {
  return parseInput(parser, sql, len, false);
}

size_t mysql_parser_parse(mysql_parser *parser, const char *sql, size_t len) {
  return parseInput(parser, sql, len, true);
}

size_t mysql_parser_node_count(mysql_parser *parser) { return parser != nullptr ? parser->nodes.size() : 0; }

const mysql_tree_node *mysql_parser_nodes(mysql_parser *parser) {
  return parser != nullptr && !parser->nodes.empty() ? parser->nodes.data() : nullptr;
}

const char *mysql_parser_rule_name(mysql_parser *parser, int rule) {
  if (parser == nullptr || rule < 0 || static_cast<size_t>(rule) >= parser->rule_names.size())
    return nullptr;
  return parser->rule_names[static_cast<size_t>(rule)].c_str();
}

const mysql_parse_error *mysql_parser_error(mysql_parser *parser, size_t index) {
  if (parser == nullptr || index >= parser->errors.size())
    return nullptr;
  return &parser->errors[index];
}

size_t mysql_parser_candidates(mysql_parser *parser, const char *sql, size_t len, size_t caret) {
  if (parser == nullptr)
    return 0;
  try {
    DecodedText text = decodeUtf8(sql != nullptr ? sql : "", sql != nullptr ? len : 0);
    size_t caret_bytes = std::min(caret, len);
    // First code point at or after the caret byte.
    size_t caret_cp = static_cast<size_t>(
      std::lower_bound(text.byte_offset.begin(), text.byte_offset.end(), caret_bytes) - text.byte_offset.begin());
    collectCandidates(*parser, text, caret_cp);
    return parser->candidates.size();
  } catch (...) {
    parser->candidate_texts.clear();
    parser->candidates.clear();
    return 0;
  }
}

const mysql_candidate *mysql_parser_candidate(mysql_parser *parser, size_t index) {
  if (parser == nullptr || index >= parser->candidates.size())
    return nullptr;
  return &parser->candidates[index];
}

} // extern "C"

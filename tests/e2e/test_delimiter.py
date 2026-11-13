"""DELIMITER, --delimiter, and source, as in mysql.cc.

A script defines a stored procedure and a trigger under `DELIMITER $$`, so the
semicolons inside their bodies are not statement ends. The same script runs
from stdin, from `source` on stdin, from `source` in the REPL, and with -e.
"""

import os
import re

import harness
from harness import ROOT_PASSWORD, ROOT_USER, TEST_DB, E2ETestCase, password_env

ENTER = "\r"

SETUP_SQL = """\
DROP TRIGGER IF EXISTS delim_trg;
DROP PROCEDURE IF EXISTS delim_add;
DROP TABLE IF EXISTS delim_log;
DROP TABLE IF EXISTS delim_audit;
CREATE TABLE delim_log (id INT AUTO_INCREMENT PRIMARY KEY, note VARCHAR(64));
CREATE TABLE delim_audit (note VARCHAR(64));
DELIMITER $$
CREATE PROCEDURE delim_add(IN n INT)
BEGIN
  DECLARE i INT DEFAULT 0;
  WHILE i < n DO
    INSERT INTO delim_log (note) VALUES (CONCAT('row ', i));
    SET i = i + 1;
  END WHILE;
END$$
CREATE TRIGGER delim_trg AFTER INSERT ON delim_log FOR EACH ROW
BEGIN
  INSERT INTO delim_audit (note) VALUES (CONCAT('saw ', NEW.note));
END$$
DELIMITER ;
CALL delim_add(2);
INSERT INTO delim_log (note) VALUES ('marker');
SELECT note FROM delim_log ORDER BY id;
SELECT note FROM delim_audit ORDER BY note;
"""

# Batch output: two tab-separated result sets, each with a header line.
SETUP_OUTPUT = (
    "note\nrow 0\nrow 1\nmarker\n"
    "note\nsaw marker\nsaw row 0\nsaw row 1\n"
)


class DelimiterTests(E2ETestCase):
    def thysql(self, server, args, stdin=None, env=None):
        return harness.run_thysql(
            server.connect_args(ROOT_USER) + ["--database", TEST_DB] + list(args),
            stdin=stdin,
            env=env if env is not None else {"MYSQL_PWD": ROOT_PASSWORD},
        )

    def write_file(self, name, text):
        path = os.path.join(self.home, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        return path

    def test_delimiter_script_on_stdin_defines_procedure_and_trigger(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, [], stdin=SETUP_SQL)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, SETUP_OUTPUT)
                self.assertEqual(result.stderr, "")

    def test_source_on_stdin_runs_the_script_file(self):
        path = self.write_file("setup.sql", SETUP_SQL)
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, [], stdin=f"source {path}\n")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, SETUP_OUTPUT)

    def test_backslash_dot_is_an_alias_for_source(self):
        path = self.write_file("setup_alias.sql", SETUP_SQL)
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, [], stdin=f"\\. {path}\n")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, SETUP_OUTPUT)

    def test_source_in_the_repl_runs_the_script_and_keeps_the_prompt(self):
        path = self.write_file("setup_repl.sql", SETUP_SQL)
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.interactive(
                    server.connect_args(ROOT_USER) + [TEST_DB],
                    env=password_env(ROOT_USER),
                )
                session.expect("Welcome to thysql.")
                prompt = f"{ROOT_USER}@127.0.0.1:{server.port}/{TEST_DB}> "
                session.expect(prompt)
                session.send(f"source {path}" + ENTER)
                session.expect(re.compile(r"\|\s*saw row 1\s*\|"))
                session.expect(prompt)
                session.send("\x04")
                self.assertEqual(session.wait_exit(), 0, session.buffer)

    def test_delimiter_typed_at_the_repl_prompt_changes_the_terminator(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.interactive(
                    server.connect_args(ROOT_USER) + [TEST_DB],
                    env=password_env(ROOT_USER),
                )
                session.expect("Welcome to thysql.")
                prompt = f"{ROOT_USER}@127.0.0.1:{server.port}/{TEST_DB}> "
                session.expect(prompt)
                # Wait for "\n" before the prompt. A bare prompt also appears while the line is
                # being typed, and input sent before the REPL is ready is dropped.
                session.send("delimiter $$" + ENTER)
                session.expect("\n" + prompt)
                session.send("select 'typed' as t; select 'semi' as s$$" + ENTER)
                session.expect(re.compile(r"\|\s*typed\s*\|\s*\n"))
                session.expect(re.compile(r"\|\s*semi\s*\|"))
                session.expect("\n" + prompt)
                session.send("\x04")
                self.assertEqual(session.wait_exit(), 0, session.buffer)

    def test_execute_with_delimiter_flag(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(
                    server,
                    ["--delimiter=$$", "-e", "select 1 as one; select 2 as two$$"],
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "one\n1\ntwo\n2\n")

    def test_delimiter_command_in_execute_text(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(
                    server,
                    ["-e", "delimiter //\nselect 'slash' as v//\ndelimiter ;\nselect 'semi' as w;"],
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "v\nslash\nw\nsemi\n")

    def test_nested_source_runs_files_in_order(self):
        self.write_file("inner.sql", "select 'inner' as i;\n")
        outer = self.write_file("outer.sql", f"source {os.path.join(self.home, 'inner.sql')}\nselect 'outer' as o;\n")
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, [], stdin=f"source {outer}\n")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "i\ninner\no\nouter\n")

    def test_without_force_a_failing_sourced_statement_stops_the_run(self):
        path = self.write_file("bad.sql", "select * from missing_table;\nselect 2 as two;\n")
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, [], stdin=f"source {path}\nselect 3 as three;\n")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertRegex(result.stderr, r"(?m)^ERROR 1146 \(42S02\) at line 1:")

    def test_force_keeps_going_through_a_sourced_file(self):
        path = self.write_file("bad_force.sql", "select * from missing_table;\nselect 2 as two;\n")
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["-f"], stdin=f"source {path}\nselect 3 as three;\n")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "two\n2\nthree\n3\n")
                self.assertRegex(result.stderr, r"(?m)^ERROR 1146 \(42S02\) at line 1:")

    def test_source_of_a_missing_file_fails(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                missing = os.path.join(self.home, "no_such_file.sql")
                result = self.thysql(server, [], stdin=f"source {missing}\n")
                self.assertEqual(result.returncode, 1)
                self.assertIn("Cannot open file", result.stderr)

    def test_source_nesting_has_a_depth_limit(self):
        loop = os.path.join(self.home, "loop.sql")
        self.write_file("loop.sql", f"source {loop}\n")
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, [], stdin=f"source {loop}\n")
                self.assertEqual(result.returncode, 1)
                self.assertIn("nested more than 16 levels deep", result.stderr)

    def test_bare_delimiter_command_is_an_error(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, [], stdin="delimiter\nselect 1;\n")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("DELIMITER must be followed by a 'delimiter' character or string", result.stderr)

    def test_invalid_delimiter_flag_is_rejected(self):
        for value in ("", "a\\b"):
            with self.subTest(value=value):
                result = harness.run_thysql([f"--delimiter={value}", "-e", "select 1"], env={})
                self.assertEqual(result.returncode, 1)
                self.assertIn("Invalid delimiter", result.stderr)

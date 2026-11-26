"""Editing a bot's memory: two files, a budget, and a save that is one rename.

A bot's memory is not host state — it is two files in the bot's own profile
(`memories/MEMORY.md` and `memories/USER.md`), read by the agent at the start of every turn. Until this
change both apps could only *look* at them, on the argument that the agent's memory tool owns the
format. The owner asked to edit them anyway ("edit memory option on bot settings of all bots"), so the
pane now writes, and these guards pin the five ways that can go wrong:

* a request that could reach a file other than the bot's own two — so the name is an allow-list of two
  literals, never a path, and a traversal is refused with the names that *are* accepted;
* a save that leaves half a file behind — so the write is a temp file and a rename, and the mode of the
  file being replaced is the mode that comes out;
* a save the runtime would refuse — so the budget is the runtime's own count, checked before the write
  and shown in the pane as `4,210 / 6,100 characters`;
* a pane that truncates silently instead of saying no — so a save over budget is a sentence naming the
  limit and the overage, and the button is off;
* an editor that changes a bot's memory without saying so — so a save confirms once, naming the file
  and saying the bot reads it on its next turn.

Static checks over the Rust and the Swift, in the style `test_vault_pane.py` and `test_vault_edit.py`
established: they fail at the moment the mistake is written. The behavioural side is Rust tests in
`hermeyd/src/bot_docs.rs` (the refusal codes, the inode that moves, the mode that does not, the file
that is never created for a name off the list); these pin the shape that makes it possible.
"""

from __future__ import annotations

import re
import unittest

from test_vault_pane import ROOT, block, code, module_code

HERMEYD = ROOT / "hermeyd" / "src"
BOT_DOCS_RAW = (HERMEYD / "bot_docs.rs").read_text(encoding="utf-8")
BOT_DOCS = code(BOT_DOCS_RAW)
BOT_DOCS_SHIPPED = module_code(BOT_DOCS_RAW)
MAIN_RS = code((HERMEYD / "main.rs").read_text(encoding="utf-8"))

KIT = ROOT / "Sources" / "HermesKit"
MEMORY_KIT = code((KIT / "BotMemory.swift").read_text(encoding="utf-8"))
POINTER = code((KIT / "EndlessSessionPointer.swift").read_text(encoding="utf-8"))
GATEWAY = code((KIT / "GatewayClient.swift").read_text(encoding="utf-8"))
ACTOR = code((KIT / "GatewayClientActor.swift").read_text(encoding="utf-8"))
APP_MODEL = code((ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8"))

UI = ROOT / "Sources" / "HermeyUI"
PANE = code((UI / "BotMemorySheet.swift").read_text(encoding="utf-8"))
EDITOR = code((UI / "BotMemoryEditor.swift").read_text(encoding="utf-8"))

MAC_SETTINGS = code((ROOT / "Apps" / "HermesMac" / "Views" / "MacBotSettingsSheet.swift")
                    .read_text(encoding="utf-8"))
PHONE_SETTINGS = code((ROOT / "Apps" / "HermesMobile" / "Views" / "BotModelSettingsScreen.swift")
                      .read_text(encoding="utf-8"))
PHONE_DOOR = code((ROOT / "Apps" / "HermesMobile" / "Views" / "BotSettingsDoor.swift")
                  .read_text(encoding="utf-8"))
PHONE_CHAT = code((ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift")
                  .read_text(encoding="utf-8"))

# The two files a bot's memory consists of. Both ends keep a list; this is what they must agree on.
THE_TWO_FILES = {"MEMORY.md", "USER.md"}

# What the runtime joins entries with, and counts. `tools/memory_tool_store.py:ENTRY_DELIMITER`.
DELIMITER = '\\n§\\n'


def route_body(opener: str) -> str:
    return block(BOT_DOCS, opener)


def declaration(text: str, opener: str, closer: str) -> str:
    """A declaration `block` cannot frame: it has no brace body of its own.

    `block` starts at the first `{` after the opener, and `const DOCUMENTS: [(&str, …); 2] = [ … ]`
    has none — it would return the body of whatever function came next. The closer is given because
    the array's own type carries a `;` before the value does.
    """
    start = text.index(opener)
    return text[start:text.index(closer, start) + len(closer)]


class EveryMemoryRouteIsTheOwners(unittest.TestCase):
    def test_all_three_routes_exist(self) -> None:
        for opener in ("pub async fn memory_get(", "pub async fn memory_get_one(",
                       "pub async fn memory_put("):
            self.assertIn(opener, BOT_DOCS, f"{opener!r} is gone")

    def test_the_device_is_checked_before_anything_else_happens(self) -> None:
        for opener in ("pub async fn memory_get(", "pub async fn memory_get_one(",
                       "pub async fn memory_put("):
            body = route_body(opener)
            self.assertIn("require_device(&st, &headers)?", body,
                          f"{opener!r} does not check the device")
            before = body[:body.index("require_device(")]
            for token in ("std::fs", "document_value(", "write_atomic(", "document_spec(", "crate::"):
                self.assertNotIn(token, before,
                                 f"{opener!r} touched {token!r} before the device was established")

    def test_they_are_mounted_where_the_panes_call_them(self) -> None:
        self.assertIn('"/v1/bots/{profile}/memory"', MAIN_RS)
        self.assertIn('"/v1/bots/{profile}/memory/{name}"', MAIN_RS)
        self.assertIn("bot_docs::memory_get", MAIN_RS)
        self.assertIn("bot_docs::memory_get_one", MAIN_RS)
        self.assertIn("bot_docs::memory_put", MAIN_RS)
        # A write is a PUT on the document's own path: a POST on the collection would be "create a
        # memory", which is not a thing this host does.
        self.assertNotRegex(MAIN_RS, r"/v1/bots/\{profile\}/memory\"[^\n]*\.post\(")


class ADocumentNameIsAnAllowListAndNeverAPath(unittest.TestCase):
    def test_the_two_names_are_the_whole_of_what_can_be_opened(self) -> None:
        documents = declaration(BOT_DOCS, "const DOCUMENTS", "];")
        found = set(re.findall(r'"([A-Z]+\.md)"', documents))
        self.assertEqual(found, THE_TWO_FILES, f"the allow-list changed: {sorted(found)}")
        # …and the app's copy of it is the same two, or a pane would offer a row the host refuses.
        allowed = declaration(MEMORY_KIT, "public static let allowedNames", "]")
        self.assertEqual(set(re.findall(r'"([A-Z]+\.md)"', allowed)), THE_TWO_FILES)

    def test_the_resolution_is_an_equality_match_and_not_a_join(self) -> None:
        spec = block(BOT_DOCS, "fn document_spec(name: &str)")
        self.assertIn("DOCUMENTS", spec)
        self.assertIn(".iter()", spec)
        self.assertIn("== name", spec, "the name must be compared, not used to build anything")
        for token in ("join(", "Path", "canonicalize", ".."):
            self.assertNotIn(token, spec, f"the allow-list builds a path: {token!r}")

    def test_both_document_routes_refuse_a_name_off_the_list_with_a_422(self) -> None:
        for opener in ("pub async fn memory_get_one(", "pub async fn memory_put("):
            body = route_body(opener)
            self.assertIn("document_spec(&name)", body, f"{opener!r} does not use the allow-list")
            self.assertIn("UNPROCESSABLE_ENTITY", body, f"{opener!r} does not answer 422")
            self.assertIn("names_sentence()", body,
                          f"{opener!r} refuses without naming the accepted documents")
            # The refusal comes before the file is looked at or written.
            after = "document_value(" if "memory_get_one" in opener else "write_atomic("
            self.assertLess(body.index("document_spec(&name)"), body.index(after),
                            f"{opener!r} resolves the name after it has used it")

    def test_the_refusal_names_both_files(self) -> None:
        sentence = block(BOT_DOCS, "fn names_sentence()")
        self.assertIn("DOCUMENTS[0].0", sentence)
        self.assertIn("DOCUMENTS[1].0", sentence)

    def test_the_path_helper_only_ever_takes_an_already_resolved_name(self) -> None:
        helper = block(BOT_DOCS, "fn document_path(dir: &FsPath, name: &str)")
        self.assertIn('dir.join("memories").join(name)', helper)
        # No route joins the request's own string onto anything: both go through the helper, whose
        # `name` is what `document_spec` accepted.
        for opener in ("pub async fn memory_get_one(", "pub async fn memory_put("):
            body = route_body(opener)
            self.assertNotIn("join(&name)", body)
            self.assertNotIn("join(name)", body)
            self.assertNotIn("Path::new", body)

    def test_the_app_refuses_a_name_off_the_list_before_it_builds_a_request(self) -> None:
        self.assertIn("public static func isAllowedName(_ name: String) -> Bool", MEMORY_KIT)
        self.assertIn("allowedNames.contains(name)", MEMORY_KIT)
        self.assertIn("static func memoryName(_ name: String) throws -> String", POINTER)
        self.assertIn("BotMemoryDocument.isAllowedName(name)", POINTER)
        # Both calls that carry a name go through it.
        self.assertEqual(POINTER.count("try Self.memoryName(name)"), 2)


class ASaveIsOneRenameAndKeepsItsMode(unittest.TestCase):
    def test_the_write_is_a_temp_file_beside_the_target_then_a_rename(self) -> None:
        body = block(BOT_DOCS, "fn write_atomic(path: &FsPath, text: &str)")
        self.assertIn("symlink", body, "a link named MEMORY.md must not be written through")
        self.assertLess(body.index("std::fs::write(&tmp"), body.index("std::fs::rename(&tmp, path)"),
                        "the rename must publish a file that was written whole")
        # The temp file is beside the target — a rename across filesystems is a copy, and a copy is
        # the partial write this is here to prevent.
        self.assertIn("parent.join(", body)
        self.assertNotIn("std::env::temp_dir()", body)

    def test_the_original_mode_is_read_before_the_rename_and_not_assumed(self) -> None:
        body = block(BOT_DOCS, "fn write_atomic(path: &FsPath, text: &str)")
        self.assertIn("mode_of(&meta)", body, "the file's own mode is not read")
        self.assertLess(body.index("mode_of(&meta)"), body.index("std::fs::rename(&tmp, path)"),
                        "the mode must be set on the temp file before it is published")
        self.assertIn("unwrap_or(0o600)", body, "a new memory document must still be owner-only")
        self.assertIn("set_mode(&tmp, mode)", body)

    def test_nothing_is_ever_written_in_place(self) -> None:
        body = block(BOT_DOCS, "fn write_atomic(path: &FsPath, text: &str)")
        for token in ("std::fs::write(path", "std::fs::write(&path", "OpenOptions", "File::create",
                       "set_len("):
            self.assertNotIn(token, body, f"a document could be truncated in place: {token!r}")
        self.assertIn("std::fs::write(&tmp", body)

    def test_a_failed_write_removes_its_temp_file(self) -> None:
        body = block(BOT_DOCS, "fn write_atomic(path: &FsPath, text: &str)")
        self.assertEqual(body.count("std::fs::remove_file(&tmp)"), 2,
                         "each failure after the temp file exists must clean it up")

    def test_every_memory_write_goes_through_the_one_writer(self) -> None:
        # One definition and one call: a second write path is a second set of rules.
        self.assertEqual(BOT_DOCS_SHIPPED.count("write_atomic("), 2)
        self.assertIn("write_atomic(&document_path(&dir, &name), &body.text)?",
                      route_body("pub async fn memory_put("))

    def test_the_rust_tests_prove_the_atomic_path(self) -> None:
        # The property, asserted over a real file: the inode moved (a rename), the mode survived even
        # though it is not the default, and no temp file was left beside the document.
        self.assertIn("fn a_save_replaces_the_file_by_rename_and_keeps_its_mode", BOT_DOCS_RAW)
        self.assertIn(".ino()", BOT_DOCS_RAW)
        self.assertIn("0o640", BOT_DOCS_RAW, "a non-default mode, so preserving it proves something")
        self.assertIn("left behind", BOT_DOCS_RAW)
        self.assertIn("fn a_write_that_cannot_be_published_leaves_the_previous_document_whole",
                      BOT_DOCS_RAW)


class TheSizeCapIsEnforcedOnBothEnds(unittest.TestCase):
    def test_the_host_cap_is_256_kib_and_a_413_with_a_sentence(self) -> None:
        self.assertIn("pub const MAX_DOCUMENT_BYTES: usize = 256 * 1024", BOT_DOCS_RAW)
        body = route_body("pub async fn memory_put(")
        self.assertIn("body.text.len() > MAX_DOCUMENT_BYTES", body)
        self.assertIn("PAYLOAD_TOO_LARGE", body)
        self.assertIn("larger than {MAX_DOCUMENT_BYTES} bytes", body)
        # The cap is checked before the budget and before the write.
        self.assertLess(body.index("MAX_DOCUMENT_BYTES"), body.index("let used = counted("))
        self.assertLess(body.index("MAX_DOCUMENT_BYTES"), body.index("write_atomic("))

    def test_the_framework_ceiling_sits_above_the_handlers_so_a_413_carries_its_sentence(self) -> None:
        self.assertIn("DefaultBodyLimit::max(bot_docs::MAX_DOCUMENT_BYTES * 4)", MAIN_RS)

    def test_the_app_refuses_the_same_size_before_sending_it(self) -> None:
        self.assertIn("public static let maxBytes = 256 * 1024", MEMORY_KIT)
        self.assertIn("MemoryBudget.maxBytes", EDITOR)
        self.assertIn("public static func overBytesSentence(name: String, bytes: Int)", MEMORY_KIT)
        self.assertIn("MemoryBudget.overBytesSentence(", EDITOR)
        # …and the over-budget refusal is what disables the Save button.
        self.assertIn("isDisabled: isSaving || !isDirty || refusal != nil", EDITOR)


class TheBudgetIsTheRuntimesOwn(unittest.TestCase):
    def test_the_count_mirrors_the_memory_tool(self) -> None:
        self.assertIn(f'const ENTRY_DELIMITER: &str = "{DELIMITER}"', BOT_DOCS_RAW,
                      "the delimiter must be the runtime's, or the count is a different count")
        counted = block(BOT_DOCS, "fn counted(text: &str)")
        self.assertIn("split(ENTRY_DELIMITER)", counted)
        self.assertIn(".map(str::trim)", counted)
        self.assertIn(".chars()", counted,
                      "characters, not bytes: the runtime counts a Python str")
        # The app's copy of the arithmetic, so the number on screen is the number the host enforces.
        swift = block(MEMORY_KIT, "public static func counted(_ text: String) -> Int")
        self.assertIn("components(separatedBy: entryDelimiter)", swift)
        self.assertIn("trimmingCharacters(in: .whitespacesAndNewlines)", swift)
        self.assertIn(r'public static let entryDelimiter = "\n§\n"', MEMORY_KIT)

    def test_the_limit_comes_from_the_bots_own_config(self) -> None:
        limit = block(BOT_DOCS, "fn limit_for(dir: &FsPath, target: &str)")
        self.assertIn('config.yaml', limit)
        self.assertIn('"memory_char_limit"', limit)
        self.assertIn('"user_char_limit"', limit)
        self.assertIn("DEFAULT_MEMORY_LIMIT", limit)
        self.assertIn("DEFAULT_USER_LIMIT", limit)
        # The runtime's own fallbacks (`agent/agent_init.py`).
        self.assertIn("const DEFAULT_MEMORY_LIMIT: u64 = 2200", BOT_DOCS_RAW)
        self.assertIn("const DEFAULT_USER_LIMIT: u64 = 1375", BOT_DOCS_RAW)

    def test_it_is_checked_before_the_write_and_says_which_limit_and_by_how_much(self) -> None:
        body = route_body("pub async fn memory_put(")
        self.assertLess(body.index("let used = counted(&body.text)"),
                        body.index("write_atomic("),
                        "the budget must be checked before the file is touched")
        self.assertIn("if used > limit", body)
        self.assertIn("let over = used - limit", body)
        self.assertIn("CONFLICT", body)
        # The sentence names the file, the budget and the overage, and points at the setting.
        self.assertIn('"{name} would hold {used} characters of a {limit}-character budget', body)
        self.assertIn("{over} over", body)
        self.assertIn("memory.memory_char_limit", body)
        self.assertIn("memory.user_char_limit", body)

    def test_nothing_is_silently_truncated(self) -> None:
        body = route_body("pub async fn memory_put(")
        for token in ("truncate", "[..", "chars().take(", "take("):
            self.assertNotIn(token, body, f"a save could be silently cut short: {token!r}")
        # The whole text is what is written — the request's own field, unmodified.
        self.assertIn("write_atomic(&document_path(&dir, &name), &body.text)?", body)

    def test_the_pane_shows_the_budget_and_refuses_rather_than_cutting(self) -> None:
        # "4,210 / 6,100 characters", in the pane and in the editor.
        self.assertIn(r'"\(used) / \(budget) characters"', MEMORY_KIT)
        self.assertIn("document.budgetText", PANE)
        self.assertIn(r'"\(used.formatted()) / \(limit.formatted()) characters"', EDITOR)
        self.assertIn("public static func overBudgetSentence(name: String, used: Int, limit: Int)",
                      MEMORY_KIT)
        self.assertIn(r'"\(name) would hold \(used) characters of a \(limit)-character budget',
                      MEMORY_KIT)
        # A refused save is a sentence beside the button, not a truncation behind it.
        self.assertIn("private var refusal: String?", EDITOR)
        self.assertIn("if budgetKnown, used > limit {", EDITOR)
        self.assertIn("Text(refusal)", EDITOR)


class ThePaneExistsOnBothShellsAndSavesOnce(unittest.TestCase):
    def test_the_pane_and_its_editor_are_shared_by_both_shells(self) -> None:
        # One file each in the shared design system, so the Mac and the phone cannot drift apart the
        # way the two bot-settings copies once did.
        self.assertTrue((UI / "BotMemorySheet.swift").is_file())
        self.assertTrue((UI / "BotMemoryEditor.swift").is_file())
        self.assertIn("public struct BotMemorySheet: View", PANE)
        self.assertIn("struct BotMemoryEditor: View", EDITOR)
        self.assertIn("#if os(iOS)", EDITOR, "the editor carries both shells' chrome")

    def test_the_mac_reaches_it_from_bot_settings(self) -> None:
        self.assertIn('HermeyButton("Memory…"', MAC_SETTINGS)
        self.assertIn("BotMemorySheet(botName: bot.displayName", MAC_SETTINGS)
        self.assertIn("BotMemoryAccess(", MAC_SETTINGS)
        for call in ("model.memory(for: bot.id)",
                     "model.memoryDocument(named: name, for: bot.id)",
                     "model.saveMemoryDocument(text, named: name, for: bot.id)"):
            self.assertIn(call, MAC_SETTINGS, f"the Mac does not wire {call}")

    def test_the_phone_reaches_it_from_bot_settings(self) -> None:
        self.assertIn('Label("Memory", systemImage: "brain")', PHONE_SETTINGS)
        self.assertIn("BotMemorySheet(botName: bot.displayName, access: memory)", PHONE_SETTINGS)
        self.assertIn("var memory: BotMemoryAccess? = nil", PHONE_SETTINGS,
                      "the editor row must be optional: a client that cannot write must not offer it")
        # The shared door is where the list's and the conversation's settings both land.
        self.assertIn("memory: BotMemoryAccess(", PHONE_DOOR)
        self.assertIn("model.saveMemoryDocument(text, named: name, for: bot.id)", PHONE_DOOR)
        # …and the conversation's own drawer opens the same editable pane, not a stale read-only one.
        self.assertIn("BotMemoryAccess(", PHONE_CHAT)

    def test_opening_a_document_reads_it_fresh(self) -> None:
        # The list was drawn before the editor opened; the agent may have written since.
        self.assertIn("read: access.read", PANE)
        self.assertIn("try await read(current.name)", EDITOR)
        # …and the list is re-read after a save, so the row's count is the file's.
        self.assertIn("await reload()", PANE)

    def test_a_save_confirms_once_and_says_what_it_means(self) -> None:
        self.assertIn('.alert("Save \\(current.name)?", isPresented: $confirming)', EDITOR)
        self.assertIn("on its next turn", EDITOR,
                      "the confirmation must say when the bot reads the file")
        self.assertIn("This replaces the whole file on the host.", EDITOR)
        # One confirmation, and the write is reachable only from it: the footer's Save asks; the
        # alert's Save writes. A footer that wrote would be a save with no sentence in front of it.
        self.assertEqual(EDITOR.count("confirming = true"), 1, "more than one door into the save")
        alert = block(EDITOR, '.alert("Save \\(current.name)?", isPresented: $confirming)')
        self.assertIn("await write()", alert, "the confirmed button is not the one that writes")
        footer = block(EDITOR, "private var footer: some View")
        self.assertIn("confirming = true", footer)
        self.assertNotIn("write()", footer, "the footer saves without asking")
        self.assertIn("await save(current.name, text)", EDITOR)

    def test_the_warning_about_visibility_is_a_line_in_both_places(self) -> None:
        line = "secrets do not belong in it"
        self.assertIn(line, PANE)
        self.assertIn(line, EDITOR)
        self.assertIn(r"visible to \(botName) on every turn", PANE)

    def test_a_bot_with_no_file_yet_opens_empty_and_is_created_on_first_save(self) -> None:
        # The host reads a missing file as an empty document, not an error…
        body = block(BOT_DOCS, "fn document_value(dir: &FsPath, name: &str, target: &str, label: &str)")
        self.assertIn("Err(_) => shape(\"\", false, None)", body)
        self.assertIn("fn a_bot_with_no_file_yet_reads_empty_and_is_created_on_first_save", BOT_DOCS_RAW)
        # …and the pane says so, rather than drawing a fault.
        self.assertIn("No file yet — opened empty; the first save creates it.", PANE)

    def test_the_editor_is_plain_text_and_shows_the_line_count(self) -> None:
        self.assertIn("TextEditor(text: $text)", EDITOR)
        self.assertIn("TypeScale.mono(", EDITOR, "a memory is a text file, so it is drawn in one pitch")
        self.assertIn(".textSelection(.enabled)", EDITOR)
        self.assertIn("private var lineCount: Int { text.components(separatedBy: \"\\n\").count }", EDITOR)
        self.assertIn(r'"\(lineCount) line\(lineCount == 1 ? "" : "s")"', EDITOR)
        # Revert puts the file's text back without a request.
        self.assertIn('HermeyButton("Revert"', EDITOR)
        self.assertIn("text = loaded?.text ?? document.text", EDITOR)


class NoRequestCarriesAPathAndNothingIsLogged(unittest.TestCase):
    def test_the_write_body_is_exactly_the_text(self) -> None:
        # The request a save sends: one field. Not a path, not a file name, not a directory — the
        # document is chosen by the allow-listed segment in the URL, and nothing else.
        save = block(POINTER, "public func saveMemoryDocument(")
        bodies = re.findall(r"body: \[([^\]]*)\]", save)
        self.assertEqual(len(bodies), 1, "a save must be one request with one body")
        keys = set(re.findall(r'"([a-z_]+)"\s*:', bodies[0]))
        self.assertEqual(keys, {"text"}, f"the save body carries {sorted(keys)}")

    def test_the_hosts_write_shape_is_one_field_too(self) -> None:
        put = block(BOT_DOCS, "struct MemoryPut")
        members = re.findall(r"^\s{4}pub (\w+):", put, flags=re.M)
        self.assertEqual(members, ["text"], f"MemoryPut grew a member: {members}")

    def test_the_url_is_built_from_the_profile_and_the_allow_listed_name(self) -> None:
        save = block(POINTER, "public func saveMemoryDocument(")
        self.assertIn("try Self.pathComponent(profile)", save)
        self.assertIn("try Self.memoryName(name)", save)
        self.assertIn('bridgePUT("v1/bots/\\(bot)/memory/\\(document)"', save)
        read = block(POINTER, "public func memoryDocument(")
        self.assertIn('bridgeGET("v1/bots/\\(bot)/memory/\\(document)"', read)

    def test_neither_side_logs_a_document(self) -> None:
        for name, source in (("bot_docs.rs", BOT_DOCS_SHIPPED),
                             ("BotMemoryEditor.swift", EDITOR),
                             ("BotMemorySheet.swift", PANE)):
            for logger in ("println!", "eprintln!", "dbg!", "log::", "tracing::", "print("):
                self.assertNotIn(logger, source, f"{name} logs: {logger!r}")

    def test_no_refusal_quotes_the_text_it_refused(self) -> None:
        body = route_body("pub async fn memory_put(")
        # The count and the limits may be quoted; the document's own text may not.
        self.assertNotIn("{text}", body)
        self.assertNotIn("body.text}", body)
        # The only places the text is used are the count and the write.
        self.assertEqual(body.count("body.text"), 4,
                         "the request's text goes to two length checks, to `counted`, and to the write — "
                         "and nowhere else")

    def test_a_refusal_is_a_sentence_both_shells_show_unchanged(self) -> None:
        self.assertIn("public enum MemoryFailure", MEMORY_KIT)
        self.assertIn("public static func sentence(_ error: Error) -> String", MEMORY_KIT)
        self.assertIn("nothing was changed", MEMORY_KIT)
        # Both panes use it rather than inventing their own words.
        self.assertIn("MemoryFailure.sentence(error)", PANE)
        self.assertIn("MemoryFailure.sentence(error)", EDITOR)


class TheWrongFileIsNeverReachable(unittest.TestCase):
    def test_the_profile_is_a_plain_directory_name(self) -> None:
        profile = block(BOT_DOCS, "fn profile_dir(st: &AppState, profile: &str)")
        self.assertIn("c.is_ascii_alphanumeric() || c == '-' || c == '_'", profile)
        self.assertIn("profile.len() <= 64", profile)
        self.assertIn("UNPROCESSABLE_ENTITY", profile)

    def test_the_traversal_attempts_the_rust_tests_make_are_in_the_suite(self) -> None:
        # Named in the Rust test that refuses them, so a reader can see what was tried.
        for attempt in ('"..%2FMEMORY.md"', '"../MEMORY.md"', '"MEMORY.md/../USER.md"',
                        '"../../MEMORY.md"'):
            self.assertIn(attempt, BOT_DOCS_RAW, f"the traversal case {attempt} is not tested")
        self.assertIn("assert_eq!(fail.0, StatusCode::UNPROCESSABLE_ENTITY", BOT_DOCS_RAW)
        self.assertIn("why.contains(\"MEMORY.md\") && why.contains(\"USER.md\")", BOT_DOCS_RAW)

    def test_a_symlink_cannot_hand_over_or_receive_a_file(self) -> None:
        self.assertIn("fn a_symlinked_document_is_refused_rather_than_followed", BOT_DOCS_RAW)
        self.assertIn('"refusing to write through a symlink"', BOT_DOCS_RAW)
        self.assertIn("is_symlink", BOT_DOCS_SHIPPED)

    def test_a_write_never_creates_the_bot_it_cannot_find(self) -> None:
        body = route_body("pub async fn memory_put(")
        self.assertIn("if !dir.is_dir()", body)
        self.assertIn('"no such bot"', body)
        self.assertLess(body.index("if !dir.is_dir()"), body.index("write_atomic("))
        self.assertIn("fn an_unknown_bot_is_a_404_on_a_write_and_never_creates_one", BOT_DOCS_RAW)


if __name__ == "__main__":
    unittest.main()

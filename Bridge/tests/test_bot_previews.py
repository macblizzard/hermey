"""The bot-list preview must describe the conversation the app actually opens.

A bot does work in sessions the chat never shows: cron runs, CLI turns, subagents. When the preview
looked at "the profile's most recently active session" as well as the stored pointer, a bot's row
advertised a message from one of those, the row lit an unread mark, and opening the bot showed a
transcript whose last line was hours older. The mark was then wrong forever, because the window it
compares against never moves.

These tests use a real (tiny) `state.db` rather than mocks: the bug was an SQL choice, and only SQL
can prove it is gone.
"""
import sqlite3
from pathlib import Path

from hermes_bridge.bot_previews import _last_message

SCHEMA = """
CREATE TABLE sessions (id TEXT PRIMARY KEY, started_at REAL NOT NULL, last_activity_at REAL);
CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT,
    timestamp REAL
);
"""


def _db(tmp_path: Path, sessions: list[tuple[str, float]]) -> Path:
    path = tmp_path / "state.db"
    conn = sqlite3.connect(path)
    conn.executescript(SCHEMA)
    for sid, activity in sessions:
        conn.execute("INSERT INTO sessions (id, started_at, last_activity_at) VALUES (?, ?, ?)",
                     (sid, activity, activity))
    conn.commit()
    conn.close()
    return path


def _say(path: Path, session: str, role: str, text: str, at: float) -> None:
    conn = sqlite3.connect(path)
    conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, ?, ?, ?)",
                 (session, role, text, at))
    conn.commit()
    conn.close()


def test_activity_in_another_session_does_not_become_the_preview(tmp_path):
    """The cron case: the chat's last line is 06:34, a cron run wrote at 09:23."""
    path = _db(tmp_path, [("chat", 1_000.0), ("cron-run", 9_000.0)])
    _say(path, "chat", "assistant", "Brief received here in this chat", 1_000.0)
    _say(path, "cron-run", "assistant", "Root cause found: WinRM job objects", 9_000.0)

    preview = _last_message(path, "chat")

    assert preview is not None
    assert preview["text"].startswith("Brief received")
    assert preview["at"] == 1_000.0


def test_a_bot_without_a_pointer_still_gets_its_newest_line(tmp_path):
    """An absent pointer is not an empty row: the list still has something to show."""
    path = _db(tmp_path, [("only", 5_000.0)])
    _say(path, "only", "user", "hello", 5_000.0)

    preview = _last_message(path, None)

    assert preview is not None and preview["text"] == "hello"


def test_a_stale_pointer_falls_back_instead_of_going_blank(tmp_path):
    """The pointer can outlive its session (a reset conversation); that must not erase the line."""
    path = _db(tmp_path, [("fresh", 7_000.0)])
    _say(path, "fresh", "assistant", "after the reset", 7_000.0)

    preview = _last_message(path, "forgotten-session")

    assert preview is not None and preview["text"] == "after the reset"


def test_markup_is_stripped_and_only_the_first_line_survives(tmp_path):
    path = _db(tmp_path, [("chat", 1.0)])
    _say(path, "chat", "assistant", "**Root cause** found\n\nsecond paragraph", 1.0)

    preview = _last_message(path, "chat")

    assert preview is not None and preview["text"] == "Root cause found"

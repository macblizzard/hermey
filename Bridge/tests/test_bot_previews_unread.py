"""The unread count must describe the same conversation the row describes.

The counter is the one number on this screen a user can check by hand: they open the bot and count
what is waiting. So the rules are strict — the bot's own turns only, after the device's mark, in the
session the app actually opens.
"""
import sqlite3
from pathlib import Path

from hermes_bridge.bot_previews import _conversation, _unread_count

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


def _say(path: Path, session: str, role: str, text: str | None, at: float) -> None:
    conn = sqlite3.connect(path)
    conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, ?, ?, ?)",
                 (session, role, text, at))
    conn.commit()
    conn.close()


def test_counts_only_the_bots_turns_after_the_mark(tmp_path):
    path = _db(tmp_path, [("chat", 5_000.0)])
    _say(path, "chat", "assistant", "older reply", 1_000.0)
    _say(path, "chat", "assistant", "first new reply", 4_000.0)
    _say(path, "chat", "user", "me answering", 4_100.0)
    _say(path, "chat", "assistant", "second new reply", 4_500.0)

    payload, session = _conversation(path, "chat")

    assert session == "chat"
    assert _unread_count(path, session, 2_000.0) == 2, "two bot turns after the mark, not the user's"
    assert _unread_count(path, session, 4_200.0) == 1
    assert _unread_count(path, session, 9_000.0) == 0


def test_a_mark_of_zero_or_missing_session_counts_nothing(tmp_path):
    path = _db(tmp_path, [("chat", 5_000.0)])
    _say(path, "chat", "assistant", "reply", 4_000.0)

    assert _unread_count(path, "chat", 0) == 0
    assert _unread_count(path, None, 1.0) == 0


def test_a_busier_sibling_session_is_not_counted(tmp_path):
    """A cron run wrote ten turns while the chat sat still: the row must not claim ten unread."""
    path = _db(tmp_path, [("chat", 1_000.0), ("cron-run", 9_000.0)])
    _say(path, "chat", "assistant", "chat reply", 1_000.0)
    for i in range(10):
        _say(path, "cron-run", "assistant", f"cron line {i}", 9_000.0 + i)

    payload, session = _conversation(path, "chat")

    assert session == "chat"
    assert _unread_count(path, session, 500.0) == 1


def test_empty_and_blank_messages_are_not_counted(tmp_path):
    path = _db(tmp_path, [("chat", 5_000.0)])
    _say(path, "chat", "assistant", "   ", 4_000.0)
    _say(path, "chat", "assistant", None, 4_100.0)
    _say(path, "chat", "assistant", "real reply", 4_200.0)

    assert _unread_count(path, "chat", 3_000.0) == 1

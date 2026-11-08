from __future__ import annotations

import pytest

from hermes_bridge.proxy import _RelayError, split_frames


def test_a_message_without_newline_is_one_frame():
    """The gateway's WS transport sends JSON with no trailing newline."""
    assert split_frames(b'{"a":1}', 1024) == [b'{"a":1}']


def test_newline_batches_are_split():
    assert split_frames(b'{"a":1}\n{"b":2}\n', 1024) == [b'{"a":1}', b'{"b":2}']


def test_trailing_newline_does_not_create_an_empty_frame():
    assert split_frames(b'{"a":1}\n', 1024) == [b'{"a":1}']
    assert split_frames(b'{"a":1}\r\n\r\n{"b":2}\n', 1024) == [b'{"a":1}', b'{"b":2}']


def test_rejects_a_frame_over_the_cap():
    with pytest.raises(_RelayError) as excinfo:
        split_frames(b"x" * 1025, 1024)
    assert excinfo.value.code == 1009


def test_a_frame_exactly_at_the_cap_is_allowed():
    frames = split_frames(b"x" * 1024, 1024)
    assert len(frames) == 1
    assert len(frames[0]) == 1024


def test_one_oversized_frame_inside_a_batch_is_rejected():
    with pytest.raises(_RelayError):
        split_frames(b'{"ok":1}\n' + b"x" * 1025 + b"\n", 1024)


def test_empty_message_yields_nothing():
    assert split_frames(b"", 1024) == []
    assert split_frames(b"\n\n", 1024) == []

"""The bot's workspace, over HTTP: the list, the bytes, and the ways in that must not work.

The interesting half of this file is the security half. A workspace is a directory the *agent* can
write to, so anything it can create — a `..` name, a symlink, a file big enough to exhaust a phone —
has to be treated as hostile input rather than as our own data.
"""
from __future__ import annotations

import os
from pathlib import Path

import httpx
import pytest


@pytest.fixture()
def workspace_home(tmp_path, monkeypatch):
    home = tmp_path / "hermes-home"
    profile = home / "profiles" / "cody"
    (profile / "workspace" / "reports").mkdir(parents=True)
    (profile / "attachments").mkdir(parents=True)
    (profile / "workspace" / "reports" / "q3.md").write_text("# Q3\n\nNumbers.\n", encoding="utf-8")
    (profile / "workspace" / "plan.txt").write_text("one two three\n", encoding="utf-8")
    (profile / "attachments" / "20261103_brief.pdf").write_bytes(b"%PDF-1.4 fake")
    monkeypatch.setenv("HERMES_HOME", str(home))
    return profile


def _get(bridge, path, headers=None):
    """A bridge ticket is single use, so every request pairs first."""
    ticket = bridge.pair()["ticket"]
    return httpx.get(f"{bridge.base_url}{path}",
                     headers={"Authorization": f"Bearer {ticket}", **(headers or {})}, timeout=10)


def test_it_lists_what_the_bot_wrote_and_what_the_user_sent(bridge, workspace_home):
    response = _get(bridge, "/v1/workspace/cody")
    assert response.status_code == 200, response.text
    payload = response.json()
    names = {entry["path"] for entry in payload["files"]}
    assert "reports/q3.md" in names, "a nested document is still a document"
    assert "plan.txt" in names
    assert "20261103_brief.pdf" in names, "uploads and output belong in one list"

    q3 = next(entry for entry in payload["files"] if entry["path"] == "reports/q3.md")
    assert q3["kind"] == "md"
    assert q3["previewable"] is True
    assert q3["source"] == "workspace"
    assert q3["size"] == len("# Q3\n\nNumbers.\n")
    assert q3["modified"].endswith("+00:00")


def test_a_missing_workspace_is_an_empty_list_not_an_error(bridge, workspace_home):
    (workspace_home / "workspace").rename(workspace_home / "workspace-gone")
    response = _get(bridge, "/v1/workspace/cody")
    assert response.status_code == 200
    sources = {entry["source"] for entry in response.json()["files"]}
    assert "workspace" not in sources, "no directory is an empty folder, not a 500"
    assert "attachments" in sources, "and it must not take the uploads down with it"


def test_the_bytes_come_back_with_a_type_a_viewer_can_use(bridge, workspace_home):
    response = _get(bridge, "/v1/workspace/cody/file?path=reports/q3.md")
    assert response.status_code == 200
    assert response.text == "# Q3\n\nNumbers.\n"
    assert "text/markdown" in response.headers["content-type"]
    assert response.headers["accept-ranges"] == "bytes"

    pdf = _get(bridge, "/v1/workspace/cody/file?path=20261103_brief.pdf")
    assert pdf.status_code == 200
    assert pdf.headers["content-type"] == "application/pdf"


def test_a_range_answers_206_so_a_pdf_can_page(bridge, workspace_home):
    response = _get(bridge, "/v1/workspace/cody/file?path=plan.txt", {"Range": "bytes=4-6"})
    assert response.status_code == 206
    assert response.text == "two"
    assert response.headers["content-range"] == "bytes 4-6/14"


@pytest.mark.parametrize("hostile", [
    "../../../etc/passwd",
    "/etc/passwd",
    "reports/../../../etc/passwd",
])
def test_traversal_never_resolves(bridge, workspace_home, hostile):
    response = _get(bridge, f"/v1/workspace/cody/file?path={hostile}")
    assert response.status_code in (400, 404)
    assert b"root:" not in response.content


def test_a_symlink_is_refused_rather_than_followed(bridge, workspace_home, tmp_path):
    secret = tmp_path / "secret.txt"
    secret.write_text("not yours", encoding="utf-8")
    os.symlink(secret, workspace_home / "workspace" / "innocent.md")

    listing = _get(bridge, "/v1/workspace/cody").json()
    assert "innocent.md" not in {entry["path"] for entry in listing["files"]}, "a link is not a document"

    response = _get(bridge, "/v1/workspace/cody/file?path=innocent.md")
    assert response.status_code in (400, 404)
    assert b"not yours" not in response.content


def test_a_dotfile_stays_hidden(bridge, workspace_home):
    (workspace_home / "workspace" / ".env").write_text("TOKEN=secret", encoding="utf-8")
    listing = _get(bridge, "/v1/workspace/cody").json()
    assert ".env" not in {entry["path"] for entry in listing["files"]}


def test_it_needs_a_paired_device(bridge, workspace_home):
    response = httpx.get(f"{bridge.base_url}/v1/workspace/cody", timeout=10)
    assert response.status_code in (401, 403)

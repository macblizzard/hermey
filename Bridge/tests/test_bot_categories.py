"""Bot categories over HTTP: one file on the host, two devices agreeing about it.

The rules worth pinning are the ones a user would notice being broken:

* a category is a name, and two categories cannot share one;
* deleting a category moves its bots to Uncategorized — it never deletes a bot;
* an assignment survives a second read (the file is the truth, not a device's memory);
* the routes need a device ticket, like every other bot route.
"""

from __future__ import annotations

import httpx
import pytest


def _request(bridge, method: str, path: str, body=None):
    """A bridge ticket is single use, so every request pairs first."""
    ticket = bridge.pair()["ticket"]
    return httpx.request(method, f"{bridge.base_url}{path}", json=body,
                         headers={"Authorization": f"Bearer {ticket}"}, timeout=10)


def _create(bridge, name: str):
    return _request(bridge, "POST", "/v1/bot-categories", {"name": name})


class TestCategoriesAreAName:
    def test_a_new_host_has_none(self, bridge) -> None:
        response = _request(bridge, "GET", "/v1/bot-categories")
        assert response.status_code == 200, response.text
        assert response.json() == {"categories": [], "assignments": {}}

    def test_creating_returns_the_whole_document(self, bridge) -> None:
        response = _create(bridge, "Work")
        assert response.status_code == 200, response.text
        payload = response.json()
        assert payload["category"]["name"] == "Work"
        assert payload["category"]["id"]
        assert payload["categories"][0]["id"] == payload["category"]["id"]

    def test_whitespace_is_normalised_and_empty_is_refused(self, bridge) -> None:
        assert _create(bridge, "  Home   lab ").json()["category"]["name"] == "Home lab"
        assert _request(bridge, "POST", "/v1/bot-categories", {"name": "   "}).status_code == 422

    def test_two_categories_cannot_share_a_name(self, bridge) -> None:
        _create(bridge, "Work")
        again = _create(bridge, "work")
        assert again.status_code == 409, again.text

    def test_a_long_name_is_refused(self, bridge) -> None:
        assert _create(bridge, "x" * 41).status_code == 422

    def test_renaming_and_the_clash_it_can_cause(self, bridge) -> None:
        first = _create(bridge, "Work").json()["category"]["id"]
        second = _create(bridge, "Home").json()["category"]["id"]

        renamed = _request(bridge, "PATCH", f"/v1/bot-categories/{first}", {"name": "Office"})
        assert renamed.status_code == 200, renamed.text
        names = {c["id"]: c["name"] for c in renamed.json()["categories"]}
        assert names[first] == "Office"

        clash = _request(bridge, "PATCH", f"/v1/bot-categories/{first}", {"name": "Home"})
        assert clash.status_code == 409, clash.text
        assert second  # the other category is untouched by the refusal


class TestAssignments:
    def test_a_bot_can_be_sorted_and_unsorted(self, bridge) -> None:
        category = _create(bridge, "Work").json()["category"]["id"]

        sorted_ = _request(bridge, "PUT", "/v1/bots/cody/category", {"category_id": category})
        assert sorted_.status_code == 200, sorted_.text
        assert sorted_.json()["assignments"] == {"cody": category}

        cleared = _request(bridge, "PUT", "/v1/bots/cody/category", {"category_id": None})
        assert cleared.json()["assignments"] == {}

    def test_the_assignment_is_read_back_from_the_host(self, bridge) -> None:
        category = _create(bridge, "Work").json()["category"]["id"]
        _request(bridge, "PUT", "/v1/bots/aria/category", {"category_id": category})

        re_read = _request(bridge, "GET", "/v1/bot-categories").json()
        assert re_read["assignments"] == {"aria": category}

    def test_an_unknown_category_is_refused(self, bridge) -> None:
        response = _request(bridge, "PUT", "/v1/bots/cody/category", {"category_id": "nope"})
        assert response.status_code == 404, response.text

    def test_a_profile_name_that_is_a_path_is_refused(self, bridge) -> None:
        category = _create(bridge, "Work").json()["category"]["id"]
        response = _request(bridge, "PUT", "/v1/bots/..%2Fetc/category", {"category_id": category})
        assert response.status_code in (404, 422), response.text


class TestDeletingACategoryNeverDeletesABot:
    def test_its_bots_fall_to_uncategorized(self, bridge) -> None:
        category = _create(bridge, "Work").json()["category"]["id"]
        _request(bridge, "PUT", "/v1/bots/cody/category", {"category_id": category})
        other = _create(bridge, "Home").json()["category"]["id"]
        _request(bridge, "PUT", "/v1/bots/aria/category", {"category_id": other})

        deleted = _request(bridge, "DELETE", f"/v1/bot-categories/{category}")
        assert deleted.status_code == 200, deleted.text
        payload = deleted.json()
        assert [c["id"] for c in payload["categories"]] == [other]
        # Uncategorized is the absence of an assignment — the app draws it, the host does not
        # invent a row for it.
        assert payload["assignments"] == {"aria": other}

    def test_deleting_an_unknown_category_is_a_404(self, bridge) -> None:
        assert _request(bridge, "DELETE", "/v1/bot-categories/nope").status_code == 404


class TestTheRoutesNeedADevice:
    @pytest.mark.parametrize("method,path,body", [
        ("GET", "/v1/bot-categories", None),
        ("POST", "/v1/bot-categories", {"name": "Work"}),
        ("PUT", "/v1/bots/cody/category", {"category_id": None}),
        ("DELETE", "/v1/bot-categories/abc", None),
    ])
    def test_without_a_ticket(self, bridge, method, path, body) -> None:
        response = httpx.request(method, f"{bridge.base_url}{path}", json=body, timeout=10)
        assert response.status_code in (401, 403), response.text

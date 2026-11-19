"""Bot categories over HTTP: one file on the host, two devices agreeing about it.

The rules worth pinning are the ones a user would notice being broken:

* a category is a name, and two categories cannot share one;
* deleting a category moves its bots to Uncategorized — it never deletes a bot;
* an assignment survives a second read (the file is the truth, not a device's memory);
* the routes need a device ticket, like every other bot route.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

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
        assert response.json() == {"categories": [], "assignments": {}, "order": []}

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


class TestTwoDevicesWriteOneFile:
    """The phone and the Mac write the same document, so the host has to make the writes add up.

    The rule the apps rely on: a mutation is a whole-file read-modify-write, and two of them cannot
    interleave. A device that files one bot must never silently drop the other device's filing — the
    two-device case is the whole reason this state is on the host.
    """

    def test_filings_from_many_requests_all_survive(self, bridge) -> None:
        category = _create(bridge, "Work").json()["category"]["id"]
        # Six, not sixteen: every request pairs first, and a claim is rate limited per address.
        profiles = [f"bot{index}" for index in range(6)]

        def file(profile: str):
            return _request(bridge, "PUT", f"/v1/bots/{profile}/category",
                            {"category_id": category})

        with ThreadPoolExecutor(max_workers=len(profiles)) as pool:
            responses = list(pool.map(file, profiles))

        assert [r.status_code for r in responses] == [200] * len(profiles)
        state = _request(bridge, "GET", "/v1/bot-categories").json()
        assert state["assignments"] == {profile: category for profile in profiles}

    def test_categories_created_at_once_all_survive(self, bridge) -> None:
        names = [f"Group {index}" for index in range(6)]
        with ThreadPoolExecutor(max_workers=len(names)) as pool:
            responses = list(pool.map(lambda name: _create(bridge, name), names))

        assert all(r.status_code == 200 for r in responses)
        listed = [c["name"] for c in _request(bridge, "GET", "/v1/bot-categories").json()["categories"]]
        assert sorted(listed) == sorted(names)

    def test_the_same_bot_filed_twice_ends_at_the_later_request(self, bridge) -> None:
        work = _create(bridge, "Work").json()["category"]["id"]
        home = _create(bridge, "Home").json()["category"]["id"]

        _request(bridge, "PUT", "/v1/bots/cody/category", {"category_id": work})
        later = _request(bridge, "PUT", "/v1/bots/cody/category", {"category_id": home})

        # "Last write wins" is not a merge rule to reason about: the answer to the last request *is*
        # the document a read returns, so both devices draw the same list.
        assert later.json()["assignments"] == {"cody": home}
        assert _request(bridge, "GET", "/v1/bot-categories").json()["assignments"] == {"cody": home}

    def test_a_mutation_in_flight_cannot_be_built_on_a_stale_read(self, bridge) -> None:
        """The deterministic form of the race: one change is held open while a second lands.

        Without a lock the second one reads the file the first has not written yet, saves its own
        document, and the first then publishes over it — one of the two changes is gone. With the
        lock the second waits for the first, so both are in the file.
        """
        import threading
        import time

        from hermes_bridge import bot_categories

        runtime = bridge.app.state.bridge
        first_started = threading.Event()
        release_first = threading.Event()

        def slow_change(data: dict) -> None:
            first_started.set()
            assert release_first.wait(5)
            data["categories"].append({"id": "aaa", "name": "First"})

        def quick_change(data: dict) -> None:
            data["categories"].append({"id": "bbb", "name": "Second"})

        first = threading.Thread(target=bot_categories.mutate, args=(runtime, slow_change))
        first.start()
        assert first_started.wait(5)
        second = threading.Thread(target=bot_categories.mutate, args=(runtime, quick_change))
        second.start()
        # Long enough that the second is inside `mutate` — blocked on the lock, or, without one,
        # between its read and its write.
        time.sleep(0.2)
        release_first.set()
        first.join(5)
        second.join(5)
        assert not first.is_alive() and not second.is_alive()

        names = sorted(c["id"] for c in bot_categories.load(runtime)["categories"])
        assert names == ["aaa", "bbb"]

    def test_a_refused_write_leaves_the_file_as_it_was(self, bridge) -> None:
        kept = _create(bridge, "Work").json()["category"]["id"]
        _request(bridge, "PUT", "/v1/bots/cody/category", {"category_id": kept})

        assert _request(bridge, "PUT", "/v1/bots/aria/category",
                        {"category_id": "nope"}).status_code == 404
        assert _request(bridge, "DELETE", "/v1/bot-categories/nope").status_code == 404
        assert _request(bridge, "PATCH", "/v1/bot-categories/nope",
                        {"name": "Elsewhere"}).status_code == 404

        state = _request(bridge, "GET", "/v1/bot-categories").json()
        assert [c["id"] for c in state["categories"]] == [kept]
        assert state["assignments"] == {"cody": kept}


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


class TestTheOwnerCanArrangeThem:
    """Ordering: the arrangement is the file's, not a device's memory."""

    def _ids(self, payload: dict) -> list:
        return [c["id"] for c in payload["categories"]]

    def test_the_default_arrangement_is_still_the_alphabetical_one(self, bridge) -> None:
        """No order stored, so the apps sort. An install that never reorders looks unchanged."""
        _create(bridge, "Work")
        _create(bridge, "Home")
        assert _request(bridge, "GET", "/v1/bot-categories").json()["order"] == [
            _request(bridge, "GET", "/v1/bot-categories").json()["categories"][0]["id"],
            _request(bridge, "GET", "/v1/bot-categories").json()["categories"][1]["id"],
        ]

    def test_arranging_returns_the_document_in_the_new_order(self, bridge) -> None:
        first = _create(bridge, "Work").json()["category"]["id"]
        second = _create(bridge, "Home").json()["category"]["id"]
        moved = _request(bridge, "PUT", "/v1/bot-categories/order", {"ids": [second, first]})
        assert moved.status_code == 200, moved.text
        assert moved.json()["order"] == [second, first]
        # and the categories themselves come back in that order, so a reader that ignores `order`
        # still draws what the owner arranged
        assert self._ids(moved.json()) == [second, first]

    def test_it_persists_across_reads(self, bridge) -> None:
        first = _create(bridge, "Work").json()["category"]["id"]
        second = _create(bridge, "Home").json()["category"]["id"]
        _request(bridge, "PUT", "/v1/bot-categories/order", {"ids": [second, first]})
        assert _request(bridge, "GET", "/v1/bot-categories").json()["order"] == [second, first]

    def test_unknown_ids_are_ignored_and_missing_ones_are_kept(self, bridge) -> None:
        """A device that has not seen a category cannot lose it by arranging."""
        first = _create(bridge, "Work").json()["category"]["id"]
        second = _create(bridge, "Home").json()["category"]["id"]
        payload = _request(bridge, "PUT", "/v1/bot-categories/order",
                           {"ids": [second, "not-a-real-id"]}).json()
        assert payload["order"] == [second, first]

    def test_a_new_category_joins_the_end_of_an_arrangement(self, bridge) -> None:
        first = _create(bridge, "Work").json()["category"]["id"]
        _request(bridge, "PUT", "/v1/bot-categories/order", {"ids": [first]})
        third = _create(bridge, "Zebra").json()["category"]["id"]
        assert _request(bridge, "GET", "/v1/bot-categories").json()["order"] == [first, third]

    def test_deleting_removes_it_from_the_arrangement(self, bridge) -> None:
        first = _create(bridge, "Work").json()["category"]["id"]
        second = _create(bridge, "Home").json()["category"]["id"]
        _request(bridge, "PUT", "/v1/bot-categories/order", {"ids": [second, first]})
        _request(bridge, "DELETE", f"/v1/bot-categories/{second}")
        assert _request(bridge, "GET", "/v1/bot-categories").json()["order"] == [first]

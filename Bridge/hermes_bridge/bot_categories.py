"""Bot categories: the owner's grouping of the bots on this host.

A category is not a property of a bot's own files. It is the *owner's* opinion about a bot, and it
has to read the same from the phone and from the Mac — so it lives here, on the host, in one file
beside the bridge's own state. A per-device grouping would be two devices disagreeing about the
same list, which is a bug report the moment someone opens the other app.

The file is deliberately small and whole:

    {"version": 1,
     "categories": [{"id": "…", "name": "Work", "created_at": 1731600000.0}],
     "assignments": {"cody": "…"}}

Two rules make it safe to write from either device:

* **A category is deleted, a bot never is.** Deleting a category drops its assignments and the bots
  fall back to Uncategorized, which is what the app already draws for a bot with no assignment.
* **Last write wins, whole file.** The app sends one change at a time and reads the answer back;
  there is no merge to get wrong, and a half-written file cannot exist because the write goes to a
  temporary file that is then moved into place.

The client contract that goes with it (both apps follow it — see `AppModel`):

* a device reads the document **on connect and after every write**, and caches the last answer so a
  launch with no host still draws the groups; the cache is read-only, so two devices can never
  disagree about who owns a category;
* because every mutation is a read-modify-write *under this file's lock*, two devices sorting two
  different bots both keep their change. Only the same bot filed twice is a conflict, and there the
  later request wins — the answer it returns is the document both devices will show.

Routes (device ticket, like every other `/v1/bots/**` route):

    GET    /v1/bot-categories                 -> {categories, assignments}
    POST   /v1/bot-categories {name}          -> {category, categories, assignments}
    PATCH  /v1/bot-categories/{id} {name}     -> {categories, assignments}
    DELETE /v1/bot-categories/{id}            -> {categories, assignments}
    PUT    /v1/bots/{profile}/category {category_id|null} -> {profile, category_id, …}
"""

from __future__ import annotations

import json
import re
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

from .device_auth import require_device

#: A profile name is a directory name elsewhere, so it is checked with the same shape the CLI uses.
PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")

#: A name is a chip on a row, not a sentence. Forty characters is a long label already.
MAX_NAME = 40

#: Enough for a person's own taxonomy, few enough that the list stays a list.
MAX_CATEGORIES = 60

FILENAME = "bot-categories.json"


class CategoryWrite(BaseModel):
    name: str


class AssignmentWrite(BaseModel):
    category_id: Optional[str] = None


def state_file(runtime) -> Path:
    """The file this host keeps its categories in.

    Derived from the runtime's own database path rather than a module constant: a bridge running
    against a different database (a test, a second instance) must not write into the first one's
    directory.
    """
    return Path(runtime.config.db_path).parent / FILENAME


def _empty() -> dict:
    return {"version": 1, "categories": [], "assignments": {}}


def load(runtime) -> dict:
    path = state_file(runtime)
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return _empty()
    except OSError:
        return _empty()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        # A damaged file is not an empty one: keep a copy, so the loss is recoverable and visible.
        try:
            path.with_suffix(".json.damaged").write_text(raw, encoding="utf-8")
        except OSError:
            pass
        return _empty()
    if not isinstance(data, dict):
        return _empty()
    categories = data.get("categories")
    assignments = data.get("assignments")
    data["categories"] = categories if isinstance(categories, list) else []
    data["assignments"] = assignments if isinstance(assignments, dict) else {}
    return data


def save(runtime, data: dict) -> None:
    path = state_file(runtime)
    with _lock_for(path):
        _write_document(path, data)


def _write_document(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".writing")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    # The move is the publish: a reader sees the old document or the new one, never a half of one.
    temporary.replace(path)


#: One lock per state file, so two requests in one bridge cannot interleave their read-modify-write.
#:
#: The apps write the same file from two devices; without this, a `PUT` (read, change, save) and a
#: `POST` landing together would each start from the same read and the second save would drop the
#: first one's change. A *re-entrant* lock because `save()` takes it too, and a mutation calls it.
_LOCKS: dict[str, threading.RLock] = {}
_LOCKS_GUARD = threading.Lock()


def _lock_for(path: Path) -> threading.RLock:
    key = str(path)
    with _LOCKS_GUARD:
        lock = _LOCKS.get(key)
        if lock is None:
            lock = threading.RLock()
            _LOCKS[key] = lock
        return lock


def mutate(runtime, change: Callable[[dict], Any]) -> Any:
    """Apply one change to the document, under the file's lock, and return what it returned.

    The read, the change and the write are one step for anyone else writing this file. A `change`
    that raises (a 404, a 409) leaves the file exactly as it was: nothing is saved.
    """
    path = state_file(runtime)
    with _lock_for(path):
        data = load(runtime)
        outcome = change(data)
        save(runtime, data)
        return outcome


def _clean_name(name: str) -> str:
    cleaned = " ".join(name.split())
    if not cleaned:
        raise HTTPException(status_code=422, detail="a category needs a name")
    if len(cleaned) > MAX_NAME:
        raise HTTPException(status_code=422,
                            detail=f"a category name is capped at {MAX_NAME} characters")
    return cleaned


def _payload(data: dict) -> dict:
    return {"categories": data["categories"], "assignments": data["assignments"]}


def create_bot_categories_router(runtime) -> APIRouter:
    router = APIRouter(prefix="/v1", tags=["bot-categories"])

    @router.get("/bot-categories")
    def list_categories(authorization: str | None = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        return _payload(load(runtime))

    @router.post("/bot-categories")
    def create_category(body: CategoryWrite,
                        authorization: str | None = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        name = _clean_name(body.name)

        def change(data: dict) -> dict:
            if len(data["categories"]) >= MAX_CATEGORIES:
                raise HTTPException(status_code=409,
                                    detail=f"this host holds {MAX_CATEGORIES} categories already")
            if any(str(c.get("name", "")).casefold() == name.casefold()
                   for c in data["categories"]):
                raise HTTPException(status_code=409, detail="a category with that name exists")
            category = {"id": uuid.uuid4().hex[:12], "name": name, "created_at": time.time()}
            data["categories"].append(category)
            return category

        category = mutate(runtime, change)
        return {"category": category, **_payload(load(runtime))}

    @router.patch("/bot-categories/{category_id}")
    def rename_category(category_id: str, body: CategoryWrite,
                        authorization: str | None = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        name = _clean_name(body.name)

        def change(data: dict) -> None:
            target = next((c for c in data["categories"] if c.get("id") == category_id), None)
            if target is None:
                raise HTTPException(status_code=404, detail="no such category")
            if any(c.get("id") != category_id
                   and str(c.get("name", "")).casefold() == name.casefold()
                   for c in data["categories"]):
                raise HTTPException(status_code=409, detail="a category with that name exists")
            target["name"] = name

        mutate(runtime, change)
        return _payload(load(runtime))

    @router.delete("/bot-categories/{category_id}")
    def delete_category(category_id: str,
                        authorization: str | None = Header(default=None)) -> dict:
        require_device(runtime, authorization)

        def change(data: dict) -> None:
            remaining = [c for c in data["categories"] if c.get("id") != category_id]
            if len(remaining) == len(data["categories"]):
                raise HTTPException(status_code=404, detail="no such category")
            data["categories"] = remaining
            # Deleting a group never deletes a bot: a bot with no assignment is Uncategorized, which
            # the list draws for anyone who has not sorted it.
            data["assignments"] = {profile: category
                                   for profile, category in data["assignments"].items()
                                   if category != category_id}

        mutate(runtime, change)
        return _payload(load(runtime))

    @router.put("/bots/{profile}/category")
    def assign_category(profile: str, body: AssignmentWrite,
                        authorization: str | None = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        if not PROFILE_RE.match(profile):
            raise HTTPException(status_code=422, detail="invalid profile name")

        def change(data: dict) -> None:
            if body.category_id is None:
                data["assignments"].pop(profile, None)
            else:
                if not any(c.get("id") == body.category_id for c in data["categories"]):
                    raise HTTPException(status_code=404, detail="no such category")
                data["assignments"][profile] = body.category_id

        mutate(runtime, change)
        return {"profile": profile, "category_id": body.category_id, **_payload(load(runtime))}

    return router

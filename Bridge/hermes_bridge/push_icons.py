"""The face a banner carries: the bot's own portrait, exported once and served as a PNG.

Bark can show one image inside a notification, and it takes a URL. The honest source of that image
is the app itself — `BotSilhouette` is SwiftUI geometry, and re-drawing it in Python would produce a
second, subtly different family of faces. So the app renders it with `ImageRenderer` and uploads the
bytes; the host only stores and serves them.

Where they live matters: the bridge runs under `ProtectSystem=strict` and can write nothing but
`/var/lib/hermey`, while the phone has to fetch the image over the tailnet. `hermes-apps-dist`
already serves `/srv/hermes-apps-dist` on `:8444`, so a symlink `icons -> /var/lib/hermey/push-icons`
puts the bytes where an unauthenticated GET can reach them without widening either unit.
"""
import hashlib
import re
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Header, HTTPException, Response
from pydantic import BaseModel

from .device_auth import require_device

#: Where the apps write their renders. One file per bot, named after the profile.
#:
#: Under `/var/lib/hermey`, which is what the unit's `ReadWritePaths` actually allows — the icons
#: first lived in `/var/lib/hermey` and every upload would have failed with a read-only
#: filesystem, because the deployed unit may write only the live state dir.
ICON_DIR = Path("/var/lib/hermey/push-icons")

#: A notification image, not a wallpaper.
MAX_BYTES = 512 * 1024

#: PNG magic. A caller sending anything else is a bug, and a text file served as an image is worse
#: than no image at all.
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"

_PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


class IconUpload(BaseModel):
    #: Base64 PNG. Base64 rather than multipart so the client needs no encoder beyond what it has.
    png: str
    #: The renderer's own hash, so an unchanged face costs a request and no write.
    sha256: Optional[str] = None


def _path(profile: str) -> Path:
    return ICON_DIR / f"{profile}.png"


def icon_exists(profile: str) -> bool:
    return _path(profile).is_file()


def create_push_icon_router(runtime) -> APIRouter:
    router = APIRouter(prefix="/v1/push/icon", tags=["push"])

    @router.put("/{profile}")
    def upload(profile: str, body: IconUpload,
               authorization: str | None = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        if not _PROFILE_RE.match(profile):
            raise HTTPException(status_code=422, detail="invalid profile")
        import base64

        try:
            data = base64.b64decode(body.png, validate=True)
        except Exception:
            raise HTTPException(status_code=422, detail="png is not base64")
        if not data.startswith(PNG_MAGIC):
            raise HTTPException(status_code=422, detail="not a PNG")
        if len(data) > MAX_BYTES:
            raise HTTPException(status_code=413, detail="icon is too large")

        digest = hashlib.sha256(data).hexdigest()
        if body.sha256 and body.sha256 == digest and icon_exists(profile):
            return {"profile": profile, "changed": False, "sha256": digest}

        ICON_DIR.mkdir(parents=True, exist_ok=True)
        # Written to a neighbour and moved, so a reader never sees half an image.
        temporary = _path(profile).with_suffix(".png.part")
        temporary.write_bytes(data)
        temporary.replace(_path(profile))
        return {"profile": profile, "changed": True, "sha256": digest}

    @router.get("/{profile}.png")
    def fetch(profile: str) -> Response:
        """Unauthenticated on purpose: the relay app fetches this, and it holds no credential.

        The only thing it reveals is a bot's face — the same picture the roster shows to anyone
        with the app. Nothing here names a bot's instructions, notes or messages.
        """
        profile = profile.removesuffix(".png")
        if not _PROFILE_RE.match(profile) or not icon_exists(profile):
            raise HTTPException(status_code=404, detail="no icon")
        return Response(content=_path(profile).read_bytes(), media_type="image/png",
                        headers={"cache-control": "no-cache"})

    return router

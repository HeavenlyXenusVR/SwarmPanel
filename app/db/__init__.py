"""PanelDatabase, composed from domain mixins.

Split from a single 4,487-line database.py into per-domain modules (core
plumbing + cache invalidation, accounts, social, bots, gallery, lumisound,
admin-browser, metrics) via Python mixin composition — this preserves every
``db.method_name(...)`` call site in the rest of the app unchanged, since
external code still sees one ``PanelDatabase`` instance with all methods.

``CoreMixin`` must stay first in the MRO: it's the only mixin that defines
``__init__``, owns all cache dicts, and its ``_invalidate_hot_caches()`` is
called from methods in nearly every other mixin (e.g. ``control_bot()`` in
BotsMixin invalidates the gallery/dashboard caches too) — cache ownership
could not be split per-domain without duplicating state.
"""

from .accounts import AccountsMixin
from .admin_browser import AdminBrowserMixin
from .alerts import AlertsMixin
from .audit import AuditMixin
from .bots import BotsMixin
from .core import CoreMixin
from .gallery import GalleryMixin
from .lumisound import LumisoundMixin
from .metrics import MetricsMixin
from .social import SocialMixin


class PanelDatabase(
    CoreMixin,
    AccountsMixin,
    SocialMixin,
    BotsMixin,
    GalleryMixin,
    LumisoundMixin,
    AdminBrowserMixin,
    MetricsMixin,
    AuditMixin,
    AlertsMixin,
):
    pass


__all__ = ["PanelDatabase"]

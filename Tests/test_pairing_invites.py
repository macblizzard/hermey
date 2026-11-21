"""A paired device can invite another one, on both apps.

Asked for 2026-11-17: "generate a qr code and url on both devices to pair another device from that … on
desktop the option should be available on command palette as well". Three halves: the host relaxed its
own rule (a paired device already holds full authority, so the invite grants nothing new — but it is
audited), the client asks for the invite, and each app shows it as a QR and a link.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = (ROOT / "Sources" / "HermesKit" / "BotModelSettings.swift").read_text(encoding="utf-8")
CLIENT = (ROOT / "Sources" / "HermesKit" / "EndlessSessionPointer.swift").read_text(encoding="utf-8")
ACTOR = (ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
QR = (ROOT / "Sources" / "HermeyUI" / "QRCodeView.swift").read_text(encoding="utf-8")
IOS_SHEET = (ROOT / "Apps" / "HermesMobile" / "Views" / "PairAnotherDeviceSheet.swift").read_text(encoding="utf-8")
IOS_DEVICES = (ROOT / "Apps" / "HermesMobile" / "Views" / "SettingsScreen.swift").read_text(encoding="utf-8")
IOS_APP = (ROOT / "Apps" / "HermesMobile" / "HermesMobileApp.swift").read_text(encoding="utf-8")
MAC_SHEET = (ROOT / "Apps" / "HermesMac" / "Pairing" / "MacPairAnotherSheet.swift").read_text(encoding="utf-8")
STORE = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")
ROOT_VIEW = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")


class TheClientAsksForAnInvite(unittest.TestCase):
    # Removed with the Python bridge: `testLocalStillMintsWithoutCredentials` and
    # `testTheInviteIsAuditedAgainstTheMinter` guarded `app.py`'s rule that a *paired device* may
    # mint a pairing code, and its `pair.invite` audit record. hermeyd's `pair_start` mints on the
    # loopback host only and emits no `pair.invite` event, so both assertions lost their subject —
    # the gap is reported with this change rather than papered over.

    def testTheClientAsksThroughItsBridgeTicket(self) -> None:
        self.assertIn("func makePairingInvite() async throws -> PairingInvite", CLIENT)
        self.assertIn('bridgePOST("v1/pair/start", body: [:], timeout: 15)', CLIENT)
        self.assertIn("return try await sessionPointer.makePairingInvite()", ACTOR)
        self.assertIn("public func makePairingInvite() async throws -> PairingInvite", MODEL)


class TheInviteIsAShareableLink(unittest.TestCase):
    def testTheUrlIsTheShapeEverySurfaceAlreadyParses(self) -> None:
        # Both apps' pairing parsers accept any scheme with `host` + `code` in the query — the same
        # shape `hermey pair` prints. Inventing a new one would mean teaching every parser.
        self.assertIn('URLComponents(string: "hermes://pair")', KIT)
        self.assertIn('URLQueryItem(name: "host", value: host)', KIT)
        self.assertIn('URLQueryItem(name: "code", value: code)', KIT)

    def testTheExpirySurvivesJSONFloats(self) -> None:
        # `expires_at` is an epoch in seconds — a JSON number with a fraction, which `as? Int` refuses.
        self.assertIn('(object["expires_at"] as? Double).map(Int.init)', KIT)


class TheAppsShowIt(unittest.TestCase):
    def testBothSheetsShowQRLinkCopyAndExpiry(self) -> None:
        for name, sheet in (("iOS", IOS_SHEET), ("macOS", MAC_SHEET)):
            with self.subTest(platform=name):
                self.assertIn("QRCodeView(content: invite.url", sheet)
                self.assertIn("invite.url", sheet)
                self.assertIn("Copy link", sheet)
                self.assertIn("single-use", sheet)

    def testMobileReachesItFromDevices(self) -> None:
        self.assertIn("Pair another device…", IOS_DEVICES)
        self.assertIn("PairAnotherDeviceSheet(model: app.model)", IOS_DEVICES)
        self.assertIn(".disabled(!app.isPaired)", IOS_DEVICES)

    def testMacReachesItFromThePalette(self) -> None:
        self.assertIn('id: "host.invite"', STORE)
        self.assertIn("Pair another device…", STORE)
        self.assertIn("MacPairAnotherSheet(model: store.model)", ROOT_VIEW)
        self.assertIn("case .pairInvite: return \"pair-invite\"", ROOT_VIEW)

    def testAScannedInviteOpensThePairingSheetWithTheLinkLoaded(self) -> None:
        # A QR read by the *system* camera lands on the app's own URL scheme; the sheet absorbs it
        # through its existing host-confirmation dialog rather than pairing sight unseen.
        self.assertIn('url.host == "pair"', IOS_APP)
        self.assertIn("pendingPairingLink = url.absoluteString", IOS_APP)
        self.assertIn("guard let link = app.pendingPairingLink else { return }",
                      (ROOT / "Apps/HermesMobile/Views/PairingSheet.swift").read_text(encoding="utf-8"))


class TheQRIsSystemDrawn(unittest.TestCase):
    def testCoreImageGeneratorOnBothPlatforms(self) -> None:
        self.assertIn("CIFilter.qrCodeGenerator()", QR)
        self.assertIn("#if os(iOS)", QR)
        self.assertIn("UIImage", QR)
        self.assertIn("NSImage", QR)

    def testDarkModulesOnWhite(self) -> None:
        # A QR's finder patterns assume contrast; the app's dark canvas is exactly the wrong backdrop.
        self.assertIn(".fill(.white)", IOS_SHEET)
        self.assertIn(".fill(.white)", MAC_SHEET)

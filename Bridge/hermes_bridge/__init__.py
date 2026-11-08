"""Hermes bridge — the only new server-side surface for the native clients.

Rules this package must keep, because they are the whole security story:

* bind loopback only (`127.0.0.1`); TLS and tailnet exposure are `tailscale serve`'s job
* never expose the gateway's own token to a client
* every device is identified by a public key it holds in its Secure Enclave/Keychain
* every request is authenticated, size-capped and method-allow-listed
"""

from .app import create_app

__all__ = ["create_app"]

"""The LLM API key in the desktop keyring (the Keychain on macOS).

Uses Secret Service (GNOME Keyring, KWallet) through `keyring`. Same
service/account names as KeychainStore, so the key is easy to find.
"""
import keyring
from keyring.errors import KeyringError

SERVICE = "com.papertalk.key"


def read(account: str) -> str:
    """The secret saved under `account`, or "" (also when no keyring is available)."""
    try:
        return keyring.get_password(SERVICE, account) or ""
    except KeyringError:
        return ""


def write(account: str, secret: str) -> bool:
    """Save `secret` under `account`; False when no keyring is available."""
    try:
        keyring.set_password(SERVICE, account, secret)
        return True
    except KeyringError:
        return False


def delete(account: str) -> None:
    """Remove `account`'s secret, if there is one."""
    try:
        keyring.delete_password(SERVICE, account)
    except KeyringError:
        pass

import logging
from urllib.parse import urlparse

import jwt

from core import Denied, Officer

LOG = logging.getLogger("regiq.audit")


class Authentication:
    def __init__(self, tenant: str, app_id: str, bot_id: str, officers: dict, approvers: list[str]):
        self.tenant = tenant
        self.app_id = app_id
        self.bot_id = bot_id
        self.officers = officers
        self.approvers = set(approvers)
        self.entra_keys = jwt.PyJWKClient(
            f"https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys",
            lifespan=3600,
        )
        self.bot_keys = jwt.PyJWKClient(
            "https://login.botframework.com/v1/.well-known/keys", lifespan=3600,
        )

    def entra(self, token: str, audiences: list[str]) -> dict:
        try:
            key = self.entra_keys.get_signing_key_from_jwt(token)
            claims = jwt.decode(
                token, key.key, algorithms=["RS256"], audience=audiences,
                issuer=[
                    f"https://sts.windows.net/{self.tenant}/",
                    f"https://login.microsoftonline.com/{self.tenant}/v2.0",
                ],
                options={"require": ["exp", "nbf", "aud", "iss", "oid", "tid"]},
            )
        except (jwt.PyJWTError, ValueError) as exc:
            raise Denied("Invalid or expired Entra token.") from exc
        if claims["tid"] != self.tenant:
            raise Denied("Wrong tenant.")
        return claims

    def api(self, token: str) -> dict:
        claims = self.entra(token, [self.app_id, f"api://{self.app_id}"])
        if "access_as_user" not in claims.get("scp", "").split() and not (
            set(claims.get("roles", [])) & {"OfficerTest", "ApprovalTest"}
        ):
            raise Denied("An API access token with the required permission is required.")
        return claims

    def officer(self, oid: str) -> Officer:
        entry = self.officers.get(oid)
        if not entry:
            raise Denied("This identity is not a configured tax officer.")
        return Officer(oid, entry["partition"], entry["container"])

    def storage(self, token: str, oid: str) -> dict:
        claims = self.entra(token, ["https://storage.azure.com", "https://storage.azure.com/"])
        if claims["oid"] != oid:
            raise Denied("Storage token identity does not match the caller.")
        if claims.get("scp") and "user_impersonation" not in claims["scp"].split():
            raise Denied("Missing delegated Storage permission.")
        return claims

    def approver(self, oid: str):
        if oid not in self.approvers:
            raise Denied("Administrator approval permission is required.")

    def bot(self, token: str, activity: dict) -> str:
        try:
            key = self.bot_keys.get_signing_key_from_jwt(token)
            claims = jwt.decode(
                token, key.key, algorithms=["RS256"],
                issuer="https://api.botframework.com", audience=self.bot_id,
                options={"require": ["exp", "nbf", "iss", "aud"]},
                leeway=60,
            )
        except (jwt.PyJWTError, ValueError) as exc:
            raise Denied("Invalid Bot Connector token.") from exc
        endorsements = key._jwk_data.get("endorsements", [])
        if "msteams" not in endorsements or activity.get("channelId") != "msteams":
            raise Denied("An endorsed Microsoft Teams channel is required.")
        url = activity.get("serviceUrl", "")
        parsed = urlparse(url)
        service_url = claims.get("serviceurl", claims.get("serviceUrl", ""))
        if (not service_url or service_url.rstrip("/") != url.rstrip("/")
                or parsed.scheme != "https" or parsed.hostname != "smba.trafficmanager.net"
                or parsed.username or parsed.password or parsed.port not in (None, 443)
                or parsed.query or parsed.fragment):
            raise Denied("Invalid Teams service URL.")
        if activity.get("channelData", {}).get("tenant", {}).get("id") != self.tenant:
            raise Denied("Wrong Teams tenant.")
        if activity.get("conversation", {}).get("conversationType") != "personal":
            raise Denied("Use a personal conversation; shared chats are not supported.")
        oid = activity.get("from", {}).get("aadObjectId")
        if not oid:
            raise Denied("A trusted officer identity is required.")
        return oid

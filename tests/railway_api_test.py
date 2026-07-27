#!/usr/bin/env python3
"""Black-box regression tests for the Railway GraphQL helper.

The helper is invoked exactly as a skill caller invokes it.  A fake curl binary
records options and header-file contents, so no credential or network request
leaves the test process.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = REPO_ROOT / "plugins/railway/skills/use-railway/scripts/railway-api.sh"
QUERY = "query { project { id } }"

FAKE_CURL = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

arguments = sys.argv[1:]
headers = []
for index, argument in enumerate(arguments):
    if argument == "-H":
        header = arguments[index + 1]
        if header.startswith("@"):
            headers.extend(
                line for line in Path(header[1:]).read_text().splitlines() if line
            )
        else:
            headers.append(header)

Path(os.environ["TEST_CAPTURE_PATH"]).write_text(
    json.dumps({"arguments": arguments, "headers": headers})
)
print('{"data":{"ok":true}}')
"""

FAKE_RAILWAY = """#!/usr/bin/env python3
import os
from pathlib import Path

Path(os.environ["TEST_RAILWAY_INVOKED_PATH"]).write_text("invoked")
raise SystemExit(1)
"""


class RailwayApiHelperTests(unittest.TestCase):
    def run_helper(self, *, config=None, api_token=None, project_token=None):
        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            home = temp_dir / "home"
            curl_dir = temp_dir / "bin"
            capture_path = temp_dir / "capture.json"
            curl_dir.mkdir(parents=True)
            fake_curl = curl_dir / "curl"
            fake_curl.write_text(FAKE_CURL)
            fake_curl.chmod(0o755)
            fake_railway = curl_dir / "railway"
            fake_railway.write_text(FAKE_RAILWAY)
            fake_railway.chmod(0o755)
            railway_invoked_path = temp_dir / "railway-invoked"

            if config is not None:
                config_path = home / ".railway/config.json"
                config_path.parent.mkdir(parents=True)
                config_path.write_text(json.dumps(config))

            environment = os.environ.copy()
            environment.update(
                {
                    "HOME": str(home),
                    "PATH": f"{curl_dir}:{environment['PATH']}",
                    "TEST_CAPTURE_PATH": str(capture_path),
                    "TEST_RAILWAY_INVOKED_PATH": str(railway_invoked_path),
                }
            )
            environment.pop("RAILWAY_API_TOKEN", None)
            environment.pop("RAILWAY_TOKEN", None)
            if api_token is not None:
                environment["RAILWAY_API_TOKEN"] = api_token
            if project_token is not None:
                environment["RAILWAY_TOKEN"] = project_token

            completed = subprocess.run(
                [str(HELPER), QUERY],
                cwd=REPO_ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            capture = (
                json.loads(capture_path.read_text()) if capture_path.exists() else None
            )
            return completed, capture, railway_invoked_path.exists()

    def assert_success_header(
        self, completed, capture, railway_invoked, expected_header, token
    ):
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout), {"data": {"ok": True}})
        self.assertIsNotNone(capture)
        self.assertIn(expected_header, capture["headers"])
        self.assertNotIn(token, " ".join(capture["arguments"]))
        self.assertFalse(railway_invoked)

    def test_current_oauth_access_token_uses_bearer_without_refreshing(self):
        token = "fixture-oauth-access-token"
        completed, capture, railway_invoked = self.run_helper(
            config={
                "user": {
                    "accessToken": token,
                    "refreshToken": "fixture-refresh-token",
                    "tokenExpiresAt": int(time.time()) + 3600,
                }
            }
        )

        self.assert_success_header(
            completed, capture, railway_invoked, f"Authorization: Bearer {token}", token
        )
        observed = completed.stdout + completed.stderr + " ".join(
            capture["arguments"] + capture["headers"]
        )
        self.assertNotIn("fixture-refresh-token", observed)

    def test_legacy_config_token_remains_compatible(self):
        token = "fixture-legacy-token"
        completed, capture, railway_invoked = self.run_helper(
            config={"user": {"token": token}}
        )

        self.assert_success_header(
            completed, capture, railway_invoked, f"Authorization: Bearer {token}", token
        )

    def test_explicit_account_or_workspace_token_does_not_require_config(self):
        token = "fixture-account-token"
        completed, capture, railway_invoked = self.run_helper(api_token=token)

        self.assert_success_header(
            completed, capture, railway_invoked, f"Authorization: Bearer {token}", token
        )

    def test_explicit_project_token_uses_project_access_token_header(self):
        token = "fixture-project-token"
        completed, capture, railway_invoked = self.run_helper(project_token=token)

        self.assert_success_header(
            completed,
            capture,
            railway_invoked,
            f"Project-Access-Token: {token}",
            token,
        )
        self.assertFalse(
            any(header.startswith("Authorization:") for header in capture["headers"])
        )

    def test_mutually_exclusive_explicit_tokens_fail_without_request(self):
        completed, capture, railway_invoked = self.run_helper(
            api_token="fixture-account-token", project_token="fixture-project-token"
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("cannot both be set", completed.stdout)
        self.assertIsNone(capture)
        self.assertFalse(railway_invoked)

    def test_missing_credentials_fail_without_request(self):
        completed, capture, railway_invoked = self.run_helper(config={"user": {}})

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("No Railway credential found", completed.stdout)
        self.assertIsNone(capture)
        self.assertFalse(railway_invoked)

    def test_refresh_token_is_never_used_as_a_credential(self):
        completed, capture, railway_invoked = self.run_helper(
            config={"user": {"refreshToken": "fixture-refresh-token"}}
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("No Railway credential found", completed.stdout)
        self.assertIsNone(capture)
        self.assertFalse(railway_invoked)

    def test_expired_access_token_fails_without_refreshing_or_requesting(self):
        completed, capture, railway_invoked = self.run_helper(
            config={
                "user": {
                    "accessToken": "fixture-expired-access-token",
                    "refreshToken": "fixture-refresh-token",
                    "tokenExpiresAt": int(time.time()) - 1,
                }
            }
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("expired", completed.stdout)
        self.assertIsNone(capture)
        self.assertFalse(railway_invoked)

    def test_access_token_without_a_valid_expiry_fails_predictably(self):
        completed, capture, railway_invoked = self.run_helper(
            config={"user": {"accessToken": "fixture-access-token"}}
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("valid expiry", completed.stdout)
        self.assertIsNone(capture)
        self.assertFalse(railway_invoked)


if __name__ == "__main__":
    unittest.main()

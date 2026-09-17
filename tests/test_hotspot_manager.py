import importlib.util
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).parents[1] / "scripts" / "hotspot-manager.py"
SPEC = importlib.util.spec_from_file_location("hotspot_manager", MODULE_PATH)
assert SPEC and SPEC.loader
hotspot_manager = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hotspot_manager)


class RunArgsTests(unittest.TestCase):
    def test_uses_requested_timeout(self):
        completed = subprocess.CompletedProcess(["command"], 0, "ok\n", "")
        with patch.object(subprocess, "run", return_value=completed) as run:
            result = hotspot_manager.run_args(["command"], timeout=75)

        self.assertEqual(result, (True, "ok", ""))
        self.assertEqual(run.call_args.kwargs["timeout"], 75)


class RestartVpnTests(unittest.TestCase):
    def test_retries_activation_before_applying_policy(self):
        up_attempts = 0

        def fake_run_args(cmd, timeout=30):
            nonlocal up_attempts
            if cmd[:4] == ["sudo", "nmcli", "connection", "up"]:
                up_attempts += 1
                if up_attempts == 1:
                    return False, "", "temporary timeout"
            return True, "", ""

        with (
            patch.object(
                hotspot_manager, "get_configured_backend", return_value="tun0"
            ),
            patch.object(hotspot_manager, "check_vpn", return_value=False),
            patch.object(hotspot_manager, "run_args", side_effect=fake_run_args),
            patch.object(hotspot_manager, "wait_for_interface", return_value=True),
            patch.object(
                hotspot_manager, "apply_vpn_policy", return_value=True
            ) as policy,
            patch.object(hotspot_manager, "refresh_github_routes") as refresh,
            patch.object(hotspot_manager.time, "sleep"),
            patch.object(hotspot_manager, "log"),
        ):
            self.assertTrue(hotspot_manager.restart_vpn())

        self.assertEqual(up_attempts, 2)
        policy.assert_called_once_with()
        refresh.assert_called_once_with()

    def test_github_refresh_allows_sufficient_runtime(self):
        with (
            patch.object(hotspot_manager, "run_args") as run,
            patch.object(hotspot_manager, "GITHUB_ROUTE_SCRIPT", "/route-refresh"),
        ):
            run.side_effect = [(True, "", ""), (True, "", "")]
            hotspot_manager.refresh_github_routes()

        self.assertEqual(run.call_args_list[1].kwargs["timeout"], 120)


if __name__ == "__main__":
    unittest.main()

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


class Ipv6ModeTests(unittest.TestCase):
    def test_get_configured_ipv6_mode_defaults_to_drop(self):
        with patch("builtins.open", side_effect=FileNotFoundError):
            self.assertEqual(hotspot_manager.get_configured_ipv6_mode(), "drop")

    def test_set_ipv6_mode_rejects_invalid_values(self):
        self.assertFalse(hotspot_manager.set_ipv6_mode("invalid"))

    def test_set_ipv6_mode_valid(self):
        with (
            patch.object(
                hotspot_manager, "update_goodwifi_conf", return_value=True
            ) as upd,
            patch.object(hotspot_manager, "apply_vpn_policy", return_value=True) as pol,
            patch.object(hotspot_manager, "log"),
        ):
            self.assertTrue(hotspot_manager.set_ipv6_mode("reject"))
            upd.assert_called_once_with("IPV6_LEAK_PROTECTION", "reject")
            pol.assert_called_once_with()


class DockerServiceTests(unittest.TestCase):
    def test_check_docker_container_running(self):
        with patch.object(hotspot_manager, "run_args", return_value=(True, "true", "")):
            self.assertTrue(hotspot_manager.check_docker_container("adguardhome"))

    def test_check_docker_container_stopped(self):
        with patch.object(
            hotspot_manager, "run_args", return_value=(True, "false", "")
        ):
            self.assertFalse(hotspot_manager.check_docker_container("adguardhome"))

    def test_check_docker_container_missing(self):
        with patch.object(
            hotspot_manager, "run_args", return_value=(False, "", "no such object")
        ):
            self.assertIsNone(hotspot_manager.check_docker_container("nonexistent"))


class VpnConnectionDetectionTests(unittest.TestCase):
    def test_auto_detects_vpn_connection(self):
        nmcli_output = "eth0:802-3-ethernet\nmy-custom-vpn:vpn\n"
        with (
            patch.dict(hotspot_manager.CONFIG, {"vpn_name": ""}),
            patch.object(
                hotspot_manager,
                "run_args",
                side_effect=[
                    (True, nmcli_output, ""),
                    (False, "", ""),
                ],
            ),
        ):
            self.assertEqual(hotspot_manager.get_vpn_connection_name(), "my-custom-vpn")

    def test_uses_explicit_configured_vpn_connection(self):
        nmcli_output = "eth0:802-3-ethernet\ncustom-vpn:vpn\n"
        with (
            patch.dict(hotspot_manager.CONFIG, {"vpn_name": "custom-vpn"}),
            patch.object(
                hotspot_manager,
                "run_args",
                return_value=(True, nmcli_output, ""),
            ),
        ):
            self.assertEqual(hotspot_manager.get_vpn_connection_name(), "custom-vpn")


class AdGuardStateTests(unittest.TestCase):
    def test_get_adguard_enabled_defaults_to_true(self):
        with patch("builtins.open", side_effect=FileNotFoundError):
            with patch.object(
                hotspot_manager, "check_docker_container", return_value=True
            ):
                self.assertTrue(hotspot_manager.get_adguard_enabled())

    def test_set_adguard_state_disable(self):
        with (
            patch.object(
                hotspot_manager, "update_goodwifi_conf", return_value=True
            ) as upd,
            patch.object(
                hotspot_manager, "configure_dnsmasq_fallback", return_value=True
            ) as dnsm,
            patch.object(
                hotspot_manager, "run_args", return_value=(True, "", "")
            ) as run,
            patch.object(hotspot_manager, "check_dns", return_value=True),
            patch.object(hotspot_manager, "log"),
        ):
            self.assertTrue(hotspot_manager.set_adguard_state(False))
            upd.assert_called_once_with("ADGUARD_ENABLED", "false")
            dnsm.assert_called_once_with(enable_fallback=True)
            stop_call = any(
                call.args[0][:2] == ["docker", "stop"] for call in run.call_args_list
            )
            self.assertTrue(stop_call)

    def test_set_adguard_state_enable(self):
        with (
            patch.object(
                hotspot_manager, "update_goodwifi_conf", return_value=True
            ) as upd,
            patch.object(
                hotspot_manager, "configure_dnsmasq_fallback", return_value=True
            ) as dnsm,
            patch.object(hotspot_manager, "run_args", return_value=(True, "", "")),
            patch.object(hotspot_manager, "check_docker_container", return_value=True),
            patch.object(hotspot_manager, "log"),
        ):
            self.assertTrue(hotspot_manager.set_adguard_state(True))
            upd.assert_called_once_with("ADGUARD_ENABLED", "true")
            dnsm.assert_called_once_with(enable_fallback=False)


if __name__ == "__main__":
    unittest.main()
